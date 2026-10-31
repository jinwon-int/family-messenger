// agent-choices-v1(#620) 테스트: node --test archive/native-mls/web/hande/tests/agent-choices.test.mjs
// 판정은 세 앱 공유 벡터(archive/native-mls/tests/fixtures/agent-choices-vectors.json)를 그대로 돌린다.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseChoices, choiceReply, composeChoice, choiceState, choiceKeyAction, choiceKeyInput } from '../agent-choices.js';
import { installShortcuts } from '../shortcuts.js';

const vectors = JSON.parse(readFileSync(new URL('../../../tests/fixtures/agent-choices-vectors.json', import.meta.url), 'utf8'));

test('공유 벡터가 실렸다', () => {
  assert.ok(vectors.parse.length > 20);
  assert.ok(vectors.reply.length > 10);
  assert.ok(vectors.compose.length > 0);
});

for (const v of vectors.parse) {
  test(`parse: ${v.name}`, () => {
    assert.deepEqual(parseChoices(v.text), v.expected);
  });
}

for (const v of vectors.reply) {
  test(`reply: ${JSON.stringify(v.text)} / ${v.count}`, () => {
    assert.deepEqual(choiceReply(v.text, v.count), v.expected);
  });
}

for (const v of vectors.compose) {
  test(`compose: ${JSON.stringify(v.numbers)} / ${JSON.stringify(v.labels)}`, () => {
    assert.equal(composeChoice(v.numbers, v.labels), v.expected);
  });
}

test('reply: compose 결과는 답 판정 B 로 다시 같은 번호가 된다(왕복)', () => {
  for (const v of vectors.compose) {
    assert.deepEqual(choiceReply(composeChoice(v.numbers, v.labels), v.labels.length), [...new Set(v.numbers)].sort((a, b) => a - b));
  }
  // 파싱한 선택지 라벨로도 왕복한다 — 라벨 안의 `.`·`[ ]`·숫자가 A 를 흔들지 않는다.
  const choices = parseChoices(vectors.parse[0].text);
  const labels = choices.items.map((it) => it.label);
  for (const numbers of [[1], [2, 3], [3, 1, 2]]) {
    assert.deepEqual(choiceReply(composeChoice(numbers, labels), labels.length), [...numbers].sort((a, b) => a - b));
  }
});

test('compose: 라벨이 없거나 빈 번호는 (내용 없음)', () => {
  assert.equal(composeChoice([2, 1], ['A']), '1. A\n2. (내용 없음)');
  assert.equal(composeChoice([], ['A']), '');
});

test('reply: 문자열이 아니거나 공백·점뿐이면 null', () => {
  assert.equal(choiceReply(null, 3), null);
  assert.equal(choiceReply('', 3), null);
  assert.equal(choiceReply(' . ', 3), null);
  assert.equal(choiceReply('1..', 3), null);   // 끝 `.` 은 하나만 지운다
  assert.equal(choiceReply('1 -2', 3), null);
  assert.equal(choiceReply('\n \t\n', 3), null);   // B: 공백뿐인 줄만 남으면 null
  assert.deepEqual(choiceReply('1. A\r\n3. C\r\n', 3), [1, 3]);   // B: CRLF
});

test('parse: 문자열이 아니거나 빈 글은 null', () => {
  assert.equal(parseChoices(''), null);
  assert.equal(parseChoices(null), null);
  assert.equal(parseChoices(undefined), null);
});

// ---- 상태(규격 §2) — app.js R.entries 모양 ----

const ASK = '어떻게 할까요?\n1. 유지\n2. 롤백 (권장)\n3. 보류';
const agent = (key, body = ASK) => ({ key, kind: 'text', isAgent: true, isMe: false, body });
const mine = (key, body) => ({ key, kind: 'text', isAgent: false, isMe: true, body });
const other = (key, body) => ({ key, kind: 'text', isAgent: false, isMe: false, body });

test('state: 뒤에 메시지가 없으면 open', () => {
  const s = choiceState([other('a', '안녕'), agent('b')], 1);
  assert.equal(s.state, 'open');
  assert.equal(s.choices.items.length, 3);
  assert.equal(s.choices.recommended, 2);
});

test('state: 시스템 줄만 뒤에 있으면 여전히 open', () => {
  const s = choiceState([agent('b'), { key: 'sys-1', kind: 'system', body: '알림' }], 0);
  assert.equal(s.state, 'open');
});

