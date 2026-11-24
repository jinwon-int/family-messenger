// 순수 파서 테스트(node:test, DOM 없음): node --test archive/native-mls/web/hande/tests/agent-markdown.test.mjs
// 앞 다섯 개는 iOS AgentConversationTests.swift 의 AgentMarkdownTests 를 그대로 옮긴 것 — 두 화면이 같은 글을 같게 나눈다.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseBlocks, inlineSpans, hasMarkdown, MAX_ROWS, MAX_SOURCE } from '../agent-markdown.js';

const P = (text) => ({ type: 'paragraph', text });

test('iOS 동등: 봇 상태 답장 → 문단·표·목록', () => {
  const body = [
    '방 상태를 확인했는데, **`test-rs`라는 방이 없습니다.**',
    '',
    '**확인한 내용** (`room_status`)',
    '| 방 | 모드 | joined |',
    '|---|---|:---:|',
    '| `family` | silent | ✅ |',
    '| `family-acc` | agent | ✅ |',
    '',
    '- 봇이 알고 있는 방은 이 두 개뿐입니다.',
    '- `family-acc`를 말씀하신 것일 수도 있지만',
    '  짐작으로 바꾸지는 않았습니다.',
    '',
    '1. **`family-acc`를 silent로 바꾸기** — 권장',
    '2. 그대로 두기',
  ].join('\n');
  const blocks = parseBlocks(body);
  assert.equal(blocks.length, 5);
  assert.deepEqual(blocks[0], P('방 상태를 확인했는데, **`test-rs`라는 방이 없습니다.**'));
  assert.deepEqual(blocks[1], P('**확인한 내용** (`room_status`)'));
  assert.deepEqual(blocks[2], { type: 'table', header: ['방', '모드', 'joined'], rows: [['`family`', 'silent', '✅'], ['`family-acc`', 'agent', '✅']] });
  assert.equal(blocks[3].type, 'list');
  assert.equal(blocks[3].items.length, 2);
  assert.equal(blocks[3].items[0].marker, null);
  assert.equal(blocks[3].items[1].text, '`family-acc`를 말씀하신 것일 수도 있지만\n짐작으로 바꾸지는 않았습니다.');
  assert.deepEqual(blocks[4].items.map((item) => item.marker), ['1.', '2.']);
});

test('iOS 동등: 앞뒤 문단과 붙은 표', () => {
  assert.deepEqual(parseBlocks('요약\n| a | b |\n|---|---|\n| 1 | 2 |\n끝'),
    [P('요약'), { type: 'table', header: ['a', 'b'], rows: [['1', '2']] }, P('끝')]);
});

test('iOS 동등: 들쭉날쭉·너무 긴 표는 머리 폭에 맞추고 60행에서 자른다', () => {
  const long = Array.from({ length: 70 }, (_, n) => `| r${n} |`).join('\n');
  const [table] = parseBlocks(`| a | b |\n|---|---|\n| only |\n| x | y | z |\n${long}`);
  assert.deepEqual(table.header, ['a', 'b']);
  assert.deepEqual(table.rows[0], ['only', '']);
  assert.deepEqual(table.rows[1], ['x', 'y']);
  assert.equal(table.rows.length, MAX_ROWS + 1);
  assert.deepEqual(table.rows.at(-1), ['…', '']);
});

test('iOS 동등: 코드·제목·인용·구분선, #해시태그는 제목 아님', () => {
  assert.deepEqual(parseBlocks('# 제목\n## 소제목\n```sh\nls -la\n| not | a table |\n```\n> 인용\n> 둘째 줄\n---\n#해시태그'), [
    { type: 'heading', level: 1, text: '제목' }, { type: 'heading', level: 2, text: '소제목' },
    { type: 'code', text: 'ls -la\n| not | a table |' }, { type: 'quote', text: '인용\n둘째 줄' }, { type: 'rule' }, P('#해시태그'),
  ]);
});

test('iOS 동등: 안 닫힌 울타리·평문·빈 글은 안전하게', () => {
  assert.deepEqual(parseBlocks('```\nopen'), [{ type: 'code', text: 'open' }]);
  assert.deepEqual(parseBlocks('그냥 한 줄'), [P('그냥 한 줄')]);
  assert.deepEqual(parseBlocks(''), []);
  assert.deepEqual(parseBlocks('a | b 는 표가 아니다'), [P('a | b 는 표가 아니다')]);
  assert.deepEqual(parseBlocks('**굵게**만'), [P('**굵게**만')]);
});

test('목록: 들여쓰기 깊이·번호 표시·4자리 숫자는 목록 아님', () => {
  const [list] = parseBlocks('- 하나\n  - 둘\n\t- 셋\n3) 넷');
  assert.deepEqual(list.items, [
    { level: 0, marker: null, text: '하나' }, { level: 1, marker: null, text: '둘' },
    { level: 2, marker: null, text: '셋' }, { level: 0, marker: '3)', text: '넷' },
  ]);
  assert.deepEqual(parseBlocks('2026. 10. 20.'), [P('2026. 10. 20.')]);
  assert.deepEqual(parseBlocks('-하이픈 붙임'), [P('-하이픈 붙임')]);
});

