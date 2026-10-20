// One room on this device: the relay-app.js flow (#243 2-a) as a session object the
// hande screens drive. The processing order is the one the bot (session.rs
// poll_room) and iOS (RoomSyncEngine) follow:
//   own commit echo → merge_pending (+ targeted Welcome) · Welcome before joining →
//   join · foreign commit → stage_commit → policy check ①~④ → merge_staged /
//   discard_staged + ⛔ halt (#261) · application → decrypt → sealed history (#370).
// Reads never move the relay cursor; an explicit ?ack= after everything up to seq is
// durably processed. Trust comes from the facade (AAD binding, pinned keys) and the
// relay (policy chain, JWT ↔ device subject); this module moves bytes and keeps the
// durable page state (#296: per room + device + database).
// #431 stage 4: the worker runs in multi-store mode (one worker `device`, room-scoped
// messages); this session owns one room store derived from the identity store (or the
// lobby store when the room's Welcome was built from a lobby key package).
import {parseStageReport, checkCommit, outerForCommit, resolveUncertainPending} from './commit-policy.js';
import {attachmentOutbox, isAttachment} from './relay-attachments.js';
import {strings} from './strings.js';
import {actorOf, DEVICE} from './identity.js';

export const WORKER = 'device';

const utf8 = new TextEncoder(), decoder = new TextDecoder();
export const b64 = bytes => {
  const view = new Uint8Array(bytes);
  let binary = '';
  for (let at = 0; at < view.length; at += 8192) binary += String.fromCharCode.apply(null, view.subarray(at, at + 8192));
  return btoa(binary);
};
export const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
export const hex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
const genId = () => Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
/** One facade operation on a room store (ledger item acked unless transient / deferred). */
export async function op(worker, room, method, bytes = [], sequence = 0, {deferAck = false, onAckError = () => {}} = {}) {
  const id = genId();
  const value = await worker.call(WORKER, 'operation', {room, id, method, bytes: Array.from(bytes), sequence, fault: ''});
  if (!value.ok) throw new Error(`${method} 거부`);
  const result = value.result;
  const ack = async () => { try { const a = await worker.call(WORKER, 'ack', {room, ids: [id]}); if (!a.ok) onAckError(new Error('ack 거부')); } catch (error) { onAckError(error); } };
  if (!result.transient) { if (deferAck) result.ack = ack; else await ack(); }
  result.ack ??= async () => {};
  return result;
}
const two = n => String(n).padStart(2, '0');
export const clock = (seconds = false, d = new Date()) => `${two(d.getHours())}:${two(d.getMinutes())}` + (seconds ? `:${two(d.getSeconds())}` : '');

// Framed member list (u32 count, then u32 len ‖ identity ‖ 32-byte key).
export function parseMembers(framed) {
  const bytes = new Uint8Array(framed), view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const count = view.getUint32(0, true);
  let at = 4; const out = [];
  for (let i = 0; i < count; i++) {
    const n = view.getUint32(at, true); at += 4;
    out.push(decoder.decode(bytes.subarray(at, at + n))); at += n + 32;
  }
  return out;
}
// Same framing, keeping the 32-byte signature key: `remove_pending` addresses a
// member by that key (#289), never by the display identity alone.
export function parseMemberKeys(framed) {
  const bytes = new Uint8Array(framed), view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const count = view.getUint32(0, true);
  let at = 4; const out = new Map();
  for (let i = 0; i < count; i++) {
    const n = view.getUint32(at, true); at += 4;
    const id = decoder.decode(bytes.subarray(at, at + n)); at += n;
    out.set(id, bytes.slice(at, at + 32)); at += 32;
  }
  return out;
}
const membersWire = devices => devices.slice().sort().map(device => ({device, actor: actorOf(device)}));
// owner-web-1a2b3c → owner-web-1a2b3c-2 → …-3 (inside the relay identifier grammar).
export function nextDeviceId(dev) {
  const m = /^(.*)-(\d+)$/.exec(dev);
  const next = m ? `${m[1]}-${Number(m[2]) + 1}` : `${dev}-2`;
  return next.length <= 64 ? next : next.slice(0, 64);
}

