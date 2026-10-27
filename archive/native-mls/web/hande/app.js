// 한데 웹 — app state machine (iOS AppModel.Phase: starting → needsActor →
// needsEnrollment → ready / halted / fatal) wired to the screens in ui.js.
// Stage 4 (#431): one device identity (device.js, worker multi-store mode) and any
// number of rooms (room.js, one session per room) — the rooms the relay lists for
// this device, rooms created or requested here, and rooms a lobby Welcome opens
// (owner actors join automatically, family devices accept with one tap — iOS
// AppModel.discoverLobbyWelcomes / acceptInvite).
import * as ui from './ui.js';
import {strings, displayName, isAgentDevice, isMine, isOneToOne, roomLabel, previewLine, relativeTime} from './strings.js';
import {orderRooms, moveRoom, readRoomOrder, writeRoomOrder} from './room-order.js';
import {readDraft, writeDraft} from './drafts.js';
import {createWorkerBridge} from './worker-bridge.js';
import {createRelay} from './relay.js';
import {createIdentityStore, databaseFor, ROOM, IDENTITY_DATABASE, LOBBY_DATABASE} from './identity.js';
import {createRoomSession, nextDeviceId, clock} from './room.js';
import {createDevice, LOBBY_TARGET} from './device.js';
import {imageType, shouldPreview} from './attachment-view.js';
import {fileboxConfig} from './filebox.js';
import {installShortcuts} from './shortcuts.js';

