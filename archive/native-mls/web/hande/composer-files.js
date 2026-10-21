// 작성창 붙여넣기·끌어다 놓기 첨부(#480 B, PC 편의). DataTransfer 에서 보낼 파일 하나를 고른다 — 한데 첨부는
// 한 번에 하나(room.js sendAttachment)라 첫 파일만 쓴다. 이미지가 있으면 이미지를 우선한다(스크린샷 붙여넣기).
// 글자만 있는 붙여넣기(items 에 파일 없음)는 null — 브라우저 기본(텍스트 붙여넣기)에 맡긴다.

/**
 * @param {{items?: ArrayLike<{kind?: string, type?: string, getAsFile?: () => File|null}>, files?: ArrayLike<File>}|null|undefined} transfer
 * @returns {File|null}
 */
export function pickTransferFile(transfer) {
  if (!transfer) return null;
  const files = [];
  const items = transfer.items ? Array.from(transfer.items) : [];
  for (const item of items) {
    if (item?.kind !== 'file' || typeof item.getAsFile !== 'function') continue;
    const file = item.getAsFile();
    if (file) files.push(file);
  }
  if (files.length === 0 && transfer.files) for (const file of Array.from(transfer.files)) if (file) files.push(file);
  if (files.length === 0) return null;
  return files.find((file) => String(file.type || '').startsWith('image/')) ?? files[0];
}

/** 끌어다 놓기 중인 것이 파일인지(텍스트 선택을 끌 때는 첨부 표시를 켜지 않는다). */
export function transferHasFiles(transfer) {
  const types = transfer?.types ? Array.from(transfer.types) : [];
  return types.includes('Files');
}
