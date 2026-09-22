// App bootstrap: storage wiring, login flow, room list, chat, sheets.

import { strings } from './strings.js';
import * as session from './session.js';
import { createFamilyClient, loginWithPassword, PlaintextRefusedError } from './matrix/client.js';
import { messageKind, humanFileSize, validateAttachment, attachmentContent, mergeTimelineEntry, formattedMessageBody } from './messages.js';
import { extractMentions } from './mentions.js';
import { describeInvite } from './invites.js';
import { lastMessagePreview, listSignature, sortByActivity } from './rooms.js';
import { viewKeyAction, listPageMove, isSplitLayout, listPageNavAction } from './keyboard.js';
import { splitParticipants, shortHandle } from './participants.js';
import { attachmentFromContent, collectAttachments, fileboxRefreshUrl } from './attachments.js';
import { PhotoPreviews } from './photo-previews.js';
import { applyTypingEvent, createTypingState, pruneTyping, typingIndicator, typingNames } from './typing.js';
import { DEFAULT_CONFIG, loadConfig } from './config.js';
import { disablePush, enablePush, hasMatchingPusher, isIosDevice, pushAvailability, readSubscription } from './push.js';
import * as ui from './ui.js';

const root = document.getElementById('app');

// iOS Safari '모든 쿠키 차단' 등에서 storage 프로퍼티 접근 자체가 throw한다 —
// 모듈 전체가 죽어 빈 화면이 되는 것을 막는다(세션 지속만 포기).
function safeStorage(candidate, label) {
  try {
    const probe = candidate.getItem('__probe__');
    void probe;
    return candidate;
  } catch (error) {
    console.warn(label + ' unavailable, using in-memory shim', error?.name);
    const map = new Map();
    return {
      getItem: (key) => (map.has(key) ? map.get(key) : null),
      setItem: (key, value) => map.set(key, String(value)),
      removeItem: (key) => map.delete(key),
      clear: () => map.clear(),
    };
  }
}

const stores = {
  persistent: safeStorage(window.localStorage, 'localStorage'),
  volatile: safeStorage(window.sessionStorage, 'sessionStorage'),
};

const state = {
  client: null,
  myUserId: null,
  summaries: [],
  invites: [],
  aiConsentRooms: new Set(), // 방별 AI 동의 — 세션 안에서만 유지한다
  rooms: new Map(), // roomId -> {summary, timeline: []}
  currentRoomId: null,
  listFocusIndex: -1, // 대화목록 Page Up/Page Down 포커스 위치 — 목록이 다시 그려져도 유지한다
  listFocusRoomId: null,
  syncState: 'idle',
  config: DEFAULT_CONFIG,
  box: { open: false, tab: 'attachments', refresh: 0 }, // 보관함 pane
  cryptoError: null, // 암호화 모듈(rust crypto) 초기화 실패 배너
  typing: createTypingState(), // roomId -> Map(userId -> {name, ts}) — 방 헤더 "입력중.."
};

const photoPreviews = new PhotoPreviews({
  fetchPhoto: (attachment, options) => state.client.fetchAttachment(attachment, options),
  onChange: () => renderCurrent(),
});

function renderCurrent() {
  if (!state.client) return;
  const current = state.currentRoomId ? state.rooms.get(state.currentRoomId) : null;
  photoPreviews.sync(current?.summary.roomId ?? null, current?.timeline.map((entry) => entry.attachment) ?? []);
  ui.renderShell(root, {
    list: {
      summaries: listSummaries(),
      syncState: state.syncState,
      banner: state.cryptoError,
      onSelect: (room, event) => openRoom(room.roomId, {
        keyboard: event?.detail === 0,
        touch: event?.pointerType === 'touch',
      }),
      onOpenVerification: openVerification,
      onOpenRecovery: openRecovery,
      onOpenMenu: openMenu,
      invites: state.invites.map((i) => i.view),
      inviteHandlers: {
        isAiConsentAcknowledged: (invite) => state.aiConsentRooms.has(invite.roomId),
        onAiConsentChange: (invite, checked) => {
          if (checked) state.aiConsentRooms.add(invite.roomId);
          else state.aiConsentRooms.delete(invite.roomId);
          renderCurrent();
        },
        onAccept: (invite) => respondInvite(invite, 'join'),
        onDecline: (invite) => respondInvite(invite, 'decline'),
      },
    },
    room: current
      ? {
          room: current.summary,
          timeline: current.timeline,
          notice: current.notice,
          hasMore: current.hasMore !== false,
          loadingEarlier: current.loadingEarlier === true,
          onLoadEarlier: () => loadEarlier(state.currentRoomId),
          onBack: openRooms,
          onSend: (text) => sendText(text),
          onAttach: (file) => sendAttachment(file),
          photoPreviews,
          onOpenAttachment: openAttachment,
          onTyping: (hasText) => handleComposerTyping(state.currentRoomId, hasText),
          typing: typingIndicator(typingNames(state.typing, current.summary.roomId, { myUserId: state.myUserId }), strings.chat.typing),
        }
      : null,
    box: {
      open: state.box.open,
      tab: state.config.filebox ? state.box.tab : 'attachments',
      attachments: collectAttachments(state.rooms.values()),
      filebox: state.config.filebox
        ? {
            url: fileboxRefreshUrl(state.config.filebox.url, state.box.refresh),
            homeUrl: state.config.filebox.url,
            title: state.config.filebox.title ?? strings.box.tabFilebox,
          }
        : null,
      onToggle: () => {
        state.box.open = !state.box.open;
        renderCurrent();
      },
      onTab: (tab) => {
        state.box.tab = tab;
        renderCurrent();
      },
      onRefresh: () => {
        state.box.refresh += 1;
        renderCurrent();
      },
      onOpen: (attachment) => openAttachment(attachment),
    },
  });
  restoreRoomListFocus();
}