/**
 * @param {object} deps
 * @param {string} deps.room  relay room id
 * @param {string} deps.device  this device id (actor = part before the first '-')
 * @param {string} deps.database  durable worker database name
 * @param {{spawn, call, stop}} deps.worker  worker bridge; the worker name is `room:<room>`
 * @param {{api, roomPath, describe}} deps.relay
 * @param {Storage} deps.storage  localStorage (page state, attachment outbox)
 * @param {object} deps.on  callbacks: change(), message(entry), log(text), notice(text, tone), synced(), offline(bool)
 * @param {object} [deps.policy]  commit policy functions (injectable for tests)
 */
export function createRoomSession({room, device, database, worker, relay, storage, on, policy = {parseStageReport, checkCommit, outerForCommit, resolveUncertainPending}, pollMs = 4000, setInterval: setI = globalThis.setInterval, clearInterval: clearI = globalThis.clearInterval}) {
    const S = {started: false, joined: false, pending: false,
    // #295 F4: epoch an invite/remove commit was built on when its POST outcome is unknown (else null).
    pendingUncertain: null,
    expectedRoster: null, pendingWelcome: null, relaySeq: 0, epoch: 0, wcursor: 0, roster: [], timer: null, busy: false,
    // #261: a refused commit halts this device (durable, operator decides); retriedSeq remembers one merge retry per relay seq.
    halted: null, retriedSeq: 0, failedSeq: 0, transferring: false,
    waiting403: false, syncedAt: null, fingerprint: '', publicKey: '', revision: 0, historyOn: false};
  let attachments = null;
  const stateKey = () => `hande:room:${room}:${device}:${database}`;
  const log = (...parts) => on.log?.(`${clock(true)} ${parts.join(' ')}`);
  const notify = (text, tone = 'info') => on.notice?.(text, tone);
  const changed = () => on.change?.();

  function save() {
    storage.setItem(stateKey(), JSON.stringify({joined: S.joined, pending: S.pending, expectedRoster: S.expectedRoster,
      pendingWelcome: S.pendingWelcome, pendingUncertain: S.pendingUncertain ?? null,
      relaySeq: S.relaySeq, epoch: S.epoch, roster: S.roster, halted: S.halted}));
  }
  function load() {
    try { const v = JSON.parse(storage.getItem(stateKey()) || 'null'); if (v) Object.assign(S, v); } catch (_) { /* ignore */ }
  }
  function resetState() {
    Object.assign(S, {joined: false, pending: false, pendingUncertain: null, relaySeq: 0, roster: [], expectedRoster: null, pendingWelcome: null, halted: null, epoch: 0});
  }

  // ---- worker (multi-store: every message carries this room) ----
  async function callWorker(method, argument) {
    const value = await worker.call(WORKER, method, {room, ...argument});
    if (!value.ok) throw new Error(`${method} 거부`);
    return value.result;
  }
  async function roomOp(method, bytes = [], sequence = 0, {deferAck = false} = {}) {
    // A transient operation (stage_commit, #261) has no ledger item to ack. A decrypt
    // (#370) acks only after its row is in the local history.
    const result = await op(worker, room, method, bytes, sequence, {deferAck, onAckError: error => log('ledger ack 실패:', error.message)});
    S.wcursor = result.cursor;
    return result;
  }
  let historyWarned = false;
  async function remember(row) {
    if (!S.historyOn) return;
    try { await callWorker('history_put', row); }
    catch (error) { if (!historyWarned) { historyWarned = true; log('대화 보관 실패 — 이 메시지는 새로고침 뒤 다시 보이지 않는다:', error.message); } }
  }
  async function restoreHistory() {
    if (!S.historyOn) return 0;
    let rows;
    try { rows = await callWorker('history_list', {limit: 500}); }
    catch (error) { log('보관된 대화를 읽지 못했다:', error.message); return 0; }
    for (const r of rows) {
      const ts = Number.isSafeInteger(r.received_at) ? r.received_at : null;
      if (r.kind === 'attachment') emitAttachment(r.sender, r.size, r.seq, ts, async () => new Uint8Array((await callWorker('history_get', {seq: r.seq})).bytes));
      else emitText(r.sender, r.client, r.text, r.seq, ts, false);
    }
    return rows.length;
  }
  function emitText(sender, client, text, seq, ts, replay) {
    on.message?.({kind: 'text', seq, sender, client: client ?? '', text, ts, replay: !!replay});
  }
  function emitAttachment(sender, size, seq, ts, loadBytes) {
    on.message?.({kind: 'attachment', seq, sender, client: '', text: '', size, ts, load: loadBytes});
  }
  function emitSystem(text, key) { on.message?.({kind: 'system', seq: null, text, key}); }

  // ---- relay ----
  const path = suffix => relay.roomPath(room, suffix);
  const describe = relay.describe;
  async function postEvent(kind, bytes, {targets, members, epoch} = {}) {
    const payload = {device, client_id: `${device}-${genId()}`, kind, epoch: epoch ?? S.epoch, bytes: b64(bytes)};
    if (targets) payload.targets = targets;
    if (members) payload.members = members;
    return relay.api('POST', path('events'), payload);
  }
  // #295 F4: POST an invite/remove commit whose answer may be lost — keep it pending
  // (marked uncertain, durable); the next sync decides (echo → merge, foreign commit
  // wins → forget, room still at this epoch → drop).
  async function postUncertain(commit, expected, pendingWelcome) {
    try {
      return await postEvent('commit', commit, {members: membersWire(expected)});
    } catch (error) {
      S.pending = true; S.pendingUncertain = S.epoch; S.expectedRoster = expected; S.pendingWelcome = pendingWelcome; save(); changed();
      log(`commit 게시 결과를 확인하지 못했다(${error.message}) — 다음 동기화가 반영 여부를 판정한다`);
      await sync({quiet: true});
      return null;
    }
  }

  // ---- sync (the smoke's Device.sync, in the browser) ----
  async function sync({quiet = false} = {}) {
    if (!S.started || S.busy || S.transferring || S.halted) return undefined;
    S.busy = true;
    try {
      const {status, body} = await relay.api('GET', path(`events?device=${encodeURIComponent(device)}&after=${S.relaySeq}`));
      if (status === 404 && body && body.error === 'no_such_room') { S.waiting403 = false; markSynced(); if (!quiet) log(strings.room.noRoomYet); return undefined; }
      if (status === 403) {   // not on the policy chain yet (#251 A-3): the enrollment screen waits
        if (!S.waiting403) log(`릴레이가 이 기기를 받지 않는다(${describe(status, body)}) — 운영자 등록 대기`);
        S.waiting403 = true; S.syncedAt = clock(true); changed();
        return undefined;
      }
      if (status !== 200) { if (!quiet) log('동기화 실패:', describe(status, body)); return undefined; }
      if (S.waiting403) { S.waiting403 = false; log('릴레이가 이 기기를 받아들였다(등록 완료)'); }
      if (body.first_seq > S.relaySeq + 1 && S.relaySeq > 0) notify(strings.room.historyGap(S.relaySeq + 1, body.first_seq - 1), 'warn');
      for (const ev of body.events) {
        const seqBefore = S.relaySeq;
        S.relaySeq = Math.max(S.relaySeq, ev.seq);
        if (ev.device === device) {
          if (ev.kind === 'commit' && S.pending) {
            await roomOp('merge_pending');
            S.pending = false; S.pendingUncertain = null;
            S.roster = S.expectedRoster || S.roster; S.expectedRoster = null;
            S.epoch = ev.epoch + 1; changed();
            log(`내 commit 반영(seq ${ev.seq}) — epoch 전진`);
            if (S.pendingWelcome) {
              const {target, welcome} = S.pendingWelcome; S.pendingWelcome = null;
              const r = await postEvent('welcome', unb64(welcome), {targets: [target], epoch: ev.epoch + 1});
              log(r.status === 201 ? `${target}에게 Welcome 전송` : `Welcome 전송 실패: ${describe(r.status, r.body)}`);
            }
          }
          continue;
        }
        const data = unb64(ev.bytes);
        if (!S.joined) {
          if (ev.kind === 'welcome') {
            await roomOp('join', data);
            S.joined = true; S.roster = parseMembers((await roomOp('members')).output); changed();
            log(`참여 완료(seq ${ev.seq}) — 멤버 ${S.roster.join(', ')}`);
          }
          continue;  // anything before our Welcome is not ours to read
        }
        if (ev.kind === 'welcome') { log(`무시: 이미 참여한 기기에 온 Welcome(seq ${ev.seq})`); continue; }
        if (ev.kind === 'commit') {
          // #261 two-step application: stage (authenticate + roster delta report), check
          // the delta against this device's roster and — when this commit is the latest
          // epoch — against the relay's enforced roster (#295), then merge; a refusal
          // discards (epoch unchanged) and halts this device.
          let report;
          try { report = policy.parseStageReport((await roomOp('stage_commit', data)).output); }
          catch (error) { log(`commit 거부(seq ${ev.seq}, ${ev.device}): ${error.message} — 이 기기는 방에서 빠졌을 수 있다`); continue; }
          const removesMe = report.removes.some(m => m.id === device);
          const outer = policy.outerForCommit({report, self: device, eventEpoch: ev.epoch, roomEpoch: body.epoch, members: body.members});
          const verdict = policy.checkCommit({report, roster: S.roster, committer: ev.device, outer});
          if (!verdict.ok) {
            try { await roomOp('discard_staged'); } catch (error) { log(`discard 실패: ${error.message}`); }
            halt(ev.seq, ev.device, verdict);
            break;
          }
          try { await roomOp('merge_staged'); } catch (error) {
            // The resident worker session was most likely rebuilt between stage and merge
            // (another tab wrote, worker restarted): fetch this seq again once.
            if (S.retriedSeq !== ev.seq) {
              S.retriedSeq = ev.seq; S.relaySeq = seqBefore;
              log(`commit 적용 실패(seq ${ev.seq}): ${error.message} — 다시 가져와 1회 재시도`);
              break;
            }
            log(`commit 거부(seq ${ev.seq}, ${ev.device}): ${error.message} — 이 기기는 방에서 빠졌을 수 있다`);
            continue;
          }
          if (removesMe) {   // #289: applied, not refused — this device is out
            halt(ev.seq, ev.device, {reason: 'removed_from_room', detail: ''});
            break;
          }
          if (S.pending) {
            // #295 F4: a foreign commit won the epoch our (uncertain) commit was built on;
            // merging it consumed our pending commit (OpenMLS, #239) — ours never landed.
            S.pending = false; S.pendingUncertain = null; S.expectedRoster = null; S.pendingWelcome = null;
            log(`내 commit은 반영되지 않았다(seq ${ev.seq} ${ev.device}의 commit이 먼저) — 필요하면 다시 시도`);
            notify(strings.room.commitRaced, 'warn');
          }
          S.roster = parseMembers((await roomOp('members')).output); changed();
          log(`commit 검증·적용(seq ${ev.seq}, ${ev.device}) — +${report.adds.map(m => m.id).join(',') || '없음'} −${report.removes.map(m => m.id).join(',') || '없음'}` +
            `${outer ? ' · 릴레이 로스터 일치' : ' · (이전 epoch: 내부 검사만)'} — 멤버 ${S.roster.join(', ')}`);
          continue;
        }
        // The durable worker binds the room itself (bindDecrypt from its own init).
        let out;
        try { out = await roomOp('decrypt', data, S.wcursor + 1, {deferAck: true}); }
        catch (error) {
          // A worker refusal (ledger capacity, store/session inconsistency, timeout) is
          // not a facade verdict: the store rolled back, the ciphertext is still readable.
          // Keep relaySeq at the last applied event so the quiet poll never acks past it
          // (2026-10-15 seq 127: a 1.27 MB photo was acked away unseen).
          S.relaySeq = seqBefore;
          if (S.failedSeq !== ev.seq) { S.failedSeq = ev.seq; log(strings.room.decryptFailed(ev.seq, ev.device) + `: ${error.message}`); }
          break;
        }
        if (out.rejected === true) { await out.ack(); log(`해독 거부 → 건너뜀(seq ${ev.seq}, ${ev.device})`); emitUndecryptable(ev); continue; }
        const sender = out.sender ?? ev.device, client = out.client ?? '';
        const ts = Number.isSafeInteger(ev.created_at) ? ev.created_at * 1000 : Date.now();
        if (isAttachment(ev.client_id)) {
          const bytes = new Uint8Array(out.output);
          emitAttachment(sender, bytes.length, ev.seq, ts, async () => bytes);
          await remember({seq: ev.seq, sender, client, kind: 'attachment', text: '', bytes: Array.from(bytes)});
        } else {
          const text = decoder.decode(new Uint8Array(out.output));
          emitText(sender, out.client, text, ev.seq, ts, out.replay);
          await remember({seq: ev.seq, sender, client, kind: 'text', text, bytes: []});
        }
        await out.ack();
      }
      S.epoch = body.epoch;
      if (S.pending && policy.resolveUncertainPending({pendingEpoch: S.pendingUncertain, roomEpoch: body.epoch}) === 'drop') {
        // #295 F4: the POST whose answer we lost never reached the relay.
        await roomOp('clear_pending');
        S.pending = false; S.pendingUncertain = null; S.expectedRoster = null; S.pendingWelcome = null;
        log('게시 결과를 몰랐던 내 commit은 릴레이에 없다 — 버렸다. 다시 시도하면 된다.');
      }
      if (S.joined && S.relaySeq > 0 && body.cursor < S.relaySeq) {
        const ack = await relay.api('GET', path(`events?device=${encodeURIComponent(device)}&after=${S.relaySeq}&ack=${S.relaySeq}`));
        if (ack.status !== 200 && !quiet) log('ack 실패:', describe(ack.status, ack.body));
      }
      save(); markSynced(); changed();
      return undefined;
    } catch (error) { if (!quiet) log('동기화 오류:', error.message); return error; }   // quiet polling: status line only
    finally { S.busy = false; }
  }
  function emitUndecryptable(ev) {
    on.message?.({kind: 'undecryptable', seq: ev.seq, sender: ev.device, client: '', text: '', ts: Number.isSafeInteger(ev.created_at) ? ev.created_at * 1000 : Date.now()});
  }
  function markSynced() { S.syncedAt = clock(true); on.synced?.(S.syncedAt); }
  // #261: a commit this device refuses to merge — loud, durable, final for this device.
  function halt(seq, committer, verdict) {
    S.halted = {seq, committer, reason: verdict.reason, detail: verdict.detail ?? '', at: clock(), removed: verdict.reason === 'removed_from_room'};
    save();
    stopPolling();
    const h = S.halted;
    emitSystem(h.removed ? strings.room.haltRemoved(seq, committer) : strings.room.haltRefused(seq, committer, h.reason + (h.detail ? ` (${h.detail})` : '')), `halt-${seq}`);
    log(h.removed ? `방에서 제거됨(seq ${seq}, ${committer}) — 이 기기는 더 읽지 않는다` : `⛔ commit 거부(seq ${seq}, ${committer}): ${h.reason}${h.detail ? ` — ${h.detail}` : ''}`);
    changed();
  }
  function stopPolling() { if (S.timer) { clearI(S.timer); S.timer = null; } }

  // ---- start / resume ----
  /**
   * Open this room's store in the (already started) multi-store worker. `from` picks the
   * clone source for a NEW store: 'identity' (group-less — create / room key package) or
   * 'lobby' (the lobby store's unused key package secrets, so the Welcome a lobby key
   * package produced can be joined). `replace` drops an existing group-less store first
   * (iOS LobbyKeyring.adoptRoom overwrites a state that never joined). `startSeq` rewinds
   * the relay cursor so that Welcome (seq) is read on the next sync. Resolves {fresh}.
   */
  async function open({from = 'identity', replace = false, startSeq = null} = {}) {
    if (S.transferring) throw new Error('첨부 전송 중');
    stopPolling();
    S.syncedAt = null;
    load();
    if (replace && !S.joined) {
      const r = await worker.call(WORKER, 'reset_room', {room, database});
      if (!r.ok) throw new Error('reset_room 거부');
      resetState(); storage.removeItem(stateKey());
    }
    const opened = await worker.call(WORKER, 'open_room', {room, database, from});
    if (!opened.ok) throw new Error('open_room 거부');
    S.historyOn = opened.result.history === true; historyWarned = false;
    S.publicKey = hex(Uint8Array.from(opened.result.public_key)); S.revision = opened.result.revision;
    S.fingerprint = hex(new Uint8Array(await crypto.subtle.digest('SHA-256', Uint8Array.from(opened.result.public_key))));
    S.wcursor = opened.result.cursor;
    if (opened.result.fresh) resetState();
    if (startSeq !== null && S.relaySeq >= startSeq) { S.relaySeq = startSeq - 1; S.joined = false; save(); }
    return {fresh: opened.result.fresh === true};
  }
  async function activate() {
    attachments = attachmentOutbox({storage, key: `hande:attachment:${database}:${room}:${device}`,
      device, encrypt: async bytes => (await roomOp('encrypt', bytes)).output,
      post: payload => relay.api('POST', path('events'), payload)});
    S.started = true;
    let members = null;
    try { members = parseMembers((await roomOp('members')).output); } catch (_) { /* no group yet */ }
    if (S.joined && members) S.roster = members;
    if (!S.joined && !S.halted && members && members.includes(device)) {
      // #296: the worker still holds the group but the page state was lost. Trust the
      // worker; resume from the relay's acked cursor for this device — never from 0.
      const probe = await relay.api('GET', path(`events?device=${encodeURIComponent(device)}&after=0&limit=1`));
      if (probe.status === 200 && Number.isSafeInteger(probe.body?.cursor)) {
        S.joined = true; S.roster = members; S.pending = false; S.expectedRoster = null; S.pendingWelcome = null;
        S.relaySeq = Math.max(S.relaySeq, probe.body.cursor); S.epoch = probe.body.epoch ?? S.epoch; save();
        log(strings.room.resumed(members.join(', '), S.relaySeq));
      } else {
        log(`참여 상태를 복구하지 못했다(릴레이 ${describe(probe.status, probe.body)}) — 동기화 뒤 다시 시작`);
      }
    }
    log(`워커 시작: ${device} @ ${database} (relay seq ${S.relaySeq}, joined=${S.joined}, pending=${S.pending})`);
    // Resume: earlier rows come back only from this browser's sealed history (#370).
    // 오너 결정(2026-10-20): 타임라인의 시스템 행으로는 띄우지 않고 화면 로그에만 남긴다.
    if (S.joined && S.relaySeq > 0) {
      const restored = await restoreHistory();
      log(restored > 0 ? strings.room.historyRestored(restored, S.relaySeq) : strings.room.historyNone(S.relaySeq));
    }
    changed();
    if (S.halted) { emitSystem(S.halted.removed ? strings.room.haltRemoved(S.halted.seq, S.halted.committer) : strings.room.haltRefused(S.halted.seq, S.halted.committer, S.halted.reason), `halt-${S.halted.seq}`); return; }
    await sync({quiet: true});
    S.timer = setI(() => sync({quiet: true}), pollMs);
  }

  // ---- room actions ----
  function requireOpen() { if (!S.started || S.halted || S.transferring) throw new Error(S.halted ? strings.room.haltBody : '대화방이 준비되지 않았습니다'); }
  async function create() {
    requireOpen();
    if (S.joined) throw new Error(strings.room.alreadyInRoom);
    await roomOp('create');
    S.joined = true; S.roster = [device]; S.epoch = 0; save(); changed();
    log('방(그룹) 생성 — 이제 다른 기기의 키 패키지로 초대할 수 있다');
  }
  /** 참여 요청: publish one key package to this room (iOS JoinRequestView). */
  async function publishKeyPackage() {
    requireOpen();
    const out = await roomOp('key_package');
    const ref = hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new Uint8Array(out.output))));
    const r = await relay.api('POST', path('keypackages'), {device, packages: [{ref, bytes: b64(out.output)}]});
    if (r.status !== 201 && r.status !== 200) throw new Error(`키 패키지 게시 실패: ${describe(r.status, r.body)}`);
    log(`키 패키지 게시(${r.body?.stored ? '저장' : '중복'}) — 상대 기기가 "초대"로 이 기기를 넣을 수 있다`);
  }
  async function invite(target) {
    requireOpen();
    if (!DEVICE.test(target)) throw new Error(strings.room.noKeyPackage(target));
    if (!S.joined) throw new Error(strings.room.notJoined);
    if (S.pending) throw new Error(strings.room.pendingCommit);
    await sync();
    let kp = await relay.api('GET', path(`keypackages?device=${encodeURIComponent(target)}&consumer=${encodeURIComponent(device)}`));
    if (kp.status === 404) {   // #380: no room key package → the target's lobby key (consumed for this room)
      kp = await relay.api('GET', `/v2/lobby/keypackages?device=${encodeURIComponent(target)}&consumer=${encodeURIComponent(device)}&room=${encodeURIComponent(room)}`);
    }
    if (kp.status !== 200) throw new Error(`${strings.room.noKeyPackage(target)} (${describe(kp.status, kp.body)})`);
    const framed = new Uint8Array((await roomOp('invite_with_commit', unb64(kp.body.bytes))).output);
    const n = new DataView(framed.buffer, framed.byteOffset, framed.byteLength).getUint32(0, true);
    const commit = framed.subarray(4, 4 + n), welcome = framed.subarray(4 + n);
    const expected = parseMembers((await roomOp('members_after_pending')).output);
    const r = await postUncertain(commit, expected, {target, welcome: b64(welcome)});
    if (!r) return;
    if (r.status === 409) { await roomOp('clear_pending'); log(`commit 거절(${describe(r.status, r.body)}) — 방이 먼저 바뀌었다`); await sync(); throw new Error(strings.room.commitRaced); }
    if (r.status !== 201) { await roomOp('clear_pending'); throw new Error(strings.room.commitRefused(describe(r.status, r.body))); }
    S.pending = true; S.expectedRoster = expected; S.pendingWelcome = {target, welcome: b64(welcome)}; save(); changed();
    log(`${target} 추가 commit 게시(seq ${r.body.seq}) — 반영되면 Welcome을 보낸다`);
    await sync();
  }
  // #289: a trusted device removes a member the operator already revoked on the chain.
  async function remove(target) {
    requireOpen();
    if (!DEVICE.test(target)) throw new Error(strings.room.notMember(target, S.roster.join(', ')));
    if (target === device) throw new Error(strings.room.removeSelf);
    if (!S.joined) throw new Error(strings.room.notJoined);
    if (S.pending) throw new Error(strings.room.pendingCommit);
    await sync();
    const key = parseMemberKeys((await roomOp('members')).output).get(target);
    if (!key) throw new Error(strings.room.notMember(target, S.roster.join(', ')));
    const commit = new Uint8Array((await roomOp('remove_pending', key)).output);   // bare commit, no Welcome
    const expected = parseMembers((await roomOp('members_after_pending')).output);
    const r = await postUncertain(commit, expected, null);
    if (!r) return;
    if (r.status === 409) { await roomOp('clear_pending'); await sync(); throw new Error(strings.room.commitRaced); }
    if (r.status !== 201) { await roomOp('clear_pending'); throw new Error(strings.room.commitRefused(describe(r.status, r.body))); }
    S.pending = true; S.expectedRoster = expected; S.pendingWelcome = null; save(); changed();
    log(`${target} 제거 commit 게시(seq ${r.body.seq}) — 반영되면 epoch 전진`);
    await sync();
  }
  /** Returns the seq of the stored message; the caller keeps the draft on any throw (#251 A-2). */
  async function send(text) {
    requireOpen();
    if (!text) return null;
    if (!S.joined) throw new Error(strings.room.notJoined);
    const problem = await sync({quiet: true});
    if (problem && problem.network) throw problem;   // relay unreachable: say so before spending a ratchet step
    for (let attempt = 0; attempt < 2; attempt++) {
      const out = await roomOp('encrypt', utf8.encode(text));
      const r = await postEvent('application', new Uint8Array(out.output));
      if (r.status === 201) {
        S.epoch = r.body.epoch; save();
        const ts = Date.now();
        emitText(device, device, text, r.body.seq, ts, false);
        await remember({seq: r.body.seq, sender: device, client: device, kind: 'text', text, bytes: []});   // MLS cannot decrypt our own messages
        return r.body.seq;
      }
      if (r.status === 409 && r.body && r.body.error === 'cas_mismatch' && attempt === 0) { log(strings.room.epochChanged); await sync(); continue; }
      throw new Error(strings.room.sendFailed(describe(r.status, r.body)));
    }
    return null;
  }
  async function sendAttachment(file) {
    requireOpen();
    if (!S.joined || S.pending) throw new Error(S.joined ? strings.room.pendingCommit : strings.room.notJoined);
    if (S.busy) throw new Error('동기화 중입니다. 잠시 뒤 다시 보내 주세요.');
    S.transferring = true; changed();
    try {
      const result = await attachments.send(file, S.epoch);
      log(`첨부 전송 확인(seq ${result.seq}, ${result.size}바이트${result.duplicate ? ', 중복 없이 확인' : ''})`);
      const bytes = file ? new Uint8Array(await file.arrayBuffer()) : null;
      if (bytes) { emitAttachment(device, bytes.length, result.seq, Date.now(), async () => bytes); await remember({seq: result.seq, sender: device, client: device, kind: 'attachment', text: '', bytes: Array.from(bytes)}); }
      return result;
    } finally { S.transferring = false; changed(); }
  }

  // ---- E2 approval (trusted-device screen) ----
  let candidate = null;
  async function offerCandidate(json) {
    requireOpen();
    const c = JSON.parse(json);
    for (const k of ['device_id', 'actor', 'subject', 'signing_key', 'base_revision']) if (!(k in c)) throw new Error(strings.room.candidateMissing(k));
    if (!/^[a-f0-9]{64}$/.test(c.signing_key)) throw new Error(strings.room.candidateKeyInvalid);
    const fp = decoder.decode(new Uint8Array((await roomOp('policy_fingerprint', utf8.encode(c.signing_key))).output));
    candidate = {...c, fingerprint: fp};
    log(`후보 ${c.device_id} 지문 표시 — 새 기기 화면의 지문과 눈으로 비교한다`);
    return {deviceId: c.device_id, fingerprint: fp};
  }
  async function approveCandidate() {
    requireOpen();
    if (!candidate) throw new Error('먼저 등록 JSON을 붙여 넣어 지문을 확인하세요');
    const args = {action: 'approve-device', device_id: candidate.device_id, actor: candidate.actor, subject: candidate.subject,
      signing_key: candidate.signing_key, acceptance: 'trusted-device-fingerprint', base_revision: Number(candidate.base_revision)};
    const framed = new Uint8Array((await roomOp('sign_approval', utf8.encode(JSON.stringify(args)))).output);
    const n = new DataView(framed.buffer, framed.byteOffset, framed.byteLength).getUint32(0, true);
    const evidence = {...args, signature: hex(framed.subarray(4 + n)), fingerprint: candidate.fingerprint, approved_by: device};
    delete evidence.action; delete evidence.acceptance;
    candidate = null;
    log(strings.room.approvalSigned);
    return JSON.stringify(evidence, null, 1);
  }
  function denyCandidate() { candidate = null; }

  // ---- forget this room's store (⛔ 정지 해제 = 상태를 버리고 재초대를 기다림, iOS §3.5) ----
  async function wipe() {
    stopPolling();
    const r = await worker.call(WORKER, 'reset_room', {room, database});
    if (!r.ok) throw new Error('reset_room 거부');
    storage.removeItem(stateKey());
    storage.removeItem(`hande:attachment:${database}:${room}:${device}`);
    S.started = false; resetState(); changed();
    log(`방 상태 삭제(${room}) — 재초대를 기다린다`);
  }
  function stop() { stopPolling(); worker.call(WORKER, 'close_room', {room}).catch(() => {}); S.started = false; }

  function registration(subject) {
    return {device_id: device, actor: actorOf(device), subject: subject || strings.app.subjectUnknown, signing_key: S.publicKey, fingerprint: S.fingerprint};
  }
  return {
    room, device, database,
    get state() { return S; },
    get attachmentPending() { return !!attachments?.pending; },
    get joined() { return S.joined; },
    open, activate, sync, create, publishKeyPackage, invite, remove, send, sendAttachment,
    offerCandidate, approveCandidate, denyCandidate, wipe, stop, registration,
  };
}