test('state: 바로 다음이 내 `N` 이면 answered([N]) + 라벨', () => {
  for (const reply of ['2', ' 2번 ', '2.', '2 번.']) {
    const s = choiceState([agent('b'), mine('c', reply)], 0);
    assert.equal(s.state, 'answered', reply);
    assert.deepEqual(s.numbers, [2]);
    assert.deepEqual(s.labels, ['롤백 (권장)']);
  }
});

test('state: 내 답이 여러 번호면 answered(오름차순 목록) + 라벨들(#624)', () => {
  for (const reply of ['1, 3', '3,1', '1 3', '1번, 3번', '3 → 1', '1/3/1']) {
    const s = choiceState([agent('b'), mine('c', reply)], 0);
    assert.equal(s.state, 'answered', reply);
    assert.deepEqual(s.numbers, [1, 3], reply);
    assert.deepEqual(s.labels, ['유지', '보류'], reply);
  }
  assert.equal(choiceState([agent('b'), mine('c', '1, 4')], 0), null);   // 하나라도 범위 밖이면 closed
  assert.equal(choiceState([agent('b'), mine('c', '1,')], 0), null);
});

test('state: 카드가 보낸 줄 형식(compose)이 다음 내 글이면 answered(#624)', () => {
  const open = choiceState([agent('b')], 0);
  const sent = composeChoice([3, 1], open.choices.items.map((it) => it.label));
  assert.equal(sent, '1. 유지\n3. 보류');
  const s = choiceState([agent('b'), mine('c', sent)], 0);
  assert.equal(s.state, 'answered');
  assert.deepEqual(s.numbers, [1, 3]);
  assert.deepEqual(s.labels, ['유지', '보류']);
  // 라벨 글은 비교하지 않는다 — 손으로 친 `2. 아무 말` 도 answered([2]).
  assert.deepEqual(choiceState([agent('b'), mine('c', '2. 아무 말')], 0)?.numbers, [2]);
  assert.equal(choiceState([agent('b'), mine('c', '1. 유지\n그리고 빨리요')], 0), null);
});

test('state: 범위 밖 번호·다른 글·남의 글·첨부는 closed(null)', () => {
  assert.equal(choiceState([agent('b'), mine('c', '4')], 0), null);
  assert.equal(choiceState([agent('b'), mine('c', '2번으로 할게')], 0), null);
  assert.equal(choiceState([agent('b'), other('c', '2')], 0), null);
  assert.equal(choiceState([agent('b'), { key: 'c', kind: 'attachment', isMe: true, body: '' }], 0), null);
});

test('state: 복호화 실패·시스템 줄은 건너뛴다(iOS 와 같다)', () => {
  assert.equal(choiceState([agent('b'), { key: 'c', kind: 'undecryptable', isMe: false, body: '' }], 0)?.state, 'open');
  assert.deepEqual(choiceState([agent('b'), { key: 's', kind: 'system', isMe: false, body: 'x' }, mine('c', '2')], 0)?.numbers, [2]);
});

test('state: 「바로 다음」만 본다 — 남의 글 뒤의 내 `N` 은 closed', () => {
  assert.equal(choiceState([agent('b'), other('c', '저는 1'), mine('d', '1')], 0), null);
});

test('state: 선택지 없는 글·사람 글·에이전트 첨부는 null', () => {
  assert.equal(choiceState([agent('b', '작업을 끝냈습니다.')], 0), null);
  assert.equal(choiceState([{ ...agent('b'), isAgent: false }], 0), null);
  assert.equal(choiceState([{ ...agent('b'), kind: 'attachment' }], 0), null);
  assert.equal(choiceState([], 0), null);
});

test('state: isMine 판정을 바꿔 끼울 수 있다(같은 사람의 다른 기기)', () => {
  const entries = [agent('b'), { key: 'c', kind: 'text', isAgent: false, isMe: false, sender: 'mom-iphone-1', body: '3' }];
  assert.equal(choiceState(entries, 0), null);
  const s = choiceState(entries, 0, (e) => e.sender?.startsWith('mom-'));
  assert.equal(s.state, 'answered');
  assert.deepEqual(s.numbers, [3]);
});

test('state: 같은 entry 의 본문이 바뀌면 다시 판정한다(메모 무효화)', () => {
  const e = agent('b');
  assert.equal(choiceState([e], 0).state, 'open');
  e.body = '끝났습니다.';
  assert.equal(choiceState([e], 0), null);
});