const PREVIEW_LABELS = () => ({ photo: strings.media.photo, video: strings.media.video, file: strings.media.file, undecryptable: strings.chat.decryptFailedShort });
const TIME_LABELS = () => ({ justNow: strings.rooms.justNow, minutesAgo: strings.rooms.minutesAgo, hoursAgo: strings.rooms.hoursAgo, yesterday: strings.rooms.yesterday });

/** Room summaries decorated with the last message preview + typing label, newest activity first. */
function listSummaries() {
  const decorated = state.summaries.map((summary) => {
    // Array.prototype.at은 ES2022다. 빌드 타깃이 es2020이고 esbuild는 메서드를
    // 폴리필하지 않아 구형 모바일에서 TypeError가 난다(빈 화면 사고와 같은 종류).
    const timeline = state.rooms.get(summary.roomId)?.timeline;
    const entry = timeline && timeline.length > 0 ? timeline[timeline.length - 1] : null;
    const preview = lastMessagePreview(entry, PREVIEW_LABELS());
    return {
      ...summary,
      lastMessage: preview ? { ...preview, ts: entry.ts ?? null, eventId: entry.eventId ?? null } : null,
      // 목록에서도 이름 옆 "입력중.." — 내 입력은 제외된다(typingNames).
      typing: typingIndicator(typingNames(state.typing, summary.roomId, { myUserId: state.myUserId }), strings.chat.typing),
    };
  });
  return sortByActivity(decorated);
}

// 목록은 이벤트가 올 때 즉시 갱신되지만, 상대 시간 라벨("3분 전")과 놓친 변화를 위해
// 2초마다 서명을 비교해 실제로 달라졌을 때만 다시 그린다(초안·스크롤 보존은 renderShell 몫).
let listTicker = null;
let lastListSignature = '';
function startListTicker() {
  if (listTicker) return;
  listTicker = setInterval(() => {
    if (!state.client) return;
    // 만료된 타이핑 표시를 걷는다 — 연결이 끊긴 사이 남은 표시가 헤더·목록에 고착하지 않게.
    const prunedRooms = pruneTyping(state.typing);
    const signature = listSignature(listSummaries(), Date.now(), TIME_LABELS());
    if (signature === lastListSignature && prunedRooms.length === 0) return;
    lastListSignature = signature;
    renderCurrent();
  }, 2000);
}

async function openAttachment(attachment) {
  try {
    ui.setStatus(root, strings.box.loading);
    const blob = await state.client.fetchAttachment(attachment);
    ui.setStatus(root, null);
    const objectUrl = URL.createObjectURL(blob);
    if (attachment.kind === 'photo') {
      ui.openPreviewSheet(root, { name: attachment.name, src: objectUrl, onClose: () => URL.revokeObjectURL(objectUrl) });
      return;
    }
    const link = document.createElement('a');
    link.href = objectUrl;
    link.download = attachment.name;
    link.rel = 'noopener';
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(objectUrl), 60_000);
  } catch (error) {
    console.error('attachment open failed', error);
    ui.setStatus(root, strings.box.downloadFailed, 'error');
  }
}

/** The rust store belongs to another (previous) device of this account. */
function isStoreMismatch(error) {
  return /account in the store doesn't match/i.test(String(error?.message ?? error ?? ''));
}

/** IndexedDB left half-deleted or with a stale schema (NotFoundError on object stores, VersionError). */
function isBrokenStore(error) {
  const text = String(error?.message ?? error ?? '');
  return /object stores? was not found|NotFoundError|VersionError/i.test(text) || error?.name === 'NotFoundError' || error?.name === 'VersionError';
}

async function enableEncryptionWithRecovery(client, { fresh }) {
  // 저장소 이름이 계정+기기별이라(client.cryptoDatabasePrefix) 새 로그인은 항상 빈 저장소를 연다 —
  // 로그인 시 삭제하지 않는다(삭제는 다른 탭이 잡고 있으면 blocked돼 반쯤 지워진 DB를 남겼다:
  // NotFoundError "object stores was not found", 2026-09-17 실기기).
  void fresh;
  try {
    await client.enableEncryption();
    return null;
  } catch (error) {
    console.error('rust crypto unavailable', error);
    // 같은 이름의 저장소가 깨져 있거나(반쯤 지워진 DB) 다른 계정 것이면 이 기기 이름의 저장소만 비우고 한 번 재시도한다.
    if (isStoreMismatch(error) || isBrokenStore(error)) {
      try {
        await client.resetLocalStores();
        await client.enableEncryption();
        return null;
      } catch (retryError) {
        console.error('rust crypto unavailable after store reset', retryError);
        return retryError;
      }
    }
    return error;
  }
}

