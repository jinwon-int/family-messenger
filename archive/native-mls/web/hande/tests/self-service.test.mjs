// 기기 셀프서비스 순수 판정(#574 PR 2b): node --test archive/native-mls/web/hande/tests/self-service.test.mjs
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {
  canApprove, isSibling, candidatesFor, approvalArgs, approvalEvidence, rolesActions, nextRoles, rolesArgs, rolesEvidence, recordOf, actorHasRegistrar,
  siblingInviteRooms, enrollModeFrom, readSiblingQueue, writeSiblingQueue, enqueueSiblingInvites, splitSiblingQueue, isRetryableInviteError,
  siblingQueueKey, SIBLING_INVITE_TTL_MS, ROLE_REGISTRAR,
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
