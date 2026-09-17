import test from 'node:test';
import assert from 'node:assert/strict';
import { attachmentFromContent, collectAttachments, fileboxRefreshUrl, mediaDownloadPath } from '../src/attachments.js';

test('attachmentFromContent: 평문 첨부(m.image/m.video/m.file/m.audio)와 종류·크기·mimetype', () => {
  const photo = attachmentFromContent({ msgtype: 'm.image', body: 'menu.jpg', url: 'mxc://hs/abc', info: { mimetype: 'image/jpeg', size: 1200 } });
  assert.deepEqual(photo, { kind: 'photo', name: 'menu.jpg', mimetype: 'image/jpeg', size: 1200, url: 'mxc://hs/abc', encrypted: null });
  assert.equal(attachmentFromContent({ msgtype: 'm.video', body: 'v.mp4', url: 'mxc://hs/v' }).kind, 'video');
  assert.equal(attachmentFromContent({ msgtype: 'm.file', body: 'a.pdf', url: 'mxc://hs/f' }).kind, 'file');
  assert.equal(attachmentFromContent({ msgtype: 'm.audio', body: 'a.ogg', url: 'mxc://hs/a' }).kind, 'file');
  assert.equal(attachmentFromContent({ msgtype: 'm.file', url: 'mxc://hs/f' }).name, 'file');
  assert.equal(attachmentFromContent({ msgtype: 'm.file', body: 'a', url: 'mxc://hs/f' }).mimetype, 'application/octet-stream');
});

test('attachmentFromContent: 암호화 첨부(content.file)는 키 재료를 함께 싣고, 키가 없으면 버린다', () => {
  const file = { url: 'mxc://hs/enc', key: { kty: 'oct', k: 'x' }, iv: 'iv', hashes: { sha256: 'h' }, v: 'v2', mimetype: 'image/png' };
  const att = attachmentFromContent({ msgtype: 'm.image', body: 'p.png', file, info: { size: 10 } });
  assert.equal(att.url, 'mxc://hs/enc');
  assert.deepEqual(att.encrypted, { key: file.key, iv: 'iv', hashes: file.hashes, v: 'v2' });
  assert.equal(att.mimetype, 'image/png'); // info.mimetype 없으면 file.mimetype
  assert.equal(attachmentFromContent({ msgtype: 'm.image', body: 'p.png', file: { url: 'mxc://hs/enc' } }), null);
});

test('attachmentFromContent: 첨부가 아니거나 mxc가 아니면 null', () => {
  assert.equal(attachmentFromContent({ msgtype: 'm.text', body: '안녕' }), null);
  assert.equal(attachmentFromContent({ msgtype: 'm.image', body: 'x', url: 'https://evil/x.jpg' }), null);
  assert.equal(attachmentFromContent(null), null);
});

test('mediaDownloadPath: 인증 미디어 v1 경로, 서버·ID는 URL 인코딩', () => {
  assert.equal(mediaDownloadPath('mxc://matrix.example.com/AbC123'), '/_matrix/client/v1/media/download/matrix.example.com/AbC123');
  assert.equal(mediaDownloadPath('mxc://hs:8448/a b'), '/_matrix/client/v1/media/download/hs%3A8448/a%20b');
  assert.equal(mediaDownloadPath('https://x'), null);
  assert.equal(mediaDownloadPath(''), null);
});

test('collectAttachments: 모든 방을 합쳐 최신순, 방 이름·보낸 사람·시각을 붙인다', () => {
  const rooms = [
    { summary: { roomId: '!a', displayName: '우리 가족' }, timeline: [
      { eventId: '$1', name: '엄마', ts: 100, attachment: { kind: 'photo', name: 'a.jpg', url: 'mxc://h/1', mimetype: 'image/jpeg', size: 1, encrypted: null } },
      { eventId: '$2', name: '나', ts: 300, body: '텍스트', attachment: null },
    ] },
    { summary: { roomId: '!b', displayName: '아빠' }, timeline: [
      { eventId: '$3', name: '아빠', ts: 200, attachment: { kind: 'file', name: 'b.pdf', url: 'mxc://h/2', mimetype: 'application/pdf', size: 2, encrypted: null } },
    ] },
  ];
  const list = collectAttachments(rooms);
  assert.deepEqual(list.map((f) => [f.name, f.roomName, f.sender, f.ts]), [['b.pdf', '아빠', '아빠', 200], ['a.jpg', '우리 가족', '엄마', 100]]);
  assert.deepEqual(collectAttachments([]), []);
  assert.deepEqual(collectAttachments(new Map([['!a', rooms[0]]]).values()).length, 1);
});

test('fileboxRefreshUrl: 새로고침 횟수를 쿼리로 붙여 iframe을 다시 탐색하게 한다', () => {
  assert.equal(fileboxRefreshUrl('https://files.example.com/', 0), 'https://files.example.com/');
  assert.equal(fileboxRefreshUrl('https://files.example.com/', 2), 'https://files.example.com/?_files_refresh=2');
  assert.equal(fileboxRefreshUrl('https://files.example.com/?x=1', 1), 'https://files.example.com/?x=1&_files_refresh=1');
});
