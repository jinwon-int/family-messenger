// App bootstrap: storage wiring, login flow, room list, chat, sheets.

import { strings } from './strings.js';
import * as session from './session.js';
import { createFamilyClient, loginWithPassword, PlaintextRefusedError } from './matrix/client.js';
import { messageKind, humanFileSize, validateAttachment, attachmentContent } from './messages.js';
import { extractMentions } from './mentions.js';
import { splitParticipants } from './participants.js';
import * as ui from './ui.js';

const root = document.getElementById('app');
const stores = { persistent: window.localStorage, volatile: window.sessionStorage };

const state = {
  client: null,
  myUserId: null,
  summaries: [],
  rooms: new Map(), // roomId -> {summary, timeline: []}
  currentRoomId: null,
  syncState: 'idle',
};

function renderCurrent() {
  if (!state.client) return;
  const current = state.currentRoomId ? state.rooms.get(state.currentRoomId) : null;
  if (current) {
    ui.renderRoom(root, {
      room: current.summary,
      timeline: current.timeline,
      notice: current.notice,
      onBack: openRooms,
      onSend: (text) => sendText(text),
      onAttach: (file) => sendAttachment(file),
    });
  } else {
    ui.renderRoomList(root, {
      summaries: state.summaries,
      syncState: state.syncState,
      onSelect: (room) => openRoom(room.roomId),
      onOpenVerification: openVerification,
      onOpenRecovery: openRecovery,
    });
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
  openRooms();
}

function refreshSummaries() {
  state.summaries = state.client.roomSummaries();
  for (const summary of state.summaries) {
    const existing = state.rooms.get(summary.roomId);
    if (existing) existing.summary = summary;
    else state.rooms.set(summary.roomId, { summary, timeline: [], notice: null });
  }
  renderCurrent();
}

function agentUserIds(summary) {
  return new Set(summary.agents.map((a) => a.userId));
}

function timelineEntry(event, summary) {
  const content = event.getContent?.() ?? {};
  const kind = messageKind(content);
  const sender = event.sender ?? {};
  const { agents } = splitParticipants([sender], { agentUserIds: agentUserIds(summary) });
  const meta = content.info?.size ? humanFileSize(content.info.size) : null;
  return {
    userId: event.getSender?.(),
    name: sender.name ?? event.getSender?.(),
    isAgent: agents.length > 0,
    isMe: event.getSender?.() === state.myUserId,
    kind: kind === 'unknown' ? 'file' : kind,
    body: typeof content.body === 'string' && kind !== 'unknown' && kind !== 'file'
      ? content.body
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
  entry0.timeline.push(timelineEntry(event, entry0.summary));
  if (roomId === state.currentRoomId) renderCurrent();
}

function openRooms() {
  state.currentRoomId = null;
  refreshSummaries();
}

function openRoom(roomId) {
  state.currentRoomId = roomId;
  renderCurrent();
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

function openRecovery() {
  const close = ui.openRecoverySheet(root, {
    onClose: () => {
      close();
      renderCurrent();
    },
  });
}

function start() {
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
