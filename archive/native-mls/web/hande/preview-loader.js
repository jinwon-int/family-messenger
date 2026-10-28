// 첨부 미리보기 불러오기 + 실패 시 「다시 시도」(#544 B) — 패밀리챗 photo-previews.js 의 queued/ready/error 전이 이식.
// 예전에는 `entry.load().catch(() => {})` 로 실패가 조용히 묻혀 file-v2 다운로드가 한 번 막히면 사진이 영영 「파일」 행이었다.
// 이제 실패는 `entry.previewFailed` 로 남고, 말풍선의 「다시 시도」가 같은 load() 를 다시 부른다(file-v2 는 load 가 실패하면
// 캐시를 비워 다음 호출에서 다시 받는다 — room.js emitFileV2). 사진이 아닌 파일(판별 null)은 실패가 아니다 — 그냥 파일 행.
// 순수 모듈: imageType·createUrl·onChange 를 주입받아 node:test 로 검증한다(tests/preview-loader.test.mjs).

import {imageType as sniff, shouldPreview} from './attachment-view.js';

/**
 * @param {object} deps
 * @param {(bytes: Uint8Array) => string|null} [deps.imageType]  내용 판별(attachment-view.js)
 * @param {(bytes: Uint8Array, type: string) => string} deps.createUrl  blob URL 생성
 * @param {() => void} deps.onChange  entry 상태가 바뀔 때(화면 재렌더)
 * @param {(entry: object) => string} [deps.altFor]  img alt
 * @returns {(entry: object) => Promise<void>} loadPreview — 한 entry 에 대해 동시에 한 번만 돈다
 */
export function createPreviewLoader({ imageType = sniff, createUrl, onChange, altFor = (e) => `${e.senderName ?? ''}의 사진` }) {
  return async function loadPreview(entry) {
    if (!shouldPreview(entry) || entry.image || entry.previewBusy) return;
    entry.previewBusy = true;
    onChange();
    try {
      const bytes = await entry.load();
      const type = imageType(bytes);
      if (type) entry.image = { url: createUrl(bytes, type), type, alt: altFor(entry) };
      entry.previewFailed = false;
    } catch (_) {
      entry.previewFailed = true;
    } finally {
      entry.previewBusy = false;
      onChange();
    }
  };
}
