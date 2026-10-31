// agent-choices-v1 (family-messenger#620, archive/native-mls/AGENT-CHOICES-V1.md) — 에이전트 선택지 탭 선택.
//
// 에이전트 글이 `1. … 2. … 3. …` 선택지로 끝나면 말풍선 아래에 선택 카드를 그린다. 보내는 것은 손으로 치는 것과
// 똑같은 텍스트다 — 카드는 줄마다 `N. 라벨`(복수 선택 #624)을 보내고, 손으로 친 `1`·`1, 3` 도 같은 답이 된다(와이어 변경 없음). 상태(open / answered / closed)는 타임라인에서 매번 계산하고 저장하지 않는다.
// 판정 규칙은 세 앱 공통 — 공유 벡터 archive/native-mls/tests/fixtures/agent-choices-vectors.json 과 같아야 한다.
// 정규식의 숫자는 ASCII [0-9] 만, 공백은 스페이스·탭·줄바꿈만(규격 §1 — JS \s 의 유니코드 공백과 다르게 보지 않게 명시).
//
// 순수 함수(DOM 없음) — node --test 로 검증한다.

const ITEM = /^ {0,3}([0-9]{1,2})[.)][ \t]+([^ \t\n][^\n]*)$/;
const FENCE = /^[ \t]*```/;
const BLANK = /^[ \t]*$/;
const INDENTED = /^( {2,}|\t)/;
const RECOMMENDED = /권장[ \t\n]*[:：]?[ \t\n]*([0-9]{1,2})[ \t\n]*번/;
const CUES = ['?', '？', '권장', '선택', '골라', '고르', '답해', '원하시', '할까요', '하시겠', '정해', '다음 액션', '다음 단계', '옵션', 'choose', 'option', 'recommend'];

export const MIN_ITEMS = 2;
export const MAX_ITEMS = 9;
export const MAX_TRAILING = 3;

const hasCue = (line) => {
  const lower = line.toLowerCase();   // 영문만 대소문자 무시(한글·기호는 그대로)
  return CUES.some((cue) => lower.includes(cue));
};

/** 라벨: `**`·`__`·`` ` `` 를 지우고 연속 공백을 한 칸으로, 양끝 공백 제거. */
function cleanLabel(raw) {
  return raw.replaceAll('**', '').replaceAll('__', '').replaceAll('`', '').replace(/[ \t\n]+/g, ' ').replace(/^ | $/g, '');
}

/**
 * 에이전트 글 본문에서 끝의 선택지를 찾는다(규격 §1).
 * @param {string} text
 * @returns {null | {items: {number: number, label: string}[], recommended: number | null}}
 */
export function parseChoices(text) {
  if (typeof text !== 'string' || text.length === 0) return null;
  const source = text.replace(/\r\n/g, '\n');
  const lines = source.split('\n');
  let block = null;   // {items:[{number, label}], start, end, open, invalid}
  let fenced = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (FENCE.test(line)) {
      fenced = !fenced;
      if (block) block.open = false;   // 펜스 줄 = 일반 줄
      continue;
    }
    if (fenced) { if (block) block.open = false; continue; }   // 펜스 안 = 항목이 될 수 없는 일반 줄
    const item = ITEM.exec(line);
    if (item) {
      const number = Number.parseInt(item[1], 10);
      const label = cleanLabel(item[2]);
      if (number === 1) block = {items: [{number, label}], start: i, end: i, open: true, invalid: false};
      else if (block && block.open && !block.invalid && number === block.items.at(-1).number + 1) { block.items.push({number, label}); block.end = i; }
      else if (block) { block.invalid = true; block.open = false; }   // 뒤에 `1` 이 오면 다시 시작
      continue;
    }
    if (BLANK.test(line)) continue;
    if (INDENTED.test(line)) { if (block && block.open) block.end = i; continue; }   // 이어지는 줄(라벨엔 넣지 않는다)
    if (block) block.open = false;
  }
  if (!block || block.invalid) return null;
  const count = block.items.length;
  if (count < MIN_ITEMS || count > MAX_ITEMS) return null;
  const trailing = lines.slice(block.end + 1).filter((line) => !BLANK.test(line));
  if (trailing.length > MAX_TRAILING) return null;
  let above = null;
  for (let i = block.start - 1; i >= 0; i--) if (!BLANK.test(lines[i])) { above = lines[i]; break; }
  const cued = (above !== null && hasCue(above)) || trailing.some(hasCue) || block.items.some((it) => hasCue(it.label));
  if (!cued) return null;
  let recommended = null;
  const named = RECOMMENDED.exec(source);   // 메시지 전체(펜스 포함)의 첫 일치만
  const n = named ? Number.parseInt(named[1], 10) : 0;
  if (n >= 1 && n <= count) recommended = n;
  else recommended = block.items.find((it) => it.label.includes('권장'))?.number ?? null;
  return {items: block.items, recommended};
}