test('표 칸 안의 \\| 는 글자', () => {
  const [table] = parseBlocks('| 식 | 뜻 |\n|---|---|\n| a \\| b | 또는 |');
  assert.deepEqual(table.rows, [['a | b', '또는']]);
});

test('CRLF 줄바꿈도 같게 나눈다', () => {
  assert.deepEqual(parseBlocks('# 제목\r\n본문'), [{ type: 'heading', level: 1, text: '제목' }, P('본문')]);
});

test('줄 안 서식: 코드·굵게·기울임·취소선', () => {
  assert.deepEqual(inlineSpans('a **b** `c` *d* ~~e~~ __f__'), [
    { style: 'text', text: 'a ' }, { style: 'strong', text: 'b' }, { style: 'text', text: ' ' },
    { style: 'code', text: 'c' }, { style: 'text', text: ' ' }, { style: 'em', text: 'd' },
    { style: 'text', text: ' ' }, { style: 'del', text: 'e' }, { style: 'text', text: ' ' }, { style: 'strong', text: 'f' },
  ]);
  // 코드 안은 해석하지 않는다. 겹친 서식은 바깥 한 겹만 나오고, 안쪽은 같은 함수로 다시 나뉜다(ui.js inlineNodes).
  assert.deepEqual(inlineSpans('`**x**`'), [{ style: 'code', text: '**x**' }]);
  const [outer] = inlineSpans('**`test-rs`라는 방이 없습니다.**');
  assert.deepEqual(outer, { style: 'strong', text: '`test-rs`라는 방이 없습니다.' });
  assert.deepEqual(inlineSpans(outer.text), [{ style: 'code', text: 'test-rs' }, { style: 'text', text: '라는 방이 없습니다.' }]);
  assert.deepEqual(inlineSpans('`` a`b ``'), [{ style: 'code', text: 'a`b' }]);
});

test('줄 안 서식: 짝 없는 기호·snake_case·곱셈은 글자 그대로', () => {
  for (const plain of ['2 * 3 * 4', 'file_name_here', '**열기만', '별표 하나 *', '`닫힘없음', '~~ 공백 ~~', '__init__.py']) {
    const spans = inlineSpans(plain);
    if (plain === '__init__.py') { assert.deepEqual(spans, [{ style: 'strong', text: 'init' }, { style: 'text', text: '.py' }]); continue; }
    assert.deepEqual(spans, [{ style: 'text', text: plain }], plain);
  }
  assert.deepEqual(inlineSpans(''), []);
});

test('hasMarkdown: 평범한 대화는 그대로 평문, 서식이 있으면 블록으로', () => {
  for (const plain of ['안녕하세요', '두 줄\n대화', '2 * 3 = 6', 'a | b', '', null, undefined, 42]) assert.equal(hasMarkdown(plain), false, String(plain));
  for (const md of ['**굵게**', '- 목록', '# 제목', '```\ncode\n```', '`x`', '| a |\n|---|']) assert.equal(hasMarkdown(md), true, md);
  assert.equal(hasMarkdown(`**x** ${'a'.repeat(MAX_SOURCE)}`), false);
});

test('받은 HTML·링크·이미지 문법은 해석 없이 문자열로만 돌아온다', () => {
  const hostile = '<img src=x onerror=alert(1)> [눌러](javascript:alert(1)) ![p](https://evil/x.png) <script>x</script>';
  assert.deepEqual(parseBlocks(hostile), [P(hostile)]);
  const spans = inlineSpans(`**${hostile}**`);
  assert.deepEqual(spans, [{ style: 'strong', text: hostile }]);
  // 미리 이스케이프하지 않는다(ui.js 가 텍스트 노드로 넣으므로 이중 이스케이프가 된다).
  assert.deepEqual(parseBlocks('# <b>t</b>\n| <i>h</i> |\n|---|\n| <u>c</u> |'), [
    { type: 'heading', level: 1, text: '<b>t</b>' }, { type: 'table', header: ['<i>h</i>'], rows: [['<u>c</u>']] },
  ]);
  // ui.js 는 span.style 을 태그 이름으로 쓴다 — 허용 목록 밖의 값이 나오면 안 된다.
  const allowed = new Set(['text', 'code', 'strong', 'em', 'del', 'link']);
  for (const span of inlineSpans('*a* **b** `c` ~~d~~ __e__ [f](https://a.example) x')) assert.ok(allowed.has(span.style), span.style);
  // 링크 문법은 http(s) 주소일 때만 'link' — javascript: 와 이미지 문법은 글자 그대로.
  assert.ok(inlineSpans(hostile).every((span) => span.style === 'text'));
});

