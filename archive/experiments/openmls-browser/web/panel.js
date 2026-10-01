// 합성 수동 패널(#177 M4 실기기 리허설). 스모크가 구동하는 동일한 durable 워커를
// 사람 손으로 구동한다. 신뢰는 고정 키 검증에서 온다; 이 패널은 구동 편의만 제공한다.
const token = (location.pathname.match(/\/s\/([0-9a-f]{8})\//) || [])[1];
const $ = id => document.getElementById(id);
const utf8 = new TextEncoder();
const decoder = new TextDecoder();
const b64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes)));
const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
const genId = () => Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 12);
const log = (...parts) => { $('log').textContent += parts.join(' ') + '\n'; };
let cursor = 0, started = false;
const slots = {package: null, welcome: null, cipher: null};
const slotLabel = {package: '패키지', welcome: 'welcome', cipher: '암호문'};

// http(LAN)에서는 secure context가 아니어도 동작해야 하는 표시용 SHA-256.
// 신뢰 결정에는 쓰이지 않는다 — 지문 대조는 사람이 두 화면을 눈으로 비교한다.
const sha256 = (() => {
  const K = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2];
  const rotr = (x, n) => (x >>> n) | (x << (32 - n));
  return bytes => {
    bytes = Array.from(bytes);
    const bitlen = bytes.length * 8;
    const padded = bytes.concat([0x80]).concat(Array.from({length: (56 - (bytes.length + 1) % 64 + 64) % 64}, () => 0))
      .concat([0, 0, 0, 0, (bitlen >>> 24) & 255, (bitlen >>> 16) & 255, (bitlen >>> 8) & 255, bitlen & 255]);
    let h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    const T = (x, y, z) => (x & y) ^ (~x & z);      // choice
    const M = (x, y, z) => (x & y) ^ (x & z) ^ (y & z); // majority
    for (let off = 0; off < padded.length; off += 64) {
      const w = new Array(64);
      for (let i = 0; i < 64; i++) {
        w[i] = i < 16
          ? (padded[off + i * 4] << 24) | (padded[off + i * 4 + 1] << 16) | (padded[off + i * 4 + 2] << 8) | padded[off + i * 4 + 3]
          : (((w[i - 2] >>> 17) | (w[i - 2] << 15)) ^ ((w[i - 2] >>> 19) | (w[i - 2] << 13)) ^ (w[i - 2] >>> 10))
            + w[i - 7] + (((w[i - 15] >>> 7) | (w[i - 15] << 25)) ^ ((w[i - 15] >>> 18) | (w[i - 15] << 14)) ^ (w[i - 15] >>> 3)) + w[i - 16] | 0;
      }
      let [a, b, c, d, e, f, g, hh] = h;
      for (let i = 0; i < 64; i++) {
        const t1 = (hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + T(e, f, g) + K[i] + w[i]) | 0;
        const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + M(a, b, c)) | 0;
        hh = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
      }
      h = [(h[0] + a) | 0, (h[1] + b) | 0, (h[2] + c) | 0, (h[3] + d) | 0,
           (h[4] + e) | 0, (h[5] + f) | 0, (h[6] + g) | 0, (h[7] + hh) | 0];
    }
    return h.map(x => (x >>> 0).toString(16).padStart(8, '0')).join('');
  };
})();

const group4 = hex => hex.replace(/(.{4})/g, '$1 ').trim();
const fail = error => { log('실패:', String(error)); alert(String(error)); };
const busy = async (button, run) => {
  button.disabled = true;
  try { await run(); } catch (error) { fail(error); } finally { button.disabled = !started; }
};

