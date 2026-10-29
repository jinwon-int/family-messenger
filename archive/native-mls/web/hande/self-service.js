// 새 기기 셀프서비스(#574 PR 2b) — 순수 판정·조립 함수(DOM·워커·릴레이 없음, tests/self-service.test.mjs).
//
// 서버 계약(PR #578, server/devices.go · me.go · lobby.go):
//   POST /v2/devices/candidates  새 기기가 자기 공개 기록을 우편함에 올린다(subject 는 JWT 에서, 본문에 넣지 않는다).
//   GET  /v2/devices/candidates  같은 subject 의 활성 기기가 우편함을 본다 → {policy_revision, candidates}.
//   POST /v2/devices/approvals   E2 증거(approve-device 서명) → 체인 commit.  409 stale_revision 이면 revision 으로 다시 서명.
//   POST /v2/devices/roles       E5 증거(set-roles 서명, roles 는 완전한 정렬 목록) → registrar 부여/해제.
//   GET  /v2/me                  {subject, policy_revision, devices:[{device_id, actor, fingerprint, status, acceptance, roles}]}.
// 누가 서명할 수 있나(devicepolicy.VerifyApproval/VerifyRoles): 이 기기가 활성이고, (registrar 이거나 같은 actor 에 활성 registrar 가 하나도 없을 때).
// 마지막 registrar 는 스스로 해제할 수 없다(다른 기기에 먼저 부여).

export const ROLE_REGISTRAR = 'registrar';
export const APPROVAL_ACTION = 'approve-device';
export const APPROVAL_ACCEPTANCE = 'trusted-device-fingerprint';
/** 형제 기기 초대 대기열(localStorage)의 수명 — 새 기기가 활성이 된 뒤 로비 키를 올릴 때까지 기다리되, 영원히는 아니다. */
export const SIBLING_INVITE_TTL_MS = 30 * 60_000;
/** 후보 게시의 재게시 여유: 만료(10분) 이만큼 전에 다시 올린다. */
export const CANDIDATE_REPOST_MARGIN_MS = 5 * 60_000;

const SIGNING_KEY = /^[a-f0-9]{64}$/;
const FINGERPRINT = /^[a-f0-9]{64}$/;

const devicesOf = (me) => (Array.isArray(me?.devices) ? me.devices.filter((d) => d && typeof d.device_id === 'string') : []);
const rolesOf = (d) => (Array.isArray(d?.roles) ? d.roles.filter((r) => typeof r === 'string') : []);
const isActive = (d) => d?.status === 'active';
export const isRegistrar = (d) => rolesOf(d).includes(ROLE_REGISTRAR);

/** /v2/me 의 내 기기 기록(없으면 null — 옛 릴레이거나 아직 체인에 없는 기기). */
export function recordOf(me, device) {
  return devicesOf(me).find((d) => d.device_id === device) ?? null;
}

/** 이 actor 에 활성 registrar 가 하나라도 있나(devicepolicy.HasRegistrar). */
export function actorHasRegistrar(me, actor) {
  return devicesOf(me).some((d) => d.actor === actor && isActive(d) && isRegistrar(d));
}

/**
 * 이 기기가 같은 actor 의 새 기기를 승인(E2)하거나 역할(E5)에 서명할 수 있나:
 * 활성이고, registrar 이거나 그 actor 에 활성 registrar 가 없다(#574 이전 체인의 「활성 기기면 누구나」 규칙).
 */
export function canApprove(me, device) {
  const rec = recordOf(me, device);
  if (!rec || !isActive(rec)) return false;
  return isRegistrar(rec) || !actorHasRegistrar(me, rec.actor);
}

/**
 * 로비 Welcome 을 보낸 기기가 내 형제 기기인가 — 내가 아니고, 체인에 그 ID 의 활성 기록이 있고, 같은 actor.
 * 오너가 아닌 가족도 자기 다른 기기가 보낸 초대는 묻지 않고 받는다.
 */
