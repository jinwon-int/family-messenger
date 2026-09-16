import test from 'node:test';
import assert from 'node:assert/strict';
import { canAccept, describeInvite } from '../src/invites.js';

test('초대 요약을 화면 모델로 만든다', () => {
  const invite = describeInvite({
    roomId: '!family:example.com',
    displayName: '우리 가족',
    kind: 'family',
    memberCount: 3,
    inviterName: '아빠',
    agents: [{ userId: '@helper:example.com' }],
    humans: [{ userId: '@haejun:example.com' }],
  });
  assert.deepEqual(invite, {
    roomId: '!family:example.com',
    displayName: '우리 가족',
    kind: 'family',
    memberCount: 3,
    inviterName: '아빠',
    agentCount: 1,
    requiresAiConsent: true,
  });
});

test('AI 참여자가 없으면 동의 없이 수락한다', () => {
  const invite = describeInvite({ roomId: '!dm:example.com', agents: [] });
  assert.equal(invite.requiresAiConsent, false);
  assert.deepEqual(canAccept(invite, { aiConsentAcknowledged: false }), { allowed: true, reason: null });
});

test('AI 참여 방은 동의 기록 전에는 수락이 막힌다', () => {
  const invite = describeInvite({ roomId: '!family:example.com', agents: [{ userId: '@helper:example.com' }] });
  assert.deepEqual(canAccept(invite), { allowed: false, reason: 'ai-consent-required' });
  assert.deepEqual(canAccept(invite, { aiConsentAcknowledged: true }), { allowed: true, reason: null });
});

test('비정상 입력도 안전하게 다룬다', () => {
  const empty = describeInvite(null);
  assert.equal(empty.roomId, '');
  assert.equal(empty.kind, 'other');
  assert.equal(empty.memberCount, 0);
  assert.equal(empty.requiresAiConsent, false);
  // 요약이 비정상이어도 막히지는 않는다(방어는 어댑터와 UI가 담당).
  assert.deepEqual(canAccept(empty), { allowed: true, reason: null });
  assert.deepEqual(canAccept(undefined), { allowed: true, reason: null });
});
