// 첨부 미리보기 불러오기·실패·다시 시도(#544 B). node --test archive/native-mls/web/hande/tests/preview-loader.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createPreviewLoader } from '../preview-loader.js';

const JPEG = (() => { const b = new Uint8Array(16); b.set([0xff, 0xd8, 0xff, 0xe0]); return b; })();
const TEXT = new TextEncoder().encode('hello, not an image — 16 bytes+');

function harness() {
  let changes = 0;
  const urls = [];
  const loadPreview = createPreviewLoader({
    createUrl: (bytes, type) => { const u = `blob:${type}:${bytes.length}`; urls.push(u); return u; },
    onChange: () => { changes += 1; },
  });
  return { loadPreview, urls, get changes() { return changes; } };
}
const entry = (load, extra = {}) => ({ kind: 'attachment', size: 16, seq: 7, senderName: '쩡이🍎', load, image: null, previewFailed: false, previewBusy: false, ...extra });

test('성공: 내용이 이미지면 image 가 생기고 previewFailed=false, 바쁜 표식은 끝나면 내려간다', async () => {
  const h = harness();
  const e = entry(async () => JPEG);
  const p = h.loadPreview(e);
  assert.equal(e.previewBusy, true, '부르는 즉시 바쁨');
  await p;
  assert.equal(e.previewBusy, false);
  assert.equal(e.previewFailed, false);
  assert.deepEqual(e.image, { url: 'blob:image/jpeg:16', type: 'image/jpeg', alt: '쩡이🍎의 사진' });
  assert.equal(h.changes, 2, '시작·끝 각 1회 재렌더');
});

test('사진이 아닌 파일(판별 null)은 실패가 아니다 — image 없음, previewFailed=false, 다시 시도 버튼 없음', async () => {
  const h = harness();
  const e = entry(async () => TEXT);
  await h.loadPreview(e);
  assert.equal(e.image, null);
  assert.equal(e.previewFailed, false);
  assert.equal(h.urls.length, 0);
});

test('실패 → previewFailed=true 로 남고(예전엔 조용히 묻힘), 다시 시도하면 같은 load() 를 다시 불러 성공으로 바뀐다', async () => {
  const h = harness();
  let tries = 0;
  const e = entry(async () => { tries += 1; if (tries === 1) throw new Error('blob 404'); return JPEG; });
  await h.loadPreview(e);
  assert.equal(tries, 1);
  assert.equal(e.previewFailed, true);
  assert.equal(e.previewBusy, false);
  assert.equal(e.image, null);
  await h.loadPreview(e);   // 말풍선의 「미리보기 다시 시도」
  assert.equal(tries, 2);
  assert.equal(e.previewFailed, false);
  assert.equal(e.image?.type, 'image/jpeg');
});

test('이미 불러왔거나(image) 불러오는 중(previewBusy)이거나 미리보기 대상이 아니면 load() 를 부르지 않는다', async () => {
  const h = harness();
  let tries = 0;
  const load = async () => { tries += 1; return JPEG; };
  await h.loadPreview(entry(load, { image: { url: 'blob:x', type: 'image/png', alt: '' } }));
  await h.loadPreview(entry(load, { previewBusy: true }));
  await h.loadPreview(entry(load, { kind: 'text' }));
  await h.loadPreview(entry(load, { size: 5 * 1024 * 1024 + 1 }));
  await h.loadPreview(entry(null));
  assert.equal(tries, 0);
  assert.equal(h.changes, 0, '건너뛸 때는 재렌더도 없다');
});

test('같은 entry 를 겹쳐 부르면(폴링 재렌더 + 다시 시도 클릭) 두 번째는 건너뛰어 load() 가 한 번만 돈다', async () => {
  const h = harness();
  let tries = 0;
  let release;
  const e = entry(() => new Promise((resolve) => { tries += 1; release = () => resolve(JPEG); }));
  const first = h.loadPreview(e);
  const second = h.loadPreview(e);
  await second;
  assert.equal(tries, 1);
  release();
  await first;
  assert.equal(e.image?.type, 'image/jpeg');
});
