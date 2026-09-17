// Participant classification: humans vs AI agents.
//
// The fleet contract (scripts/fleet_core.py) keeps an explicit set of bot
// user IDs as the source of truth; we never guess from user-ID shapes.
// Rooms may additionally mark an agent with a custom membership-content
// field so the badge works even when the client has no configured set.

/** Custom room-member event content field that marks an AI participant. */
export const AGENT_KIND_MARKER = 'us.familychat.kind';
/** Value of AGENT_KIND_MARKER that marks an AI agent participant. */
export const AGENT_KIND_VALUE = 'agent';

/**
 * @param {object} member room member as {userId, content?} where content is
 *   the raw membership event content (custom keys included).
 * @param {{agentUserIds?: Iterable<string>}} [opts]
 * @returns {boolean} true when the member is an AI agent.
 */
export function isAgentMember(member, { agentUserIds } = {}) {
  if (!member || typeof member.userId !== 'string') return false;
  if (agentUserIds && new Set(agentUserIds).has(member.userId)) return true;
  return member?.content?.[AGENT_KIND_MARKER] === AGENT_KIND_VALUE;
}

/**
 * Split members into agents and humans, preserving order and deduplicating
 * by user ID.
 * @param {object[]} members
 * @param {{agentUserIds?: Iterable<string>}} [opts]
 * @returns {{agents: object[], humans: object[]}}
 */
export function splitParticipants(members, opts = {}) {
  const seen = new Set();
  const agents = [];
  const humans = [];
  for (const member of members ?? []) {
    if (!member || seen.has(member.userId)) continue;
    seen.add(member.userId);
    (isAgentMember(member, opts) ? agents : humans).push(member);
  }
  return { agents, humans };
}

const MXID_RE = /^@([^:\s]+):[^\s]+$/;

/**
 * Display label for a sender. The SDK falls back to the full Matrix id
 * (@user:server) when a member has no display name; families read the
 * localpart, so that case is shortened to "@user". Real display names and
 * anything that is not a Matrix id pass through untouched.
 * @param {string|null|undefined} name
 * @returns {string}
 */
export function shortHandle(name) {
  const text = String(name ?? '').trim();
  const match = MXID_RE.exec(text);
  return match ? `@${match[1]}` : text;
}
