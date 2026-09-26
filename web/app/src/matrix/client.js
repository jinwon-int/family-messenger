// matrix-js-sdk adapter.
//
// The SDK is loaded lazily (dynamic import) so the pure product logic in
// src/*.js stays dependency-free and testable without node_modules; the
// loader is injectable, which is also how tests drive this file with a
// fake SDK. E2EE uses the Rust crypto stack (@matrix-org/matrix-sdk-
// crypto-wasm, pulled in by matrix-js-sdk) — decision D: we do not
// assemble cryptography ourselves.

import { classifyRoom, roomDisplayName } from '../rooms.js';
import { splitParticipants } from '../participants.js';
import { mediaDownloadPath } from '../attachments.js';
import { ROOM_ORDER_EVENT, parseRoomOrder } from '../room-order.js';

/** @returns {Promise<object>} the matrix-js-sdk module */
export function defaultSdkLoader() {
  return import('matrix-js-sdk');
}

/** Raised when a send would go to a room we can prove is unencrypted. */
export class PlaintextRefusedError extends Error {
  constructor(roomId) {
    super(`plaintext send refused for ${roomId}`);
    this.name = 'PlaintextRefusedError';
    this.roomId = roomId;
  }
}

/**
 * Password login against a homeserver; returns raw credentials for
 * createFamilyClient. Mirrors the SDK contract (m.login.password).
 */
export async function loginWithPassword({
  homeserverUrl,
  user,
  password,
  deviceId,
  deviceDisplayName,
  sdkLoader = defaultSdkLoader,
  clientFactory,
} = {}) {
  for (const [name, value] of Object.entries({ homeserverUrl, user, password })) {
    if (typeof value !== 'string' || value.length === 0) {
      throw new TypeError(`loginWithPassword: ${name} is required`);
    }
  }
  const sdk = await sdkLoader();
  const client = clientFactory ? clientFactory(sdk, { baseUrl: homeserverUrl }) : sdk.createClient({ baseUrl: homeserverUrl });
  const data = { identifier: { type: 'm.id.user', user }, password };
  // 같은 브라우저에서 다시 로그인할 때 기존 device_id를 재사용한다. 그래야 서버가 새 기기를
  // 만들지 않고, 기기별 crypto 저장소(familychat::user::device)의 서명 상태가 그대로 이어져
  // 로그인마다 기기 검증을 다시 하지 않는다 (2026-09-17 실기기: 세션마다 새 기기 → 매번 검증).
  if (typeof deviceId === 'string' && deviceId.length > 0) data.device_id = deviceId;
  if (typeof deviceDisplayName === 'string' && deviceDisplayName.length > 0) {
    data.initial_device_display_name = deviceDisplayName;
  }
  return client.login('m.login.password', data);
}

/**
 * @param {{homeserverUrl: string, userId: string, accessToken: string,
 *          deviceId: string, sdkLoader?: () => Promise<object>,
 *          clientFactory?: (sdk: object, opts: object) => object}} opts
 * @returns {Promise<ClientAdapter>}
 */
export async function createFamilyClient({
  homeserverUrl,
  userId,
  accessToken,
  deviceId,
  sdkLoader = defaultSdkLoader,
  clientFactory,
} = {}) {
  for (const [name, value] of Object.entries({ homeserverUrl, userId, accessToken, deviceId })) {
    if (typeof value !== 'string' || value.length === 0) {
      throw new TypeError(`createFamilyClient: ${name} is required`);
    }
  }
  const sdk = await sdkLoader();
  const opts = { baseUrl: homeserverUrl, userId, accessToken, deviceId, timelineSupport: true };
  const client = clientFactory
    ? clientFactory(sdk, opts)
    : sdk.createClient(opts);
  return new ClientAdapter(client, userId);
}

/**
 * matrix-js-sdk VerificationPhase (pinned 42.3.0; tests/transport_smoke.mjs
 * checks these against the installed SDK).
 */