async function connect(creds, { fresh = false } = {}) {
  state.myUserId = creds.userId;
  state.client = await createFamilyClient(creds);
  state.cryptoError = null;
  const cryptoFailure = await enableEncryptionWithRecovery(state.client, { fresh });
  if (!cryptoFailure) {
    // 이 브라우저에 이 기기의 암호화 저장소가 실제로 생겼다 — 다음 로그인에서만 기기 ID를 재사용한다.
    session.saveSession({ cryptoDeviceId: creds.deviceId }, stores);
  }
  if (cryptoFailure) {
    // 콘솔에만 남기면 이후 모든 전송이 조용히 실패하는 이유를 가족이 알 수 없다(#126) — 화면에 상시 배너 + 원인.
    const detail = String(cryptoFailure?.message ?? cryptoFailure).slice(0, 160);
    state.cryptoError = `${strings.errors.cryptoUnavailable} (${detail})`;
  }
  // 리스너를 start보다 먼저 건다 — 초기 sync의 Room.timeline을 놓치지 않기 위해.
  state.client.onTimeline((event, meta) => {
    if (event.getType() !== 'm.room.message') return;
    appendTimeline(event, meta?.atStart === true);
  });
  // 새 방이 보이면 목록·초대를 즉시 갱신한다(세션 중 도착한 초대 포함).
  state.client.onRoomAdded(() => refreshSummaries());
  // 다른 사람의 입력 중 상태(m.typing)가 바뀌면 방 헤더와 목록 표시를 갱신한다.
  state.client.onTyping((info) => {
    if (!applyTypingEvent(state.typing, info)) return;
    renderCurrent();
  });
  state.client.onTimelineReset?.((roomId) => {
    const entry = state.rooms.get(roomId);
    if (!entry) return;
    entry.timeline = [];
    hydrateFromSdk(roomId);
    if (roomId === state.currentRoomId) renderCurrent();
  });
  // 내 다른 기기(휴대폰 앱 등)가 이 기기 검증을 요청하면 수락 시트를 연다.
  state.client.onVerificationRequest((request) => openIncomingVerification(request));
  state.client.start((syncState) => {
    state.syncState = syncState === 'PREPARED' || syncState === 'SYNCING' ? 'live' : syncState === 'ERROR' ? 'error' : state.syncState;
    if (syncState === 'PREPARED' || syncState === 'ERROR') refreshSummaries();
    if (syncState === 'PREPARED') {
      // 초기 sync 이벤트가 방 Map보다 먼저 오면 appendTimeline이 버려
      // 최신이 빠진 채 scrollback만 남는 방이 생긴다 — SDK live timeline으로 채운다.
      for (const roomId of state.rooms.keys()) hydrateFromSdk(roomId);
      renderCurrent();
      backfillPreviews();
    }
  });
  startListTicker();
  installKeyboardShortcuts();
  installRoomListKeyboardNav();
  openRooms();
  resumePush();
}

/**
 * 이미 알림을 허용한 기기에서만 pusher를 조용히 다시 등록한다.
 *
 * **권한을 여기서 요청하지 않는다.** 로그인 직후 팝업을 띄우면 거절당했을 때
 * 회복이 어렵다(#167 C — 설정의 명시적 토글로 켠다). 여기가 필요한 이유는 따로
 * 있다: pusher는 홈서버의 계정에 붙고 구독은 브라우저에 붙는데, 홈서버가 pushkey를
 * 정리했거나(구독 만료 후 재구독) 다른 계정으로 로그인하면 둘이 어긋난다.
 * 로그인할 때마다 다시 등록하면 그 어긋남이 한 번의 로그인으로 낫는다.
 */
async function resumePush() {
  if (!state.config.push) return;
  if (typeof Notification === 'undefined' || Notification.permission !== 'granted') return;
  // ⚠ 사용자가 껐으면 되살리지 않는다. disablePush는 브라우저 권한을 취소할 수
  //    없어서(JS로 불가) 끈 뒤에도 permission은 granted로 남는다. 권한만 보고
  //    재등록하면 끄기 버튼이 새로고침 한 번에 무효가 된다.
  if (session.readPushPreference(stores) === 'off') return;
  if (!('serviceWorker' in navigator)) return;
  try {
    const registration = await serviceWorkerReady();
    if (!registration) return;
    await enablePush({
      registration,
      push: state.config.push,
      client: state.client,
      userId: state.myUserId,
      deviceDisplayName: state.client.deviceId() ?? undefined,
      permission: Notification.permission,
    });
  } catch (error) {
    // 알림이 없다고 채팅을 막지 않는다. 원인은 콘솔에만 남긴다.
    console.error('push registration failed', error);
  }
}

// 방 화면 키보드 단축키: 대화형 요소 밖 Enter=작성창 커서, Home=방 목록.
// 시트(verification/recovery)가 열려 있으면 가로채지 않는다 — 시트 Esc는 자체 닫기.
// 대화목록 Page Up/Page Down 탐색: 방 항목(.room-item) 사이에서 포커스를 옮긴다(roving focus).
// 2분할(목록|대화)에서는 옮긴 방을 오른쪽에 바로 미리 보고, Enter가 작성창으로 커서를 보낸다.
// 작성창에서 다시 Page Up/Down이면 목록 탐색으로 돌아간다(대화는 그대로).
// Enter 열기는 포커스된 버튼의 원래 동작이라 여기서 가로채지 않는다.
// 시트(<dialog open>)가 열려 있으면 끓어쓰지 않는다.
const EDITABLE_TAGS = new Set(['INPUT', 'TEXTAREA', 'SELECT']);

