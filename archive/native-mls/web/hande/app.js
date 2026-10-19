// 한데 웹 — app state machine (iOS AppModel.Phase: starting → needsActor →
// needsEnrollment → ready / halted / fatal) wired to the screens in ui.js and one
// room session (room.js). Stage 2 of #431: one room (the configured default room);
// identity sharing across rooms is stage 4.
import * as ui from './ui.js';
import {strings, displayName, isAgentDevice} from './strings.js';
import {createWorkerBridge} from './worker-bridge.js';
import {createRelay} from './relay.js';
import {createIdentityStore, databaseFor, ROOM} from './identity.js';
import {createRoomSession, nextDeviceId, clock} from './room.js';

const DEFAULT_ROOM = 'family';
const IMAGE_SNIFF_MAX = 2 * 1024 * 1024;   // decode attachments up to this size eagerly for an inline preview

function imageType(bytes) {
  if (bytes.length < 12) return null;
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return 'image/png';
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
  if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x38) return 'image/gif';
  if (bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) return 'image/webp';
  return null;
}

async function loadConfig() {
  try {
    const r = await fetch('./config.json', {credentials: 'same-origin'});
    if (r.status !== 200) return {};
    const v = await r.json();
    return v && typeof v === 'object' ? v : {};
  } catch (_) { return {}; }
}