const isDigit = (ch) => ch >= '0' && ch <= '9';   // ASCII 만 — 전각 `１` 은 숫자가 아니다
const isGap = (ch) => ch === ' ' || ch === '\t';
const SEPARATORS = ['->', ',', '，', '、', '/', '+', '→'];   // 두 글자 `->` 를 먼저 본다

/**
 * 답 판정 A. 번호 나열(규격 §2 「답 판정」, #624) — 정규식 대신 차례로 읽는다.
 *   1. 양끝 스페이스·탭·\r·\n 제거 → 끝이 `.` 이면 하나만 지우고 오른쪽 공백 다시 제거 → 빈 글이면 null.
 *   2. 번호: ASCII 숫자 1~2자(3자 이상 null). 뒤에 (스페이스·탭* +) `번` 이 있을 때만 거기까지 소비.
 *   3. 끝이면 끝. 아니면 구분자: 공백* + (, ， 、 / + → ->)? + 공백* — 한 글자도 못 먹었거나 뒤가 끝이면 null. 2로.
 *   4. 모든 번호 ∈ 1..count, 결과는 오름차순·중복 제거.
 * @returns {number[] | null}
 */
function numberListReply(text, count) {
  let s = text.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, '');
  if (s.endsWith('.')) s = s.slice(0, -1).replace(/[ \t\r\n]+$/, '');
  if (s.length === 0) return null;
  const numbers = [];
  let i = 0;
  for (;;) {
    // 2. 번호
    let j = i;
    while (j < s.length && isDigit(s[j])) j++;
    if (j === i || j - i > 2) return null;
    numbers.push(Number.parseInt(s.slice(i, j), 10));
    i = j;
    let k = i;
    while (k < s.length && isGap(s[k])) k++;
    if (s[k] === '번') i = k + 1;   // `번` 이 없으면 공백은 구분자 몫으로 남긴다
    // 3. 끝 또는 구분자
    if (i === s.length) break;
    const from = i;
    while (i < s.length && isGap(s[i])) i++;
    const sep = SEPARATORS.find((m) => s.startsWith(m, i));
    if (sep) i += sep.length;
    while (i < s.length && isGap(s[i])) i++;
    if (i === from || i === s.length) return null;
  }
  // 4. 범위·정렬·중복 제거
  if (numbers.some((n) => n < 1 || n > count)) return null;
  return [...new Set(numbers)].sort((a, b) => a - b);
}

/**
 * 답 판정 B. 줄 형식: 공백뿐인 줄을 버리고 남은 줄이 모두 §1 항목 줄이어야 한다(라벨 글은 비교하지 않는다).
 * 번호가 모두 1..count → 오름차순·중복 제거.
 */
function lineFormReply(text, count) {
  const lines = text.replace(/\r\n/g, '\n').split('\n').filter((line) => !BLANK.test(line));
  if (lines.length === 0) return null;
  const numbers = [];
  for (const line of lines) {
    const item = ITEM.exec(line);
    if (!item) return null;
    numbers.push(Number.parseInt(item[1], 10));
  }
  if (numbers.some((n) => n < 1 || n > count)) return null;
  return [...new Set(numbers)].sort((a, b) => a - b);
}

/**
 * 내 답이 고른 번호 목록인가(규격 §2 「답 판정」): A. 번호 나열(`1`·`1, 3`)을 먼저, null 이면 B. 줄 형식(`1. 라벨` 줄들).
 * @returns {number[] | null} 오름차순·중복 없는 번호 목록
 */
export function choiceReply(text, count) {
  if (typeof text !== 'string') return null;
  return numberListReply(text, count) ?? lineFormReply(text, count);
}

export const EMPTY_LABEL = '(내용 없음)';

/**
 * 보낼 글(규격 §2 compose): 고른 번호 → 오름차순·중복 제거 후 줄마다 `N. 라벨` 을 `\n` 으로 잇는다.
 * labels 는 choices.items 의 라벨(§1.6 정리된 라벨, 번호 n → labels[n-1]). 빈 라벨은 `N. (내용 없음)`.
 * 이 글은 답 판정 B 로 다시 같은 번호 집합이 된다(왕복).
 */
export function composeChoice(numbers, labels) {
  return [...new Set(Array.from(numbers ?? [], Number))].sort((a, b) => a - b)
    .map((n) => { const label = labels?.[n - 1]; return `${n}. ${typeof label === 'string' && label !== '' ? label : EMPTY_LABEL}`; })
    .join('\n');
}

const parsed = new WeakMap();   // entry → {body, choices}: 재렌더마다 같은 글을 다시 훑지 않게
function choicesOf(entry) {
  const hit = parsed.get(entry);
  if (hit && hit.body === entry.body) return hit.choices;
  const choices = parseChoices(entry.body);
  parsed.set(entry, {body: entry.body, choices});
  return choices;
}