function splitLayout() {
  return isSplitLayout((query) => window.matchMedia(query));
}

function listRoomButtons() {
  return Array.from(root.querySelectorAll('.pane-list .room-item'));
}

function currentListIndex(buttons) {
  const focused = buttons.indexOf(document.activeElement);
  if (focused >= 0) return focused;
  const id = state.listFocusRoomId || state.currentRoomId;
  return id ? buttons.findIndex((button) => button.dataset.roomId === id) : -1;
}

function restoreRoomListFocus({ force = false } = {}) {
  if (state.listFocusIndex < 0) return;
  const shell = root.querySelector('main.shell');
  if (!shell) return;
  const split = splitLayout();
  const listVisible = shell.dataset.view === 'list' || (split && shell.dataset.view === 'room');
  if (!listVisible) return;
  // 단일 pane 방 화면에서는 목록이 숨겨져 있으니 포커스를 되살리지 않는다.
  if (!split && state.currentRoomId) return;
  if (root.querySelector('dialog[open]')) return;
  // 2초 갱신이 목록을 갈아끊우면 포커스가 body로 떨어진다 — 그 때만 되살린다.
  if (!force && document.activeElement && document.activeElement !== document.body) return;
  const buttons = listRoomButtons();
  if (!buttons.length) { state.listFocusIndex = -1; return; }
  const remembered = buttons.findIndex((button) => button.dataset.roomId === state.listFocusRoomId);
  const index = remembered >= 0 ? remembered : Math.min(state.listFocusIndex, buttons.length - 1);
  state.listFocusIndex = index;
  state.listFocusRoomId = buttons[index].dataset.roomId;
  buttons[index].focus({ preventScroll: true });
}

function installRoomListKeyboardNav() {
  document.addEventListener('keydown', (event) => {
    if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return;
    const shell = root.querySelector('main.shell');
    if (!shell) return;
    if (root.querySelector('dialog[open]')) return;
    const target = event.target;
    const composerFocused = Boolean(target && (target.isContentEditable === true || EDITABLE_TAGS.has(target.tagName)));
    const action = listPageNavAction({
      key: event.key,
      split: splitLayout(),
      view: shell.dataset.view,
      composerFocused,
    });
    if (!action) return;
    const buttons = listRoomButtons();
    const next = listPageMove({ key: event.key, count: buttons.length, currentIndex: currentListIndex(buttons) });
    if (next === null) return;
    event.preventDefault(); // 화면 스크롤 대신 목록 이동으로 쓴다
    state.listFocusIndex = next;
    state.listFocusRoomId = buttons[next].dataset.roomId;
    if (action === 'preview') {
      openRoom(buttons[next].dataset.roomId, { preview: true });
      restoreRoomListFocus({ force: true });
      return;
    }
    buttons[next].focus();
  });
}

function installKeyboardShortcuts() {
  document.addEventListener('keydown', (event) => {
    if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return;
    if (!state.currentRoomId) return;
    if (root.querySelector('dialog[open]')) return;
    const action = viewKeyAction({ key: event.key, target: event.target });
    if (!action) return;
    if (action === 'back') {
      event.preventDefault();
      openRooms();
      return;
    }
    const input = root.querySelector('.composer textarea[name=body]');
    if (input && document.activeElement !== input) {
      event.preventDefault();
      input.focus();
    }
  });
}

function refreshSummaries() {
  state.summaries = state.client.roomSummaries();
  state.invites = state.client.inviteSummaries().map((summary) => ({ summary, view: describeInvite(summary) }));
  const known = new Set([...state.summaries, ...state.invites.map((i) => i.summary)].map((s) => s.roomId));
  for (const roomId of state.aiConsentRooms) {
    if (!known.has(roomId)) state.aiConsentRooms.delete(roomId);
  }
  for (const summary of state.summaries) {
    const existing = state.rooms.get(summary.roomId);
    if (existing) existing.summary = summary;
    else state.rooms.set(summary.roomId, { summary, timeline: [], notice: null });
  }
  renderCurrent();
}

async function respondInvite(invite, action) {
  try {
    if (action === 'join') await state.client.joinRoom(invite.roomId);
    else await state.client.declineInvite(invite.roomId);
    state.aiConsentRooms.delete(invite.roomId);
    refreshSummaries();
  } catch (error) {
    console.error('invite action failed', error);
    ui.setStatus(root, strings.invite.failed, 'error');
  }
}

function sameUser(a, b) {
  return typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
}

function agentUserIds(summary) {
  return new Set(summary.agents.map((a) => a.userId));
}

