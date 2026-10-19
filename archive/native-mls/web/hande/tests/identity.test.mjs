import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createIdentityStore, databaseFor, ACTOR} from '../identity.js';

const mem = () => { const m = new Map(); return {getItem: k => m.has(k) ? m.get(k) : null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k)}; };
const fixed = n => new Uint8Array(n).fill(0xab);

test('choose/rotate/restorePrevious keep the actor and remember the previous id', () => {
  const store = createIdentityStore({storage: mem(), random: fixed});
  assert.ok(ACTOR.test('owner'));
  const first = store.choose('owner');
  assert.equal(first.device, 'owner-web-ababab');
  assert.deepEqual(store.choose('mom'), first, 'choose is idempotent once set');
  const rotated = store.rotate();
  assert.equal(rotated.previous, first.device);
  const restored = store.restorePrevious();
  assert.equal(restored.device, first.device);
  assert.equal(restored.restoredFrom, rotated.device);
  assert.equal(store.restorePrevious(), null, 'nothing left to restore');
  assert.equal(databaseFor('family-acc'), 'family-mls-synthetic-hande-family-acc');
});