async function callWorker(method, argument) {
  const value = await window.call('device', method, argument);
  if (!value.ok) throw new Error(`${method} 거부`);
  return value.result;
}
async function op(method, bytes = [], sequence = 0) {
  const result = await callWorker('operation', {id: genId(), method, bytes: Array.from(bytes), sequence, fault: ''});
  cursor = result.cursor;
  return result;
}
async function api(path, body) {
  const response = await fetch(path, body === undefined ? undefined
    : {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)});
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
  return response.json();
}
const slotFromLabel = label =>
  label.startsWith('keypackage') ? 'package' : label.startsWith('welcome') ? 'welcome'
  : label.startsWith('ciphertext') ? 'cipher' : null;
function renderSlots() {
  $('slots').textContent = '슬롯: ' + Object.entries(slots)
    .map(([k, v]) => `${slotLabel[k]}=${v === null ? '없음' : `${v.length}B`}`).join(' ');
}

$('register').addEventListener('click', () => busy($('register'), async () => {
  if (!$('kind').value) throw new Error('브라우저 종류를 선택한다');
  const detail = await api('devices', {kind: $('kind').value, ua: navigator.userAgent,
    platform: navigator.platform || '', screen: `${screen.width}x${screen.height}`,
    dpr: devicePixelRatio, languages: (navigator.languages || []).join(',')});
  $('reg-out').textContent = `등록됨: ${detail.kind} — ${navigator.userAgent}`;
  log('기기 등록:', detail.kind);
}));

$('start').addEventListener('click', () => busy($('start'), async () => {
  const identity = $('identity').value.trim(), database = $('database').value.trim();
  const passphrase = $('passphrase').value;
  if (!/^[a-zA-Z0-9_.:-]{1,64}$/.test(identity)) throw new Error('신원 형식');
  if (!/^family-mls-synthetic-[a-z0-9-]{1,64}$/.test(database)) throw new Error('데이터베이스 이름은 family-mls-synthetic- 접두 필요');
  if (passphrase.length < 32 || passphrase.length > 128) throw new Error('암호는 32–128자');
  window.stopWorker?.('device');
  await window.spawn('device', true);
  const init = await callWorker('init', {identity, database, room: 'family', passphrase});
  cursor = init.cursor;
  const status = await callWorker('status');
  localStorage.setItem('real-device-session', JSON.stringify({identity, database}));
  started = true;
  const fingerprint = group4(sha256(new Uint8Array(status.public_key)));
  $('state').textContent = `신원 ${identity} · 지문 ${fingerprint}\nrevision ${status.revision} · cursor ${status.cursor} · ledger ${status.entries}건 · reloads ${status.reloads}`;
  for (const id of ['create', 'keypackage', 'invite', 'join', 'encrypt', 'decrypt', 'evict']) $(id).disabled = false;
  log(`워커 시작: ${identity} @ ${database} (cursor ${cursor})`);
}));

$('board-refresh').addEventListener('click', () => busy($('board-refresh'), async () => {
  const entries = await api('board');
  $('board-list').innerHTML = '';
  for (const entry of entries) {
    const row = document.createElement('div');
    const radio = document.createElement('input');
    radio.type = 'radio'; radio.name = 'board-item'; radio.value = entry.id;
    const text = document.createElement('span');
    text.textContent = ` ${entry.label} · ${entry.len}B · ${entry.when}`;
    row.append(radio, text);
    $('board-list').append(row);
  }
  if (!entries.length) $('board-list').textContent = '교환판이 비어 있다.';
}));
$('fetch-item').addEventListener('click', () => busy($('fetch-item'), async () => {
  const chosen = document.querySelector('input[name="board-item"]:checked');
  if (!chosen) throw new Error('가져올 항목을 선택한다');
  const item = await api(`board/${chosen.value}`);
  const slot = slotFromLabel(item.label);
  slots[slot ?? 'cipher'] = unb64(item.b64);
  if (!slot) log(`알 수 없는 라벨 ${item.label} — 암호문 슬롯에 넣었다`);
  renderSlots();
  log(`가져옴: ${item.label} → ${slot ?? 'cipher'} 슬롯`);
}));

