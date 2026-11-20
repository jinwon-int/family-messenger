// v2 relay HTTP client. Same-origin only: the Cloudflare Access cookie rides along
// and the edge injects Cf-Access-Jwt-Assertion (RELAY-APP.md "왜 릴레이가 직접
// 서빙하나"). A failed fetch (relay down, tunnel gone, Access cookie expired) is a
// network error distinct from any HTTP status; the caller shows a human sentence
// (#251 A-1) and the quiet poll only flips the offline marker.
import {strings} from './strings.js';

/**
 * JSON 요청 하나의 시간 제한(#853). 응답이 오지 않는 요청(절전 복귀·망 전환·반쯤 죽은 연결)은 브라우저가 몇 분씩 붙잡을 수
 * 있는데, 방 sync 가 그 요청을 기다리는 동안 작성창이 잠긴다(#828 `S.live`). 시간이 지나면 네트워크 실패와 같게 끝낸다.
 */
export const REQUEST_TIMEOUT_MS = 15_000;
/** `/v2/watch` 는 릴레이가 `wait` 만큼 붙잡는 게 정상이라, 그 위에 이만큼만 더 기다린다. */
export const WATCH_TIMEOUT_MARGIN_MS = 10_000;

export function createRelay({fetch = globalThis.fetch.bind(globalThis), onOffline = () => {}, timeoutMs = REQUEST_TIMEOUT_MS} = {}) {
  let offline = false;
  function setOffline(down) {
    if (down === offline) return;
    offline = down; onOffline(down);
  }
  /**
   * `run(signal)` 을 `ms` 안에 끝낸다. abort 로 실제 요청을 끊고, abort 를 따르지 않는 fetch 도 있으니 race 로도 끝낸다.
   * 타이머는 호출 시점의 전역 setTimeout 을 쓴다(테스트가 바꿔 끼운 타이머 포함).
   */
  function withTimeout(run, ms) {
    const ctrl = typeof AbortController === 'function' ? new AbortController() : null;
    let timer = null;
    const expired = new Promise((_, reject) => {
      timer = globalThis.setTimeout(() => {
        const e = new Error(`relay request timed out after ${ms} ms`); e.name = 'TimeoutError';
        try { ctrl?.abort(e); } catch (_) { /* 옛 브라우저: abort(reason) 미지원 */ }
        reject(e);
      }, ms);
    });
    const work = run(ctrl?.signal);
    work.catch(() => {});   // race 에서 진 쪽의 늦은 거절이 처리 안 된 거절로 남지 않게
    return Promise.race([work, expired]).finally(() => globalThis.clearTimeout(timer));
  }
  async function api(method, path, body, {timeoutMs: limit = timeoutMs} = {}) {
    let result;
    try {
      result = await withTimeout(async signal => {
        const response = await fetch(path, {method, credentials: 'same-origin',
          headers: body === undefined ? {} : {'Content-Type': 'application/json'},
          body: body === undefined ? undefined : JSON.stringify(body), ...(signal ? {signal} : {})});
        let json = null;
        try { json = await response.json(); } catch (_) { json = null; }
        return {response, json};
      }, limit);
    } catch (error) {
      setOffline(true);
      const wrapped = new Error(strings.relay.networkFailed); wrapped.network = true; wrapped.cause = error;
      if (error?.name === 'TimeoutError') wrapped.timeout = true;
      throw wrapped;
    }
    const {response, json} = result;
    setOffline(false);
    if (response.status === 401) { const e = new Error(strings.relay.unauthorized); e.unauthorized = true; throw e; }
    return {status: response.status, body: json};
  }
  const roomPath = (room, suffix) => `/v2/rooms/${encodeURIComponent(room)}/${suffix}`;
  const describe = (status, body) => `${status} ${body && body.error ? body.error : ''}`.trim();
  /** Access subject of the logged-in person (GET /v2/me, #431) — null when the route is absent (access disabled). */
  async function me() {
    const info = await meInfo();
    return info ? info.subject : null;
  }
  /**
   * GET /v2/me 본문 전체(#574): `{subject, policy_revision, devices:[{device_id, actor, fingerprint, status, acceptance, roles}]}`.
   * 기기 스토어가 없는 옛 릴레이는 `{subject}` 만, 경로가 없으면(접근 인증 꺼짐) null.
   */
  async function meInfo() {
    const r = await api('GET', '/v2/me');
    if (r.status === 200 && typeof r.body?.subject === 'string') return r.body;
    if (r.status === 404) return null;
    throw new Error(`/v2/me ${describe(r.status, r.body)}`);
  }
  /**
   * file-v2 (#499): GET one ciphertext blob as bytes (relay blob store, #505). Non-200 throws
   * with `status` and the relay error code (403 not_a_member, 404 no_such_blob, 410 room_closed);
   * a failed fetch is a network error like api(). The caller verifies sha256 and decrypts.
   */
  async function blob(room, id, device) {
    const path = `${roomPath(room, `blobs/${encodeURIComponent(id)}`)}?device=${encodeURIComponent(device)}`;
    let response;
    try { response = await fetch(path, {method: 'GET', credentials: 'same-origin'}); } catch (error) {
      setOffline(true);
      const wrapped = new Error(strings.relay.networkFailed); wrapped.network = true; wrapped.cause = error;
      throw wrapped;
    }
    setOffline(false);
    if (response.status === 401) { const e = new Error(strings.relay.unauthorized); e.unauthorized = true; throw e; }
    if (response.status !== 200) {
      let json = null;
      try { json = await response.json(); } catch (_) { json = null; }
      const e = new Error(`blob ${describe(response.status, json)}`); e.status = response.status;
      throw e;
    }
    return new Uint8Array(await response.arrayBuffer());
  }
  /**
   * file-v2 송신(#499 3단계, FILE-V2.md §3): 암호문 원시 바이트를 POST /v2/rooms/{room}/blobs?device= 로 올린다.
   * 201(새로 저장)·200(이미 있음 — 내용 주소라 멱등)이면 {status, body:{id,size}}. 그 밖의 상태도 throw 하지 않고
   * 돌려준다(413 blob_too_large·room_bytes_cap·device_bytes_cap, 403 not_a_member, 410 room_closed). 네트워크 실패는 api() 와 같다.
   */
  async function postBlob(room, device, bytes) {
    const path = `${roomPath(room, 'blobs')}?device=${encodeURIComponent(device)}`;
    let response;
    try {
      response = await fetch(path, {method: 'POST', credentials: 'same-origin',
        headers: {'Content-Type': 'application/octet-stream'}, body: bytes});
    } catch (error) {
      setOffline(true);
      const wrapped = new Error(strings.relay.networkFailed); wrapped.network = true; wrapped.cause = error;
      throw wrapped;
    }
    setOffline(false);
    let json = null;
    try { json = await response.json(); } catch (_) { json = null; }
    if (response.status === 401) { const e = new Error(strings.relay.unauthorized); e.unauthorized = true; throw e; }
    return {status: response.status, body: json};
  }
  /**
   * room-order v1(#715): 이 사람(actor)의 대화방 순서. `GET /v2/me/room-order?device=` → {status, body}
   * (200 {rooms, revision, updated_at} · 404 = 옛 릴레이). throw 하지 않고 상태를 돌려준다; 네트워크 실패만 api() 처럼 throw.
   */
  function getRoomOrder(device) {
    return api('GET', `/v2/me/room-order?device=${encodeURIComponent(device)}`);
  }
  /** `PUT /v2/me/room-order {device, rooms, base_revision}` → 200 {rooms, revision, updated_at} · 409 revision_conflict {현재 값} · 404. */
  function putRoomOrder(device, rooms, baseRevision) {
    return api('PUT', '/v2/me/room-order', {device, rooms, base_revision: baseRevision});
  }
  /**
   * GET /v2/watch(#755 2a, 릴레이 #424 `server/wait.go`): 여러 방을 요청 하나로 기다린다 — `after` 뒤에 행이 있는 방이 있으면 즉시,
   * 없으면 처음 바뀐 방(새 글·typing·읽음·알림·닫힘) 또는 `waitMs` 뒤 빈 결과.
   * @param {string} device
   * @param {{room: string, after: number}[]} rooms 1~64개
   * @param {number} waitMs 릴레이 상한 25 000(넘으면 릴레이가 줄인다)
   * @returns {Promise<{supported: boolean, changed: string[], errors: Record<string, string>}>}
   *   `supported = false` = #424 이전 릴레이(봉투 없는 404) — 호출자는 방별 4초 폴링을 유지한다. 그 밖의 비정상 응답은 throw.
   */
  async function watch(device, rooms, waitMs) {
    const q = new URLSearchParams({device, wait: String(Math.max(0, Math.floor(waitMs)))});
    for (const {room, after} of rooms) q.append('room', `${room}:${Math.max(0, Math.floor(after))}`);
    const {status, body} = await api('GET', `/v2/watch?${q.toString().replaceAll('%3A', ':')}`, undefined,
      {timeoutMs: Math.max(0, Math.floor(waitMs)) + WATCH_TIMEOUT_MARGIN_MS});
    if (status === 404 && (body === null || typeof body !== 'object')) return {supported: false, changed: [], errors: {}};
    if (status !== 200 || !body || !Array.isArray(body.changed)) {
      const e = new Error(`watch ${describe(status, body)}`); e.status = status; throw e;
    }
    return {supported: true, changed: body.changed.filter(r => typeof r === 'string'), errors: body.errors && typeof body.errors === 'object' ? body.errors : {}};
  }
  return {api, roomPath, describe, me, meInfo, blob, postBlob, getRoomOrder, putRoomOrder, watch, get offline() { return offline; }};
}