export function isSibling(from, me, actor, device) {
  if (typeof from !== 'string' || !from || from === device || !actor) return false;
  const rec = recordOf(me, from);
  return Boolean(rec) && rec.actor === actor && isActive(rec);
}

/** 우편함에서 내 actor 의 후보만(모양이 온전한 것만). 승인은 같은 actor 사이에서만 유효하다. */
export function candidatesFor(list, actor) {
  const rows = Array.isArray(list?.candidates) ? list.candidates : [];
  return rows.filter((c) => c && typeof c.device_id === 'string' && c.actor === actor && SIGNING_KEY.test(c.signing_key ?? '') && FINGERPRINT.test(c.fingerprint ?? ''));
}

/** sign_approval 입력(파사드가 받는 정확한 키 집합, 알 수 없는 키는 거부된다). */
export function approvalArgs(candidate, policyRevision) {
  const base = Number(policyRevision);
  if (!Number.isSafeInteger(base) || base < 1) throw new Error('base_revision');
  return {action: APPROVAL_ACTION, device_id: candidate.device_id, actor: candidate.actor, subject: candidate.subject,
    signing_key: candidate.signing_key, acceptance: APPROVAL_ACCEPTANCE, base_revision: base};
}

/** POST /v2/devices/approvals 본문 = AddDeviceEvidence(strict JSON): action·acceptance 는 뺀다. */
export function approvalEvidence(args, signature, fingerprint, approvedBy) {
  const {action: _a, acceptance: _c, ...rest} = args;
  return {...rest, signature, fingerprint, approved_by: approvedBy};
}

/** 역할 목록에 registrar 를 넣거나 빼서 **완전한 정렬 목록**으로(서버 CanonicalRoles 와 같은 모양). */
export function nextRoles(roles, grant) {
  const set = new Set(rolesOf({roles}));
  if (grant) set.add(ROLE_REGISTRAR); else set.delete(ROLE_REGISTRAR);
  return [...set].sort();
}

/** sign_roles 입력 `{device_id, actor, roles, base_revision}`. */
export function rolesArgs(target, roles, policyRevision) {
  const base = Number(policyRevision);
  if (!Number.isSafeInteger(base) || base < 1) throw new Error('base_revision');
  return {device_id: target.device_id, actor: target.actor, roles: [...roles].sort(), base_revision: base};
}

/** POST /v2/devices/roles 본문 = RolesEvidence. */
export function rolesEvidence(args, signature, approvedBy) {
  return {...args, signature, approved_by: approvedBy};
}

/**
 * 「내 기기」 시트의 행: 체인의 내 subject 기기 전부(폐기 포함) + 이 기기가 각 기기에 할 수 있는 역할 변경.
 * - 서명 가능 = canApprove(E5 도 같은 규칙: 활성 + registrar 이거나 actor 에 registrar 없음).
 * - 부여: 대상이 활성·같은 actor·아직 registrar 가 아닐 때.
 * - 해제: 대상이 활성·같은 actor·registrar 이고, 해제 뒤에도 활성 registrar 가 남을 때(마지막 registrar 는 해제 불가).
 */
export function rolesActions(me, device) {
  const all = devicesOf(me);
  const self = recordOf(me, device);
  const canSign = canApprove(me, device);
  const actor = self?.actor ?? null;
  const activeRegistrars = all.filter((d) => d.actor === actor && isActive(d) && isRegistrar(d)).length;
  const devices = all.map((d) => {
    const registrar = isRegistrar(d);
    const eligible = canSign && isActive(d) && d.actor === actor;
    const grant = eligible && !registrar;
    const release = eligible && registrar && activeRegistrars - 1 > 0;
    return {deviceId: d.device_id, actor: d.actor, fingerprint: d.fingerprint ?? '', status: d.status ?? '', roles: rolesOf(d), registrar,
      isSelf: d.device_id === device, grant, release, lastRegistrar: eligible && registrar && !release};
  });
  return {canSign, actor, devices};
}