function timelineEntry(event, summary) {
  const content = event.getContent?.() ?? {};
  const undecryptable = typeof event.isDecryptionFailure === 'function' && event.isDecryptionFailure();
  const kind = undecryptable ? 'undecryptable' : messageKind(content);
  const sender = event.sender ?? {};
  const { agents } = splitParticipants([sender], { agentUserIds: agentUserIds(summary) });
  const meta = !undecryptable && content.info?.size ? humanFileSize(content.info.size) : null;
  return {
    attachment: undecryptable ? null : attachmentFromContent(content),
    eventId: event.getId?.() ?? null,
    userId: event.getSender?.(),
    name: shortHandle(sender.name ?? event.getSender?.()),
    isAgent: agents.length > 0,
    isMe: sameUser(event.getSender?.(), state.myUserId),
    kind: kind === 'unknown' ? 'file' : kind,
    formattedBody: undecryptable ? null : formattedMessageBody(content),
    ts: typeof event.getTs === 'function' ? event.getTs() : null,
    body: undecryptable
      ? strings.chat.decryptFailed
      : typeof content.body === 'string'
        ? content.body
        : strings.chat.unreadable,
    meta,
  };
}

function ensureRoomEntry(roomId) {
  let entry = state.rooms.get(roomId);
  if (entry) return entry;
  entry = { summary: { roomId, displayName: roomId, kind: 'other', memberCount: 0, agents: [] }, timeline: [], notice: null };
  state.rooms.set(roomId, entry);
  return entry;
}

function appendTimeline(event, atStart = false) {
  const roomId = event.getRoomId?.();
  if (!roomId) return;
  // 초기 sync는 방 목록 갱신보다 Room.timeline이 먼저 올 수 있다 — 버리면 최신이 빠진다.
  const entry0 = ensureRoomEntry(roomId);
  // 복호화 재시도는 같은 event id로 다시 전달된다 — 자리표시를 본문으로 치환한다.
  mergeTimelineEntry(entry0.timeline, timelineEntry(event, entry0.summary), { atStart });
  if (roomId === state.currentRoomId) renderCurrent();
}

/** SDK live timeline에 있는데 화면 복사본에 없는 메시지(놓친 초기 sync)를 채운다. */
function hydrateFromSdk(roomId) {
  if (!state.client || typeof state.client.liveTimelineEvents !== 'function') return;
  const entry = state.rooms.get(roomId);
  if (!entry) return;
  const events = state.client.liveTimelineEvents(roomId);
  if (!Array.isArray(events) || events.length === 0) return;
  for (const event of events) {
    if (event.getType?.() === 'm.room.message') {
      mergeTimelineEntry(entry.timeline, timelineEntry(event, entry.summary));
      continue;
    }
    if (typeof event.isEncrypted === 'function' && event.isEncrypted() && typeof event.once === 'function') {
      event.once('Event.decrypted', () => {
        if (event.getType?.() === 'm.room.message') appendTimeline(event, false);
      });
    }
  }
}

const EARLIER_PAGE = 30;
const OPEN_MIN_MESSAGES = 15;

/** Pull one older page for a room; guarded so only one request runs per room. */
async function loadEarlier(roomId, limit = EARLIER_PAGE) {
  const entry = state.rooms.get(roomId);
  if (!entry || entry.loadingEarlier || entry.hasMore === false) return 0;
  entry.loadingEarlier = true;
  if (roomId === state.currentRoomId) renderCurrent();
  let added = 0;
  try {
    added = await state.client.loadEarlier(roomId, limit);
    entry.hasMore = added > 0 && state.client.canLoadEarlier(roomId);
  } catch (error) {
    console.error('load earlier failed', error);
  } finally {
    entry.loadingEarlier = false;
  }
  if (roomId === state.currentRoomId) renderCurrent();
  return added;
}

// 동기화 직후 미리보기(마지막 메시지)가 없는 방은 한 페이지씩 조용히 채운다(목록 미리보기·보관함용).
let backfillStarted = false;
async function backfillPreviews() {
  if (backfillStarted) return;
  backfillStarted = true;
  const targets = [...state.rooms.entries()].filter(([, entry]) => entry.timeline.length === 0).slice(0, 12);
  for (const [roomId] of targets) {
    await loadEarlier(roomId, 20);
    renderCurrent();
  }
}

function saveRoomDraft() {
  const entry = state.rooms.get(state.currentRoomId);
  const input = root.querySelector('.composer textarea[name=body]');
  if (entry && input) entry.draft = input.value;
}

function openRooms() {
  const returning = Boolean(state.currentRoomId);
  saveRoomDraft();
  if (returning) {
    state.listFocusRoomId = state.currentRoomId;
    state.listFocusIndex = Math.max(0, listRoomButtons().findIndex((button) => button.dataset.roomId === state.currentRoomId));
  }
  stopTyping(state.currentRoomId);
  state.currentRoomId = null;
  state.box.open = false;
  refreshSummaries();
  if (returning) restoreRoomListFocus({ force: true });
}

