// 셀프서비스 공용 벡터(#366 3g) — host-core `self_service`(봇·Android ffi)·Android `core/SelfService` 와 같은 파일
// archive/native-mls/tests/fixtures/self-service-vectors.json 을 웹 self-service.js 로 돌린다. 웹 코드는 바꾸지 않았다(같은 규칙을
// JS 로 갖고 있다) — 이 시험은 호스트 사이에 판정이 갈라지지 않음을 고정한다.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {
  ROLE_REGISTRAR, SIBLING_INVITE_TTL_MS, SIBLING_LOBBY_RECHECK_MS, CANDIDATE_REPOST_MARGIN_MS,
  actorHasRegistrar, canApprove, isSibling, candidatesFor, nextRoles, rolesActions, siblingInviteRooms, enrollModeFrom,
} from '../self-service.js';

const vectors = JSON.parse(readFileSync(new URL('../../../tests/fixtures/self-service-vectors.json', import.meta.url), 'utf8'));
const meOf = (c) => (c.me === null ? null : vectors.mes[c.me]);
const cases = (key) => {
  assert.ok(vectors[key].length > 0, key);
  return vectors[key];
};

test('constants: same values as host-core and Android', () => {
  const c = vectors.constants;
  assert.equal(ROLE_REGISTRAR, c.role_registrar);
  assert.equal(SIBLING_INVITE_TTL_MS, c.sibling_invite_ttl_ms);
  assert.equal(SIBLING_LOBBY_RECHECK_MS, c.sibling_lobby_recheck_ms);
  assert.equal(CANDIDATE_REPOST_MARGIN_MS, c.candidate_repost_margin_ms);
});

test('actorHasRegistrar · canApprove · isSibling: same decision as host-core and Android', () => {
  for (const c of cases('actor_has_registrar')) assert.equal(actorHasRegistrar(meOf(c), c.actor), c.expect, c.name);
  for (const c of cases('can_approve')) assert.equal(canApprove(meOf(c), c.device), c.expect, c.name);
  for (const c of cases('is_sibling')) assert.equal(isSibling(c.from, meOf(c), c.actor, c.device), c.expect, c.name);
});

test('candidatesFor · nextRoles: same rows and lists as host-core and Android', () => {
  for (const c of cases('candidates_for')) {
    assert.deepEqual(candidatesFor({candidates: c.candidates}, c.actor).map((r) => r.device_id), c.expect, c.name);
  }
  for (const c of cases('next_roles')) assert.deepEqual(nextRoles(c.roles, c.grant), c.expect, JSON.stringify(c));
});

test('rolesActions: same rows in chain order as host-core', () => {
  for (const c of cases('roles_actions')) {
    const v = rolesActions(meOf(c), c.device);
    assert.equal(v.canSign, c.expect.can_sign, c.name);
    assert.equal(v.actor, c.expect.actor, c.name);
    const rows = v.devices.map((d) => ({device_id: d.deviceId, registrar: d.registrar, is_self: d.isSelf, grant: d.grant,
      release: d.release, last_registrar: d.lastRegistrar}));
    assert.deepEqual(rows, c.expect.devices, c.name);
  }
});

test('siblingInviteRooms · enrollModeFrom: same decision as host-core and Android', () => {
  for (const c of cases('sibling_invite_rooms')) {
    const rooms = c.rooms.map((r) => ({roomId: r.room, joined: r.joined, halted: r.halted, pending: r.pending, roster: r.roster}));
    assert.deepEqual(siblingInviteRooms(rooms, c.target ?? undefined), c.expect, c.name);
  }
  for (const c of cases('enroll_mode')) {
    assert.equal(enrollModeFrom(c.status, c.code ? {error: c.code} : {}), c.expect, JSON.stringify(c));
  }
});
