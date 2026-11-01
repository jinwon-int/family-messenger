// 「내 마지막 말」 바 순수 로직 테스트(#480 C). node --test archive/native-mls/web/hande/tests/last-sent.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { lastSentEntry, recentSentSummaries, lastSentView, dayStart, collapsedKey, sentDayPrefix, EARLIER_MINIMUM } from '../last-sent.js';

const labels = { photo: '[사진]', file: '[파일]' };
const me = (key, body, ts, extra = {}) => ({ key, kind: 'text', isMe: true, body, ts, ...extra });
const other = (key, body, ts) => ({ key, kind: 'text', isMe: false, body, ts });
const sys = (key) => ({ key, kind: 'system', isMe: false, body: '초대', ts: 1 });

test('lastSentEntry: 내 말 중 마지막, 시스템 행·복호화 실패는 제외', () => {
  const tl = [me('a', '1', 1), other('b', '2', 2), me('c', '3', 3), { key: 'd', kind: 'undecryptable', isMe: true, ts: 4 }, sys('e')];
  assert.deepEqual(lastSentEntry(tl), { entry: tl[2], index: 2 });
  assert.equal(lastSentEntry([other('b', '2', 2)]), null);
  assert.equal(lastSentEntry(null), null);
});

test('recentSentSummaries: 최신순, 답장 수는 다음 내 말 전까지의 남의 말 수, 첨부는 [사진]/[파일]', () => {
  const tl = [me('a', '첫 말', 1), other('b', '답1', 2), other('c', '답2', 3), me('d', '둘째', 4), sys('s'), other('e', '답3', 5),
    { key: 'f', kind: 'attachment', isMe: true, ts: 6, image: { url: 'blob:x' } }, { key: 'g', kind: 'attachment', isMe: true, ts: 7 }];
  const out = recentSentSummaries(tl, { labels });
  assert.deepEqual(out.map((i) => [i.key, i.text, i.replies]), [['g', '[파일]', 0], ['f', '[사진]', 0], ['d', '둘째', 1], ['a', '첫 말', 2]]);
  assert.deepEqual(recentSentSummaries(tl, { labels, limit: 2 }).map((i) => i.key), ['g', 'f']);
  assert.deepEqual(recentSentSummaries(tl, { labels, limit: 0 }), []);
});

test('recentSentSummaries: 빈 미리보기(공백만)는 건너뛰고 경계도 되지 않는다', () => {
  const tl = [me('a', '진짜', 1), other('b', 'x', 2), me('c', '   ', 3), other('d', 'y', 4)];
  const out = recentSentSummaries(tl, { labels });
  assert.deepEqual(out.map((i) => [i.key, i.replies]), [['a', 2]]);
});

test('lastSentView minimum 0(예전 규칙): 첫 항목은 날짜와 무관, 나머지는 오늘 것만', () => {
  const now = new Date(2026, 9, 21, 15, 0).getTime();
  const yesterday = new Date(2026, 9, 20, 15, 0).getTime();
  const today = new Date(2026, 9, 21, 9, 0).getTime();
  const tl = [me('old', '어제 말', yesterday), me('t1', '오늘 1', today), me('t2', '오늘 2', today + 1000)];
  const view = lastSentView(tl, { labels, now, minimum: 0 });
  assert.equal(view.lastSent.key, 't2');
  assert.deepEqual(view.earlierSent.map((i) => i.key), ['t1']);
  const onlyOld = lastSentView([me('old', '어제 말', yesterday)], { labels, now, minimum: 0 });
  assert.equal(onlyOld.lastSent.key, 'old', '가장 최근 내 말은 어제 것이어도 바 본문이 된다');
  assert.deepEqual(onlyOld.earlierSent, []);
  assert.equal(lastSentView([], { labels, now }).lastSent, null);
});

