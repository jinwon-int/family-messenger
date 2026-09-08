#!/usr/bin/env python3
"""Two isolated synthetic Chromium clients against a freshly spawned native server."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
import urllib.request
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright, expect


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    root = Path(__file__).resolve().parents[1]
    (root / "artifacts").mkdir(mode=0o700, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="native-browser-", dir=root / "artifacts"))
    state = work / "state"
    state.mkdir(mode=0o700)
    log = work / "server.log"
    evidence = {"synthetic_only": True, "e2ee": False,
                "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    process = output = None
    address = "127.0.0.1:0"
    url = None

    def start():
        nonlocal process, output, address, url
        output = log.open("ab")
        offset = log.stat().st_size
        process = subprocess.Popen([str(binary), "--synthetic-only", "--state", str(state),
                                    "--listen", address], stdout=subprocess.DEVNULL, stderr=output)
        until = time.monotonic() + 10
        while time.monotonic() < until:
            if process.poll() is not None:
                raise RuntimeError("prototype exited before listening")
            match = re.search(r"listening (127\.0\.0\.1:\d+)", log.read_bytes()[offset:].decode())
            if match:
                address = match[1]
                url = "http://" + address
                return
            time.sleep(0.02)
        raise RuntimeError("prototype start timeout")

    def request(method, path, data=None):
        req = urllib.request.Request(url + path, method=method,
                                     headers={"Authorization": "Bearer synthetic-alice", "Content-Type": "application/json"},
                                     data=json.dumps(data).encode() if data is not None else None)
        with urllib.request.urlopen(req, timeout=5) as response:
            return json.load(response)

    try:
        start()
        with sync_playwright() as p:
            browser = p.chromium.launch()
            expect.set_options(timeout=20000)
            ac = browser.new_context(viewport={"width": 1180, "height": 900})
            bc = browser.new_context(viewport={"width": 1100, "height": 850})
            a, b = ac.new_page(), bc.new_page()
            errors = []
            a.on("pageerror", lambda e: errors.append(str(e)))
            b.on("pageerror", lambda e: errors.append(str(e)))
            a_events = []
            a.on("request", lambda r: a_events.append(urlparse(r.url).query) if "/events?" in r.url else None)
            b_events = []
            b.on("request", lambda r: b_events.append(urlparse(r.url).query) if "/events?" in r.url else None)
            a.goto(url)
            a.locator("summary").click()
            a.locator("#room-id").fill("family")
            a.locator("#create-form button").click()
            expect(a.locator("#room-title")).to_have_text("family")
            b.goto(url)
            b.locator("#actor").select_option("bob")
            expect(b.locator("#room-title")).to_have_text("family")
            a.locator("#message").fill("합성 대화: 안녕하세요")
            a.locator("#send").click()
            expect(b.locator(".body")).to_have_text(["합성 대화: 안녕하세요"])
            hostile = '<img src=x onerror="window.injection=true"> 시험 텍스트'
            b.locator("#message").fill(hostile)
            b.locator("#send").click()
            expect(a.locator(".body")).to_have_count(2)
            assert a.locator(".body img").count() == 0
            assert a.evaluate("window.injection === undefined")
            assert a.locator(".body").nth(1).inner_text() == hostile
            evidence["two_client_send_and_text_rendering"] = True

            # Kill the real server. Hold Bob's new stream requests while a message
            # arrives after restart, then verify resumption from his applied seq.
            b.route("**/events?*", lambda route: route.abort())
            process.kill()
            process.wait(timeout=5)
            output.close()
            expect(b.locator("#connection")).to_contain_text("연결")
            start()
            request("POST", "/v1/rooms/family/messages",
                    {"client_id": "offline", "payload": base64.b64encode("끊긴 동안의 합성 대화".encode()).decode()})
            b.unroute("**/events?*")
            expect(b.locator(".body")).to_have_count(3)
            assert "after=2" in b_events, b_events
            assert len(set(b.locator("#messages li").evaluate_all("es=>es.map(e=>e.dataset.seq)"))) == 3
            evidence["server_restart_and_cursor_reconnect"] = True

            # Commit a POST, discard its response and suppress the sender's SSE.
            # The same tab must retain the immutable pending ID across reload.
            a.route("**/events?*", lambda route: route.abort())
            a.locator("#reconnect").click()
            sent_ids = []

            def lost_response(route):
                sent_ids.append(json.loads(route.request.post_data)["client_id"])
                response = route.fetch()
                assert response.status == 201
                route.abort()

            a.route("**/messages", lost_response)
            a.locator("#message").fill("응답 유실 합성 메시지")
            a.locator("#send").click()
            expect(a.locator("#retry")).to_be_visible()
            expect(a.locator("#send-status")).to_contain_text("확인하지 못했습니다")
            assert len(sent_ids) == 1
            a.reload()
            expect(a.locator("#retry")).to_be_visible()
            stored = a.evaluate("JSON.parse(sessionStorage.getItem('family-synthetic-pending-v1:alice:family'))")
            assert stored["client_id"] == sent_ids[0]
            a.unroute("**/messages", lost_response)
            with a.expect_request(lambda r: r.method == "POST" and r.url.endswith("/messages")) as retry:
                a.locator("#retry").click()
            assert json.loads(retry.value.post_data)["client_id"] == sent_ids[0]
            expect(a.locator("#retry")).to_be_hidden()
            history = request("GET", "/v1/rooms/family/messages")
            assert len([m for m in history if m["client_id"] == sent_ids[0]]) == 1
            a.unroute("**/events?*")
            expect(a.locator(".body")).to_have_count(4)
            evidence["lost_response_reload_same_id_retry_exactly_one_stored_message"] = True
            a.screenshot(path=str(work / "desktop.png"), full_page=True)
            a.set_viewport_size({"width": 390, "height": 844})
            assert a.evaluate("document.documentElement.scrollWidth <= innerWidth")
            a.screenshot(path=str(work / "mobile.png"), full_page=True)
            evidence["mobile_layout_no_horizontal_overflow"] = True

            # A live TCP connection can stop delivering without closing. Pause
            # only our disposable server: Bob stalls in the body; Alice opens a
            # new connection and stalls before headers. Both must retry on their
            # own within the 25s watchdog, then recover after SIGCONT.
            expect(b.locator(".body")).to_have_count(4)
            expect(b.locator("#connection")).to_have_text("연결됨")
            process.send_signal(signal.SIGSTOP)
            before_a, before_b = len(a_events), len(b_events)
            a.locator("#reconnect").click()
            until = time.monotonic() + 35
            while time.monotonic() < until and (len(a_events) < before_a + 2 or len(b_events) < before_b + 1):
                a.wait_for_timeout(100)
            assert len(a_events) >= before_a + 2, "header stall never retried"
            assert len(b_events) >= before_b + 1, "body stall never retried"
            process.send_signal(signal.SIGCONT)
            expect(a.locator(".body")).to_have_count(4)
            expect(b.locator("#connection")).to_have_text("연결됨")
            evidence["open_connection_header_and_body_stall_recovery"] = True

            # Charlie sees no rooms. Removing Bob clears his active conversation
            # and prevents further writes and room discovery.
            b.locator("#actor").select_option("charlie")
            expect(b.locator("#rooms button")).to_have_count(0)
            expect(b.locator("#messages li")).to_have_count(0)
            b.locator("#actor").select_option("bob")
            expect(b.locator(".body")).to_have_count(4)
            a.locator("#member-actor").select_option("bob")
            a.locator("#remove-member").click()
            expect(b.locator("#connection")).to_have_text("접근 권한이 없습니다.")
            expect(b.locator("#messages li")).to_have_count(0)
            expect(b.locator("#send")).to_be_disabled()
            b.locator("#refresh").click()
            expect(b.locator("#rooms button")).to_have_count(0)
            evidence["actor_switch_and_live_membership_revocation"] = True
            assert not errors, errors
            evidence["page_errors"] = 0
            evidence["ok"] = True
            browser.close()
    finally:
        if process is not None and process.poll() is None:
            process.send_signal(signal.SIGCONT)
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
