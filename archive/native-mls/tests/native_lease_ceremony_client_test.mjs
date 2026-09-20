#!/usr/bin/env node
// Node-only public client checks. Fake Worker / Playwright protocol is separate.
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname, join} from 'node:path';
import {createHash} from 'node:crypto';
import {result, operation, scope, request, describe, receivedMessages} from '../../experiments/openmls-browser/web/lease-ceremony-client.js';

const web = join(dirname(fileURLToPath(import.meta.url)), '../../experiments/openmls-browser/web');
const pin = (actor, device, key) => ({actor, device_id: device, device_revision: 1, signing_key: key.repeat(64)});
const context = {
  version: 1, intent_id: 'generated-intent', decision_revision: 1, expires_at: 2_000_000_000,
  source_room: 'source', source_group: 'ab'.repeat(16), target_room: 'target',
  predecessor: pin('bob', 'old', '1'), candidate: pin('bob', 'new', '2'), peer: pin('alice', 'peer', '3'),
  candidate_fingerprint: createHash('sha256').update(Buffer.from('2'.repeat(64), 'hex')).digest('hex'),
  package_sha256: '5'.repeat(64), admission: 'preflight-only'
};
const reservation = {version: 1, reservation_id: 'generated-reservation', context, phase: 'reserved-inactive'};
const fail = async (fn) => { try { await fn(); throw new Error('expected throw'); } catch (e) { if (e.message === 'expected throw') throw e; } };
let passed = 0;
const check = (ok, name) => { if (!ok) throw new Error(name); passed++; };

check(scope('alice', 'family-mls-device-vault-synthetic-protocol', 'peer'), 'peer-scope');
check(scope('bob', 'family-mls-candidate-synthetic-protocol', 'candidate'), 'candidate-scope');
check(!scope('alice', 'family-mls-candidate-synthetic-protocol', 'peer'), 'role-db-mismatch');
check(JSON.stringify(operation('activate')) === JSON.stringify({kind: 'activate'}), 'activate-op');
check(JSON.stringify(operation('send', 'message-one', 'generated hello')) === JSON.stringify({kind: 'send', id: 'message-one', text: 'generated hello'}), 'send-op');
await fail(() => operation('send', 'bad id', 'x'));
await fail(() => operation('send', 'ok', 'x'.repeat(300)));

const peerDb = 'family-mls-device-vault-synthetic-protocol';
const doc = {version: 1, scopes: [{identity: 'alice', role: 'peer', database: peerDb, reservation}]};
const loaded = await request(JSON.stringify(doc), 'alice', peerDb, 'peer');
check(loaded.reservation.reservation_id === reservation.reservation_id, 'request-id');
const extra = structuredClone(doc); extra.scopes[0].password = 'must reject';
await fail(() => request(JSON.stringify(extra), 'alice', peerDb, 'peer'));

const activate = {committed: true, role: 'peer', received: [], phase: 'awaiting-pair', channel_full: null, outbox_status: 'empty'};
check((await result(activate, 'alice', peerDb, 'peer', 'activate', reservation)).state === 'awaiting-pair', 'awaiting-pair');
check(describe(await result({...activate, phase: 'leased'}, 'alice', peerDb, 'peer', 'activate', reservation)).includes('양쪽'), 'leased-copy');
await fail(() => result({...activate, phase: 'leased', received: [{seq: 1, text: 'x'}]}, 'alice', peerDb, 'peer', 'activate', reservation));
await fail(() => result({...activate, approval: 'must-reject'}, 'alice', peerDb, 'peer', 'activate', reservation));
await fail(() => result({...activate, pending: {id: 'x'}}, 'alice', peerDb, 'peer', 'activate', reservation));

const synced = {committed: true, role: 'peer', received: [{seq: 1, text: 'generated candidate hello'}], phase: 'leased', channel_full: false, outbox_status: 'empty'};
const shown = await result(synced, 'alice', peerDb, 'peer', 'sync', reservation);
check(shown.state === 'synchronized' && shown.received_count === 1 && shown.last_seq === 1 && !('received' in shown), 'sync-public');
check(receivedMessages(synced.received)[0].text === 'generated candidate hello', 'inbox');
await fail(() => result({...synced, phase: 'awaiting-pair'}, 'alice', peerDb, 'peer', 'sync', reservation));
await fail(() => result({...synced, outbox_status: 'blocked-capacity', channel_full: false}, 'alice', peerDb, 'peer', 'sync', reservation));
const full = {committed: true, role: 'candidate', received: [{seq: 64, text: 'generated final peer message'}], phase: 'leased', channel_full: true, outbox_status: 'blocked-capacity'};
check((await result(full, 'bob', 'family-mls-candidate-synthetic-protocol', 'candidate', 'sync', reservation)).state === 'channel-full', 'full');

const html = readFileSync(join(web, 'lease-ceremony.html'), 'utf8');
for (const id of ['identity', 'role', 'database', 'action', 'message-id', 'message-text', 'request-file', 'confirmation', 'password', 'consent', 'run', 'lock', 'received-list', 'public-result', 'export', 'uncertain', 'status']) {
  check(html.includes(`id="${id}"`), 'html-' + id);
}
check(html.includes('value="activate"') && html.includes('value="sync"') && html.includes('value="send"'), 'actions');
check(!html.includes('web/') && !html.includes('deploy/tuwunel') && !html.includes('fleet_matrix'), 'no-ops-mix');
console.log(JSON.stringify({passed: true, checks: passed, kind: 'node client only, no private custody'}));
