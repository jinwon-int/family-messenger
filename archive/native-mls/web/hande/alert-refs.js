// alert-refs-v1(archive/native-mls/ALERT-REFS-V1.md, 오너 요청 2026-11-07) — 플릿 알림의 `#번호` 를 눌러 원래 알림으로 이동.
// 판정은 세 앱 공통 — 공유 벡터 archive/native-mls/tests/fixtures/alert-refs-vectors.json 과 같아야 한다. 순수 함수(DOM 없음).

/** 플릿 알림 봇 actor(기기 `fleet-bot`). 링크는 이 봇의 글에만 만든다. */
export const FLEET_ACTOR = 'fleet';

const ID_CHAR = /[0-9a-z]/;
const WORD = /[0-9A-Za-z_]/;
const LABEL = /^\[[^\]\n]{1,40}\] /u;   // 라벨 길이 = 코드 포인트(이모지 하나 = 1, iOS·Android 와 같게)

/** 이 기기가 플릿 알림 봇인가(actor = 기기 ID 첫 `-` 앞). */
export function isFleetDevice(device) {
  return String(device ?? '').split('-')[0] === FLEET_ACTOR;
}

/** text[i] 에서 시작하는 번호(`#` + [0-9a-z]{6}, 경계 규칙 §1)면 그 6자, 아니면 null. */
function idAt(text, i) {
  if (text[i] !== '#') return null;
  if (i > 0 && (WORD.test(text[i - 1]) || text[i - 1] === '#')) return null;
  const id = text.slice(i + 1, i + 7);
  if (id.length !== 6 || ![...id].every((c) => ID_CHAR.test(c))) return null;
  if (i + 7 < text.length && WORD.test(text[i + 7])) return null;
  return id;
}

/**
 * 글 → {self, refs}. refs = [{id, start, end}](start·end = JS 문자열 index, `#` 포함) — 자기 번호 자리와 자기 번호와 같은 번호는 뺀다.
 * @param {string} text
 * @returns {{self: string|null, refs: {id: string, start: number, end: number}[]}}
 */
export function parseAlertRefs(text) {
  if (typeof text !== 'string' || text === '') return {self: null, refs: []};
  const label = LABEL.exec(text);
  const at = label ? label[0].length : 0;
  let self = null;
  const own = idAt(text, at);
  if (own !== null && (at + 7 === text.length || text[at + 7] === ' ' || text[at + 7] === '\n')) self = own;
  const refs = [];
  for (let i = 0; i < text.length; i++) {
    if (self !== null && i === at) continue;
    const id = idAt(text, i);
    if (id === null || id === self) continue;
    refs.push({id, start: i, end: i + 7});
    i += 6;
  }
  return {self, refs};
}