/**
 * 새 형제 기기를 초대할 방: 내가 참여했고, 정지가 아니고, 내 commit 이 대기 중이 아니고, 아직 명단에 없는 방.
 * @param {Array<{roomId: string, joined: boolean, halted: any, pending: boolean, roster: string[]}>} rooms
 */
export function siblingInviteRooms(rooms, target) {
  const list = Array.isArray(rooms) ? rooms : [];
  return list.filter((r) => r && r.joined && !r.halted && !r.pending && !(Array.isArray(r.roster) && r.roster.includes(target))).map((r) => r.roomId);
}

/**
 * POST /v2/devices/candidates 의 응답 → 등록 화면 모드.
 * 201 = 형제 기기가 승인한다('sibling'); 409 device_exists = 이 ID 는 다시 쓸 수 없다('id-taken');
 * 403 first_device_out_of_band·subject_mismatch, 404(옛 릴레이·접근 인증 꺼짐), 그 밖 = 운영자 흐름('operator').
 */
export function enrollModeFrom(status, body) {
  if (status === 201) return 'sibling';
  if (status === 409 && body?.error === 'device_exists') return 'id-taken';
  return 'operator';
}

// ---- 형제 기기 초대 대기열(localStorage `hande:sibling-invites:<device>`) ----
// 새 기기는 활성이 된 다음 틱에야 로비 키를 올리므로(device.js replenish) 승인 직후의 초대는 「키 패키지 없음」으로 실패한다.
// 승인한 기기가 방 목록을 적어 두고 틱마다 다시 시도한다; TTL 이 지나면 🔔 에 알리고 버린다.

export const siblingQueueKey = (device) => `hande:sibling-invites:${device}`;

export function readSiblingQueue(storage, device) {
  try {
    const v = JSON.parse(storage.getItem(siblingQueueKey(device)) || '[]');
    return Array.isArray(v) ? v.filter((e) => e && typeof e.target === 'string' && Array.isArray(e.rooms) && Number.isFinite(e.since)) : [];
  } catch (_) { return []; }
}

export function writeSiblingQueue(storage, device, queue) {
  try {
    if (!queue.length) storage.removeItem(siblingQueueKey(device)); else storage.setItem(siblingQueueKey(device), JSON.stringify(queue));
    return true;
  } catch (_) { return false; }
}

/** 대기열에 (target, rooms) 를 넣는다 — 같은 target 이 있으면 방을 합치고 시각은 유지. 방이 없으면 그대로. */
export function enqueueSiblingInvites(queue, target, rooms, now) {
  const add = [...new Set((rooms ?? []).filter((r) => typeof r === 'string' && r))];
  if (!add.length) return queue;
  const existing = queue.find((e) => e.target === target);
  if (existing) return queue.map((e) => (e === existing ? {...e, rooms: [...new Set([...e.rooms, ...add])]} : e));
  return [...queue, {target, rooms: add, since: now}];
}

/** 처리할 것과 포기할 것(TTL 지남)으로 나눈다. */
export function splitSiblingQueue(queue, now, ttl = SIBLING_INVITE_TTL_MS) {
  const live = [], expired = [];
  for (const e of queue) (now - e.since > ttl ? expired : live).push(e);
  return {live, expired};
}

/**
 * 초대 실패 사유가 「다음 틱에 다시」인가 — 네트워크 실패이거나, 메시지가 retryable 문구(키 패키지 아직 없음 · 내 commit 대기 ·
 * 방이 먼저 바뀜) 가운데 하나를 품고 있을 때. 그 밖(정책 거절 등)은 포기하고 🔔 에 남긴다.
 */
export function isRetryableInviteError(error, retryable = []) {
  if (error?.network) return true;
  const m = String(error?.message ?? '');
  return retryable.some((text) => typeof text === 'string' && text && m.includes(text));
}