export function startApp(root, {storage = localStorage, fetch: fetchImpl = globalThis.fetch.bind(globalThis)} = {}) {
  const app = {
    phase: 'starting', message: strings.app.starting, error: null, fatal: null,
    actor: null, device: null, subject: null, room: DEFAULT_ROOM, session: null,
    entries: [], entryKeys: new Set(), images: new Map(), draft: '', sending: false,
    notice: null, listOpen: true, logs: [], unread: false, lastLine: '',
  };
  const identity = createIdentityStore({storage});
  const worker = createWorkerBridge();
  const relay = createRelay({fetch: fetchImpl, onOffline: down => { app.offlineAt = down ? clock() : null; render(); }});
  app.offlineAt = null;

  // ---- rendering (coalesced) ----
  // Every change may move the phase (the relay's 403 appears or disappears), so the
  // phase is re-derived right before each paint.
  let scheduled = false;
  function render() {
    if (scheduled) return;
    scheduled = true;
    queueMicrotask(() => { scheduled = false; updatePhase(); paint(); });
  }
  function paint() {
    const S = app.session?.state;
    if (app.phase === 'fatal') { ui.renderFatal(root, {title: strings.app.fatalTitle, detail: app.fatal, onRetry: () => location.reload(), onWipe: S ? wipeDevice : null}); return; }
    if (app.phase === 'needsActor') { ui.renderActorSetup(root, {onSubmit: chooseActor, error: app.error, busy: false}); return; }
    if (app.phase === 'starting' || !S) { ui.renderStarting(root, {message: app.message}); return; }
    if (app.phase === 'enroll') {
      const reg = app.session.registration(app.subject);
      ui.renderEnroll(root, {deviceId: app.device, actor: app.actor, fingerprint: S.fingerprint, subject: app.subject,
        registrationJson: JSON.stringify(reg, null, 1), waiting: S.waiting403, lastCheckedAt: S.syncedAt,
        onCopy: () => copy(JSON.stringify(reg, null, 1)), onCheck: () => app.session.sync({quiet: true}).then(render),
        onOpenApprove: null, onWipe: confirmWipe, error: app.error});
      return;
    }
    const halted = S.halted ? {...S.halted} : null;
    const roomState = halted ? 'halted' : S.joined ? 'joined' : 'pending';
    const last = app.entries.filter(e => e.kind === 'text' || e.kind === 'attachment').at(-1);
    const list = {
      rooms: [{roomId: app.room, name: app.room, emoji: halted ? '🪵' : '🔥',
        preview: last ? `${last.senderName}: ${last.kind === 'attachment' ? strings.chat?.attachmentImage ?? '사진' : last.body}` : (S.joined ? strings.rooms?.noMessages ?? '' : strings.room.notJoined),
        time: last?.ts ? ui.formatTime?.(last.ts) ?? '' : '', unread: app.unread && !app.roomOpen, state: roomState,
        hasAgent: S.roster.some(isAgentDevice), members: S.roster.length}],
      currentRoomId: app.roomOpen ? app.room : null,
      onSelect: () => { app.roomOpen = true; app.unread = false; render(); },
      onOpenMenu: openMenu, onOpenJoin: openJoin, onOpenCreate: openCreate,
      sync: {lastSyncAt: S.syncedAt, offlineSince: app.offlineAt, reconnecting: relay.offline},
      notice: app.notice, deviceLabel: app.device,
    };
    const room = app.roomOpen ? {
      roomId: app.room, name: app.room, members: S.roster.slice(), joined: S.joined, halted,
      timeline: app.entries, draft: app.draft, onSend: sendText, onAttach: sendAttachment, onOpenAttachment: e => e.load(),
      onBack: () => { app.roomOpen = false; render(); }, onOpenInvite: openInvite, onOpenMembers: openInvite,
      onDraft: text => { app.draft = text; }, notice: app.roomNotice, sending: app.sending || S.transferring,
      attachmentPending: app.session.attachmentPending ? {size: 0, onRetry: () => sendAttachment(null)} : null,
    } : null;
    ui.renderShell(root, {list, room});
  }
  const status = (text, tone = 'info') => ui.setStatus(root, text, tone);
  async function copy(text) {
    try { await navigator.clipboard.writeText(text); status(strings.app.copied, 'ok'); }
    catch (_) { status(strings.app.copyFailed, 'warn'); }
  }

  // ---- timeline ----
  function addEntry(m) {
    const key = m.key ?? (m.seq !== null && m.seq !== undefined ? `seq-${m.seq}` : `sys-${app.entries.length}`);
    if (app.entryKeys.has(key)) return;
    app.entryKeys.add(key);
    const entry = {key, kind: m.kind, seq: m.seq ?? null, sender: m.sender ?? '', senderName: m.sender ? displayName(m.sender) : '',
      isMe: m.sender === app.device, isAgent: m.sender ? isAgentDevice(m.sender) : false, body: m.text ?? '', ts: m.ts ?? null,
      size: m.size ?? 0, image: null, replay: !!m.replay, load: m.load ?? null};
    app.entries.push(entry);
    app.entries.sort((a, b) => (a.seq ?? Infinity) - (b.seq ?? Infinity) || 0);
    if (!entry.isMe && (entry.kind === 'text' || entry.kind === 'attachment') && !app.roomOpen) app.unread = true;
    if (entry.kind === 'attachment' && entry.load && entry.size <= IMAGE_SNIFF_MAX) {
      entry.load().then(bytes => {
        const type = imageType(bytes);
        if (!type) return;
        entry.image = {url: URL.createObjectURL(new Blob([bytes], {type})), alt: `${entry.senderName}의 사진`};
        render();
      }).catch(() => {});
    }
    render();
  }

  // ---- phases ----
  async function boot() {
    if (!globalThis.Worker || !globalThis.WebAssembly || !globalThis.indexedDB) { fatal(strings.app.workerUnavailable); return; }
    const config = await loadConfig();
    if (typeof config.defaultRoom === 'string' && ROOM.test(config.defaultRoom)) app.room = config.defaultRoom;
    const id = identity.read();
    if (!id) { app.phase = 'needsActor'; render(); return; }
    await startSession(id);
  }
  function fatal(detail) { app.phase = 'fatal'; app.fatal = detail; render(); }
  async function chooseActor(actor) {
    try {
      const id = identity.choose(actor.trim());
      app.error = null;
      await startSession(id);
    } catch (error) { app.error = strings.actor?.invalid ?? error.message; render(); }
  }
  function newSession(id) {
    return createRoomSession({room: app.room, device: id.device, database: databaseFor(app.room), worker, relay, storage, on: {
      change: render,
      message: addEntry,
      log: line => { app.logs.push(line); if (app.logs.length > 500) app.logs.shift(); console.debug('[hande]', line); },
      notice: (text, tone) => status(text, tone),
      synced: () => render(),
    }});
  }
  async function startSession(id) {
    app.actor = id.actor; app.device = id.device;
    app.phase = 'starting'; app.message = strings.app.deriving; render();
    relay.me().then(subject => { app.subject = subject; render(); }).catch(() => {});
    try {
      let session = newSession(id);
      let opened = await session.open(identity.passphrase());
      if (opened.wiped) {
        // The store is new but this browser used it before (#290): the chain never
        // re-accepts the old id with a new fingerprint — start as a new device id.
        await session.wipe();
        const rotated = identity.rotate();
        status(strings.room.freshStore(rotated.device), 'warn');
        app.actor = rotated.actor; app.device = rotated.device;
        session = newSession(rotated);
        opened = await session.open(identity.passphrase());
      }
      app.session = session;
      app.roomOpen = window.matchMedia?.('(min-width: 900px)').matches ?? true;
      await session.activate();
      updatePhase();
    } catch (error) {
      fatal(/worker|boot/.test(error.message) ? strings.app.workerUnavailable : strings.app.storageUnavailable(error.message));
    }
  }
  function updatePhase() {
    const S = app.session?.state;
    if (!S || !S.started) return;
    const next = S.waiting403 ? 'enroll' : (S.syncedAt || relay.offline) ? 'ready' : 'starting';
    if (next === 'starting') app.message = strings.app.starting;
    app.phase = next;
  }

  // ---- actions ----
  async function guard(run, {keepStatus = false} = {}) {
    try { return await run(); }
    catch (error) { if (!keepStatus) status(error.message, 'danger'); throw error; }
  }
  async function sendText(text) {
    if (app.sending) return false;
    app.sending = true; render();
    try { await app.session.send(text); app.draft = ''; app.unread = false; return true; }
    catch (error) { status(error.message, 'danger'); return false; }
    finally { app.sending = false; render(); }
  }
  async function sendAttachment(file) {
    try {
      const result = await app.session.sendAttachment(file);
      status(strings.room.attachmentSent(result.seq, result.size), 'ok');
    } catch (error) { status(error.message, 'danger'); render(); }
  }
  function openMenu() {
    ui.openMenuSheet(root, {items: [
      {label: strings.menu?.settings ?? '설정', run: openSettings},
      {label: strings.menu?.invite ?? '기기 초대 · 멤버', run: openInvite},
      {label: strings.menu?.approve ?? '신뢰 기기 승인', run: openApprove},
      {label: strings.menu?.sync ?? '지금 동기화', run: () => app.session.sync().then(render)},
      {label: strings.menu?.wipe ?? '이 기기 지우기', run: confirmWipe, tone: 'danger'},
    ], onClose: () => {}});
  }
  function openSettings() {
    const reg = JSON.stringify(app.session.registration(app.subject), null, 1);
    ui.openSettingsSheet(root, {deviceId: app.device, actor: app.actor, fingerprint: app.session.state.fingerprint, subject: app.subject,
      origin: location.host, onCopyRegistration: () => copy(reg), onOpenApprove: openApprove, onWipe: confirmWipe, onClose: () => {}});
  }
  function openJoin() {
    ui.openJoinSheet(root, {defaultRoom: app.room, busy: false, message: null, onClose: () => {}, onSubmit: async roomId => {
      if (roomId !== app.room) throw new Error(strings.rooms?.singleRoomOnly ?? `이 버전은 기본 대화방(${app.room})만 지원합니다 — 다른 대화방은 후속(#431 4단계)`);
      await guard(() => app.session.publishKeyPackage());
      status(strings.room.keyPackagePublished, 'ok');
    }});
  }
  function openCreate() {
    ui.openCreateSheet(root, {defaultRoom: app.room, busy: false, message: null, onClose: () => {}, onSubmit: async roomId => {
      if (roomId !== app.room) throw new Error(strings.rooms?.singleRoomOnly ?? `이 버전은 기본 대화방(${app.room})만 지원합니다 — 다른 대화방은 후속(#431 4단계)`);
      await guard(() => app.session.create());
      status(strings.room.created, 'ok');
    }});
  }
  function openInvite() {
    ui.openInviteSheet(root, {roomId: app.room, members: app.session.state.roster.slice(), busy: false, message: null, onClose: () => {},
      onInvite: async target => { await guard(() => app.session.invite(target)); status(strings.room.inviteDone(target), 'ok'); },
      onRemove: async target => { await guard(() => app.session.remove(target)); status(strings.room.removeDone(target), 'ok'); }});
  }
  function openApprove() {
    ui.openApproveSheet(root, {onOffer: json => app.session.offerCandidate(json), onApprove: () => app.session.approveCandidate(),
      onClose: () => app.session.denyCandidate()});
  }
  function confirmWipe() {
    ui.openConfirmSheet(root, {title: strings.wipe?.title ?? '이 기기 지우기', body: strings.wipe?.warning ?? '', confirmLabel: strings.wipe?.confirm ?? '지우기', tone: 'danger',
      onConfirm: wipeDevice, onClose: () => {}});
  }
  async function wipeDevice() {
    try {
      const next = nextDeviceId(app.device);
      await app.session.wipe();
      identity.rotate(); identity.forgetPassphrase();
      app.entries = []; app.entryKeys = new Set();
      status(strings.room.wipeDone(next), 'warn');
      setTimeout(() => location.reload(), 1500);
    } catch (error) { status(error.message, 'danger'); }
  }

  window.addEventListener('beforeunload', () => { for (const e of app.entries) if (e.image) URL.revokeObjectURL(e.image.url); });
  boot().catch(error => fatal(error.message));
  return {get state() { return app; }};
}
