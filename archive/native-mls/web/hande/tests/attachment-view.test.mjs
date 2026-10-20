// attachment-view.js: 받은 첨부의 미리보기 판별 상한·내용 기반 이미지 판별·저장 파일명 (pure node:test).
// 2026-10-20 family seq 372 — iPhone 사진 3,278,613바이트가 PC 크롬에서 "파일 · attachment-372.bin" 으로
// 보인 회귀: 미리보기 상한(옛 2 MiB)이 첨부 한도(5 MiB, #364)보다 낮았다.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {imageType, shouldPreview, downloadSpec, IMAGE_PREVIEW_MAX, INERT_TYPE} from '../attachment-view.js';
import {MAX_ATTACHMENT} from '../relay-attachments.js';

const head = (...bytes) => { const b = new Uint8Array(16); b.set(bytes); return b; };
const JPEG = head(0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00);
const PNG = head(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a);
const GIF = head(0x47, 0x49, 0x46, 0x38, 0x39, 0x61);
const WEBP = head(0x52, 0x49, 0x46, 0x46, 0x10, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50);
const HEIC = head(0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63);   // ftypheic

test('imageType: 래스터 이미지 4종만 내용으로 판별, HEIC·텍스트·짧은 바이트는 null', () => {
  assert.equal(imageType(JPEG), 'image/jpeg');
  assert.equal(imageType(PNG), 'image/png');
  assert.equal(imageType(GIF), 'image/gif');
  assert.equal(imageType(WEBP), 'image/webp');
  assert.equal(imageType(HEIC), null);
  assert.equal(imageType(new TextEncoder().encode('hello, not an image at all')), null);
  assert.equal(imageType(new Uint8Array([0xff, 0xd8, 0xff])), null);   // < 12 bytes
  assert.equal(imageType(null), null);
});

test('shouldPreview: 첨부 한도(5 MiB)까지 — 3.1 MiB 사진(seq 372)도 판별 대상, 한도 초과·본체 없음·텍스트는 제외', () => {
  assert.equal(IMAGE_PREVIEW_MAX, MAX_ATTACHMENT);
  assert.equal(IMAGE_PREVIEW_MAX, 5 * 1024 * 1024);
  const load = async () => JPEG;
  assert.equal(shouldPreview({kind: 'attachment', size: 3_278_613, load}), true);
  assert.equal(shouldPreview({kind: 'attachment', size: MAX_ATTACHMENT, load}), true);
  assert.equal(shouldPreview({kind: 'attachment', size: MAX_ATTACHMENT + 1, load}), false);
  assert.equal(shouldPreview({kind: 'attachment', size: 100, load: null}), false);
  assert.equal(shouldPreview({kind: 'text', size: 100, load}), false);
  assert.equal(shouldPreview({kind: 'attachment', size: -1, load}), false);
  assert.equal(shouldPreview(null), false);
});

test('downloadSpec: 판별된 이미지는 확장자+MIME, 그 밖은 attachment-<seq>.bin + 불활성 MIME', () => {
  assert.deepEqual(downloadSpec(372, 'image/jpeg'), {name: 'attachment-372.jpg', type: 'image/jpeg'});
  assert.deepEqual(downloadSpec(7, 'image/png'), {name: 'attachment-7.png', type: 'image/png'});
  assert.deepEqual(downloadSpec(8, 'image/gif'), {name: 'attachment-8.gif', type: 'image/gif'});
  assert.deepEqual(downloadSpec(9, 'image/webp'), {name: 'attachment-9.webp', type: 'image/webp'});
  assert.deepEqual(downloadSpec(372, null), {name: 'attachment-372.bin', type: INERT_TYPE});
  // 발신자가 주장하는 MIME 은 들어올 길이 없지만, 목록 밖 값은 무엇이든 불활성으로 떨어진다.
  assert.deepEqual(downloadSpec(10, 'text/html'), {name: 'attachment-10.bin', type: INERT_TYPE});
  assert.deepEqual(downloadSpec(11, 'image/svg+xml'), {name: 'attachment-11.bin', type: INERT_TYPE});
  assert.deepEqual(downloadSpec(null, 'image/jpeg'), {name: 'attachment-x.jpg', type: 'image/jpeg'});
  assert.deepEqual(downloadSpec(undefined, null), {name: 'attachment-x.bin', type: INERT_TYPE});
});
