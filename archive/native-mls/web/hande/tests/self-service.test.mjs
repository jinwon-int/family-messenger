// 기기 셀프서비스 순수 판정(#574 PR 2b): node --test archive/native-mls/web/hande/tests/self-service.test.mjs
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {
  canApprove, isSibling, candidatesFor, approvalArgs, approvalEvidence, rolesActions, nextRoles, rolesArgs, rolesEvidence, recordOf, actorHasRegistrar,
  siblingInviteRooms, enrollModeFrom, readSiblingQueue, writeSiblingQueue, enqueueSiblingInvites, splitSiblingQueue, isRetryableInviteError,
  siblingQueueKey, SIBLING_INVITE_TTL_MS, ROLE_REGISTRAR,
  siblingInviteBudget, nextSiblingEntry, siblingInviteTurn, SIBLING_LOBBY_RECHECK_MS,
} from '../self-service.js';

const KEY = 'ab'.repeat(32), FP = 'cd'.repeat(32);
const dev = (device_id, {status = 'active', roles = [], actor = device_id.split('-')[0]} = {}) => ({device_id, actor, fingerprint: FP, status, acceptance: 'operator', roles});
const me = (...devices) => ({subject: 'sub-1', policy_revision: 7, devices});
const memStorage = () => { const m = new Map(); return {getItem: k => m.has(k) ? m.get(k) : null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k), map: m}; };

test('canApprove: 활성 + (registrar 이거나 actor 에 활성 registrar 없음) — 서버 VerifyApproval 과 같은 규칙', () => {
  const pre574 = me(dev('mom-web-a'), dev('mom-iphone-b'));
  assert.equal(canApprove(pre574, 'mom-web-a'), true, 'registrar 가 없으면 활성 기기 누구나');
  assert.equal(canApprove(me(dev('mom-web-a', {status: 'revoked'}), dev('mom-iphone-b')), 'mom-web-a'), false, '폐기 기기는 못 한다');
  const withReg = me(dev('mom-web-a'), dev('mom-iphone-b', {roles: ['registrar']}));
  assert.equal(canApprove(withReg, 'mom-web-a'), false, 'registrar 가 생기면 그 기기만');
  assert.equal(canApprove(withReg, 'mom-iphone-b'), true);
  assert.equal(canApprove(me(dev('mom-web-a'), dev('mom-iphone-b', {roles: ['registrar'], status: 'revoked'})), 'mom-web-a'), true, '폐기된 registrar 는 세지 않는다');
  assert.equal(canApprove(withReg, 'dad-web-z'), false, '체인에 없는 기기');
  assert.equal(canApprove(null, 'mom-web-a'), false, '/v2/me 없음(접근 인증 꺼짐)');
  assert.equal(canApprove({subject: 'sub-1'}, 'mom-web-a'), false, '옛 릴레이(devices 없음)');
  assert.equal(actorHasRegistrar(withReg, 'mom'), true);
  assert.equal(actorHasRegistrar(withReg, 'dad'), false);
  assert.deepEqual(recordOf(withReg, 'mom-iphone-b').roles, ['registrar']);
  assert.equal(recordOf(withReg, 'nope'), null);
});

test('isSibling: 내가 아닌 같은 actor 의 활성 체인 기록이 보낸 Welcome 만', () => {
  const info = me(dev('mom-web-a'), dev('mom-iphone-b'), dev('mom-old-c', {status: 'revoked'}), dev('dad-web-d'));
  assert.equal(isSibling('mom-iphone-b', info, 'mom', 'mom-web-a'), true);
  assert.equal(isSibling('mom-web-a', info, 'mom', 'mom-web-a'), false, '나 자신');
  assert.equal(isSibling('mom-old-c', info, 'mom', 'mom-web-a'), false, '폐기된 기기');
  assert.equal(isSibling('dad-web-d', info, 'mom', 'mom-web-a'), false, '다른 사람');
  assert.equal(isSibling('mom-ghost', info, 'mom', 'mom-web-a'), false, '체인에 없음');
  assert.equal(isSibling(undefined, info, 'mom', 'mom-web-a'), false, '옛 릴레이는 from 이 없다');
  assert.equal(isSibling('mom-iphone-b', null, 'mom', 'mom-web-a'), false);
});

