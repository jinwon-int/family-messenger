// status-v1 (#560, STATUS-V1.md §3): the web 한데 transient agent-status bubble — pure board logic.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {isStatusClient, createStatusBoard, applyStatus, clearStatusOnMessage, visibleStatuses, STATUS_TTL_MS} from '../status-v1.js';

const U = '0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2';

test('isStatusClient: status-<uuid> only (the bot/relay/iOS shape)', () => {
  assert.equal(isStatusClient(`status-${U}`), true);
  assert.equal(isStatusClient(`status-${U.toUpperCase()}`), false, 'lowercase only');
  assert.equal(isStatusClient('status-'), false, 'prefix alone is a normal message');
  assert.equal(isStatusClient(`status-${U}x`), false);
  assert.equal(isStatusClient(`file-v2-${U}`), false);
  assert.equal(isStatusClient('dungae-bot-echo-3'), false);
  assert.equal(isStatusClient(undefined), false);
});

test('one bubble per sender, updated in place; newest status wins, older seq ignored', () => {
  const b = createStatusBoard();
  const now = 1_700_000_000_000;
  assert.equal(applyStatus(b, {sender: 'dungae-bot', text: '⏳ Working — 5s', seq: 10, ts: now}, now), true);
  assert.equal(applyStatus(b, {sender: 'dungae-bot', text: '⏳ Working — 10s | Bash: ls', seq: 11, ts: now}, now), true);
  assert.equal(applyStatus(b, {sender: 'dungae-bot', text: '⏳ Working — 10s | Bash: ls', seq: 12, ts: now}, now), false, 'same text → no repaint');
  assert.equal(applyStatus(b, {sender: 'dungae-bot', text: '⏳ old', seq: 9, ts: now}, now), false, 'an older status never replaces a newer one');
  applyStatus(b, {sender: 'seoseo-bot', text: '⏳ Working — 5s', seq: 13, ts: now}, now);
  assert.deepEqual(visibleStatuses(b, now).map(s => [s.sender, s.text]), [['dungae-bot', '⏳ Working — 10s | Bash: ls'], ['seoseo-bot', '⏳ Working — 5s']]);
});

test('the sender\'s next normal message clears its bubble; other senders keep theirs', () => {
  const b = createStatusBoard();
  const now = 1_700_000_000_000;
  applyStatus(b, {sender: 'dungae-bot', text: '⏳ a', seq: 10, ts: now}, now);
  applyStatus(b, {sender: 'seoseo-bot', text: '⏳ b', seq: 11, ts: now}, now);
  assert.equal(clearStatusOnMessage(b, 'dungae-bot', 12), true);
  assert.deepEqual(visibleStatuses(b, now).map(s => s.sender), ['seoseo-bot']);
  assert.equal(clearStatusOnMessage(b, 'owner-pc', 13), false, 'a human message touches nobody else');
});

test('a status older than the sender\'s reply (same sync batch, any order) never reappears', () => {
  const b = createStatusBoard();
  const now = 1_700_000_000_000;
  clearStatusOnMessage(b, 'dungae-bot', 20);           // the reply (seq 20) is processed first
  assert.equal(applyStatus(b, {sender: 'dungae-bot', text: '⏳ late', seq: 19, ts: now}, now), false);
  assert.deepEqual(visibleStatuses(b, now), []);
  assert.equal(applyStatus(b, {sender: 'dungae-bot', text: '⏳ next turn', seq: 21, ts: now}, now), true, 'the next turn shows again');
  // A history replay of an older message must not clear a newer status.
  assert.equal(clearStatusOnMessage(b, 'dungae-bot', 5), false);
  assert.equal(visibleStatuses(b, now).length, 1);
});

test('5 min without an update → gone (turn ended without a reply); relay time, capped at this clock', () => {
  const b = createStatusBoard();
  const now = 1_700_000_000_000;
  applyStatus(b, {sender: 'dungae-bot', text: '⏳ a', seq: 1, ts: now}, now);
  assert.equal(visibleStatuses(b, now + STATUS_TTL_MS).length, 1);
  assert.equal(visibleStatuses(b, now + STATUS_TTL_MS + 1).length, 0);
  assert.equal(b.bySender.size, 0, 'expired entries leave the board');
  // A backlog status from an hour ago is already expired on arrival.
  applyStatus(b, {sender: 'dungae-bot', text: '⏳ old', seq: 2, ts: now - 3_600_000}, now);
  assert.equal(visibleStatuses(b, now).length, 0);
  // A relay clock ahead of this device does not keep the bubble alive longer.
  applyStatus(b, {sender: 'dungae-bot', text: '⏳ future', seq: 3, ts: now + 3_600_000}, now);
  assert.equal(visibleStatuses(b, now + STATUS_TTL_MS + 1).length, 0);
});

test('blank / non-string text is ignored; long lines are bounded', () => {
  const b = createStatusBoard();
  assert.equal(applyStatus(b, {sender: 'dungae-bot', text: '   ', seq: 1}), false);
  assert.equal(applyStatus(b, {sender: 'dungae-bot', text: null, seq: 1}), false);
  assert.equal(applyStatus(b, {sender: '', text: '⏳', seq: 1}), false);
  applyStatus(b, {sender: 'dungae-bot', text: '⏳ ' + 'x'.repeat(5000), seq: 2});
  assert.equal(visibleStatuses(b)[0].text.length, 500);
});
