// DOM 스모크(2026-09-17 #126): node --test는 DOM이 없어 ui.js의 화면 결함("null" 글자, 초안 유실,
// 작성창 교체로 IME 끊김)을 한 번도 잡지 못했다. happy-dom으로 주요 화면을 실제로 그려 본다.
import test from 'node:test';
import assert from 'node:assert/strict';
import { Window } from 'happy-dom';

const window = new Window({ url: 'https://chat.example.test/' });
for (const key of ['window', 'document', 'HTMLElement', 'Node', 'Event', 'CSS', 'FormData', 'Intl']) {
  if (!(key in globalThis) || key === 'window' || key === 'document') globalThis[key] = window[key] ?? globalThis[key];
}
globalThis.window = window;
globalThis.document = window.document;
if (!globalThis.CSS) globalThis.CSS = window.CSS;

const ui = await import('../../src/ui.js');
const { strings } = await import('../../src/strings.js');

const root = () => {
  document.body.innerHTML = '<div id="app"></div>';
  return document.getElementById('app');
};
const rooms = [
  { roomId: '!a:x', displayName: '우리 가족', kind: 'family', memberCount: 4, agents: [{ userId: '@fambot:x' }], lastMessage: { sender: '팸봇', text: '안녕', ts: Date.now() - 30_000, eventId: '$1' } },
  { roomId: '!b:x', displayName: '엄마', kind: 'private', memberCount: 2, agents: [], lastMessage: { sender: '엄마', text: '잘자', ts: Date.now() - 10_000, eventId: '$2' } },
];
const timeline = [
  { eventId: '$e1', name: '아빠', isMe: false, kind: 'text', body: '저녁 먹자', ts: Date.now() - 60_000 },
  { eventId: '$e2', name: '나', isMe: true, kind: 'photo', body: 'menu.jpg', meta: '2.4 MB', ts: Date.now() },
  // main.js timelineEntry가 복호화 실패 본문을 strings.chat.decryptFailed로 채운다 — ui는 body를 그대로 그린다.
  { eventId: '$e3', name: '홍길동', isMe: false, kind: 'undecryptable', body: strings.chat.decryptFailed, ts: Date.now() },
];
const listProps = () => ({ summaries: rooms, syncState: 'live', onSelect() {}, onOpenVerification() {}, onOpenRecovery() {}, onOpenMenu() {}, invites: [{ roomId: '!i:x', displayName: '여행', kind: 'family', memberCount: 3, agentCount: 1, requiresAiConsent: true, inviterName: '아빠' }], inviteHandlers: { isAiConsentAcknowledged: () => false, onAiConsentChange() {}, onAccept() {}, onDecline() {} } });
const roomProps = () => ({ room: rooms[0], timeline, onSend() {}, onAttach() {}, onBack() {}, hasMore: true, onLoadEarlier() {} });
const boxProps = () => ({ open: false, tab: 'attachments', attachments: [{ kind: 'file', name: 'a.pdf', mimetype: 'application/pdf', size: 12, url: 'mxc://x/1', encrypted: null, roomName: '우리 가족', sender: '나', ts: Date.now() }], filebox: { url: 'https://files.example.test/', homeUrl: 'https://files.example.test/', title: '파일보관함' }, onToggle() {}, onTab() {}, onRefresh() {}, onOpen() {} });

const noNullText = (node) => assert.ok(!/\bnull\b|undefined/.test(node.textContent), '화면에 null/undefined 글자가 있다');

