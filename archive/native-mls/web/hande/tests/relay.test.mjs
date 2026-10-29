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
