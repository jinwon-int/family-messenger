// relay.js /v2/me (#574): meInfo() 는 본문 전체, me() 는 subject 만 — 옛 릴레이({subject} 만)·404(접근 인증 꺼짐)·오류.
// node --test archive/native-mls/web/hande/tests/relay.test.mjs
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createRelay} from '../relay.js';

const fetchWith = (status, body) => async () => ({status, json: async () => { if (body === undefined) throw new Error('no body'); return body; }});

test('meInfo: 기기 스토어가 있는 릴레이는 subject·policy_revision·devices 를 통째로', async () => {
  const body = {subject: 'sub-1', policy_revision: 7, devices: [{device_id: 'mom-web-a', actor: 'mom', fingerprint: 'fe'.repeat(32), status: 'active', acceptance: 'operator', roles: ['registrar']}]};
  const relay = createRelay({fetch: fetchWith(200, body)});
  assert.deepEqual(await relay.meInfo(), body);
  assert.equal(await relay.me(), 'sub-1');
});

test('meInfo: 옛 릴레이는 {subject} 만, 404 는 null, 그 밖은 throw', async () => {
  assert.deepEqual(await createRelay({fetch: fetchWith(200, {subject: 'sub-1'})}).meInfo(), {subject: 'sub-1'});
  assert.equal(await createRelay({fetch: fetchWith(404, {error: 'not_found'})}).meInfo(), null);
  assert.equal(await createRelay({fetch: fetchWith(404, {error: 'not_found'})}).me(), null);
  await assert.rejects(() => createRelay({fetch: fetchWith(500, {error: 'device_policy_unavailable'})}).meInfo(), /\/v2\/me 500 device_policy_unavailable/);
  await assert.rejects(() => createRelay({fetch: fetchWith(200, {nope: 1})}).meInfo(), /\/v2\/me 200/);
});

test('room-order v1(#715): GET /v2/me/room-order?device= · PUT {device, rooms, base_revision} — 상태·본문을 그대로 돌려준다', async () => {
  const seen = [];
  const fetch = async (path, init) => {
    seen.push({path, method: init.method, body: init.body === undefined ? undefined : JSON.parse(init.body), headers: init.headers, credentials: init.credentials});
    if (init.method === 'GET') return {status: 200, json: async () => ({rooms: ['family'], revision: 2, updated_at: 9})};
    return {status: 409, json: async () => ({error: 'revision_conflict', rooms: ['family'], revision: 2, updated_at: 9})};
  };
  const relay = createRelay({fetch});
  assert.deepEqual(await relay.getRoomOrder('owner-web 1'), {status: 200, body: {rooms: ['family'], revision: 2, updated_at: 9}});
  assert.deepEqual(await relay.putRoomOrder('owner-web-1', ['family', 'b'], 1), {status: 409, body: {error: 'revision_conflict', rooms: ['family'], revision: 2, updated_at: 9}});
  assert.equal(seen[0].path, '/v2/me/room-order?device=owner-web%201');
  assert.equal(seen[0].method, 'GET');
  assert.equal(seen[0].credentials, 'same-origin');
  assert.deepEqual(seen[1], {path: '/v2/me/room-order', method: 'PUT', body: {device: 'owner-web-1', rooms: ['family', 'b'], base_revision: 1},
    headers: {'Content-Type': 'application/json'}, credentials: 'same-origin'});
});

test('room-order v1: 404(옛 릴레이)는 throw 하지 않고, 네트워크 실패는 network 오류로 throw', async () => {
  assert.deepEqual(await createRelay({fetch: fetchWith(404, {error: 'not_found'})}).getRoomOrder('d'), {status: 404, body: {error: 'not_found'}});
  const down = createRelay({fetch: async () => { throw new TypeError('Failed to fetch'); }});
  await assert.rejects(() => down.putRoomOrder('d', [], 0), e => e.network === true);
});