export const VERIFICATION_PHASE = Object.freeze({ Unsent: 1, Requested: 2, Ready: 3, Started: 4, Cancelled: 5, Done: 6 });

/**
 * Resolve with a verifier once the request can run SAS: if the other side
 * already started one, use it; once the request is Ready, start our own.
 * Resolves null when the request is cancelled or finished first.
 */
export function waitForVerifier(request) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (fn) => {
      if (settled) return;
      settled = true;
      request.removeListener?.('change', check);
      fn();
    };
    const check = () => {
      if (request.verifier) return finish(() => resolve(request.verifier));
      const phase = request.phase;
      if (phase === VERIFICATION_PHASE.Cancelled || phase === VERIFICATION_PHASE.Done) return finish(() => resolve(null));
      if (phase === VERIFICATION_PHASE.Ready) {
        return finish(() => request.startVerification('m.sas.v1').then(resolve, reject));
      }
      return undefined;
    };
    request.on?.('change', check);
    check();
  });
}

export class ClientAdapter {
  /** @param {object} client a matrix-js-sdk MatrixClient */
  constructor(client, myUserId) {
    this.client = client;
    this.myUserId = myUserId;
    this.timelineSubscriptions = new Set();
  }

  /**
   * Turn on Rust (WASM) end-to-end encryption. Must run before
   * start(); resolves when crypto is ready to upload device keys.
   * The crypto store is persisted in IndexedDB when the runtime has one
   * (browsers); without it (Node drivers, some private-mode browsers) an
   * in-memory store is used so the adapter stays usable.
   * @param {{useIndexedDB?: boolean}} [opts]
   */
  async enableEncryption({ useIndexedDB = typeof indexedDB !== 'undefined' } = {}) {
    if (typeof this.client.initRustCrypto !== 'function') {
      throw new Error('initRustCrypto unavailable: matrix-js-sdk without rust crypto');
    }
    await this.client.initRustCrypto({ useIndexedDB, cryptoDatabasePrefix: this.cryptoDatabasePrefix() });
  }

  /**
   * IndexedDB name prefix for the rust crypto store, unique per account+device.
   * Every login gets a fresh device id, so a shared prefix made the store from
   * a previous device collide ("the account in the store doesn't match …"),
   * and deleting it at login raced with open handles (NotFoundError on the
   * object stores, 2026-09-17). A per-device name needs no deletion at all.
   */
  cryptoDatabasePrefix() {
    const device = this.client.getDeviceId?.() ?? this.client.deviceId ?? '';
    const safe = (value) => String(value ?? '').replace(/[^A-Za-z0-9._-]/g, '_');
    return `familychat::${safe(this.myUserId)}::${safe(device)}`;
  }

  /** Begin syncing. @param {(state: string) => void} [onSyncState] */
  start(onSyncState) {
    if (onSyncState) {
      this.client.on('sync', (state) => onSyncState(state));
    }
    this.client.startClient({ initialSyncLimit: 20 });
  }

  stop() {
    for (const off of this.timelineSubscriptions) off();
    this.client.stopClient();
  }

  /** Nudge the SDK's existing retry loop after the browser comes back online. */
  retrySync() {
    return this.client.retryImmediately?.();
  }

  /**
   * Room ids flagged as direct messages by the m.direct account data,
   * i.e. 1:1 개인방.
   */
  directRoomIds() {
    const content = this.client.getAccountData?.('m.direct')?.getContent?.() ?? {};
    const ids = new Set();
    for (const rooms of Object.values(content)) {
      if (Array.isArray(rooms)) for (const id of rooms) ids.add(id);
    }
    return ids;
  }

  /** 대화 목록 고정 순서(방 ID 배열). 저장된 적이 없으면 빈 배열 = 기본 순서. */
  roomOrder() {
    return parseRoomOrder(this.client.getAccountData?.(ROOM_ORDER_EVENT)?.getContent?.());
  }

