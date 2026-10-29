// This device across rooms (#431 stage 4, iOS AppModel's `_identity` / `_lobby` slots):
// the worker's multi-store mode holds one identity store (the signer) and derives every
// room store from it, so one policy-chain enrollment covers all rooms. Here live the
// device-level relay calls (`GET /v2/rooms`, lobby routes) and the lobby keyring:
// unused key packages published room-independently, so a steward bot or an owner device
// can invite this device into a room it never asked to join (#380 P5-3).
import {strings} from './strings.js';
import {IDENTITY_ROOM, LOBBY_ROOM, LOBBY_DATABASE} from './identity.js';
import {op, b64, unb64, hex} from './room.js';

const WORKER = 'device';
export const LOBBY_TARGET = 8;   // facade cap on outstanding key packages (`key package limit`)

export function createDevice({device, worker, relay, storage, on = {}}) {
  const D = {started: false, fresh: false, migrated: false, publicKey: '', fingerprint: '', lobby: {live: null, max: null, unsupported: false}, enrolled: null,
    selfService: {unsupported: false, posted: null}};   // #574: candidate mailbox / approvals / roles routes (404 on an old relay → never asked again)
  const log = (...parts) => on.log?.(parts.join(' '));
  const publishedKey = `hande:lobby:published:${device}`;
  const readPublished = () => { try { const v = JSON.parse(storage.getItem(publishedKey) || '[]'); return Array.isArray(v) ? v.filter(x => typeof x === 'string') : []; } catch (_) { return []; } };
  const writePublished = list => storage.setItem(publishedKey, JSON.stringify(list.slice(-64)));

  /** Open the identity store (one custody KDF); `legacy` migrates a stage-2 single-room database. */
  async function start({passphrase, identityDatabase, legacy = null}) {
    if (!worker.has(WORKER)) await worker.spawn(WORKER);
    const argument = {identity: device, passphrase, identity_database: identityDatabase};
    if (legacy) argument.legacy = legacy;
    const r = await worker.call(WORKER, 'init_multi', argument);
    if (!r.ok) { const e = new Error(`init_multi 거부${r.stage ? `: ${r.stage}` : ''}`); e.stage = r.stage ?? null; throw e; }
    D.started = true; D.fresh = r.result.fresh === true; D.migrated = r.result.migrated === true;
    D.publicKey = hex(Uint8Array.from(r.result.public_key));
    D.fingerprint = hex(new Uint8Array(await crypto.subtle.digest('SHA-256', Uint8Array.from(r.result.public_key))));
    return {fresh: D.fresh, migrated: D.migrated};
  }
  /** Lobby package ref = sha256 hex of its bytes (base64 string or bytes) — the relay's `ref`. */
  const refOf = async bytes => hex(new Uint8Array(await crypto.subtle.digest('SHA-256', typeof bytes === 'string' ? unb64(bytes) : bytes)));
  async function openLobby() {
    const r = await worker.call(WORKER, 'open_room', {room: LOBBY_ROOM, database: LOBBY_DATABASE, from: 'identity'});
    if (!r.ok) throw new Error('로비 스토어를 열지 못했습니다');
    return r.result;
  }
  // ---- relay, device level ----
  const describe = relay.describe;
  /** `GET /v2/rooms?device=` — rooms the relay knows for this device; 403 = not on the policy chain yet. */
  async function rooms() {
    const r = await relay.api('GET', `/v2/rooms?device=${encodeURIComponent(device)}`);
    if (r.status === 403) { D.enrolled = false; return null; }
    if (r.status !== 200 || !Array.isArray(r.body?.rooms)) throw new Error(`방 목록 ${describe(r.status, r.body)}`);
    D.enrolled = true;
    return r.body.rooms;
  }
  async function welcomes() {
    if (D.lobby.unsupported) return [];
    const r = await relay.api('GET', `/v2/lobby/welcomes?device=${encodeURIComponent(device)}`);
    if (r.status === 404) { D.lobby.unsupported = true; return []; }
    if (r.status === 403) return [];
    if (r.status !== 200 || !Array.isArray(r.body?.welcomes)) throw new Error(`로비 초대 ${describe(r.status, r.body)}`);
    return r.body.welcomes.filter(w => typeof w.room === 'string' && Number.isSafeInteger(w.seq));
  }
  /**
   * Lobby keyring replenish (iOS LobbyKeyring.replenish): the relay consumes and expires the
   * oldest first, so `published.length − live` leading entries are gone — delete their local
   * secrets, then mint and publish what is missing up to min(target, relay max).
   * `prune: false` keeps the consumed entries' secrets (and their place in the published
   * list) and only mints: a consumed package may be the one a Welcome this device has not
   * joined yet was built from — deleting its secret makes that Welcome unreadable for good
   * (#517). `protect` is the precise form: the refs (sha256 hex of the package bytes, what
   * `GET /v2/lobby/welcomes` reports as `key_package_ref`) whose secrets must stay; they keep
   * their place at the head of the list and go on the first replenish after the Welcome is
   * adopted. The caller passes `prune: false` only when a pending Welcome carries no ref.
   */
  async function replenish(target = LOBBY_TARGET, {prune = true, protect = new Set()} = {}) {
    if (D.lobby.unsupported) return null;
    const st = await relay.api('GET', `/v2/lobby/status?device=${encodeURIComponent(device)}`);
    if (st.status === 404) { D.lobby.unsupported = true; return null; }
    if (st.status === 403) return null;   // not enrolled yet
    if (st.status !== 200) throw new Error(`로비 상태 ${describe(st.status, st.body)}`);
    const live = Number(st.body.live ?? 0), max = Number(st.body.max ?? target);
    await openLobby();
    let published = readPublished();
    const consumed = Math.min(Math.max(0, published.length - live), published.length);
    let pruned = 0, kept = 0;
    if (prune) {
      const remaining = [];
      for (const bytes of published.slice(0, consumed)) {
        if (protect.size && protect.has(await refOf(bytes))) { remaining.push(bytes); kept++; continue; }
        try { await op(worker, LOBBY_ROOM, 'delete_key_package', unb64(bytes)); pruned++; } catch (_) { /* already gone */ }
      }
      published = remaining.concat(published.slice(consumed)); writePublished(published);
    } else kept = consumed;
    const want = Math.min(target, max) - live;
    const fresh = [];
    for (let i = 0; i < want; i++) {
      let out;
      try { out = await op(worker, LOBBY_ROOM, 'key_package'); } catch (_) { break; }   // local cap: stop minting
      fresh.push(new Uint8Array(out.output));
    }
    let stored = 0;
    if (fresh.length) {
      const packages = [];
      for (const bytes of fresh) packages.push({ref: await refOf(bytes), bytes: b64(bytes)});
      const r = await relay.api('POST', '/v2/lobby/keypackages', {device, packages});
      if (r.status === 201 || r.status === 200) { stored = fresh.length; writePublished(published.concat(fresh.map(b64))); }
      else {
        // Not on the relay: a local secret without a published key only occupies the cap.
        for (const bytes of fresh) { try { await op(worker, LOBBY_ROOM, 'delete_key_package', bytes); } catch (_) {} }
        throw new Error(`로비 키 게시 ${describe(r.status, r.body)}`);
      }
    }
    D.lobby.live = live + stored; D.lobby.max = max;
    log(`로비 키: 서버 ${live}→${D.lobby.live}/${max}, 지움 ${pruned}, 새로 ${stored}` + (kept ? `, 수락 안 된 초대가 있어 소비된 ${kept}개 비밀키는 남김` : ''));
    return {live: D.lobby.live, max, minted: stored, pruned, kept};
  }
  // ---- identity store operations (E2 approval) ----
  const utf8 = new TextEncoder(), decoder = new TextDecoder();
  async function policyFingerprint(signingKeyHex) {
    return decoder.decode(new Uint8Array((await op(worker, IDENTITY_ROOM, 'policy_fingerprint', utf8.encode(signingKeyHex))).output));
  }
  /** Framed facade output = u32le(n) ‖ canonical payload(n bytes) ‖ Ed25519 signature(64) → signature hex. */
  const signatureOf = framed => {
    const n = new DataView(framed.buffer, framed.byteOffset, framed.byteLength).getUint32(0, true);
    return hex(framed.subarray(4 + n));
  };
  async function signApproval(argsJson) {
    return signatureOf(new Uint8Array((await op(worker, IDENTITY_ROOM, 'sign_approval', utf8.encode(argsJson))).output));
  }
  /** E5 (#574): `sign_roles` with `{device_id, actor, roles, base_revision}` — same frame as sign_approval. */
  async function signRoles(argsJson) {
    return signatureOf(new Uint8Array((await op(worker, IDENTITY_ROOM, 'sign_roles', utf8.encode(argsJson))).output));
  }
  const actor = () => device.split('-')[0];
  function registration(subject) {
    return {device_id: device, actor: actor(), subject: subject || strings.app.subjectUnknown, signing_key: D.publicKey, fingerprint: D.fingerprint};
  }
  // ---- device self-service (#574 PR 2b, server/devices.go) — every call returns {status, body}; the caller reads the code ----
  /**
   * `POST /v2/devices/candidates` — this (not yet enrolled) device posts its public record for a sibling to approve.
   * Body is strict JSON without `subject` (the relay takes it from the JWT). 201 {device_id, fingerprint, policy_revision, expires_at(s)};
   * 409 device_exists · 403 first_device_out_of_band · 404 old relay / access disabled (D.selfService.unsupported, stop asking).
   */
  async function postCandidate() {
    if (D.selfService.unsupported) return {status: 404, body: null};
    const r = await relay.api('POST', '/v2/devices/candidates', {device_id: device, actor: actor(), signing_key: D.publicKey, fingerprint: D.fingerprint});
    if (r.status === 404) D.selfService.unsupported = true;
    if (r.status === 201) D.selfService.posted = {expiresAt: Number(r.body?.expires_at ?? 0) * 1000, policyRevision: r.body?.policy_revision ?? null};
    return r;
  }
  /** `GET /v2/devices/candidates?device=` (an active device of the same subject) → {policy_revision, candidates} · null when absent/forbidden. */
  async function listCandidates() {
    if (D.selfService.unsupported) return null;
    const r = await relay.api('GET', `/v2/devices/candidates?device=${encodeURIComponent(device)}`);
    if (r.status === 404) { D.selfService.unsupported = true; return null; }
    if (r.status === 403) return null;
    if (r.status !== 200 || !Array.isArray(r.body?.candidates)) throw new Error(`기기 후보 목록 ${describe(r.status, r.body)}`);
    return r.body;
  }
  /** `POST /v2/devices/approvals` (E2 evidence) → 201 {device_id, approved_by, revision} · 409 stale_revision(body.revision) · 403 approval_rejected(detail). */
  async function postApproval(evidence) { return relay.api('POST', '/v2/devices/approvals', evidence); }
  /** `POST /v2/devices/roles` (E5 evidence) → 201 {device_id, roles, approved_by, revision} · 409 · 403 as above. */
  async function postRoles(evidence) { return relay.api('POST', '/v2/devices/roles', evidence); }
  function stop() { worker.stop(WORKER); D.started = false; }
  return {device, get state() { return D; }, start, openLobby, rooms, welcomes, replenish, policyFingerprint, signApproval, signRoles, registration,
    postCandidate, listCandidates, postApproval, postRoles, stop};
}
