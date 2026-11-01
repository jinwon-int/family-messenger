#!/usr/bin/env python3
"""hande web smoke (#431 stage 2): the relay serves archive/native-mls/web/hande at the
root of its own host (-hande-host / -hande-dir) and two Chromium contexts drive the
product screens only — zero Python-side relay calls:

  name chosen on first run (actor → device id) → owner creates the room → mom
  requests to join (key package) → owner invites mom from the invite sheet → mom
  joins from the Welcome → messages both ways (sender labels) → owner's relay
  cursor acked → mom reloads the page and the sealed history (#370) comes back.
  … and at the end the typing line (#562/#635, #639 A2): mom composes → owner's room header
  shows 「타닥타닥…」 (1:1) / 「mom이 타닥타닥…」 (three people) → gone once mom clears or sends.

Access mode is disabled (loopback, no JWT), membership enforcement off; the hande
host is a Host header the page never sees. Synthetic only (disposable keys).

  python3 archive/native-mls/tests/native_hande_web_smoke.py \\
      --bundle artifacts/mls-pkg --relay-binary artifacts/native-mls-relay

Receipt: archive/artifacts/native-hande-web-*/verification.json
"""
import argparse
import json
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
ARCHIVE = HERE.parents[1]
HANDE = ARCHIVE / 'native-mls' / 'web' / 'hande'
HOST = 'hande.localhost'   # *.localhost is loopback and a secure context in Chromium (crypto.subtle, Web Locks)
ROOM = 'family'               # DEFAULT_ROOM of app.js (no config.json)


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class Relay:
    def __init__(self, binary, port, data, hande_dir, log):
        self.argv = [str(binary.resolve()), '-addr', f'127.0.0.1:{port}', '-data-dir', str(data),
                     '-access-mode', 'disabled', '-hande-host', HOST, '-hande-dir', str(hande_dir)]
        self.port = port
        self.base = f'http://127.0.0.1:{port}'
        self.log = log
        self.proc = None

    def start(self):
        self.proc = subprocess.Popen(self.argv, stdout=open(self.log, 'ab'), stderr=subprocess.STDOUT)
        for _ in range(100):
            try:
                with urllib.request.urlopen(self.base + '/v2/health', timeout=2) as r:
                    if r.status == 200:
                        return
            except OSError:
                time.sleep(0.1)
        raise RuntimeError('relay did not start: ' + self.log.read_text()[-800:])

    def stop(self):
        if self.proc is None:
            return
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)
        self.proc = None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bundle', required=True, type=Path)
    ap.add_argument('--relay-binary', required=True, type=Path)
    ap.add_argument('--keep', action='store_true')
    ap.add_argument('--screenshot', type=Path, help='save owner/mom room screenshots (PNG) under this directory')
    args = ap.parse_args()

    work = Path(tempfile.mkdtemp(prefix='hande-web-'))
    hande_dir = work / 'hande'
    subprocess.run([str(HANDE / 'build.sh'), str(args.bundle), str(hande_dir)], check=True, stdout=subprocess.DEVNULL)
    port = free_port()
    data = work / 'data'
    data.mkdir(mode=0o700)
    relay = Relay(args.relay_binary, port, data, hande_dir, work / 'relay.log')
    receipt = {'synthetic_only': True, 'real_device_evidence': False, 'checks': {}, 'room': ROOM}
    out_dir = ARCHIVE / 'artifacts' / f'native-hande-web-{secrets.token_hex(4)}'
    try:
        relay.start()
        # Host routing: the hande host gets index.html at "/", any other host gets the API 404.
        req = urllib.request.Request(relay.base + '/', headers={'Host': HOST})
        with urllib.request.urlopen(req, timeout=5) as r:
            html = r.read().decode()
            assert '<title>한데' in html, html[:200]
            assert "'wasm-unsafe-eval'" in r.headers.get('Content-Security-Policy', ''), r.headers
            assert r.headers.get('Cache-Control') == 'no-store', r.headers
        try:
            urllib.request.urlopen(relay.base + '/', timeout=5)
            raise AssertionError('relay host must not serve the hande index')
        except urllib.error.HTTPError as e:
            assert e.code == 404, e.code
        receipt['checks']['hande_root_served_by_host'] = True

        pages = []
        with sync_playwright() as p:
            # The page's origin is http://hande.localhost:<port> — loopback by name, so the
            # same-origin /v2 fetches carry the hande Host and the context is secure.
            base = f'http://{HOST}:{port}'
            browser = p.chromium.launch()
            receipt['browser'] = browser.version

            class Dev:
                def __init__(self, actor):
                    self.actor = actor
                    self.ctx = browser.new_context(viewport={'width': 1280, 'height': 900})
                    self.page = self.ctx.new_page()
                    self.console = []
                    self.page.on('console', lambda m: self.console.append(m.text))
                    pages.append(self)
                    self.page.goto(base + '/', timeout=20000)
                    self.page.fill('[data-testid="actor-input"]', actor)
                    self.page.click('[data-testid="actor-submit"]')
                    self.wait_shell()

                def open_menu_item(self, testid):
                    # 참여 요청·방 만들기는 ⚙ 설정 메뉴 안에 있다(2026-10-27): 메뉴를 열고 항목을 누른다.
                    self.page.click('[data-testid="open-menu"]')
                    self.page.click(f'[data-testid="{testid}"]')

                def wait_shell(self, timeout=180000):
                    self.page.wait_for_selector('[data-testid="room-list"]', timeout=timeout)

                def reload(self):
                    self.page.reload(timeout=20000)
                    self.wait_shell()

                def device_id(self):
                    return self.page.text_content('[data-testid="device-label"]').strip()

                def open_room(self):
                    self.page.click('[data-testid="room-item"]')
                    self.page.wait_for_selector('[data-testid="timeline"]', timeout=20000)

                def status(self):
                    return self.page.text_content('[data-testid="status"]') or ''

                def wait_status(self, text, timeout=60000):
                    self.page.wait_for_function("t => (document.querySelector('[data-testid=\"status\"]')?.textContent || '').includes(t)",
                                                arg=text, timeout=timeout)

                def wait_room(self, room, members, timeout=90000):
                    self.page.wait_for_function("([r, n]) => { const el = document.querySelector(`[data-testid=\"room-item\"][data-room-id=\"${r}\"]`);"
                                                " return !!el && el.dataset.state === 'joined' && Number(el.dataset.members || 0) >= n; }",
                                                arg=[room, members], timeout=timeout)

                def open_room_id(self, room):
                    self.page.click(f'[data-testid="room-item"][data-room-id="{room}"]')
                    self.page.wait_for_function("r => document.querySelector('.room-screen')?.dataset.roomId === r || document.querySelector(`[data-testid=\"room-item\"][data-room-id=\"${r}\"][aria-current=\"true\"]`) !== null",
                                                arg=room, timeout=20000)
                    self.page.wait_for_selector('[data-testid="timeline"]', timeout=20000)

                def wait_open(self, room, timeout=10000):
                    self.page.wait_for_function("r => document.querySelector('.room-screen')?.dataset.roomId === r",
                                                arg=room, timeout=timeout)

                def has_invite_card(self, room):
                    return self.page.query_selector(f'[data-testid="lobby-invite"][data-room-id="{room}"]') is not None

                def wait_members(self, n, timeout=90000):
                    self.page.wait_for_function("n => document.querySelectorAll('[data-testid=\"room-item\"][data-state=\"joined\"]').length >= 1 && "
                                                "Number(document.querySelector('[data-testid=\"room-item\"]')?.dataset.members || 0) >= n",
                                                arg=n, timeout=timeout)

                def bubbles(self):
                    return self.page.eval_on_selector_all('[data-testid="bubble"]', 'els => els.map(e => e.textContent)')

                def wait_bubble(self, text, timeout=60000):
                    self.page.wait_for_function("t => [...document.querySelectorAll('[data-testid=\"bubble\"]')].some(e => e.textContent.includes(t))",
                                                arg=text, timeout=timeout)

                def send(self, text):
                    self.page.fill('[data-testid="composer"]', text)
                    self.page.press('[data-testid="composer"]', 'Enter')
                    self.wait_bubble(text)

            def dump():
                for d in pages:
                    try:
                        print(f'--- {d.actor} console:\n' + '\n'.join(d.console[-40:]), file=sys.stderr)
                        print(f'--- {d.actor} status: ' + d.status()[:300], file=sys.stderr)
                        print(f'--- {d.actor} body: ' + (d.page.text_content('body') or '')[:600], file=sys.stderr)
                    except Exception as e:  # noqa: BLE001
                        print(f'--- {d.actor}: unavailable ({e})', file=sys.stderr)
            try:
                run_flow(Dev, receipt, args.screenshot, relay.base)
            except Exception:
                dump()
                raise
            browser.close()
        receipt['relay_log_tail'] = (work / 'relay.log').read_text()[-1200:]
        out_dir.mkdir(parents=True, mode=0o700)
        (out_dir / 'verification.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=1))
        print(json.dumps(receipt['checks'], ensure_ascii=False))
        print(out_dir / 'verification.json')
    except Exception:
        print('--- relay log:\n' + (work / 'relay.log').read_text()[-1500:], file=sys.stderr)
        raise
    finally:
        relay.stop()
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)