  /** 대화 목록 순서를 계정 account data에 저장한다(같은 계정의 다른 기기로 동기화된다). */
  async setRoomOrder(roomIds) {
    await this.client.setAccountData(ROOM_ORDER_EVENT, { rooms: [...roomIds] });
  }

  /**
   * 대화 목록 순서가 바뀌면(다른 기기에서 옮김, 내 저장의 되울림) 호출한다.
   * @param {(roomIds: string[]) => void} handler
   * @returns {() => void} unsubscribe
   */
  onRoomOrderChange(handler) {
    const listener = (event) => {
      if (event?.getType?.() !== ROOM_ORDER_EVENT) return;
      handler(parseRoomOrder(event.getContent?.()));
    };
    this.client.on('accountData', listener);
    return () => this.client.removeListener?.('accountData', listener);
  }

  /**
   * Summaries for the room list: product kind, display name, participant
   * split (human vs AI).
   * @param {{agentUserIds?: Iterable<string>}} [opts]
   */
  roomSummaries(opts = {}) {
    const rooms = this.client.getRooms?.() ?? [];
    const direct = this.directRoomIds();
    return rooms.map((room) => {
      const members = (room.getMembers?.() ?? []).map((m) => ({
        userId: m.userId,
        name: m.name,
        content: m.events?.member?.getContent?.() ?? {},
      }));
      const isDirect = direct.has(room.roomId);
      const memberCount = typeof room.getJoinedMemberCount === 'function'
        ? room.getJoinedMemberCount()
        : members.length;
      const otherMemberNames = members.filter((m) => m.userId !== this.myUserId).map((m) => m.name);
      const { agents, humans } = splitParticipants(members, opts);
      return {
        roomId: room.roomId,
        name: room.name,
        otherMemberNames,
        displayName: roomDisplayName({ name: room.name, otherMemberNames }),
        isDirect,
        memberCount,
        kind: classifyRoom({ isDirect, memberCount }),
        agents,
        humans,
      };
    });
  }

  /**
   * Joined-member handles for mention building: full user id plus localpart
   * (the part after @ that users type in the composer).
   * @param {string} roomId
   */
  roomMemberHandles(roomId) {
    const room = this.client.getRoom?.(roomId);
    if (!room) return [];
    return (room.getMembers?.() ?? [])
      .filter((m) => (m.events?.member?.getContent?.().membership ?? 'join') === 'join')
      .map((m) => ({ userId: m.userId, localpart: String(m.userId.split(':')[0] ?? '').slice(1) }))
      .filter((h) => h.localpart.length > 0);
  }

  /** Whether the room is end-to-end encrypted (best effort). */
  isRoomEncrypted(roomId) {
    try {
      return Boolean(this.client.isRoomEncrypted?.(roomId));
    } catch {
      return false;
    }
  }

  /** Send m.text. Refuses provable-plaintext rooms, hides no failures.
   * `mentions` (optional) is an iterable of full user ids; it becomes the
   * spec'd m.mentions structure so homeserver/bridges can see the mention
   * (fleet_matrix family mode gates replies on this structure).
   */
  async sendText(roomId, text, mentions) {
    const body = String(text ?? '').trim();
    if (body.length === 0) return null;
    if (!this.isRoomEncrypted(roomId)) throw new PlaintextRefusedError(roomId);
    const content = { msgtype: 'm.text', body };
    const ids = [...new Set(mentions ?? [])].filter((id) => typeof id === 'string' && id.startsWith('@'));
    if (ids.length > 0) content['m.mentions'] = { user_ids: ids };
    return this.client.sendEvent(roomId, 'm.room.message', content);
  }

  /**
   * Send (or clear) my typing state for a room. `timeoutMs` is the window the
   * homeserver keeps the flag before auto-expiring it (spec: m.typing), so a
   * crashed tab cannot type forever. Best-effort: callers may ignore failures.
   */
  sendTyping(roomId, isTyping, timeoutMs = 30_000) {
    if (typeof this.client.sendTyping !== 'function') return Promise.resolve();
    return this.client.sendTyping(roomId, isTyping, timeoutMs);
  }