test('링크 문법 [글자](http(s)://…) → link 조각(오너 2026-11-16 — 에이전트 주소는 어떤 호스트든 링크)', () => {
  assert.deepEqual(inlineSpans('[#825](https://github.com/jinwon-int/family-messenger/pull/825) 머지'), [
    { style: 'link', text: '#825', href: 'https://github.com/jinwon-int/family-messenger/pull/825' },
    { style: 'text', text: ' 머지' },
  ]);
  assert.deepEqual(inlineSpans('[위키](https://ko.wikipedia.org/wiki/Foo_(bar))'), [
    { style: 'link', text: '위키', href: 'https://ko.wikipedia.org/wiki/Foo_(bar)' },
  ]);
  assert.deepEqual(inlineSpans('[id](https://id@a.example/x)'), [{ style: 'link', text: 'id', href: 'https://id@a.example/x' }]);
  assert.deepEqual(inlineSpans('[내부](http://100.64.0.1:8080/x)'), [{ style: 'link', text: '내부', href: 'http://100.64.0.1:8080/x' }]);
  for (const plain of ['[a](javascript:alert(1))', '![p](https://a.example/x.png)', '[a](/relative)', '[](https://a.example)']) {
    assert.ok(inlineSpans(plain).every((span) => span.style === 'text'), plain);
  }
  assert.equal(hasMarkdown('보기 [여기](https://a.example)'), true);
  assert.equal(hasMarkdown('그냥 https://a.example 주소'), false);
});

// #834: 답 끝 스킬 줄 → 칩. 봇(responder.rs skills_footer)·iOS(AgentSkills.swift)와 같은 규칙.
import {splitSkills, MAX_SKILLS} from '../agent-markdown.js';

test('splitSkills: 빈 줄 뒤 마지막 `📘 a · b` 줄만 떼어 칩 목록으로', () => {
  assert.deepEqual(splitSkills('답입니다.\n\n📘 gh-pr-flow · wiki-record'), {body: '답입니다.', skills: ['gh-pr-flow', 'wiki-record']});
  assert.deepEqual(splitSkills('## 제목\n- 항목\n\n📘 plugin:skill\n'), {body: '## 제목\n- 항목', skills: ['plugin:skill']});
  // 선택지 블록 뒤에 붙어도 블록은 본문에 그대로 남는다.
  const choice = '**[답변 필요]** 하나만 선택\n1. (권장) 진행\n2. 보류';
  assert.equal(splitSkills(`${choice}\n\n📘 gh-pr-flow`).body, choice);
});

test('splitSkills: 규칙 밖이면 글 그대로(skills 빈 배열)', () => {
  for (const text of [
    '답\n📘 gh-pr-flow',                 // 빈 줄 없이 바로 붙음
    '📘 gh-pr-flow',                      // 본문 없음
    '답\n\n📘 gh-pr-flow\n\n덧붙임',      // 마지막 줄이 아님
    '답\n\n📘 bad name',                  // 공백 든 이름
    '답\n\n📘 a, b',                       // 구분자가 ` · ` 가 아님
    '답\n\n📘 ',                          // 이름 없음
    `답\n\n📘 ${Array.from({length: MAX_SKILLS + 1}, (_, i) => `s${i}`).join(' · ')}`,
    '답\n\n📘 ' + 'x'.repeat(65),
  ]) assert.deepEqual(splitSkills(text), {body: text, skills: []}, text);
  assert.deepEqual(splitSkills(undefined), {body: '', skills: []});
});

// #887: 웹·Android 공유 벡터(archive/native-mls/tests/fixtures/agent-markdown-vectors.json) — Android `AgentMarkdownTest` 가 같은 파일을 돌린다.
// 벡터의 blocks·spans 는 이 파일 함수들의 반환값 그대로다. 규칙을 바꾸면 벡터도 함께 고쳐 두 앱이 같이 따라오게 한다.
import { readFileSync } from 'node:fs';
import { MAX_COLUMNS } from '../agent-markdown.js';

const vectors = JSON.parse(readFileSync(new URL('../../../tests/fixtures/agent-markdown-vectors.json', import.meta.url), 'utf8'));

test('공유 벡터: 상한(열·행·글 길이)', () => {
  assert.deepEqual(vectors.limits, { max_columns: MAX_COLUMNS, max_rows: MAX_ROWS, max_source: MAX_SOURCE });
});

test('공유 벡터: parseBlocks', () => {
  assert.ok(vectors.blocks.length >= 30);
  for (const c of vectors.blocks) assert.deepEqual(parseBlocks(c.text), c.blocks, c.name);
});

test('공유 벡터: inlineSpans', () => {
  assert.ok(vectors.inline.length >= 30);
  for (const c of vectors.inline) assert.deepEqual(inlineSpans(c.text), c.spans, c.name);
});

test('공유 벡터: hasMarkdown', () => {
  assert.ok(vectors.has_markdown.length >= 15);
  for (const c of vectors.has_markdown) assert.equal(hasMarkdown(c.text), c.expected, c.name);
});
