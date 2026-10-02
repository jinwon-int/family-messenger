// Human client for the v2 relay (#243 2-a). Same durable worker the smokes drive
// (durable-worker.js: IndexedDB + passphrase custody); the relay flow is the one
// native_v2_relay_smoke.py proves, moved into the browser:
//   publish key package → (someone) invite_with_commit → POST commit (members list
//   from members_after_pending) → own echo → merge_pending → POST targeted Welcome
//   → target joins from the Welcome → application messages at the room's epoch,
//   409 cas_mismatch → clear_pending / sync / retry. Reads never move the relay
//   cursor; an explicit ?ack= after everything up to seq is durably processed.
// Trust comes from the facade (AAD binding, pinned keys) and the relay (policy
// chain, JWT ↔ device subject); this page is plumbing and display only.
const $ = id => document.getElementById(id);
const utf8 = new TextEncoder(), decoder = new TextDecoder();
const ID = /^[A-Za-z0-9_-]{1,64}$/;        // relay identifier (device, room, client_id)
const ROOM = /^[a-z0-9-]{1,64}$/;          // worker room charset (subset of the relay's)
const DB = /^family-mls-synthetic-[a-z0-9-]{1,64}$/;
const b64 = bytes => {
  const view = new Uint8Array(bytes);
  let binary = '';
  for (let at = 0; at < view.length; at += 8192) binary += String.fromCharCode.apply(null, view.subarray(at, at + 8192));
  return btoa(binary);
};
const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
const hex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
const genId = () => Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
const log = (...parts) => { $('log').textContent += new Date().toLocaleTimeString() + ' ' + parts.join(' ') + '\n'; };
const fail = error => { log('실패:', String(error)); alert(String(error)); };
// Actor of a device id: the part before the first '-' (owner-pc → owner, bot-1 → bot).
// The relay checks members[].actor against the policy chain, so device ids in a
// pilot follow this rule; a wrong actor is a 400 commit_actor_mismatch, never a merge.
const actorOf = device => device.split('-')[0];

const S = {dev: null, room: null, db: null, started: false, joined: false, pending: false,
  expectedRoster: null, pendingWelcome: null, relaySeq: 0, epoch: 0, wcursor: 0, roster: [], timer: null, busy: false};
const stateKey = () => `relay-app:${S.room}:${S.dev}`;
function save() {
  localStorage.setItem(stateKey(), JSON.stringify({joined: S.joined, pending: S.pending, expectedRoster: S.expectedRoster,
    pendingWelcome: S.pendingWelcome, relaySeq: S.relaySeq, epoch: S.epoch, roster: S.roster}));
}
function load() {
  try { const v = JSON.parse(localStorage.getItem(stateKey()) || 'null'); if (v) Object.assign(S, v); } catch (_) { /* ignore */ }
}

// ---- worker ----
async function callWorker(method, argument) {
  const value = await window.call('device', method, argument);
  if (!value.ok) throw new Error(`${method} 거부`);
  return value.result;
}
async function op(method, bytes = [], sequence = 0) {
  const id = genId();
  const result = await callWorker('operation', {id, method, bytes: Array.from(bytes), sequence, fault: ''});
  S.wcursor = result.cursor;
  try { await callWorker('ack', {ids: [id]}); } catch (error) { log('ledger ack 실패:', error.message); }
  return result;
}
// Framed member list (u32 count, then u32 len ‖ identity ‖ 32-byte key).
function parseMembers(framed) {
  const bytes = new Uint8Array(framed), view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const count = view.getUint32(0, true);
  let at = 4; const out = [];
  for (let i = 0; i < count; i++) {
    const n = view.getUint32(at, true); at += 4;
    out.push(decoder.decode(bytes.subarray(at, at + n))); at += n + 32;
  }
  return out;
}
const membersWire = devices => devices.slice().sort().map(device => ({device, actor: actorOf(device)}));
// §3.6 binding (room ‖ client for encrypt, room for decrypt) is added by the durable
// worker from its own init — this page hands it raw plaintext / raw ciphertext.

