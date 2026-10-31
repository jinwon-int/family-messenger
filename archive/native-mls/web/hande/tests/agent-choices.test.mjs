// agent-choices-v1(#620) 테스트: node --test archive/native-mls/web/hande/tests/agent-choices.test.mjs
// 판정은 세 앱 공유 벡터(archive/native-mls/tests/fixtures/agent-choices-vectors.json)를 그대로 돌린다.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseChoices, choiceReply, composeChoice, choiceState } from '../agent-choices.js';

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
  test(`compose: ${JSON.stringify(v.numbers)}`, () => {
    assert.equal(composeChoice(v.numbers), v.expected);
  });
}

test('reply: compose 결과는 다시 같은 번호로 읽힌다(왕복)', () => {
  for (const v of vectors.compose) assert.deepEqual(choiceReply(composeChoice(v.numbers), 3), [...new Set(v.numbers)].sort((a, b) => a - b));
});

test('reply: 문자열이 아니거나 공백·점뿐이면 null', () => {
  assert.equal(choiceReply(null, 3), null);
  assert.equal(choiceReply('', 3), null);
  assert.equal(choiceReply(' . ', 3), null);
  assert.equal(choiceReply('1..', 3), null);   // 끝 `.` 은 하나만 지운다
  assert.equal(choiceReply('1 -2', 3), null);
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
