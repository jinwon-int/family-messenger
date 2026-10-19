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
  return {api, roomPath, describe, me, get offline() { return offline; }};
}