// ---- relay ----
async function api(method, path, body) {
  const response = await fetch(path, {method, credentials: 'same-origin',
    headers: body === undefined ? {} : {'Content-Type': 'application/json'},
    body: body === undefined ? undefined : JSON.stringify(body)});
  let json = null;
  try { json = await response.json(); } catch (_) { json = null; }
  if (response.status === 401) throw new Error('401 — Cloudflare Access 로그인이 필요하다(페이지를 새로고침해 로그인)');
  return {status: response.status, body: json};
}
const roomPath = suffix => `/v2/rooms/${encodeURIComponent(S.room)}/${suffix}`;
function describe(status, body) { return `${status} ${body && body.error ? body.error : ''}`.trim(); }

async function postEvent(kind, bytes, {targets, members, epoch} = {}) {
  const payload = {device: S.dev, client_id: `${S.dev}-${genId()}`, kind, epoch: epoch ?? S.epoch, bytes: b64(bytes)};
  if (targets) payload.targets = targets;
  if (members) payload.members = members;
  return api('POST', roomPath('events'), payload);
}

// ---- sync (the smoke's Device.sync, in the browser) ----
async function sync({quiet = false} = {}) {
  if (!S.started || S.busy) return;
  S.busy = true;
  try {
    const {status, body} = await api('GET', roomPath(`events?device=${encodeURIComponent(S.dev)}&after=${S.relaySeq}`));
    if (status === 404 && body && body.error === 'no_such_room') { if (!quiet) log('방이 아직 없다 — 첫 기기가 "방 만들기"를 하고 초대해야 한다.'); return; }
    if (status === 403) { setState(`릴레이가 이 기기를 받지 않는다(${describe(status, body)}) — 운영자 등록 대기`); return; }
    if (status !== 200) { if (!quiet) log('동기화 실패:', describe(status, body)); return; }
    if (body.first_seq > S.relaySeq + 1 && S.relaySeq > 0) log(`경고: 릴레이가 seq ${S.relaySeq + 1}~${body.first_seq - 1}를 이미 지웠다 — 재참여가 필요할 수 있다`);
    for (const ev of body.events) {
      S.relaySeq = Math.max(S.relaySeq, ev.seq);
      if (ev.device === S.dev) {
        if (ev.kind === 'commit' && S.pending) {
          await op('merge_pending');
          S.pending = false;
          S.roster = S.expectedRoster || S.roster; S.expectedRoster = null;
          S.epoch = ev.epoch + 1; renderRoster();
          log(`내 commit 반영(seq ${ev.seq}) — epoch 전진`);
          if (S.pendingWelcome) {
            const {target, welcome} = S.pendingWelcome; S.pendingWelcome = null;
            const r = await postEvent('welcome', unb64(welcome), {targets: [target], epoch: ev.epoch + 1});
            log(r.status === 201 ? `${target}에게 Welcome 전송` : `Welcome 전송 실패: ${describe(r.status, r.body)}`);
          }
        }
        continue;
      }
      const data = unb64(ev.bytes);
      if (!S.joined) {
        if (ev.kind === 'welcome') {
          await op('join', data);
          S.joined = true; S.roster = parseMembers((await op('members')).output); renderRoster();
          log(`참여 완료(seq ${ev.seq}) — 멤버 ${S.roster.join(', ')}`);
        }
        continue;  // anything before our Welcome is not ours to read
      }
      if (ev.kind === 'welcome') { log(`무시: 이미 참여한 기기에 온 Welcome(seq ${ev.seq})`); continue; }
      if (ev.kind === 'commit') {
        try {
          await op('commit', data);
          S.roster = parseMembers((await op('members')).output); renderRoster();
          log(`commit 적용(seq ${ev.seq}, ${ev.device}) — 멤버 ${S.roster.join(', ')}`);
        } catch (error) { log(`commit 거부(seq ${ev.seq}, ${ev.device}): ${error.message} — 이 기기는 방에서 빠졌을 수 있다`); }
        continue;
      }
      // The durable worker binds the room itself (bindDecrypt from its own init), so
      // the ciphertext goes in raw — `sealed()` is the memory-lane framing only.
      const out = await op('decrypt', data, S.wcursor + 1);
      if (out.rejected === true) { log(`해독 거부 → 건너뜀(seq ${ev.seq}, ${ev.device})`); continue; }
      showMessage(out.sender ?? ev.device, out.client, decoder.decode(new Uint8Array(out.output)), ev.seq, out.replay);
    }
    S.epoch = body.epoch;
    if (S.joined && S.relaySeq > 0 && body.cursor < S.relaySeq) {
      const ack = await api('GET', roomPath(`events?device=${encodeURIComponent(S.dev)}&after=${S.relaySeq}&ack=${S.relaySeq}`));
      if (ack.status !== 200 && !quiet) log('ack 실패:', describe(ack.status, ack.body));
    }
    save(); renderRoster();
  } catch (error) { if (!quiet) log('동기화 오류:', error.message); }
  finally { S.busy = false; }
}
function showMessage(sender, client, text, seq, replay) {
  const row = document.createElement('div');
  if (sender === S.dev) row.className = 'me';
  row.textContent = `[${seq}] ${sender}${client && client !== sender ? ` (${client})` : ''}: ${text}${replay ? ' (재생)' : ''}`;
  $('messages').append(row);
}
function renderRoster() {
  $('roster').textContent = `멤버: ${S.roster.length ? S.roster.join(', ') : '—'} · epoch ${S.epoch} · 릴레이 seq ${S.relaySeq}` +
    (S.pending ? ' · 내 commit 대기 중' : '') + (S.joined ? '' : ' · (아직 참여 전)');
}
function setState(text) { $('state').textContent = text; }
function enable(on) {
  for (const id of ['create', 'keypackage', 'invite', 'sync', 'send', 'evict', 'offer']) $(id).disabled = !on;
}

