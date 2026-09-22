// Decrypted photo URLs live only for the selected room. Never persist bytes or keys.
const keyOf = (attachment) => JSON.stringify(attachment);

export class PhotoPreviews {
  constructor({ fetchPhoto, onChange, createUrl = (blob) => URL.createObjectURL(blob), revokeUrl = (url) => URL.revokeObjectURL(url) }) {
    Object.assign(this, { fetchPhoto, onChange, createUrl, revokeUrl });
    this.entries = new Map();
    this.roomId = null;
    this.active = 0;
  }

  sync(roomId, attachments) {
    if (roomId !== this.roomId) this.clear();
    this.roomId = roomId;
    const photos = attachments.filter((attachment) => attachment?.kind === 'photo');
    const wanted = new Set(photos.map(keyOf));
    for (const [key, entry] of this.entries) {
      if (!wanted.has(key)) this.remove(key, entry);
    }
    for (const attachment of photos) {
      const key = keyOf(attachment);
      if (!this.entries.has(key)) this.entries.set(key, { attachment, status: 'queued' });
    }
    this.pump();
  }

  get(attachment) { return this.entries.get(keyOf(attachment)); }

  retry(attachment) {
    const entry = this.get(attachment);
    if (entry?.status !== 'error') return;
    entry.status = 'queued';
    this.pump();
    this.onChange();
  }

  fail(attachment) {
    const entry = this.get(attachment);
    if (entry?.status !== 'ready') return;
    this.revokeUrl(entry.src);
    delete entry.src;
    entry.status = 'error';
    this.onChange();
  }

  remove(key, entry) {
    this.entries.delete(key);
    entry.controller?.abort();
    if (entry.src) this.revokeUrl(entry.src);
  }

  clear() {
    for (const [key, entry] of this.entries) this.remove(key, entry);
    this.roomId = null;
  }

  pump() {
    for (const [key, entry] of this.entries) {
      if (this.active >= 3) break;
      if (entry.status !== 'queued') continue;
      entry.status = 'loading';
      entry.controller = new AbortController();
      this.active += 1;
      // Promise boundary also catches a synchronous fetchPhoto failure.
      Promise.resolve().then(() => {
        if (this.entries.get(key) !== entry) return null;
        return this.fetchPhoto(entry.attachment, { signal: entry.controller.signal });
      }).then((blob) => {
        if (this.entries.get(key) !== entry) return;
        entry.src = this.createUrl(blob);
        entry.status = 'ready';
      }).catch(() => {
        if (this.entries.get(key) === entry) entry.status = 'error';
      }).finally(() => {
        this.active -= 1;
        this.pump();
        if (this.entries.get(key) === entry) this.onChange();
      });
    }
  }
}
