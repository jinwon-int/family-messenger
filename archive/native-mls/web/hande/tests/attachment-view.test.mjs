// attachment-view.js: 받은 첨부의 미리보기 판별 상한·내용 기반 이미지 판별·저장 파일명 (pure node:test).
// 2026-10-20 family seq 372 — iPhone 사진 3,278,613바이트가 PC 크롬에서 "파일 · attachment-372.bin" 으로
// 보인 회귀: 미리보기 상한(옛 2 MiB)이 첨부 한도(5 MiB, #364)보다 낮았다.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {imageType, shouldPreview, downloadSpec, IMAGE_PREVIEW_MAX, INERT_TYPE,
  mediaDims, mediaBoxStyle, pendingMedia, dimsAgree, MEDIA_MAX_WIDTH_PX, MEDIA_MAX_WIDTH_VW, MEDIA_MAX_HEIGHT_PX} from '../attachment-view.js';
import {readFileSync} from 'node:fs';
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

test('downloadSpec: a safe file-v2 name replaces the generated one, MIME stays sniffed/inert (#499)', async () => {
  const {downloadSpec, INERT_TYPE} = await import('../attachment-view.js');
  assert.deepEqual(downloadSpec(5, 'image/png', '사진.png'), {name: '사진.png', type: 'image/png'});
  assert.deepEqual(downloadSpec(5, null, 'report.html'), {name: 'report.html', type: INERT_TYPE}, 'sender name never sets the MIME');
  for (const bad of [null, '', '.env', 'a/b', 'a\\b', 'x\u0001y']) assert.equal(downloadSpec(5, null, bad).name, 'attachment-5.bin', String(bad));
});

// ---- #647 ①: 설명자 w/h 로 사진 상자 크기를 디코드 전에 정한다 ----

test('mediaDims: 둘 다 1~20000 정수일 때만 힌트', () => {
  assert.deepEqual(mediaDims({w: 4032, h: 3024}), {w: 4032, h: 3024});
  assert.deepEqual(mediaDims({w: 1, h: 20000, extra: 1}), {w: 1, h: 20000}, 'extra keys dropped');
  for (const bad of [null, undefined, {}, {w: 10}, {w: 0, h: 5}, {w: 5, h: 20001}, {w: 1.5, h: 2}, {w: '10', h: 10}, {w: -1, h: 3}]) {
    assert.equal(mediaDims(bad), null, JSON.stringify(bad));
  }
});

test('mediaBoxStyle: CSS 사진 상자(min(400px, 72vw) × 440px)와 같은 맞춤 — 가로·세로·정사각·극단 비·작은 사진', () => {
  assert.equal(mediaBoxStyle({w: 4032, h: 3024}), 'width: min(4032px, 400px, 72vw, 586.667px); aspect-ratio: 4032 / 3024; height: auto;', 'landscape: width-bound');
  assert.equal(mediaBoxStyle({w: 3024, h: 4032}), 'width: min(3024px, 400px, 72vw, 330px); aspect-ratio: 3024 / 4032; height: auto;', 'portrait: height-bound → 330 × 440');
  assert.equal(mediaBoxStyle({w: 1000, h: 1000}), 'width: min(1000px, 400px, 72vw, 440px); aspect-ratio: 1000 / 1000; height: auto;');
  assert.match(mediaBoxStyle({w: 100, h: 20000}), /min\(100px, 400px, 72vw, 2\.2px\)/, 'a very tall strip stays inside 440px');
  assert.match(mediaBoxStyle({w: 120, h: 80}), /min\(120px, /, 'small photos are not enlarged (same as max-width/max-height)');
  assert.equal(mediaBoxStyle(null), null, 'no hint → natural size as before');
  assert.equal(mediaBoxStyle({w: 0, h: 1}), null);
});

test('mediaBoxStyle 상수가 styles.css 의 사진 상자와 같다', () => {
  const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
  const rule = css.match(/\.bubble \.body\.media img \{([^}]*)\}/)?.[1] ?? '';
  assert.match(rule, new RegExp(`max-width: min\\(${MEDIA_MAX_WIDTH_PX}px, ${MEDIA_MAX_WIDTH_VW}vw\\)`));
  assert.match(rule, new RegExp(`max-height: ${MEDIA_MAX_HEIGHT_PX}px`));
  assert.match(css, /\.media-placeholder \{[^}]*max-width: min\(400px, 72vw\); max-height: 440px/);
});

test('pendingMedia: 크기를 아는 사진을 불러오는 동안만 사진 자리', () => {
  const base = {kind: 'attachment', image: null, previewFailed: false, previewBusy: true, dims: {w: 3, h: 4}};
  assert.equal(pendingMedia(base), true);
  assert.equal(pendingMedia({...base, dims: null}), false, 'legacy: file row while loading, as before');
  assert.equal(pendingMedia({...base, previewBusy: false}), false, 'done and not an image → file row');
  assert.equal(pendingMedia({...base, previewFailed: true}), false, 'failed → file row with retry');
  assert.equal(pendingMedia({...base, image: {url: 'blob:x'}}), false, 'loaded → the img');
  assert.equal(pendingMedia({...base, kind: 'text'}), false);
  assert.equal(pendingMedia(null), false);
});

test('dimsAgree: 디코드한 비가 힌트와 2% 안이면 고정 크기 유지, 아니면 푼다', () => {
  assert.equal(dimsAgree({w: 3024, h: 4032}, 3024, 4032), true);
  assert.equal(dimsAgree({w: 3024, h: 4032}, 300, 401), true, 'rounding');
  assert.equal(dimsAgree({w: 4032, h: 3024}, 3024, 4032), false, 'a wrong (unrotated) hint');
  assert.equal(dimsAgree(null, 10, 10), true, 'no hint → nothing to undo');
  assert.equal(dimsAgree({w: 3, h: 4}, 0, 0), true, 'not decoded yet');
});
