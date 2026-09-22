import test from 'node:test';
import assert from 'node:assert/strict';
import { Window } from 'happy-dom';
const window = new Window({ url: 'https://chat.example.test/' });
for (const key of ['window', 'document', 'CSS']) globalThis[key] = window[key];
const ui = await import('../../src/ui.js');
const { PhotoPreviews } = await import('../../src/photo-previews.js');
const { attachmentFromContent } = await import('../../src/attachments.js');
const flush = () => new Promise((resolve) => setImmediate(resolve));

test('received plain/encrypted photos render inline, open on click, and keep the composer on refresh', async () => {
  document.body.innerHTML = '<div id="app"></div>';
  const app = document.getElementById('app');
  const contents = [
    { msgtype: 'm.image', body: '사진.png', url: 'mxc://hs/plain', info: { mimetype: 'image/png' } },
    { msgtype: 'm.image', body: '<img src=x>.png', file: { url: 'mxc://hs/encrypted', key: { k: 'key' }, iv: 'iv', hashes: { sha256: 'h' } }, info: { mimetype: 'image/png' } },
  ];
  const attachments = contents.map(attachmentFromContent);
  const opened = [], fetched = [];
  let id = 0;
  const cache = new PhotoPreviews({ fetchPhoto: async (attachment) => { fetched.push(attachment); return new Blob(['png']); },
    createUrl: () => `blob:photo/${++id}`, revokeUrl() {}, onChange: () => render() });
  const props = { room: { roomId: '!room', displayName: '가족', agents: [] },
    timeline: attachments.map((attachment, i) => ({ eventId: `$${i}`, kind: 'photo', attachment, body: attachment.name, isMe: i === 1, name: '엄마' })),
    photoPreviews: cache, onOpenAttachment: (attachment) => opened.push(attachment), onSend() {}, onAttach() {}, onBack() {} };
  function render() { cache.sync('!room', attachments); ui.renderRoom(app, props); }
  render();
  assert.equal(app.querySelectorAll('.photo-preview [role=status]').length, 2);
  const composer = app.querySelector('textarea');
  composer.value = '작성 중';
  await flush();
  assert.equal(app.querySelectorAll('.bubble img').length, 2);
  assert.equal(app.querySelector('img').getAttribute('src'), 'blob:photo/1');
  assert.equal(app.querySelectorAll('img')[1].alt, '<img src=x>.png');
  app.querySelector('button.photo-preview').click();
  assert.equal(opened[0], attachments[0]);
  render();
  await flush();
  assert.equal(fetched.length, 2);
  assert.equal(app.querySelector('textarea'), composer);
  assert.equal(composer.value, '작성 중');
  // Browser decode failures get the same explicit retry affordance as network failures.
  app.querySelector('img').dispatchEvent(new window.Event('error'));
  assert.equal(app.querySelectorAll('.photo-retry').length, 1);
  app.querySelector('.photo-retry').click();
  await flush();
  assert.equal(fetched.length, 3);
  assert.equal(app.querySelectorAll('.bubble img').length, 2);
  cache.clear();
});