// ---- start / resume ----
const markerKey = db => 'fresh-marker:' + db;
async function activate(statusInfo) {
  localStorage.setItem(markerKey(S.db), '1');
  localStorage.setItem('relay-app:last', JSON.stringify({room: S.room, dev: S.dev, db: S.db}));
  S.started = true; enable(true);
  const fp = decoder.decode(new Uint8Array((await op('fingerprint')).output));
  const key = hex(statusInfo.public_key);
  setState(`기기 ${S.dev} · 방 ${S.room}\n지문 ${fp.replace(/(.{4})/g, '$1 ').trim()}\nrevision ${statusInfo.revision} · 저장항목 ${statusInfo.entries}건`);
  $('enroll-info').textContent = JSON.stringify({device_id: S.dev, actor: actorOf(S.dev), subject: '<운영자가 CF Access sub로 채움>',
    signing_key: key, fingerprint: fp}, null, 1);
  if (S.joined) { try { S.roster = parseMembers((await op('members')).output); } catch (_) { /* no group yet */ } }
  renderRoster();
  log(`워커 시작: ${S.dev} @ ${S.db} (relay seq ${S.relaySeq}, joined=${S.joined}, pending=${S.pending})`);
  await sync({quiet: true});
  S.timer = setInterval(() => sync({quiet: true}), 4000);
}
$('start').addEventListener('click', async () => {
  const dev = $('device').value.trim(), room = $('room').value.trim(), db = $('database').value.trim();
  const passphrase = $('passphrase').value;
  try {
    if (!ID.test(dev)) throw new Error('기기 ID: 영숫자·_·- 1~64자 (예 owner-pc, owner-iphone)');
    if (!ROOM.test(room)) throw new Error('방: 소문자·숫자·- 1~64자');
    if (!DB.test(db)) throw new Error('DB 이름은 family-mls-synthetic- 접두 필요');
    if (passphrase.length < 32 || passphrase.length > 128) throw new Error('암호는 32–128자');
    $('start').disabled = true;
    if (S.timer) clearInterval(S.timer);
    window.stopWorker?.('device');
    S.dev = dev; S.room = room; S.db = db; load();
    await window.spawn('device', true);
    setState('워커 시작 중 — 암호 키 유도에 모바일에서는 1~3분 걸릴 수 있다. 화면을 켜 두고 기다린다.');
    const init = await callWorker('init', {identity: dev, database: db, room, passphrase});
    $('passphrase').value = '';
    const statusInfo = await callWorker('status');
    if (init.fresh && localStorage.getItem(markerKey(db))) {
      window.__pendingFresh = statusInfo;
      $('confirm-fresh').hidden = false;
      setState('저장소가 비워져 새 기기로 시작한다 — 운영자 재등록과 상대 기기의 재초대가 필요하며 이전 메시지는 읽을 수 없다. "새 기기로 시작"으로 확인.');
      return;
    }
    if (init.fresh) { S.joined = false; S.pending = false; S.relaySeq = 0; S.roster = []; S.expectedRoster = null; S.pendingWelcome = null; }
    await activate(statusInfo);
  } catch (error) { fail(error); } finally { $('start').disabled = false; }
});
$('confirm-fresh').addEventListener('click', async () => {
  const statusInfo = window.__pendingFresh; if (!statusInfo) return;
  window.__pendingFresh = null; $('confirm-fresh').hidden = true;
  localStorage.removeItem(stateKey());
  Object.assign(S, {joined: false, pending: false, relaySeq: 0, roster: [], expectedRoster: null, pendingWelcome: null});
  try { await activate(statusInfo); } catch (error) { fail(error); }
});

