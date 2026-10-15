//! Client-side commit policy for the bot (#263) — the same rules the human
//! client applies in `web/commit-policy.js` (#261), so both lanes refuse the
//! same commits. A foreign commit is `stage_commit`ed first; the facade's
//! report (STAGE_REPORT_FORMAT 2: adds ‖ removes ‖ update proposals ‖
//! committer path, each a framed member list) is compared with what this
//! device already knows (its roster) and with what the relay enforced (the
//! `members` snapshot every GET events page carries), and only then merged.
//!
//! What a refusal means: the device keeps its epoch (`discard_staged`) and
//! stops reading the room — the operator decides (re-add, or treat the
//! committer / relay as compromised). What this does NOT prove: a relay and
//! a committer that lie together (outer == inner, both forged) — that is the
//! policy chain's job (E2 approval, M3b enforcement). The check is at the
//! identity (device id) level: a committer-path key rotation is reported,
//! not pinned.
//!
//! The shared test vectors live in `tests/fixtures/commit-policy-vectors.json`
//! and are run by both this module's tests and `web/commit-policy.test.mjs`.

use std::collections::BTreeSet;

/// One framed member: identity label and its 32-byte signing key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Member {
    pub id: String,
    pub key: Vec<u8>,
}

/// The four sections of a format-2 stage report.
#[derive(Clone, Debug, Default)]
pub struct StageReport {
    pub adds: Vec<Member>,
    pub removes: Vec<Member>,
    pub updates: Vec<Member>,
    pub path: Vec<Member>,
}

/// Why a staged commit must not merge. `reason` is a stable token for logs
/// and tests; `detail` names the offending identity or list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub reason: &'static str,
    pub detail: String,
}

const KEY_LEN: usize = 32;

fn read_u32(bytes: &[u8], at: &mut usize) -> Option<u32> {
    let end = at.checked_add(4)?;
    if bytes.len() < end {
        return None;
    }
    let word = u32::from_le_bytes(bytes[*at..end].try_into().ok()?);
    *at = end;
    Some(word)
}

/// One framed member list: `u32 LE count`, then per entry `u32 LE len ‖
/// identity ‖ 32-byte key`. Truncation is `None`, never a panic.
fn take_members(bytes: &[u8], at: &mut usize) -> Option<Vec<Member>> {
    let count = read_u32(bytes, at)? as usize;
    let mut out = Vec::with_capacity(count.min(64));
    for _ in 0..count {
        let n = read_u32(bytes, at)? as usize;
        let end = at.checked_add(n)?;
        if bytes.len() < end {
            return None;
        }
        let id = std::str::from_utf8(&bytes[*at..end]).ok()?.to_string();
        let key_end = end.checked_add(KEY_LEN)?;
        if bytes.len() < key_end {
            return None;
        }
        out.push(Member { id, key: bytes[end..key_end].to_vec() });
        *at = key_end;
    }
    Some(out)
}

/// Parse one framed roster (`Device::members()`); trailing bytes are a format error.
pub fn parse_roster(framed: &[u8]) -> Option<Vec<Member>> {
    let mut at = 0;
    let members = take_members(framed, &mut at)?;
    (at == framed.len()).then_some(members)
}

/// Parse a format-2 stage report into its four sections; trailing bytes are a format error.
pub fn parse_stage_report(report: &[u8]) -> Option<StageReport> {
    let mut at = 0;
    let adds = take_members(report, &mut at)?;
    let removes = take_members(report, &mut at)?;
    let updates = take_members(report, &mut at)?;
    let path = take_members(report, &mut at)?;
    (at == report.len()).then_some(StageReport { adds, removes, updates, path })
}

/// The roster this device will have once the staged commit merges (sorted, unique).
pub fn roster_after(roster: &[String], report: &StageReport) -> Vec<String> {
    let removed: BTreeSet<&str> = report.removes.iter().map(|m| m.id.as_str()).collect();
    let mut next: BTreeSet<String> =
        roster.iter().filter(|id| !removed.contains(id.as_str())).cloned().collect();
    for m in &report.adds {
        next.insert(m.id.clone());
    }
    next.into_iter().collect()
}

