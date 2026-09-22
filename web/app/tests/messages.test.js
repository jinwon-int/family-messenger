import test from 'node:test';
import assert from 'node:assert/strict';
import {
  MAX_ATTACHMENT_BYTES,
  attachmentContent,
  humanFileSize,
  messageKind,
  formattedMessageBody,
  mergeTimelineEntry,
  retainProgressRedaction,
  validateAttachment,
} from '../src/messages.js';

test('Matrix HTML is preserved only on explicit formatted text, with a size bound', () => {
  const content = { msgtype: 'm.text', body: '**안녕**', format: 'org.matrix.custom.html', formatted_body: '<strong>안녕</strong>' };
  assert.equal(formattedMessageBody(content), content.formatted_body);
  assert.equal(formattedMessageBody({ ...content, msgtype: 'm.notice' }), content.formatted_body);
  for (const change of [{ format: undefined }, { msgtype: 'm.image' }, { formatted_body: {} }, { formatted_body: 'x'.repeat(100_001) }]) {
    assert.equal(formattedMessageBody({ ...content, ...change }), null);
  }
  assert.equal(formattedMessageBody(null), null);
});

test('메시지 종류 분류', () => {
  assert.equal(messageKind({ msgtype: 'm.text', body: '안녕' }), 'text');
  assert.equal(messageKind({ msgtype: 'm.emote' }), 'text');
  assert.equal(messageKind({ msgtype: 'm.image' }), 'photo');
  assert.equal(messageKind({ msgtype: 'm.video' }), 'video');
  assert.equal(messageKind({ msgtype: 'm.file' }), 'file');
  assert.equal(messageKind({ msgtype: 'm.notice' }), 'notice');
  assert.equal(messageKind({ msgtype: 'm.key.verification.request' }), 'unknown');
  assert.equal(messageKind(null), 'unknown');
});

test('수정 이벤트는 감싸인 안쪽 msgtype을 따른다', () => {
  assert.equal(messageKind({ msgtype: undefined, 'm.new_content': { msgtype: 'm.image' } }), 'photo');
});

test('사람이 읽는 크기 표시', () => {
  assert.equal(humanFileSize(0), '0 바이트');
  assert.equal(humanFileSize(512), '512 바이트');
  assert.equal(humanFileSize(1024), '1 KB');
  assert.equal(humanFileSize(1536), '1.5 KB');
  assert.equal(humanFileSize(90 * 1024 * 1024), '90 MB');
  assert.equal(humanFileSize(1610612736), '1.5 GB');
  assert.equal(humanFileSize(-1), '');
  assert.equal(humanFileSize(Number.NaN), '');
});

test('첨부 용량 상한: 90 MiB 이하만 허용', () => {
  assert.deepEqual(validateAttachment({ size: 1024 }), { ok: true });
  assert.deepEqual(validateAttachment({ size: MAX_ATTACHMENT_BYTES }), { ok: true });
  const tooLarge = validateAttachment({ size: MAX_ATTACHMENT_BYTES + 1 });
  assert.equal(tooLarge.ok, false);
  assert.equal(tooLarge.reason, 'too-large');
  assert.equal(validateAttachment({ size: Number.NaN }).ok, false);
  assert.equal(validateAttachment(null).ok, false);
});

test('첨부 본문은 mxc URL과 미디어 정보를 담는다', () => {
  const content = attachmentContent(
    { name: '가족사진.jpg', type: 'image/jpeg', size: 2048 },
    'mxc://example.com/abc123',
    { width: 1200, height: 900 },
  );
  assert.equal(content.msgtype, 'm.image');
  assert.equal(content.body, '가족사진.jpg');
  assert.equal(content.url, 'mxc://example.com/abc123');
  assert.deepEqual(content.info, { mimetype: 'image/jpeg', size: 2048, w: 1200, h: 900 });
});

