// 한데 웹 — app state machine (iOS AppModel.Phase: starting → needsActor →
// needsEnrollment → ready / halted / fatal) wired to the screens in ui.js.
// Stage 4 (#431): one device identity (device.js, worker multi-store mode) and any
// number of rooms (room.js, one session per room) — the rooms the relay lists for
// this device, rooms created or requested here, and rooms a lobby Welcome opens
// (owner actors join automatically, family devices accept with one tap — iOS
// AppModel.discoverLobbyWelcomes / acceptInvite).
import * as ui from './ui.js';
import {strings, displayName, isAgentDevice} from './strings.js';
import {createWorkerBridge} from './worker-bridge.js';
import {createRelay} from './relay.js';
import {createIdentityStore, databaseFor, ROOM, IDENTITY_DATABASE} from './identity.js';
import {createRoomSession, nextDeviceId, clock} from './room.js';
import {createDevice, LOBBY_TARGET} from './device.js';

const DEFAULT_ROOM = 'family';
const AUTO_JOIN_ACTORS = new Set(['owner']);   // iOS AppModel.autoJoinActors
const IMAGE_SNIFF_MAX = 2 * 1024 * 1024;   // decode attachments up to this size eagerly for an inline preview
const TICK_MS = 8000;                       // device-level refresh (rooms list, lobby welcomes, replenish)

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
    actor: null, device: null, subject: null, defaultRoom: DEFAULT_ROOM, dev: null,
    rooms: new Map(),          // roomId → {session, entries, entryKeys, unread, order}
    current: null, roomOpen: false, draft: new Map(), sending: false,
    invites: [], adoptFailed: new Map(), dismissed: new Set(), lobbyDue: true,
    notice: null, logs: [], offlineAt: null, tick: null,
  };
  const identity = createIdentityStore({storage});
  const worker = createWorkerBridge();
  const relay = createRelay({fetch: fetchImpl, onOffline: down => { app.offlineAt = down ? clock() : null; render(); }});
  const knownKey = () => `hande:rooms:${app.device}`;
  const readKnown = () => { try { const v = JSON.parse(storage.getItem(knownKey()) || '[]'); return Array.isArray(v) ? v.filter(r => ROOM.test(r)) : []; } catch (_) { return []; } };
  const writeKnown = () => storage.setItem(knownKey(), JSON.stringify([...app.rooms.keys()]));
  const markerKey = () => `hande:fresh-marker:${IDENTITY_DATABASE}`;
  const logLine = line => { app.logs.push(`${clock(true)} ${line}`); if (app.logs.length > 500) app.logs.shift(); console.debug('[hande]', line); };

  // ---- rendering (coalesced); the phase is re-derived right before each paint ----
  let scheduled = false;
  function render() {
    if (scheduled) return;
    scheduled = true;
    queueMicrotask(() => { scheduled = false; updatePhase(); paint(); });
  }
  function updatePhase() {
    if (app.phase === 'fatal' || app.phase === 'needsActor' || !app.dev?.state.started) return;
    const enrolled = app.dev.state.enrolled;
    app.phase = enrolled === false ? 'enroll' : (enrolled === true || relay.offline) ? 'ready' : 'starting';
    if (app.phase === 'starting') app.message = strings.app.starting;
  }
  const status = (text, tone = 'info') => ui.setStatus(root, text, tone);
  async function copy(text) {
    try { await navigator.clipboard.writeText(text); status(strings.app.copied, 'ok'); }
    catch (_) { status(strings.app.copyFailed, 'warn'); }
  }
  function roomRow(roomId) {
    const R = app.rooms.get(roomId), S = R.session.state;
    const halted = S.halted ? {...S.halted} : null;
    const last = R.entries.filter(e => e.kind === 'text' || e.kind === 'attachment').at(-1);
    return {roomId, name: roomId, emoji: halted ? '🪵' : '🔥',
      preview: last ? `${last.senderName}: ${last.kind === 'attachment' ? '사진' : last.body}` : (S.joined ? strings.rooms.noMessages : strings.room.notJoined),
      time: last?.ts ? ui.formatTime?.(last.ts) ?? '' : '', unread: R.unread && !(app.roomOpen && app.current === roomId),
      state: halted ? 'halted' : S.joined ? 'joined' : 'pending', hasAgent: S.roster.some(isAgentDevice), members: S.roster.length, order: R.order};
  }
  function paint() {
    const D = app.dev?.state;
    if (app.phase === 'fatal') { ui.renderFatal(root, {title: strings.app.fatalTitle, detail: app.fatal, onRetry: () => location.reload(), onWipe: D ? confirmWipe : null}); return; }
    if (app.phase === 'needsActor') { ui.renderActorSetup(root, {onSubmit: chooseActor, error: app.error, busy: false}); return; }
    if (app.phase === 'starting' || !D) { ui.renderStarting(root, {message: app.message}); return; }
    if (app.phase === 'enroll') {
      const reg = app.dev.registration(app.subject);
      ui.renderEnroll(root, {deviceId: app.device, actor: app.actor, fingerprint: D.fingerprint, subject: app.subject,
        registrationJson: JSON.stringify(reg, null, 1), waiting: true, lastCheckedAt: app.lastCheckedAt ?? null,
        onCopy: () => copy(JSON.stringify(reg, null, 1)), onCheck: () => refresh().then(render),
        onOpenApprove: null, onWipe: confirmWipe, error: app.error});
      return;
    }
    const rows = [...app.rooms.keys()].map(roomRow).sort((a, b) => a.order - b.order);
    const anySynced = [...app.rooms.values()].map(R => R.session.state.syncedAt).filter(Boolean).sort().at(-1) ?? app.lastCheckedAt ?? null;
    const list = {
      rooms: rows, currentRoomId: app.roomOpen ? app.current : null,
      onSelect: openRoomScreen, onOpenMenu: openMenu, onOpenJoin: openJoin, onOpenCreate: openCreate,
      sync: {lastSyncAt: anySynced, offlineSince: app.offlineAt, reconnecting: relay.offline},
      notice: app.notice, deviceLabel: app.device,
      invites: app.invites.filter(i => !app.dismissed.has(i.room)).map(i => ({room: i.room, busy: !!i.busy, message: i.message ?? null,
        onAccept: () => acceptInvite(i.room), onIgnore: () => { app.dismissed.add(i.room); render(); }})),
    };
    const R = app.roomOpen && app.current ? app.rooms.get(app.current) : null;
    const room = R ? (() => {
      const S = R.session.state;
      return {roomId: app.current, name: app.current, members: S.roster.slice(), joined: S.joined, halted: S.halted ? {...S.halted} : null,
        timeline: R.entries, draft: app.draft.get(app.current) ?? '', onSend: sendText, onAttach: sendAttachment, onOpenAttachment: e => e.load(),
        onBack: () => { app.roomOpen = false; render(); }, onOpenInvite: openInvite, onOpenMembers: openInvite,
        onDraft: text => { app.draft.set(app.current, text); }, notice: null, sending: app.sending || S.transferring,
        attachmentPending: R.session.attachmentPending ? {size: 0, onRetry: () => sendAttachment(null)} : null};
    })() : null;
    ui.renderShell(root, {list, room});
  }

  // ---- timeline per room ----
  function addEntry(roomId, m) {
    const R = app.rooms.get(roomId);
    if (!R) return;
    const key = m.key ?? (m.seq !== null && m.seq !== undefined ? `seq-${m.seq}` : `sys-${R.entries.length}`);
    if (R.entryKeys.has(key)) return;
    R.entryKeys.add(key);
    const entry = {key, kind: m.kind, seq: m.seq ?? null, sender: m.sender ?? '', senderName: m.sender ? displayName(m.sender) : '',
      isMe: m.sender === app.device, isAgent: m.sender ? isAgentDevice(m.sender) : false, body: m.text ?? '', ts: m.ts ?? null,
      size: m.size ?? 0, image: null, replay: !!m.replay, load: m.load ?? null};
    R.entries.push(entry);
    R.entries.sort((a, b) => (a.seq ?? Infinity) - (b.seq ?? Infinity) || 0);
    if (!entry.isMe && (entry.kind === 'text' || entry.kind === 'attachment') && !(app.roomOpen && app.current === roomId)) R.unread = true;
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

  // ---- rooms ----
  function newSession(roomId) {
    return createRoomSession({room: roomId, device: app.device, database: databaseFor(roomId), worker, relay, storage, on: {
      change: render,
      message: m => addEntry(roomId, m),
      log: logLine,
      notice: (text, tone) => status(text, tone),
      synced: () => render(),
    }});
  }
  /** Open (and remember) a room; `from`/`replace`/`startSeq` as room.js open(). */
  async function ensureRoom(roomId, opts = {}) {
    let R = app.rooms.get(roomId);
    if (R && !opts.replace) return R;
    if (R) { R.session.stop(); app.rooms.delete(roomId); }
    const session = newSession(roomId);
    R = {session, entries: [], entryKeys: new Set(), unread: false, order: app.rooms.size};
    app.rooms.set(roomId, R); writeKnown();
    try {
      await session.open(opts);
      await session.activate();
    } catch (error) { app.rooms.delete(roomId); writeKnown(); throw error; }
    render();
    return R;
  }
  function openRoomScreen(roomId) {
    if (!app.rooms.has(roomId)) return;
    app.current = roomId; app.roomOpen = true; app.rooms.get(roomId).unread = false; render();
  }

  // ---- phases ----
  async function boot() {
    if (!globalThis.Worker || !globalThis.WebAssembly || !globalThis.indexedDB) { fatal(strings.app.workerUnavailable); return; }
    const config = await loadConfig();
    if (typeof config.defaultRoom === 'string' && ROOM.test(config.defaultRoom)) app.defaultRoom = config.defaultRoom;
    const id = identity.read();
    if (!id) { app.phase = 'needsActor'; render(); return; }
    await startDevice(id);
  }
  function fatal(detail) { app.phase = 'fatal'; app.fatal = detail; render(); }
  async function chooseActor(actor) {
    try {
      const id = identity.choose(actor.trim());
      app.error = null;
      await startDevice(id);
    } catch (error) { app.error = strings.actor?.invalid ?? error.message; render(); }
  }
  async function startDevice(id) {
    app.actor = id.actor; app.device = id.device;
    app.phase = 'starting'; app.message = strings.app.deriving; render();
    relay.me().then(subject => { app.subject = subject; render(); }).catch(() => {});
    try {
      let dev = createDevice({device: app.device, worker, relay, storage, on: {log: logLine}});
      // Stage-2 install: the default room's single-store database holds the signer → migrate it.
      const legacy = {database: databaseFor(app.defaultRoom), room: app.defaultRoom};
      let opened = await dev.start({passphrase: identity.passphrase(), identityDatabase: IDENTITY_DATABASE, legacy});
      if (opened.fresh && !opened.migrated && (storage.getItem(markerKey()) !== null || storage.getItem(`hande:fresh-marker:${legacy.database}`) !== null)) {
        // The stores are new but this browser used this id before (#290): the chain never
        // re-accepts the old id with a new fingerprint — start as a new device id.
        dev.stop();
        const rotated = identity.rotate();
        status(strings.room.freshStore(rotated.device), 'warn');
        app.actor = rotated.actor; app.device = rotated.device;
        for (const k of Object.keys(storage)) if (k.startsWith('hande:room:') || k.startsWith('hande:rooms:')) storage.removeItem(k);
        dev = createDevice({device: app.device, worker, relay, storage, on: {log: logLine}});
        opened = await dev.start({passphrase: identity.passphrase(), identityDatabase: IDENTITY_DATABASE});
      }
      storage.setItem(markerKey(), '1');
      app.dev = dev;
      if (opened.migrated) logLine(`신원 이전: ${legacy.database} → ${IDENTITY_DATABASE}`);
      app.roomOpen = false;
      // Known rooms open first (their own 4 s polling); the default room is always known.
      const known = new Set(readKnown()); if (opened.migrated || known.size === 0) known.add(app.defaultRoom);
      for (const roomId of known) { try { await ensureRoom(roomId); } catch (error) { logLine(`방 ${roomId} 열기 실패: ${error.message}`); } }
      if (window.matchMedia?.('(min-width: 900px)').matches && app.rooms.size) { app.current = [...app.rooms.keys()][0]; app.roomOpen = true; }
      await refresh();
      app.tick = setInterval(() => refresh().catch(() => {}), TICK_MS);
      render();
    } catch (error) {
      fatal(/worker|boot|init_multi/.test(error.message) ? strings.app.workerUnavailable : strings.app.storageUnavailable(error.message));
    }
  }
  /**
   * Device-level refresh (iOS AppModel.refresh): relay room list (403 = not enrolled yet →
   * enrollment screen), lobby Welcomes for rooms this device has not joined (auto-join or
   * invite card), lobby key replenish once enrolled.
   */
  let refreshing = false;
  async function refresh() {
    if (refreshing || !app.dev?.state.started) return;
    refreshing = true;
    try {
      let listed;
      try { listed = await app.dev.rooms(); } catch (error) { logLine(`방 목록 실패: ${error.message}`); listed = undefined; }
      app.lastCheckedAt = clock(true);
      if (listed === null) { render(); return; }   // 403: waiting for the operator
      if (Array.isArray(listed)) {
        for (const r of listed) if (r.member && !r.closed && ROOM.test(r.room) && !app.rooms.has(r.room)) {
          try { await ensureRoom(r.room); } catch (error) { logLine(`방 ${r.room} 열기 실패: ${error.message}`); }
        }
      }
      await discoverLobbyWelcomes();
      if (app.lobbyDue) {
        try { const report = await app.dev.replenish(LOBBY_TARGET); if (report) app.lobbyDue = false; }
        catch (error) { logLine(`로비 키 보충 실패: ${error.message}`); }
      }
    } finally { refreshing = false; render(); }
  }
  async function discoverLobbyWelcomes() {
    let welcomes;
    try { welcomes = await app.dev.welcomes(); } catch (error) { logLine(`로비 초대 조회 실패: ${error.message}`); return; }
    const invites = [];
    for (const w of welcomes) {
      if (!ROOM.test(w.room) || app.adoptFailed.get(w.room) === w.seq) continue;
      const R = app.rooms.get(w.room);
      if (R && R.session.joined) continue;   // joined already — the next ack drops it from the list
      if (AUTO_JOIN_ACTORS.has(app.actor)) await adoptWelcome(w);
      else if (!app.dismissed.has(w.room) && !invites.some(i => i.room === w.room)) invites.push({room: w.room, seq: w.seq});
    }
    // Keep busy/message state of cards still pending.
    app.invites = invites.map(i => ({...i, ...(app.invites.find(x => x.room === i.room) ?? {})}));
  }
  /** Room state = lobby clone → cursor before the Welcome → sync that room (join). */
  async function adoptWelcome(w) {
    try {
      const R = await ensureRoom(w.room, {from: 'lobby', replace: true, startSeq: w.seq});
      await R.session.sync({quiet: true});
      if (R.session.joined) { status(strings.lobby.joined(w.room), 'ok'); app.lobbyDue = true; return true; }
      app.adoptFailed.set(w.room, w.seq);
      return false;
    } catch (error) { app.adoptFailed.set(w.room, w.seq); logLine(`로비 초대 수락 실패(${w.room}): ${error.message}`); return false; }
  }
  async function acceptInvite(roomId) {
    const invite = app.invites.find(i => i.room === roomId);
    if (!invite || invite.busy) return;
    invite.busy = true; invite.message = null; render();
    const ok = await adoptWelcome(invite);
    invite.busy = false;
    if (ok) app.invites = app.invites.filter(i => i.room !== roomId);
    else invite.message = strings.lobby.acceptFailed(strings.room.notJoined);
    render();
  }

  // ---- actions ----
  const cur = () => app.rooms.get(app.current)?.session;
  async function guard(run) {
    try { return await run(); }
    catch (error) { status(error.message, 'danger'); throw error; }
  }
  async function sendText(text) {
    const s = cur();
    if (!s || app.sending) return false;
    app.sending = true; render();
    try { await s.send(text); app.draft.set(app.current, ''); app.rooms.get(app.current).unread = false; return true; }
    catch (error) { status(error.message, 'danger'); return false; }
    finally { app.sending = false; render(); }
  }
  async function sendAttachment(file) {
    const s = cur();
    if (!s) return;
    try {
      const result = await s.sendAttachment(file);
      status(strings.room.attachmentSent(result.seq, result.size), 'ok');
    } catch (error) { status(error.message, 'danger'); render(); }
  }
  function openMenu() {
    ui.openMenuSheet(root, {items: [
      {label: strings.menu.settings, run: openSettings},
      ...(cur() ? [{label: strings.menu.invite, run: openInvite}] : []),
      {label: strings.menu.approve, run: openApprove},
      {label: strings.menu.sync, run: () => refresh().then(() => Promise.all([...app.rooms.values()].map(R => R.session.sync()))).then(render)},
      {label: strings.menu.wipe, run: confirmWipe, tone: 'danger'},
    ], onClose: () => {}});
  }
  function openSettings() {
    const reg = JSON.stringify(app.dev.registration(app.subject), null, 1);
    ui.openSettingsSheet(root, {deviceId: app.device, actor: app.actor, fingerprint: app.dev.state.fingerprint, subject: app.subject,
      origin: location.host, onCopyRegistration: () => copy(reg), onOpenApprove: openApprove, onWipe: confirmWipe, onClose: () => {}});
  }
  function openJoin() {
    ui.openJoinSheet(root, {defaultRoom: app.current ?? app.defaultRoom, busy: false, message: null, onClose: () => {}, onSubmit: async roomId => {
      const R = await guard(() => ensureRoom(roomId));
      await guard(() => R.session.publishKeyPackage());
      status(strings.room.keyPackagePublished, 'ok');
    }});
  }
  function openCreate() {
    ui.openCreateSheet(root, {defaultRoom: '', busy: false, message: null, onClose: () => {}, onSubmit: async roomId => {
      const R = await guard(() => ensureRoom(roomId));
      await guard(() => R.session.create());
      status(strings.room.created, 'ok');
      openRoomScreen(roomId);
    }});
  }
  function openInvite() {
    const s = cur();
    if (!s) return;
    ui.openInviteSheet(root, {roomId: app.current, members: s.state.roster.slice(), selfDevice: app.device, busy: false, message: null, onClose: () => {},
      onInvite: async target => { await guard(() => s.invite(target)); status(strings.room.inviteDone(target), 'ok'); },
      onRemove: async target => { await guard(() => s.remove(target)); status(strings.room.removeDone(target), 'ok'); }});
  }
  function openApprove() {
    let candidate = null;
    ui.openApproveSheet(root, {
      onOffer: async json => {
        const c = JSON.parse(json);
        for (const k of ['device_id', 'actor', 'subject', 'signing_key', 'base_revision']) if (!(k in c)) throw new Error(strings.room.candidateMissing(k));
        if (!/^[a-f0-9]{64}$/.test(c.signing_key)) throw new Error(strings.room.candidateKeyInvalid);
        const fingerprint = await app.dev.policyFingerprint(c.signing_key);
        candidate = {...c, fingerprint};
        return {deviceId: c.device_id, fingerprint};
      },
      onApprove: async () => {
        if (!candidate) throw new Error('먼저 등록 JSON을 붙여 넣어 지문을 확인하세요');
        const args = {action: 'approve-device', device_id: candidate.device_id, actor: candidate.actor, subject: candidate.subject,
          signing_key: candidate.signing_key, acceptance: 'trusted-device-fingerprint', base_revision: Number(candidate.base_revision)};
        const signature = await app.dev.signApproval(JSON.stringify(args));
        const evidence = {...args, signature, fingerprint: candidate.fingerprint, approved_by: app.device};
        delete evidence.action; delete evidence.acceptance;
        candidate = null;
        logLine(strings.room.approvalSigned);
        return JSON.stringify(evidence, null, 1);
      },
      onClose: () => { candidate = null; },
    });
  }
  function confirmWipe() {
    ui.openConfirmSheet(root, {title: strings.wipe?.title ?? '이 기기 지우기', body: strings.wipe?.warning ?? '', confirmLabel: strings.wipe?.confirm ?? '지우기', tone: 'danger',
      onConfirm: wipeDevice, onClose: () => {}});
  }
  /** 이 기기 지우기 (iOS §9-5): every store of this identity, the lobby keys on the relay, local state. */
  async function wipeDevice() {
    try {
      const next = nextDeviceId(app.device);
      if (app.tick) clearInterval(app.tick);
      try { await relay.api('DELETE', `/v2/lobby/keypackages?device=${encodeURIComponent(app.device)}`); } catch (_) { /* best effort */ }
      for (const R of app.rooms.values()) { try { await R.session.wipe(); } catch (_) {} }
      app.dev.stop();
      const names = [IDENTITY_DATABASE, `${IDENTITY_DATABASE}-history`, 'family-mls-synthetic-hande--lobby', 'family-mls-synthetic-hande--lobby-history'];
      for (const dbName of names) await new Promise(resolve => { const r = indexedDB.deleteDatabase(dbName); r.onsuccess = r.onerror = r.onblocked = () => resolve(); });
      for (const k of Object.keys(storage)) if (k.startsWith('hande:') && k !== 'hande:identity') storage.removeItem(k);
      identity.rotate(); identity.forgetPassphrase();
      status(strings.room.wipeDone(next), 'warn');
      setTimeout(() => location.reload(), 1500);
    } catch (error) { status(error.message, 'danger'); }
  }

  window.addEventListener('beforeunload', () => { for (const R of app.rooms.values()) for (const e of R.entries) if (e.image) URL.revokeObjectURL(e.image.url); });
  boot().catch(error => fatal(error.message));
  return {get state() { return app; }};
}
