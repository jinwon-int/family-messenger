import test from 'node:test';
import assert from 'node:assert/strict';
import { lastSentEntry, lastSentSummary, recentSentSummaries, collapsedKey, dayStart, indexSummaries, mergeSentSummaries } from '../src/last-sent.js';

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

test('최근 내 말 목록: 최신순 최대 limit개, 답장 수는 다음 내 말 전까지, [0]은 lastSentSummary와 같다', () => {
  const timeline = [
    me('$1', '첫 말'), other('$2', '답1'), other('$3', '답2'),
    me('$4', '둘째 말'),
    me('$5', '셋째 말'), other('$6', '답3'),
    me('$7', '넷째 말', { ts: 2000 }), other('$8', '답4'), other('$9', '답5'), other('$10', '답6'),
  ];
  const recent = recentSentSummaries(timeline, { labels });
  assert.deepEqual(recent.map((r) => [r.eventId, r.text, r.replies, r.ts]), [
    ['$7', '넷째 말', 3, 2000],
    ['$5', '셋째 말', 1, 1000],
    ['$4', '둘째 말', 0, 1000],
  ], '최신순 3개, 첫 말은 한도 밖');
  assert.deepEqual(recent[0], lastSentSummary(timeline, { labels }));
  assert.deepEqual(recentSentSummaries(timeline, { labels, limit: 1 }).map((r) => r.eventId), ['$7']);
  assert.deepEqual(recentSentSummaries(timeline, { labels, limit: 10 }).map((r) => r.eventId), ['$7', '$5', '$4', '$1']);
  assert.equal(recentSentSummaries(timeline, { labels, limit: 10 })[3].replies, 2, '첫 말의 답장은 둘째 말 전까지 2개');
});

test('최근 내 말 목록: 전송 중 에코·held·notice·빈 미리보기 처리, 내 말이 없거나 limit이 이상하면 []', () => {
  const timeline = [
    other('$1', '시작'),
    me('$2', '지운 말', { held: true }), // 내 말로 안 친다 — 경계도 아니다
    me('$3', '보이는 말'), other('$4', '답'),
    me('$5', '', { kind: 'notice' }), // 조용한 종류 — 무시
    me('~local', '보내는 중'),
  ];
  const recent = recentSentSummaries(timeline, { labels });
  assert.deepEqual(recent.map((r) => [r.eventId, r.pending, r.replies]), [['~local', true, 0], ['$3', false, 1]]);
  assert.deepEqual(recentSentSummaries([other('$1', '남의 말')], { labels }), []);
  assert.deepEqual(recentSentSummaries(null, { labels }), []);
  assert.deepEqual(recentSentSummaries(timeline, { labels, limit: 0 }), []);
});

// 오늘 내 말 인덱스(오너 2026-10-07): 서버 sender 필터로 받은 내 말과 타임라인의 내 말을 합친다.
test('dayStart: 기기 시간 기준 오늘 0시', () => {
  const noon = new Date(2026, 9, 7, 12, 34, 56).getTime();
  assert.equal(dayStart(noon), new Date(2026, 9, 7, 0, 0, 0).getTime());
  assert.equal(dayStart(new Date(2026, 9, 7, 0, 0, 0).getTime()), new Date(2026, 9, 7, 0, 0, 0).getTime());
  assert.ok(Number.isFinite(dayStart()));
});

test('indexSummaries: 내 말만 최신순, 답장 수는 null, 삭제·진행·알림·열 수 없는 메시지는 제외, limit', () => {
  const entries = [
    me('$a', '아침', { ts: 100 }), other('$x', '남', { ts: 150 }), me('$b', '점심', { ts: 200 }),
    me('$h', '', { ts: 300, held: true }), me('$p', '진행', { ts: 310, isProgress: true }), me('$n', '알림', { ts: 320, kind: 'notice' }),
    me('$u', '', { ts: 330, kind: 'undecryptable' }), me('$c', '저녁', { ts: 400 }),
  ];
  assert.deepEqual(indexSummaries(entries, { labels }).map((s) => [s.eventId, s.text, s.ts, s.pending, s.replies]), [
    ['$c', '저녁', 400, false, null], ['$b', '점심', 200, false, null], ['$a', '아침', 100, false, null],
  ]);
  assert.deepEqual(indexSummaries(entries, { labels, limit: 1 }).map((s) => s.eventId), ['$c']);
  assert.deepEqual(indexSummaries(null, { labels }), []);
});

test('mergeSentSummaries: 같은 id는 타임라인이 이기고(답장 수 유지), 최신순, 목록은 sinceTs 이후만, 로컬 에코는 그대로', () => {
  const fromTimeline = [
    { eventId: '~echo', text: '방금', ts: 1000, pending: true, replies: 0 },
    { eventId: '$c', text: '저녁', ts: 900, pending: false, replies: 3 },
    { eventId: '$y', text: '어제', ts: 50, pending: false, replies: 1 },
  ];
  const fromIndex = [
    { eventId: '$c', text: '저녁', ts: 900, pending: false, replies: null },
    { eventId: '$b', text: '점심', ts: 500, pending: false, replies: null },
    { eventId: '$a', text: '아침', ts: 200, pending: false, replies: null },
    { eventId: '$z', text: '그제', ts: 10, pending: false, replies: null },
  ];
  const { lastSent, earlierSent } = mergeSentSummaries(fromTimeline, fromIndex, { sinceTs: 100 });
  assert.equal(lastSent.eventId, '~echo', '바 본문은 가장 최근(전송 중 포함)');
  assert.deepEqual(earlierSent.map((s) => [s.eventId, s.replies]), [['$c', 3], ['$b', null], ['$a', null]], '어제 것은 목록에서 뺀다');
  assert.deepEqual(mergeSentSummaries(fromTimeline, fromIndex, { sinceTs: 100, limit: 1 }).earlierSent.map((s) => s.eventId), ['$c']);
  // 타임라인에 내 말이 없어도(아침에만 말했고 범위 밖) 인덱스만으로 바를 그린다.
  const onlyIndex = mergeSentSummaries([], fromIndex, { sinceTs: 100 });
  assert.equal(onlyIndex.lastSent.eventId, '$c');
  assert.deepEqual(onlyIndex.earlierSent.map((s) => s.eventId), ['$b', '$a']);
  assert.deepEqual(mergeSentSummaries([], [], {}), { lastSent: null, earlierSent: [] });
});

test('접기 상태 키는 방별', () => {
  assert.equal(collapsedKey('!a:x'), 'familychat:lastSent:collapsed:!a:x');
  assert.equal(collapsedKey(null), 'familychat:lastSent:collapsed:');
});