test('conversation bubbles use sanitized Matrix HTML and retain literal plain/attachment fallbacks', () => {
  const app = root();
  ui.renderShell(app, { list: listProps(), room: { ...roomProps(), timeline: [
    { ...timeline[0], body: '**정상**', formattedBody: '<p><strong>정상</strong></p><ul><li>확인 완료</li></ul>' },
    { ...timeline[1], body: '<img src=x>.jpg', formattedBody: '<strong>attachment must stay plain</strong>' },
    { ...timeline[2], formattedBody: '<strong>failure must stay plain</strong>' },
    { ...timeline[0], eventId: '$plain', body: '**원문** <script>x()</script>' },
    { ...timeline[0], eventId: '$empty', body: '대체 본문', formattedBody: '<img src="https://example.com">' },
  ] } });
  assert.equal(app.querySelector('.rich-text strong').textContent, '정상');
  assert.equal(app.querySelector('.rich-text li').textContent, '확인 완료');
  assert.equal(app.querySelectorAll('.rich-text').length, 1);
  assert.equal(app.querySelector('.kind-photo strong'), null);
  assert.equal(app.querySelector('.kind-undecryptable strong'), null);
  assert.equal(app.querySelector('[data-event-id="$plain"] .body').textContent, '**원문** <script>x()</script>');
  assert.equal(app.querySelector('[data-event-id="$empty"] .body').textContent, '대체 본문');
  assert.equal(app.querySelector('img,script'), null);
});

test('로그인 화면: 기본값이 있으면 홈서버 칸이 접히고 아이디가 채워진다', () => {
  const app = root();
  ui.renderLogin(app, { onSubmit() {}, defaults: { homeserverUrl: 'https://matrix.example.test', user: 'minseo' } });
  assert.ok(app.querySelector('details.advanced'));
  assert.equal(app.querySelector('input[name=homeserverUrl]').value, 'https://matrix.example.test');
  assert.equal(app.querySelector('input[name=user]').value, 'minseo');
  noNullText(app);
  const plain = root();
  ui.renderLogin(plain, { onSubmit() {} });
  assert.equal(plain.querySelector('details.advanced'), null);
});

test('셸: 목록·대화·보관함이 그려지고 내 메시지는 data-me, 복호화 실패는 자리표시', () => {
  const app = root();
  ui.renderShell(app, { list: listProps(), room: roomProps(), box: boxProps() });
  assert.equal(app.querySelectorAll('.room-item').length, 2);
  assert.equal(app.querySelector('.room-item[aria-current="true"] .room-name').textContent, '우리 가족');
  const previews = [...app.querySelectorAll('.room-item .preview')].map((n) => n.textContent);
  assert.equal(previews[0], '팸봇: 안녕');
  assert.equal(previews[1], '잘자');
  assert.equal(app.querySelectorAll('.room-item')[0].querySelector('.preview-sender').textContent, '팸봇: ');
  assert.equal(app.querySelectorAll('.room-item')[1].querySelector('.preview-sender'), null);
  assert.equal(app.querySelectorAll('li.bubble').length, 3);
  assert.equal(app.querySelector('li.bubble[data-me="true"] .body').textContent.includes('menu.jpg'), true);
  assert.ok(app.querySelector('li.bubble.kind-undecryptable .body').textContent.includes(strings.chat.decryptFailed));
  assert.ok(app.querySelector('.load-earlier button'));
  assert.equal(app.querySelectorAll('.file-item').length, 1);
  assert.equal(app.querySelectorAll('.box-tabs button').length, 2);
  assert.equal(app.querySelector('main.shell').dataset.view, 'room');
  noNullText(app);
});

test('셸: 같은 방을 다시 그려도 작성창 요소·값이 유지되고, 방을 바꾸면 새로 만든다', () => {
  const app = root();
  ui.renderShell(app, { list: listProps(), room: roomProps(), box: boxProps() });
  const ta = app.querySelector('.composer textarea[name=body]');
  ta.value = '내가';
  ui.renderShell(app, { list: listProps(), room: { ...roomProps(), timeline: [...timeline, { eventId: '$e4', name: '엄마', isMe: false, kind: 'text', body: '새 글', ts: Date.now() }] }, box: boxProps() });
  const ta2 = app.querySelector('.composer textarea[name=body]');
  assert.equal(ta2, ta, '같은 방 재렌더는 textarea를 교체하면 안 된다(IME)');
  assert.equal(ta2.value, '내가');
  assert.equal(app.querySelectorAll('li.bubble').length, 4);
  ui.renderShell(app, { list: listProps(), room: { ...roomProps(), room: rooms[1] }, box: boxProps() });
  assert.notEqual(app.querySelector('.composer textarea[name=body]'), ta);
});

