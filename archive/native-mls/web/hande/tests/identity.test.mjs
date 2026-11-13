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

// #766 C1: the page deletes the worker's unlock cache by name, so the two names must agree,
// and every path that drops the identity store must drop the cache with it.
test('unlock cache: the page and the worker agree on the database name, and the wipe list has it', async () => {
  const {IDENTITY_DATABASE, IDENTITY_UNLOCK_DATABASE, PASSPHRASE_IS_GENERATED} = await import('../identity.js');
  const {unlockCacheName} = await import('../session-store.js');
  const {readFileSync} = await import('node:fs');
  assert.equal(IDENTITY_UNLOCK_DATABASE, unlockCacheName(IDENTITY_DATABASE));
  assert.equal(PASSPHRASE_IS_GENERATED, true);
  const app = readFileSync(new URL('../app.js', import.meta.url), 'utf8');
  const wipe = app.slice(app.indexOf('async function wipeIdentityStores()'));
  const list = wipe.slice(0, wipe.indexOf('await deleteDb(name)'));
  assert.match(list, /IDENTITY_DATABASE, `\$\{IDENTITY_DATABASE\}-history`, IDENTITY_UNLOCK_DATABASE, LOBBY_DATABASE/);
  // Every start asks for the cache through the one permission constant — no literal `true`.
  const starts = app.match(/dev\.start\(\{[^}]*\}\)/g) ?? [];
  assert.equal(starts.length, 3);
  for (const call of starts) assert.match(call, /unlockCache: PASSPHRASE_IS_GENERATED\}\)$/, call);
});
