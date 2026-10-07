#!/usr/bin/env python3
"""격리 릴레이 스모크 감독자 (#276 §2.4, 파이널라이저 PR ③).

Go 릴레이(`archive/native-mls/server`)를 `-access-mode disabled` 로 loopback 임시 포트에 띄우고, 시뮬레이터 XCTest
(`FamilyChatTests/RelaySmokeTests.swift`)가 릴레이를 **중단·재시작**할 수 있게 작은 제어 HTTP 를 연다.
데이터 디렉터리는 호출자가 `mktemp -d` 로 준다 — 재시작해도 같은 디렉터리를 쓰므로 저장된 이벤트가 남아
"재시작 뒤 정확 바이트 재전송 = 200 duplicate" 를 실제 디스크로 확인한다.

  POST /stop     릴레이 종료(SIGTERM, 기다림)          → {"running": false}
  POST /start    같은 인자로 다시 시작, /v2/health 대기   → {"running": true}
  GET  /status   {"running": bool, "restarts": n}
  POST /shutdown 릴레이 종료 후 감독자도 끝낸다

준비되면 `--ready-file` 에 {"relay_url", "control_url", "pid"} JSON 을 쓴다(CI 스텝·로컬 컨테이너가 읽음).
운영 서비스·운영 데이터와 무관: 127.0.0.1 의 빈 포트(0 = 자동)와 넘겨받은 임시 디렉터리만 쓴다.
표준 라이브러리만 사용.
"""
import argparse
import http.server
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Relay:
    def __init__(self, binary, data_dir, port, log_path):
        self.argv = [binary, "-addr", f"127.0.0.1:{port}", "-data-dir", data_dir, "-access-mode", "disabled"]
        self.url = f"http://127.0.0.1:{port}"
        self.log_path = log_path
        self.proc = None
        self.restarts = 0
        self.lock = threading.Lock()

    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def start(self, timeout=30):
        with self.lock:
            if self.running():
                return
            log = open(self.log_path, "ab")
            self.proc = subprocess.Popen(self.argv, stdout=log, stderr=subprocess.STDOUT)
            deadline = time.time() + timeout
            while time.time() < deadline:
                if self.proc.poll() is not None:
                    raise RuntimeError(f"relay exited early with {self.proc.returncode} (see {self.log_path})")
                try:
                    with urllib.request.urlopen(self.url + "/v2/health", timeout=1) as r:
                        if r.status == 200:
                            return
                except OSError:
                    pass
                time.sleep(0.1)
            raise RuntimeError("relay did not become healthy in time")

    def stop(self, timeout=15):
        with self.lock:
            if not self.running():
                return
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
            self.restarts += 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--relay-bin", required=True)
    ap.add_argument("--data-dir", required=True, help="mktemp -d 로 만든 빈 디렉터리")
    ap.add_argument("--port", type=int, default=0, help="릴레이 포트(0 = 빈 포트 자동)")
    ap.add_argument("--control-port", type=int, default=0)
    ap.add_argument("--ready-file", required=True)
    ap.add_argument("--log", default=None, help="릴레이 로그(기본 <data-dir>/relay.log)")
    args = ap.parse_args()

    relay = Relay(args.relay_bin, args.data_dir, args.port or free_port(), args.log or os.path.join(args.data_dir, "relay.log"))
    relay.start()
    done = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def reply(self, code, body):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/status":
                return self.reply(200, {"running": relay.running(), "restarts": relay.restarts})
            self.reply(404, {"error": "not_found"})

        def do_POST(self):
            try:
                if self.path == "/stop":
                    relay.stop()
                elif self.path == "/start":
                    relay.start()
                elif self.path == "/shutdown":
                    relay.stop()
                    done.set()
                else:
                    return self.reply(404, {"error": "not_found"})
                self.reply(200, {"running": relay.running(), "restarts": relay.restarts})
            except Exception as exc:  # 제어 실패는 테스트가 그대로 보도록 500 + 사유
                self.reply(500, {"error": str(exc)})

        def log_message(self, fmt, *a):
            sys.stderr.write("[supervisor] " + (fmt % a) + "\n")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.control_port), Handler)
    control_url = f"http://127.0.0.1:{server.server_address[1]}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with open(args.ready_file + ".tmp", "w") as f:
        json.dump({"relay_url": relay.url, "control_url": control_url, "pid": os.getpid()}, f)
    os.replace(args.ready_file + ".tmp", args.ready_file)
    print(f"READY relay={relay.url} control={control_url}", flush=True)

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: done.set())
    done.wait()
    relay.stop()
    server.shutdown()


if __name__ == "__main__":
    main()