test('candidatesFor: 내 actor 의 온전한 후보만', () => {
  const list = {policy_revision: 7, candidates: [
    {device_id: 'mom-pc-1', actor: 'mom', subject: 'sub-1', signing_key: KEY, fingerprint: FP, created_at: 1, expires_at: 601},
    {device_id: 'dad-pc-2', actor: 'dad', subject: 'sub-1', signing_key: KEY, fingerprint: FP, created_at: 1, expires_at: 601},
    {device_id: 'mom-pc-3', actor: 'mom', subject: 'sub-1', signing_key: 'zz', fingerprint: FP, created_at: 1, expires_at: 601},
    null,
  ]};
  assert.deepEqual(candidatesFor(list, 'mom').map(c => c.device_id), ['mom-pc-1']);
  assert.deepEqual(candidatesFor(null, 'mom'), []);
  assert.deepEqual(candidatesFor({candidates: 'x'}, 'mom'), []);
});

test('approvalArgs / approvalEvidence: sign_approval 입력은 파사드의 정확한 키, 증거는 action·acceptance 없이', () => {
  const c = {device_id: 'mom-pc-1', actor: 'mom', subject: 'sub-1', signing_key: KEY, fingerprint: FP, created_at: 1, expires_at: 601};
  const args = approvalArgs(c, 7);
  assert.deepEqual(args, {action: 'approve-device', device_id: 'mom-pc-1', actor: 'mom', subject: 'sub-1', signing_key: KEY, acceptance: 'trusted-device-fingerprint', base_revision: 7});
  assert.deepEqual(Object.keys(args), ['action', 'device_id', 'actor', 'subject', 'signing_key', 'acceptance', 'base_revision']);
  assert.equal(approvalArgs(c, '12').base_revision, 12, '문자열 revision 도 숫자로');
  assert.throws(() => approvalArgs(c, 0), /base_revision/);
  assert.throws(() => approvalArgs(c, null), /base_revision/);
  const ev = approvalEvidence(args, 'ff'.repeat(64), FP, 'mom-web-a');
  assert.deepEqual(ev, {device_id: 'mom-pc-1', actor: 'mom', subject: 'sub-1', signing_key: KEY, base_revision: 7, signature: 'ff'.repeat(64), fingerprint: FP, approved_by: 'mom-web-a'});
  assert.ok(!('action' in ev) && !('acceptance' in ev), 'AddDeviceEvidence 는 strict JSON — 여분 키 금지');
});

test('nextRoles / rolesArgs / rolesEvidence: 완전한 정렬 목록, sign_roles 입력 모양', () => {
  assert.deepEqual(nextRoles([], true), ['registrar']);
  assert.deepEqual(nextRoles(['registrar'], true), ['registrar']);
  assert.deepEqual(nextRoles(['zeta', 'registrar'], false), ['zeta']);
  assert.deepEqual(nextRoles(undefined, false), []);
  const args = rolesArgs(dev('mom-iphone-b'), ['registrar'], 7);
  assert.deepEqual(args, {device_id: 'mom-iphone-b', actor: 'mom', roles: ['registrar'], base_revision: 7});
  assert.throws(() => rolesArgs(dev('mom-iphone-b'), [], 0), /base_revision/);
  assert.deepEqual(rolesEvidence(args, 'ee'.repeat(64), 'mom-web-a'), {...args, signature: 'ee'.repeat(64), approved_by: 'mom-web-a'});
});

test('rolesActions: 부여는 활성·같은 actor·비registrar, 해제는 마지막 registrar 가 아닐 때만', () => {
  // registrar 가 없는 actor: 활성 기기 누구나 서명·부여 가능(부트스트랩), 해제할 것은 없음.
  const boot = rolesActions(me(dev('mom-web-a'), dev('mom-iphone-b'), dev('mom-old-c', {status: 'revoked'}), dev('dad-web-d')), 'mom-web-a');
  assert.equal(boot.canSign, true); assert.equal(boot.actor, 'mom');
  const by = view => Object.fromEntries(view.devices.map(d => [d.deviceId, d]));
  let v = by(boot);
  assert.deepEqual([v['mom-web-a'].grant, v['mom-web-a'].release, v['mom-web-a'].isSelf], [true, false, true]);
  assert.deepEqual([v['mom-iphone-b'].grant, v['mom-iphone-b'].release], [true, false]);
  assert.deepEqual([v['mom-old-c'].grant, v['mom-old-c'].release, v['mom-old-c'].status], [false, false, 'revoked'], '폐기 기기는 보이되 손댈 수 없다');
  assert.deepEqual([v['dad-web-d'].grant, v['dad-web-d'].release], [false, false], '다른 actor');
  // registrar 하나뿐: 그 기기는 해제 불가(lastRegistrar), 다른 기기에 부여는 가능.
  const one = rolesActions(me(dev('mom-web-a', {roles: ['registrar']}), dev('mom-iphone-b')), 'mom-web-a');
  v = by(one);
  assert.deepEqual([v['mom-web-a'].grant, v['mom-web-a'].release, v['mom-web-a'].lastRegistrar, v['mom-web-a'].registrar], [false, false, true, true]);
  assert.deepEqual([v['mom-iphone-b'].grant, v['mom-iphone-b'].release], [true, false]);
  // registrar 둘: 둘 다 해제 가능(자기 자신 포함 — 다른 하나가 남는다).
  const two = rolesActions(me(dev('mom-web-a', {roles: ['registrar']}), dev('mom-iphone-b', {roles: ['registrar']})), 'mom-web-a');
  v = by(two);
  assert.deepEqual([v['mom-web-a'].release, v['mom-iphone-b'].release, v['mom-web-a'].lastRegistrar], [true, true, false]);
  // registrar 가 있는데 내가 아니면: 서명 불가, 모든 버튼 꺼짐.
  const notMe = rolesActions(me(dev('mom-web-a'), dev('mom-iphone-b', {roles: ['registrar']})), 'mom-web-a');
  assert.equal(notMe.canSign, false);
  assert.ok(notMe.devices.every(d => !d.grant && !d.release));
  // 체인 모름
  assert.deepEqual(rolesActions(null, 'mom-web-a'), {canSign: false, actor: null, devices: []});
  assert.equal(ROLE_REGISTRAR, 'registrar');
});

