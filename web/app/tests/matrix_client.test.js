import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import {
  ClientAdapter,
  PlaintextRefusedError,
  createFamilyClient,
  loginWithPassword,
} from '../src/matrix/client.js';

function fakeSdk() {
  const calls = { createClient: [] };
  const clients = [];
  return {
    calls,
    clients,
    createClient(opts) {
      calls.createClient.push(opts);
      const client = new FakeClient(opts);
      clients.push(client);
      return client;
    },
  };
}

class FakeClient extends EventEmitter {
  constructor(opts) {
    super();
    this.opts = opts;
    this.started = false;
    this.stopped = false;
    this.sent = [];
    this.uploads = [];
    this.roomsById = new Map();
    this.directContent = {};
    this.encrypted = new Set();
    this.crypto = null;
  }

  async initRustCrypto(opts) {
    this.initRustCryptoOpts = opts;
    this.crypto = { requested: [] };
  }

  getCrypto() {
    return this.crypto;
  }

  getAccountData(type) {
    return { getContent: () => this.directContent[type] };
  }

  getRooms() {
    return [...this.roomsById.values()];
  }

  getRoom(roomId) {
    return this.roomsById.get(roomId) ?? null;
  }

  isRoomEncrypted(roomId) {
    return this.encrypted.has(roomId);
  }

  async sendEvent(roomId, type, content) {
    this.sent.push({ roomId, type, content });
    return { event_id: `e${this.sent.length}` };
  }

  async uploadContent(data, opts) {
    this.uploads.push({ data, opts });
    return { content_uri: 'mxc://example.com/up1' };
  }

  startClient(opts) {
    this.started = true;
    this.startOpts = opts;
  }

  stopClient() {
    this.stopped = true;
  }

  async login(type, data) {
    this.loginCall = { type, data };
    return { user_id: '@a:example.com', access_token: 'tok', device_id: 'D' };
  }

  async joinRoom(roomId) {
    this.joinedRooms = [...(this.joinedRooms ?? []), roomId];
    return { roomId };
  }

  async leave(roomId) {
    this.leftRooms = [...(this.leftRooms ?? []), roomId];
  }

  addRoom(room) {
    this.roomsById.set(room.roomId, room);
  }
}

function member(userId, name, kind) {
  return {
    userId,
    name,
    events: { member: { getContent: () => (kind ? { 'us.familychat.kind': kind } : {}) } },
  };
}

function room(roomId, { name, members, joinedCount }) {
  return {
    roomId,
    name,
    getMembers: () => members,
    getJoinedMemberCount: () => joinedCount ?? members.length,
  };
}

const CREDS = {
  homeserverUrl: 'https://matrix.example.com',
  userId: '@minseo:example.com',
  accessToken: 'syt-token',
  deviceId: 'DEVICE1',
};

test('자격 증명이 그대로 SDK 클라이언트 생성자로 전달된다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  assert.deepEqual(sdk.calls.createClient[0], {
    baseUrl: CREDS.homeserverUrl,
    userId: CREDS.userId,
    accessToken: CREDS.accessToken,
    deviceId: CREDS.deviceId,
  });
  assert.ok(adapter instanceof ClientAdapter);
  for (const key of Object.keys(CREDS)) {
    await assert.rejects(createFamilyClient({ ...CREDS, [key]: '', sdkLoader: async () => sdk }), TypeError);
  }
});

test('로그인은 m.login.password로 홈서버에 요청한다', async () => {
  const sdk = fakeSdk();
  const creds = await loginWithPassword({
    homeserverUrl: 'https://matrix.example.com',
    user: 'minseo',
    password: 'pw',
    sdkLoader: async () => sdk,
  });
  const client = sdk.clients[0];
  assert.deepEqual(client.loginCall, {
    type: 'm.login.password',
    data: { identifier: { type: 'm.id.user', user: 'minseo' }, password: 'pw' },
  });
  assert.deepEqual(creds, { user_id: '@a:example.com', access_token: 'tok', device_id: 'D' });
  await assert.rejects(loginWithPassword({ homeserverUrl: 'https://matrix.example.com', user: '', password: 'pw', sdkLoader: async () => sdk }));
});

