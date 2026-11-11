// 방 여러 개를 동시성 상한 안에서 연다(#752). 앱 시작·refresh 가 방을 하나씩 `await` 하면 방마다
// 릴레이 왕복(sync 1회, 한국↔프랑크푸르트 약 0.3 s)과 워커 작업이 방 수만큼 직렬로 쌓인다.
// 워커(durable-worker.js)는 메시지를 Promise 큐로 하나씩 처리하므로 동시에 불러도 워커 안 작업은
// 섞이지 않는다 — 겹치는 것은 페이지 쪽 대기(네트워크 왕복)뿐이다.
//
// 시작 순서는 입력 순서 그대로다: ensureRoom 은 첫 await 전에 app.rooms 에 넣고 order 를 매기므로,
// 방 목록 순서·넓은 화면의 첫 방 선택(app.rooms 의 첫 키)이 직렬 때와 같다.

export const ROOM_OPEN_CONCURRENCY = 6;

/**
 * @template T
 * @param {Iterable<T>} items 열 방(입력 순서 = 시작 순서)
 * @param {(item: T) => Promise<unknown>} open 하나 열기(거부되면 onError 로 보내고 나머지는 계속)
 * @param {{limit?: number, onError?: (item: T, error: unknown) => void}} [opts]
 * @returns {Promise<{opened: number, failed: number}>} 모두 끝난 뒤(성공·실패 무관) resolve — 거부하지 않는다
 */
export async function openRoomsLimited(items, open, {limit = ROOM_OPEN_CONCURRENCY, onError = () => {}} = {}) {
  const list = [...items];
  const width = Math.max(1, Math.min(Number.isSafeInteger(limit) && limit > 0 ? limit : 1, list.length));
  let next = 0;
  let opened = 0;
  let failed = 0;
  async function lane() {
    while (next < list.length) {
      const item = list[next++];
      try { await open(item); opened++; } catch (error) {
        failed++;
        try { onError(item, error); } catch (_) { /* 로그 실패가 다른 방 열기를 막지 않는다 */ }
      }
    }
  }
  await Promise.all(Array.from({length: width}, lane));
  return {opened, failed};
}
