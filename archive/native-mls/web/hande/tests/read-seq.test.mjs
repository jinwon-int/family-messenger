// read-seq.js (#541) — iOS Unread.isUnread 표(AgentConversationTests)와 같은 판정 + localStorage 영속.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSeqKeyFor, readReadSeq, writeReadSeq, latestSeq, isUnread } from '../read-seq.js';

function memoryStorage() {
  const m = new Map();
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k), _m: m };
}
const e = (seq, isMe = false, kind = 'text') => ({ seq, isMe, kind });

test('isUnread: iOS Unread.isUnread 표', () => {
  assert.equal(isUnread([e(5)], 4), true);
  assert.equal(isUnread([e(5)], 0), true);
  assert.equal(isUnread([e(5)], undefined), true);
  assert.equal(isUnread([e(5)], 5), false);
  assert.equal(isUnread([e(6, true)], 1), false, '마지막이 내 글이면 안 읽음 아님');
  assert.equal(isUnread([e(3), e(7, true)], 1), false, '같은 사람 다른 기기 글(isMe)도 내 글');
  assert.equal(isUnread([e(3, true), e(7)], 1), true);
  assert.equal(isUnread([], 0), false);
});

test('isUnread: seq 없는 행·시스템 행은 세지 않는다', () => {
  assert.equal(isUnread([e(4), { kind: 'system', seq: null }], 4), false);
  assert.equal(isUnread([e(4), { kind: 'text', seq: null, isMe: false }], 4), false);
  assert.equal(isUnread([e(4), e(9, false, 'attachment')], 4), true, '첨부도 센다');
  assert.equal(isUnread([e(9), e(2, true)], 3), true, '배열 순서가 아니라 seq 로 마지막을 고른다');
});

test('새로고침 시나리오: 보관 이력이 다시 들어와도 이미 본 방은 안 읽음 아님 (#541)', () => {
  const s = memoryStorage();
  const restored = [e(10), e(11, true), e(12)];
  const seen = writeReadSeq(s, 'owner-web-abc123', 'family', latestSeq(restored));
  assert.equal(seen, 12);
  // 다음 페이지 세션: 저장된 값으로 같은 이력을 판정
  const again = readReadSeq(s, 'owner-web-abc123', 'family');
  assert.equal(isUnread(restored, again), false);
  assert.equal(isUnread([...restored, e(13)], again), true, '그 뒤 새 글은 안 읽음');
});

test('writeReadSeq: 줄어들지 않고, 잘못된 값은 무시', () => {
  const s = memoryStorage();
  assert.equal(writeReadSeq(s, 'd', 'r', 5), 5);
  assert.equal(writeReadSeq(s, 'd', 'r', 3), 5);
  assert.equal(writeReadSeq(s, 'd', 'r', null), 5);
  assert.equal(writeReadSeq(s, 'd', 'r', 1.5), 5);
  assert.equal(readReadSeq(s, 'd', 'r'), 5);
  assert.equal(s.getItem(readSeqKeyFor('d', 'r')), '5');
  assert.equal(readReadSeq(s, 'd', 'other'), 0);
});

test('readReadSeq: 깨진 값·저장소 예외는 0', () => {
  const s = memoryStorage();
  s.setItem(readSeqKeyFor('d', 'r'), 'garbage');
  assert.equal(readReadSeq(s, 'd', 'r'), 0);
  s.setItem(readSeqKeyFor('d', 'r'), '-4');
  assert.equal(readReadSeq(s, 'd', 'r'), 0);
  const broken = { getItem() { throw new Error('denied'); }, setItem() { throw new Error('quota'); } };
  assert.equal(readReadSeq(broken, 'd', 'r'), 0);
  assert.equal(writeReadSeq(broken, 'd', 'r', 7, 0), 7, '저장 실패여도 메모리 값은 올라간다');
});

test('latestSeq: text·attachment 의 최대 seq', () => {
  assert.equal(latestSeq([e(3), e(8, true), { kind: 'system', seq: 99 }, e(5, false, 'attachment')]), 8);
  assert.equal(latestSeq([]), 0);
  assert.equal(latestSeq(undefined), 0);
});

test('키는 hande: 접두(이 기기 지우기 대상)', () => {
  assert.ok(readSeqKeyFor('d', 'r').startsWith('hande:'));
});