$('create').addEventListener('click', () => busy($('create'), async () => {
  await op('create'); log('그룹 생성 완료');
}));
$('keypackage').addEventListener('click', () => busy($('keypackage'), async () => {
  const identity = $('identity').value.trim();
  const out = await op('key_package');
  await api('board', {label: `keypackage:${identity}`, b64: b64(out.output)});
  log('키 패키지 게시 완료');
}));
$('invite').addEventListener('click', () => busy($('invite'), async () => {
  if (!slots.package) throw new Error('먼저 교환판에서 패키지를 가져온다');
  const identity = $('identity').value.trim();
  const out = await op('invite', slots.package);
  await api('board', {label: `welcome:${identity}`, b64: b64(out.output)});
  log('초대 완료 — Welcome 게시됨');
}));
$('join').addEventListener('click', () => busy($('join'), async () => {
  if (!slots.welcome) throw new Error('먼저 교환판에서 Welcome을 가져온다');
  await op('join', slots.welcome);
  log('참여 완료 — 이제 양방향 메시지 가능');
}));

$('encrypt').addEventListener('click', () => busy($('encrypt'), async () => {
  const identity = $('identity').value.trim();
  const out = await op('encrypt', utf8.encode($('msg').value));
  await api('board', {label: `ciphertext:${identity}`, b64: b64(out.output)});
  log('암호문 게시 완료');
}));
$('decrypt').addEventListener('click', () => busy($('decrypt'), async () => {
  if (!slots.cipher) throw new Error('먼저 교환판에서 암호문을 가져온다');
  const out = await op('decrypt', slots.cipher, cursor + 1);
  slots.cipher = null; renderSlots();
  $('mail').textContent = `해독: ${decoder.decode(new Uint8Array(out.output))}`
    + (out.replay ? ' (재생 응답)' : '') + `\n(cursor ${out.cursor}, revision ${out.revision})`;
  log(`해독 성공 cursor=${out.cursor}`);
}));

$('observe').addEventListener('click', () => busy($('observe'), async () => {
  await api('observations', {kind: $('kind').value, bg_seconds: Number($('bg-seconds').value) || 0,
    bg_decrypted: $('bg-ok').checked, notes: $('notes').value});
  $('observe-out').textContent = '관찰 기록이 세션 서버에 저장되었다.';
  log('관찰 전송 완료');
}));
$('evict').addEventListener('click', () => busy($('evict'), async () => {
  const database = $('database').value.trim();
  if (!confirm(`${database} 의 IndexedDB를 삭제한다(축출 재연습). 계속?`)) return;
  window.stopWorker('device');
  await new Promise((resolve, reject) => {
    const request = indexedDB.deleteDatabase(database);
    request.onsuccess = resolve;
    request.onerror = () => reject(new Error('deleteDatabase 실패'));
    request.onblocked = () => reject(new Error('deleteDatabase 차단됨 — 다른 탭을 닫는다'));
  });
  started = false;
  for (const id of ['create', 'keypackage', 'invite', 'join', 'encrypt', 'decrypt', 'evict']) $(id).disabled = true;
  $('state').textContent = '저장소 삭제 완료. 같은 신원·데이터베이스·암호로 다시 시작하면 새 지문(새 기기)이 된다 — 상대의 재초대 필요.';
  log('저장소 삭제 완료(축출 재연습): 재시작 후 재초대 필요');
}));

try {
  const saved = JSON.parse(localStorage.getItem('real-device-session') || 'null');
  if (saved) { $('identity').value = saved.identity; $('database').value = saved.database; }
} catch (_) { /* 손상된 저장은 무시 */ }
if (!token) { log('세션 토큰 경로가 아니다 — 서버가 인쇄한 /s/<토큰>/panel.html 로 접속한다.'); }
// selftest 전용 표시용 해시 훅(신뢰 결정에 사용하지 않는다).
window.__panel = {sha256};
