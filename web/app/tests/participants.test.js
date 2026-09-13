import test from 'node:test';
import assert from 'node:assert/strict';
import { AGENT_KIND_MARKER, AGENT_KIND_VALUE, isAgentMember, splitParticipants } from '../src/participants.js';

const human = { userId: '@minseo:example.com', name: '민서' };
const agentByMarker = { userId: '@helper:example.com', name: '도우미', content: { [AGENT_KIND_MARKER]: AGENT_KIND_VALUE } };
const agentById = { userId: '@bot1:example.com', name: '봇1' };

test('사용자 목록으로 지정한 AI 참여자를 인식한다', () => {
  assert.equal(isAgentMember(agentById, { agentUserIds: ['@bot1:example.com'] }), true);
  assert.equal(isAgentMember(agentById, { agentUserIds: ['@other:example.com'] }), false);
});

test('참여자 이벤트의 표식으로도 AI를 인식한다', () => {
  assert.equal(isAgentMember(agentByMarker), true);
  assert.equal(isAgentMember(agentByMarker, { agentUserIds: new Set() }), true);
  assert.equal(isAgentMember({ userId: '@x:example.com', content: { [AGENT_KIND_MARKER]: 'human' } }), false);
});

test('사람 참여자는 AI로 분류하지 않는다', () => {
  assert.equal(isAgentMember(human), false);
  assert.equal(isAgentMember(null), false);
  assert.equal(isAgentMember({}), false);
});

test('참여자 분리는 중복 없이 순서를 유지한다', () => {
  const members = [human, agentByMarker, { ...human }, agentById];
  const { agents, humans } = splitParticipants(members, { agentUserIds: ['@bot1:example.com'] });
  assert.deepEqual(agents.map((m) => m.userId), ['@helper:example.com', '@bot1:example.com']);
  assert.deepEqual(humans.map((m) => m.userId), ['@minseo:example.com']);
});
