// 대화 목록 NEW 배지 — 안 읽은 방의 이름 옆에 둥근 "N" 배지, 이름 굵게, 스크린리더에는 "새 메시지".
// DOM 노드는 assert.equal로 비교하지 않는다 — 실패 메시지가 happy-dom 객체를 diff하다 힙이 터진다.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Window } from 'happy-dom';

const window = new Window({ url: 'https://chat.example.test/' });
for (const key of ['HTMLElement', 'Node', 'Event', 'CSS', 'FormData']) globalThis[key] = window[key] ?? globalThis[key];
globalThis.window = window;
globalThis.document = window.document;
if (!globalThis.CSS) globalThis.CSS = window.CSS;

const ui = await import('../../src/ui.js');
const { strings } = await import('../../src/strings.js');

const root = () => {
  document.body.innerHTML = '<div id="app"></div>';
  return document.getElementById('app');
};
const summaries = (unread = {}) => [
  { roomId: '!a:x', displayName: '우리 가족', kind: 'family', memberCount: 4, agents: [], unread: Boolean(unread['!a:x']),
    lastMessage: { sender: '엄마', text: '저녁 먹자', ts: Date.now() - 30_000, eventId: '$1' } },
  { roomId: '!b:x', displayName: '아빠', kind: 'private', memberCount: 2, agents: [], unread: Boolean(unread['!b:x']), lastMessage: null },
];
const render = (app, unread, extra = {}) => ui.renderShell(app, {
  list: { summaries: summaries(unread), syncState: 'live', onSelect() {}, onOpenVerification() {}, onOpenRecovery() {}, onOpenMenu() {}, ...extra },
  room: null,
});
const row = (app, roomId) => app.querySelector(`.room-item[data-room-id="${roomId}"]`);

test('안 읽은 방만 이름 바로 옆에 N 배지가 붙고, 행이 unread로 표시된다', () => {
  const app = root();
  render(app, { '!a:x': true });
  const unread = row(app, '!a:x');
  const badge = unread.querySelector('.room-title .unread-badge');
  assert.ok(badge, '이름과 같은 묶음(.room-title) 안에 배지가 있다');
  assert.equal(badge.previousElementSibling?.className, 'room-name', '배지는 이름 바로 뒤');
  assert.equal(badge.querySelector('[aria-hidden="true"]').textContent, 'N');
  assert.ok(unread.classList.contains('unread'));
  assert.equal(unread.querySelector('.room-name').textContent, '우리 가족', '이름 글자는 그대로(말줄임 대상)');
  assert.equal(row(app, '!b:x').querySelector('.unread-badge'), null);
  assert.ok(!row(app, '!b:x').classList.contains('unread'));
});

test('접근성: 배지의 N은 읽지 않고 "새 메시지"를 읽는다 — 행(버튼)의 이름에 포함된다', () => {
  const app = root();
  render(app, { '!b:x': true });
  const button = row(app, '!b:x');
  const badge = button.querySelector('.unread-badge');
  assert.equal(strings.rooms.unreadLabel, '새 메시지');
  assert.equal(badge.getAttribute('title'), '새 메시지');
  assert.equal(badge.querySelector('.visually-hidden').textContent, '새 메시지');
  assert.equal(button.tagName, 'BUTTON');
  // 버튼의 접근 가능한 이름 = aria-hidden을 뺀 글자 내용.
  const hidden = [...button.querySelectorAll('[aria-hidden="true"]')].map((node) => node.textContent);
  assert.deepEqual(hidden.filter((text) => text === 'N'), ['N']);
  assert.match(button.textContent, /아빠.*새 메시지/);
});

test('읽으면 배지가 사라지고, 다시 새 메시지가 오면 같은 행에 다시 붙는다(목록 재조정)', () => {
  const app = root();
  render(app, { '!a:x': true });
  assert.ok(row(app, '!a:x').querySelector('.unread-badge'));
  render(app, {});
  assert.equal(app.querySelector('.unread-badge'), null, '읽음이면 배지 없음');
  assert.ok(!row(app, '!a:x').classList.contains('unread'));
  render(app, { '!a:x': true });
  assert.ok(row(app, '!a:x').querySelector('.unread-badge'));
});

