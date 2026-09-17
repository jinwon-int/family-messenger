// Attachment box: every photo/video/file the client has seen across rooms.
//
// Pure helpers only — no DOM, no network. Media bytes are fetched through
// ClientAdapter.fetchAttachment (authenticated media endpoint, spec v1.11),
// and end-to-end encrypted attachments (Element sends `content.file` with an
// AES-CTR key) are decrypted with matrix-encrypt-attachment.

const MXC_RE = /^mxc:\/\/([^/]+)\/([^/?#]+)$/;

/**
 * Shape an m.room.message content into an attachment record, or null when
 * the content is not an attachment we can fetch.
 * @param {object} content
 * @returns {{kind:'photo'|'video'|'file', name:string, mimetype:string, size:number|null,
 *           url:string, encrypted:null|{key:object, iv:string, hashes:object, v?:string}}|null}
 */
export function attachmentFromContent(content) {
  if (!content || typeof content !== 'object') return null;
  const kind = content.msgtype === 'm.image'
    ? 'photo'
    : content.msgtype === 'm.video'
      ? 'video'
      : content.msgtype === 'm.file' || content.msgtype === 'm.audio'
        ? 'file'
        : null;
  if (!kind) return null;
  const file = content.file && typeof content.file === 'object' && typeof content.file.url === 'string' ? content.file : null;
  const url = file ? file.url : content.url;
  if (typeof url !== 'string' || !MXC_RE.test(url)) return null;
  const info = content.info && typeof content.info === 'object' ? content.info : {};
  const encrypted = file && file.key && typeof file.iv === 'string' && file.hashes
    ? { key: file.key, iv: file.iv, hashes: file.hashes, ...(typeof file.v === 'string' ? { v: file.v } : {}) }
    : null;
  if (file && !encrypted) return null; // encrypted payload without usable key material
  return {
    kind,
    name: typeof content.body === 'string' && content.body.length > 0 ? content.body : 'file',
    mimetype: typeof info.mimetype === 'string' && info.mimetype ? info.mimetype : (typeof file?.mimetype === 'string' && file.mimetype ? file.mimetype : 'application/octet-stream'),
    size: Number.isFinite(info.size) ? info.size : null,
    url,
    encrypted,
  };
}

/**
 * Authenticated media download path (client-server v1.11) for an mxc URL.
 * @returns {string|null}
 */
export function mediaDownloadPath(mxcUrl) {
  const match = MXC_RE.exec(String(mxcUrl ?? ''));
  if (!match) return null;
  return `/_matrix/client/v1/media/download/${encodeURIComponent(match[1])}/${encodeURIComponent(match[2])}`;
}

/**
 * Flatten every room's timeline entries into one newest-first attachment list.
 * @param {Iterable<{summary:{roomId:string, displayName?:string}, timeline:Array<object>}>} rooms
 */
export function collectAttachments(rooms) {
  const out = [];
  for (const room of rooms ?? []) {
    const summary = room?.summary ?? {};
    for (const entry of room?.timeline ?? []) {
      if (!entry?.attachment) continue;
      out.push({
        ...entry.attachment,
        eventId: entry.eventId ?? null,
        roomId: summary.roomId ?? null,
        roomName: summary.displayName ?? '',
        sender: entry.name ?? '',
        ts: Number.isFinite(entry.ts) ? entry.ts : null,
      });
    }
  }
  return out.sort((a, b) => (b.ts ?? 0) - (a.ts ?? 0));
}

/**
 * Filebox iframe URL with a refresh counter, so "새로고침" re-navigates the
 * frame without reloading the app (same trick as the seo web bridge panel).
 */
export function fileboxRefreshUrl(base, refresh = 0) {
  const url = new URL(base);
  if (refresh > 0) url.searchParams.set('_files_refresh', String(refresh));
  return url.toString();
}
