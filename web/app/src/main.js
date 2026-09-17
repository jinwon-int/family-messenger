// App bootstrap: storage wiring, login flow, room list, chat, sheets.

import { strings } from './strings.js';
import * as session from './session.js';
import { createFamilyClient, loginWithPassword, PlaintextRefusedError } from './matrix/client.js';
import { messageKind, humanFileSize, validateAttachment, attachmentContent, mergeTimelineEntry } from './messages.js';
import { extractMentions } from './mentions.js';
import { describeInvite } from './invites.js';
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
};

function renderCurrent() {
  if (!state.client) return;
  const current = state.currentRoomId ? state.rooms.get(state.currentRoomId) : null;
  ui.renderShell(root, {
    list: {
      summaries: state.summaries,
      syncState: state.syncState,
      onSelect: (room) => openRoom(room.roomId),
      onOpenVerification: openVerification,
      onOpenRecovery: openRecovery,
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

async function connect(creds) {
  state.myUserId = creds.userId;
  state.client = await createFamilyClient(creds);
  try {
    await state.client.enableEncryption();
  } catch (error) {
    console.error('rust crypto unavailable', error);
  }
  state.client.start((syncState) => {
    state.syncState = syncState === 'PREPARED' || syncState === 'SYNCING' ? 'live' : syncState === 'ERROR' ? 'error' : state.syncState;
    if (syncState === 'PREPARED' || syncState === 'ERROR') refreshSummaries();
  });
  state.client.onTimeline((event) => {
    if (event.getType() !== 'm.room.message') return;
    appendTimeline(event);
  });
  // 새 방이 보이면 목록·초대를 즉시 갱신한다(세션 중 도착한 초대 포함).
  state.client.onRoomAdded(() => refreshSummaries());
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

function appendTimeline(event) {
  const roomId = event.getRoomId?.();
  const entry0 = state.rooms.get(roomId);
  if (!entry0) return;
  // 복호화 재시도는 같은 event id로 다시 전달된다 — 자리표시를 본문으로 치환한다.
  mergeTimelineEntry(entry0.timeline, timelineEntry(event, entry0.summary));
  if (roomId === state.currentRoomId) renderCurrent();
}

function openRooms() {
  state.currentRoomId = null;
  refreshSummaries();
}

function openRoom(roomId) {
  state.currentRoomId = roomId;
  renderCurrent();
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

function openRecovery() {
  const close = ui.openRecoverySheet(root, {
    onClose: () => {
      close();
      renderCurrent();
    },
  });
}

function start() {
  loadConfig().then((config) => {
    state.config = config;
    renderCurrent();
  });
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
  ui.renderLogin(root, {
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
        await connect(fresh);
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
