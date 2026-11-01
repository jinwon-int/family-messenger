// 받은 첨부를 어떻게 보여 주고 저장할지 — 내용(매직 바이트)만 보고 정한다.
// 첨부는 봉투 없는 날 바이트 한 덩어리(relay-attachments.js)라 발신자가 말한 파일명·MIME 이 없고,
// 있더라도 믿지 않는다. 여기서 판별한 래스터 이미지(JPEG/PNG/GIF/WebP)만 미리보기와
// 확장자를 얻고, 나머지는 전부 `attachment-<seq>.bin` + 불활성 MIME 으로 남는다.
// iOS AttachmentFormat.sniffMime / AttachmentSupport(사진은 한도 안의 JPEG/PNG/GIF/WebP 그대로).
import {MAX_ATTACHMENT} from './relay-attachments.js';

/** 미리보기 판별 상한 = 첨부 한도. iOS 는 #364 결정 B 이후 5 MiB 까지 사진을 그대로 보내므로
 *  (2026-10-20 family seq 372: 3.1 MiB 사진이 "파일"로 보임) 그보다 낮은 상한은 사진을 파일로 만든다. */
export const IMAGE_PREVIEW_MAX = MAX_ATTACHMENT;

const EXTENSION = {'image/jpeg': 'jpg', 'image/png': 'png', 'image/gif': 'gif', 'image/webp': 'webp'};
export const INERT_TYPE = 'application/octet-stream';

/** 래스터 이미지 MIME(JPEG/PNG/GIF/WebP) 또는 null. 브라우저가 그릴 수 있는 형식만 — HEIC 등은 null. */
export function imageType(bytes) {
  if (!bytes || bytes.length < 12) return null;
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return 'image/png';
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
  if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x38) return 'image/gif';
  if (bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46
      && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) return 'image/webp';
  return null;
}

/** 이 첨부를 미리보기로 판별해 볼지(크기 한도 안, 본체를 읽을 수 있을 때). */
export function shouldPreview(entry) {
  return entry?.kind === 'attachment' && typeof entry.load === 'function'
    && Number.isSafeInteger(entry.size) && entry.size >= 0 && entry.size <= IMAGE_PREVIEW_MAX;
}

/**
 * 저장 파일명·MIME. `type` 은 imageType() 결과(내용 판별)만 넘긴다 — 판별된 이미지는
 * `attachment-<seq>.<jpg|png|gif|webp>` + 그 MIME, 그 밖은 `attachment-<seq>.bin` + 불활성 MIME.
 */
export function downloadSpec(seq, type, fileName = null) {
  const ext = EXTENSION[type];
  const stem = `attachment-${Number.isSafeInteger(seq) ? seq : 'x'}`;
  const spec = ext ? {name: `${stem}.${ext}`, type} : {name: `${stem}.bin`, type: INERT_TYPE};
  // file-v2 (#499): the sender may name the file. A name already reduced by file-v2.js
  // safeFileName() (last path segment, no control chars, not dot-led) replaces the generated
  // one; the MIME stays the sniffed type or the inert one — never the sender's.
  if (typeof fileName === 'string' && fileName && !/[\\/\u0000-\u001f\u007f]/.test(fileName) && !fileName.startsWith('.')) spec.name = fileName;
  return spec;
}

// ---- 사진 자리 크기(#647 ①) ----
// file-v2 설명자 w/h 힌트(보낸 쪽이 잰 표시 방향 픽셀)가 있으면, 사진을 받기·디코드하기 **전에** 말풍선 자리를 최종 크기로 잡는다 —
// 방에 들어온 뒤 사진 행 높이가 바뀌어 타임라인 위치가 어긋나지 않게(#497·#647). 상자는 styles.css 의
// `.bubble .body.media img { max-width: min(400px, 72vw); max-height: 440px }` 와 같다(값을 바꾸면 둘 다).

export const MEDIA_MAX_WIDTH_PX = 400;
export const MEDIA_MAX_WIDTH_VW = 72;
export const MEDIA_MAX_HEIGHT_PX = 440;
const MAX_HINT = 20000;   // file-v2.js MAX_DIMENSION(FILE-V2.md §1)

/** {w, h} 힌트를 검증해 그대로(둘 다 1~20000 정수) 또는 null. */
export function mediaDims(dims) {
  const ok = n => Number.isSafeInteger(n) && n >= 1 && n <= MAX_HINT;
  return dims && ok(dims.w) && ok(dims.h) ? {w: dims.w, h: dims.h} : null;
}

/**
 * 사진 상자의 인라인 style — 너비 = min(원본 폭, 400px, 72vw, 440px × 비), 높이는 aspect-ratio 로.
 * CSS 의 max-width·max-height 가 원본 크기의 사진에 하는 일(비를 지켜 줄이고 키우지 않음)을 디코드 없이 같게 계산한다.
 * 같은 값을 빈 자리와 img 에 함께 쓴다 — 로딩 전후 행 높이가 같다. 힌트가 없으면 null(종전처럼 사진 고유 크기).
 */
export function mediaBoxStyle(dims) {
  const d = mediaDims(dims);
  if (!d) return null;
  const byHeight = Math.round(MEDIA_MAX_HEIGHT_PX * d.w / d.h * 1000) / 1000;
  return `width: min(${d.w}px, ${MEDIA_MAX_WIDTH_PX}px, ${MEDIA_MAX_WIDTH_VW}vw, ${byHeight}px); aspect-ratio: ${d.w} / ${d.h}; height: auto;`;
}

/** 크기를 아는 사진이 아직 불러오는 중인가 — 이때 파일 줄 대신 같은 크기의 사진 자리를 그린다. */
export function pendingMedia(entry) {
  return entry?.kind === 'attachment' && !entry.image && !entry.previewFailed && Boolean(entry.previewBusy) && mediaDims(entry.dims) !== null;
}

/** 디코드된 사진의 비가 힌트와 맞는가(상대 2%, iOS ImagePixelSize.resolve 와 같은 기준). 틀린 힌트면 img 의 고정 크기를 푼다. */
export function dimsAgree(dims, naturalWidth, naturalHeight, tolerance = 0.02) {
  const d = mediaDims(dims);
  if (!d || !(naturalWidth > 0) || !(naturalHeight > 0)) return true;
  const measured = naturalWidth / naturalHeight;
  return Math.abs(d.w / d.h - measured) / measured <= tolerance;
}
