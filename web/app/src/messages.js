// Message content mapping and attachment metadata.
//
// Stage 1 supports text plus the three attachment families the roadmap
// names: photos, videos and generic files. Attachments are AES-CTR
// encrypted and the ciphertext goes through the homeserver media repository
// first (the SDK yields an mxc:// URL); this module only shapes the resulting
// m.room.message content (spec EncryptedFile in `content.file`).

export const MSGTYPE_BY_KIND = Object.freeze({
  text: 'm.text',
  photo: 'm.image',
  video: 'm.video',
  file: 'm.file',
});

// The homeserver accepts up to ~100 MiB per request and the homeserver
// evaluation (docs/evidence/homeserver-eval-20260913.md) measured 90 MiB
// uploads succeeding directly — but the tunnel boundary is unverified,
// so the composer guards at 90 MiB until device acceptance (stage 2).
export const MAX_ATTACHMENT_BYTES = 90 * 1024 * 1024;

/**
 * Classify an incoming or outgoing event content.
 * @param {{msgtype?: string, 'm.new_content'?: object}} content
 * @returns {'text'|'photo'|'video'|'file'|'notice'|'encrypted'|'unknown'}
 */
export function messageKind(content) {
  if (!content || typeof content !== 'object') return 'unknown';
  const type = typeof content.msgtype === 'string' && content.msgtype.length > 0
    ? content.msgtype
    : content['m.new_content']?.msgtype;
  switch (type) {
    case 'm.text':
    case 'm.emote':
      return 'text';
    case 'm.image':
      return 'photo';
    case 'm.video':
      return 'video';
    case 'm.file':
      return 'file';
    case 'm.notice':
      return 'notice';
    default:
      return 'unknown';
  }
}

/** Only explicit Matrix HTML on text messages is eligible for rich display.
 * Keep this separate from the DOM sanitizer: event content is still untrusted.
 */
export function formattedMessageBody(content) {
  if (!['text', 'notice'].includes(messageKind(content))) return null;
  return content?.format === 'org.matrix.custom.html'
    && typeof content.formatted_body === 'string'
    && content.formatted_body.length <= 100_000
    ? content.formatted_body : null;
}

/** Korean-friendly size label: 512 바이트, 3.5 KB, 1.2 MB, 2.0 GB. */
export function humanFileSize(bytes) {
  const n = Number(bytes);
  if (!Number.isFinite(n) || n < 0) return '';
  if (n < 1024) return `${Math.round(n)} 바이트`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = n;
  let unit = -1;
  do {
    value /= 1024;
    unit += 1;
  } while (value >= 1024 && unit < units.length - 1);
  const rounded = Math.round(value * 10) / 10;
  return `${Number.isInteger(rounded) ? rounded : rounded.toFixed(1)} ${units[unit]}`;
}

/**
 * Guard for the composer before any upload is attempted.
 * @param {{size: number, type?: string}} file
 * @returns {{ok: true} | {ok: false, reason: 'too-large'|'unsupported'}}
 */
export function validateAttachment(file) {
  if (!file || !Number.isFinite(file.size) || file.size < 0) return { ok: false, reason: 'unsupported' };
  if (file.size > MAX_ATTACHMENT_BYTES) return { ok: false, reason: 'too-large' };
  return { ok: true };
}