// ---- room ----
const guard = (id, run) => $(id).addEventListener('click', async () => {
  $(id).disabled = true;
  try { await run(); } catch (error) { fail(error); } finally { $(id).disabled = !S.started; }
});
guard('create', async () => {
  if (S.joined) throw new Error('이 기기는 이미 방(그룹)에 있다');
  await op('create');
  S.joined = true; S.roster = [S.dev]; S.epoch = 0; save(); renderRoster();
  log('방(그룹) 생성 — 이제 다른 기기의 키 패키지로 초대할 수 있다');
});
guard('keypackage', async () => {
  const out = await op('key_package');
  const ref = hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new Uint8Array(out.output))));
  const r = await api('POST', roomPath('keypackages'), {device: S.dev, packages: [{ref, bytes: b64(out.output)}]});
  if (r.status !== 201 && r.status !== 200) throw new Error(`키 패키지 게시 실패: ${describe(r.status, r.body)}`);
  log(`키 패키지 게시(${r.body.stored ? '저장' : '중복'}) — 상대 기기가 "초대"로 이 기기를 넣을 수 있다`);
});
guard('invite', async () => {
  const target = $('target').value.trim();
  if (!ID.test(target)) throw new Error('초대할 기기 ID');
  if (!S.joined) throw new Error('먼저 방에 들어가 있어야 한다');
  if (S.pending) throw new Error('내 commit이 아직 반영되지 않았다 — 동기화 뒤 다시');
  await sync();
  const kp = await api('GET', roomPath(`keypackages?device=${encodeURIComponent(target)}&consumer=${encodeURIComponent(S.dev)}`));
  if (kp.status !== 200) throw new Error(`${target}의 키 패키지 없음: ${describe(kp.status, kp.body)} (상대가 먼저 "키 패키지 게시")`);
  const framed = new Uint8Array((await op('invite_with_commit', unb64(kp.body.bytes))).output);
  const n = new DataView(framed.buffer, framed.byteOffset, framed.byteLength).getUint32(0, true);
  const commit = framed.subarray(4, 4 + n), welcome = framed.subarray(4 + n);
  const expected = parseMembers((await op('members_after_pending')).output);
  const r = await postEvent('commit', commit, {members: membersWire(expected)});
  if (r.status === 409) {
    await op('clear_pending');
    log(`commit 거절(${describe(r.status, r.body)}) — 방이 먼저 바뀌었다. 동기화 뒤 다시 초대한다.`);
    await sync(); return;
  }
  if (r.status !== 201) { await op('clear_pending'); throw new Error(`commit 거절: ${describe(r.status, r.body)}`); }
  S.pending = true; S.expectedRoster = expected; S.pendingWelcome = {target, welcome: b64(welcome)}; save();
  log(`${target} 추가 commit 게시(seq ${r.body.seq}) — 반영되면 Welcome을 보낸다`);
  await sync();
});
guard('sync', () => sync());
guard('send', async () => {
  const text = $('msg').value;
  if (!text) return;
  if (!S.joined) throw new Error('아직 방에 참여하지 않았다');
  await sync({quiet: true});
  for (let attempt = 0; attempt < 2; attempt++) {
    const out = await op('encrypt', utf8.encode(text));
    const r = await postEvent('application', new Uint8Array(out.output));
    if (r.status === 201) { showMessage(S.dev, S.dev, text, r.body.seq, false); $('msg').value = ''; S.epoch = r.body.epoch; save(); return; }
    if (r.status === 409 && r.body && r.body.error === 'cas_mismatch' && attempt === 0) { log('epoch가 바뀌어 다시 암호화'); await sync(); continue; }
    throw new Error(`전송 실패: ${describe(r.status, r.body)}`);
  }
});

