// 에이전트 답장의 마크다운 → 블록·줄 안 조각. 순수 함수(DOM 없음, node --test).
// 블록 규칙은 iOS FamilyMLSCore/Agent/AgentMarkdown.swift(#405 P1)를 그대로 옮겼다 — 두 화면이 같은 글을 같게 나눈다.
// 받은 글은 신뢰하지 않는다: 여기서는 문자열만 돌려주고, 화면(ui.js)이 텍스트 노드로만 넣는다(HTML 해석 없음).
// 링크·이미지 문법은 iOS 와 같이 이동·원격 로드 없이 글자 그대로 둔다.

/** 표가 아무리 길어도 화면이 감당할 만큼만(열 8 · 행 60). 넘치는 행은 버리고 끝에 "…" 행을 둔다. */
export const MAX_COLUMNS = 8;
export const MAX_ROWS = 60;
/** 이보다 긴 글은 나누지 않고 평문으로 그린다(렌더 비용 상한). */
export const MAX_SOURCE = 100_000;

const isBlank = (ch) => ch === ' ' || ch === '\t';
const trimWs = (s) => s.replace(/^[ \t]+|[ \t]+$/g, '');

/**
 * @typedef {{type:'heading', level:number, text:string}
 *   | {type:'paragraph', text:string}
 *   | {type:'list', items:{level:number, marker:string|null, text:string}[]}
 *   | {type:'table', header:string[], rows:string[][]}
 *   | {type:'code', text:string}
 *   | {type:'quote', text:string}
 *   | {type:'rule'}} Block
 */

