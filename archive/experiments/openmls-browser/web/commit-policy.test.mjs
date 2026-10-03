// Pure-function tests for the client-side commit policy check (#261):
// stage-report parsing and the merge/refuse decision. No wasm, no IndexedDB.
// Run: node --test web/commit-policy.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import {parseStageReport, checkCommit, rosterAfter, hex} from './commit-policy.js';

const utf8 = new TextEncoder();
const key = n => new Uint8Array(32).fill(n);
function frameMembers(members) {
  const parts = [];
  const count = new Uint8Array(4); new DataView(count.buffer).setUint32(0, members.length, true); parts.push(count);
  for (const [id, k] of members) {
    const bytes = utf8.encode(id), len = new Uint8Array(4); new DataView(len.buffer).setUint32(0, bytes.length, true);
    parts.push(len, bytes, k);
  }
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0; for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}
function report({adds = [], removes = [], updates = [], path = []}) {
  const sections = [adds, removes, updates, path].map(frameMembers);
  const out = new Uint8Array(sections.reduce((n, s) => n + s.length, 0));
  let at = 0; for (const s of sections) { out.set(s, at); at += s.length; }
  return out;
}
const ROSTER = ['owner-iphone', 'bot-gongmyoung', 'owner-pc'];

test('a format-2 report parses into four sections with hex keys', () => {
  const r = parseStageReport(report({adds: [['probe-1', key(1)]], path: [['owner-pc', key(7)]]}));
  assert.deepEqual(r.adds, [{id: 'probe-1', key: hex(key(1))}]);
  assert.deepEqual(r.removes, []);
  assert.deepEqual(r.updates, []);
  assert.deepEqual(r.path, [{id: 'owner-pc', key: hex(key(7))}]);
});

test('truncated or padded reports are format errors, never silent', () => {
  const good = report({path: [['owner-pc', key(7)]]});
  assert.throws(() => parseStageReport(good.subarray(0, good.length - 5)), /truncated/);
  const padded = new Uint8Array(good.length + 1); padded.set(good);
  assert.throws(() => parseStageReport(padded), /trailing/);
  assert.throws(() => parseStageReport(new Uint8Array(3)), /truncated/);
});

test('an add by a current member with a matching relay roster merges', () => {
  const r = parseStageReport(report({adds: [['owner-pc2', key(2)]], path: [['owner-pc', key(7)]]}));
  const v = checkCommit({report: r, roster: ROSTER, committer: 'owner-pc', outer: ['owner-pc2', 'bot-gongmyoung', 'owner-pc', 'owner-iphone']});
  assert.equal(v.ok, true);
  assert.deepEqual(v.expected, ['bot-gongmyoung', 'owner-iphone', 'owner-pc', 'owner-pc2']);
  assert.deepEqual(rosterAfter(ROSTER, r), v.expected);
});

test('a remove by a current member merges; inner-only check when the commit is not the latest', () => {
  const r = parseStageReport(report({removes: [['owner-pc', key(3)]], path: [['owner-iphone', key(7)]]}));
  assert.equal(checkCommit({report: r, roster: ROSTER, committer: 'owner-iphone'}).ok, true);
  assert.deepEqual(rosterAfter(ROSTER, r), ['bot-gongmyoung', 'owner-iphone']);
});

test('the relay row device must be the MLS committer', () => {
  const r = parseStageReport(report({adds: [['x', key(1)]], path: [['owner-pc', key(7)]]}));
  const v = checkCommit({report: r, roster: ROSTER, committer: 'owner-iphone'});
  assert.equal(v.ok, false); assert.equal(v.reason, 'committer_mismatch');
  const two = parseStageReport(report({path: [['owner-pc', key(7)], ['owner-pc', key(8)]]}));
  assert.equal(checkCommit({report: two, roster: ROSTER, committer: 'owner-pc'}).reason, 'committer_path');
  const none = parseStageReport(report({adds: [['x', key(1)]]}));
  assert.equal(checkCommit({report: none, roster: ROSTER, committer: 'owner-pc'}).reason, 'committer_path');
});

test('a committer this device does not know is refused', () => {
  const r = parseStageReport(report({adds: [['x', key(1)]], path: [['stranger', key(7)]]}));
  assert.equal(checkCommit({report: r, roster: ROSTER, committer: 'stranger'}).reason, 'committer_not_member');
});

test('roster deltas must be consistent with what this device knows', () => {
  const path = [['owner-pc', key(7)]];
  const cases = [
    [{adds: [['owner-iphone', key(1)]], path}, 'add_already_member'],
    [{adds: [['n', key(1)], ['n', key(2)]], path}, 'add_duplicate'],
    [{removes: [['ghost', key(1)]], path}, 'remove_not_member'],
    [{removes: [['owner-iphone', key(1)], ['owner-iphone', key(1)]], path}, 'remove_duplicate'],
    [{updates: [['owner-pc', key(9)]], path}, 'unexpected_update_proposal'],
  ];
  for (const [spec, reason] of cases) {
    const v = checkCommit({report: parseStageReport(report(spec)), roster: ROSTER, committer: 'owner-pc'});
    assert.equal(v.ok, false, reason);
    assert.equal(v.reason, reason);
  }
});

test('the relay roster must equal the MLS roster after the commit (outer == inner)', () => {
  const r = parseStageReport(report({adds: [['owner-pc2', key(2)]], path: [['owner-pc', key(7)]]}));
  // The relay says a different device joined: refuse.
  let v = checkCommit({report: r, roster: ROSTER, committer: 'owner-pc', outer: ['owner-iphone', 'bot-gongmyoung', 'owner-pc', 'intruder']});
  assert.equal(v.reason, 'outer_inner_mismatch');
  assert.match(v.detail, /intruder/);
  // The relay still shows the old roster (add not reflected): refuse.
  v = checkCommit({report: r, roster: ROSTER, committer: 'owner-pc', outer: ROSTER});
  assert.equal(v.reason, 'outer_inner_mismatch');
  // Order and duplicates in the relay list do not matter.
  v = checkCommit({report: r, roster: ROSTER, committer: 'owner-pc', outer: ['owner-pc2', 'owner-pc2', 'owner-pc', 'owner-iphone', 'bot-gongmyoung']});
  assert.equal(v.ok, true);
});
