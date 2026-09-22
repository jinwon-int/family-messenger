import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { build } from 'esbuild';
import { Window } from 'happy-dom';
import { ClientAdapter } from '../../src/matrix/client.js';
import { saveSession } from '../../src/session.js';

const sdk = createRequire(import.meta.url)('matrix-js-sdk');
const bundle = await build({
  entryPoints: [new URL('../../src/main.js', import.meta.url).pathname],
  bundle: true, write: false, format: 'iife', platform: 'browser',
  plugins: [{ name: 'test-client', setup(builder) {
    builder.onResolve({ filter: /\/matrix\/client\.js$/ }, () => ({ path: 'client', namespace: 'fixture' }));
    builder.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({ contents: `
      export const createFamilyClient = async () => window.testClient;
      export const loginWithPassword = async () => { throw new Error('Unexpected login'); };
      export class PlaintextRefusedError extends Error {}
    ` }));
  } }],
});
const flush = () => new Promise((resolve) => setImmediate(resolve));
const content = (body) => ({ msgtype: 'm.text', body });
const roomId = '!room:example.test';
const bot = '@bot:example.test';

// Real pinned SDK Room/event-mapper/relation aggregation, synthetic wire events.
// Only login, encryption initialization and network sync are bypassed.
async function app(t, initial = []) {
  const window = new Window({ url: 'https://chat.example.test/' });
  t.after(() => window.happyDOM.abort());
  window.document.body.innerHTML = '<div id="app"></div>';
  window.fetch = async () => ({ ok: true, json: async () => ({}) });
  const client = sdk.createClient({ baseUrl: 'https://matrix.example.test', userId: '@owner:example.test', accessToken: 'synthetic', timelineSupport: true });
  const room = new sdk.Room(roomId, client, '@owner:example.test', { timelineSupport: true });
  client.store.storeRoom(room);
  client.reEmitter.reEmit(room, ['Room.timeline', 'Room.redaction', 'Room.localEchoUpdated', 'Room.timelineReset']);
  const adapter = new ClientAdapter(client, '@owner:example.test');
  let synced;
  Object.assign(adapter, {
    enableEncryption: async () => {}, start(callback) { synced = callback; },
    roomSummaries: () => [{ roomId, displayName: '시험', kind: 'private', memberCount: 2, agents: [] }],
    inviteSummaries: () => [], canLoadEarlier: () => false,
  });
  window.testClient = adapter;
  saveSession({ homeserverUrl: 'https://matrix.example.test', userId: '@owner:example.test', deviceId: 'TEST', accessToken: 'synthetic' }, {
    persistent: window.localStorage, volatile: window.sessionStorage,
  });
  const send = async (id, ts, data, sender = bot, extra = {}) => {
    const event = client.getEventMapper()({ room_id: roomId, event_id: id, type: 'm.room.message', sender, origin_server_ts: ts, content: data, ...extra });
    await room.addLiveEvents([event], { addToState: false });
    client.emit('event', event);
    await flush();
    return event;
  };
  const edit = (id, target, ts, body, sender = bot) => send(id, ts, {
    ...content('* ' + body), 'm.new_content': content(body), 'm.relates_to': { rel_type: 'm.replace', event_id: target },
  }, sender);
  for (const args of initial) await send(...args);
  window.eval(bundle.outputFiles[0].text);
  for (let i = 0; i < 30 && !window.document.querySelector('.room-item'); i++) await flush();
  assert.ok(synced);
  synced('PREPARED');
  window.document.querySelector('.room-item').click();
  const bubbles = () => [...window.document.querySelectorAll('.timeline .bubble')].map((node) => node.textContent);
  const redact = (target) => send('$redact-' + target, 500, {}, bot, { type: 'm.room.redaction', redacts: target });
  return { window, client, room, adapter, send, edit, redact, bubbles, synced };
}

test('SDK edits update one heartbeat, move it after intervening chat, and retain the draft', async (t) => {
  const a = await app(t);
  await a.send('$work', 100, content('⏳ Working — 1s'));
  await a.send('$chat', 200, content('진행 상황을 알려줘'), '@owner:example.test');
  const input = a.window.document.querySelector('textarea');
  input.value = '작성 중인 초안';
  for (let i = 0; i < 4; i++) await a.edit('$edit' + i, '$work', 300 + i, `⏳ Working — ${i + 2}s`);
  const rows = a.bubbles();
  assert.equal(rows.length, 2);
  assert.match(rows[0], /진행 상황/);
  assert.match(rows[1], /⏳ Working — 5s/);
  assert.doesNotMatch(rows.join(''), /\* ⏳/);
  assert.equal(a.window.document.querySelector('textarea'), input);
  assert.equal(input.value, '작성 중인 초안');
});

