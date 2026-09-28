// 안 읽음 판정과 읽음 확인(read receipt) 전송 판단 — DOM·SDK 없이 테스트하는 순수 로직.
//
// 기준 메시지는 대화 목록 미리보기와 같은 "마지막 표시 메시지"(화면 복사본 timeline의 끝)다.
// 상태 이벤트·수정 봉투·반응은 화면 복사본에 들어오지 않고, 삭제된 메시지는 빠지거나
// (진행 말풍선이면) held로 자리만 남으므로 건너뛴다. 읽음 여부는 SDK의 영수증 정보
// (Room.hasUserReadEvent)로 묻는다 — 서버 알림 수(unread_notifications)에 기대지 않는다.

/** 서버가 준 이벤트 ID인가(로컬 에코 '~…'는 아직 영수증을 받을 수 없다). */
function isServerEventId(eventId) {
  return typeof eventId === 'string' && eventId.startsWith('$');
}

/**
 * 안 읽음 판정·읽음 확인에 쓰는 마지막 표시 메시지. 삭제되어 자리만 남은 진행 말풍선(held)은 건너뛴다.
 * @param {Array<{eventId?: string|null, isMe?: boolean, held?: boolean}>|null|undefined} timeline
 */
export function latestDisplayedEntry(timeline) {
  if (!Array.isArray(timeline)) return null;
  for (let i = timeline.length - 1; i >= 0; i--) {
    const entry = timeline[i];
    if (entry && !entry.held) return entry;
  }
  return null;
}

/**
 * 방이 안 읽음인가. 마지막 표시 메시지가 남의 것이고, 내가 그것을 읽지 않았다고 SDK가 확답할 때만 true.
 * 내 메시지가 마지막이면 읽은 것이다(보냈다면 그 앞은 봤다). hasRead가 모른다(null)고 하면
 * 배지를 띄우지 않는다 — 지울 수 없는 거짓 배지보다 놓친 배지가 낫다.
 * @param {Array<object>|null|undefined} timeline 화면 복사본(main.js state.rooms[].timeline)
 * @param {(eventId: string) => boolean|null} hasRead
 */
export function isRoomUnread(timeline, hasRead) {
  const entry = latestDisplayedEntry(timeline);
  if (!entry || entry.isMe || !isServerEventId(entry.eventId)) return false;
  let read;
  try {
    read = hasRead(entry.eventId);
  } catch {
    return false;
  }
  return read === false;
}

/**
 * 지금 읽음 확인을 보낼 이벤트 ID(없으면 null). 방이 열려 있고, 문서가 보이며 포커스가 있고,
 * 타임라인이 맨 아래(최신 메시지가 화면에 보임)일 때만 보낸다. 내 메시지·로컬 에코·
 * 이미 보낸(또는 SDK가 이미 읽었다고 아는) 이벤트에는 다시 보내지 않는다 — SDK는 보낼 때
 * 로컬 에코 영수증을 남기므로 더 오래된 이벤트도 hasRead가 true가 된다.
 * @param {{roomId: string|null, timeline: Array<object>, visible: boolean, focused: boolean,
 *          atBottom: boolean, hasRead: (eventId: string) => boolean|null, lastSent?: string|null}} input
 */
export function readReceiptTarget({ roomId, timeline, visible, focused, atBottom, hasRead, lastSent = null }) {
  if (!roomId || !visible || !focused || !atBottom) return null;
  const entry = latestDisplayedEntry(timeline);
  if (!entry || entry.isMe || !isServerEventId(entry.eventId)) return null;
  if (entry.eventId === lastSent) return null;
  let read;
  try {
    read = hasRead(entry.eventId);
  } catch {
    read = null;
  }
  return read === true ? null : entry.eventId;
}

/**
 * 읽음 확인 전송기. 방별로 마지막으로 보낸 이벤트를 기억해 같은 이벤트를 두 번 보내지 않고,
 * 실패는 onError로 기록만 한다(재시도로 서버를 두드리지 않는다 — 다음 새 메시지에서 다시 보낸다).
 * @param {{send: (roomId: string, eventId: string) => Promise<unknown>|unknown, onError?: (error: unknown) => void}} opts
 */
export function createReadReceiptSender({ send, onError = () => {} }) {
  const sent = new Map(); // roomId -> eventId
  return {
    /** 조건이 맞으면 보내고 보낸 이벤트 ID를, 아니면 null을 돌려준다. 절대 throw하지 않는다. */
    maybeSend(input) {
      const eventId = readReceiptTarget({ ...input, lastSent: sent.get(input?.roomId) ?? null });
      if (!eventId) return null;
      sent.set(input.roomId, eventId);
      try {
        Promise.resolve(send(input.roomId, eventId)).catch(onError);
      } catch (error) {
        onError(error);
      }
      return eventId;
    },
    /** 로그아웃 등으로 계정이 바뀌면 기억을 비운다. */
    reset() {
      sent.clear();
    },
  };
}
