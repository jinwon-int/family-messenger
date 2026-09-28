import test from 'node:test';
import assert from 'node:assert/strict';
import { createReadReceiptSender, isRoomUnread, latestDisplayedEntry, readReceiptTarget } from '../src/read-receipts.js';

const other = (eventId, extra = {}) => ({ eventId, isMe: false, kind: 'text', body: '안녕', ...extra });
const mine = (eventId, extra = {}) => ({ eventId, isMe: true, kind: 'text', body: '응', ...extra });
const readSet = (...ids) => (eventId) => ids.includes(eventId);

test('isRoomUnread: 메시지가 없으면 안 읽음이 아니다', () => {
  assert.equal(isRoomUnread([], () => false), false);
  assert.equal(isRoomUnread(null, () => false), false);
  assert.equal(isRoomUnread(undefined, () => false), false);
});

test('isRoomUnread: 남의 마지막 메시지에 내 영수증이 없으면 안 읽음, 있으면 읽음', () => {
  const timeline = [other('$1'), other('$2')];
  assert.equal(isRoomUnread(timeline, readSet()), true);
  assert.equal(isRoomUnread(timeline, readSet('$2')), false);
  assert.equal(isRoomUnread(timeline, readSet('$1')), true, '앞 메시지만 읽었으면 여전히 안 읽음');
});

test('isRoomUnread: 내 메시지가 마지막이면 읽은 것이다(영수증을 묻지도 않는다)', () => {
  let asked = 0;
  assert.equal(isRoomUnread([other('$1'), mine('$2')], () => { asked += 1; return false; }), false);
  assert.equal(isRoomUnread([other('$1'), mine('~local-echo')], () => false), false, '전송 중 로컬 에코도 내 것');
  assert.equal(asked, 0);
});

test('isRoomUnread: SDK가 모른다(null)·예외면 배지를 띄우지 않는다', () => {
  assert.equal(isRoomUnread([other('$1')], () => null), false);
  assert.equal(isRoomUnread([other('$1')], () => { throw new Error('boom'); }), false);
  assert.equal(isRoomUnread([other('~local')], () => false), false, '서버 ID가 없는 항목은 판정하지 않는다');
});

test('latestDisplayedEntry: 삭제되어 자리만 남은 진행 말풍선(held)은 건너뛴다', () => {
  const timeline = [other('$answer'), other('$work', { isProgress: true, held: true })];
  assert.equal(latestDisplayedEntry(timeline).eventId, '$answer');
  assert.equal(isRoomUnread(timeline, readSet('$answer')), false);
  assert.equal(isRoomUnread(timeline, readSet()), true);
});

const visibleInput = (extra = {}) => ({
  roomId: '!a:x', timeline: [other('$1'), other('$2')], visible: true, focused: true, atBottom: true,
  hasRead: readSet(), ...extra,
});

test('readReceiptTarget: 보이고·포커스 있고·맨 아래일 때만 최신 메시지를 고른다', () => {
  assert.equal(readReceiptTarget(visibleInput()), '$2');
  assert.equal(readReceiptTarget(visibleInput({ visible: false })), null, '숨은 탭');
  assert.equal(readReceiptTarget(visibleInput({ focused: false })), null, '다른 창에 포커스');
  assert.equal(readReceiptTarget(visibleInput({ atBottom: false })), null, '위로 스크롤해 최신이 안 보임');
  assert.equal(readReceiptTarget(visibleInput({ roomId: null })), null, '열린 방 없음');
});

test('readReceiptTarget: 이미 읽음·방금 보냄·내 메시지·로컬 에코·빈 방이면 보내지 않는다', () => {
  assert.equal(readReceiptTarget(visibleInput({ hasRead: readSet('$2') })), null);
  assert.equal(readReceiptTarget(visibleInput({ lastSent: '$2' })), null);
  assert.equal(readReceiptTarget(visibleInput({ timeline: [other('$1'), mine('$2')] })), null);
  assert.equal(readReceiptTarget(visibleInput({ timeline: [other('~pending')] })), null);
  assert.equal(readReceiptTarget(visibleInput({ timeline: [] })), null);
  assert.equal(readReceiptTarget(visibleInput({ hasRead: () => null })), '$2', 'SDK가 모르면 보내 본다');
});

test('createReadReceiptSender: 같은 이벤트는 한 번만, 새 메시지가 오면 다시 보낸다', async () => {
  const calls = [];
  const sender = createReadReceiptSender({ send: async (roomId, eventId) => { calls.push([roomId, eventId]); } });
  assert.equal(sender.maybeSend(visibleInput()), '$2');
  assert.equal(sender.maybeSend(visibleInput()), null, '같은 이벤트 재전송 없음');
  assert.equal(sender.maybeSend(visibleInput({ visible: false, timeline: [other('$3')] })), null);
  assert.equal(sender.maybeSend(visibleInput({ timeline: [other('$2'), other('$3')] })), '$3');
  assert.equal(sender.maybeSend(visibleInput({ roomId: '!b:x' })), '$2', '방마다 따로 기억한다');
  await Promise.resolve();
  assert.deepEqual(calls, [['!a:x', '$2'], ['!a:x', '$3'], ['!b:x', '$2']]);
  sender.reset();
  assert.equal(sender.maybeSend(visibleInput()), '$2', 'reset 뒤에는 다시 보낼 수 있다');
});

test('createReadReceiptSender: 전송 실패(거부·동기 throw)는 onError로만 기록하고 재시도하지 않는다', async () => {
  const errors = [];
  let attempts = 0;
  const rejecting = createReadReceiptSender({
    send: async () => { attempts += 1; throw new Error('network'); },
    onError: (error) => errors.push(error.message),
  });
  assert.equal(rejecting.maybeSend(visibleInput()), '$2');
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(rejecting.maybeSend(visibleInput()), null);
  assert.equal(attempts, 1);
  const throwing = createReadReceiptSender({
    send: () => { throw new Error('sync'); },
    onError: (error) => errors.push(error.message),
  });
  assert.doesNotThrow(() => throwing.maybeSend(visibleInput()));
  assert.deepEqual(errors, ['network', 'sync']);
});