// ---- 배포 목록(build.sh)과 서비스 워커 프리캐시(sw-policy.js)에 빠지지 않았는지 ----

test('agent-choices.js 가 build.sh 배포 목록과 SHELL_ASSETS 에 있다', async () => {
  const { SHELL_ASSETS } = await import('../sw-policy.js');
  assert.ok(SHELL_ASSETS.includes('./agent-choices.js'));
  const build = readFileSync(new URL('../build.sh', import.meta.url), 'utf8');
  assert.match(build, /\sagent-choices\.js\s/);
});

// ---- 키보드 단축키(#629, 규격 §3.1) ----

test('공유 벡터 keys 가 실렸다', () => {
  assert.equal(vectors.keys.length, 18);
});

for (const v of vectors.keys) {
  test(`keys: ${v.name}`, () => {
    assert.deepEqual(choiceKeyAction(v.input, v.card), v.expected);
  });
}

const OPEN3 = {count: 3, selected: [], enabled: true};
const base = {key: 'digit', digit: null, alt: false, ctrl: false, meta: false, shift: false, composing: false};

test('keys: KeyboardEvent → 입력 — Mac ⌥+1(key ¡)도 code Digit1 로 숫자 1', () => {
  assert.deepEqual(choiceKeyInput({code: 'Digit1', key: '¡', altKey: true}), {...base, digit: 1, alt: true});
  assert.deepEqual(choiceKeyAction(choiceKeyInput({code: 'Digit1', key: '¡', altKey: true}), OPEN3), {action: 'toggle', number: 1});
});

test('keys: KeyboardEvent → 입력 — Numpad3 · Digit0/Numpad0 은 숫자가 아니다', () => {
  assert.deepEqual(choiceKeyInput({code: 'Numpad3', key: '3', altKey: true}), {...base, digit: 3, alt: true});
  assert.equal(choiceKeyInput({code: 'Digit0', key: 'º', altKey: true}).key, 'other');
  assert.equal(choiceKeyInput({code: 'Numpad0', key: '0', altKey: true}).key, 'other');
  assert.equal(choiceKeyInput({code: 'KeyA', key: '1', altKey: true}).key, 'other');   // key 가 '1' 이어도 code 로 본다
});

test('keys: KeyboardEvent → 입력 — Enter·NumpadEnter 는 enter, 수정키는 그대로', () => {
  assert.deepEqual(choiceKeyInput({code: 'Enter', key: 'Enter', altKey: true}), {...base, key: 'enter', alt: true});
  assert.equal(choiceKeyInput({code: 'NumpadEnter', key: 'Enter'}).key, 'enter');
  assert.deepEqual(choiceKeyInput({code: 'Digit2', key: '@', altKey: true, ctrlKey: true, metaKey: true, shiftKey: true}),
    {...base, digit: 2, alt: true, ctrl: true, meta: true, shift: true});
});

test('keys: KeyboardEvent → 입력 — isComposing / keyCode 229 는 조합 중(null)', () => {
  assert.equal(choiceKeyInput({code: 'Digit1', key: '1', altKey: true, isComposing: true}).composing, true);
  assert.equal(choiceKeyInput({code: 'Digit1', key: 'Process', altKey: true, keyCode: 229}).composing, true);
  assert.equal(choiceKeyAction(choiceKeyInput({code: 'Digit1', key: '1', altKey: true, keyCode: 229}), OPEN3), null);
  assert.equal(choiceKeyInput({}).key, 'other');
});

/** document 캡처 단계 리스너를 흉내 낸다 — 캡처 리스너가 stopPropagation 하면 대상(작성창)·버블 리스너는 돌지 않는다. */
function fakeDoc() {
  const listeners = [];
  return {
    listeners,
    defaultView: null, activeElement: null,
    addEventListener: (type, fn, capture) => listeners.push({type, fn, capture: Boolean(capture)}),
    removeEventListener: (type, fn, capture) => {
      const i = listeners.findIndex((l) => l.type === type && l.fn === fn && l.capture === Boolean(capture));
      if (i >= 0) listeners.splice(i, 1);
    },
    dispatch(init, targetHandler) {
      const event = {defaultPrevented: false, stopped: false, target: {tagName: 'TEXTAREA'}, ...init,
        preventDefault() { this.defaultPrevented = true; }, stopPropagation() { this.stopped = true; }};
      for (const l of listeners.filter((x) => x.type === 'keydown' && x.capture)) { l.fn(event); if (event.stopped) return event; }
      targetHandler?.(event);
      if (event.stopped) return event;
      for (const l of listeners.filter((x) => x.type === 'keydown' && !x.capture)) l.fn(event);
      return event;
    },
  };
}