test('ordinary edits keep their position; forged and older edits cannot replace current content', async (t) => {
  const a = await app(t);
  await a.send('$answer', 100, content('답변 초안'));
  await a.send('$other', 200, content('다음 대화'));
  await a.edit('$valid', '$answer', 400, '수정된 답변');
  await a.edit('$forged', '$answer', 900, '가짜 답변', '@attacker:example.test');
  await a.edit('$old', '$answer', 300, '오래된 수정');
  assert.equal(a.bubbles().length, 2);
  assert.match(a.bubbles()[0], /수정된 답변/);
  assert.match(a.bubbles()[1], /다음 대화/);
});

test('redact/repost and final cleanup remove the previous heartbeat and all edit envelopes', async (t) => {
  const a = await app(t);
  await a.send('$work', 100, content('⏳ Working — 1s'));
  await a.edit('$edit', '$work', 150, '⏳ Working — 2s');
  await a.redact('$work');
  await a.send('$work2', 200, content('⏳ Waiting for progress — 3s'));
  assert.equal(a.bubbles().length, 1);
  assert.match(a.bubbles()[0], /Waiting for progress/);
  await a.send('$answer', 300, content('최종 답변'));
  await a.redact('$work2');
  assert.equal(a.bubbles().length, 1);
  assert.match(a.bubbles()[0], /최종 답변/);
  a.synced('PREPARED');
  assert.equal(a.bubbles().length, 1, 'hydration must not resurrect redacted bubbles');
});

test('reload hydrates one latest heartbeat at its update position; late old edits do not float it', async (t) => {
  const initial = [
    ['$work', 100, content('⏳ Working — 1s')],
    ['$edit', 250, { ...content('* ⏳ Working — 2s'), 'm.new_content': content('⏳ Working — 2s'), 'm.relates_to': { rel_type: 'm.replace', event_id: '$work' } }],
    ['$chat', 200, content('앞 대화')],
    ['$later', 300, content('뒤 대화')],
  ];
  const a = await app(t, initial);
  assert.equal(a.bubbles().length, 3);
  assert.match(a.bubbles()[0], /앞 대화/);
  assert.match(a.bubbles()[1], /Working — 2s/);
  assert.match(a.bubbles()[2], /뒤 대화/);
  await a.edit('$late', '$work', 150, '⏳ Working — 0s');
  assert.match(a.bubbles()[1], /Working — 2s/);
});

test('an initial sync containing only edits recovers the original with SDK context', async (t) => {
  const a = await app(t);
  let requests = 0;
  a.client.getEventContext = async (_roomId, id) => {
    requests++;
    assert.equal(id, '$outside');
    return { event: { event_id: id, room_id: roomId, type: 'm.room.message', sender: bot,
      origin_server_ts: 100, content: content('⏳ Working — 1s') }, events_before: [], events_after: [], state: [] };
  };
  await a.edit('$latest', '$outside', 900, '⏳ Working — 9s');
  for (let i = 0; i < 10 && a.bubbles().length === 0; i++) await flush();
  assert.equal(requests, 1);
  assert.equal(a.bubbles().length, 1);
  assert.match(a.bubbles()[0], /Working — 9s/);
});