/** @returns {Block[]} */
export function parseBlocks(source) {
  const lines = String(source ?? '').replace(/\r\n/g, '\n').split('\n');
  /** @type {Block[]} */
  const blocks = [];
  let paragraph = [];
  let list = [];
  let quote = [];
  let i = 0;

  const flushParagraph = () => { if (paragraph.length) { blocks.push({ type: 'paragraph', text: paragraph.join('\n') }); paragraph = []; } };
  const flushList = () => { if (list.length) { blocks.push({ type: 'list', items: list }); list = []; } };
  const flushQuote = () => { if (quote.length) { blocks.push({ type: 'quote', text: quote.join('\n') }); quote = []; } };
  const flushAll = () => { flushParagraph(); flushList(); flushQuote(); };

  while (i < lines.length) {
    const line = lines[i];
    const trimmed = trimWs(line);

    // 코드 울타리: 닫는 ``` 까지(없으면 끝까지) 그대로.
    if (trimmed.startsWith('```')) {
      flushAll();
      const body = [];
      i += 1;
      while (i < lines.length && !trimWs(lines[i]).startsWith('```')) { body.push(lines[i]); i += 1; }
      blocks.push({ type: 'code', text: body.join('\n') });
      i += 1;
      continue;
    }
    if (trimmed === '') { flushAll(); i += 1; continue; }

    // 표: 이 줄에 `|` 가 있고 다음 줄이 구분선(|---|:--:|)이면.
    if (trimmed.includes('|') && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
      flushAll();
      const header = cells(trimmed).slice(0, MAX_COLUMNS);
      const rows = [];
      let truncated = false;
      i += 2;
      while (i < lines.length) {
        const row = trimWs(lines[i]);
        if (row === '' || !row.includes('|')) break;
        if (rows.length < MAX_ROWS) rows.push(normalize(cells(row), header.length)); else truncated = true;
        i += 1;
      }
      if (truncated) rows.push(normalize(['…'], header.length));
      blocks.push({ type: 'table', header, rows });
      continue;
    }
    const level = headingLevel(trimmed);
    if (level !== null) {
      flushAll();
      blocks.push({ type: 'heading', level, text: trimWs(trimmed.replace(/^#+/, '')) });
      i += 1;
      continue;
    }
    if (isRule(trimmed)) { flushAll(); blocks.push({ type: 'rule' }); i += 1; continue; }
    if (trimmed.startsWith('>')) {
      flushParagraph(); flushList();
      quote.push(trimWs(trimmed.slice(1)));
      i += 1;
      continue;
    }
    const item = listItem(line);
    if (item) {
      flushParagraph(); flushQuote();
      list.push(item);
      i += 1;
      continue;
    }
    // 목록 바로 뒤의 들여쓴 이어지는 줄은 앞 항목에 붙인다.
    if (list.length && isBlank(line[0])) {
      const last = list.pop();
      list.push({ ...last, text: `${last.text}\n${trimmed}` });
      i += 1;
      continue;
    }
    flushList(); flushQuote();
    paragraph.push(line);
    i += 1;
  }
  flushAll();
  return blocks;
}

/** 블록으로 나눌 가치가 있는가 — 평범한 대화(서식 없음)는 지금처럼 한 덩어리 평문으로 둔다. */
export function hasMarkdown(source) {
  if (typeof source !== 'string' || source.length === 0 || source.length > MAX_SOURCE) return false;
  const blocks = parseBlocks(source);
  if (blocks.some((block) => block.type !== 'paragraph')) return true;
  return blocks.some((block) => inlineSpans(block.text).some((span) => span.style !== 'text'));
}

export function cells(row) {
  let s = trimWs(row);
  if (s.startsWith('|')) s = s.slice(1);
  if (s.endsWith('|') && !s.endsWith('\\|')) s = s.slice(0, -1);
  // `\|` 는 칸 안의 글자.
  const placeholder = '\u0000';
  return s.split('\\|').join(placeholder).split('|').map((part) => trimWs(part.split(placeholder).join('|')));
}

export function normalize(row, width) {
  if (width <= 0) return row;
  if (row.length >= width) return row.slice(0, width);
  return [...row, ...Array(width - row.length).fill('')];
}

export function isTableSeparator(line) {
  const parts = cells(line);
  if (parts.length === 0) return false;
  return parts.every((part) => {
    let p = part;
    if (p.startsWith(':')) p = p.slice(1);
    if (p.endsWith(':')) p = p.slice(0, -1);
    return p.length >= 3 && /^-+$/.test(p);
  });
}

export function headingLevel(trimmed) {
  const hashes = /^#*/.exec(trimmed)[0].length;
  if (hashes < 1 || hashes > 6) return null;
  return trimmed[hashes] === ' ' ? hashes : null;
}

export function isRule(trimmed) {
  const compact = trimmed.split(' ').join('');
  if (compact.length < 3 || !'-*_'.includes(compact[0])) return false;
  return [...compact].every((ch) => ch === compact[0]);
}

export function listItem(line) {
  let indent = 0;
  let k = 0;
  while (k < line.length && isBlank(line[k])) { indent += line[k] === '\t' ? 4 : 1; k += 1; }
  const body = line.slice(k);
  const level = Math.min(Math.floor(indent / 2), 4);
  if (body.length > 1 && '-*•+'.includes(body[0]) && body[1] === ' ') {
    return { level, marker: null, text: trimWs(body.slice(2)) };
  }
  const digits = /^[0-9]{1,3}/.exec(body)?.[0] ?? '';
  if (digits && !/^[0-9]/.test(body.slice(digits.length))) {
    const p = body[digits.length];
    if ((p === '.' || p === ')') && body[digits.length + 1] === ' ') {
      return { level, marker: `${digits}${p}`, text: trimWs(body.slice(digits.length + 2)) };
    }
  }
  return null;
}

/**
 * 줄 안 서식: `코드` · 별표 둘 또는 밑줄 둘(굵게) · 별표 하나(기울임) · 물결 둘(취소선). 여기서는 바깥 한 겹만 나누고, 안쪽(코드 제외)은 화면이 같은 함수로 다시 나눈다.
 * 짝이 없는 기호는 글자 그대로 둔다. 밑줄 하나(_x_)는 snake_case 를 깨뜨리므로 다루지 않는다.
 * @returns {{style:'text'|'code'|'strong'|'em'|'del', text:string}[]}
 */
export function inlineSpans(text) {
  const source = String(text ?? '');
  const spans = [];
  let plain = '';
  const push = (style, value) => {
    if (style === 'text') { plain += value; return; }
    if (plain) { spans.push({ style: 'text', text: plain }); plain = ''; }
    spans.push({ style, text: value });
  };
  let i = 0;
  while (i < source.length) {
    const rest = source.slice(i);
    const match = inlineMatch(rest);
    if (match) { push(match.style, match.text); i += match.length; continue; }
    push('text', source[i]);
    i += 1;
  }
  if (plain) spans.push({ style: 'text', text: plain });
  return spans;
}

const INLINE = [
  // 백틱 n개로 열면 같은 n개로 닫는다. 안쪽은 서식 해석 없음.
  { style: 'code', re: /^(`+)(?!`)([\s\S]*?[^`])\1(?!`)/, group: 2 },
  { style: 'strong', re: /^\*\*(?![\s*])([\s\S]*?[^\s*])\*\*/, group: 1 },
  { style: 'strong', re: /^__(?![\s_])([\s\S]*?[^\s_])__/, group: 1 },
  { style: 'del', re: /^~~(?![\s~])([\s\S]*?[^\s~])~~/, group: 1 },
  { style: 'em', re: /^\*(?![\s*])([^*\n]*?[^\s*])\*(?!\*)/, group: 1 },
];

function inlineMatch(rest) {
  const first = rest[0];
  if (first !== '`' && first !== '*' && first !== '_' && first !== '~') return null;
  for (const { style, re, group } of INLINE) {
    const m = re.exec(rest);
    if (m) {
      const inner = style === 'code' ? m[group].replace(/^ (.*[^ ].*) $/s, '$1') : m[group];
      return { style, text: inner, length: m[0].length };
    }
  }
  return null;
}