test('영상은 duration을, 알 수 없는 형식은 m.file로 보낸다', () => {
  const video = attachmentContent({ name: 'clip.mp4', type: 'video/mp4', size: 10 }, 'mxc://example.com/v', { durationSec: 12.4 });
  assert.equal(video.msgtype, 'm.video');
  assert.equal(video.info.duration, 12);
  const other = attachmentContent({ name: 'data.bin', type: '', size: 1 }, 'mxc://example.com/f');
  assert.equal(other.msgtype, 'm.file');
  assert.equal(other.info.mimetype, 'application/octet-stream');
  assert.throws(() => attachmentContent({ name: 'x', size: 1 }, 'https://example.com/not-mxc'));
  assert.throws(() => attachmentContent({ name: 'x', size: 1 }, ''));
});

test('mergeTimelineEntry: 같은 event id는 치환하고, id 없는 항목은 항상 덧붙인다 (#125)', () => {
  const timeline = [];
  assert.equal(mergeTimelineEntry(timeline, { eventId: '$a', body: '열 수 없음' }), 'appended');
  assert.equal(mergeTimelineEntry(timeline, { eventId: '$b', body: '둘째' }), 'appended');
  assert.equal(mergeTimelineEntry(timeline, { eventId: '$a', body: '복호화됨' }), 'replaced');
  assert.equal(mergeTimelineEntry(timeline, { body: '무명' }), 'appended');
  assert.equal(mergeTimelineEntry(timeline, { body: '무명' }), 'appended');
  assert.deepEqual(timeline.map((e) => e.body), ['복호화됨', '둘째', '무명', '무명']);
});

test('mergeTimelineEntry: atStart는 앞에 붙이고(이전 대화), 같은 id는 치환한다', () => {
  const timeline = [{ eventId: '$c', body: '셋' }];
  assert.equal(mergeTimelineEntry(timeline, { eventId: '$b', body: '둘' }, { atStart: true }), 'prepended');
  assert.equal(mergeTimelineEntry(timeline, { eventId: '$a', body: '하나' }, { atStart: true }), 'prepended');
  assert.equal(mergeTimelineEntry(timeline, { eventId: '$d', body: '넷' }), 'appended');
  assert.equal(mergeTimelineEntry(timeline, { eventId: '$b', body: '둘!' }, { atStart: true }), 'replaced');
  assert.deepEqual(timeline.map((e) => e.body), ['하나', '둘!', '셋', '넷']);
});

test('진행 말풍선 삭제는 자리를 유지하고, 재게시·답이 그 자리를 이어받는다', () => {
  const timeline = [
    { eventId: '$work', userId: '@bot:example.test', isProgress: true, ts: 100, body: '⏳ Working — 1s' },
    { eventId: '$chat', userId: '@owner:example.test', ts: 200, body: '중간에 온 말' },
  ];
  assert.equal(retainProgressRedaction(timeline, '$work'), 'held');
  assert.equal(timeline[0].held, true);
  assert.equal(timeline.length, 2);
  assert.equal(mergeTimelineEntry(timeline, {
    eventId: '$work2', userId: '@bot:example.test', isProgress: true, ts: 300, body: '⏳ Waiting for progress — 3s',
  }), 'replaced');
  assert.deepEqual(timeline.map((item) => item.eventId), ['$chat', '$work2']);
  assert.equal(timeline[1].held, undefined);
  retainProgressRedaction(timeline, '$work2');
  assert.equal(timeline.some((item) => item.held), true);
  mergeTimelineEntry(timeline, { eventId: '$answer', userId: '@bot:example.test', ts: 400, body: '최종 답변' });
  assert.deepEqual(timeline.map((item) => item.eventId), ['$chat', '$answer']);
});

test('답이 이미 아래에 있으면 진행 말풍선 삭제는 바로 빼는 것이다', () => {
  const timeline = [
    { eventId: '$work', userId: '@bot:example.test', isProgress: true, ts: 100, body: '⏳ Working — 1s' },
    { eventId: '$answer', userId: '@bot:example.test', ts: 200, body: '최종 답변' },
  ];
  assert.equal(retainProgressRedaction(timeline, '$work'), 'removed');
  assert.deepEqual(timeline.map((item) => item.eventId), ['$answer']);
  assert.equal(retainProgressRedaction([{ eventId: '$chat', body: '일반' }], '$chat'), 'removed');
});