def lobby_live(relay_base, device):
    with urllib.request.urlopen(f'{relay_base}/v2/lobby/status?device={device}', timeout=5) as r:
        return json.load(r).get('live', 0)


def wait_lobby_keys(relay_base, device, timeout_s=60):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if lobby_live(relay_base, device) >= 1:
            return True
        time.sleep(1)
    return False


def run_flow(Dev, receipt, screenshot=None, relay_base=None):
    owner, mom = Dev('owner'), Dev('mom')
    owner_id, mom_id = owner.device_id(), mom.device_id()
    assert owner_id.startswith('owner-web-') and mom_id.startswith('mom-web-'), (owner_id, mom_id)
    receipt['checks']['first_run_names_make_device_ids'] = True

    # owner: + → 방 만들기 (same room id as the default) → the room item becomes joined
    owner.open_menu_item('menu-create')
    owner.page.fill('[data-testid="create-room"]', ROOM)
    owner.page.click('[data-testid="create-submit"]')
    owner.wait_members(1)
    receipt['checks']['owner_created_room'] = True

    # mom: + → 참여 요청 (publishes a key package to the room)
    mom.open_menu_item('menu-join')
    mom.page.fill('[data-testid="join-room"]', ROOM)
    mom.page.click('[data-testid="join-submit"]')
    mom.wait_status('참여를 요청했습니다')
    receipt['checks']['mom_requested_join'] = True

    # owner: room → 초대 sheet → mom's device id → commit 201 → own echo → Welcome
    owner.open_room()
    owner.page.click('[data-testid="open-invite"]')
    owner.page.fill('[data-testid="invite-device"]', mom_id)
    owner.page.click('[data-testid="invite-submit"]')
    owner.wait_members(2)
    mom.wait_members(2)
    receipt['checks']['invite_commit_echo_welcome_join'] = True

    # messages both ways, sender labels, Korean text
    mom.open_room()
    owner.send('안녕, 한데 웹에서 보냄')
    mom.wait_bubble('안녕, 한데 웹에서 보냄')
    mom.send('잘 받았어요 🔥')
    owner.wait_bubble('잘 받았어요 🔥')
    receipt['checks']['messages_both_ways'] = True
    if screenshot:
        screenshot.mkdir(parents=True, exist_ok=True)
        owner.page.screenshot(path=str(screenshot / 'owner-room.png'))
        mom.page.screenshot(path=str(screenshot / 'mom-room.png'))

    # reload: sealed history (#370) restores both rows for mom without re-reading the relay
    mom.reload()
    mom.open_room()
    mom.wait_bubble('안녕, 한데 웹에서 보냄', timeout=120000)
    mom.wait_bubble('잘 받았어요 🔥')
    assert mom.device_id() == mom_id, (mom.device_id(), mom_id)
    receipt['checks']['reload_restores_sealed_history_same_device'] = True

    # ---- stage 4: a second room through the LOBBY (#380) — owner creates fam2 and invites mom,
    # who never requested fam2: the invite consumes mom's lobby key; mom (family actor) gets an
    # invite card and accepts with one click; the room is a lobby clone that joins the Welcome.
    assert wait_lobby_keys(relay_base, mom_id), 'mom published lobby keys after enrollment'
    assert wait_lobby_keys(relay_base, owner_id), 'owner published lobby keys'
    receipt['checks']['lobby_keys_replenished_after_enrollment'] = True
    owner.open_menu_item('menu-create')
    owner.page.fill('[data-testid="create-room"]', 'fam2')
    owner.page.click('[data-testid="create-submit"]')
    owner.wait_room('fam2', 1)
    owner.open_room_id('fam2')
    owner.page.click('[data-testid="open-invite"]')
    owner.page.fill('[data-testid="invite-device"]', mom_id)
    owner.page.click('[data-testid="invite-submit"]')
    owner.wait_room('fam2', 2)
    receipt['checks']['invite_falls_back_to_lobby_key_package'] = True
    mom.page.wait_for_selector('[data-testid="lobby-invite"][data-room-id="fam2"]', timeout=60000)
    assert not mom.has_invite_card('family'), 'no card for a joined room'
    mom.page.click('[data-testid="lobby-invite"][data-room-id="fam2"] [data-testid="invite-accept"]')
    mom.wait_room('fam2', 2)
    receipt['checks']['family_device_accepts_lobby_invite_card_and_joins'] = True
    mom.open_room_id('fam2')
    owner.send('fam2에서 안녕')
    mom.wait_bubble('fam2에서 안녕')
    mom.send('fam2 잘 돼요')
    owner.wait_bubble('fam2 잘 돼요')
    receipt['checks']['messages_both_ways_in_lobby_room'] = True

    # ---- owner actor auto-joins: mom creates fam3 and invites owner via the lobby — no card, joined on the next tick
    mom.open_menu_item('menu-create')
    mom.page.fill('[data-testid="create-room"]', 'fam3')
    mom.page.click('[data-testid="create-submit"]')
    mom.wait_room('fam3', 1)
    mom.open_room_id('fam3')
    mom.page.click('[data-testid="open-invite"]')
    mom.page.fill('[data-testid="invite-device"]', owner_id)
    mom.page.click('[data-testid="invite-submit"]')
    mom.wait_room('fam3', 2)
    owner.wait_room('fam3', 2)
    assert not owner.has_invite_card('fam3'), 'owner joins automatically, no card'
    receipt['checks']['owner_actor_auto_joins_lobby_welcome'] = True
    owner.open_room_id('fam3')
    mom.send('fam3 자동 참여 확인')
    owner.wait_bubble('fam3 자동 참여 확인')
    receipt['checks']['messages_in_auto_joined_room'] = True

    # ---- rooms stay apart: the first room's timeline has none of the other rooms' lines
    owner.open_room_id(ROOM)
    bubbles = owner.bubbles()
    assert any('안녕, 한데 웹에서 보냄' in b for b in bubbles), bubbles
    assert not any('fam2' in b or 'fam3' in b for b in bubbles), bubbles
    receipt['checks']['rooms_isolated'] = True

    # ---- keyboard shortcuts (#478, 패밀리챗 동등): 1280px 은 2분할 — PageDown/PageUp 은 목록 순서대로
    # 옆 방을 바로 열고 작성창에 커서, 작성창 Esc 는 대화 내용으로, 대화 내용 Enter 는 작성창으로, Home 은 목록으로.
    def owner_room():
        return owner.page.evaluate("() => document.querySelector('.room-screen')?.dataset.roomId ?? null")

    def owner_focus():
        return owner.page.evaluate(
            "() => document.activeElement?.dataset.testid ?? document.activeElement?.tagName ?? null")

    owner.page.focus('[data-testid="composer"]')
    owner.page.keyboard.press('PageDown')
    owner.wait_open('fam2')
    assert owner_focus() == 'composer', owner_focus()
    owner.page.keyboard.press('PageDown')
    owner.wait_open('fam3')
    owner.page.keyboard.press('PageUp')
    owner.wait_open('fam2')
    owner.page.keyboard.press('Escape')
    assert owner_focus() == 'timeline', owner_focus()
    owner.page.keyboard.press('Enter')
    assert owner_focus() == 'composer', owner_focus()
    owner.page.keyboard.press('Home')
    owner.page.wait_for_function(
        "() => document.querySelector('main.shell')?.dataset.view === 'list'"
        " && !document.querySelector('.room-screen')", timeout=10000)
    assert owner_room() is None
    receipt['checks']['keyboard_pageupdown_esc_enter_home'] = True

    # ---- room order editing (#480 A): ↕ → ▲ on the second row moves it first; the order survives a reload.
    def owner_room_ids():
        return owner.page.eval_on_selector_all('[data-testid="room-item"]', 'els => els.map(e => e.dataset.roomId)')

    before = owner_room_ids()
    assert len(before) == 3, before
    owner.page.click('[data-testid="order-toggle"]')
    owner.page.wait_for_selector('ul.rooms > li.reorderable', timeout=10000)
    owner.page.click(f'ul.rooms > li[data-key="{before[1]}"] .order-up')
    owner.page.wait_for_function("ids => document.querySelector('[data-testid=\"room-item\"]')?.dataset.roomId === ids[1]",
                                 arg=before, timeout=10000)
    owner.page.click('[data-testid="order-toggle"]')
    owner.page.wait_for_function("() => !document.querySelector('ul.rooms > li.reorderable')", timeout=10000)
    assert owner_room_ids() == [before[1], before[0], before[2]], owner_room_ids()
    owner.reload()
    owner.wait_room(ROOM, 2, timeout=120000)
    owner.page.wait_for_function("ids => document.querySelector('[data-testid=\"room-item\"]')?.dataset.roomId === ids[1]",
                                 arg=before, timeout=20000)
    receipt['checks']['room_order_edit_persists_on_this_device'] = True
    owner.open_room_id(ROOM)

    # ---- draft persistence (#480 B): a draft typed in fam3 survives the reload below
    mom.open_room_id('fam3')
    mom.page.fill('[data-testid="composer"]', '다 못 쓴 글')
    mom.page.wait_for_function("() => localStorage.getItem(`hande:draft:${document.querySelector('[data-testid=\"device-label\"]').textContent.trim()}:fam3`) === '다 못 쓴 글'",
                               timeout=10000)

    # ---- reload: identity + rooms reopen with one custody KDF; all three rooms still joined
    mom.reload()
    for room, n in ((ROOM, 2), ('fam2', 2), ('fam3', 2)):
        mom.wait_room(room, n, timeout=120000)
    assert mom.device_id() == mom_id
    receipt['checks']['reload_reopens_identity_and_all_rooms'] = True
    mom.open_room_id('fam3')
    assert mom.page.input_value('[data-testid="composer"]') == '다 못 쓴 글'
    mom.page.fill('[data-testid="composer"]', '')
    receipt['checks']['draft_survives_reload'] = True

    # ---- service worker (#480 D): registered as a module worker and active; /v2 is never intercepted
    owner.page.wait_for_function("() => navigator.serviceWorker.getRegistration().then(r => Boolean(r && r.active))", timeout=30000)
    receipt['checks']['service_worker_active'] = True

    # ---- self-heal (2026-10-19 field failure): the page's device id drifted from the identity
    # store (a rotate while the stores stayed) → init_multi refused → the app drops the
    # identity/lobby stores, restores the previous id and comes back with every room intact.
    mom.page.evaluate("() => { const v = JSON.parse(localStorage.getItem('hande:identity')); v.previous = v.device; v.device = v.actor + '-web-ffffff'; localStorage.setItem('hande:identity', JSON.stringify(v)); }")
    mom.reload()
    for room, n in ((ROOM, 2), ('fam2', 2), ('fam3', 2)):
        mom.wait_room(room, n, timeout=120000)
    assert mom.device_id() == mom_id, (mom.device_id(), mom_id)
    receipt['checks']['identity_store_mismatch_self_heals_to_previous_id'] = True

    # ---- room list keeps its scroll and focus across sync ticks (2026-10-26 field report, #502/#507).
    # The sync line ("동기화 HH:MM:SS") changes on every room poll. It used to be part of the list
    # pane's signature, so each sync swapped the whole pane — the list's scroll container: a
    # scrolled-down list jumped back to the top (#502 carries the offset over) and focus inside the
    # pane was dropped (#507 swaps only the sync line). A short window makes the owner's three rooms
    # overflow in the 1280px two-pane layout, where the list header is not sticky.
    owner.page.set_viewport_size({'width': 1280, 'height': 260})
    owner.page.wait_for_function(
        "() => { const p = document.querySelector('.pane-list'); return !!p && p.scrollHeight - p.clientHeight >= 60; }",
        timeout=10000)
    start = owner.page.evaluate("""() => {
        const pane = document.querySelector('.pane-list');
        // Focus first: focusing a header button scrolls the pane back up to it.
        pane.querySelector('[data-testid="open-menu"]').focus();
        pane.scrollTop = pane.scrollHeight;
        window.__handeListPane = pane;
        return {top: pane.scrollTop, sync: pane.querySelector('.sync-line')?.textContent ?? ''};
    }""")
    assert start['top'] >= 60, start
    seen = start['sync']
    for _ in range(2):   # two real sync-line changes
        handle = owner.page.wait_for_function(
            "prev => { const t = document.querySelector('.pane-list .sync-line')?.textContent ?? '';"
            " return t !== prev ? t : false; }", arg=seen, timeout=60000)
        seen = handle.json_value()
    after = owner.page.evaluate("""() => {
        const pane = document.querySelector('.pane-list');
        const active = document.activeElement;
        return {samePane: pane === window.__handeListPane, top: pane.scrollTop,
                focus: active?.dataset?.testid ?? active?.tagName ?? null,
                syncLines: pane.querySelectorAll('.sync-line').length};
    }""")
    receipt['room_list_sync_scroll'] = {'start': start, 'after': after, 'last_sync_line': seen}
    assert after['top'] == start['top'], ('list scroll moved across sync', start, after)
    assert after['samePane'] and after['focus'] == 'open-menu', ('list pane replaced or focus lost across sync', start, after)
    assert after['syncLines'] == 1, after
    receipt['checks']['room_list_keeps_scroll_and_focus_across_sync'] = True
    owner.page.set_viewport_size({'width': 1280, 'height': 900})

    # ---- typing indicator (#562 / #635, #639 A2): mom composes in the family room → owner's room
    # header shows the typing line (data-testid="typing", strings.chat.typing) → it goes away once
    # mom stops. Page side only: mom's composer → R.session.typing → POST /typing (TTL 6 s), owner's
    # 4 s room poll → GET /events `typing` → typingLabel. 1:1 (two people) drops the name by design
    # (strings.js typingNames), so the name is checked after dad joins as a third person.
    def typing_line(dev):
        return dev.page.evaluate("() => document.querySelector('[data-testid=\"typing\"]')?.textContent ?? null")

    def wait_typing_shown(dev, expect, timeout_s=30):
        """Keep mom typing (one key a second; the page re-posts every 3 s) until dev's header
        shows exactly `expect`. Returns the seconds it took."""
        composer = mom.page.locator('[data-testid="composer"]')
        started = time.monotonic()
        while True:
            composer.press_sequentially('.')
            try:
                dev.page.wait_for_function("t => document.querySelector('[data-testid=\"typing\"]')?.textContent === t",
                                           arg=expect, timeout=1000)
                return round(time.monotonic() - started, 2)
            except Exception:  # noqa: BLE001 — playwright TimeoutError: not yet, type on
                assert time.monotonic() - started < timeout_s, (
                    f'{dev.actor} never showed typing {expect!r} in {timeout_s}s; header line: {typing_line(dev)!r}')

    def wait_typing_gone(dev, timeout_s=15):
        started = time.monotonic()
        dev.page.wait_for_function("() => !document.querySelector('[data-testid=\"typing\"]')",
                                   timeout=timeout_s * 1000)
        return round(time.monotonic() - started, 2)

    owner.open_room_id(ROOM)
    mom.open_room_id(ROOM)
    assert typing_line(owner) is None and typing_line(mom) is None, (typing_line(owner), typing_line(mom))
    mom.page.fill('[data-testid="composer"]', '타자 치는 중')
    shown_1to1 = wait_typing_shown(owner, '타닥타닥…')
    assert typing_line(mom) is None, ('own typing must not show on mom\'s screen', typing_line(mom))
    mom.page.fill('[data-testid="composer"]', '')   # draft cleared, nothing sent → POST /typing {clear}
    gone_1to1 = wait_typing_gone(owner)
    assert not any('타자 치는 중' in b for b in owner.bubbles()), 'a draft is never sent'
    receipt['checks']['typing_shown_on_peer_screen_and_gone_after_draft_cleared_1to1'] = {
        'label': '타닥타닥…', 'shown_after_secs': shown_1to1, 'gone_after_clear_secs': gone_1to1}

    # Three people for the named line: owner founds fam4 and adds dad, then mom. This relay tracks
    # no membership (no -device-state), so an online member that merges someone else's add commit
    # refuses it by design (commit-policy.js outer roster check, #295 F1: relay [] vs MLS [...]).
    # So nobody but the committer may hold the room while a commit lands: dad only publishes his
    # key package and goes offline (his Welcome waits), mom asks to join after dad is in and
    # joins from her own Welcome. Owner's roster (and mom's) is then owner · dad · mom.
    room3 = 'fam4'
    owner.open_menu_item('menu-create')
    owner.page.fill('[data-testid="create-room"]', room3)
    owner.page.click('[data-testid="create-submit"]')
    owner.wait_room(room3, 1)
    dad = Dev('dad')
    dad_id = dad.device_id()
    dad.open_menu_item('menu-join')
    dad.page.fill('[data-testid="join-room"]', room3)
    dad.page.click('[data-testid="join-submit"]')
    dad.wait_status('참여를 요청했습니다')
    dad.ctx.close()   # offline from here on (dump() reports a closed page as unavailable)
    owner.open_room_id(room3)
    owner.page.click('[data-testid="open-invite"]')
    owner.page.fill('[data-testid="invite-device"]', dad_id)
    owner.page.click('[data-testid="invite-submit"]')
    owner.wait_room(room3, 2)
    mom.open_menu_item('menu-join')
    mom.page.fill('[data-testid="join-room"]', room3)
    mom.page.click('[data-testid="join-submit"]')
    mom.wait_status('참여를 요청했습니다')
    owner.page.click('[data-testid="open-invite"]')
    owner.page.fill('[data-testid="invite-device"]', mom_id)
    owner.page.click('[data-testid="invite-submit"]')
    owner.wait_room(room3, 3)
    mom.wait_room(room3, 3)
    owner.open_room_id(room3)
    mom.open_room_id(room3)
    # mom's display name = participantName('mom-web-…') = 'mom' (no Korean nickname → particle 이).
    label = 'mom이 타닥타닥…'
    mom.page.fill('[data-testid="composer"]', '셋이서 타자 치는 중')
    shown_group = wait_typing_shown(owner, label)
    mom.page.press('[data-testid="composer"]', 'Enter')   # sending ends it (clear + the relay drops it on store)
    mom.wait_bubble('셋이서 타자 치는 중')
    gone_group = wait_typing_gone(owner)
    owner.wait_bubble('셋이서 타자 치는 중')
    receipt['checks']['typing_names_sender_in_group_room_and_gone_after_send'] = {
        'label': label, 'shown_after_secs': shown_group, 'gone_after_send_secs': gone_group,
        'participants': 3}


if __name__ == '__main__':
    main()
