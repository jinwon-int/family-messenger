// status-v1 (family-messenger#560, archive/native-mls/STATUS-V1.md §3) — 에이전트 작업 상태 말풍선.
//
// 봇은 매트릭스의 「⏳ Working — 10s | Bash: …」 한 줄을 `client_id = status-<uuid>` 인 application 메시지로
// 5초마다 새로 보낸다(한데에는 메시지 편집이 없다). 앱은 그 메시지를 **저장하지 않고** 보낸이별 임시 말풍선
// 하나로만 보인다: 새 status 가 오면 본문만 바뀌고, 그 보낸이의 다음 일반 메시지(답·첨부)가 오면 사라지며,
// 마지막 status 가 5분 넘게 갱신되지 않으면 사라진다. 안 읽음·방 목록 미리보기·첨부함·「내 마지막 말」 바에는
// 들어가지 않는다 — 타임라인 entries 밖(이 맵)에만 있으므로.
//
// 순수 함수(DOM·시계 전역 없음) — node --test 로 검증한다.

/** 바깥 client_id 모양(봇·릴레이·iOS 와 같은 규칙): `status-` + uuid v4 소문자 36자. 접두만 맞으면 일반 글. */
export const isStatusClient = id => /^status-[a-f0-9-]{36}$/.test(id ?? '');

/** 마지막 status 이후 이 시간 동안 새 status 도 답도 없으면 말풍선을 지운다(턴이 답 없이 끝난 경우의 안전망). */
export const STATUS_TTL_MS = 5 * 60 * 1000;

/** 한 줄 상한 — 브리지는 8 KiB 까지 보낼 수 있지만 말풍선은 한 줄짜리다. */
const MAX_TEXT = 500;

/** 보낸이별 상태 맵 + 보낸이별 마지막 일반 메시지 seq(늦게 도착한 옛 status 가 답 뒤에 다시 뜨지 않게). */
export function createStatusBoard() {
  return {bySender: new Map(), lastSeq: new Map()};
}

/**
 * status 메시지 하나를 반영한다. 같은 보낸이의 일반 메시지보다 앞선(seq 가 작은) status 는 무시한다 —
 * 한 번의 동기화에 답과 그 앞의 status 가 같이 와도 순서와 상관없이 답이 이긴다.
 * @returns {boolean} 화면이 바뀌는지
 */
export function applyStatus(board, {sender, text, seq, ts}, now = Date.now()) {
  if (!sender || typeof text !== 'string') return false;
  const line = text.trim().slice(0, MAX_TEXT);
  if (!line) return false;
  const after = board.lastSeq.get(sender);
  if (Number.isSafeInteger(after) && Number.isSafeInteger(seq) && seq < after) return false;
  const prev = board.bySender.get(sender);
  if (prev && Number.isSafeInteger(prev.seq) && Number.isSafeInteger(seq) && seq < prev.seq) return false;
  // 만료 기준 시각: 릴레이 created_at 이 있으면 그것(밀린 이력을 한꺼번에 받아도 옛 status 는 바로 만료),
  // 단 이 기기 시계보다 미래로는 두지 않는다(시계가 뒤처진 기기에서 말풍선이 오래 남지 않게).
  const at = Number.isFinite(ts) ? Math.min(ts, now) : now;
  board.bySender.set(sender, {sender, text: line, seq: Number.isSafeInteger(seq) ? seq : null, at});
  return !prev || prev.text !== line;
}

/**
 * 같은 보낸이의 일반 메시지(글·첨부·해독 불가)가 왔다 — 그보다 앞선 status 를 지운다.
 * 이력 복원(seq 순서가 아닐 수 있음)에서도 쓰므로 seq 가 더 큰 status 는 남긴다.
 * @returns {boolean} 화면이 바뀌는지
 */
export function clearStatusOnMessage(board, sender, seq) {
  if (!sender) return false;
  if (Number.isSafeInteger(seq)) board.lastSeq.set(sender, Math.max(seq, board.lastSeq.get(sender) ?? 0));
  const cur = board.bySender.get(sender);
  if (!cur) return false;
  if (Number.isSafeInteger(seq) && Number.isSafeInteger(cur.seq) && cur.seq > seq) return false;
  board.bySender.delete(sender);
  return true;
}

/** 지금 보일 말풍선들(만료된 것은 맵에서도 지운다) — 오래된 것부터, 타임라인 맨 아래에 이 순서로 붙인다. */
export function visibleStatuses(board, now = Date.now()) {
  for (const [sender, s] of board.bySender) if (now - s.at > STATUS_TTL_MS) board.bySender.delete(sender);
  return [...board.bySender.values()].sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0));
}
