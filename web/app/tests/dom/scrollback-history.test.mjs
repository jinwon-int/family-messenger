// #279: heartbeat/progress edits must not make back-pagination stop before the real start.
// Real pinned SDK (Room, timeline set, scrollback, event mapper); only HTTP is synthetic.
// Lives under tests/dom/ because it needs the installed SDK (npm test runs before npm ci).
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { ClientAdapter } from '../../src/matrix/client.js';

const sdk = createRequire(import.meta.url)('matrix-js-sdk');
// FetchHttpApi request logs drown the test output.
const silent = { trace() {}, debug() {}, info() {}, warn() {}, error() {}, getChild: () => silent };
const ROOM = '!r:example.test';
const ME = '@owner:example.test';
const BOT = '@bot:example.test';
const tick = () => new Promise((resolve) => setImmediate(resolve));

// History shaped like a node room (2026-10-05 jingun sample: 57% edits, 12% redactions,
// edit→original distance often > one page): progress messages edited many times, interleaved.
function nodeRoomHistory(size, seed) {
  let s = seed;
  const rnd = () => ((s = (s * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
  const h = [{ event_id: '$e0', room_id: ROOM, sender: ME, type: 'm.room.create', state_key: '', origin_server_ts: 1, content: {} }];
  const open = [];
  while (h.length < size) {
    const i = h.length;
    const r = rnd();
    const base = { event_id: `$e${i}`, room_id: ROOM, sender: BOT, origin_server_ts: 1000 + i };
    if (r < 0.1) {
      h.push({ ...base, type: 'm.room.message', content: { msgtype: 'm.notice', body: `⏳ Working ${i}` } });
      open.push({ id: `$e${i}`, left: 4 + Math.floor(rnd() * 8) });
    } else if (r < 0.66 && open.length) {
      const t = open[Math.floor(rnd() * open.length)];
      h.push({ ...base, type: 'm.room.message', content: { msgtype: 'm.notice', body: '* ⏳', 'm.new_content': { msgtype: 'm.notice', body: '⏳' }, 'm.relates_to': { rel_type: 'm.replace', event_id: t.id } } });
      if (--t.left === 0) open.splice(open.indexOf(t), 1);
    } else if (r < 0.78 && i > 1) {
      h.push({ ...base, type: 'm.room.redaction', redacts: `$e${i - 1 - Math.floor(rnd() * 3)}`, content: {} });
    } else {
      h.push({ ...base, type: 'm.room.message', content: { msgtype: 'm.text', body: `msg ${i}` } });
    }
  }
  return h;
}

async function scrollToStart(seed) {
  const H = nodeRoomHistory(900, seed);
  const N = H.length;
  const requests = { context: 0, event: 0 };
  const fetchFn = async (url) => {
    const u = new URL(url);
    let body = {};
    const ctx = u.pathname.match(/\/context\/(.+)$/);
    const single = u.pathname.match(/\/event\/(.+)$/);
    if (ctx) {
      requests.context++;
      const i = Number(decodeURIComponent(ctx[1]).slice(2));
      body = { event: H[i], events_before: [], events_after: [], state: [], start: `t${i}`, end: `f${i}` };
    } else if (single) {
      requests.event++;
      body = H[Number(decodeURIComponent(single[1]).slice(2))];
    } else if (u.pathname.endsWith('/messages')) {
      const from = Number(u.searchParams.get('from').slice(1));
      const limit = Number(u.searchParams.get('limit'));
      const chunk = [];
      for (let i = from - 1; i >= Math.max(0, from - limit); i--) chunk.push(H[i]);
      body = { chunk, start: `t${from}`, ...(from - limit > 0 ? { end: `t${from - limit}` } : {}) };
    }
    return new Response(JSON.stringify(body), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  const client = sdk.createClient({ baseUrl: 'https://matrix.example.test', userId: ME, accessToken: 'synthetic', timelineSupport: true, fetchFn, logger: silent });
  const room = new sdk.Room(ROOM, client, ME, { timelineSupport: true });
  client.store.storeRoom(room);
  client.reEmitter.reEmit(room, ['Room.timeline', 'Room.redaction', 'Room.timelineReset']);
  const adapter = new ClientAdapter(client, ME);
  const seen = new Set();
  const off = adapter.onTimeline((event) => { if (event.getId?.()) seen.add(event.getId()); });
  // initial sync window (initialSyncLimit: 20)
  room.getLiveTimeline().setPaginationToken(`t${N - 20}`, 'b');
  const live = H.slice(N - 20).map((e) => client.getEventMapper()(e));
  await room.addLiveEvents(live, { addToState: false });
  for (const e of live) client.emit('event', e);
  // == main.js loadEarlier loop (hasMore from the server token)
  let pages = 0;
  const stalls = [];
  while (adapter.canLoadEarlier(ROOM) && pages < 200) {
    for (let i = 0; i < 5; i++) await tick(); // let edit-target recovery requests settle, as a user scroll would
    const added = await adapter.loadEarlier(ROOM, 30);
    pages++;
    if (added === 0) stalls.push(pages);
  }
  for (let i = 0; i < 5; i++) await tick();
  off();
  const events = room.getLiveTimeline().getEvents();
  client.stopClient();
  return { pages, stalls, oldest: events[0]?.getId(), liveCount: events.length, timelines: room.getUnfilteredTimelineSet().getTimelines().length, seen, requests, N };
}

for (const seed of [1, 2, 3, 7, 11]) {
  test(`node-room history (seed ${seed}): back-pagination reaches the real start and never stalls`, async () => {
    const r = await scrollToStart(seed);
    assert.equal(r.oldest, '$e0', 'live timeline must reach the room creation event');
    assert.deepEqual(r.stalls, [], 'a page added nothing to the live timeline');
    assert.equal(r.timelines, 1, 'edit-target recovery must not add side timelines');
    assert.equal(r.requests.context, 0, 'no /context (getEventTimeline) requests');
    assert.equal(r.liveCount, r.N, 'every event is on the live timeline');
  });
}