test('rust crypto 활성화 후 클라이언트를 시작한다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  await adapter.enableEncryption();
  // Node has no IndexedDB: the crypto store falls back to memory instead of failing.
  assert.equal(typeof indexedDB, 'undefined');
  assert.deepEqual(adapter.client.initRustCryptoOpts, { useIndexedDB: false });
  const states = [];
  adapter.start((state) => states.push(state));
  assert.ok(adapter.client.started);
  adapter.client.emit('sync', 'PREPARED');
  assert.deepEqual(states, ['PREPARED']);
  adapter.stop();
  assert.ok(adapter.client.stopped);
});

test('IndexedDB가 있으면 영구 저장소를 쓰고, 명시 옵션이 우선한다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  globalThis.indexedDB = {};
  try {
    await adapter.enableEncryption();
    assert.deepEqual(adapter.client.initRustCryptoOpts, { useIndexedDB: true });
    await adapter.enableEncryption({ useIndexedDB: false });
    assert.deepEqual(adapter.client.initRustCryptoOpts, { useIndexedDB: false });
  } finally {
    delete globalThis.indexedDB;
  }
  await adapter.enableEncryption({ useIndexedDB: true });
  assert.deepEqual(adapter.client.initRustCryptoOpts, { useIndexedDB: true });
});

test('rust crypto가 없으면 활성화가 실패한다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  adapter.client.initRustCrypto = undefined;
  await assert.rejects(adapter.enableEncryption(), /initRustCrypto/);
});

test('방 목록: m.direct·인원수·AI 표식으로 요약한다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  adapter.client.directContent['m.direct'] = { '@minseo:example.com': ['!dm:example.com'] };
  adapter.client.addRoom(room('!dm:example.com', { name: '', members: [member('@minseo:example.com', '민서'), member('@haejun:example.com', '해준')] }));
  adapter.client.addRoom(room('!family:example.com', { name: '우리 가족', members: [member('@minseo:example.com', '민서'), member('@haejun:example.com', '해준'), member('@helper:example.com', '도우미', 'agent')] }));
  const summaries = adapter.roomSummaries();
  const dm = summaries.find((r) => r.roomId === '!dm:example.com');
  const family = summaries.find((r) => r.roomId === '!family:example.com');
  assert.equal(dm.kind, 'private');
  assert.equal(dm.displayName, '해준');
  assert.equal(family.kind, 'family');
  assert.equal(family.displayName, '우리 가족');
  assert.deepEqual(family.agents.map((m) => m.userId), ['@helper:example.com']);
  assert.deepEqual(family.humans.map((m) => m.userId), ['@minseo:example.com', '@haejun:example.com']);
});

test('평문임이 확인되는 방으로의 전송은 거부된다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  adapter.client.encrypted.add('!family:example.com');
  await assert.rejects(adapter.sendText('!plain:example.com', '안녕'), PlaintextRefusedError);
  await assert.rejects(adapter.sendAttachment('!plain:example.com', { msgtype: 'm.image' }), PlaintextRefusedError);
  const sent = await adapter.sendText('!family:example.com', '  안녕  ');
  assert.match(sent.event_id, /e\d/);
  assert.equal(adapter.client.sent[0].content.body, '안녕');
  assert.equal(adapter.client.sent[0].type, 'm.room.message');
  assert.equal(await adapter.sendText('!family:example.com', '   '), null);
  assert.equal(adapter.client.sent.length, 1);
});

test('업로드는 mxc URL을 돌려주고 첨부 본문을 보낸다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  adapter.client.encrypted.add('!family:example.com');
  const data = new Uint8Array([1, 2, 3]);
  const upload = await adapter.uploadMedia({ name: 'photo.jpg', type: 'image/jpeg' }, data);
  assert.equal(upload.content_uri, 'mxc://example.com/up1');
  await adapter.sendAttachment('!family:example.com', { msgtype: 'm.image', url: 'mxc://example.com/up1' });
  assert.equal(adapter.client.uploads[0].opts.name, 'photo.jpg');
  assert.equal(adapter.client.sent[0].type, 'm.room.message');
});

test('타임라인 구독은 해제 함수를 돌려준다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  const events = [];
  const off = adapter.onTimeline((event) => events.push(event));
  adapter.client.emit('Room.timeline', 'evt1');
  off();
  adapter.client.emit('Room.timeline', 'evt2');
  assert.deepEqual(events, ['evt1']);
});

