// Message content mapping and attachment metadata.
//
// Stage 1 supports text plus the three attachment families the roadmap
// names: photos, videos and generic files. Attachments go through the
// homeserver media repository first (the SDK yields an mxc:// URL); this
// module only shapes the resulting m.room.message content.

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

/**
 * Build the encrypted-room message content for an uploaded attachment.
 * @param {{name: string, type?: string, size: number}} file
 * @param {string} mxcUrl mxc:// URL returned by the media repository
 * @param {{width?: number, height?: number, durationSec?: number}} [meta]
 * @returns {{msgtype: string, body: string, url: string, info: object}}
 */
export function attachmentContent(file, mxcUrl, meta = {}) {
  if (typeof mxcUrl !== 'string' || !mxcUrl.startsWith('mxc://')) {
    throw new TypeError('attachmentContent: mxc:// URL required');
  }
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
  return { msgtype, body: file.name, url: mxcUrl, info };
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
export function mergeTimelineEntry(timeline, entry, { atStart = false, chronological = false } = {}) {
  let result = 'appended';
  if (entry.eventId) {
    const index = timeline.findIndex((item) => item.eventId === entry.eventId);
    if (index >= 0) {
      timeline[index] = entry;
      result = 'replaced';
    }
  }
  // 이전 대화(scrollback)는 오래된 순서로 하나씩 앞에 붙는다 — 뒤가 아니라 앞에 넣는다.
  if (result !== 'replaced') {
    if (atStart) {
      timeline.unshift(entry);
      result = 'prepended';
    } else timeline.push(entry);
  }
  // SDK context lookup can return a missing ordinary message from the middle
  // of the conversation, not just an older page. Restore its original place.
  if (chronological && Number.isFinite(entry.ts)) {
    timeline.splice(timeline.indexOf(entry), 1);
    const index = timeline.findIndex((other) => Number.isFinite(other.ts) && other.ts > entry.ts);
    timeline.splice(index < 0 ? timeline.length : index, 0, entry);
  }
  // A heartbeat belongs at its last update's position, even after hydration,
  // scrollback or delayed decryption. Never use callback arrival time here.
  const progress = timeline.filter((item) => item.isProgress && Number.isFinite(item.ts));
  if (progress.length) {
    const messages = timeline.filter((item) => !progress.includes(item));
    for (const item of progress.sort((a, b) => a.ts - b.ts)) {
      const index = messages.findIndex((other) => Number.isFinite(other.ts) && other.ts > item.ts);
      messages.splice(index < 0 ? messages.length : index, 0, item);
    }
    timeline.splice(0, timeline.length, ...messages);
  }
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
