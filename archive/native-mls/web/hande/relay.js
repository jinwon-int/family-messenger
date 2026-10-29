// v2 relay HTTP client. Same-origin only: the Cloudflare Access cookie rides along
// and the edge injects Cf-Access-Jwt-Assertion (RELAY-APP.md "왜 릴레이가 직접
// 서빙하나"). A failed fetch (relay down, tunnel gone, Access cookie expired) is a
// network error distinct from any HTTP status; the caller shows a human sentence
// (#251 A-1) and the quiet poll only flips the offline marker.
import {strings} from './strings.js';

export function createRelay({fetch = globalThis.fetch.bind(globalThis), onOffline = () => {}} = {}) {
  let offline = false;
  function setOffline(down) {
    if (down === offline) return;
    offline = down; onOffline(down);
  }
  async function api(method, path, body) {
    let response;
    try {
      response = await fetch(path, {method, credentials: 'same-origin',
        headers: body === undefined ? {} : {'Content-Type': 'application/json'},
        body: body === undefined ? undefined : JSON.stringify(body)});
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
  return {api, roomPath, describe, me, meInfo, blob, postBlob, get offline() { return offline; }};
}