test('시트: 설정 메뉴·기기 관리·검증·복구·미리보기가 "null" 없이 열린다', async () => {
  const app = root();
  ui.renderShell(app, { list: listProps(), room: null, box: boxProps() });
  const closeMenu = ui.openMenuSheet(app, { items: [{ label: '기기 검증', onClick() {} }, { label: '로그아웃', onClick() {}, danger: true }] });
  assert.equal(app.querySelectorAll('dialog.menu .menu-items button').length, 2);
  noNullText(app.querySelector('dialog.menu'));
  closeMenu();
  const devices = [
    { deviceId: 'CUR', displayName: '', lastSeenTs: Date.now(), lastSeenIp: '', isCurrent: true, crossSigned: null },
    { deviceId: 'OLD', displayName: '', lastSeenTs: Date.now() - 86_400_000, lastSeenIp: '1.2.3.4', isCurrent: false, crossSigned: false },
  ];
  const closeDevices = ui.openDevicesSheet(app, { load: async () => devices, remove: async () => ({ deleted: [] }) });
  await new Promise((r) => setTimeout(r, 5));
  assert.equal(app.querySelectorAll('.device-item').length, 2);
  assert.ok(app.querySelector('.device-item input[type=checkbox][disabled]'), '현재 기기는 선택 불가');
  noNullText(app.querySelector('dialog.devices'));
  closeDevices();
  const closeVerify = ui.openVerificationSheet(app, { driver: async (cb) => { cb.onRequested?.(); cb.onEmojis([['🐶', 'Dog']], { confirm() {}, mismatch() {} }); } });
  app.querySelector('dialog.sheet button.primary').click();
  await new Promise((r) => setTimeout(r, 5));
  assert.equal(app.querySelectorAll('dialog.sheet .emojis li').length, 1);
  assert.ok(app.querySelector('dialog.sheet .emojis .meta').textContent.includes('강아지'));
  noNullText(app.querySelector('dialog.sheet'));
  // 목록 화면 전체 재구성(2초 갱신)이 열린 시트를 떼었다 붙이면 모달에서 빠진다 — 같은 노드가 제자리에 남아야 한다.
  const sheet = app.querySelector('dialog.sheet');
  const removed = [];
  const observer = new window.MutationObserver((records) => records.forEach((r) => removed.push(...r.removedNodes)));
  observer.observe(app, { childList: true });
  ui.renderShell(app, { list: listProps(), room: null, box: boxProps() });
  ui.renderShell(app, { list: listProps(), room: roomProps(), box: boxProps() });
  observer.takeRecords().forEach((r) => removed.push(...r.removedNodes));
  observer.disconnect();
  assert.equal(removed.includes(sheet), false, '전체 재구성이 열린 시트를 DOM에서 떼면 안 된다');
  assert.ok(sheet.isConnected && sheet.open && app.querySelector('main.shell'), '시트와 셸이 함께 남아야 한다');
  closeVerify();
  assert.equal(app.querySelector('dialog.sheet'), null, '닫힌 검증 시트는 DOM에서 제거된다');
  // 진행 중(상대 수락 대기)에 시트를 닫으면 요청을 취소해 상대 기기가 시간 초과까지 기다리지 않는다.
  let cancelled = 0;
  const closePending = ui.openVerificationSheet(app, { driver: async (cb) => { cb.onRequest?.({ cancel() { cancelled += 1; } }); cb.onRequested?.(); await new Promise(() => {}); } });
  app.querySelector('dialog.sheet button.primary').click();
  await new Promise((r) => setTimeout(r, 5));
  closePending();
  assert.equal(cancelled, 1, '대기 중 닫기는 SDK 요청을 취소한다');
  const closeRecovery = ui.openRecoverySheet(app, {});
  assert.match(app.querySelector('dialog.sheet .recovery-key').textContent, /\S{4}/);
  noNullText(app.querySelector('dialog.sheet'));
  closeRecovery();
  const closePreview = ui.openPreviewSheet(app, { name: 'p.jpg', src: 'blob:x' });
  assert.equal(app.querySelector('dialog.preview img').getAttribute('alt'), 'p.jpg');
  closePreview();
});

