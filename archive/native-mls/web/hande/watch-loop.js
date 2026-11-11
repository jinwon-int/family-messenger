// 기기 단위 대기 루프(#755 2a). 방마다 4초 폴링(방 21개 ≈ 초당 5 요청, 새 글 평균 약 2 s 늦게 보임)을
// 릴레이 `GET /v2/watch`(#424) 요청 하나로 바꾼다 — 바뀐 방만 즉시 sync 한다.
//
// - watch 가 되면: 방별 타이머는 안전망 간격(SAFETY_POLL_MS)으로 늦춘다(watch 가 어떤 이유로 놓쳐도 결국 맞춰지게).
// - 릴레이가 #424 이전(supported=false)이거나 오류면: 방별 4초 폴링(DEFAULT_POLL_MS)으로 되돌리고, 미지원은 REPROBE_MS 뒤 다시 확인.
// - 바뀐 방이 몰려도 루프는 MIN_GAP_MS 간격 아래로 돌지 않는다(typing 처럼 잦은 변화).
// 시계·대기는 주입(테스트). 이 모듈은 DOM 이 없다.

export const WATCH_WAIT_MS = 25000;
export const DEFAULT_POLL_MS = 4000;
export const SAFETY_POLL_MS = 60000;
export const MIN_GAP_MS = 1000;
export const REPROBE_MS = 5 * 60 * 1000;
export const MAX_ROOMS = 64;

/**
 * @param {{
 *   relay: {watch: (device: string, rooms: {room: string, after: number}[], waitMs: number) => Promise<{supported: boolean, changed: string[], errors: Record<string, string>}>},
 *   device: () => string | null,
 *   targets: () => {room: string, after: number}[],
 *   onChanged: (rooms: string[]) => Promise<unknown>,
 *   onMode: (watching: boolean) => void,
 *   onAlive?: () => void,
 *   sleep?: (ms: number) => Promise<void>,
 *   now?: () => number,
 *   log?: (line: string) => void,
 * }} deps
 */
export function createWatchLoop({relay, device, targets, onChanged, onMode, onAlive = () => {}, sleep = ms => new Promise(r => setTimeout(r, ms)), now = Date.now, log = () => {}}) {
  let running = false;
  let watching = null;          // null = 아직 모름, true/false = 마지막으로 알린 모드
  let unsupportedUntil = 0;
  const mode = (on) => { if (watching !== on) { watching = on; onMode(on); } };

  async function step() {
    const me = device();
    const list = targets().slice(0, MAX_ROOMS);
    if (!me || list.length === 0 || now() < unsupportedUntil) { mode(false); await sleep(DEFAULT_POLL_MS); return; }
    const started = now();
    let result;
    try {
      result = await relay.watch(me, list, WATCH_WAIT_MS);
    } catch (error) {
      log(`watch 실패(${error.message}) — 4초 폴링으로`);
      mode(false);
      await sleep(DEFAULT_POLL_MS);
      return;
    }
    if (!result.supported) {
      log('릴레이가 /v2/watch 를 모름(#424 이전) — 4초 폴링 유지');
      unsupportedUntil = now() + REPROBE_MS;
      mode(false);
      return;
    }
    mode(true);
    // 변화가 없어 대기만 끝났어도 릴레이와 이어져 있고 놓친 것이 없다는 확인이다 — 「동기화 HH:MM:SS」 줄을 갱신하게 알린다.
    // (방별 폴링이 60 s 안전망으로 늦춰진 뒤 그 줄이 최대 60 s 멈춰 보이던 회귀 — #760 후속.)
    try { onAlive(); } catch (_) { /* 화면 갱신 실패가 루프를 멈추지 않는다 */ }
    if (result.changed.length > 0) {
      try { await onChanged(result.changed); } catch (_) { /* 방 sync 실패는 그 방 로그로 — 루프는 계속 */ }
    }
    const spent = now() - started;
    if (spent < MIN_GAP_MS) await sleep(MIN_GAP_MS - spent);
  }

  async function run() {
    while (running) await step();
  }

  return {
    start() { if (running) return; running = true; run().catch(() => { running = false; }); },
    stop() { running = false; },
    get running() { return running; },
    get watching() { return watching === true; },
    step,   // 테스트용 한 바퀴
  };
}