test('siblingInviteRooms: 참여·비정지·비대기·명단에 없는 방만', () => {
  const rooms = [
    {roomId: 'family', joined: true, halted: null, pending: false, roster: ['mom-web-a', 'dad-web-d']},
    {roomId: 'already', joined: true, halted: null, pending: false, roster: ['mom-web-a', 'mom-pc-1']},
    {roomId: 'halted', joined: true, halted: {reason: 'x'}, pending: false, roster: ['mom-web-a']},
    {roomId: 'pending', joined: true, halted: null, pending: true, roster: ['mom-web-a']},
    {roomId: 'notjoined', joined: false, halted: null, pending: false, roster: []},
    {roomId: 'noroster', joined: true, halted: null, pending: false, roster: undefined},
  ];
  assert.deepEqual(siblingInviteRooms(rooms, 'mom-pc-1'), ['family', 'noroster']);
  assert.deepEqual(siblingInviteRooms(undefined, 'mom-pc-1'), []);
});

test('enrollModeFrom: 201 sibling · 409 device_exists id-taken · 403/404/그 밖 operator', () => {
  assert.equal(enrollModeFrom(201, {device_id: 'x', policy_revision: 3}), 'sibling');
  assert.equal(enrollModeFrom(409, {error: 'device_exists'}), 'id-taken');
  assert.equal(enrollModeFrom(409, {error: 'other'}), 'operator');
  assert.equal(enrollModeFrom(403, {error: 'first_device_out_of_band'}), 'operator');
  assert.equal(enrollModeFrom(403, {error: 'subject_mismatch'}), 'operator');
  assert.equal(enrollModeFrom(404, null), 'operator');
  assert.equal(enrollModeFrom(500, {error: 'internal'}), 'operator');
});

test('형제 기기 초대 대기열: localStorage 왕복, 같은 target 은 방 합침, TTL 로 나눔', () => {
  const storage = memStorage();
  assert.deepEqual(readSiblingQueue(storage, 'mom-web-a'), []);
  let q = enqueueSiblingInvites([], 'mom-pc-1', ['family', 'family'], 1000);
  assert.deepEqual(q, [{target: 'mom-pc-1', rooms: ['family'], since: 1000}]);
  q = enqueueSiblingInvites(q, 'mom-pc-1', ['family', 'acc'], 5000);
  assert.deepEqual(q, [{target: 'mom-pc-1', rooms: ['family', 'acc'], since: 1000}], '시각은 처음 것, 방은 합집합');
  q = enqueueSiblingInvites(q, 'mom-pc-2', [], 6000);
  assert.equal(q.length, 1, '방이 없으면 넣지 않는다');
  q = enqueueSiblingInvites(q, 'mom-pc-2', ['family'], 6000);
  assert.ok(writeSiblingQueue(storage, 'mom-web-a', q));
  assert.equal(siblingQueueKey('mom-web-a'), 'hande:sibling-invites:mom-web-a');
  assert.ok(storage.map.has('hande:sibling-invites:mom-web-a'), '「이 기기 지우기」의 hande:* 정리에 포함된다');
  assert.deepEqual(readSiblingQueue(storage, 'mom-web-a'), q);
  const {live, expired} = splitSiblingQueue(q, 1000 + SIBLING_INVITE_TTL_MS + 1);
  assert.deepEqual(live.map(e => e.target), ['mom-pc-2']);
  assert.deepEqual(expired.map(e => e.target), ['mom-pc-1']);
  writeSiblingQueue(storage, 'mom-web-a', []);
  assert.ok(!storage.map.has('hande:sibling-invites:mom-web-a'), '비면 키를 지운다');
  storage.setItem('hande:sibling-invites:mom-web-a', '{bad');
  assert.deepEqual(readSiblingQueue(storage, 'mom-web-a'), [], '깨진 값은 빈 대기열');
});