function openRoom(roomId, { keyboard = false, touch = false, preview = false } = {}) {
  saveRoomDraft();
  if (state.currentRoomId && state.currentRoomId !== roomId) stopTyping(state.currentRoomId);
  state.currentRoomId = roomId;
  state.listFocusRoomId = roomId;
  state.listFocusIndex = Math.max(0, listRoomButtons().findIndex((button) => button.dataset.roomId === roomId));
  state.box.open = false;
  const entry = state.rooms.get(roomId);
  if (entry && entry.hasMore === undefined) entry.hasMore = state.client.canLoadEarlier(roomId);
  hydrateFromSdk(roomId);
  renderCurrent();
  // 방을 열었는데 보이는 메시지가 적으면 이전 페이지를 한 번 자동으로 채운다.
  if (entry && entry.timeline.length < OPEN_MIN_MESSAGES && entry.hasMore !== false) loadEarlier(roomId);
  const input = root.querySelector('.composer textarea[name=body]');
  if (input && entry?.draft != null) {
    input.value = entry.draft;
    input.dispatchEvent(new Event('input', { bubbles: true }));
  }
  // 2분할 미리보기는 작성창에 커서를 두지 않는다 — Enter가 작성, Page Up/Down이 목록 탐색.
  if (preview) return;
  // 키보드로 선택하면 터치 기기의 외장 키보드에서도 바로 작성한다.
  // 터치 탭은 화면 키보드를 자동으로 띄우지 않는다.
  if (keyboard || (!touch && window.matchMedia('(pointer: fine)').matches)) {
    input?.focus();
  }
}

// --- 입력 중 표시 전송: 작성창 활동을 m.typing으로 변환한다 ---
// 홈서버는 timeout 후 스스로 만료시키므로(기본 30초), 계속 입력하면 만료 전에 재알림하고
// 뜸하거나 전송·방 전환하면 즉시 끈다. 실패는 조용히 무시한다(표시 기능일 뿐이다).
const TYPING_TIMEOUT_MS = 30_000; // 홈서버에 요청하는 유지 창
const TYPING_REFRESH_MS = 20_000; // 계속 입력 중일 때 재알림 주기(만료 전)
const TYPING_IDLE_MS = 6_000;     // 입력이 뜸하면 끄기까지의 대기
let typingActive = false;
let typingSentAt = 0;
let typingIdleTimer = null;

async function pushTyping(roomId, isTyping) {
  try {
    await state.client?.sendTyping(roomId, isTyping, TYPING_TIMEOUT_MS);
  } catch (error) {
    console.warn('typing send failed', error);
  }
}

/** Stop announcing typing for a room (and remember nothing across rooms). */
function stopTyping(roomId) {
  if (typingIdleTimer) {
    clearTimeout(typingIdleTimer);
    typingIdleTimer = null;
  }
  if (!typingActive) return;
  typingActive = false;
  if (roomId) void pushTyping(roomId, false);
}

/** Composer activity from ui: hasText = the textarea has content. */
function handleComposerTyping(roomId, hasText) {
  if (!state.client || !roomId || roomId !== state.currentRoomId) return;
  if (!hasText) {
    stopTyping(roomId);
    return;
  }
  const now = Date.now();
  if (!typingActive || now - typingSentAt >= TYPING_REFRESH_MS) {
    typingActive = true;
    typingSentAt = now;
    void pushTyping(roomId, true);
  }
  if (typingIdleTimer) clearTimeout(typingIdleTimer);
  typingIdleTimer = setTimeout(() => stopTyping(roomId), TYPING_IDLE_MS);
}

async function sendText(text) {
  const entry = state.rooms.get(state.currentRoomId);
  const roomId = state.currentRoomId;
  try {
    const handles = state.client.roomMemberHandles(roomId);
    await state.client.sendText(roomId, text, extractMentions(text, handles));
    stopTyping(roomId);
  } catch (error) {
    if (error instanceof PlaintextRefusedError) {
      entry.notice = strings.errors.plaintextRefused;
    } else {
      entry.notice = strings.chat.sendFailed;
    }
    renderCurrent();
  }
}

async function sendAttachment(file) {
  const check = validateAttachment(file);
  const entry = state.rooms.get(state.currentRoomId);
  if (!check.ok) {
    entry.notice = check.reason === 'too-large' ? strings.media.tooLarge : strings.media.unsupported;
    renderCurrent();
    return;
  }
  try {
    const data = await file.arrayBuffer();
    const upload = await state.client.uploadMedia(file, data);
    const mxcUrl = typeof upload === 'string' ? upload : upload.content_uri;
    await state.client.sendAttachment(
      state.currentRoomId,
      attachmentContent({ name: file.name, type: file.type, size: file.size }, mxcUrl),
    );
  } catch (error) {
    entry.notice = error instanceof PlaintextRefusedError ? strings.errors.plaintextRefused : strings.chat.sendFailed;
    renderCurrent();
  }
}

function openVerification() {
  const close = ui.openVerificationSheet(root, {
    driver: (callbacks) => state.client.startEmojiVerification(callbacks),
    onClose: () => {
      close();
      renderCurrent();
    },
  });
}

function openIncomingVerification(request) {
  if (root.querySelector('dialog[open]')) return; // 시트가 이미 떠 있으면 겹치지 않는다
  const close = ui.openVerificationSheet(root, {
    incoming: true,
    driver: (callbacks) => state.client.acceptEmojiVerification(request, callbacks),
    onClose: () => {
      close();
      renderCurrent();
    },
  });
}

function openMenu() {
  ui.openMenuSheet(root, {
    items: [
      { label: strings.verification.title, onClick: openVerification },
      { label: strings.recovery.title, onClick: openRecovery },
      { label: strings.notifications.title, onClick: openNotifications },
      { label: strings.account.devicesTitle, onClick: openDevices },
      { label: strings.account.logout, onClick: logout, danger: true },
    ],
    // 메뉴가 닫힐 때 재렌더하지 않는다 — 닫힘(close) 이벤트가 비동기라 항목이 연 시트를 지웠다.
  });
}