  /**
   * Subscribe to other people's typing state changes (SDK RoomMember.typing,
   * emitted from the sync's ephemeral m.typing list). handler receives a flat
   * {roomId, userId, name, typing}; returns an unsubscribe function.
   */
  onTyping(handler) {
    const listener = (_event, member) => {
      if (!member?.roomId || !member?.userId) return;
      handler({ roomId: member.roomId, userId: member.userId, name: member.name ?? '', typing: Boolean(member.typing) });
    };
    this.client.on('RoomMember.typing', listener);
    return () => this.client.removeListener('RoomMember.typing', listener);
  }

  /** Send an attachment whose mxc URL is already uploaded. */
  async sendAttachment(roomId, content) {
    if (!this.isRoomEncrypted(roomId)) throw new PlaintextRefusedError(roomId);
    return this.client.sendEvent(roomId, 'm.room.message', content);
  }

  /**
   * Upload a file and return its mxc URL.
   * @param {File|{name: string, type?: string}} file
   * @param {ArrayBuffer|Uint8Array} data
   */
  uploadMedia(file, data) {
    return this.client.uploadContent(data, {
      name: file.name,
      type: file.type ?? 'application/octet-stream',
    });
  }

  /** This session's device id. */
  deviceId() {
    return this.client.getDeviceId?.() ?? null;
  }

  /**
   * Register/replace a push gateway pusher. The body goes to
   * POST /_matrix/client/v3/pushers/set verbatim — the SDK does not reshape it,
   * so the non-spec `data` keys sygnal reads (endpoint/auth/events_only/
   * only_last_per_room) survive. Build it with src/push.js, not by hand.
   */
  setPusher(pusher) {
    return this.client.setPusher(pusher);
  }

  /** Delete a pusher (sends kind: null). pushKey is the subscription's p256dh. */
  removePusher(pushKey, appId) {
    return this.client.removePusher(pushKey, appId);
  }

  /** This account's pushers. Used to tell "really on" from "subscribed but not registered". */
  async getPushers() {
    const response = await this.client.getPushers();
    return Array.isArray(response?.pushers) ? response.pushers : [];
  }

  /**
   * My devices with cross-signing status (crossSigned: true/false, null when
   * crypto cannot tell). The current session is flagged so the UI never
   * offers to delete it from this list.
   */
  async listDevices() {
    const response = await this.client.getDevices();
    const crypto = this.client.getCrypto?.();
    const current = this.deviceId();
    const devices = [];
    for (const device of response?.devices ?? []) {
      let crossSigned = null;
      if (crypto?.getDeviceVerificationStatus) {
        try {
          const status = await crypto.getDeviceVerificationStatus(this.myUserId, device.device_id);
          crossSigned = status ? Boolean(status.crossSigningVerified) : null;
        } catch {
          crossSigned = null;
        }
      }
      devices.push({
        deviceId: device.device_id,
        displayName: typeof device.display_name === 'string' ? device.display_name : '',
        lastSeenTs: Number.isFinite(device.last_seen_ts) ? device.last_seen_ts : null,
        lastSeenIp: typeof device.last_seen_ip === 'string' ? device.last_seen_ip : '',
        isCurrent: device.device_id === current,
        crossSigned,
      });
    }
    return devices.sort((a, b) => (b.isCurrent - a.isCurrent) || ((b.lastSeenTs ?? 0) - (a.lastSeenTs ?? 0)));
  }