test('이모지 기기 검증: SAS 표시 → 확인 → 완료', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  await adapter.enableEncryption();

  const verifier = new EventEmitter();
  verifier.verify = () =>
    new Promise((resolve, reject) => {
      verifier.emit('show_sas', {
        sas: { emoji: [['🐶', 'dog'], ['🐱', 'cat']] },
        confirm: async () => resolve(),
        mismatch() {
          reject(new Error('mismatched sas'));
        },
      });
    });
  adapter.client.crypto.requestOwnUserVerification = async () => ({
    startVerification: async (method) => {
      assert.equal(method, 'm.sas.v1');
      return verifier;
    },
  });

  let done = 0;
  let cancelled = 0;
  const shown = [];
  await adapter.startEmojiVerification({
    onEmojis: (emojis, confirmers) => {
      shown.push(emojis);
      confirmers.confirm();
    },
    onDone: () => {
      done += 1;
    },
    onCancelled: () => {
      cancelled += 1;
    },
  });
  assert.deepEqual(shown, [[['🐶', 'dog'], ['🐱', 'cat']]]);
  assert.equal(done, 1);
  assert.equal(cancelled, 0);
});

test('SAS 불일치를 신고하면 검증이 실패로 끝난다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  await adapter.enableEncryption();

  const verifier = new EventEmitter();
  verifier.verify = () =>
    new Promise((_resolve, reject) => {
      verifier.emit('show_sas', {
        sas: { emoji: [['🐷', 'pig']] },
        confirm: async () => {},
        mismatch() {
          reject(new Error('mismatched sas'));
        },
      });
    });
  adapter.client.crypto.requestOwnUserVerification = async () => ({
    startVerification: async () => verifier,
  });

  let cancelled = 0;
  const shown = [];
  await assert.rejects(
    adapter.startEmojiVerification({
      onEmojis: (emojis, confirmers) => {
        shown.push(emojis);
        confirmers.mismatch();
      },
      onDone: () => assert.fail('완료되어서는 안 된다'),
      onCancelled: () => {
        cancelled += 1;
      },
    }),
    /mismatched/,
  );
  assert.equal(shown.length, 1);
  assert.equal(cancelled, 0);
});

test('sendText는 멘션 목록을 m.mentions 구조로 실어 보낸다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  adapter.client.encrypted.add('!family:example.com');
  const sent = await adapter.sendText('!family:example.com', '안녕', [
    '@helper:example.com', '@helper:example.com', 'not-a-user-id',
  ]);
  assert.match(sent.event_id, /e\d/);
  assert.deepEqual(adapter.client.sent[0].content['m.mentions'].user_ids, ['@helper:example.com']);
});

test('멘션이 없으면 m.mentions 필드를 넣지 않는다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  adapter.client.encrypted.add('!family:example.com');
  await adapter.sendText('!family:example.com', '안녕', []);
  assert.equal(adapter.client.sent[0].content['m.mentions'], undefined);
});

test('roomMemberHandles는 가입 멤버의 localpart를 돌려준다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  adapter.client.addRoom(room('!r:example.com', {
    name: 'r',
    members: [
      { userId: '@minseo:example.com', name: '민서', events: { member: { getContent: () => ({ membership: 'join' }) } } },
      { userId: '@guest:example.com', name: 'g', events: { member: { getContent: () => ({ membership: 'invite' }) } } },
    ],
  }));
  assert.deepEqual(adapter.roomMemberHandles('!r:example.com'), [
    { userId: '@minseo:example.com', localpart: 'minseo' },
  ]);
  assert.deepEqual(adapter.roomMemberHandles('!missing:example.com'), []);
});