test('isRetryableInviteError: 네트워크·지정 문구만 다시 시도', () => {
  const noKey = 'mom-pc-1 기기의 키 패키지가 없습니다';
  assert.equal(isRetryableInviteError(new Error(`${noKey} (404 no_key_package)`), [noKey]), true);
  assert.equal(isRetryableInviteError(Object.assign(new Error('연결 실패'), {network: true}), []), true);
  assert.equal(isRetryableInviteError(new Error('변경이 거절되었습니다: 403'), [noKey]), false);
  assert.equal(isRetryableInviteError(null, [noKey]), false);
});

// ---- #616: 형제 기기 초대가 로비 키 상한(8)에 막혀 9번째 방부터 빠지던 문제 ----

test('splitSiblingQueue(#616): TTL 은 마지막 진행(progress)부터 — 진행이 있으면 오래된 항목도 산다', () => {
  const q = [{target: 'a', rooms: ['x'], since: 0, progress: 10 * 3_600_000}, {target: 'b', rooms: ['x'], since: 0}];
  const {live, expired} = splitSiblingQueue(q, SIBLING_INVITE_TTL_MS + 1);
  assert.deepEqual(live.map(e => e.target), ['a']);
  assert.deepEqual(expired.map(e => e.target), ['b']);
  assert.ok(SIBLING_INVITE_TTL_MS >= 24 * 3_600_000, '15시간 동안 백그라운드였던 탭(10-30)도 기다린다');
});

test('siblingInviteBudget / nextSiblingEntry', () => {
  assert.equal(siblingInviteBudget(null), Infinity, '모르면 예전처럼 제한 없음');
  assert.equal(siblingInviteBudget({live: 3}), 3);
  assert.equal(siblingInviteBudget({live: -1}), 0);
  const e = {target: 't', rooms: ['a', 'b'], since: 1, recheckAt: 5};
  assert.equal(nextSiblingEntry(e, [], {now: 10}), null, '남은 방이 없으면 끝');
  assert.deepEqual(nextSiblingEntry(e, ['b'], {now: 10, progressed: true}), {target: 't', rooms: ['b'], since: 1, progress: 10});
  assert.deepEqual(nextSiblingEntry(e, ['b'], {now: 10, starved: true}), {target: 't', rooms: ['b'], since: 1, recheckAt: 10 + SIBLING_LOBBY_RECHECK_MS});
});

/** 형제 기기(새 웹 기기)를 흉내: 로비 키 상한 8, 초대가 하나씩 쓰고, replenish() 가 상한까지 채운다. */
function sibling(maxKeys = 8) {
  const s = {live: 0, statusCalls: 0, inviteCalls: 0, members: new Set()};
  s.replenish = () => { s.live = maxKeys; };
  s.lobbyStatus = async () => { s.statusCalls++; return {live: s.live, max: maxKeys}; };
  s.invite = async roomId => {
    s.inviteCalls++;
    if (s.live <= 0) throw new Error('t-web 기기의 키 패키지가 없습니다 (404 no_live_key_package)');
    s.live--; s.members.add(roomId);
  };
  return s;
}
const NO_KEY = 't-web 기기의 키 패키지가 없습니다';

