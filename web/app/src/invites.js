// Invite intake: pending room invitations and the AI consent gate.
//
// Roadmap stage 1 / 원칙 1: the family member must be told what an AI
// participant can read and where its replies go BEFORE accepting the invite
// (fleet_matrix posts the same disclosure when it first joins). Pure logic
// only — the view calls canAccept() to drive the accept button, and
// main.js performs joinRoom/declineInvite through the client adapter.

/**
 * View model for one pending invitation, safe to render for partial input.
 * @param {{roomId?: string, displayName?: string, kind?: string,
 *          memberCount?: number, inviterName?: string, agents?: object[]}} [summary]
 */
export function describeInvite(summary) {
  const agents = Array.isArray(summary?.agents) ? summary.agents : [];
  return {
    roomId: typeof summary?.roomId === 'string' ? summary.roomId : '',
    displayName: typeof summary?.displayName === 'string' ? summary.displayName : '',
    kind: typeof summary?.kind === 'string' ? summary.kind : 'other',
    memberCount: Number(summary?.memberCount ?? 0),
    inviterName: typeof summary?.inviterName === 'string' ? summary.inviterName : '',
    agentCount: agents.length,
    requiresAiConsent: agents.length > 0,
  };
}

/**
 * Accept gate: an invited room with AI participants stays locked until the
 * consent acknowledgement is recorded for it (per session, in memory).
 * @param {ReturnType<typeof describeInvite>} invite
 * @param {{aiConsentAcknowledged?: boolean}} [opts]
 * @returns {{allowed: boolean, reason: null|'ai-consent-required'}}
 */
export function canAccept(invite, { aiConsentAcknowledged = false } = {}) {
  if (invite?.requiresAiConsent && !aiConsentAcknowledged) {
    return { allowed: false, reason: 'ai-consent-required' };
  }
  return { allowed: true, reason: null };
}
