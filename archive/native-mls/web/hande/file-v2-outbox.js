// file-v2 송신 보관함(#499 3단계, archive/native-mls/FILE-V2.md §3) — 한데 웹 전용(relay-app 은 v1 만).
//
// 순서: 파일 바이트 → encryptFile(새 키·nonce, AES-256-GCM) → 릴레이 blob 업로드(내용 주소라 멱등) →
// 설명자 JSON 을 MLS 로 암호화 → 보관(localStorage) → 이벤트 게시(client_id = file-v2-<uuid>).
// 보관하는 것은 **MLS 암호문**뿐이다 — 파일 키가 든 설명자 평문·파일 바이트·이름은 남기지 않는다(새로고침 뒤 재시도는
// 같은 암호문을 다시 게시한다). 업로드 뒤 게시가 불확실하면 같은 바이트로만 다시 보낸다(이중 전송 없음, v1 과 같은 규칙).
//
// 보내기 스위치: SEND_FILE_V2 — #499 전환 계획 3에 따라 모든 기기의 v2 수신(웹·iOS·안드로이드·봇) 확인 뒤 오너 승인으로 켰다.
// 시험용으로 한 브라우저에서만 켜려면 localStorage `hande:file-v2-send` = "1".
import {MAX_FILE_V2, encryptFile, encodeDescriptor} from './file-v2.js';

export const SEND_FILE_V2 = true;   // #499 3단계 켜기(오너 승인) — 끄려면 false 로 되돌린다(보낸 v2 는 계속 열린다)
export const SEND_OVERRIDE_KEY = 'hande:file-v2-send';
/** 이 브라우저가 v2 로 보내는가 — 기본 스위치 또는 시험용 덮어쓰기. */
export function sendsFileV2(storage, enabled = SEND_FILE_V2) {
  if (enabled) return true;
  try { return storage?.getItem(SEND_OVERRIDE_KEY) === '1'; } catch (_) { return false; }
}

export const isFileV2Client = id => /^file-v2-[a-f0-9-]{36}$/.test(id ?? '');
// 설명자 ≤ 4 KiB 의 MLS 암호문(+ 여유)을 base64 로 — 손상된 보관 기록을 거른다.
const MAX_PENDING_BASE64 = Math.ceil((4096 + 4096) / 3) * 4;
const utf8 = new TextEncoder();

function base64(bytes) {
  let binary = '';
  for (let at = 0; at < bytes.length; at += 8192) binary += String.fromCharCode(...bytes.subarray(at, at + 8192));
  return btoa(binary);
}

/** 보낸 쪽 힌트(FILE-V2.md §1): 형식에 맞을 때만 싣는다 — 맞지 않으면 빼고 보낸다(받는 쪽은 내용으로 판단). */
function hints(file) {
  const out = {};
  if (typeof file?.type === 'string' && file.type.length <= 100
      && /^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}\/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}$/.test(file.type)) out.mime = file.type;
  // eslint-disable-next-line no-control-regex
  if (typeof file?.name === 'string' && file.name.length >= 1 && [...file.name].length <= 255 && !/[\u0000-\u001f\u007f-\u009f]/.test(file.name)) out.name = file.name;
  return out;
}

/**
 * @param {object} deps
 * @param {Storage} deps.storage
 * @param {string} deps.key        보관 키(방·기기마다)
 * @param {string} deps.device
 * @param {(bytes: Uint8Array) => Promise<ArrayBuffer|Uint8Array>} deps.encrypt  MLS application 암호화(설명자 평문)
 * @param {(payload: object) => Promise<{status:number, body:any}>} deps.post    POST /events
 * @param {(ciphertext: Uint8Array) => Promise<{status:number, body:any}>} deps.upload  POST /blobs
 */
