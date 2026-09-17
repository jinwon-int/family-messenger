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
  return client.login('m.login.password', { identifier: { type: 'm.id.user', user }, password });
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
  const opts = { baseUrl: homeserverUrl, userId, accessToken, deviceId };
  const client = clientFactory
    ? clientFactory(sdk, opts)
    : sdk.createClient(opts);
  return new ClientAdapter(client, userId);
}

export class ClientAdapter {
  /** @param {object} client a matrix-js-sdk MatrixClient */
  constructor(client, myUserId) {
    this.client = client;
    this.myUserId = myUserId;
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
    await this.client.initRustCrypto({ useIndexedDB });
  }

  /** Begin syncing. @param {(state: string) => void} [onSyncState] */
  start(onSyncState) {
    if (onSyncState) {
      this.client.on('sync', (state) => onSyncState(state));
    }
    this.client.startClient({ initialSyncLimit: 20 });
  }

  stop() {
    this.client.stopClient();
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
    const listener = (event) => {
      const encrypted = typeof event?.isEncrypted === 'function' && event.isEncrypted();
      if (!encrypted || typeof event.on !== 'function') {
        handler(event);
        return;
      }
      event.on('Event.decrypted', () => handler(event));
      const pending = typeof event.isBeingDecrypted === 'function' && event.isBeingDecrypted();
      const stillCiphertext = typeof event.getType === 'function' && event.getType() === 'm.room.encrypted';
      if (!pending && !stillCiphertext) handler(event);
    };
    this.client.on('Room.timeline', listener);
    return () => this.client.removeListener('Room.timeline', listener);
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
   * `start` sends a verification request (own-user device verification
   * when no room/user is given, otherwise an in-room request) and drives
   * the SAS exchange:
   *   onEmojis(emojis, {confirm, mismatch}) — seven [emoji, name] pairs;
   *   onDone() once both sides accepted; onCancelled() otherwise.
   * Throws when rust crypto is not enabled yet.
   */
  async startEmojiVerification({ userId, roomId, onEmojis, onDone, onCancelled }) {
    const crypto = this.client.getCrypto?.();
    if (!crypto) throw new Error('rust crypto not enabled');
    const request = roomId && userId
      ? await crypto.requestVerificationDM(userId, roomId)
      : await crypto.requestOwnUserVerification();
    const verifier = await request.startVerification('m.sas.v1');
    verifier.on('show_sas', (sasEvent) => {
      const emojis = Array.isArray(sasEvent?.sas?.emoji) ? sasEvent.sas.emoji : [];
      onEmojis(emojis, {
        confirm: () => sasEvent.confirm().then(onDone).catch(onCancelled),
        mismatch: () => sasEvent.mismatch(),
      });
    });
    verifier.on('cancel', () => onCancelled?.());
    await verifier.verify();
    return request;
  }
}