test('late encrypted edits collapse into the original; an older decrypt cannot overwrite the latest', async (t) => {
  const a = await app(t);
  await a.send('$work', 100, content('⏳ Working — 1s'));
  async function ciphertext(id, ts) {
    const relation = { rel_type: 'm.replace', event_id: '$work' };
    const event = a.client.getEventMapper({ decrypt: false })({ event_id: id, room_id: roomId, sender: bot,
      origin_server_ts: ts, type: 'm.room.encrypted', content: { algorithm: 'm.megolm.v1.aes-sha2', 'm.relates_to': relation } });
    await a.room.addLiveEvents([event], { addToState: false });
    return async (body) => {
      await event.attemptDecryption({ decryptEvent: async () => ({ clearEvent: {
        type: 'm.room.message', content: { ...content('* ' + body), 'm.new_content': content(body), 'm.relates_to': relation },
      } }) });
      await flush();
    };
  }
  const decryptOld = await ciphertext('$old', 200);
  const decryptNew = await ciphertext('$new', 300);
  assert.equal(a.bubbles().length, 1);
  await decryptNew('⏳ Working — 3s');
  await decryptOld('⏳ Working — 2s');
  assert.equal(a.bubbles().length, 1);
  assert.match(a.bubbles()[0], /Working — 3s/);
  await a.redact('$work');
  assert.equal(a.bubbles().length, 1, 'progress redact waits for the answer instead of collapsing the scroller');
  await a.send('$done', 400, content('최종 답변'));
  assert.equal(a.bubbles().length, 1);
  assert.match(a.bubbles()[0], /최종 답변/);
});

test('redact then repost keeps one progress bubble and the same timeline element', async (t) => {
  const a = await app(t);
  await a.send('$work', 100, content('⏳ Working — 1s'));
  await a.send('$chat', 200, content('중간에 온 말'), '@owner:example.test');
  const list = a.window.document.querySelector('.timeline');
  const bubble = a.window.document.querySelector('li.bubble.is-progress');
  assert.ok(list);
  assert.ok(bubble);
  await a.edit('$edit', '$work', 250, '⏳ Working — 9s | Read: file.py');
  assert.ok(a.window.document.querySelector('.timeline') === list, 'edit keeps timeline');
  assert.ok(a.window.document.querySelector('li.bubble.is-progress') === bubble, 'edit keeps progress node');
  assert.match(bubble.textContent, /Read: file.py/);
  await a.redact('$work');
  assert.equal(a.bubbles().length, 2);
  assert.ok(a.window.document.querySelector('.timeline') === list, 'redact keeps timeline');
  await a.send('$work2', 300, content('⏳ Waiting for progress — 3s'));
  assert.equal(a.bubbles().length, 2);
  assert.ok(a.window.document.querySelector('.timeline') === list, 'repost keeps timeline');
  assert.ok(a.window.document.querySelector('li.bubble.is-progress') === bubble, 'repost keeps progress node');
  assert.match(bubble.textContent, /Waiting for progress/);
  assert.doesNotMatch(bubble.textContent, /Working — 1s/);
  await a.redact('$work2');
  await a.send('$answer', 400, content('최종 답변'));
  assert.equal(a.bubbles().length, 2);
  assert.match(a.bubbles().join('\n'), /최종 답변/);
  assert.doesNotMatch(a.bubbles().join('\n'), /Waiting for progress/);
});

test('context-recovered ordinary edits return to their original chronological position', async (t) => {
  const a = await app(t);
  await a.send('$old', 50, content('먼저 온 대화'));
  await a.send('$newer', 300, content('나중 대화'));
  a.client.getEventContext = async () => ({
    event: { event_id: '$missing', room_id: roomId, type: 'm.room.message', sender: bot,
      origin_server_ts: 100, content: content('원래 답변') },
    events_before: [], events_after: [], state: [],
  });
  await a.edit('$edit-missing', '$missing', 400, '수정된 중간 답변');
  for (let i = 0; i < 10 && a.bubbles().length < 3; i++) await flush();
  assert.equal(a.bubbles().length, 3);
  assert.match(a.bubbles()[0], /먼저 온 대화/);
  assert.match(a.bubbles()[1], /수정된 중간 답변/);
  assert.match(a.bubbles()[2], /나중 대화/);
});

test('delayed ordinary decryption preserves server order', async (t) => {
  const a = await app(t);
  const event = a.client.getEventMapper({ decrypt: false })({ event_id: '$early', room_id: roomId, sender: bot,
    origin_server_ts: 100, type: 'm.room.encrypted', content: { algorithm: 'm.megolm.v1.aes-sha2' } });
  await a.room.addLiveEvents([event], { addToState: false });
  await a.send('$mine', 200, content('LATER_SELF'), '@owner:example.test');
  await event.attemptDecryption({ decryptEvent: async () => ({ clearEvent: {
    type: 'm.room.message', content: content('EARLIER_OTHER'),
  } }) });
  await flush();
  assert.deepEqual(a.bubbles().map(s => s.includes('EARLIER_OTHER') ? 'early' : 'late'), ['early', 'late']);
});


