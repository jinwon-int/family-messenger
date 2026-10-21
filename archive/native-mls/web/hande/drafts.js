// 방별 작성 초안 영속화(#480 B) — 패밀리챗은 방을 오가며 초안을 메모리에 보존한다(main.js). 한데는 거기에
// 더해 새로고침·브라우저 재시작 뒤에도 남도록 이 기기 localStorage(`hande:draft:<device>:<room>`)에 둔다.
// 저장 실패(용량·사생활 모드)는 조용히 — 초안은 편의 기능이다. 빈 초안은 키를 지운다.

export const DRAFT_LIMIT = 20_000;   // 글자 상한 — 한 방의 초안이 localStorage 를 독차지하지 않게

export const draftKeyFor = (device, room) => `hande:draft:${device}:${room}`;

export function readDraft(storage, device, room) {
  try {
    const value = storage.getItem(draftKeyFor(device, room));
    return typeof value === 'string' ? value.slice(0, DRAFT_LIMIT) : '';
  } catch (_) { return ''; }
}

export function writeDraft(storage, device, room, text) {
  const value = typeof text === 'string' ? text.slice(0, DRAFT_LIMIT) : '';
  try {
    if (value.length === 0) storage.removeItem(draftKeyFor(device, room));
    else storage.setItem(draftKeyFor(device, room), value);
    return true;
  } catch (_) { return false; }
}

/** 이 기기의 모든 초안 키(지우기·이전용). */
export function draftKeys(storage, device) {
  const prefix = `hande:draft:${device}:`;
  try { return Object.keys(storage).filter((k) => k.startsWith(prefix)); } catch (_) { return []; }
}
