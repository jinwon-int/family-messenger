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
    const r = await api('GET', '/v2/me');
    if (r.status === 200 && typeof r.body?.subject === 'string') return r.body.subject;
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
  return {api, roomPath, describe, me, blob, get offline() { return offline; }};
}
