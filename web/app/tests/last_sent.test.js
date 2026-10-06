import test from 'node:test';
import assert from 'node:assert/strict';
import { lastSentEntry, lastSentSummary, collapsedKey } from '../src/last-sent.js';

const labels = { photo: '사진', video: '영상', file: '파일', undecryptable: '열 수 없는 메시지' };
const me = (eventId, body, extra = {}) => ({ eventId, isMe: true, kind: 'text', body, ts: 1000, ...extra });
const other = (eventId, body, extra = {}) => ({ eventId, isMe: false, kind: 'text', body, name: '아빠', ts: 1000, ...extra });

test('내 마지막 말: 뒤에서부터 내 메시지를 고르고, 그 뒤 남의 메시지 수를 답장으로 센다', () => {
  const timeline = [other('$1', '저녁?'), me('$2', '7시에 가요'), other('$3', '좋아'), other('$4', '뭐 먹지')];
  assert.deepEqual(lastSentEntry(timeline), { entry: timeline[1], index: 1 });
  assert.deepEqual(lastSentSummary(timeline, { labels }), { eventId: '$2', text: '7시에 가요', ts: 1000, pending: false, replies: 2 });
});

test('내 메시지가 없거나 timeline이 아니면 null', () => {
  assert.equal(lastSentSummary([other('$1', 'x')], { labels }), null);
  assert.equal(lastSentSummary(null, { labels }), null);
  assert.equal(lastSentSummary([], { labels }), null);
});

test('로컬 에코(~id)는 전송 중, 답장 0', () => {
  const timeline = [other('$1', 'a'), me('~txn1', '방금 보냄')];
  assert.deepEqual(lastSentSummary(timeline, { labels }), { eventId: '~txn1', text: '방금 보냄', ts: 1000, pending: true, replies: 0 });
});

test('삭제된 진행 말풍선(held)·상태 알림(notice)·열 수 없는 메시지는 내 말로 치지 않는다', () => {
  const timeline = [me('$1', '진짜 마지막'), other('$2', '답'), me('$3', '', { held: true }), me('$4', '진행', { isProgress: true }), me('$5', '알림', { kind: 'notice' }), me('$6', '', { kind: 'undecryptable' })];
  const summary = lastSentSummary(timeline, { labels });
  assert.equal(summary.eventId, '$1');
  assert.equal(summary.replies, 1);
});

test('답장 수에도 held·notice·undecryptable·진행은 빠진다', () => {
  const timeline = [me('$1', 'x'), other('$2', '', { held: true }), other('$3', '알림', { kind: 'notice' }), other('$4', '', { kind: 'undecryptable' }), other('$5', '진행', { isProgress: true }), other('$6', '진짜 답')];
  assert.equal(lastSentSummary(timeline, { labels }).replies, 1);
});

test('첨부는 목록 미리보기와 같은 [사진] 파일명 꼴, 공백은 한 칸으로', () => {
  assert.equal(lastSentSummary([me('$1', 'menu.jpg', { kind: 'photo' })], { labels }).text, '[사진] menu.jpg');
  assert.equal(lastSentSummary([me('$1', '  여러\n줄   메시지 ')], { labels }).text, '여러 줄 메시지');
});

test('본문이 비어 미리보기가 없으면 null (빈 알림 등)', () => {
  assert.equal(lastSentSummary([me('$1', '   ')], { labels }), null);
});

test('수정·삭제는 화면 복사본을 그대로 따른다 — 마지막 내 말이 빠지면 그 이전 내 말', () => {
  const before = [me('$1', '첫 말'), other('$2', '답'), me('$3', '둘째 말')];
  assert.equal(lastSentSummary(before, { labels }).eventId, '$3');
  const after = before.filter((e) => e.eventId !== '$3');
  assert.equal(lastSentSummary(after, { labels }).eventId, '$1');
  assert.equal(lastSentSummary(after, { labels }).replies, 1);
});

test('접기 상태 키는 방별', () => {
  assert.equal(collapsedKey('!a:x'), 'familychat:lastSent:collapsed:!a:x');
  assert.equal(collapsedKey(null), 'familychat:lastSent:collapsed:');
});