test('열려 있는(선택된) 방 행과 순서 편집 행에도 같은 배지가 그려진다', () => {
  const app = root();
  ui.renderShell(app, {
    list: { summaries: summaries({ '!a:x': true }), syncState: 'live', onSelect() {}, onOpenVerification() {}, onOpenRecovery() {}, onOpenMenu() {} },
    room: { room: summaries()[0], timeline: [], onSend() {}, onAttach() {}, onBack() {} },
  });
  const active = row(app, '!a:x');
  assert.equal(active.getAttribute('aria-current'), 'true');
  assert.ok(active.querySelector('.unread-badge'), '아직 안 읽었으면(맨 아래가 아님 등) 열린 방에도 남는다');
  const editing = root();
  render(editing, { '!b:x': true }, { orderEditing: true, onToggleOrderEdit() {}, onMoveRoom() {} });
  assert.ok(row(editing, '!b:x').querySelector('.unread-badge'));
});

test('styles.css: 배지는 전용 색 토큰(라이트·다크 공용)의 원형 16~18px, 이름은 말줄임을 유지하고 배지는 줄지 않는다', () => {
  const css = readFileSync(new URL('../../styles.css', import.meta.url), 'utf-8');
  const rule = (selector) => {
    const match = css.match(new RegExp(`(^|\\n)${selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*\\{([^}]*)\\}`));
    assert.ok(match, `${selector} 규칙이 있다`);
    return match[2];
  };
  const badge = rule('.unread-badge');
  assert.match(badge, /background:\s*var\(--unread\)/);
  assert.match(badge, /color:\s*var\(--on-unread\)/);
  assert.match(badge, /border-radius:\s*50%/);
  assert.match(badge, /flex:\s*none/);
  const size = Number(badge.match(/\bwidth:\s*(\d+)px/)?.[1]);
  assert.ok(size >= 16 && size <= 18, `배지 지름 ${size}px`);
  assert.match(badge, new RegExp(`height:\\s*${size}px`));
  const tokens = [...css.matchAll(/--unread:\s*(#[0-9a-f]{6})/gi)].map((m) => m[1]);
  assert.equal(tokens.length, 1, '라이트·다크 공용 한 벌(두 배경 모두에서 대비를 만족한다)');
  // 11px 굵은 글자는 "큰 글자"가 아니다 — 흰 N과 배경의 대비가 WCAG AA 4.5:1 이상이어야 한다.
  const onTokens = [...css.matchAll(/--on-unread:\s*(#[0-9a-f]{6})/gi)].map((m) => m[1]);
  assert.equal(onTokens.length, 1);
  const luminance = (hex) => {
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
      .map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  tokens.forEach((bg, i) => {
    const [hi, lo] = [luminance(bg), luminance(onTokens[i])].sort((x, y) => y - x);
    const ratio = (hi + 0.05) / (lo + 0.05);
    assert.ok(ratio >= 4.5, `${onTokens[i]} on ${bg} 대비 ${ratio.toFixed(2)}`);
    // 다크 모드 카드(--surface #171d2c) 위에서도 배지 자체가 보여야 한다(비텍스트 3:1).
    const surface = (luminance(bg) + 0.05) / (luminance('#171d2c') + 0.05);
    assert.ok(surface >= 3, `${bg} on dark surface ${surface.toFixed(2)}`);
  });
  const name = rule('.room-item .room-title .room-name');
  assert.match(name, /min-width:\s*0/);
  assert.match(rule('.room-item .room-title'), /min-width:\s*0/);
  assert.match(rule('.room-item.unread .room-name'), /font-weight:\s*800/);
  assert.match(rule('.visually-hidden'), /clip/);
});

test('styles.css: 스크린리더 "새 메시지" 라벨(절대 위치)은 방 행·셸 안에 갇혀 문서를 늘리지 않는다', () => {
  // 기준 상자가 없으면 목록 아래쪽 안 읽은 방의 라벨이 문서 높이를 늘려, PC 크롬에서 배경 휠에
  // 앱 전체가 위로 밀려 올라갔다(실측 doc 1129/911, scrollY 218). 실제 Chromium 검사는 browser_smoke.
  const css = readFileSync(new URL('../../styles.css', import.meta.url), 'utf-8');
  const rule = (selector) => {
    const match = css.match(new RegExp(`(^|\\n)${selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*\\{([^}]*)\\}`));
    assert.ok(match, `${selector} 규칙이 있다`);
    return match[2];
  };
  assert.match(rule('.visually-hidden'), /position:\s*absolute/);
  assert.match(rule('.room-item'), /position:\s*relative/);
  assert.match(rule('main.shell'), /position:\s*relative/);
  assert.match(rule('main.shell'), /overflow:\s*hidden/);
});