// 오너 2026-11-01 「과거에 쓴 말 10개 이상」(iOS LastSent.earlier 와 같은 규칙): 오늘 말은 전부, 적으면 지난 날 말로 10개까지.
test('lastSentView 기본: 오늘 말이 적으면 지난 날 말로 10개까지 채운다', () => {
  assert.equal(EARLIER_MINIMUM, 10);
  const now = new Date(2026, 9, 21, 15, 0).getTime();
  const old = Array.from({ length: 15 }, (_, i) => me(`o${i + 1}`, `옛말 ${i + 1}`, new Date(2026, 9, 10, 9, i).getTime()));
  const latest = me('latest', '방금 말', new Date(2026, 9, 21, 14, 0).getTime());
  const onlyOld = lastSentView([...old, latest], { labels, now });
  assert.equal(onlyOld.lastSent.key, 'latest');
  assert.deepEqual(onlyOld.earlierSent.map((i) => i.key), ['o15', 'o14', 'o13', 'o12', 'o11', 'o10', 'o9', 'o8', 'o7', 'o6'],
    '오늘 말이 없어도 빈 목록이 아니라 최근 10개');
  const today = Array.from({ length: 3 }, (_, i) => me(`t${i + 1}`, `오늘 ${i + 1}`, new Date(2026, 9, 21, 9, i).getTime()));
  const quiet = lastSentView([...old, ...today, latest], { labels, now });
  assert.deepEqual(quiet.earlierSent.map((i) => i.key), ['t3', 't2', 't1', 'o15', 'o14', 'o13', 'o12', 'o11', 'o10', 'o9'], '오늘 3 + 옛말 7');
});

test('lastSentView 기본: 오늘 말이 10개보다 많으면 오늘 것 전부(옛말 없음), limit 은 그대로 상한', () => {
  const now = new Date(2026, 9, 21, 23, 0).getTime();
  const old = Array.from({ length: 5 }, (_, i) => me(`o${i}`, `옛말 ${i}`, new Date(2026, 9, 10, 9, i).getTime()));
  const today = Array.from({ length: 12 }, (_, i) => me(`t${i + 1}`, `오늘 ${i + 1}`, new Date(2026, 9, 21, 9, i).getTime()));
  const latest = me('latest', '방금 말', new Date(2026, 9, 21, 22, 0).getTime());
  const busy = lastSentView([...old, ...today, latest], { labels, now });
  assert.equal(busy.earlierSent.length, 12);
  assert.ok(busy.earlierSent.every((i) => i.key.startsWith('t')), '오늘 말이 충분하면 지난 날 말은 넣지 않는다');
  assert.equal(lastSentView([...old, ...today, latest], { labels, now, limit: 5 }).earlierSent.length, 5);
  assert.equal(lastSentView([...old, latest], { labels, now, minimum: 99, limit: 3 }).earlierSent.length, 3, 'minimum 은 limit 을 넘지 않는다');
});

test('sentDayPrefix: 오늘 빈칸 · 어제 · 그 전 M.D.', () => {
  const now = new Date(2026, 9, 21, 15, 0).getTime();
  assert.equal(sentDayPrefix(new Date(2026, 9, 21, 0, 0).getTime(), { now }), '');
  assert.equal(sentDayPrefix(new Date(2026, 9, 20, 23, 59).getTime(), { now }), '어제');
  assert.equal(sentDayPrefix(new Date(2026, 9, 20, 0, 0).getTime(), { now, yesterday: 'Y' }), 'Y');
  assert.equal(sentDayPrefix(new Date(2026, 9, 19, 23, 59).getTime(), { now }), '10.19.');
  assert.equal(sentDayPrefix(new Date(2025, 0, 2, 9, 0).getTime(), { now }), '1.2.');
  assert.equal(sentDayPrefix(null, { now }), '');
});

test('dayStart / collapsedKey', () => {
  const now = new Date(2026, 9, 21, 15, 30).getTime();
  assert.equal(dayStart(now), new Date(2026, 9, 21, 0, 0, 0, 0).getTime());
  assert.equal(collapsedKey('family'), 'hande:lastSent:collapsed:family');
  assert.equal(collapsedKey(null), 'hande:lastSent:collapsed:');
});