export function fileV2Outbox({storage, key, device, encrypt, post, upload, newId = () => crypto.randomUUID(),
  locks = globalThis.navigator?.locks, crypto: webCrypto} = {}) {
  let pending = null;
  function readPending() {
    const saved = storage.getItem(key);
    if (!saved) return null;
    const p = JSON.parse(saved);
    if (!p || p.device !== device || !isFileV2Client(p.client_id) || p.kind !== 'application'
        || !Number.isSafeInteger(p.epoch) || p.epoch < 0
        || typeof p.bytes !== 'string' || p.bytes.length > MAX_PENDING_BASE64
        || !Number.isSafeInteger(p.size) || p.size < 1 || p.size > MAX_FILE_V2) {
      throw new Error('보류 중인 첨부 정보가 손상됐다. 전송을 중단한다.');
    }
    return p;
  }
  pending = readPending();
  let persisted = pending !== null;
  let running = false;
  return {
    get pending() { return pending !== null; },
    /** 반환: 릴레이 응답 + {size, descriptor}. descriptor(파일 키 포함)는 이번 호출에서 만든 경우에만 — 새로고침 뒤 재시도면 null. */
    async send(file, epoch) {
      if (running) throw new Error('첨부를 전송 중이다.');
      if (!locks?.request) throw new Error('이 브라우저는 안전한 첨부 전송을 지원하지 않는다.');
      running = true;
      try { return await locks.request(`attachment-outbox:${key}`, {mode: 'exclusive', ifAvailable: true}, async lock => {
        if (!lock) throw new Error('다른 탭에서 첨부를 전송 중이다.');
        const current = readPending();
        if (current && !pending) throw new Error('다른 탭에 보류 중인 첨부가 있다. 새 파일을 보관하고 페이지를 다시 연다.');
        if (pending && (persisted && !current || current && JSON.stringify(current) !== JSON.stringify(pending))) {
          throw new Error('다른 탭에서 첨부 상태가 변경됐다. 페이지를 다시 열어 전송 결과를 확인한다.');
        }
        if (current) { pending = current; persisted = true; }
        let descriptor = null;
        if (!pending) {
          if (!file || !Number.isSafeInteger(file.size) || file.size < 1 || file.size > MAX_FILE_V2) {
            throw new Error('첨부파일은 1바이트 이상 50 MiB(52,428,800바이트) 이하여야 한다.');
          }
          const bytes = new Uint8Array(await file.arrayBuffer());
          if (bytes.length !== file.size) throw new Error('첨부파일 크기가 바뀌었다. 다시 선택한다.');
          const sealed = await encryptFile(bytes, {crypto: webCrypto});
          // 업로드 먼저(FILE-V2.md §3-2): 응답 id 가 계산한 blob 과 같아야 한다. 실패면 아무것도 보관하지 않는다.
          const up = await upload(sealed.ciphertext);
          if (!(up.status === 201 || up.status === 200) || up.body?.id !== sealed.blob) {
            const code = up.body?.error ? ` ${up.body.error}` : '';
            throw new Error(`첨부 업로드 실패(${up.status}${code}). 다시 보내 주세요.`);
          }
          descriptor = encodeDescriptor({blob: sealed.blob, size: sealed.size, key: sealed.key, nonce: sealed.nonce, ...hints(file)});
          const ciphertext = await encrypt(utf8.encode(descriptor));
          pending = {device, client_id: `file-v2-${newId()}`, kind: 'application', epoch,
            bytes: base64(new Uint8Array(ciphertext)), size: sealed.size};
        }
        storage.setItem(key, JSON.stringify(pending));
        persisted = true;
        const {size, ...payload} = pending;
        const result = await post(payload);
        if ((result.status === 201 || result.status === 200 && result.body?.duplicate === true)
            && Number.isSafeInteger(result.body?.seq) && result.body.seq > 0) {
          storage.removeItem(key);
          pending = null; persisted = false;
          return {...result.body, size, descriptor, client_id: payload.client_id};
        }
        if (result.status === 409 && result.body?.error === 'cas_mismatch') {
          // 게시되지 않았음이 확실하다(client_id 검사가 epoch CAS 보다 먼저). 올린 blob 은 보존 기간 뒤 릴레이가 정리한다.
          storage.removeItem(key);
          pending = null; persisted = false;
          throw new Error('방이 변경돼 첨부를 보내지 못했다. 동기화 후 파일을 다시 보낸다.');
        }
        throw new Error(`첨부 전송 미확인(${result.status}). 같은 첨부를 다시 보내기로 재시도한다.`);
      }); } finally { running = false; }
    },
  };
}