const DEFAULT_ROOM = 'family';
const AUTO_JOIN_ACTORS = new Set(['owner']);   // iOS AppModel.autoJoinActors
const ADOPT_TRIES = 2;                      // a lobby Welcome gets one retry per page session (#517)
const TICK_MS = 8000;                       // device-level refresh (rooms list, lobby welcomes, replenish)

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
    invites: [], adoptFailed: new Map(), dismissed: new Set(), lobbyDue: true, pendingWelcomeRefs: {set: new Set(), complete: true},
    filebox: null, boxOpen: false, boxRefresh: 0,   // 오른쪽 파일보관함 pane (config.json filebox)
    roomOrder: [], orderEditing: false,              // 대화 목록 고정 순서(이 기기 localStorage, #480 A)
    notice: null, logs: [], offlineAt: null, tick: null,
  };
  const identity = createIdentityStore({storage});
  const worker = createWorkerBridge();
  const relay = createRelay({fetch: fetchImpl, onOffline: down => { app.offlineAt = down ? clock() : null; render(); }});
  const knownKey = () => `hande:rooms:${app.device}`;
  const readKnown = () => { try { const v = JSON.parse(storage.getItem(knownKey()) || '[]'); return Array.isArray(v) ? v.filter(r => ROOM.test(r)) : []; } catch (_) { return []; } };
  const writeKnown = () => storage.setItem(knownKey(), JSON.stringify([...app.rooms.keys()]));
  const markerKey = () => `hande:fresh-marker:${IDENTITY_DATABASE}`;
  // console.info, not debug: DevTools hides debug by default and a field report then shows nothing (2026-10-19).
  const logLine = line => { app.logs.push(`${clock(true)} ${line}`); if (app.logs.length > 500) app.logs.shift(); console.info('[hande]', line); };

  // ---- rendering (coalesced); the phase is re-derived right before each paint ----
  let scheduled = false;
  /** 오른쪽 파일보관함 pane 열고 닫기(좁은 화면에선 목록/대화 대신 보임, 넓은 화면에선 세 번째 열). */
  function toggleBox() { app.boxOpen = !app.boxOpen; render(); }

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
    // 미리보기: 마크다운 기호를 걷어낸 한 줄, 첨부는 [사진]/[파일](내용 판별 결과) — 패밀리챗 목록과 같은 모양(#480 A).
    const body = last ? (last.kind === 'attachment' ? (last.image ? strings.rooms.photoPreview : strings.rooms.filePreview) : last.body) : '';
    return {roomId, name: roomLabel(roomId), emoji: halted ? '🪵' : '🔥',
      // 1:1 방은 상대가 한 명뿐이라 「이름: 」 접두를 빼고 내용만(2026-10-26 오너).
      preview: last ? previewLine(isOneToOne(S.roster) ? '' : last.senderName, body) : (S.joined ? strings.rooms.noMessages : strings.room.notJoined),
      time: last?.ts ? relativeTime(last.ts, Date.now()) : '', unread: R.unread && !(app.roomOpen && app.current === roomId),
      state: halted ? 'halted' : S.joined ? 'joined' : 'pending', hasAgent: S.roster.some(isAgentDevice), members: S.roster.length, order: R.order};
  }
  /** 대화 목록에서 방 하나를 옮긴다 — 화면은 즉시, 저장은 이 기기 localStorage(패밀리챗 moveRoomInList). */
  function moveRoomInList(roomId, toIndex, focus = null) {
    const visibleIds = orderRooms([...app.rooms.keys()].map(roomRow), app.roomOrder).map(r => r.roomId);
    const next = moveRoom(visibleIds, roomId, toIndex, app.roomOrder);
    if (!next) return;
    app.roomOrder = next;
    writeRoomOrder(storage, app.device, next);
    render();
    if (focus) queueMicrotask(() => ui.focusRoomOrderControl(root, roomId, focus));
  }
  function toggleOrderEdit() { app.orderEditing = !app.orderEditing; render(); }
  function paint() {
    const D = app.dev?.state;
    if (app.phase === 'fatal') {
      // The last log lines ride along so a screenshot is a complete field report (no DevTools).
      const tail = app.logs.slice(-6).join('\n');
      ui.renderFatal(root, {title: strings.app.fatalTitle, detail: app.fatal + (tail ? `\n\n최근 기록:\n${tail}` : '') + `\n기기 ${app.device ?? '?'}`, onRetry: () => location.reload(), onWipe: D ? confirmWipe : null});
      return;
    }
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
    const rows = orderRooms([...app.rooms.keys()].map(roomRow), app.roomOrder);
    const anySynced = [...app.rooms.values()].map(R => R.session.state.syncedAt).filter(Boolean).sort().at(-1) ?? app.lastCheckedAt ?? null;
    const list = {
      rooms: rows, currentRoomId: app.roomOpen ? app.current : null,
      onSelect: openRoomScreen, onOpenMenu: openMenu, onOpenJoin: openJoin, onOpenCreate: openCreate, onOpenBox: app.filebox ? toggleBox : null,
      orderEditing: app.orderEditing, onToggleOrderEdit: toggleOrderEdit, onMoveRoom: moveRoomInList,
      sync: {lastSyncAt: anySynced, offlineSince: app.offlineAt, reconnecting: relay.offline},
      notice: app.notice, deviceLabel: app.device,
      invites: inviteRows(), onOpenNotify: openNotify,
    };
    const R = app.roomOpen && app.current ? app.rooms.get(app.current) : null;
    const room = R ? (() => {
      const S = R.session.state;
      return {roomId: app.current, name: roomLabel(app.current), members: S.roster.slice(), joined: S.joined, halted: S.halted ? {...S.halted} : null,
        timeline: R.entries, draft: app.draft.get(app.current) ?? '', onSend: sendText, onAttach: sendAttachment, onOpenAttachment: e => e.load(),
        onBack: () => { app.roomOpen = false; render(); }, onOpenInvite: openInvite, onOpenMembers: openInvite, onOpenBox: app.filebox ? toggleBox : null,
        onDraft: text => { app.draft.set(app.current, text); writeDraft(storage, app.device, app.current, text); }, notice: null, sending: app.sending || S.transferring,
        attachmentPending: R.session.attachmentPending ? {size: 0, onRetry: () => sendAttachment(null)} : null};
    })() : null;
    const box = app.filebox
      ? {filebox: {url: app.filebox.url, title: app.filebox.title, refresh: app.boxRefresh}, open: app.boxOpen,
         onToggle: toggleBox, onRefresh: () => { app.boxRefresh += 1; render(); }}
      : null;
    ui.renderShell(root, {list, room, box});
  }

  // ---- timeline per room ----
  function addEntry(roomId, m) {
    const R = app.rooms.get(roomId);
    if (!R) return;
    const key = m.key ?? (m.seq !== null && m.seq !== undefined ? `seq-${m.seq}` : `sys-${R.entries.length}`);
    if (R.entryKeys.has(key)) return;
    R.entryKeys.add(key);
    const entry = {key, kind: m.kind, seq: m.seq ?? null, sender: m.sender ?? '', senderName: m.sender ? displayName(m.sender) : '',
      isMe: isMine(m.sender, {device: app.device, actor: app.actor}), isAgent: m.sender ? isAgentDevice(m.sender) : false, body: m.text ?? '', ts: m.ts ?? null,
      size: m.size ?? 0, image: null, replay: !!m.replay, load: m.load ?? null, fileName: m.fileName ?? null};
    R.entries.push(entry);
    R.entries.sort((a, b) => (a.seq ?? Infinity) - (b.seq ?? Infinity) || 0);
    if (!entry.isMe && (entry.kind === 'text' || entry.kind === 'attachment') && !(app.roomOpen && app.current === roomId)) R.unread = true;
    if (shouldPreview(entry)) {   // attachment-view.js: up to MAX_ATTACHMENT, by content only
      entry.load().then(bytes => {
        const type = imageType(bytes);
        if (!type) return;
        entry.image = {url: URL.createObjectURL(new Blob([bytes], {type})), type, alt: `${entry.senderName}의 사진`};
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
    // 새로고침 뒤에도 쓰던 글이 남는다(#480 B) — 메모리 초안이 없을 때만 저장분을 올린다.
    if (!app.draft.has(roomId)) { const saved = readDraft(storage, app.device, roomId); if (saved) app.draft.set(roomId, saved); }
    try {
      await session.open(opts);
      await session.activate();
    } catch (error) { app.rooms.delete(roomId); writeKnown(); throw error; }
    render();
    return R;
  }
  function openRoomScreen(roomId) {
    app.boxOpen = false;   // 좁은 화면: 보관함 대신 대화를 보인다
    if (!app.rooms.has(roomId)) return;
    app.current = roomId; app.roomOpen = true; app.rooms.get(roomId).unread = false; render();
  }

  // ---- phases ----
  async function boot() {
    if (!globalThis.Worker || !globalThis.WebAssembly || !globalThis.indexedDB) { fatal(strings.app.workerUnavailable); return; }
    const config = await loadConfig();
    if (typeof config.defaultRoom === 'string' && ROOM.test(config.defaultRoom)) app.defaultRoom = config.defaultRoom;
    app.filebox = fileboxConfig(config.filebox, {defaultTitle: strings.box.title});
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
  const dbExists = async name => { try { return (await indexedDB.databases()).some(d => d.name === name); } catch (_) { return false; } };
  const deleteDb = name => new Promise(resolve => { const r = indexedDB.deleteDatabase(name); r.onsuccess = r.onerror = r.onblocked = () => resolve(); });
  /** Identity + lobby stores only (never a room store): recreatable from the legacy room database or afresh. */
  async function wipeIdentityStores() {
    for (const name of [IDENTITY_DATABASE, `${IDENTITY_DATABASE}-history`, LOBBY_DATABASE, `${LOBBY_DATABASE}-history`]) await deleteDb(name);
    storage.removeItem(markerKey());
    for (const k of Object.keys(storage)) if (k.startsWith('hande:lobby:')) storage.removeItem(k);
  }
  async function startDevice(id) {
    app.actor = id.actor; app.device = id.device;
    app.phase = 'starting'; app.message = strings.app.deriving; render();
    relay.me().then(subject => { app.subject = subject; render(); }).catch(() => {});
    try {
      // Stage-2 install: the default room's single-store database holds the signer → migrate it.
      const legacy = {database: databaseFor(app.defaultRoom), room: app.defaultRoom};
      const legacyExists = await dbExists(legacy.database);
      logLine(`시작: 기기 ${app.device}, 레거시 DB ${legacy.database} ${legacyExists ? '있음' : '없음'}, 신원 DB 마커 ${storage.getItem(markerKey()) !== null ? '있음' : '없음'}`);
      let dev = createDevice({device: app.device, worker, relay, storage, on: {log: logLine}});
      let opened;
      try {
        opened = await dev.start({passphrase: identity.passphrase(), identityDatabase: IDENTITY_DATABASE, legacy});
      } catch (error) {
        // Self-heal (2026-10-19 field failure, #431): the identity store was created under
        // another device id (an earlier run rotated the id while the stores stayed) →
        // `init_multi` is refused. The identity/lobby stores hold nothing a room needs
        // (the enrolled signer lives in the legacy room store or is re-derived), so drop
        // them, go back to the previous id when one is recorded, and start once more.
        if (!/^init_multi 거부/.test(error.message)) throw error;
        logLine(`신원 스토어 복구: ${error.message} — 신원·로비 스토어를 지우고 다시 시작`);
        dev.stop();
        await wipeIdentityStores();
        const prev = identity.restorePrevious();
        if (prev) { app.actor = prev.actor; app.device = prev.device; logLine(`기기 ID 복원: ${prev.restoredFrom} → ${prev.device}`); }
        dev = createDevice({device: app.device, worker, relay, storage, on: {log: logLine}});
        opened = await dev.start({passphrase: identity.passphrase(), identityDatabase: IDENTITY_DATABASE, legacy});
      }
      if (opened.fresh && !opened.migrated && !legacyExists && (storage.getItem(markerKey()) !== null || storage.getItem(`hande:fresh-marker:${legacy.database}`) !== null)) {
        // The stores are new but this browser used this id before (#290): the chain never
        // re-accepts the old id with a new fingerprint — start as a new device id. Only
        // when no legacy store exists: with one, a fresh unmigrated identity is a bug, not a wipe.
        dev.stop();
        await wipeIdentityStores();
        const rotated = identity.rotate();
        status(strings.room.freshStore(rotated.device), 'warn');
        app.actor = rotated.actor; app.device = rotated.device;
        for (const k of Object.keys(storage)) if (k.startsWith('hande:room:') || k.startsWith('hande:rooms:')) storage.removeItem(k);
        dev = createDevice({device: app.device, worker, relay, storage, on: {log: logLine}});
        opened = await dev.start({passphrase: identity.passphrase(), identityDatabase: IDENTITY_DATABASE});
      }
      if (opened.fresh && !opened.migrated && legacyExists) throw new Error(`신원 이전 실패: ${legacy.database}가 있는데 이전되지 않았습니다`);
      storage.setItem(markerKey(), '1');
      app.dev = dev;
      app.roomOrder = readRoomOrder(storage, app.device);
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
      fatal((/worker|boot|init_multi/.test(error.message) ? strings.app.workerUnavailable : strings.app.storageUnavailable(error.message)) + ` [${error.message}]`);
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
        // While a lobby Welcome is still unadopted, the package it was built from keeps its
        // secret (#517): precisely by `key_package_ref` when the relay reports it, otherwise
        // (older relay) by not pruning at all while an adoption is outstanding. Minting is unaffected.
        const refs = app.pendingWelcomeRefs;
        try { const report = await app.dev.replenish(LOBBY_TARGET, {prune: refs.complete || app.adoptFailed.size === 0, protect: refs.set}); if (report) app.lobbyDue = false; }
        catch (error) { logLine(`로비 키 보충 실패: ${error.message}`); }
      }
    } finally { refreshing = false; render(); }
  }
  async function discoverLobbyWelcomes() {
    let welcomes;
    try { welcomes = await app.dev.welcomes(); } catch (error) { logLine(`로비 초대 조회 실패: ${error.message}`); return; }
    const invites = [];
    const refs = {set: new Set(), complete: true};
    for (const w of welcomes) {
      if (!ROOM.test(w.room)) continue;
      const R = app.rooms.get(w.room);
      if (R && R.session.joined) continue;   // joined already — the next ack drops it from the list
      if (typeof w.key_package_ref === 'string' && w.key_package_ref) refs.set.add(w.key_package_ref); else refs.complete = false;
      if (app.dismissed.has(w.room) || invites.some(i => i.room === w.room)) continue;
      if (AUTO_JOIN_ACTORS.has(app.actor)) {
        // Owner devices auto-join; a failure is not silent — the invite stays in the 🔔 list
        // (and the list card) with its state, where 「다시 시도」 resets the attempt count (#521).
        const failed = app.adoptFailed.get(w.room);
        const exhausted = failed && failed.seq === w.seq && failed.tries >= ADOPT_TRIES;
        if (!exhausted && await adoptWelcome(w)) continue;
        invites.push({room: w.room, seq: w.seq, failed: {...app.adoptFailed.get(w.room)}});
      } else invites.push({room: w.room, seq: w.seq});
    }
    // Keep busy/message state of cards still pending.
    app.invites = invites.map(i => ({...(app.invites.find(x => x.room === i.room) ?? {}), ...i}));
    app.pendingWelcomeRefs = refs;
  }
  function adoptFailed(w, reason = null) {
    const prev = app.adoptFailed.get(w.room);
    app.adoptFailed.set(w.room, {seq: w.seq, tries: (prev && prev.seq === w.seq ? prev.tries : 0) + 1, reason: reason ?? prev?.reason ?? null});
  }
  /**
   * Room state = lobby clone → cursor before the Welcome → sync that room (join). The lobby
   * store is opened first: until #517 only `replenish` opened it, so a Welcome discovered on
   * the first refresh of a page (every invite made while the tab was closed) was refused at
   * `open_room(from: 'lobby')`, and the replenish that followed deleted the secret it needed.
   */
  async function adoptWelcome(w) {
    try {
      await app.dev.openLobby();
      const R = await ensureRoom(w.room, {from: 'lobby', replace: true, startSeq: w.seq});
      await R.session.sync({quiet: true});
      if (R.session.joined) { app.adoptFailed.delete(w.room); app.invites = app.invites.filter(i => i.room !== w.room); status(strings.lobby.joined(w.room), 'ok'); app.lobbyDue = true; return true; }
      adoptFailed(w, strings.room.notJoined);
      return false;
    } catch (error) { adoptFailed(w, error.message); logLine(`로비 초대 수락 실패(${w.room}, seq ${w.seq}, ${app.adoptFailed.get(w.room).tries}/${ADOPT_TRIES}): ${error.message}`); return false; }
  }
  /** 수락 / 다시 시도 (목록 카드·🔔 시트): a manual attempt always resets the per-session count. */
  async function acceptInvite(roomId) {
    const invite = app.invites.find(i => i.room === roomId);
    if (!invite || invite.busy) return;
    app.adoptFailed.delete(roomId);
    invite.busy = true; invite.message = null; invite.failed = null; render();
    const ok = await adoptWelcome(invite);
    invite.busy = false;
    if (ok) app.invites = app.invites.filter(i => i.room !== roomId);
    else { invite.failed = {...app.adoptFailed.get(roomId)}; invite.message = strings.lobby.acceptFailed(invite.failed.reason || strings.room.notJoined); }
    render();
  }
  function inviteRows() {
    return app.invites.filter(i => !app.dismissed.has(i.room)).map(i => ({room: i.room, name: roomLabel(i.room), busy: !!i.busy, message: i.message ?? null,
      failed: i.failed && i.failed.tries ? {tries: i.failed.tries, reason: i.failed.reason ?? null} : null,
      onAccept: () => acceptInvite(i.room), onIgnore: () => { app.dismissed.add(i.room); render(); }}));
  }
  function openNotify() { ui.openNotifySheet(root, {invites: inviteRows(), onClose: () => {}}); }

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
    try { await s.send(text); app.draft.set(app.current, ''); writeDraft(storage, app.device, app.current, ''); app.rooms.get(app.current).unread = false; return true; }
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
      {label: strings.menu.join, run: openJoin, testid: 'menu-join'},
      {label: strings.menu.create, run: openCreate, testid: 'menu-create'},
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
      await wipeIdentityStores();
      for (const k of Object.keys(storage)) if (k.startsWith('hande:') && k !== 'hande:identity') storage.removeItem(k);
      identity.rotate(); identity.forgetPassphrase();
      status(strings.room.wipeDone(next), 'warn');
      setTimeout(() => location.reload(), 1500);
    } catch (error) { status(error.message, 'danger'); }
  }

  window.addEventListener('beforeunload', () => { for (const R of app.rooms.values()) for (const e of R.entries) if (e.image) URL.revokeObjectURL(e.image.url); });
  // 패밀리챗과 같은 전역 단축키(#478): PageUp/Down 방 이동 · Home 목록 · 작성창 Esc/End → 대화 내용 ·
  // 대화 내용 ↑/↓ 스크롤·Esc 캐럿 모드 · 대화형 요소 밖 Enter → 작성창. 초안은 app.draft(방별)가 지킨다.
  installShortcuts(root, {
    openRoom: openRoomScreen,
    openRooms: () => { app.roomOpen = false; render(); },
    currentRoomId: () => (app.roomOpen && app.phase === 'ready' ? app.current : null),
    orderEditing: () => app.orderEditing,
  });
  boot().catch(error => fatal(error.message));
  return {get state() { return app; }};
}