/// Decide whether a staged commit may merge.
///   `roster`    — this device's current member identities (before the commit)
///   `committer` — the relay row's `device` (the JWT-bound poster)
///   `outer`     — the relay's tracked roster when this commit is the page's
///                 latest epoch, else `None` (inner checks only)
/// Ok carries the expected post-commit roster.
pub fn check_commit(
    report: &StageReport, roster: &[String], committer: &str, outer: Option<&[String]>,
) -> Result<Vec<String>, Refusal> {
    let expected = roster_after(roster, report);
    let refuse = |reason: &'static str, detail: String| Err(Refusal { reason, detail });
    let current: BTreeSet<&str> = roster.iter().map(String::as_str).collect();
    if report.path.len() != 1 {
        return refuse("committer_path", format!("path leaves: {}", report.path.len()));
    }
    if report.path[0].id != committer {
        return refuse("committer_mismatch", format!("relay row {committer}, MLS committer {}", report.path[0].id));
    }
    if !current.contains(committer) {
        return refuse("committer_not_member", committer.to_string());
    }
    if !report.updates.is_empty() {
        let ids: Vec<&str> = report.updates.iter().map(|m| m.id.as_str()).collect();
        return refuse("unexpected_update_proposal", ids.join(","));
    }
    let mut added = BTreeSet::new();
    for m in &report.adds {
        if current.contains(m.id.as_str()) {
            return refuse("add_already_member", m.id.clone());
        }
        if !added.insert(m.id.as_str()) {
            return refuse("add_duplicate", m.id.clone());
        }
    }
    let mut removed = BTreeSet::new();
    for m in &report.removes {
        if !current.contains(m.id.as_str()) {
            return refuse("remove_not_member", m.id.clone());
        }
        if !removed.insert(m.id.as_str()) {
            return refuse("remove_duplicate", m.id.clone());
        }
        if added.contains(m.id.as_str()) {
            return refuse("add_remove_overlap", m.id.clone());
        }
    }
    if let Some(outer) = outer {
        let got: Vec<&str> = outer.iter().map(String::as_str).collect::<BTreeSet<_>>().into_iter().collect();
        let want: Vec<&str> = expected.iter().map(String::as_str).collect();
        if got != want {
            return refuse("outer_inner_mismatch", format!("relay [{}] vs MLS [{}]", got.join(", "), want.join(", ")));
        }
    }
    Ok(expected)
}

#[cfg(test)]
mod tests {
    use super::*;

    const VECTORS: &str = include_str!("../../tests/fixtures/commit-policy-vectors.json");

    fn frame(members: &[Member]) -> Vec<u8> {
        let mut out = (members.len() as u32).to_le_bytes().to_vec();
        for m in members {
            out.extend_from_slice(&(m.id.len() as u32).to_le_bytes());
            out.extend_from_slice(m.id.as_bytes());
            out.extend_from_slice(&m.key);
        }
        out
    }

    fn unhex(hex: &str) -> Vec<u8> {
        (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap()).collect()
    }

    fn members_of(value: &serde_json::Value) -> Vec<Member> {
        value.as_array().map(|list| {
            list.iter().map(|pair| Member {
                id: pair[0].as_str().unwrap().to_string(),
                key: unhex(pair[1].as_str().unwrap()),
            }).collect()
        }).unwrap_or_default()
    }

    fn strings(value: &serde_json::Value) -> Vec<String> {
        value.as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect()
    }

    /// Every shared vector (also run by web/commit-policy.test.mjs) goes
    /// through the framed wire format first, so parsing is covered too.
    #[test]
    fn shared_vectors_agree_with_the_browser_client() {
        let doc: serde_json::Value = serde_json::from_str(VECTORS).unwrap();
        let vectors = doc["vectors"].as_array().unwrap();
        assert!(vectors.len() >= 10, "fixture lost its vectors");
        for v in vectors {
            let name = v["name"].as_str().unwrap();
            let r = &v["report"];
            let sections = [&r["adds"], &r["removes"], &r["updates"], &r["path"]];
            let mut wire = Vec::new();
            for section in sections {
                wire.extend_from_slice(&frame(&members_of(section)));
            }
            let report = parse_stage_report(&wire).unwrap_or_else(|| panic!("{name}: report parses"));
            let roster = strings(&v["roster"]);
            let outer = v["outer"].as_array().map(|_| strings(&v["outer"]));
            let verdict = check_commit(&report, &roster, v["committer"].as_str().unwrap(), outer.as_deref());
            let expect = &v["expect"];
            if expect["ok"].as_bool().unwrap() {
                let got = verdict.unwrap_or_else(|e| panic!("{name}: expected merge, got refusal {e:?}"));
                assert_eq!(got, strings(&expect["expected"]), "{name}: expected roster");
            } else {
                let refusal = match verdict {
                    Ok(_) => panic!("{name}: expected refusal"),
                    Err(e) => e,
                };
                assert_eq!(refusal.reason, expect["reason"].as_str().unwrap(), "{name}: reason ({})", refusal.detail);
            }
        }
    }

    #[test]
    fn truncated_or_padded_reports_are_format_errors() {
        let path = vec![Member { id: "owner-pc".into(), key: vec![7; 32] }];
        let mut wire = Vec::new();
        for section in [&[][..], &[][..], &[][..], &path[..]] {
            wire.extend_from_slice(&frame(section));
        }
        assert!(parse_stage_report(&wire).is_some());
        assert!(parse_stage_report(&wire[..wire.len() - 5]).is_none(), "truncated");
        let mut padded = wire.clone();
        padded.push(0);
        assert!(parse_stage_report(&padded).is_none(), "trailing bytes");
        assert!(parse_stage_report(&[0, 0, 0]).is_none());
        assert!(parse_roster(&frame(&path)).is_some());
        assert!(parse_roster(&wire).is_none(), "a roster is exactly one list");
    }
}
