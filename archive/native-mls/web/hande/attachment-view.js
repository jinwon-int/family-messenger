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
export function downloadSpec(seq, type) {
  const ext = EXTENSION[type];
  const stem = `attachment-${Number.isSafeInteger(seq) ? seq : 'x'}`;
  return ext ? {name: `${stem}.${ext}`, type} : {name: `${stem}.bin`, type: INERT_TYPE};
}
