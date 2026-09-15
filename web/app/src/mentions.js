// Plain-text @handles → the spec'd m.mentions user_ids structure.
// fleet_matrix family mode gates replies on this structure (fleet_core
// admit), so a mention only counts when it names a real room member.

const HANDLE_RE = /@([a-zA-Z0-9._=-]+)/g;

/**
 * Full user ids of @-handles found in `text`, matched case-insensitively
 * against room member handles (`{userId, localpart}`). Unknown handles are
 * left out, so free text after an @ can never forge a mention.
 * @param {string} text
 * @param {Array<{userId: string, localpart: string}>} [handles]
 * @returns {string[]}
 */
export function extractMentions(text, handles) {
  const byLocal = new Map(
    (handles ?? [])
      .filter((h) => typeof h?.userId === 'string' && typeof h?.localpart === 'string' && h.localpart.length > 0)
      .map((h) => [h.localpart.toLowerCase(), h.userId]),
  );
  const ids = [];
  for (const match of String(text ?? '').matchAll(HANDLE_RE)) {
    const userId = byLocal.get(match[1].toLowerCase());
    if (userId && !ids.includes(userId)) ids.push(userId);
  }
  return ids;
}