// navigator.serviceWorker.ready는 등록이 없으면 **거부되지 않고 영원히 pending**이다.
// 등록은 best-effort라(아래 register().catch) 실패해 있을 수 있고, 그러면 "알림 켜기"가
// "처리 중…"에서 영영 안 돌아온다. 상한을 두고 null로 끝낸다.
const SERVICE_WORKER_READY_TIMEOUT_MS = 5000;

async function serviceWorkerReady() {
  if (!('serviceWorker' in navigator)) return null;
  let timer;
  try {
    return await Promise.race([
      navigator.serviceWorker.ready,
      new Promise((resolve) => { timer = setTimeout(() => resolve(null), SERVICE_WORKER_READY_TIMEOUT_MS); }),
    ]);
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** 지금 이 브라우저의 푸시 상태. 판단은 push.js의 순수 함수가 한다. */
async function readPushAvailability() {
  const hasServiceWorker = 'serviceWorker' in navigator;
  let subscribed = false;
  if (hasServiceWorker && state.config.push) {
    try {
      const registration = await navigator.serviceWorker.getRegistration();
      const subscription = await registration?.pushManager?.getSubscription();
      const parsed = readSubscription(subscription);
      // ⚠ 구독이 있다고 "켜짐"이라 하면 안 된다. 홈서버에 pusher가 없으면
      //    알림은 오지 않는데 화면만 켜졌다고 말한다. 양쪽을 다 본다.
      //    조회에 실패하면 "꺼짐"으로 본다 — 다시 켜기는 멱등이라 값싸고,
      //    "켜졌는데 안 온다"는 상태보다 진단이 쉽다.
      subscribed = parsed ? hasMatchingPusher(await state.client.getPushers(), parsed.p256dh, state.config.push.appId) : false;
    } catch {
      subscribed = false;
    }
  }
  return pushAvailability({
    push: state.config.push,
    hasServiceWorker,
    hasPushManager: typeof PushManager !== 'undefined',
    hasNotification: typeof Notification !== 'undefined',
    permission: typeof Notification !== 'undefined' ? Notification.permission : 'default',
    subscribed,
    isIos: isIosDevice({ userAgent: navigator.userAgent, maxTouchPoints: navigator.maxTouchPoints }),
    // 홈화면 앱인가. iOS Safari는 navigator.standalone, 그 밖은 display-mode로 본다.
    isStandalone: navigator.standalone === true || window.matchMedia?.('(display-mode: standalone)').matches === true,
  });
}

function openNotifications() {
  ui.openNotificationsSheet(root, {
    load: readPushAvailability,
    enable: async () => {
      // ⚠ requestPermission을 클릭 핸들러의 **첫 await**로 둔다. 다른 비동기
      //    작업을 먼저 기다리면 사용자 제스처가 끊겨 브라우저가 요청을 무시한다.
      //    (tests/ui_bindings.test.js의 정적 가드가 이 순서를 지킨다.)
      const permission = await Notification.requestPermission();
      if (permission !== 'granted') return { ok: false, reason: 'no-permission' };
      const registration = await serviceWorkerReady();
      if (!registration) return { ok: false, reason: 'unsupported' };
      const result = await enablePush({
        registration,
        push: state.config.push,
        client: state.client,
        userId: state.myUserId,
        deviceDisplayName: state.client?.deviceId() ?? undefined,
        permission,
      });
      if (result.ok) session.savePushPreference('on', stores);
      return result;
    },
    disable: async () => {
      // 선호를 먼저 적는다. 해제가 중간에 실패해도 다음 로그인에서 다시 켜지지
      // 않아야 한다 — 사용자는 분명히 끄겠다고 눌렀다.
      session.savePushPreference('off', stores);
      const registration = await navigator.serviceWorker.getRegistration();
      if (!registration) return { ok: true, removed: false, unsubscribed: false };
      return disablePush({ registration, push: state.config.push, client: state.client });
    },
  });
}

function openDevices() {
  ui.openDevicesSheet(root, {
    load: () => state.client.listDevices(),
    remove: (ids, password) => state.client.deleteDevices(ids, { password }),
    onClose: () => renderCurrent(),
  });
}

// 로그아웃이 푸시 정리를 기다리다 멈추지 않게 하는 상한. 홈서버 HTTP와 푸시
// 서비스 네트워크를 둘 다 타는데, SDK에 localTimeoutMs를 주지 않아 클라이언트
// 타임아웃이 없다. try/catch는 **거부만** 잡고 지연은 못 잡는다.
const PUSH_CLEANUP_TIMEOUT_MS = 3000;

/** 로그아웃 전 pusher 해제. 실패도 지연도 로그아웃을 막지 못한다. */
async function removePushForLogout(client) {
  if (!state.config.push || !('serviceWorker' in navigator)) return;
  const cleanup = (async () => {
    const registration = await navigator.serviceWorker.getRegistration();
    if (!registration) return;
    await disablePush({ registration, push: state.config.push, client });
  })();
  let timer;
  try {
    await Promise.race([
      cleanup,
      new Promise((resolve) => { timer = setTimeout(resolve, PUSH_CLEANUP_TIMEOUT_MS); }),
    ]);
  } catch (error) {
    console.error('push removal failed', error);
  } finally {
    clearTimeout(timer);
  }
  // 상한에 걸려 정리가 아직 돌고 있어도 로그아웃은 진행한다. 남은 pusher는 다음
  // 발송에서 404/410을 받아 sygnal이 reject하고 홈서버가 지운다.
  cleanup.catch(() => {});
}

async function logout() {
  if (!window.confirm(strings.account.logoutConfirm)) return;
  const client = state.client;
  try {
    ui.setStatus(root, strings.login.submitting);
    if (listTicker) {
      clearInterval(listTicker);
      listTicker = null;
    }
    // ⚠ logout()보다 **먼저** 지운다. 토큰이 사라진 뒤에는 pusher를 못 지우고,
    //   그러면 이 기기를 떠난 뒤에도 알림이 계속 간다(#126). 실패해도 로그아웃은
    //   진행한다 — 남은 pusher는 다음 발송에서 410을 받아 홈서버가 정리한다.
    await removePushForLogout(client);
    await client.logout();
  } catch (error) {
    console.error('logout failed', error);
    ui.setStatus(root, strings.account.logoutFailed, 'error');
    return;
  }
  session.clearSession(stores);
  photoPreviews.clear();
  state.client = null;
  state.myUserId = null;
  state.summaries = [];
  state.invites = [];
  state.rooms = new Map();
  state.currentRoomId = null;
  state.listFocusIndex = -1;
  state.listFocusRoomId = null;
  state.syncState = 'idle';
  state.box = { open: false, tab: 'attachments', refresh: 0 };
  state.cryptoError = null;
  stopTyping(null);
  state.typing = createTypingState();
  renderLogin();
}

function openRecovery() {
  const close = ui.openRecoverySheet(root, {
    onClose: () => {
      close();
      renderCurrent();
    },
  });
}

async function start() {
  // 설정(기본 홈서버 주소·파일보관함)은 같은 오리진의 작은 파일이라 로그인 화면 전에 기다린다.
  state.config = await loadConfig();
  const stored = session.readSession(stores);
  if (session.hasLiveSession(stored)) {
    connect(stored).catch((error) => {
      console.error(error);
      renderLogin();
    });
    return;
  }
  renderLogin();
}

function renderLogin(previousError) {
  const stored = session.readSession(stores);
  const localpart = typeof stored?.userId === 'string' && stored.userId.startsWith('@') ? stored.userId.slice(1).split(':')[0] : '';
  ui.renderLogin(root, {
    defaults: {
      homeserverUrl: stored?.homeserverUrl || state.config.homeserverUrl || '',
      user: localpart,
    },
    onSubmit: async ({ homeserverUrl, user, password }) => {
      try {
        ui.setStatus(root, strings.login.submitting);
        // 같은 계정이 같은 브라우저에서 다시 로그인하고, 그 기기의 암호화 저장소가 이 브라우저에 남아 있을 때만
        // 기존 기기 ID를 재사용한다. 저장소가 없는데 ID만 재사용하면 옛 ID에 새 키가 올라가 다른 기기의
        // 검증이 키 불일치로 취소된다(2026-09-18). 다른 계정이거나 저장소가 없으면 새 기기.
        const sameUser = Boolean(stored?.deviceId) && (user === localpart || user === stored?.userId)
          && stored.cryptoDeviceId === stored.deviceId;
        const creds = await loginWithPassword({
          homeserverUrl,
          user,
          password,
          deviceId: sameUser ? stored.deviceId : undefined,
          deviceDisplayName: strings.login.deviceName,
        });
        const fresh = {
          homeserverUrl,
          userId: creds.user_id,
          accessToken: creds.access_token,
          deviceId: creds.device_id,
        };
        session.saveSession(fresh, stores);
        await connect(fresh, { fresh: true });
      } catch (error) {
        console.error(error);
        ui.setStatus(root, strings.login.error, 'error');
      }
    },
  });
  if (previousError) ui.setStatus(root, previousError, 'error');
}

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js').catch(() => {
      /* installable PWA is best-effort; the app works without it */
    });
  });
  // 알림을 누르면 서비스워커가 이 메시지를 보낸다. 앱에 URL 라우팅이 없어
  // (방 선택은 메모리 상태) 딥링크 대신 메시지로 방을 연다.
  navigator.serviceWorker.addEventListener('message', (event) => {
    if (event?.data?.type !== 'familychat:open-room') return;
    const roomId = event.data.roomId;
    // 아직 모르는 방(초대만 와 있거나 첫 sync 전)이면 목록을 연다 — 조용히 무시하면
    // 알림을 눌렀는데 아무 일도 안 일어난 것처럼 보인다.
    if (typeof roomId !== 'string' || !state.rooms.has(roomId)) {
      openRooms();
      return;
    }
    openRoom(roomId);
  });
  // ⚠ ServiceWorkerContainer의 메시지 큐는 **초기에 비활성**이다. onmessage를
  //    설정하거나 startMessages()를 부를 때까지 메시지가 큐에 쌓인 채 전달되지
  //    않는다. addEventListener만 쓰면 위 리스너가 영원히 안 불린다 —
  //    즉 알림 클릭 라우팅이 통째로 죽는다.
  navigator.serviceWorker.startMessages?.();
}

start();
