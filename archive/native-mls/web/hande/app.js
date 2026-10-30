// 한데 웹 — app state machine (iOS AppModel.Phase: starting → needsActor →
// needsEnrollment → ready / halted / fatal) wired to the screens in ui.js.
// Stage 4 (#431): one device identity (device.js, worker multi-store mode) and any
// number of rooms (room.js, one session per room) — the rooms the relay lists for
// this device, rooms created or requested here, and rooms a lobby Welcome opens
// (owner actors join automatically, family devices accept with one tap — iOS
// AppModel.discoverLobbyWelcomes / acceptInvite).
import * as ui from './ui.js';
import {strings, displayName, isAgentDevice, isMine, isOneToOne, participantCount, roomLabel, previewLine, relativeTime, typingLabel} from './strings.js';
import {orderRooms, moveRoom, readRoomOrder, writeRoomOrder} from './room-order.js';
import {readDraft, writeDraft} from './drafts.js';
import {readReadSeq, writeReadSeq, latestSeq, isUnread} from './read-seq.js';
import {readConsent, writeConsent, agentsIn, needsConsent} from './agent-consent.js';
import {isLocalOnlyRoom, forgetRoomKeys} from './local-room.js';
import {createStatusBoard, applyStatus, clearStatusOnMessage, visibleStatuses} from './status-v1.js';
import {createWorkerBridge} from './worker-bridge.js';
import {createRelay} from './relay.js';
import {createIdentityStore, databaseFor, ROOM, IDENTITY_DATABASE, LOBBY_DATABASE} from './identity.js';
import {createRoomSession, nextDeviceId, clock} from './room.js';
import {createDevice, LOBBY_TARGET} from './device.js';
import {createPreviewLoader} from './preview-loader.js';
import {installSyncRecovery} from './sync-recovery.js';
import {fileboxConfig} from './filebox.js';
import {collectAttachments} from './attachments.js';
import {installShortcuts} from './shortcuts.js';
import {
  canApprove, isSibling, candidatesFor, approvalArgs, approvalEvidence, rolesActions, nextRoles, rolesArgs, rolesEvidence, recordOf,
  siblingInviteRooms, enrollModeFrom, readSiblingQueue, writeSiblingQueue, enqueueSiblingInvites, splitSiblingQueue, isRetryableInviteError,
  CANDIDATE_REPOST_MARGIN_MS,
} from './self-service.js';

const DEFAULT_ROOM = 'family';
const AUTO_JOIN_ACTORS = new Set(['owner']);   // iOS AppModel.autoJoinActors
const ADOPT_TRIES = 2;                      // a lobby Welcome gets one retry per page session (#517)
const TICK_MS = 8000;                       // device-level refresh (rooms list, lobby welcomes, replenish)
const ME_EVERY_TICKS = 4;                   // GET /v2/me (policy revision, my devices) every 4th tick (#574) — and right after any chain change

async function loadConfig() {
  try {
    const r = await fetch('./config.json', {credentials: 'same-origin'});
    if (r.status !== 200) return {};
    const v = await r.json();
    return v && typeof v === 'object' ? v : {};
  } catch (_) { return {}; }
}

