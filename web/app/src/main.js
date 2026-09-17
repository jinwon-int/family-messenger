// App bootstrap: storage wiring, login flow, room list, chat, sheets.

import { strings } from './strings.js';
import * as session from './session.js';
import { createFamilyClient, loginWithPassword, PlaintextRefusedError } from './matrix/client.js';
import { messageKind, humanFileSize, validateAttachment, attachmentContent, mergeTimelineEntry } from './messages.js';
import { extractMentions } from './mentions.js';
import { describeInvite } from './invites.js';
import { lastMessagePreview, listSignature, sortByActivity } from './rooms.js';
import { viewKeyAction } from './keyboard.js';
import { splitParticipants, shortHandle } from './participants.js';
import { attachmentFromContent, collectAttachments, fileboxRefreshUrl } from './attachments.js';
import { DEFAULT_CONFIG, loadConfig } from './config.js';
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
  syncState: 'idle',
  config: DEFAULT_CONFIG,
  box: { open: false, tab: 'attachments', refresh: 0 }, // 보관함 pane
  cryptoError: null, // 암호화 모듈(rust crypto) 초기화 실패 배너
};

function renderCurrent() {
  if (!state.client) return;
  const current = state.currentRoomId ? state.rooms.get(state.currentRoomId) : null;
  ui.renderShell(root, {
    list: {
      summaries: listSummaries(),
      syncState: state.syncState,
      banner: state.cryptoError,
      onSelect: (room) => openRoom(room.roomId),
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
}

const PREVIEW_LABELS = () => ({ photo: strings.media.photo, video: strings.media.video, file: strings.media.file, undecryptable: strings.chat.decryptFailedShort });
const TIME_LABELS = () => ({ justNow: strings.rooms.justNow, minutesAgo: strings.rooms.minutesAgo, hoursAgo: strings.rooms.hoursAgo, yesterday: strings.rooms.yesterday });

/** Room summaries decorated with the last message preview, newest activity first. */
function listSummaries() {
  const decorated = state.summaries.map((summary) => {
    const entry = state.rooms.get(summary.roomId)?.timeline.at(-1) ?? null;
    const preview = lastMessagePreview(entry, PREVIEW_LABELS());
    return { ...summary, lastMessage: preview ? { ...preview, ts: entry.ts ?? null, eventId: entry.eventId ?? null } : null };
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
    const signature = listSignature(listSummaries(), Date.now(), TIME_LABELS());
    if (signature === lastListSignature) return;
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

async function enableEncryptionWithRecovery(client, { fresh }) {
  // 새 로그인은 항상 새 기기 ID를 받으므로 이전 기기의 IndexedDB 암호화 저장소는 쓸 수 없다 —
  // 그대로 두면 initRustCrypto가 "the account in the store doesn't match …"로 거부한다
  // (2026-09-17 실기기: 같은 브라우저 재로그인 후 배너). 먼저 비운다.
  if (fresh) {
    try {
      await client.resetLocalStores();
    } catch (error) {
      console.warn('store reset before first crypto init failed', error);
    }
  }
  try {
    await client.enableEncryption();
    return null;
  } catch (error) {
    console.error('rust crypto unavailable', error);
    // 복원된 세션은 기기가 같아 저장소에 방 키가 있을 수 있으니, 불일치 오류일 때만 비우고 한 번 재시도한다.
    if (!fresh && isStoreMismatch(error)) {
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
  if (cryptoFailure) {
    // 콘솔에만 남기면 이후 모든 전송이 조용히 실패하는 이유를 가족이 알 수 없다(#126) — 화면에 상시 배너 + 원인.
    const detail = String(cryptoFailure?.message ?? cryptoFailure).slice(0, 160);
    state.cryptoError = `${strings.errors.cryptoUnavailable} (${detail})`;
  }
  state.client.start((syncState) => {
    state.syncState = syncState === 'PREPARED' || syncState === 'SYNCING' ? 'live' : syncState === 'ERROR' ? 'error' : state.syncState;
    if (syncState === 'PREPARED' || syncState === 'ERROR') refreshSummaries();
    if (syncState === 'PREPARED') backfillPreviews();
  });
  state.client.onTimeline((event, meta) => {
    if (event.getType() !== 'm.room.message') return;
    appendTimeline(event, meta?.atStart === true);
  });
  // 새 방이 보이면 목록·초대를 즉시 갱신한다(세션 중 도착한 초대 포함).
  state.client.onRoomAdded(() => refreshSummaries());
  startListTicker();
  // 내 다른 기기(휴대폰 앱 등)가 이 기기 검증을 요청하면 수락 시트를 연다.
  state.client.onVerificationRequest((request) => openIncomingVerification(request));
  installKeyboardShortcuts();
  openRooms();
}

// 방 화면 키보드 단축키: 대화형 요소 밖 Enter=작성창 커서, Esc=방 목록.
// 시트(verification/recovery)가 열려 있으면 가로채지 않는다 — 시트 Esc는 자체 닫기.
function installKeyboardShortcuts() {
  document.addEventListener('keydown', (event) => {
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
    ts: typeof event.getTs === 'function' ? event.getTs() : null,
    body: undecryptable
      ? strings.chat.decryptFailed
      : typeof content.body === 'string'
        ? content.body
        : strings.chat.unreadable,
    meta,
  };
}

function appendTimeline(event, atStart = false) {
  const roomId = event.getRoomId?.();
  const entry0 = state.rooms.get(roomId);
  if (!entry0) return;
  // 복호화 재시도는 같은 event id로 다시 전달된다 — 자리표시를 본문으로 치환한다.
  mergeTimelineEntry(entry0.timeline, timelineEntry(event, entry0.summary), { atStart });
  if (roomId === state.currentRoomId) renderCurrent();
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

function openRooms() {
  state.currentRoomId = null;
  refreshSummaries();
}

function openRoom(roomId) {
  state.currentRoomId = roomId;
  const entry = state.rooms.get(roomId);
  if (entry && entry.hasMore === undefined) entry.hasMore = state.client.canLoadEarlier(roomId);
  renderCurrent();
  // 방을 열었는데 보이는 메시지가 적으면 이전 페이지를 한 번 자동으로 채운다.
  if (entry && entry.timeline.length < OPEN_MIN_MESSAGES && entry.hasMore !== false) loadEarlier(roomId);
  // 포인터가 정밀한(데스크톱) 환경에서는 방을 열면 바로 입력 가능하게 한다.
  // 모바일은 자동 포커스가 키보드를 띄워 방해가 되므로 제외.
  if (window.matchMedia('(pointer: fine)').matches) {
    root.querySelector('.composer textarea[name=body]')?.focus();
  }
}

async function sendText(text) {
  const entry = state.rooms.get(state.currentRoomId);
  try {
    const handles = state.client.roomMemberHandles(state.currentRoomId);
    await state.client.sendText(state.currentRoomId, text, extractMentions(text, handles));
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
      { label: strings.account.devicesTitle, onClick: openDevices },
      { label: strings.account.logout, onClick: logout, danger: true },
    ],
    onClose: () => renderCurrent(),
  });
}

function openDevices() {
  ui.openDevicesSheet(root, {
    load: () => state.client.listDevices(),
    remove: (ids, password) => state.client.deleteDevices(ids, { password }),
    onClose: () => renderCurrent(),
  });
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
    await client.logout();
  } catch (error) {
    console.error('logout failed', error);
    ui.setStatus(root, strings.account.logoutFailed, 'error');
    return;
  }
  session.clearSession(stores);
  state.client = null;
  state.myUserId = null;
  state.summaries = [];
  state.invites = [];
  state.rooms = new Map();
  state.currentRoomId = null;
  state.syncState = 'idle';
  state.box = { open: false, tab: 'attachments', refresh: 0 };
  state.cryptoError = null;
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
        const creds = await loginWithPassword({ homeserverUrl, user, password });
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
}

start();
