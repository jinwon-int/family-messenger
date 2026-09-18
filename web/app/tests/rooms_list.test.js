import test from 'node:test';
import assert from 'node:assert/strict';
import { lastMessagePreview, listSignature, relativeTime, sortByActivity } from '../src/rooms.js';

const LABELS = { photo: '사진', video: '영상', file: '파일', undecryptable: '열 수 없는 메시지' };
const TIME = { justNow: '방금', minutesAgo: (n) => `${n}분 전`, hoursAgo: (n) => `${n}시간 전`, yesterday: '어제' };

test('lastMessagePreview: 텍스트는 한 줄로, 첨부는 종류 라벨, 복호화 실패는 안내, 빈 항목은 null', () => {
  assert.deepEqual(lastMessagePreview({ kind: 'text', name: '엄마', body: '저녁\n먹자  ' }, LABELS), { text: '저녁 먹자', sender: '엄마' });
  assert.deepEqual(lastMessagePreview({ kind: 'photo', name: '아빠', body: 'menu.jpg' }, LABELS), { text: '[사진] menu.jpg', sender: '아빠' });
  assert.equal(lastMessagePreview({ kind: 'file', name: '나', body: 'a.pdf' }, LABELS).text, '[파일] a.pdf');
  assert.deepEqual(lastMessagePreview({ kind: 'undecryptable', name: '홍길동', body: '...' }, LABELS), { text: '열 수 없는 메시지', sender: '홍길동' });
  assert.equal(lastMessagePreview({ kind: 'text', name: '나', body: '   ' }, LABELS), null);
  assert.equal(lastMessagePreview(null, LABELS), null);
});

test('relativeTime: 방금/분/시간/어제/월.일. — 분 단위라 2초 갱신에도 라벨은 분 경계에서만 바뀐다', () => {
  const now = new Date(2026, 8, 17, 16, 30).getTime();
  assert.equal(relativeTime(now - 5_000, now, TIME), '방금');
  assert.equal(relativeTime(now - 59_000, now, TIME), '방금');
  assert.equal(relativeTime(now - 60_000, now, TIME), '1분 전');
  assert.equal(relativeTime(now - 59 * 60_000 - 59_000, now, TIME), '59분 전');
  assert.equal(relativeTime(now - 3 * 3_600_000, now, TIME), '3시간 전');
  assert.equal(relativeTime(new Date(2026, 8, 16, 9, 0).getTime(), now, TIME), '어제');
  assert.equal(relativeTime(new Date(2026, 8, 10, 9, 0).getTime(), now, TIME), '9.10.');
  assert.equal(relativeTime(null, now, TIME), '');
  assert.equal(relativeTime(now + 10_000, now, TIME), '방금');
});

test('sortByActivity: 최근 메시지 순, 메시지 없는 방은 원래 순서로 뒤에', () => {
  const rooms = [
    { roomId: 'a', lastMessage: { ts: 100 } },
    { roomId: 'b', lastMessage: null },
    { roomId: 'c', lastMessage: { ts: 300 } },
    { roomId: 'd' },
    { roomId: 'e', lastMessage: { ts: 200 } },
  ];
  assert.deepEqual(sortByActivity(rooms).map((r) => r.roomId), ['c', 'e', 'a', 'b', 'd']);
  assert.deepEqual(rooms.map((r) => r.roomId), ['a', 'b', 'c', 'd', 'e'], '입력은 바꾸지 않는다');
});

test('listSignature: 보이는 값이 같으면 같고, 마지막 메시지·라벨·이름·인원이 바뀌면 달라진다', () => {
  const now = Date.now();
  const base = [{ roomId: 'a', displayName: '가족', memberCount: 3, lastMessage: { eventId: '$1', text: '안녕', ts: now - 10_000 } }];
  const same = [{ ...base[0], lastMessage: { ...base[0].lastMessage } }];
  assert.equal(listSignature(base, now, TIME), listSignature(same, now, TIME));
  assert.notEqual(listSignature(base, now, TIME), listSignature([{ ...base[0], lastMessage: { eventId: '$2', text: '새 글', ts: now } }], now, TIME));
  assert.notEqual(listSignature(base, now, TIME), listSignature(base, now + 5 * 60_000, TIME), '5분 뒤엔 라벨이 바뀐다');
  assert.equal(listSignature(base, now, TIME), listSignature(base, now + 2_000, TIME), '2초 뒤엔 라벨이 같다');
  assert.notEqual(listSignature(base, now, TIME), listSignature([{ ...base[0], memberCount: 4 }], now, TIME));
});