  /**
   * Delete other sessions. The homeserver requires user-interactive auth:
   * the first call answers 401 with a session id, the second carries the
   * password. Throws {code: 'auth-required'} when no password was given.
   */
  async deleteDevices(deviceIds, { password } = {}) {
    const ids = [...new Set(deviceIds)].filter((id) => typeof id === 'string' && id.length > 0 && id !== this.deviceId());
    if (ids.length === 0) return { deleted: [] };
    try {
      await this.client.deleteMultipleDevices(ids);
      return { deleted: ids };
    } catch (error) {
      const session = error?.httpStatus === 401 ? error?.data?.session : null;
      if (!session) throw error;
      if (!password) {
        const authRequired = new Error('deleteDevices: password required');
        authRequired.code = 'auth-required';
        throw authRequired;
      }
      await this.client.deleteMultipleDevices(ids, {
        type: 'm.login.password',
        identifier: { type: 'm.id.user', user: this.myUserId },
        password,
        session,
      });
      return { deleted: ids };
    }
  }

  /**
   * Delete the local sync + rust crypto stores (IndexedDB). Only valid before
   * start(). Used when a store left by a previous device would block
   * initRustCrypto ("the account in the store doesn't match …"). Bounded, so a
   * store held open by another tab cannot hang the login.
   */
  async resetLocalStores({ timeoutMs = 8000 } = {}) {
    if (typeof this.client.clearStores !== 'function') return false;
    let timer;
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('resetLocalStores: timed out (store open in another tab?)')), timeoutMs);
    });
    try {
      await Promise.race([this.client.clearStores({ cryptoDatabasePrefix: this.cryptoDatabasePrefix() }), timeout]);
      return true;
    } finally {
      clearTimeout(timer);
    }
  }

  /** Invalidate this session's token on the server, stop syncing and wipe local stores. */
  async logout() {
    try {
      await this.client.logout(true);
    } finally {
      try {
        this.stop();
        await this.client.clearStores?.({ cryptoDatabasePrefix: this.cryptoDatabasePrefix() });
      } catch (error) {
        console.warn('clearStores after logout failed', error);
      }
    }
  }

  /** True while the live timeline still has a backwards pagination token. */
  canLoadEarlier(roomId) {
    const room = this.client.getRoom?.(roomId);
    const timeline = room?.getLiveTimeline?.();
    if (!timeline || typeof timeline.getPaginationToken !== 'function') return false;
    return timeline.getPaginationToken('b') != null;
  }

  /**
   * Events currently on the SDK live timeline (initial sync + scrollback + live).
   * The UI keeps its own copy; this is the source of truth after a missed Room.timeline.
   */
  liveTimelineEvents(roomId) {
    const room = this.client.getRoom?.(roomId);
    const events = room?.getLiveTimeline?.()?.getEvents?.();
    return Array.isArray(events) ? events : [];
  }

  /**
   * Fetch one page of older events into the live timeline (SDK scrollback);
   * they arrive through onTimeline with atStart=true. Resolves with the
   * number of events added (0 = reached the beginning or nothing older).
   */
  async loadEarlier(roomId, limit = 30) {
    const room = this.client.getRoom?.(roomId);
    if (!room || typeof this.client.scrollback !== 'function') return 0;
    const before = room.getLiveTimeline?.()?.getEvents?.().length ?? 0;
    await this.client.scrollback(room, limit);
    const after = room.getLiveTimeline?.()?.getEvents?.().length ?? before;
    return Math.max(0, after - before);
  }

  /**
   * Download an attachment through the authenticated media endpoint and
   * decrypt it when it was sent end-to-end encrypted. Returns a Blob typed
   * with the attachment mimetype. `fetchFn`/`decrypt` are injectable for tests.
   */
  async fetchAttachment(attachment, { fetchFn = globalThis.fetch, decrypt, signal } = {}) {
    const path = mediaDownloadPath(attachment?.url);
    if (!path) throw new Error('fetchAttachment: mxc:// URL required');
    const base = String(this.client.getHomeserverUrl?.() ?? this.client.baseUrl ?? '').replace(/\/$/, '');
    const token = this.client.getAccessToken?.();
    const response = await fetchFn(base + path, { headers: token ? { Authorization: `Bearer ${token}` } : {}, ...(signal ? { signal } : {}) });
    if (!response.ok) throw new Error(`fetchAttachment: media download failed (${response.status})`);
    let data = await response.arrayBuffer();
    if (attachment.encrypted) {
      const decryptFn = decrypt ?? (await import('matrix-encrypt-attachment')).decryptAttachment;
      data = await decryptFn(data, attachment.encrypted);
    }
    return new Blob([data], { type: attachment.mimetype || 'application/octet-stream' });
  }

  /**
   * Subscribe to live timeline events for rendering.
   *
   * The SDK emits Room.timeline as soon as an event lands, while decryption
   * runs in the background (event-mapper starts it without awaiting). An
   * encrypted event therefore still reports type m.room.encrypted at that
   * moment; consumers that filter on getType() would drop every incoming
   * E2EE message (#125). Encrypted events are delivered once per
   * 'Event.decrypted' (success or failure — a later key arrival re-emits it,
   * so the handler may see the same event id again and must replace).
   */
  onTimeline(handler) {
    // SDK 인자: (event, room, toStartOfTimeline, removed, data). 이전 대화(scrollback)는
    // toStartOfTimeline=true로 오고, removed=true는 로컬 에코 제거이므로 그리지 않는다.
    let active = true;
    const subscriptions = new Map();
    const pendingTargets = new Set();
    // A fresh sync may contain only heartbeat edits: the original can be older
    // than initialSyncLimit. Ask the SDK for its context rather than displaying
    // an unvalidated edit as a new message. Fetch once per target in flight.
    const recoverTarget = (event) => {
      const relation = event?.getRelation?.();
      if (relation?.rel_type !== 'm.replace' || !relation.event_id || event.isRedacted?.()) return;
      const room = this.client.getRoom?.(event.getRoomId?.());
      if (!room || room.findEventById?.(relation.event_id)) return;
      const set = room.getUnfilteredTimelineSet?.();
      const key = `${room.roomId}/${relation.event_id}`;
      if (!set || !this.client.getEventTimeline || pendingTargets.has(key) || pendingTargets.size >= 16) return;
      pendingTargets.add(key);
      Promise.resolve().then(() => active ? this.client.getEventTimeline(set, relation.event_id) : null)
        .then((timeline) => {
          if (!active) return;
          const target = timeline?.getEvents?.().find((item) => item.getId?.() === relation.event_id);
          if (target) listener(target, room, true, false, { chronological: true });
        })
        .catch(() => { /* History may be unavailable; a later edit/scrollback can retry. */ })
        .finally(() => pendingTargets.delete(key));
    };
    const deliver = (event, meta) => {
      if (!active) return;
      recoverTarget(event);
      handler(event, meta);
    };
    const listener = (event, room, toStartOfTimeline, removed, data) => {
      if (removed) return;
      const meta = {
        atStart: Boolean(toStartOfTimeline),
        previousEventId: data?.previousEventId,
        chronological: data?.chronological === true
          || Boolean(data?.timeline && data.timeline !== room?.getLiveTimeline?.()),
      };
      const encrypted = typeof event?.isEncrypted === 'function' && event.isEncrypted();
      if (!encrypted || typeof event.on !== 'function') {
        deliver(event, meta);
        return;
      }
      if (!subscriptions.has(event)) {
        const decrypted = () => deliver(event, meta);
        subscriptions.set(event, decrypted);
        event.on('Event.decrypted', decrypted);
      }
      const pending = typeof event.isBeingDecrypted === 'function' && event.isBeingDecrypted();
      const stillCiphertext = typeof event.getType === 'function' && event.getType() === 'm.room.encrypted';
      if (!pending && !stillCiphertext) deliver(event, meta);
    };
    // matrix-js-sdk aggregates edits (including sender/ordering validation) and
    // re-emits this on the client with the ORIGINAL event and updated content.
    const replaced = (event) => deliver(event, { atStart: false });
    const redacted = (event, room) => deliver(event, {
      removed: true, roomId: room?.roomId ?? event.getRoomId?.(), eventId: event.getAssociatedId?.(),
    });
    const reset = (room) => {
      for (const [event, callback] of subscriptions) {
        if (event.getRoomId?.() !== room?.roomId) continue;
        event.removeListener?.('Event.decrypted', callback);
        subscriptions.delete(event);
      }
    };
    // The SDK mutates a pending event's ID/status in place; it does not emit a
    // second Room.timeline event when the send response or remote echo arrives.
    const localEcho = (event, room, oldEventId) => {
      if (event.status === 'cancelled') {
        deliver(event, { removed: true, cancelled: true, roomId: room?.roomId,
          eventId: oldEventId ?? event.getId?.() });
      } else {
        listener(event, room, false, false, { previousEventId: oldEventId });
      }
    };
    this.client.on('Room.timeline', listener);
    this.client.on('Room.localEchoUpdated', localEcho);
    this.client.on('Room.timelineReset', reset);
    // Unknown-parent relations may not enter any Room.timeline (SDK threads).
    this.client.on('event', recoverTarget);
    this.client.on('Event.decrypted', recoverTarget);
    this.client.on('Event.replaced', replaced);
    this.client.on('Room.redaction', redacted);
    const off = () => {
      active = false;
      this.client.removeListener('Room.timeline', listener);
      this.client.removeListener('Room.localEchoUpdated', localEcho);
      this.client.removeListener('Room.timelineReset', reset);
      this.client.removeListener('event', recoverTarget);
      this.client.removeListener('Event.decrypted', recoverTarget);
      this.client.removeListener('Event.replaced', replaced);
      this.client.removeListener('Room.redaction', redacted);
      for (const [event, callback] of subscriptions) event.removeListener?.('Event.decrypted', callback);
      subscriptions.clear();
      this.timelineSubscriptions.delete(off);
    };
    this.timelineSubscriptions.add(off);
    return off;
  }

  /** Limited sync 등으로 SDK가 live timeline을 비우면 화면 복사본도 다시 읽어야 한다. */
  onTimelineReset(handler) {
    const listener = (room) => handler(room?.roomId);
    this.client.on('Room.timelineReset', listener);
    return () => this.client.removeListener('Room.timelineReset', listener);
  }

  /**
   * Pending invitations: rooms where my own membership is 'invite'.
   * Same summary shape as roomSummaries plus the inviter's display name.
   * @param {{agentUserIds?: Iterable<string>}} [opts]
   */
  inviteSummaries(opts = {}) {
    const rooms = this.client.getRooms?.() ?? [];
    const direct = this.directRoomIds();
    const summaries = [];
    for (const room of rooms) {
      const mine = room.getMyMember?.() ?? room.getMember?.(this.myUserId);
      if ((mine?.membership ?? '') !== 'invite') continue;
      const members = (room.getMembers?.() ?? []).map((m) => ({
        userId: m.userId,
        name: m.name,
        content: m.events?.member?.getContent?.() ?? {},
      }));
      const isDirect = direct.has(room.roomId);
      // 초대 시점에는 아직 합류하지 않았으므로 합류 수 대신 전체 멤버 수(합류+초대)를 쓴다 —
      // 표시와 방 분류(가족방 기준 3명 이상) 모두 수락 뒤의 모습을 기준으로 한다.
      const memberCount = members.length;
      const otherMemberNames = members.filter((m) => m.userId !== this.myUserId).map((m) => m.name);
      const { agents, humans } = splitParticipants(members, opts);
      const senderId = mine?.events?.member?.getSender?.() ?? null;
      const inviter = members.find((m) => m.userId === senderId) ?? null;
      summaries.push({
        roomId: room.roomId,
        name: room.name,
        otherMemberNames,
        displayName: roomDisplayName({ name: room.name, otherMemberNames }),
        isDirect,
        memberCount,
        kind: classifyRoom({ isDirect, memberCount }),
        agents,
        humans,
        inviterName: inviter?.name ?? senderId ?? '',
      });
    }
    return summaries;
  }

  /** Accept a pending invitation. */
  joinRoom(roomId) {
    return this.client.joinRoom(roomId);
  }

  /** Decline a pending invitation (leave a room we never joined). */
  declineInvite(roomId) {
    return this.client.leave(roomId);
  }

  /** Subscribe to rooms appearing in the store (new room, incoming invite). */
  onRoomAdded(handler) {
    this.client.on('Room', handler);
    return () => this.client.removeListener('Room', handler);
  }

  /**
   * Emoji (SAS) device verification driver.
   *
   * `startEmojiVerification` sends a verification request (own-user device
   * verification when no room/user is given, otherwise an in-room request),
   * waits for the other device to accept it, then drives the SAS exchange:
   *   onRequested()                      — request sent, other device must accept;
   *   onEmojis(emojis, {confirm, mismatch}) — seven [emoji, name] pairs;
   *   onDone() once both sides accepted; onCancelled() otherwise.
   * Throws when rust crypto is not enabled yet.
   *
   * Calling startVerification() straight after the request used to throw
   * "other device is unknown" (the SDK only learns the peer device once the
   * request reaches phase Ready) and the sheet showed "cancelled" the moment
   * the button was pressed (2026-09-17, company PC).
   */
  async startEmojiVerification({ userId, roomId, onRequest, onRequested, onEmojis, onDone, onCancelled }) {
    const crypto = this.client.getCrypto?.();
    if (!crypto) throw new Error('rust crypto not enabled');
    const request = roomId && userId
      ? await crypto.requestVerificationDM(userId, roomId)
      : await crypto.requestOwnUserVerification();
    onRequest?.(request);
    onRequested?.();
    await this.driveVerificationRequest(request, { onEmojis, onDone, onCancelled });
    return request;
  }

  /**
   * Incoming verification requests (another of my devices, e.g. the phone
   * app, asked to verify this one). handler(request) — pass the request to
   * acceptEmojiVerification to proceed. Non-self requests are ignored.
   */
  onVerificationRequest(handler) {
    const listener = (request) => {
      if (request?.isSelfVerification === false) return;
      handler(request);
    };
    this.client.on('crypto.verificationRequestReceived', listener);
    return () => this.client.removeListener('crypto.verificationRequestReceived', listener);
  }

  /** Accept an incoming request and drive the SAS exchange with the same callbacks. */
  async acceptEmojiVerification(request, { onRequest, onEmojis, onDone, onCancelled }) {
    onRequest?.(request);
    if (request.phase === VERIFICATION_PHASE.Requested && typeof request.accept === 'function') {
      await request.accept();
    }
    await this.driveVerificationRequest(request, { onEmojis, onDone, onCancelled });
    return request;
  }

  /**
   * Wait for phase Ready (or a verifier the other side already started),
   * start SAS if nobody did, then run the emoji exchange.
   */
  async driveVerificationRequest(request, { onEmojis, onDone, onCancelled }) {
    const verifier = await waitForVerifier(request);
    if (!verifier) {
      onCancelled?.();
      return null;
    }
    // Why a verification stopped matters to the person holding two devices
    // ("이모지가 같았는데 취소됐다", 2026-09-18): pass the SDK's cancellation
    // code and which user cancelled so the sheet can show them.
    const reason = (error) => ({
      code: request.cancellationCode ?? null,
      by: request.cancellingUserId ?? null,
      message: error instanceof Error ? error.message : typeof error === 'string' ? error : null,
    });
    verifier.on('show_sas', (sasEvent) => {
      const emojis = Array.isArray(sasEvent?.sas?.emoji) ? sasEvent.sas.emoji : [];
      onEmojis(emojis, {
        confirm: () => sasEvent.confirm().then(onDone).catch((error) => onCancelled?.(reason(error))),
        mismatch: () => sasEvent.mismatch(),
      });
    });
    verifier.on('cancel', (error) => onCancelled?.(reason(error)));
    await verifier.verify();
    return verifier;
  }
}
