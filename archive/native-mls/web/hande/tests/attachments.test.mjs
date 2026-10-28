// 보관함 「첨부」 탭 순수 로직(#544 D). node --test archive/native-mls/web/hande/tests/attachments.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { collectAttachments, attachmentTitle } from '../attachments.js';

const att = (seq, ts, extra = {}) => ({ key: `seq-${seq}`, kind: 'attachment', seq, ts, sender: 'jungin-iphone-1', senderName: '쩡이🍎 · 아이폰', isMe: false, size: 1234, fileName: null, image: null, load: async () => new Uint8Array(0), ...extra });
const txt = (seq, ts) => ({ key: `seq-${seq}`, kind: 'text', seq, ts, body: 'hi' });

test('collectAttachments: 모든 방의 attachment 만, 최신순(ts 내림차순), 방 이름·보낸 사람·크기·시각·entry 참조', () => {
  const rooms = new Map([
    ['family', { entries: [txt(1, 100), att(2, 200), att(5, 500, { image: { url: 'blob:x', type: 'image/jpeg' } })] }],
    ['family-acc', { entries: [att(3, 300, { fileName: '보고서.pdf', isMe: true, sender: 'owner-web-1', senderName: 'jinon86 · PC' }), txt(4, 400)] }],
  ]);
  const files = collectAttachments(rooms, { roomLabel: (id) => ({ family: '가족', 'family-acc': '공명✴️' })[id] ?? id });
  assert.deepEqual(files.map((f) => [f.roomId, f.seq]), [['family', 5], ['family-acc', 3], ['family', 2]]);
  const [photo, pdf] = files;
  assert.equal(photo.roomName, '가족');
  assert.equal(photo.image, true);
  assert.equal(photo.fileName, null);
  assert.equal(photo.senderName, '쩡이🍎 · 아이폰');
  assert.equal(photo.size, 1234);
  assert.equal(photo.ts, 500);
  assert.equal(photo.key, 'seq-5');
  assert.equal(photo.entry, rooms.get('family').entries[2], 'entry 참조를 그대로 실어 같은 load() 로 내려받는다');
  assert.equal(pdf.roomName, '공명✴️');
  assert.equal(pdf.fileName, '보고서.pdf');
  assert.equal(pdf.isMe, true);
});

test('collectAttachments: {roomId, entries} 객체 배열도 받고, 시각 없는 첨부는 뒤로, 같은 시각은 seq 내림차순', () => {
  const files = collectAttachments([
    { roomId: 'a', entries: [att(1, null), att(2, 700), att(3, 700)] },
    { roomId: 'b', entries: [att(9, 700)] },
  ]);
  assert.deepEqual(files.map((f) => `${f.roomId}:${f.seq}`), ['b:9', 'a:3', 'a:2', 'a:1']);
  assert.equal(files.at(-1).ts, null);
});

test('collectAttachments: 빈 입력·방 없음·entries 없음은 빈 배열, 잘못된 크기는 0', () => {
  assert.deepEqual(collectAttachments(null), []);
  assert.deepEqual(collectAttachments(new Map()), []);
  assert.deepEqual(collectAttachments([{ roomId: 'x' }]), []);
  assert.deepEqual(collectAttachments([{ roomId: null, entries: [att(1, 1)] }]), [], 'roomId 없는 방은 건너뛴다');
  const [f] = collectAttachments([{ roomId: 'a', entries: [att(1, 1, { size: NaN })] }]);
  assert.equal(f.size, 0);
});

test('attachmentTitle: 파일명 > 사진 라벨 > 파일 라벨', () => {
  const labels = { photo: '[사진]', file: '[파일]' };
  assert.equal(attachmentTitle({ fileName: '가족.heic', image: true }, labels), '가족.heic');
  assert.equal(attachmentTitle({ fileName: null, image: true }, labels), '[사진]');
  assert.equal(attachmentTitle({ fileName: null, image: false }, labels), '[파일]');
});