test('own sent echo updates the displayed event identity', async (t) => {
  const a = await app(t);
  const local = new sdk.MatrixEvent({ event_id: '~local', room_id: roomId, sender: '@owner:example.test',
    origin_server_ts: 100, type: 'm.room.message', content: content('SELF_MESSAGE') });
  local.setStatus(sdk.EventStatus.SENDING);
  a.room.addPendingEvent(local, 'test-txn');
  await flush();
  a.room.updatePendingEvent(local, sdk.EventStatus.SENT, '$confirmed');
  await flush();
  assert.deepEqual([...a.window.document.querySelectorAll('li.bubble')].map(e => e.dataset.eventId), ['$confirmed']);
});


test('remote echo and subsequent hydration keep one message with server time', async (t) => {
  const a = await app(t);
  const local = new sdk.MatrixEvent({ event_id: '~local', room_id: roomId, sender: '@owner:example.test',
    origin_server_ts: 999, type: 'm.room.message', content: content('SELF_MESSAGE') });
  local.setStatus(sdk.EventStatus.SENDING);
  a.room.addPendingEvent(local, 'test-txn');
  await a.send('$other', 200, content('OTHER_MESSAGE'));
  a.room.updatePendingEvent(local, sdk.EventStatus.SENT, '$confirmed');
  await a.send('$confirmed', 100, content('SELF_MESSAGE'), '@owner:example.test', { unsigned: { transaction_id: 'test-txn' } });
  a.synced('PREPARED');
  assert.deepEqual([...a.window.document.querySelectorAll('li.bubble')].map(e => e.dataset.eventId), ['$confirmed', '$other']);
});

test('cancelled pending sends disappear instead of surviving as stale bubbles', async (t) => {
  const a = await app(t);
  const local = new sdk.MatrixEvent({ event_id: '~cancel', room_id: roomId, sender: '@owner:example.test',
    origin_server_ts: 100, type: 'm.room.message', content: content('UNSENT') });
  local.setStatus(sdk.EventStatus.NOT_SENT);
  a.room.addPendingEvent(local, 'cancel-txn');
  assert.equal(a.bubbles().length, 1);
  a.room.updatePendingEvent(local, sdk.EventStatus.CANCELLED);
  assert.equal(a.bubbles().length, 0);
});

async function addMissedEvent(a) {
  // Simulate the SDK having newer history than the app snapshot after suspension.
  a.client.reEmitter.stopReEmitting(a.room, ['Room.timeline']);
  await a.send('$missed', 100, content('RECOVERED'));
  a.client.reEmitter.reEmit(a.room, ['Room.timeline']);
  assert.equal(a.bubbles().length, 0);
}

test('SYNCING after reconnect reconciles missed SDK history and retains composer draft', async (t) => {
  const a = await app(t);
  const input = a.window.document.querySelector('textarea');
  input.value = 'draft';
  a.synced('RECONNECTING');
  await addMissedEvent(a);
  a.synced('SYNCING');
  assert.equal(a.bubbles().length, 1);
  assert.match(a.bubbles()[0], /RECOVERED/);
  assert.equal(a.window.document.querySelector('textarea').value, 'draft');
  assert.equal(a.window.document.querySelector('.status.warn'), null);
});

test('returning to the app nudges sync and recovers missed history without another login', async (t) => {
  const a = await app(t);
  let retries = 0;
  a.client.retryImmediately = () => { retries++; };
  await addMissedEvent(a);
  a.window.document.dispatchEvent(new a.window.Event('visibilitychange'));
  assert.equal(retries, 1);
  assert.equal(a.bubbles().length, 1);
  a.window.dispatchEvent(new a.window.Event('online'));
  assert.equal(retries, 2);
  assert.equal(a.bubbles().length, 1);
});


test('ordinary edits and resume preserve equal-timestamp message order', async (t) => {
  const a = await app(t);
  await a.send('$first', 100, content('FIRST'));
  await a.send('$second', 100, content('SECOND'));
  await a.edit('$edit', '$first', 200, 'FIRST_EDITED');
  a.window.dispatchEvent(new a.window.Event('pageshow'));
  assert.deepEqual([...a.window.document.querySelectorAll('li.bubble')].map(e => e.dataset.eventId), ['$first', '$second']);
});