function shortcutHarness({card = {count: 3, selected: [], enabled: true}, roomId = 'r1'} = {}) {
  const doc = fakeDoc();
  const root = {ownerDocument: doc, querySelector: () => null, querySelectorAll: () => []};
  const calls = [];
  const state = {card};
  const uninstall = installShortcuts(root, {
    document: doc, matchMedia: () => ({matches: false}),
    openRoom: () => {}, openRooms: () => {}, currentRoomId: () => roomId,
    openChoiceCard: () => (state.card ? {
      card: () => state.card,
      toggle: (n) => calls.push(['toggle', n]),
      submit: () => calls.push(['send']),
    } : null),
  });
  // 작성창(ui.js buildComposer)의 Enter 전송 — defaultPrevented 면 건너뛴다.
  const composer = (event) => {
    if (event.defaultPrevented || event.key !== 'Enter' || event.shiftKey || event.isComposing || event.keyCode === 229) return;
    event.preventDefault();
    calls.push(['composer-send']);
  };
  return {doc, calls, state, uninstall, press: (init) => doc.dispatch(init, composer)};
}

test('shortcuts: ⌥1 은 카드 토글 — preventDefault, 작성창으로 가지 않는다', () => {
  const h = shortcutHarness();
  const event = h.press({key: '¡', code: 'Digit1', altKey: true});
  assert.deepEqual(h.calls, [['toggle', 1]]);
  assert.equal(event.defaultPrevented, true);
});

test('shortcuts: ⌥Enter(체크 있음)는 카드 보내기만 — 작성창 Enter 전송은 돌지 않는다', () => {
  const h = shortcutHarness({card: {count: 3, selected: [2], enabled: true}});
  const event = h.press({key: 'Enter', code: 'Enter', altKey: true});
  assert.deepEqual(h.calls, [['send']]);
  assert.equal(event.defaultPrevented, true);
});

test('shortcuts: ⌥Enter(체크 없음)·Enter·⌥4(k=3)·카드 없음은 가로채지 않는다(기존 동작)', () => {
  const h = shortcutHarness();
  assert.equal(h.press({key: 'Enter', code: 'Enter', altKey: true}).defaultPrevented, true);   // 작성창이 평소처럼 보냄
  assert.deepEqual(h.calls, [['composer-send']]);
  h.calls.length = 0;
  h.press({key: 'Enter', code: 'Enter'});
  assert.deepEqual(h.calls, [['composer-send']]);
  h.calls.length = 0;
  assert.equal(h.press({key: '¢', code: 'Digit4', altKey: true}).defaultPrevented, false);
  h.state.card = null;
  assert.equal(h.press({key: '¡', code: 'Digit1', altKey: true}).defaultPrevented, false);
  assert.deepEqual(h.calls, []);
});

test('shortcuts: 조합 중·AltGr(Ctrl+Alt)·잠긴 카드·방 없음은 가로채지 않는다', () => {
  const h = shortcutHarness();
  assert.equal(h.press({key: '1', code: 'Digit1', altKey: true, isComposing: true}).defaultPrevented, false);
  assert.equal(h.press({key: '1', code: 'Digit1', altKey: true, ctrlKey: true}).defaultPrevented, false);
  h.state.card = {count: 3, selected: [1], enabled: false};
  assert.equal(h.press({key: '1', code: 'Digit1', altKey: true}).defaultPrevented, false);
  assert.deepEqual(h.calls, []);
  const none = shortcutHarness({roomId: null});
  assert.equal(none.press({key: '1', code: 'Digit1', altKey: true}).defaultPrevented, false);
  assert.deepEqual(none.calls, []);
});

test('shortcuts: 해제하면 캡처 리스너도 떨어진다', () => {
  const h = shortcutHarness();
  assert.ok(h.doc.listeners.some((l) => l.capture));
  h.uninstall();
  assert.equal(h.doc.listeners.length, 0);
});