/** 상태 판정에 세는 「저장된 메시지」 — 시스템 줄은 뺀다(status-v1 임시 줄은 entries 밖이라 애초에 없다). */
// 규격 §2 「저장된 메시지(텍스트·첨부)」 — 시스템 줄·복호화 실패 줄은 건너뛴다(iOS AgentChoices.cards 와 같다).
const isStoredMessage = (e) => e != null && (e.kind === 'text' || e.kind === 'attachment');

/**
 * 타임라인 entries[index] 의 선택지 상태(규격 §2).
 *   null                                   — 에이전트 텍스트가 아니거나 선택지가 없거나 `closed`(카드 없음)
 *   {state: 'open', choices}               — 뒤에 메시지가 없다 → 선택 카드
 *   {state: 'answered', numbers, labels, choices} — 바로 다음 메시지가 내 답(번호 목록, #624)
 *                                          → 한 줄 「✓ N번 선택 — 라벨」 / 「✓ 1, 3번 선택 — 라벨1 · 라벨3」
 * @param {{key:string, kind:string, body:string, isAgent:boolean, isMe:boolean}[]} entries app.js R.entries
 * @param {number} index
 * @param {(entry) => boolean} [isMine] 「내 것」 판정 — 기본은 app.js 가 계산해 둔 entry.isMe(같은 사람의 다른 기기 포함)
 */
export function choiceState(entries, index, isMine = (e) => Boolean(e?.isMe)) {
  const entry = entries?.[index];
  if (!entry || !entry.isAgent || entry.kind !== 'text') return null;
  let next = null;
  for (let j = index + 1; j < entries.length; j++) if (isStoredMessage(entries[j])) { next = entries[j]; break; }
  // 뒤에 남의 글·첨부가 있으면 무조건 closed — 선택지를 훑을 필요도 없다.
  if (next && !(next.kind === 'text' && isMine(next))) return null;
  const choices = choicesOf(entry);
  if (!choices) return null;
  if (!next) return {state: 'open', choices};
  const numbers = choiceReply(next.body, choices.items.length);
  if (numbers === null) return null;
  return {state: 'answered', numbers, labels: numbers.map((n) => choices.items[n - 1].label), choices};
}

// ---- 키보드 단축키(#629, 규격 §3.1) — 공유 벡터 `keys` ----

/**
 * 웹 KeyboardEvent → 판정 입력. 숫자는 `event.code`(Digit1~9·Numpad1~9)로 본다 — Mac ⌥+1 의 `event.key` 는 `¡` 다.
 * Enter 는 `event.key === 'Enter'`(Numpad Enter 포함). IME 조합 = isComposing 또는 keyCode 229.
 * @param {{code?: string, key?: string, altKey?: boolean, ctrlKey?: boolean, metaKey?: boolean, shiftKey?: boolean, isComposing?: boolean, keyCode?: number}} event
 * @returns {{key: 'digit'|'enter'|'other', digit: number|null, alt: boolean, ctrl: boolean, meta: boolean, shift: boolean, composing: boolean}}
 */
export function choiceKeyInput(event = {}) {
  const match = /^(?:Digit|Numpad)([1-9])$/.exec(event.code ?? '');
  const key = match ? 'digit' : event.key === 'Enter' ? 'enter' : 'other';
  return {
    key, digit: match ? Number(match[1]) : null,
    alt: Boolean(event.altKey), ctrl: Boolean(event.ctrlKey), meta: Boolean(event.metaKey), shift: Boolean(event.shiftKey),
    composing: Boolean(event.isComposing) || event.keyCode === 229,
  };
}

/**
 * 열린 선택지 카드에 대한 단축키 판정(규격 §3.1). Alt 만(Ctrl·⌘·Shift 없이), 조합 중이 아니고, 카드가 활성일 때만:
 *   Alt+N(1..k) → {action:'toggle', number:N} · Alt+Enter(체크 ≥1) → {action:'send'} · 그 밖 → null(가로채지 않음).
 * @param {{key: string, digit?: number|null, alt?: boolean, ctrl?: boolean, meta?: boolean, shift?: boolean, composing?: boolean}} input
 * @param {null | {count: number, selected: number[], enabled: boolean}} card 방의 open 카드(없으면 null)
 * @returns {null | {action: 'toggle', number: number} | {action: 'send'}}
 */
export function choiceKeyAction(input, card) {
  if (!input || !card || !card.enabled) return null;
  if (!input.alt || input.ctrl || input.meta || input.shift || input.composing) return null;
  if (input.key === 'digit') {
    const n = input.digit;
    return Number.isInteger(n) && n >= 1 && n <= 9 && n <= card.count ? {action: 'toggle', number: n} : null;
  }
  if (input.key === 'enter') return (card.selected?.length ?? 0) > 0 ? {action: 'send'} : null;
  return null;
}