async function encryptedEvent(a, id, ts) {
  const event = a.client.getEventMapper({ decrypt: false })({ event_id: id, room_id: roomId, sender: bot,
    origin_server_ts: ts, type: 'm.room.encrypted', content: { algorithm: 'm.megolm.v1.aes-sha2' } });
  await a.room.addLiveEvents([event], { addToState: false });
  return event;
}
async function decryptEvent(event, body) {
  await event.attemptDecryption({ decryptEvent: async () => ({ clearEvent: { type: 'm.room.message', content: content(body) } }) });
  await flush();
}

test('equal-timestamp encrypted messages retain SDK order when decryption completes backwards', async (t) => {
  const a = await app(t);
  const first = await encryptedEvent(a, '$first', 100);
  const second = await encryptedEvent(a, '$second', 100);
  await decryptEvent(second, 'SECOND');
  await decryptEvent(first, 'FIRST');
  assert.deepEqual([...a.window.document.querySelectorAll('li.bubble')].map(e => e.dataset.eventId), ['$first', '$second']);
});

test('hydrated failed decryptions update after the missing key arrives', async (t) => {
  const a = await app(t);
  a.client.reEmitter.stopReEmitting(a.room, ['Room.timeline']);
  const event = await encryptedEvent(a, '$missed-encrypted', 100);
  await event.attemptDecryption({ decryptEvent: async () => { throw new Error('synthetic missing key'); } });
  a.client.reEmitter.reEmit(a.room, ['Room.timeline']);
  a.window.dispatchEvent(new a.window.Event('online'));
  assert.equal(a.bubbles().length, 1);
  assert.doesNotMatch(a.bubbles()[0], /RECOVERED_KEY/);
  await decryptEvent(event, 'RECOVERED_KEY');
  assert.match(a.bubbles()[0], /RECOVERED_KEY/);
});

test('timeline reset invalidates both hydration and live decryption subscriptions', async (t) => {
  const a = await app(t);
  const live = await encryptedEvent(a, '$old-live', 100);
  a.client.reEmitter.stopReEmitting(a.room, ['Room.timeline']);
  const missed = await encryptedEvent(a, '$old-missed', 200);
  a.client.reEmitter.reEmit(a.room, ['Room.timeline']);
  a.window.dispatchEvent(new a.window.Event('online'));
  a.room.resetLiveTimeline(null, null);
  await decryptEvent(live, 'STALE_LIVE');
  await decryptEvent(missed, 'STALE_MISSED');
  assert.equal(a.bubbles().length, 0);
  await a.send('$new', 300, content('CURRENT'));
  assert.equal(a.bubbles().length, 1);
  assert.match(a.bubbles()[0], /CURRENT/);
});

test('late old progress cannot replace the newest heartbeat during decryption or resume', async (t) => {
  const a = await app(t);
  const old = await encryptedEvent(a, '$old', 100);
  const current = await encryptedEvent(a, '$current', 200);
  await decryptEvent(current, '⏳ Working — 9s');
  await decryptEvent(old, '⏳ Working — 1s');
  assert.equal(a.bubbles().length, 1);
  assert.match(a.bubbles()[0], /Working — 9s/);
  a.window.dispatchEvent(new a.window.Event('online'));
  assert.equal(a.bubbles().length, 1);
  assert.match(a.bubbles()[0], /Working — 9s/);
});


test('equal-timestamp heartbeats keep the newer SDK event after a late decryption', async (t) => {
  const a = await app(t);
  const old = await encryptedEvent(a, '$old', 100);
  const current = await encryptedEvent(a, '$current', 100);
  await decryptEvent(current, '⏳ Working — 9s');
  await decryptEvent(old, '⏳ Working — 1s');
  assert.equal(a.bubbles().length, 1);
  assert.match(a.bubbles()[0], /Working — 9s/);
});


test('resume with older answers does not erase a held progress bubble', async (t) => {
  const a = await app(t);
  await a.send('$old-answer', 100, content('OLDER_ANSWER'));
  await a.send('$progress', 200, content('⏳ Working — 2s'));
  await a.redact('$progress');
  a.window.dispatchEvent(new a.window.Event('online'));
  assert.equal(a.bubbles().length, 2);
  assert.match(a.bubbles()[1], /Working — 2s/);
  await a.send('$new-answer', 300, content('NEW_ANSWER'));
  assert.equal(a.bubbles().length, 2);
  assert.doesNotMatch(a.bubbles().join(' '), /Working/);
});