// ---- E2 approval (trusted-device screen) ----
let candidate = null;
guard('offer', async () => {
  candidate = JSON.parse($('candidate').value);
  for (const k of ['device_id', 'actor', 'subject', 'signing_key', 'base_revision']) if (!(k in candidate)) throw new Error(`후보 JSON에 ${k} 없음`);
  if (!/^[a-f0-9]{64}$/.test(candidate.signing_key)) throw new Error('signing_key는 64 hex');
  const fp = decoder.decode(new Uint8Array((await op('policy_fingerprint', utf8.encode(candidate.signing_key))).output));
  $('candidate-fingerprint').textContent = fp.replace(/(.{4})/g, '$1 ').trim();
  $('approve').disabled = $('deny').disabled = false;
  log(`후보 ${candidate.device_id} 지문 표시 — 새 기기 화면의 지문과 눈으로 비교한다`);
});
$('deny').addEventListener('click', () => { candidate = null; $('candidate-fingerprint').textContent = ''; $('approve').disabled = $('deny').disabled = true; log('거부 — 서명하지 않음'); });
$('approve').addEventListener('click', async () => {
  $('approve').disabled = $('deny').disabled = true;
  try {
    const args = {action: 'approve-device', device_id: candidate.device_id, actor: candidate.actor, subject: candidate.subject,
      signing_key: candidate.signing_key, acceptance: 'trusted-device-fingerprint', base_revision: Number(candidate.base_revision)};
    const framed = new Uint8Array((await op('sign_approval', utf8.encode(JSON.stringify(args)))).output);
    const n = new DataView(framed.buffer, framed.byteOffset, framed.byteLength).getUint32(0, true);
    const evidence = {...args, signature: hex(framed.subarray(4 + n)), fingerprint: $('candidate-fingerprint').textContent.replace(/ /g, ''), approved_by: S.dev};
    delete evidence.action; delete evidence.acceptance;
    $('evidence').textContent = JSON.stringify(evidence, null, 1);
    log(`승인 서명 완료 — 아래 증거를 운영자에게 전달한다(-add-device -input)`);
  } catch (error) { fail(error); }
  candidate = null;
});

// ---- misc ----
guard('evict', async () => {
  if (!confirm(`${S.db} 의 IndexedDB를 삭제한다(축출 재연습). 계속?`)) return;
  if (S.timer) clearInterval(S.timer);
  window.stopWorker('device');
  await new Promise((resolve, reject) => {
    const request = indexedDB.deleteDatabase(S.db);
    request.onsuccess = resolve;
    request.onerror = () => reject(new Error('deleteDatabase 실패'));
    request.onblocked = () => reject(new Error('deleteDatabase 차단됨 — 다른 탭을 닫는다'));
  });
  localStorage.removeItem(markerKey(S.db)); localStorage.removeItem(stateKey());
  S.started = false; enable(false);
  setState('저장소 삭제 완료. 같은 기기 ID로 다시 시작하면 새 지문(새 기기) — 운영자 재등록(revoke + 재등록)과 상대의 재초대 필요.');
  log('저장소 삭제(축출 재연습)');
});
$('clear-log').addEventListener('click', () => { $('log').textContent = ''; });
$('origin').textContent = location.host;
try {
  const last = JSON.parse(localStorage.getItem('relay-app:last') || 'null');
  if (last) { $('room').value = last.room; $('device').value = last.dev; $('database').value = last.db; }
} catch (_) { /* ignore */ }
