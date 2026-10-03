// Client-side commit policy check (#261): a foreign commit is staged first
// (`stage_commit` → STAGE_REPORT_FORMAT 2: adds ‖ removes ‖ update proposals ‖
// committer path, each a framed member list), then compared with what this
// device already knows (its roster) and what the relay enforced (the outer
// `members` snapshot the GET events page carries), and only then merged.
// Pure functions, no DOM, no wasm: `node --test web/commit-policy.test.mjs`.
//
// What a refusal means: the device keeps its epoch (`discard_staged`) and must
// not read the group further — the operator decides (re-add, or treat the
// relay/committer as compromised). What this does NOT prove: a relay and a
// committer that lie together (outer == inner, both forged) — that is the
// policy chain's job (E2 approval, M3b enforcement), not this check's.

const decoder = new TextDecoder();

/** One framed member list: u32 LE count, then per entry u32 LE len ‖ identity ‖ 32-byte key. */
function takeMembers(bytes, at) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (at + 4 > bytes.length) throw new Error('stage report truncated');
  const count = view.getUint32(at, true); at += 4;
  const out = [];
  for (let i = 0; i < count; i++) {
    if (at + 4 > bytes.length) throw new Error('stage report truncated');
    const n = view.getUint32(at, true); at += 4;
    if (at + n + 32 > bytes.length) throw new Error('stage report truncated');
    out.push({id: decoder.decode(bytes.subarray(at, at + n)), key: hex(bytes.subarray(at + n, at + n + 32))});
    at += n + 32;
  }
  return [out, at];
}

export function hex(bytes) { return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join(''); }

/** Parse a format-2 stage report into its four sections; trailing bytes are a format error. */
export function parseStageReport(report) {
  const bytes = report instanceof Uint8Array ? report : new Uint8Array(report);
  let at = 0, adds, removes, updates, path;
  [adds, at] = takeMembers(bytes, at);
  [removes, at] = takeMembers(bytes, at);
  [updates, at] = takeMembers(bytes, at);
  [path, at] = takeMembers(bytes, at);
  if (at !== bytes.length) throw new Error('stage report has trailing bytes');
  return {adds, removes, updates, path};
}

/** The roster this device will have once the staged commit merges (sorted, unique). */
export function rosterAfter(roster, report) {
  const removed = new Set(report.removes.map(m => m.id));
  const next = new Set(roster.filter(id => !removed.has(id)));
  for (const m of report.adds) next.add(m.id);
  return Array.from(next).sort();
}

/**
 * Decide whether a staged commit may merge.
 *   roster    — this device's current member identities (before the commit)
 *   committer — the relay row's `device` (the JWT-bound poster)
 *   outer     — the relay's tracked roster (device ids) when this commit is the
 *               page's latest epoch, else null (inner checks only)
 * Returns {ok: true, expected} or {ok: false, reason, detail, expected}.
 */
export function checkCommit({report, roster, committer, outer = null}) {
  const expected = rosterAfter(roster, report);
  const refuse = (reason, detail) => ({ok: false, reason, detail, expected});
  const current = new Set(roster);
  if (report.path.length !== 1) return refuse('committer_path', `path leaves: ${report.path.length}`);
  if (report.path[0].id !== committer) return refuse('committer_mismatch', `relay row ${committer}, MLS committer ${report.path[0].id}`);
  if (!current.has(committer)) return refuse('committer_not_member', committer);
  if (report.updates.length) return refuse('unexpected_update_proposal', report.updates.map(m => m.id).join(','));
  const added = new Set(), removed = new Set();
  for (const m of report.adds) {
    if (current.has(m.id)) return refuse('add_already_member', m.id);
    if (added.has(m.id)) return refuse('add_duplicate', m.id);
    added.add(m.id);
  }
  for (const m of report.removes) {
    if (!current.has(m.id)) return refuse('remove_not_member', m.id);
    if (removed.has(m.id)) return refuse('remove_duplicate', m.id);
    if (added.has(m.id)) return refuse('add_remove_overlap', m.id);
    removed.add(m.id);
  }
  if (outer !== null) {
    const got = Array.from(new Set(outer)).sort();
    if (got.length !== expected.length || got.some((id, i) => id !== expected[i])) {
      return refuse('outer_inner_mismatch', `relay [${got.join(', ')}] vs MLS [${expected.join(', ')}]`);
    }
  }
  return {ok: true, expected};
}