test('siblingInviteTurn(#616): 방 17개 · 로비 키 8개 — 잔량만큼만 쓰고, 키가 없으면 기다렸다가 보충되면 마저 들인다', async () => {
  const rooms = Array.from({length: 17}, (_, i) => `room${i + 1}`);
  const sib = sibling(8);
  const roomState = roomId => ({joined: true, halted: false, pending: false, roster: sib.members.has(roomId) ? ['t-web'] : ['me-iphone']});
  const turn = (e, now) => siblingInviteTurn(e, {now, lobbyStatus: sib.lobbyStatus, roomState, invite: sib.invite, retryable: [NO_KEY], noKey: NO_KEY});
  let entry = {target: 't-web', rooms, since: 0};
  let now = 0;
  // 승인 직후: 새 기기가 아직 키를 안 올림 → 초대 시도 0, 다시 물을 시각만.
  let r = await turn(entry, now);
  assert.equal(sib.inviteCalls, 0, '잔량 0 이면 404 를 쌓지 않는다');
  assert.equal(r.entry.recheckAt, now + SIBLING_LOBBY_RECHECK_MS);
  entry = r.entry;
  // 다시 물을 시각 전에는 잔량도 묻지 않는다.
  const calls = sib.statusCalls;
  r = await turn(entry, now + 1000);
  assert.equal(sib.statusCalls, calls);
  // 새 기기가 키 8개를 올림 → 한 차례에 정확히 8개 방.
  sib.replenish(); now += SIBLING_LOBBY_RECHECK_MS;
  r = await turn(entry, now);
  assert.equal(r.invited.length, 8);
  assert.equal(sib.inviteCalls, 8, '9번째 방에서 404 를 내지 않는다');
  assert.equal(r.entry.rooms.length, 9);
  assert.equal(r.entry.progress, now, '진행 시각 갱신');
  entry = r.entry;
  // 새 기기가 15시간 백그라운드(10-30 실측) — 키 0 인 채로 기다려도 TTL 은 마지막 진행부터라 버리지 않는다.
  now += 15 * 3_600_000;
  assert.equal(splitSiblingQueue([entry], now).expired.length, 0);
  r = await turn(entry, now);
  assert.equal(r.invited.length, 0);
  entry = r.entry;
  // 복귀해서 보충 → 8개, 다시 보충 → 마지막 1개.
  sib.replenish(); now += SIBLING_LOBBY_RECHECK_MS;
  r = await turn(entry, now); entry = r.entry;
  assert.equal(r.invited.length, 8);
  sib.replenish(); now += 1;
  r = await turn(entry, now);
  assert.deepEqual(r.invited, ['room17']);
  assert.equal(r.entry, null, '17개 방 모두 들어가면 대기열에서 빠진다');
  assert.equal(sib.members.size, 17);
  assert.equal(sib.inviteCalls, 17, '실패한 초대 시도 0');
});

test('siblingInviteTurn(#616): 잔량 수치가 낡아 404 가 나면 그 차례는 멈춘다 · 옛 릴레이(null)는 예전처럼 · 포기 사유는 failed', async () => {
  const sib = sibling(8);
  sib.live = 0;
  const stale = async () => ({live: 5});   // 다른 형제가 방금 다 써 버림
  const roomState = () => ({joined: true, halted: false, pending: false, roster: []});
  const e = {target: 't-web', rooms: ['a', 'b', 'c'], since: 0};
  let r = await siblingInviteTurn(e, {now: 1, lobbyStatus: stale, roomState, invite: sib.invite, retryable: [NO_KEY], noKey: NO_KEY});
  assert.equal(sib.inviteCalls, 1, '첫 404 뒤 나머지는 시도하지 않는다');
  assert.deepEqual(r.entry.rooms, ['a', 'b', 'c']);
  assert.equal(r.entry.recheckAt, 1 + SIBLING_LOBBY_RECHECK_MS);
  const calls = [];
  r = await siblingInviteTurn(e, {now: 1, lobbyStatus: async () => null, roomState, invite: async roomId => { calls.push(roomId); if (roomId === 'b') throw new Error('변경이 거절되었습니다: 403'); },
    retryable: [NO_KEY], noKey: NO_KEY});
  assert.deepEqual(calls, ['a', 'b', 'c'], '잔량을 모르면 제한 없이');
  assert.deepEqual(r.invited, ['a', 'c']);
  assert.deepEqual(r.failed.map(f => f.roomId), ['b'], '재시도 불가 사유는 포기 목록');
  assert.equal(r.entry, null);
  // 이 기기에 없는 방 · 이미 멤버 · 내 commit 대기는 예산을 쓰지 않는다.
  const spent = [];
  r = await siblingInviteTurn({target: 't-web', rooms: ['gone', 'member', 'pending', 'x'], since: 0}, {now: 1, lobbyStatus: async () => ({live: 1}),
    roomState: id => {
      const known = {gone: null, member: {joined: true, halted: false, pending: false, roster: ['t-web']}, pending: {joined: true, halted: false, pending: true, roster: []}};
      return id in known ? known[id] : {joined: true, halted: false, pending: false, roster: []};
    },
    invite: async id => { spent.push(id); }, retryable: [NO_KEY], noKey: NO_KEY});
  assert.deepEqual(spent, ['x']);
  assert.deepEqual(r.entry.rooms, ['pending']);
});
