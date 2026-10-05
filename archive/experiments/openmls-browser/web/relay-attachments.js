// Raw file bytes occupy one MLS application message: no envelope reduces the
// facade's 262144-byte limit. The outer client_id is a display hint only, never
// authentication; downloads have a generated name and an inert MIME type.
export const MAX_ATTACHMENT = 262144;
export const isAttachment = id => /^file-v1-[a-f0-9-]{36}$/.test(id ?? '');

function base64(bytes) {
  let binary = '';
  for (let at = 0; at < bytes.length; at += 8192) binary += String.fromCharCode(...bytes.subarray(at, at + 8192));
  return btoa(binary);
}

export function attachmentOutbox({storage, key, device, encrypt, post, newId = () => crypto.randomUUID()}) {
  let pending = null;
  const saved = storage.getItem(key);
  if (saved) {
    pending = JSON.parse(saved);
    if (pending.device !== device || !isAttachment(pending.client_id) || pending.kind !== 'application'
        || !Number.isSafeInteger(pending.epoch) || pending.epoch < 0
        || typeof pending.bytes !== 'string' || pending.bytes.length > 360448
        || !Number.isSafeInteger(pending.size) || pending.size < 0 || pending.size > MAX_ATTACHMENT) {
      throw new Error('보류 중인 첨부 정보가 손상됐다. 전송을 중단한다.');
    }
  }
  let running = false;
  return {
    get pending() { return pending !== null; },
    async send(file, epoch) {
      if (running) throw new Error('첨부를 전송 중이다.');
      running = true;
      try {
        if (!pending) {
          if (!file || !Number.isSafeInteger(file.size) || file.size < 0 || file.size > MAX_ATTACHMENT) {
            throw new Error('첨부파일은 256 KiB(262,144바이트) 이하여야 한다.');
          }
          const bytes = new Uint8Array(await file.arrayBuffer());
          if (bytes.length !== file.size) throw new Error('첨부파일 크기가 바뀌었다. 다시 선택한다.');
          const ciphertext = await encrypt(bytes);
          pending = {device, client_id: `file-v1-${newId()}`, kind: 'application', epoch,
            bytes: base64(new Uint8Array(ciphertext)), size: bytes.length};
        }
        // Persist before POST, including on a retry after a storage error. No
        // file name, MIME type or plaintext is kept across a page reload.
        storage.setItem(key, JSON.stringify(pending));
        const {size, ...payload} = pending;
        const result = await post(payload);
        if ((result.status === 201 || result.status === 200 && result.body?.duplicate === true)
            && Number.isSafeInteger(result.body?.seq) && result.body.seq > 0) {
          // If removal fails, keep the exact payload for another deduplicated
          // retry; never prepare a second ciphertext after uncertain delivery.
          storage.removeItem(key);
          pending = null;
          return {...result.body, size};
        }
        if (result.status === 409 && result.body?.error === 'cas_mismatch') {
          // The relay checks existing client_id bytes BEFORE epoch CAS. This
          // response proves the payload was not stored. Re-select after sync.
          storage.removeItem(key);
          pending = null;
          throw new Error('방이 변경돼 첨부를 보내지 못했다. 동기화 후 파일을 다시 보낸다.');
        }
        throw new Error(`첨부 전송 미확인(${result.status}). 같은 첨부를 다시 보내기로 재시도한다.`);
      } finally { running = false; }
    },
  };
}
