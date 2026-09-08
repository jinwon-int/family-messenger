#!/usr/bin/env python3
"""Run only a newly spawned loopback prototype with synthetic data; retain evidence."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    root = Path(__file__).resolve().parents[1]
    (root / "artifacts").mkdir(mode=0o700, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="native-live-", dir=root / "artifacts"))
    state = work / "state"
    state.mkdir(mode=0o700)
    log = work / "server.log"
    evidence = {"synthetic_only": True, "e2ee": False,
                "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    process = None
    output = None
    url = None

    def start():
        nonlocal process, output, url
        output = log.open("ab")
        offset = log.stat().st_size
        process = subprocess.Popen([str(binary), "--synthetic-only", "--state", str(state),
                                    "--listen", "127.0.0.1:0"],
                                   stdout=subprocess.DEVNULL, stderr=output)
        until = time.monotonic() + 10
        while time.monotonic() < until:
            if process.poll() is not None:
                raise RuntimeError("prototype exited before listening")
            content = log.read_bytes()[offset:].decode()
            match = re.search(r"listening (127\.0\.0\.1:\d+)", content)
            if match:
                url = "http://" + match[1]
                return
            time.sleep(0.02)
        raise RuntimeError("prototype start timeout")

    def request(method, path, actor="alice", data=None, headers=None, want=200):
        hs = {"Authorization": "Bearer synthetic-" + actor,
              "Content-Type": "application/json"}
        hs.update(headers or {})
        req = urllib.request.Request(url + path, method=method, headers=hs,
                                     data=json.dumps(data).encode() if data is not None else None)
        try:
            response = urllib.request.urlopen(req, timeout=5)
        except urllib.error.HTTPError as exc:
            response = exc
        assert response.status == want, (path, response.status, want)
        return response

    def decoded(response):
        with response:
            return json.load(response)

    def event(response):
        while True:
            line = response.readline()
            if not line:
                raise RuntimeError("unexpected SSE EOF")
            if line.startswith(b"data: "):
                return json.loads(line[6:])

    try:
        denied = subprocess.run([str(binary), "--synthetic-only", "--state", str(state),
                                 "--listen", "0.0.0.0:18920"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        assert denied.returncode != 0
        evidence["non_loopback_rejected"] = True
        start()
        decoded(request("POST", "/v1/rooms", data={"id": "family", "members": ["bob"]}, want=201))
        payload = {"client_id": "first", "payload": base64.b64encode(b"SYNTHETIC one").decode()}
        first = decoded(request("POST", "/v1/rooms/family/messages", data=payload, want=201))
        assert first["seq"] == 1
        assert decoded(request("POST", "/v1/rooms/family/messages", data=payload)) == first
        conflict = dict(payload, payload=base64.b64encode(b"changed").decode())
        request("POST", "/v1/rooms/family/messages", data=conflict, want=409).close()
        request("GET", "/v1/rooms/family/messages", actor="charlie", want=403).close()
        evidence["idempotency_conflict_and_acl"] = True
        process.kill()
        process.wait(timeout=5)
        output.close()
        start()
        assert decoded(request("GET", "/v1/rooms/family/messages", actor="bob")) == [first]
        assert decoded(request("POST", "/v1/rooms/family/messages", data=payload)) == first
        evidence["sigkill_restart_preserves_committed_message_and_retry"] = True
        with request("GET", "/v1/rooms/family/events", actor="bob",
                     headers={"Last-Event-ID": "1"}) as stream:
            second = decoded(request("POST", "/v1/rooms/family/messages",
                                     data=dict(payload, client_id="second"), want=201))
            assert event(stream) == second
        third = decoded(request("POST", "/v1/rooms/family/messages",
                                data=dict(payload, client_id="third"), want=201))
        with request("GET", "/v1/rooms/family/events?after=0", actor="bob",
                     headers={"Last-Event-ID": "2"}) as stream:
            assert event(stream) == third
            request("DELETE", "/v1/rooms/family/members/bob", want=204).close()
            decoded(request("POST", "/v1/rooms/family/messages",
                            data=dict(payload, client_id="fourth"), want=201))
            assert b"data:" not in stream.read()
        request("GET", "/v1/rooms/family/events", actor="bob", want=403).close()
        evidence["sse_live_replay_and_revocation"] = True
        process.terminate()
        assert process.wait(timeout=5) == 0
        output.close()
        start()
        request("GET", "/v1/rooms/family/messages", actor="bob", want=403).close()
        evidence["revocation_survives_restart"] = True
        evidence["state_file_modes"] = {p.name: oct(p.stat().st_mode & 0o777) for p in state.iterdir()}
        assert all(v == "0o600" for v in evidence["state_file_modes"].values())
        evidence["ok"] = True
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        if output is not None:
            output.close()
        (work / "verification.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(work / "verification.json")


if __name__ == "__main__":
    os.umask(0o077)
    main()