test('설정 메뉴 항목이 연 시트는 메뉴 닫힘·전체 재렌더 뒤에도 남아 있다', async () => {
  const app = root();
  ui.renderShell(app, { list: listProps(), room: null, box: boxProps() });
  let opened = null;
  const closeMenu = ui.openMenuSheet(app, { items: [{ label: '기기 검증', onClick() { opened = ui.openVerificationSheet(app, { driver: async () => {} }); } }] });
  app.querySelector('dialog.menu .menu-items button').click();
  await new Promise((r) => setTimeout(r, 5));
  assert.ok(app.querySelector('dialog.sheet:not(.menu)'), '메뉴가 닫힌 뒤에도 검증 시트가 있어야 한다');
  // 목록 화면 전체 재구성(방 없음)도 열린 시트를 보존해야 한다
  ui.renderShell(app, { list: listProps(), room: null, box: boxProps() });
  assert.ok(app.querySelector('dialog.sheet[open]'), '전체 재렌더 후에도 시트가 남아야 한다');
  assert.equal(app.querySelectorAll('main.shell').length, 1);
  closeMenu; opened?.();
});

test('입력 중 표시: 방 이름 옆 .typing이 그려지고, 없으면 숨긴다', () => {
  const app = root();
  ui.renderShell(app, { list: listProps(), room: { ...roomProps(), typing: '입력중..' }, box: boxProps() });
  const row = app.querySelector('.room-screen .appbar .title-row');
  assert.ok(row, '제목 행(.title-row)이 있어야 한다');
  assert.equal(row.querySelector('h2').textContent, '우리 가족');
  assert.equal(row.querySelector('.typing').textContent, '입력중..');
  noNullText(app);
  // 라벨이 빈 문자열이면 요소 자체가 없어야 한다(자리만 차지하지 않게).
  const app2 = root();
  ui.renderShell(app2, { list: listProps(), room: { ...roomProps(), typing: '' }, box: boxProps() });
  assert.equal(app2.querySelector('.room-screen .appbar .typing'), null);
});

test('입력 중 표시: 대화목록에서도 이름 옆에 그려진다(없는 방은 숨김)', () => {
  const app = root();
  const summaries = rooms.map((room, i) => ({ ...room, typing: i === 0 ? '입력중..' : '' }));
  ui.renderShell(app, { list: { ...listProps(), summaries }, room: null, box: boxProps() });
  const heads = [...app.querySelectorAll('.room-item .room-head')];
  assert.equal(heads.length, 2);
  assert.equal(heads[0].querySelector('.typing')?.textContent, '입력중..');
  assert.equal(heads[1].querySelector('.typing'), null);
  noNullText(app);
});

test('입력 중 전송: 실제 입력만 onTyping으로 전달하고 초안 복원 같은 스크립트 이벤트는 걸러낸다', () => {
  const app = root();
  const activity = [];
  ui.renderShell(app, { list: listProps(), room: { ...roomProps(), onTyping: (hasText) => activity.push(hasText) }, box: boxProps() });
  const ta = app.querySelector('.composer textarea[name=body]');
  // 스크립트가 만든 input 이벤트(isTrusted=false)는 초안 복원(#160) 같은 프로그램적 갱신이다.
  // 이 경로를 타이핑으로 치면 방을 열기만 해도 상대에게 "입력중"이 뜬다.
  ta.value = '안녕';
  ta.dispatchEvent(new window.Event('input', { bubbles: true }));
  assert.deepEqual(activity, [], '프로그램적 input 이벤트는 타이핑으로 치지 않는다');
});