test('초대 목록: 초대된 방만, 초대자와 AI 참여자를 요약한다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  const fakeMember = (userId, name, { membership = 'join', kind, sender } = {}) => ({
    userId,
    name,
    events: {
      member: {
        getContent: () => (kind ? { 'us.familychat.kind': kind } : { membership }),
        ...(sender ? { getSender: () => sender } : {}),
      },
    },
  });
  // 내 멤버십이 join인 방 — 초대 목록에서 제외된다.
  adapter.client.addRoom(room('!family:example.com', { name: '우리 가족', members: [fakeMember('@minseo:example.com', '민서')] }));
  // 초대된 가족방: AI(봇) 참여자 + 초대자 표시.
  adapter.client.addRoom({
    roomId: '!invited:example.com',
    name: '',
    getMembers: () => [
      fakeMember('@haejun:example.com', '해준', { sender: '@haejun:example.com' }),
      fakeMember('@helper:example.com', '도우미', { kind: 'agent' }),
      fakeMember('@minseo:example.com', '민서', { membership: 'invite', sender: '@haejun:example.com' }),
    ],
    getJoinedMemberCount: () => 2,
    getMyMember: () => ({ membership: 'invite', events: { member: { getSender: () => '@haejun:example.com' } } }),
  });
  const invites = adapter.inviteSummaries();
  assert.deepEqual(invites.map((i) => i.roomId), ['!invited:example.com']);
  const invite = invites[0];
  assert.equal(invite.kind, 'family'); // 합류 2 + 나(초대) = 전체 3명 기준
  assert.equal(invite.memberCount, 3);
  assert.equal(invite.inviterName, '해준'); // 초대 이벤트 sender의 표시 이름
  assert.deepEqual(invite.agents.map((m) => m.userId), ['@helper:example.com']);
  assert.equal(invite.requiresAiConsent === undefined, true); // 게이트 판정은 describeInvite가 담당
});

test('수락·거절은 SDK joinRoom/leave로 전달된다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  await adapter.joinRoom('!invited:example.com');
  await adapter.declineInvite('!other:example.com');
  assert.deepEqual(adapter.client.joinedRooms, ['!invited:example.com']);
  assert.deepEqual(adapter.client.leftRooms, ['!other:example.com']);
});

test('새 방이 보이면 onRoomAdded 콜백이 불리고 해제된다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  const seen = [];
  const off = adapter.onRoomAdded((roomObj) => seen.push(roomObj.roomId));
  adapter.client.emit('Room', { roomId: '!invited:example.com' });
  adapter.client.emit('Room', { roomId: '!second:example.com' });
  off();
  adapter.client.emit('Room', { roomId: '!third:example.com' });
  assert.deepEqual(seen, ['!invited:example.com', '!second:example.com']);
});

function encryptedEvent({ decrypted = false, pending = !decrypted } = {}) {
  const ev = new EventEmitter();
  let clear = decrypted;
  ev.isEncrypted = () => true;
  ev.isBeingDecrypted = () => pending && !clear;
  ev.getType = () => (clear ? 'm.room.message' : 'm.room.encrypted');
  ev.finishDecryption = () => {
    clear = true;
    ev.emit('Event.decrypted', ev);
  };
  return ev;
}

test('암호화 이벤트는 복호화가 끝난 뒤에만 전달된다 (#125)', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  const seen = [];
  adapter.onTimeline((event) => seen.push(event.getType()));
  const ev = encryptedEvent();
  adapter.client.emit('Room.timeline', ev);
  assert.deepEqual(seen, [], 'Room.timeline 시점(암호문)에는 전달하지 않는다');
  ev.finishDecryption();
  assert.deepEqual(seen, ['m.room.message']);
  // 키가 늦게 도착해 다시 복호화되면 같은 이벤트가 한 번 더 전달된다(치환은 소비자 몫).
  ev.finishDecryption();
  assert.deepEqual(seen, ['m.room.message', 'm.room.message']);
});

test('이미 복호화된 암호화 이벤트와 평문 이벤트는 즉시 전달된다', async () => {
  const sdk = fakeSdk();
  const adapter = await createFamilyClient({ ...CREDS, sdkLoader: async () => sdk });
  const seen = [];
  const off = adapter.onTimeline((event) => seen.push(typeof event === 'string' ? event : event.getType()));
  adapter.client.emit('Room.timeline', encryptedEvent({ decrypted: true }));
  adapter.client.emit('Room.timeline', { isEncrypted: () => false, getType: () => 'm.room.message', on() {} });
  adapter.client.emit('Room.timeline', 'plain');
  assert.deepEqual(seen, ['m.room.message', 'm.room.message', 'plain']);
  off();
  adapter.client.emit('Room.timeline', encryptedEvent({ decrypted: true }));
  assert.equal(seen.length, 3);
});
