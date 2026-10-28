// AI 참여 동의(#544 E, 선택지 3 — 오너 결정 2026-10-28): 참여는 그대로 두고, 참여 뒤 방 명단(S.roster)에 에이전트가 있고
// 이 기기에 이 방의 동의 기록이 없으면 방을 처음 열 때 동의 시트를 띄우고 동의 전에는 작성창을 잠근다.
// 수락 전에는 명단을 알 수 없어(GET /v2/lobby/welcomes 에 roster 없음) 패밀리챗의 「수락 전 동의」를 그대로 옮길 수 없다 —
// 서버 변경 없이 참여 뒤 실제 명단으로 판정하므로 정확하다. 동의는 이 기기 localStorage(`hande:agent-consent:<device>:<room>`)에
// 두고 「이 기기 지우기」(`hande:*` 삭제)로 함께 사라진다. 순수 모듈: DOM 없음(tests/agent-consent.test.mjs).
import {isAgentDevice} from './strings.js';

export const consentKeyFor = (device, room) => `hande:agent-consent:${device}:${room}`;

/** 이 기기가 이 방의 AI 참여 안내에 동의했는가. 저장소 오류는 「아직」으로. */
export function readConsent(storage, device, room) {
  try { return storage.getItem(consentKeyFor(device, room)) === '1'; } catch (_) { return false; }
}

/** 동의를 기록한다(ISO 시각은 두지 않는다 — 값은 '1', 판정만). 저장 실패면 false(이번 화면에서만 동의로 본다). */
export function writeConsent(storage, device, room) {
  try { storage.setItem(consentKeyFor(device, room), '1'); return true; } catch (_) { return false; }
}

/** 명단에서 에이전트 기기만(중복 없이, 들어온 순서). */
export function agentsIn(roster, isAgent = isAgentDevice) {
  const out = [];
  for (const d of Array.isArray(roster) ? roster : []) if (typeof d === 'string' && d && isAgent(d) && !out.includes(d)) out.push(d);
  return out;
}

/** 동의가 필요한가 — 명단에 에이전트가 있고 아직 동의하지 않았을 때만. 명단을 아직 모르면(빈 목록) 아니다. */
export function needsConsent({roster, consented, isAgent = isAgentDevice}) {
  return !consented && agentsIn(roster, isAgent).length > 0;
}
