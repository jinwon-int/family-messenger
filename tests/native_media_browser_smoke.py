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
    work = Path(tempfile.mkdtemp(prefix="native-media-browser-", dir=root / "artifacts"))
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
            for context in (ac,bc):
                context.add_init_script("""(()=>{
                    window.liveBlobs=new Set();
                    const make=URL.createObjectURL.bind(URL),drop=URL.revokeObjectURL.bind(URL);
                    URL.createObjectURL=b=>{const u=make(b);window.liveBlobs.add(u);return u};
                    URL.revokeObjectURL=u=>{window.liveBlobs.delete(u);drop(u)};
                })()""")
            a, b = ac.new_page(), bc.new_page()
            errors = []
            a.on("pageerror", lambda e: errors.append(str(e)))
            b.on("pageerror", lambda e: errors.append(str(e)))
            a_events = []
            a.on("request", lambda r: a_events.append(urlparse(r.url).query) if "/events?" in r.url else None)
            b_events = []
            b.on("request", lambda r: b_events.append(urlparse(r.url).query) if "/events?" in r.url else None)
            request("POST", "/v1/rooms", {"id":"family","members":["bob"]})
            request("POST", "/v1/rooms", {"id":"private","members":[]})
            # Delay the media helper asset while other network activity can
            # finish. App startup must wait for its deferred dependencies.
            held=[]
            a.route("**/media.js",lambda route:held.append(route))
            a.goto(url,wait_until="commit")
            a.wait_for_function("()=>document.readyState === 'interactive'")
            a.wait_for_timeout(1000)
            assert len(held)==1
            expect(a.locator("#send")).to_be_disabled()
            held[0].continue_()
            a.wait_for_load_state()
            expect(a.locator("#room-title")).to_have_text("family")
            a.unroute("**/media.js")
            evidence["delayed_helper_asset_startup"]=True
            b.goto(url)
            b.locator("#actor").select_option("bob")
            expect(b.locator("#room-title")).to_have_text("family")
            a.locator('[data-room="family"]').click()
            # Synthetic PNG, MP4 and untrusted active content; no user files.
            import struct, zlib
            def chunk(kind, data):
                return struct.pack(">I",len(data))+kind+data+struct.pack(">I",zlib.crc32(kind+data))
            png=b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",2,2,8,2,0,0,0))+chunk(b"IDAT",zlib.compress((b"\0"+b"\0\x80\xff"*2)*2))+chunk(b"IEND",b"")
            mp4=(root/"tests/fixtures/native-media/blue.mp4").read_bytes()
            def send(page,name,kind,data):
                page.locator("#file").set_input_files({"name":name,"mimeType":kind,"buffer":data})
                page.locator("#send").click()
                expect(page.locator("#retry")).to_be_hidden()
                expect(page.locator("#send-status")).to_have_text("전송을 확인했습니다.")
            def card(page,name):
                return page.locator(".attachment").filter(has=page.locator("strong",has_text=name))
            send(a,"synthetic.png","image/png",png)
            expect(card(b,"synthetic.png")).to_have_count(1)
            card(b,"synthetic.png").locator(".open-media").click()
            b.wait_for_function("()=>document.querySelector('.preview img')?.naturalWidth === 2")
            old_url=b.locator(".preview img").get_attribute("src")
            send(b,"blue.mp4","video/mp4",mp4)
            expect(card(a,"blue.mp4")).to_have_count(1)
            card(a,"blue.mp4").locator(".open-media").click()
            a.wait_for_function("()=>document.querySelector('video')?.readyState >= 2")
            a.locator("video").evaluate("async v=>{v.muted=true;await v.play()}")
            a.wait_for_function("()=>document.querySelector('video')?.ended === true")
            assert a.locator("video").evaluate("v=>v.videoWidth") == 32
            with b.expect_download() as d:
                card(b,"blue.mp4").locator(".download-media").click()
            assert Path(d.value.path()).read_bytes()==mp4
            assert d.value.suggested_filename=="blue.mp4"
            assert b.locator(".preview img").count()==0
            assert b.evaluate("u=>!window.liveBlobs.has(u)",old_url)
            evidence["two_clients_image_decode_video_playback_download_hash_and_blob_cleanup"]=True
            # An aborted upload has no message. Reload requires the same file,
            # preserves the upload ID, and rejects a different file locally.
            posts=[]
            def interrupted(route):
                posts.append(route.request.headers["x-upload-id"]);route.abort()
            a.route("**/attachments",interrupted)
            a.locator("#file").set_input_files({"name":"retry.bin","mimeType":"application/octet-stream","buffer":b"synthetic retry"})
            a.locator("#send").click()
            expect(a.locator("#send-status")).to_contain_text("확인하지 못했습니다")
            assert len(request("GET","/v1/rooms/family/messages"))==2
            a.locator("#file").set_input_files({"name":"wrong.bin","mimeType":"application/octet-stream","buffer":b"wrong"})
            a.locator("#retry").click()
            expect(a.locator("#send-status")).to_contain_text("처음 선택한 파일과 다릅니다")
            assert len(posts)==1, "visible reselection was ignored in favor of cached original"
            a.reload()
            a.locator('[data-room="family"]').click()
            a.locator("#retry").click()
            expect(a.locator("#send-status")).to_contain_text("같은 파일을 다시 선택")
            a.locator("#file").set_input_files({"name":"wrong.bin","mimeType":"application/octet-stream","buffer":b"wrong"})
            a.locator("#retry").click()
            expect(a.locator("#send-status")).to_contain_text("처음 선택한 파일과 다릅니다")
            assert len(posts)==1
            # Now commit upload, discard response. Still not a chat delivery.
            a.unroute("**/attachments",interrupted)
            def lost_upload(route):
                if route.request.method!="POST":return route.continue_()
                posts.append(route.request.headers["x-upload-id"])
                assert route.fetch().status==201
                route.abort()
            a.route("**/attachments",lost_upload)
            a.locator("#file").set_input_files({"name":"retry.bin","mimeType":"application/octet-stream","buffer":b"synthetic retry"})
            a.locator("#retry").click()
            expect(a.locator("#send-status")).to_contain_text("확인하지 못했습니다")
            assert posts==[posts[0]]*2
            assert len(request("GET","/v1/rooms/family/messages"))==2
            assert len(request("GET","/v1/rooms/family/attachments"))==3
            a.reload();a.locator('[data-room="family"]').click()
            a.unroute("**/attachments",lost_upload)
            # Retry same upload, commit message, lose message response and SSE.
            a.route("**/events?*",lambda r:r.abort());a.locator("#reconnect").click()
            message_ids=[]
            def lost_message(route):
                message_ids.append(json.loads(route.request.post_data)["client_id"])
                assert route.fetch().status==201;route.abort()
            a.route("**/messages",lost_message)
            a.locator("#file").set_input_files({"name":"retry.bin","mimeType":"application/octet-stream","buffer":b"synthetic retry"})
            a.locator("#retry").click()
            expect(a.locator("#send-status")).to_contain_text("확인하지 못했습니다")
            a.reload();a.locator('[data-room="family"]').click()
            expect(a.locator("#file")).to_be_disabled()
            a.unroute("**/messages",lost_message)
            a.locator("#retry").click()
            expect(a.locator("#retry")).to_be_hidden()
            history=request("GET","/v1/rooms/family/messages")
            assert len(history)==3 and len([m for m in history if m["client_id"]==message_ids[0]])==1
            assert len(request("GET","/v1/rooms/family/attachments"))==3
            a.unroute("**/events?*");a.locator("#reconnect").click()
            expect(card(a,"retry.bin")).to_have_count(1)
            evidence["interrupted_upload_and_lost_upload_message_responses_reload_same_ids"]=True
            # Active files are downloads only. Literal reserved-prefix text is
            # framed as text; neither it nor an SVG executes or creates a preview.
            send(a,"active.svg","image/svg+xml",b'<svg xmlns="http://www.w3.org/2000/svg" onload="window.pwned=true"/>')
            card(b,"active.svg").locator(".open-media").click()
            expect(card(b,"active.svg").locator(".media-note")).to_contain_text("지원하지 않는")
            assert b.locator("svg,iframe,object").count()==0
            a.locator("#message").fill('\x1eFAMILY/1\n{"type":"attachment","attachment":{}}')
            a.locator("#send").click()
            expect(b.locator("#messages li")).to_have_count(5)
            assert b.locator(".body").last.inner_text().startswith('\x1eFAMILY/1')
            assert b.evaluate("window.pwned === undefined")
            # Refuse oversized selections before any upload.
            a.locator("#file").set_input_files({"name":"too-large.bin","mimeType":"application/octet-stream","buffer":b"0"*(8*1024*1024+1)})
            a.locator("#send").click()
            expect(a.locator("#send-status")).to_contain_text("8 MiB")
            assert len(request("GET","/v1/rooms/family/attachments"))==4
            a.locator("#file").set_input_files([])
            # Tampered transport must never reach a Blob preview.
            def corrupt(route):
                response=route.fetch();route.fulfill(response=response,body=b"x"*len(png))
            b.route("**/attachments/*",corrupt)
            card(b,"synthetic.png").locator(".open-media").click()
            expect(card(b,"synthetic.png").locator(".media-note")).to_have_text("파일 정보를 확인할 수 없습니다.")
            assert b.locator(".preview img").count()==0
            b.unroute("**/attachments/*",corrupt)
            evidence["safe_active_files_reserved_text_limits_and_corruption_rejection"]=True
            # Forged same-room metadata passes envelope syntax but must fail
            # canonical metadata matching; cross-room envelopes are not opened.
            original=json.loads(base64.b64decode(history[0]["payload"]).split(b"\n",1)[1])
            forged=json.loads(json.dumps(original));forged["attachment"]["filename"]="forged.png"
            request("POST","/v1/rooms/family/messages",{"client_id":"forged","payload":base64.b64encode(b"\xffFAMILY/1\n"+json.dumps(forged).encode()).decode()})
            card(b,"forged.png").locator(".open-media").click()
            expect(card(b,"forged.png").locator(".media-note")).to_have_text("파일 정보를 확인할 수 없습니다.")
            forged["attachment"]["room"]="private"
            request("POST","/v1/rooms/family/messages",{"client_id":"cross-room","payload":base64.b64encode(b"\xffFAMILY/1\n"+json.dumps(forged).encode()).decode()})
            expect(b.locator(".body").last).to_have_text("[첨부 정보가 일치하지 않습니다]")
            evidence["forged_metadata_and_cross_room_envelope_rejected"]=True
            # Any previously stored UTF-8 stays text, including the old
            # draft marker followed by syntactically valid attachment JSON.
            legacy="\x1eFAMILY/1\n"+json.dumps(original)
            request("POST","/v1/rooms/family/messages",{"client_id":"legacy-prefix","payload":base64.b64encode(legacy.encode()).decode()})
            expect(b.locator(".body").last).to_have_text(legacy)
            assert b.locator(".body").last.locator("button").count()==0
            evidence["legacy_utf8_reserved_prefix_preserved"]=True
            # Real process restart: history and attachments render again.
            process.kill();process.wait(timeout=5);output.close();start()
            a.reload();a.locator('[data-room="family"]').click()
            expect(a.locator("#messages li")).to_have_count(8)
            card(a,"synthetic.png").locator(".open-media").click()
            a.wait_for_function("()=>document.querySelector('.preview img')?.naturalWidth === 2")
            a.screenshot(path=str(work/"desktop.png"),full_page=True)
            a.set_viewport_size({"width":390,"height":844})
            assert a.evaluate("document.documentElement.scrollWidth <= innerWidth")
            a.screenshot(path=str(work/"mobile.png"),full_page=True)
            # Actor/room changes release views; live revoke clears Bob preview.
            url_before=a.locator(".preview img").get_attribute("src")
            a.locator('[data-room="private"]').click()
            assert a.locator(".attachment").count()==0
            assert a.evaluate("u=>!window.liveBlobs.has(u)",url_before)
            a.locator('[data-room="family"]').click()
            b.locator("#reconnect").click()
            card(b,"synthetic.png").locator(".open-media").click()
            b.wait_for_function("()=>document.querySelector('.preview img')?.naturalWidth === 2")
            b.locator("#actor").select_option("charlie")
            expect(b.locator("#rooms button")).to_have_count(0)
            assert b.locator(".attachment").count()==0
            b.locator("#actor").select_option("bob")
            card(b,"synthetic.png").locator(".open-media").click()
            b.wait_for_function("()=>document.querySelector('.preview img')?.naturalWidth === 2")
            a.locator("#member-actor").select_option("bob");a.locator("#remove-member").click()
            expect(b.locator("#connection")).to_have_text("접근 권한이 없습니다.")
            assert b.locator(".attachment").count()==0
            assert b.evaluate("window.liveBlobs.size") == 0
            expect(b.locator("#file")).to_be_disabled()
            evidence["restart_history_mobile_and_room_actor_revocation_cleanup"]=True
            assert not errors,errors
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