// theme: main.js 의 installTheme() 핸들({get, set}) — 설정 시트의 「화면」 행이 쓴다. 없으면(테스트) 행을 숨긴다.
export function startApp(root, {storage = localStorage, fetch: fetchImpl = globalThis.fetch.bind(globalThis), theme = null} = {}) {
  const app = {
    phase: 'starting', message: strings.app.starting, error: null, fatal: null,
    actor: null, device: null, subject: null, defaultRoom: DEFAULT_ROOM, dev: null,
    rooms: new Map(),          // roomId → {session, entries, entryKeys, readSeq, order, statuses}
    current: null, roomOpen: false, draft: new Map(), sending: false,
    invites: [], adoptFailed: new Map(), dismissed: new Set(), lobbyDue: true, pendingWelcomeRefs: {set: new Set(), complete: true},
    filebox: null, boxOpen: false, boxTab: 'attachments', boxRefresh: 0, pendingJump: null,   // 오른쪽 보관함 pane: 첨부 탭(#544 D) + 파일보관함 iframe(config.json filebox)
    consentPrompted: new Set(),                      // AI 참여 동의 시트를 이 페이지 세션에서 자동으로 띄운 방(#544 E)
    relayRooms: null,                                // 릴레이가 이 기기를 멤버라고 한 방 집합(GET /v2/rooms) — 로컬 전용 방 판정용, 받기 전엔 null
    roomOrder: [], orderEditing: false,              // 대화 목록 고정 순서(이 기기 localStorage, #480 A)
    notice: null, logs: [], offlineAt: null, tick: null,
    // 기기 셀프서비스(#574 PR 2b): /v2/me 본문(정책 revision·내 기기), 등록 화면 모드, 승인할 후보, 🔔 메모.
    me: null, meTick: 0,
    enroll: {mode: 'operator', nextPostAt: 0, expiresAt: null},
    candidates: [], candidateRevision: null, dismissedCandidates: new Set(), notes: [],
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
  /** 오른쪽 보관함 pane 열고 닫기(좁은 화면에선 목록/대화 대신 보임, 넓은 화면에선 세 번째 열). */
  function toggleBox() { app.boxOpen = !app.boxOpen; render(); }
  /** 보관함 「첨부」 행 → 그 방을 열고 그 말풍선으로 스크롤(#544 D). 이동은 paint 뒤에 한다(pendingJump). */
  function openAttachmentFromBox(file) {
    if (!app.rooms.has(file.roomId)) return;
    app.pendingJump = {roomId: file.roomId, key: file.key};
    openRoomScreen(file.roomId);
  }

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
    // status-v1(#560): 에이전트가 일하는 중이면 그 최신 「⏳ Working …」 줄 — 목록에서 미리보기 자리에 보인다(오너 2026-10-30).
    // 안 읽음·정렬·미리보기 원본(entries)은 그대로다.
    const working = halted ? null : (visibleStatuses(R.statuses).at(-1)?.text ?? null);
    return {roomId, name: roomLabel(roomId), emoji: halted ? '🪵' : '🔥', working,
      // 1:1 방은 상대가 한 명뿐이라 「이름: 」 접두를 빼고 내용만(2026-10-26 오너).
      preview: last ? previewLine(isOneToOne(S.roster) ? '' : last.senderName, body) : (S.joined ? strings.rooms.noMessages : strings.room.notJoined),
      time: last?.ts ? relativeTime(last.ts, Date.now()) : '', unread: isUnread(R.entries, R.readSeq) && !(app.roomOpen && app.current === roomId),
      muted: S.muted === true,
      state: halted ? 'halted' : S.joined ? 'joined' : 'pending', hasAgent: S.roster.some(isAgentDevice), members: participantCount(S.roster), order: R.order};
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
  /** 방 알림 켜기/끄기 — 화면은 바로 바뀌고, 릴레이가 거절하면 되돌리며 알린다(iOS AppModel.setMuted 와 같은 결). */
  async function toggleMute(roomId) {
    const R = app.rooms.get(roomId);
    if (!R || typeof R.session.state.muted !== 'boolean') return;
    const next = !R.session.state.muted;
    const ok = await R.session.setMuted(next);
    status(ok ? (next ? strings.chat.mutedDone : strings.chat.unmutedDone) : strings.chat.muteFailed, ok ? 'ok' : 'warn');
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
        mode: app.enroll.mode, expiresAt: app.enroll.expiresAt,
        onCopy: () => copy(JSON.stringify(reg, null, 1)), onCheck: () => refresh().then(render),
        onOpenApprove: null, onWipe: confirmWipe, error: app.error});
      return;
    }
    const rows = orderRooms([...app.rooms.keys()].map(roomRow), app.roomOrder);
    const anySynced = [...app.rooms.values()].map(R => R.session.state.syncedAt).filter(Boolean).sort().at(-1) ?? app.lastCheckedAt ?? null;
    const list = {
      rooms: rows, currentRoomId: app.roomOpen ? app.current : null,
      onSelect: openRoomScreen, onOpenMenu: openMenu, onOpenJoin: openJoin, onOpenCreate: openCreate, onOpenBox: toggleBox,
      orderEditing: app.orderEditing, onToggleOrderEdit: toggleOrderEdit, onMoveRoom: moveRoomInList,
      sync: {lastSyncAt: anySynced, offlineSince: app.offlineAt, reconnecting: relay.offline},
      notice: app.notice, deviceLabel: app.device,
      invites: inviteRows(), candidates: candidateRows(), notes: noteRows(), onOpenNotify: openNotify,
    };
    const R = app.roomOpen && app.current ? app.rooms.get(app.current) : null;
    const room = R ? (() => {
      const S = R.session.state;
      return {roomId: app.current, name: roomLabel(app.current), members: S.roster.slice(), joined: S.joined, halted: S.halted ? {...S.halted} : null,
        timeline: R.entries, draft: app.draft.get(app.current) ?? '',
        // status-v1(#560): 에이전트 「⏳ Working …」 임시 말풍선 — 타임라인 맨 아래, entries 밖(안 읽음·미리보기 제외).
        statuses: visibleStatuses(R.statuses).map(st => ({sender: st.sender, senderName: displayName(st.sender), text: st.text})), onSend: sendText, onAttach: sendAttachment, onOpenAttachment: e => e.load(), onRetryPreview: loadPreview,
        onBack: () => { app.roomOpen = false; render(); }, onOpenInvite: openInvite, onOpenMembers: openInvite, onOpenBox: toggleBox,
        consentRequired: consentRequired(R), onOpenConsent: () => openConsentSheet(app.current),
        // 입력 중 신호(#562): 글이 있으면 「입력 중」(3초에 한 번), 비우면 해제. 릴레이 응답은 보지 않는다.
        onDraft: text => { app.draft.set(app.current, text); writeDraft(storage, app.device, app.current, text); R.session.typing(text.trim().length === 0); },
        typing: typingLabel(S.typing, {device: app.device, actor: app.actor, roster: S.roster}),
        // 방별 알림(mute.go): 같은 사람의 모든 기기에 한 값. null(옛 릴레이·아직 모름)이면 머리글에 버튼이 없다.
        muted: S.joined && !S.halted ? S.muted : null, onToggleMute: () => toggleMute(app.current),
        notice: null, sending: app.sending || S.transferring,
        attachmentPending: R.session.attachmentPending ? {size: 0, onRetry: () => sendAttachment(null)} : null};
    })() : null;
    // 보관함(#544 D): 「첨부」 탭은 항상, 파일보관함 탭은 config.json 이 있을 때만. 첨부 목록은 화면 타임라인에서 매 paint 다시 센다.
    const box = {
      open: app.boxOpen, tab: app.filebox ? app.boxTab : 'attachments',
      attachments: collectAttachments(app.rooms, {roomLabel}),
      filebox: app.filebox ? {url: app.filebox.url, title: app.filebox.title, refresh: app.boxRefresh} : null,
      onToggle: toggleBox, onTab: tab => { app.boxTab = tab === 'filebox' ? 'filebox' : 'attachments'; render(); },
      onRefresh: () => { app.boxRefresh += 1; render(); },
      onOpen: openAttachmentFromBox, onDownload: e => e.load(),
    };
    ui.renderShell(root, {list, room, box});
    // 보관함에서 고른 첨부로 이동 — 방 화면이 그려진 뒤에만(새 방이면 mount 가 맨 아래로 내린 뒤 덮어쓴다).
    if (app.pendingJump && app.roomOpen && app.current === app.pendingJump.roomId) {
      const {key} = app.pendingJump; app.pendingJump = null;
      if (!ui.jumpToEntry(root, key)) status(strings.chat.lastSent.notLoaded, 'warn');
    }
  }

  // ---- timeline per room ----
  function addEntry(roomId, m) {
    const R = app.rooms.get(roomId);
    if (!R) return;
    // status-v1(#560): 보낸이의 다음 일반 메시지(답·첨부)가 오면 그 보낸이의 작업 상태 말풍선은 끝난다.
    if (m.sender && m.kind !== 'system') clearStatusOnMessage(R.statuses, m.sender, m.seq);
    const key = m.key ?? (m.seq !== null && m.seq !== undefined ? `seq-${m.seq}` : `sys-${R.entries.length}`);
    if (R.entryKeys.has(key)) return;
    R.entryKeys.add(key);
    const entry = {key, kind: m.kind, seq: m.seq ?? null, sender: m.sender ?? '', senderName: m.sender ? displayName(m.sender) : '',
      isMe: isMine(m.sender, {device: app.device, actor: app.actor}), isAgent: m.sender ? isAgentDevice(m.sender) : false, body: m.text ?? '', ts: m.ts ?? null,
      size: m.size ?? 0, image: null, replay: !!m.replay, load: m.load ?? null, fileName: m.fileName ?? null,
      previewFailed: false, previewBusy: false};
    R.entries.push(entry);
    R.entries.sort((a, b) => (a.seq ?? Infinity) - (b.seq ?? Infinity) || 0);
    // 안 읽음은 readSeq 로 판정한다(#541) — 새로고침 뒤 다시 들어오는 보관 이력이 N 배지를 켜지 않게. 열린 방이면 바로 본 것.
    if (app.roomOpen && app.current === roomId) markRoomRead(roomId);
    // 미리보기(attachment-view.js: 한도 안, 내용 판별만). 실패는 entry.previewFailed 로 남아 말풍선의 「다시 시도」가 다시 부른다(#544 B).
    loadPreview(entry);
    render();
  }
  const loadPreview = createPreviewLoader({createUrl: (bytes, type) => URL.createObjectURL(new Blob([bytes], {type})), onChange: render});

  // ---- rooms ----
  function newSession(roomId) {
    return createRoomSession({room: roomId, device: app.device, database: databaseFor(roomId), worker, relay, storage, on: {
      change: () => { mergeRelayRead(roomId); render(); },
      message: m => addEntry(roomId, m),
      status: m => { const R = app.rooms.get(roomId); if (R && applyStatus(R.statuses, m)) render(); },
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
    R = {session, entries: [], entryKeys: new Set(), statuses: createStatusBoard(), readSeq: readReadSeq(storage, app.device, roomId), order: app.rooms.size,
      consented: readConsent(storage, app.device, roomId)};   // AI 참여 동의(#544 E) — 이 기기·이 방
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
    app.current = roomId; app.roomOpen = true; markRoomRead(roomId); render();
    promptConsentOnce(roomId);
  }
  // ---- AI 참여 동의(#544 E 선택지 3): 명단에 에이전트가 있고 이 기기의 동의 기록이 없으면 방을 처음 열 때 시트, 동의 전 작성창 잠금 ----
  const consentRequired = R => needsConsent({roster: R.session.state.roster, consented: R.consented});
  /** 페이지 세션에서 방마다 한 번만 자동으로 띄운다 — 「나중에」를 눌렀으면 게이트의 「안내 보기」로만 다시 연다. */
  function promptConsentOnce(roomId) {
    const R = app.rooms.get(roomId);
    if (!R || !consentRequired(R) || app.consentPrompted.has(roomId)) return;
    app.consentPrompted.add(roomId);
    openConsentSheet(roomId);
  }
  function openConsentSheet(roomId) {
    const R = app.rooms.get(roomId);
    if (!R) return;
    ui.openConsentSheet(root, {roomName: roomLabel(roomId), agentNames: agentsIn(R.session.state.roster).map(displayName), onClose: () => {},
      onConsent: () => {
        R.consented = true;
        if (!writeConsent(storage, app.device, roomId)) logLine(`동의 저장 실패(${roomId}) — 이번 화면에서만 유효`);
        status(strings.consent.done, 'ok'); render();
      }});
  }
  /**
   * 이 방을 화면 타임라인의 마지막 seq 까지 봤다(iOS LocalPrefs.markRead — 줄어들지 않음, 이 기기 localStorage).
   * 릴레이에도 알린다(#571 B, `POST /read`) — 같은 사람의 다른 기기에서 N 배지가 꺼지도록.
   */
  function markRoomRead(roomId) {
    const R = app.rooms.get(roomId);
    if (!R) return;
    R.readSeq = writeReadSeq(storage, app.device, roomId, latestSeq(R.entries), R.readSeq);
    R.session.markRead(R.readSeq);
  }
  /** 릴레이가 아는 같은 사람(actor)의 읽음 위치(#571 B, `GET /events` read_seq)를 이 기기 값과 합친다 — 다른 기기에서 읽었으면 여기서도 배지가 꺼진다. */
  function mergeRelayRead(roomId) {
    const R = app.rooms.get(roomId);
    if (!R) return;
    const relaySeq = R.session.state.readSeq;
    if (Number.isSafeInteger(relaySeq) && relaySeq > R.readSeq) R.readSeq = writeReadSeq(storage, app.device, roomId, relaySeq, R.readSeq);
  }

  // ---- phases ----
  async function boot() {
    if (!globalThis.Worker || !globalThis.WebAssembly || !globalThis.indexedDB) { fatal(strings.app.workerUnavailable); return; }
    const config = await loadConfig();
    if (typeof config.defaultRoom === 'string' && ROOM.test(config.defaultRoom)) app.defaultRoom = config.defaultRoom;
    app.filebox = fileboxConfig(config.filebox, {defaultTitle: strings.box.tabFilebox});
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
    refreshMe().then(render);
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
      if (window.matchMedia?.('(min-width: 900px)').matches && app.rooms.size) { app.current = [...app.rooms.keys()][0]; app.roomOpen = true; markRoomRead(app.current); promptConsentOnce(app.current); }
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
      const meDue = app.meTick++ % ME_EVERY_TICKS === 0;
      if (meDue) await refreshMe();
      let listed;
      try { listed = await app.dev.rooms(); } catch (error) { logLine(`방 목록 실패: ${error.message}`); listed = undefined; }
      app.lastCheckedAt = clock(true);
      if (listed === null) {
        // 403: not on the chain yet — post this device into the relay's candidate mailbox for a sibling to approve
        // (#574), or keep waiting for the operator. Returns the rooms list once the chain carries this device.
        listed = await enrollTick(!meDue);
        if (!Array.isArray(listed)) { render(); return; }
      }
      if (Array.isArray(listed)) {
        app.relayRooms = new Set(listed.filter(r => r.member && ROOM.test(r.room)).map(r => r.room));
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
      await discoverCandidates();
      await processSiblingInvites();
    } finally { refreshing = false; render(); }
  }
  // ---- device self-service (#574 PR 2b) ----
  /** GET /v2/me → app.me (subject · policy_revision · my devices). An old relay gives only {subject}; 404 (access off) gives null. */
  async function refreshMe() {
    try {
      const info = await relay.meInfo();
      app.me = info;
      if (typeof info?.subject === 'string') app.subject = info.subject;
    } catch (error) { logLine(`/v2/me 실패: ${error.message}`); }
  }
  /**
   * Enrollment tick on the 403 path. Refreshes /v2/me (unless this tick already did) — when the chain now lists this
   * device as active, re-asks the rooms list and hands it back so the same refresh continues into the ready phase.
   * Otherwise (re-)posts the candidate: first time, and again ~5 min before the 10-min TTL runs out. 404 → the relay has
   * no self-service (old relay / access disabled): operator flow, never asked again. 409 device_exists → id-taken.
   * 403 first_device_out_of_band → operator flow, re-checked every few minutes in case a sibling got enrolled meanwhile.
   */
  async function enrollTick(refreshMeFirst) {
    const E = app.enroll, now = Date.now();
    if (refreshMeFirst) await refreshMe();
    if (recordOf(app.me, app.device)?.status === 'active') {
      try {
        const listed = await app.dev.rooms();
        if (Array.isArray(listed)) { logLine('체인에 이 기기가 올라왔다 — 대화 화면으로'); E.mode = 'operator'; E.expiresAt = null; return listed; }
      } catch (error) { logLine(`방 목록 실패: ${error.message}`); }
    }
    if (E.mode === 'id-taken' || app.dev.state.selfService.unsupported || now < E.nextPostAt) return null;
    let r;
    try { r = await app.dev.postCandidate(); } catch (error) { logLine(`후보 게시 실패: ${error.message}`); return null; }
    const mode = enrollModeFrom(r.status, r.body);
    if (mode !== E.mode) logLine(`등록 화면 모드 ${E.mode} → ${mode} (${relay.describe(r.status, r.body)})`);
    E.mode = mode;
    if (r.status === 201) {
      E.expiresAt = app.dev.state.selfService.posted?.expiresAt ?? null;
      E.nextPostAt = E.expiresAt ? E.expiresAt - CANDIDATE_REPOST_MARGIN_MS : now + CANDIDATE_REPOST_MARGIN_MS;
      logLine(`후보 게시: 다른 기기의 승인을 기다린다(정책 revision ${r.body?.policy_revision ?? '?'}, 만료 ${E.expiresAt ? clock(true, new Date(E.expiresAt)) : '?'})`);
    } else if (r.status === 409) { E.expiresAt = null; E.nextPostAt = Infinity; }
    else if (r.status === 404) { E.expiresAt = null; logLine('릴레이에 기기 셀프서비스 없음 — 운영자 등록 흐름'); }
    else { E.expiresAt = null; E.nextPostAt = now + CANDIDATE_REPOST_MARGIN_MS; }
    return null;
  }
  /** Candidate mailbox (every tick while this device may approve): same-actor rows only, minus the ones ignored this page session. */
  async function discoverCandidates() {
    if (!app.me || !canApprove(app.me, app.device)) { app.candidates = []; return; }
    let list;
    try { list = await app.dev.listCandidates(); } catch (error) { logLine(`기기 후보 조회 실패: ${error.message}`); return; }
    if (!list) { app.candidates = []; return; }
    app.candidateRevision = Number.isSafeInteger(list.policy_revision) ? list.policy_revision : null;
    const rows = candidatesFor(list, app.actor).filter(c => !app.dismissedCandidates.has(c.device_id));
    for (const c of rows) if (!app.candidates.some(x => x.device_id === c.device_id)) logLine(`새 기기 승인 요청: ${c.device_id} (지문 ${c.fingerprint.slice(0, 8)}…)`);
    app.candidates = rows.map(c => ({...(app.candidates.find(x => x.device_id === c.device_id) ?? {}), ...c}));
  }
  function candidateRows() {
    return app.candidates.map(c => ({deviceId: c.device_id, actor: c.actor, fingerprint: c.fingerprint, expiresAt: Number.isFinite(c.expires_at) ? c.expires_at * 1000 : null,
      busy: !!c.busy, message: c.message ?? null,
      onApprove: () => openRelayApprove(c.device_id),
      onIgnore: () => { app.dismissedCandidates.add(c.device_id); app.candidates = app.candidates.filter(x => x.device_id !== c.device_id); render(); }}));
  }
  /**
   * Approve a mailbox candidate: recompute the fingerprint locally from signing_key (policy_fingerprint) and refuse when it
   * differs from what the relay relayed, then the approve sheet's compare step (relay mode) → signApproval → POST.
   */
  async function openRelayApprove(deviceId) {
    const c = app.candidates.find(x => x.device_id === deviceId);
    if (!c || c.busy) return;
    let fingerprint;
    try { fingerprint = await app.dev.policyFingerprint(c.signing_key); }
    catch (error) { c.message = strings.candidates.signFailed(error.message); render(); return; }
    if (fingerprint !== c.fingerprint) {
      c.message = strings.candidates.mismatch;
      logLine(`후보 ${deviceId} 지문 불일치: 릴레이 ${c.fingerprint} ≠ 로컬 ${fingerprint} — 승인하지 않음`);
      render();
      return;
    }
    ui.openApproveSheet(root, {mode: 'relay', candidate: {deviceId, fingerprint}, onApprove: () => approveViaRelay(c, fingerprint), onClose: () => {}});
  }
  async function approveViaRelay(c, fingerprint) {
    c.busy = true; c.message = null; render();
    try {
      let base = app.candidateRevision ?? app.me?.policy_revision ?? null;
      for (let attempt = 0; attempt < 2; attempt++) {
        if (!Number.isSafeInteger(base) || base < 1) throw new Error(strings.room.candidateMissing('base_revision'));
        const args = approvalArgs(c, base);
        let signature;
        try { signature = await app.dev.signApproval(JSON.stringify(args)); }
        catch (error) { throw new Error(strings.candidates.signFailed(error.message)); }
        const r = await app.dev.postApproval(approvalEvidence(args, signature, fingerprint, app.device));
        if (r.status === 201) {
          logLine(`${c.device_id} 승인 → 체인 revision ${r.body?.revision ?? '?'} (approved_by ${r.body?.approved_by ?? app.device})`);
          app.candidates = app.candidates.filter(x => x.device_id !== c.device_id);
          status(strings.candidates.approved(c.device_id), 'ok');
          await refreshMe();
          queueSiblingInvites(c.device_id);
          return;
        }
        if (r.status === 409 && r.body?.error === 'stale_revision' && attempt === 0) {
          logLine(`${strings.candidates.stale} (revision ${base} → ${r.body.revision ?? '?'})`);
          base = Number.isSafeInteger(r.body.revision) ? r.body.revision : null;
          if (base === null) { await refreshMe(); base = app.me?.policy_revision ?? null; }
          continue;
        }
        throw new Error(strings.candidates.rejected(r.body?.detail || relay.describe(r.status, r.body)));
      }
    } catch (error) { c.message = error.message; logLine(`${c.device_id} 승인 실패: ${error.message}`); throw error; }
    finally { c.busy = false; render(); }
  }
  const roomsView = () => [...app.rooms.entries()].map(([roomId, R]) => { const S = R.session.state; return {roomId, joined: S.joined, halted: S.halted, pending: S.pending, roster: S.roster}; });
  /** After approving a sibling: remember the rooms it should join; the queue is worked at the end of every refresh. */
  function queueSiblingInvites(target) {
    const rooms = siblingInviteRooms(roomsView(), target);
    if (!rooms.length) return;
    if (!writeSiblingQueue(storage, app.device, enqueueSiblingInvites(readSiblingQueue(storage, app.device), target, rooms, Date.now()))) logLine('형제 기기 초대 대기열 저장 실패 — 이번 화면에서만 시도');
    logLine(`형제 기기 ${target} 초대 대기열: ${rooms.join(', ')}`);
  }
  /**
   * Sibling invites (#574): a freshly approved device publishes its lobby keys only on its next tick, so the first
   * invite usually fails with noKeyPackage — keep the room queued and retry next tick; give up after 30 min with a 🔔 note.
   */
  async function processSiblingInvites() {
    const queue = readSiblingQueue(storage, app.device);
    if (!queue.length) return;
    const {live, expired} = splitSiblingQueue(queue, Date.now());
    for (const e of expired) {
      logLine(`형제 기기 ${e.target} 초대 포기(30분): ${e.rooms.join(', ')}`);
      addNote(`sibling-expired:${e.target}`, strings.candidates.siblingGaveUp(e.target, e.rooms.map(roomLabel).join(', ')), 'warn');
    }
    const next = [];
    for (const e of live) {
      const remaining = [];
      for (const roomId of e.rooms) {
        const R = app.rooms.get(roomId);
        if (!R) continue;   // room gone from this device — nothing to invite into
        const S = R.session.state;
        if (!siblingInviteRooms([{roomId, joined: S.joined, halted: S.halted, pending: S.pending, roster: S.roster}], e.target).length) {
          if (S.pending && S.joined && !S.halted) remaining.push(roomId);   // my own commit still pending → next tick
          continue;   // already a member / halted / not joined — done
        }
        try {
          await R.session.invite(e.target);
          logLine(strings.candidates.siblingInvited(e.target, roomId));
          status(strings.candidates.siblingInvited(e.target, roomLabel(roomId)), 'ok');
        } catch (error) {
          if (isRetryableInviteError(error, [strings.room.noKeyPackage(e.target), strings.room.pendingCommit, strings.room.commitRaced])) remaining.push(roomId);
          else { logLine(`형제 기기 ${e.target} 초대 실패(${roomId}, 포기): ${error.message}`); addNote(`sibling-failed:${e.target}:${roomId}`, strings.candidates.siblingFailed(e.target, roomLabel(roomId), error.message), 'danger'); }
        }
      }
      if (remaining.length) next.push({...e, rooms: remaining});
    }
    writeSiblingQueue(storage, app.device, next);
  }
  function addNote(key, text, tone = 'info') {
    if (app.notes.some(n => n.key === key)) return;
    app.notes.push({key, text, tone});
    render();
  }
  function noteRows() {
    return app.notes.map(n => ({key: n.key, text: n.text, tone: n.tone, onDismiss: () => { app.notes = app.notes.filter(x => x.key !== n.key); render(); }}));
  }
  /** 「내 기기」 sheet (#574 E5): my chain records + grant/release registrar via sign_roles → POST /v2/devices/roles. */
  const devicesView = () => (Array.isArray(app.me?.devices) ? rolesActions(app.me, app.device) : null);
  function openDevices() {
    ui.openDevicesSheet(root, {view: devicesView(), onGrant: id => setRoles(id, true), onRelease: id => setRoles(id, false), onClose: () => {}});
  }
  async function setRoles(targetId, grant) {
    let base = app.me?.policy_revision ?? null;
    for (let attempt = 0; attempt < 2; attempt++) {
      const target = recordOf(app.me, targetId);
      if (!target) throw new Error(strings.devices.empty);
      if (!Number.isSafeInteger(base) || base < 1) throw new Error(strings.room.candidateMissing('base_revision'));
      const args = rolesArgs(target, nextRoles(target.roles, grant), base);
      let signature;
      try { signature = await app.dev.signRoles(JSON.stringify(args)); }
      catch (error) { throw new Error(strings.candidates.signFailed(error.message)); }
      const r = await app.dev.postRoles(rolesEvidence(args, signature, app.device));
      if (r.status === 201) {
        logLine(`${targetId} roles=${JSON.stringify(args.roles)} → 체인 revision ${r.body?.revision ?? '?'}`);
        status(strings.devices.done(targetId, grant), 'ok');
        await refreshMe(); render();
        return devicesView();
      }
      if (r.status === 409 && r.body?.error === 'stale_revision' && attempt === 0) {
        logLine(`${strings.candidates.stale} (revision ${base} → ${r.body.revision ?? '?'})`);
        await refreshMe();   // the target's current roles may have moved too — re-read before re-signing
        base = Number.isSafeInteger(r.body.revision) ? r.body.revision : (app.me?.policy_revision ?? null);
        continue;
      }
      throw new Error(strings.devices.rejected(r.body?.detail || relay.describe(r.status, r.body)));
    }
    return devicesView();
  }
  /**
   * 탭·온라인·bfcache 복귀 직후 한 번(#544 A): ⚙ 「지금 동기화」와 같은 경로를 조용히 — 기기 refresh 뒤 방별 sync({quiet}).
   * refresh 의 `refreshing`·방의 `S.busy` 가드가 있어 폴링과 겹쳐도 안전하다. 시작 전·지운 뒤(dev.stop)에는 아무것도 하지 않는다.
   */
  async function resumeSync() {
    if (!app.dev?.state.started) return;
    logLine('복귀 동기화(탭·온라인·페이지 복귀)');
    try { await refresh(); } catch (_) { /* refresh 가 자체 로그를 남긴다 */ }
    await Promise.all([...app.rooms.values()].map(R => R.session.sync({quiet: true}).catch(() => {})));
    render();
  }
  async function discoverLobbyWelcomes() {
    let welcomes;
    try { welcomes = await app.dev.welcomes(); } catch (error) { logLine(`로비 초대 조회 실패: ${error.message}`); return; }
    const invites = [];
    const refs = {set: new Set(), complete: true};
    // One room can hold several unread Welcomes for this device (the invite before a remove +
    // re-invite stays in the log until the cursor passes it). Only the newest is openable —
    // the older ones' lobby secrets are gone — so adopt per room from the highest seq (#530).
    const newest = new Map();
    for (const w of welcomes) if (ROOM.test(w.room) && Number.isSafeInteger(w.seq) && (!newest.has(w.room) || newest.get(w.room).seq < w.seq)) newest.set(w.room, w);
    for (const w of newest.values()) {
      const R = app.rooms.get(w.room);
      if (R && R.session.joined) continue;   // joined already — the next ack drops it from the list
      if (typeof w.key_package_ref === 'string' && w.key_package_ref) refs.set.add(w.key_package_ref); else refs.complete = false;
      if (app.dismissed.has(w.room) || invites.some(i => i.room === w.room)) continue;
      // Owner devices auto-join, and so does any device whose Welcome came from its own sibling (same actor, active on
      // the chain — #574: the sibling that approved this device invites it into every room it was in).
      if (AUTO_JOIN_ACTORS.has(app.actor) || isSibling(w.from, app.me, app.actor, app.device)) {
        // A failure is not silent — the invite stays in the 🔔 list
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
  /** 🔔 시트의 「진단 기록 복사」: 최근 기록 200줄 + 기기·방 상태 요약을 클립보드로 — DevTools 없이 원인 보고(#535). */
  function copyDiagnostics() {
    const rooms = [...app.rooms.entries()].map(([id, R]) => { const S = R.session.state; return `${id}: joined=${S.joined} halted=${!!S.halted} relaySeq=${S.relaySeq} epoch=${S.epoch} pending=${S.pending}`; });
    const invites = app.invites.map(i => `${i.room}: seq ${i.seq} ${i.failed ? `failed ${i.failed.tries}x (${i.failed.reason ?? '-'})` : i.busy ? 'busy' : 'new'}`);
    const me = app.me ? `me: subject=${app.me.subject} policy_revision=${app.me.policy_revision ?? '-'} devices=${(app.me.devices ?? []).map(d => `${d.device_id}(${d.status}${d.roles?.length ? ',' + d.roles.join('+') : ''})`).join(' ') || '-'}` : 'me: -';
    const candidates = app.candidates.map(c => `${c.device_id}: fp ${c.fingerprint.slice(0, 8)}… ${c.busy ? 'busy' : c.message ? `error ${c.message}` : 'new'}`);
    const text = [`hande web diagnostics ${clock(true)} device=${app.device} actor=${app.actor} enroll=${app.enroll.mode}`, me, 'rooms:', ...rooms, 'invites:', ...invites, 'candidates:', ...candidates, 'log:', ...app.logs.slice(-200)].join('\n');
    return copy(text);
  }
  function openNotify() { ui.openNotifySheet(root, {invites: inviteRows(), candidates: candidateRows(), notes: noteRows(), onCopyLogs: copyDiagnostics, onClose: () => {}}); }

  // ---- actions ----
  const cur = () => app.rooms.get(app.current)?.session;
  async function guard(run) {
    try { return await run(); }
    catch (error) { status(error.message, 'danger'); throw error; }
  }
  async function sendText(text) {
    const s = cur();
    if (!s || app.sending) return false;
    if (consentRequired(app.rooms.get(app.current))) { status(strings.consent.blocked, 'warn'); openConsentSheet(app.current); return false; }
    app.sending = true; render();
    // 초안은 작성창이 보내기 직전에 이미 비웠다(ui.js onDraft('')). 전송이 끝난 뒤 다시 비우면 그 사이 더 쓴 글이나 —
    // `await` 동안 다른 방으로 옮겼다면 — 그 방의 초안까지 지운다. 보낸 방은 시작 때 잡아 둔다.
    const roomId = app.current;
    try { await s.send(text); markRoomRead(roomId); return true; }
    catch (error) { status(error.message, 'danger'); return false; }
    finally { app.sending = false; render(); }
  }
  async function sendAttachment(file) {
    const s = cur();
    if (!s) return;
    if (consentRequired(app.rooms.get(app.current))) { status(strings.consent.blocked, 'warn'); openConsentSheet(app.current); return; }
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
      ...(devicesView() ? [{label: strings.menu.devices, run: openDevices, testid: 'menu-devices'}] : []),
      {label: strings.menu.approve, run: openApprove},
      {label: strings.menu.sync, run: () => refresh().then(() => Promise.all([...app.rooms.values()].map(R => R.session.sync()))).then(render)},
      {label: strings.menu.wipe, run: confirmWipe, tone: 'danger'},
    ], onClose: () => {}});
  }
  function openSettings() {
    const reg = JSON.stringify(app.dev.registration(app.subject), null, 1);
    ui.openSettingsSheet(root, {deviceId: app.device, actor: app.actor, fingerprint: app.dev.state.fingerprint, subject: app.subject,
      origin: location.host, onCopyRegistration: () => copy(reg), onOpenApprove: openApprove, onOpenDevices: devicesView() ? openDevices : null, onWipe: confirmWipe, onClose: () => {},
      theme: theme ? theme.get() : null, onTheme: theme ? value => theme.set(value) : null});
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
    const roomId = app.current;
    ui.openInviteSheet(root, {roomId, roomName: roomLabel(roomId), members: s.state.roster.slice(), selfDevice: app.device, busy: false, message: null, onClose: () => {},
      onInvite: async target => { await guard(() => s.invite(target)); status(strings.room.inviteDone(target), 'ok'); },
      onRemove: async target => { await guard(() => s.remove(target)); status(strings.room.removeDone(target), 'ok'); },
      // 릴레이에 없는 로컬 전용 방(참여 요청만·방금 만든 방)만 지울 수 있다 — 릴레이 멤버 방은 다음 refresh 에 다시 열리므로 버튼을 두지 않는다.
      onForget: isLocalOnlyRoom(roomId, app.relayRooms) ? () => guard(() => forgetRoom(roomId)) : null});
  }
  /** 로컬 전용 방을 이 기기에서 지운다: 워커 스토어 reset·close → localStorage 키·알려진 목록·순서 → IndexedDB(최선 노력) → 화면. */
  async function forgetRoom(roomId) {
    const R = app.rooms.get(roomId);
    if (!R || !isLocalOnlyRoom(roomId, app.relayRooms)) throw new Error(strings.forget.hint);
    const database = databaseFor(roomId);
    try { await R.session.wipe(); } catch (error) { logLine(`방 ${roomId} 스토어 초기화 실패(계속 진행): ${error.message}`); }
    R.session.stop();
    for (const e of R.entries) if (e.image) URL.revokeObjectURL(e.image.url);
    app.rooms.delete(roomId); writeKnown();
    app.draft.delete(roomId); app.consentPrompted.delete(roomId);
    app.roomOrder = app.roomOrder.filter(id => id !== roomId); writeRoomOrder(storage, app.device, app.roomOrder);
    forgetRoomKeys(storage, {device: app.device, room: roomId, database});
    if (app.current === roomId) { app.current = null; app.roomOpen = false; }
    render();
    for (const name of [database, `${database}-history`]) await deleteDb(name);   // close_room 뒤라 보통 바로 지워진다; 막히면 다음 시작에 비어 있는 채로 남는다
    logLine(`방 ${roomId} 을 이 기기에서 지움(로컬 전용)`);
    status(strings.forget.done(roomLabel(roomId)), 'ok');
  }
  function openApprove() {
    let candidate = null;
    ui.openApproveSheet(root, {
      onOffer: async json => {
        const c = JSON.parse(json);
        for (const k of ['device_id', 'actor', 'subject', 'signing_key']) if (!(k in c)) throw new Error(strings.room.candidateMissing(k));
        if (!/^[a-f0-9]{64}$/.test(c.signing_key)) throw new Error(strings.room.candidateKeyInvalid);
        // base_revision in the pasted JSON is optional since #574: the relay tells us the current policy revision (GET /v2/me).
        const base = c.base_revision ?? app.me?.policy_revision ?? null;
        if (base === null || base === undefined) throw new Error(strings.room.candidateMissing('base_revision'));
        const fingerprint = await app.dev.policyFingerprint(c.signing_key);
        candidate = {...c, base_revision: base, fingerprint};
        return {deviceId: c.device_id, fingerprint};
      },
      onApprove: async () => {
        if (!candidate) throw new Error('먼저 등록 JSON을 붙여 넣어 지문을 확인하세요');
        const args = approvalArgs(candidate, candidate.base_revision);
        let signature;
        try { signature = await app.dev.signApproval(JSON.stringify(args)); }
        catch (error) { throw new Error(strings.candidates.signFailed(error.message)); }
        const evidence = approvalEvidence(args, signature, candidate.fingerprint, app.device);
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
      // 화면 테마(hande:theme)는 암호화 상태·기록·기기 ID 가 아니라 이 화면의 보기 설정이라 남긴다.
      for (const k of Object.keys(storage)) if (k.startsWith('hande:') && k !== 'hande:identity' && k !== 'hande:theme') storage.removeItem(k);
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
  // 탭·온라인·bfcache 복귀 즉시 동기화(#544 A, 패밀리챗 installSyncRecovery): 백그라운드 탭의 늦춰진 타이머를 기다리지 않는다.
  installSyncRecovery({document, window, resume: () => { resumeSync().catch(() => {}); }});
  boot().catch(error => fatal(error.message));
  return {get state() { return app; }};
}
