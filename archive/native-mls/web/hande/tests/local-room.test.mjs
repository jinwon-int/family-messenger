// 로컬 전용 방 「이 기기에서 지우기」 순수 로직. node --test archive/native-mls/web/hande/tests/local-room.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isLocalOnlyRoom, isRoomKey, forgetRoomKeys } from '../local-room.js';

function fakeStorage(init = {}) {
  const store = new Map(Object.entries(init));
  const storage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
  };
  return new Proxy(storage, { ownKeys: () => [...store.keys()], getOwnPropertyDescriptor: (_, k) => (store.has(k) ? { enumerable: true, configurable: true, value: store.get(k) } : undefined) });
}
const ids = { device: 'owner-web-1', room: '11', database: 'family-mls-synthetic-hande-11' };

test('isLocalOnlyRoom: 릴레이 목록을 알 때만, 거기 없는 방만 true', () => {
  assert.equal(isLocalOnlyRoom('11', new Set(['family', 'gwakga'])), true);
  assert.equal(isLocalOnlyRoom('family', new Set(['family', 'gwakga'])), false);
  assert.equal(isLocalOnlyRoom('11', null), false, '목록을 아직 못 받았으면 모름');
  assert.equal(isLocalOnlyRoom('', new Set()), false);
});

test('isRoomKey: 이 기기·이 방의 7종 키만 — 다른 방·다른 기기·identity·rooms 목록은 아니다', () => {
  for (const k of ['hande:room:11:owner-web-1:family-mls-synthetic-hande-11', 'hande:draft:owner-web-1:11', 'hande:readSeq:owner-web-1:11',
    'hande:agent-consent:owner-web-1:11', 'hande:lastSent:collapsed:11', 'hande:attachment:family-mls-synthetic-hande-11:11:owner-web-1',
    'hande:attachment-v2:family-mls-synthetic-hande-11:11:owner-web-1']) assert.equal(isRoomKey(k, ids), true, k);
  for (const k of ['hande:identity', 'hande:rooms:owner-web-1', 'hande:room-order:owner-web-1', 'hande:draft:owner-web-1:family',
    'hande:draft:owner-web-2:11', 'hande:room:family:owner-web-1:family-mls-synthetic-hande-family', 'hande:lastSent:collapsed:110', 'other:11']) assert.equal(isRoomKey(k, ids), false, k);
});

test('forgetRoomKeys: 이 방의 키만 지우고 알려진 방 목록에서 뺀다 — 다른 방·identity 는 그대로', () => {
  const storage = fakeStorage({
    'hande:identity': '{"actor":"owner","device":"owner-web-1"}',
    'hande:rooms:owner-web-1': '["family","11","gwakga"]',
    'hande:room-order:owner-web-1': '["11","family"]',
    'hande:room:11:owner-web-1:family-mls-synthetic-hande-11': '{"joined":true}',
    'hande:draft:owner-web-1:11': '쓰던 글',
    'hande:readSeq:owner-web-1:11': '3',
    'hande:agent-consent:owner-web-1:11': '1',
    'hande:draft:owner-web-1:family': '가족 초안',
    'hande:room:family:owner-web-1:family-mls-synthetic-hande-family': '{"joined":true}',
  });
  const removed = forgetRoomKeys(storage, ids);
  assert.deepEqual(removed.sort(), ['hande:agent-consent:owner-web-1:11', 'hande:draft:owner-web-1:11', 'hande:readSeq:owner-web-1:11', 'hande:room:11:owner-web-1:family-mls-synthetic-hande-11']);
  assert.equal(storage.getItem('hande:rooms:owner-web-1'), '["family","gwakga"]');
  assert.equal(storage.getItem('hande:draft:owner-web-1:family'), '가족 초안');
  assert.equal(storage.getItem('hande:identity'), '{"actor":"owner","device":"owner-web-1"}');
  assert.equal(storage.getItem('hande:room-order:owner-web-1'), '["11","family"]', '순서 목록은 app.js 가 메모리 값으로 다시 쓴다');
});

test('forgetRoomKeys: 목록이 없거나 깨져 있어도 던지지 않는다', () => {
  assert.deepEqual(forgetRoomKeys(fakeStorage({}), ids), []);
  assert.deepEqual(forgetRoomKeys(fakeStorage({ 'hande:rooms:owner-web-1': '{broken' }), ids), []);
});