const MXC_URL_RE = /^mxc:\/\/[^/]+\/[^/?#]+$/;
const BASE64_RE = /^[A-Za-z0-9+/]+$/;
const BASE64URL_RE = /^[A-Za-z0-9_-]+$/;

/** Unpadded base64 (spec "unpadded Base64"); accepts padded input too. */
function unpaddedBase64(value) {
  return typeof value === 'string' ? value.replace(/=+$/, '') : '';
}

/** JWK `k` is unpadded base64url; map any standard-alphabet input across. */
function unpaddedBase64Url(value) {
  return typeof value === 'string' ? value.replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_') : '';
}

/**
 * Shape the spec EncryptedFile (Matrix E2E attachments, v2) for an uploaded
 * ciphertext from matrix-encrypt-attachment's `encryptAttachment().info`.
 * Normalises the base64 encodings receivers validate (k unpadded base64url,
 * iv / sha256 unpadded base64) and refuses anything not spec-shaped so a
 * malformed attachment never leaves the client.
 * @param {string} mxcUrl mxc:// URL of the uploaded ciphertext
 * @param {{v: 'v2', key: object, iv: string, hashes: {sha256: string}}} info
 * @returns {{url: string, key: {kty: 'oct', alg: 'A256CTR', ext: true, k: string, key_ops: string[]},
 *            iv: string, hashes: {sha256: string}, v: 'v2'}}
 */
export function encryptedFileFor(mxcUrl, info) {
  if (typeof mxcUrl !== 'string' || !MXC_URL_RE.test(mxcUrl)) {
    throw new TypeError('encryptedFileFor: mxc:// URL required');
  }
  const key = info?.key;
  const k = unpaddedBase64Url(key?.k);
  const iv = unpaddedBase64(info?.iv);
  const sha256 = unpaddedBase64(info?.hashes?.sha256);
  if (!key || key.kty !== 'oct' || key.alg !== 'A256CTR' || !BASE64URL_RE.test(k)
    || !BASE64_RE.test(iv) || !BASE64_RE.test(sha256) || info.v !== 'v2') {
    throw new TypeError('encryptedFileFor: spec EncryptedFile (A256CTR, v2) required');
  }
  return {
    url: mxcUrl,
    key: { kty: 'oct', alg: 'A256CTR', ext: true, k, key_ops: ['encrypt', 'decrypt'] },
    iv,
    hashes: { sha256 },
    v: 'v2',
  };
}

/**
 * Build the encrypted-room message content for an uploaded attachment.
 * Matrix E2E attachments: the bytes are AES-CTR encrypted before upload and
 * the content carries `file` (EncryptedFile) — never a top-level `url`, which
 * spec clients and the bridge treat as a plaintext attachment (#308).
 * @param {{name: string, type?: string, size: number}} file original (plaintext) file
 * @param {{url: string, key: object, iv: string, hashes: object, v: string}} encryptedFile
 *   EncryptedFile from encryptedFileFor / ClientAdapter.uploadMedia
 * @param {{width?: number, height?: number, durationSec?: number}} [meta]
 * @returns {{msgtype: string, body: string, file: object, info: object}}
 */
export function attachmentContent(file, encryptedFile, meta = {}) {
  if (!encryptedFile || typeof encryptedFile !== 'object') {
    throw new TypeError('attachmentContent: EncryptedFile required');
  }
  const encrypted = encryptedFileFor(encryptedFile.url, encryptedFile);
  const mimetype = typeof file.type === 'string' && file.type.length > 0 ? file.type : 'application/octet-stream';
  const msgtype = mimetype.startsWith('image/')
    ? MSGTYPE_BY_KIND.photo
    : mimetype.startsWith('video/')
      ? MSGTYPE_BY_KIND.video
      : MSGTYPE_BY_KIND.file;
  const info = { mimetype, size: file.size };
  if (Number.isFinite(meta.width)) info.w = meta.width;
  if (Number.isFinite(meta.height)) info.h = meta.height;
  if (Number.isFinite(meta.durationSec)) info.duration = Math.round(meta.durationSec);
  return { msgtype, body: file.name, file: encrypted, info };
}

/**
 * Insert or replace a timeline entry by event id (in place). Decryption
 * retries re-deliver the same event, so a failure placeholder must give way
 * to the decrypted body instead of duplicating. Entries without an id are
 * always appended.
 * @param {Array<{eventId?: string}>} timeline
 * @param {{eventId?: string}} entry
 * @returns {'appended'|'replaced'}
 */
function sameSender(a, b) {
  return typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
}

/** The answer arrived: drop only a progress bubble the bridge already redacted. */
function dropHeldProgress(timeline, entry) {
  if (entry.isProgress || !entry.userId) return;
  for (let i = timeline.length - 1; i >= 0; i -= 1) {
    const item = timeline[i];
    if (item.isProgress && item.held && sameSender(item.userId, entry.userId)
      && (!Number.isFinite(item.ts) || !Number.isFinite(entry.ts) || entry.ts >= item.ts)) timeline.splice(i, 1);
  }
}

/**
 * The bridge deletes a buried heartbeat and posts a new event id.
 * Keep one progress bubble per sender instead of appending a second one.
 */
function replaceSenderProgress(timeline, entry, eventOrder) {
  if (!entry.isProgress || !entry.userId || !entry.eventId) return null;
  const index = timeline.findIndex((item) => item.isProgress
    && sameSender(item.userId, entry.userId)
    && item.eventId !== entry.eventId);
  if (index < 0) return null;
  if (Number.isFinite(timeline[index].ts) && Number.isFinite(entry.ts) && timeline[index].ts > entry.ts) return 'ignored';
  if (timeline[index].ts === entry.ts) {
    const oldRank = eventOrder.indexOf(timeline[index].eventId);
    const newRank = eventOrder.indexOf(entry.eventId);
    if (oldRank >= 0 && newRank >= 0 && oldRank > newRank) return 'ignored';
  }
  timeline[index] = entry;
  return 'replaced';
}

function placeProgress(timeline) {
  const progress = timeline.filter((item) => item.isProgress && Number.isFinite(item.ts));
  if (!progress.length) return;
  const messages = timeline.filter((item) => !progress.includes(item));
  for (const item of progress.sort((a, b) => a.ts - b.ts)) {
    const index = messages.findIndex((other) => Number.isFinite(other.ts) && other.ts > item.ts);
    messages.splice(index < 0 ? messages.length : index, 0, item);
  }
  timeline.splice(0, timeline.length, ...messages);
}

/**
 * A progress redaction must not collapse the timeline. The bridge still
 * deletes and reposts a buried heartbeat; removing the bubble before the
 * replacement arrives makes the chat scroll shrink, then grow.
 * Hold the bubble until that replacement, or until this sender's answer.
 * If the answer is already below the bubble, the turn is over — remove now.
 * @param {Array<{eventId?: string, isProgress?: boolean, held?: boolean, userId?: string}>} timeline
 * @param {string|null|undefined} eventId
 * @returns {'held'|'removed'|'absent'}
 */
export function retainProgressRedaction(timeline, eventId) {
  if (!eventId) return 'absent';
  const index = timeline.findIndex((item) => item.eventId === eventId);
  if (index < 0) return 'absent';
  const item = timeline[index];
  if (!item.isProgress) {
    timeline.splice(index, 1);
    return 'removed';
  }
  const answered = timeline.slice(index + 1).some((other) => !other.isProgress && sameSender(other.userId, item.userId));
  if (answered) {
    timeline.splice(index, 1);
    return 'removed';
  }
  timeline[index] = { ...item, held: true };
  return 'held';
}

export function mergeTimelineEntry(timeline, entry, { atStart = false, chronological = false, eventOrder = [] } = {}) {
  dropHeldProgress(timeline, entry);
  let result = 'appended';
  if (entry.eventId) {
    const index = timeline.findIndex((item) => item.eventId === entry.eventId);
    if (index >= 0) {
      timeline[index] = entry;
      result = 'replaced';
    }
  }
  // A new heartbeat event id replaces that sender's bubble. It is not a second message.
  if (result !== 'replaced') {
    const progressResult = replaceSenderProgress(timeline, entry, eventOrder);
    if (progressResult === 'ignored') return 'ignored';
    if (progressResult) result = progressResult;
  }
  // 이전 대화(scrollback)는 오래된 순서로 하나씩 앞에 붙는다 — 뒤가 아니라 앞에 넣는다.
  if (result !== 'replaced') {
    if (atStart) {
      timeline.unshift(entry);
      result = 'prepended';
    } else timeline.push(entry);
  }
  // Decryption can complete out of order, even for equal server timestamps.
  // Use the SDK's event sequence to break ties; retain stable order otherwise.
  if (chronological) {
    const ranks = new Map(eventOrder.map((id, index) => [id, index]));
    const ordered = timeline.filter((item) => Number.isFinite(item.ts));
    ordered.sort((a, b) => a.ts - b.ts
      || (ranks.get(a.eventId) ?? Infinity) - (ranks.get(b.eventId) ?? Infinity));
    let index = 0;
    for (let i = 0; i < timeline.length; i++) {
      if (Number.isFinite(timeline[i].ts)) timeline[i] = ordered[index++];
    }
  }
  // A heartbeat belongs at its last update's position, even after hydration,
  // scrollback or delayed decryption. Never use callback arrival time here.
  placeProgress(timeline);
  return result;
}

/** Edit envelopes are not independent bubbles; the SDK validates and applies them. */
export function isMessageEdit(event) {
  const relation = event.getRelation?.() ?? event.getOriginalContent?.()?.['m.relates_to']
    ?? event.getContent?.()?.['m.relates_to'];
  return relation?.rel_type === 'm.replace';
}

/** The bridge's existing heartbeat wire format (including stalled work). */
export function isProgressContent(content) {
  return ['m.text', 'm.notice'].includes(content?.msgtype)
    && /^⏳ (?:Working|Waiting for progress) — \d/.test(content?.body ?? '');
}
