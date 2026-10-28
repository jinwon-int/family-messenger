// 보관함 pane 「첨부」 탭(#544 D) — 패밀리챗 web/app attachments.js collectAttachments 이식.
// 이 브라우저의 화면 타임라인(방별 봉인 보관 ≤500건)에 있는 첨부를 모든 방에 걸쳐 최신순으로 편다.
// 한데 릴레이에는 서버 첨부 인덱스가 없다 — 보이는 범위는 지금 화면에 올라온 것뿐이다.
// 순수 모듈: DOM·네트워크 없음. entry 참조를 그대로 실어 보관함 행이 같은 load()(내려받기)를 쓴다.

/**
 * @param {Iterable<{roomId: string, entries: Array<object>}>} rooms  app.rooms 의 [roomId, R] 또는 {roomId, entries}
 * @param {{roomLabel?: (roomId: string) => string}} [opts]
 * @returns {Array<{key: string, roomId: string, roomName: string, seq: number|null, sender: string, senderName: string,
 *   isMe: boolean, size: number, fileName: string|null, image: boolean, ts: number|null, entry: object}>} 최신순
 */
export function collectAttachments(rooms, { roomLabel = (id) => id } = {}) {
  const out = [];
  for (const room of rooms ?? []) {
    const [roomId, R] = Array.isArray(room) ? room : [room?.roomId, room];
    if (!roomId || !R) continue;
    for (const entry of R.entries ?? []) {
      if (entry?.kind !== 'attachment') continue;
      out.push({
        key: entry.key, roomId, roomName: roomLabel(roomId),
        seq: Number.isSafeInteger(entry.seq) ? entry.seq : null,
        sender: entry.sender ?? '', senderName: entry.senderName ?? '', isMe: Boolean(entry.isMe),
        size: Number.isFinite(entry.size) ? entry.size : 0,
        fileName: typeof entry.fileName === 'string' && entry.fileName ? entry.fileName : null,
        image: Boolean(entry.image), ts: Number.isFinite(entry.ts) && entry.ts > 0 ? entry.ts : null,
        entry,
      });
    }
  }
  // 최신순: 시각 내림차순, 시각이 없으면 뒤로, 같은 시각은 seq 내림차순(같은 방 안에서 도착 순서의 역).
  return out.sort((a, b) => (b.ts ?? -1) - (a.ts ?? -1) || (b.seq ?? -1) - (a.seq ?? -1));
}

/** 보관함 행의 이름: 파일명이 있으면 그것, 없으면 사진/파일 라벨(사진은 내용 판별 결과). */
export function attachmentTitle(file, labels) {
  if (file.fileName) return file.fileName;
  return file.image ? labels.photo : labels.file;
}
