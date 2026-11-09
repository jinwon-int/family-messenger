//! #728 (ReplyQuote v2 후속): an owner's reply to a bubble arrives as
//!
//! ```text
//! > 공명✴️ #1253: <summary, ≤200 chars>
//!
//! <the reply>
//! ```
//!
//! (iOS `FamilyMLSCore/Agent/ReplyQuote.swift`). The agent only sees `prompt`
//! text — it cannot look up relay seq 1253 — so the bot keeps the room's
//! recent plaintexts in memory and, when the quoted seq is there, hands the
//! agent the whole original instead of the 200-char summary:
//!
//! ```text
//! [답장 대상 #1253 · 공명✴️]
//! <original, ≤ QUOTED_MAX_BYTES>
//!
//! <the reply>
//! ```
//!
//! The buffer is memory only (never written to disk, wiped on drop, lost on
//! restart) and per room, so a seq from another room can never match. A miss
//! (restart, older than the window, an attachment, v1 quote without `#seq`)
//! leaves the text exactly as sent — the summary is the fallback.

use std::collections::VecDeque;
use zeroize::Zeroizing;

/// Plaintexts kept per room (newest win; older ones drop off the front).
pub const RECENT_PER_ROOM: usize = 200;
/// Bytes of one kept plaintext (cut on a char boundary). Bot replies are
/// already ≤ 8 KiB (`DEFAULT_REPLY_MAX_BYTES`); this bounds a long human text.
pub const RECENT_TEXT_MAX_BYTES: usize = 16 * 1024;
/// Bytes of the original placed in the prompt (less if the reply itself needs
/// the room under the prompt cap).
pub const QUOTED_MAX_BYTES: usize = 8 * 1024;

const CUT_MARKER: &str = "\n…(길어서 줄임)";

/// A parsed reply head (Swift `ReplyQuote.Parsed`, the fields the bot uses).
#[derive(Debug, PartialEq, Eq)]
pub struct Parsed<'a> {
    /// Name label before `#seq` (`None` = no name).
    pub name: Option<&'a str>,
    /// The quoted relay seq (v2). `None` = v1 head or a label without a number.
    pub seq: Option<i64>,
    /// The reply body after the blank line.
    pub text: &'a str,
}

fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

fn trim_spaces(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_whitespace() && !is_newline(c))
}

/// Swift `ReplyQuote.parse`: exactly one `> ` head line, then a blank line,
/// then a non-blank body. Anything else is not a reply (`None`).
pub fn parse(body: &str) -> Option<Parsed<'_>> {
    let rest = body.strip_prefix("> ")?;
    let gap = rest.find("\n\n")?;
    let head = &rest[..gap];
    if head.contains(is_newline) {
        return None;
    }
    let quote = trim_spaces(head);
    let text = &rest[gap + 2..];
    if quote.is_empty() || text.trim().is_empty() {
        return None;
    }
    let (name, seq) = split_head(quote);
    Some(Parsed { name, seq, text })
}

/// Swift `ReplyQuote.splitHead` (label part): the text before the first `: `
/// is the label — `이름 #123` · `#123` · `이름`. The last `#` must open the
/// label or follow a space, and be followed by 1–18 ASCII digits > 0.
fn split_head(head: &str) -> (Option<&str>, Option<i64>) {
    let Some(colon) = head.find(": ") else { return (None, None) };
    let label = &head[..colon];
    if let Some(hash) = label.rfind('#') {
        let opens = hash == 0 || label[..hash].ends_with(' ');
        let digits = &label[hash + 1..];
        if opens && !digits.is_empty() && digits.len() <= 18 && digits.bytes().all(|b| b.is_ascii_digit()) {
            if let Ok(seq) = digits.parse::<i64>() {
                if seq > 0 {
                    let name = trim_spaces(&label[..hash]);
                    return ((!name.is_empty()).then_some(name), Some(seq));
                }
            }
        }
    }
    ((!label.is_empty()).then_some(label), None)
}

/// Cut on a char boundary at `max` bytes.
fn cut(text: &str, max: usize) -> &str {
    if text.len() <= max {
        return text;
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

struct Entry {
    seq: i64,
    sender: String,
    text: Zeroizing<String>,
}

/// One room's recent plaintexts (memory only).
#[derive(Default)]
pub struct Recent {
    entries: VecDeque<Entry>,
}

impl Recent {
    /// Keep `text` (from device `sender`) under relay `seq`. A seq already
    /// kept (a byte-equal replay, the bot's own echo read back) is ignored.
    pub fn record(&mut self, seq: i64, sender: &str, text: &str) {
        if seq <= 0 || text.trim().is_empty() || self.entries.iter().any(|e| e.seq == seq) {
            return;
        }
        self.entries.push_back(Entry {
            seq,
            sender: sender.to_string(),
            text: Zeroizing::new(cut(text, RECENT_TEXT_MAX_BYTES).to_string()),
        });
        while self.entries.len() > RECENT_PER_ROOM {
            self.entries.pop_front();
        }
    }

    /// `(sender device, text)` kept under `seq`.
    pub fn get(&self, seq: i64) -> Option<(&str, &str)> {
        self.entries.iter().rev().find(|e| e.seq == seq).map(|e| (e.sender.as_str(), e.text.as_str()))
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.entries.len()
    }
}

/// What `expand` did, for the journal (never the text).
#[derive(Debug, PartialEq, Eq)]
pub enum Expansion {
    /// Not a v2 reply (no quote head, or no `#seq`).
    NotReply,
    /// A v2 reply whose seq is not in this room's buffer.
    Miss { seq: i64 },
    /// The original was placed in the prompt.
    Hit { seq: i64, text: String },
}

/// The prompt for `text` in a room whose recent plaintexts are `recent`:
/// the quote head replaced by the whole original (bounded so original +
/// reply fit `budget` bytes, the reply never cut), or the text unchanged.
pub fn expand(text: &str, recent: &Recent, budget: usize) -> Expansion {
    let Some(parsed) = parse(text) else { return Expansion::NotReply };
    let Some(seq) = parsed.seq else { return Expansion::NotReply };
    let Some((sender, original)) = recent.get(seq) else { return Expansion::Miss { seq } };
    // The original's own reply head (a reply to a reply) is shown as the
    // apps show it: its body only.
    let original = parse(original).map_or(original, |p| p.text).trim_end();
    let label = parsed.name.unwrap_or_else(|| crate::responder::actor_of(sender));
    let header = format!("[답장 대상 #{seq} · {label}]\n");
    let room = budget.saturating_sub(header.len() + 2 + parsed.text.len()).min(QUOTED_MAX_BYTES);
    if room <= CUT_MARKER.len() {
        // The reply alone fills the prompt: keep it as sent.
        return Expansion::Miss { seq };
    }
    let quoted = if original.len() <= room {
        original.to_string()
    } else {
        format!("{}{CUT_MARKER}", cut(original, room - CUT_MARKER.len()).trim_end())
    };
    Expansion::Hit { seq, text: format!("{header}{quoted}\n\n{}", parsed.text) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_v2_heads_like_swift() {
        let p = parse("> 엄마 #1234: 내일 몇 시에 와?\n\n7시쯤!").unwrap();
        assert_eq!(p, Parsed { name: Some("엄마"), seq: Some(1234), text: "7시쯤!" });
        // No name.
        assert_eq!(parse("> #9: 요약\n\n답").unwrap(), Parsed { name: None, seq: Some(9), text: "답" });
        // Name with spaces and an emoji.
        assert_eq!(parse("> 공명 ✴️ #1253: x\n\ny").unwrap().name, Some("공명 ✴️"));
        // The summary may contain `: ` and `#`.
        assert_eq!(parse("> 아빠 #5: a: b #6\n\nc").unwrap().seq, Some(5));
        // Body keeps its own lines.
        assert_eq!(parse("> #5: s\n\nline1\n\nline2").unwrap().text, "line1\n\nline2");
    }

    #[test]
    fn v1_and_bad_numbers_have_no_seq() {
        assert_eq!(parse("> 엄마: 내일?\n\n응").unwrap().seq, None);
        assert_eq!(parse("> 엄마: 내일?\n\n응").unwrap().name, Some("엄마"));
        for head in ["엄마#12", "엄마 #0", "엄마 #-3", "엄마 #12a", "엄마 #", "엄마 #1234567890123456789", "엄마 #１２"] {
            let body = format!("> {head}: s\n\nr");
            assert_eq!(parse(&body).unwrap().seq, None, "{head}");
        }
        // No `: ` at all = the whole head is the summary.
        assert_eq!(parse("> 그냥 인용\n\n답").unwrap(), Parsed { name: None, seq: None, text: "답" });
    }

    #[test]
    fn not_a_reply() {
        for body in [
            "그냥 글",
            ">#5: s\n\nr",        // no space after `>`
            "> #5: s\nr",         // no blank line
            "> #5: s\n> more\n\nr", // multi-line quote
            "> #5: s\n\n   \n",   // blank body
            ">  \n\nr",           // empty head
        ] {
            assert_eq!(parse(body), None, "{body:?}");
        }
    }

    #[test]
    fn ring_buffer_is_bounded_and_dedups() {
        let mut r = Recent::default();
        for seq in 1..=(RECENT_PER_ROOM as i64 + 5) {
            r.record(seq, "owner-pc", &format!("m{seq}"));
        }
        assert_eq!(r.len(), RECENT_PER_ROOM);
        assert_eq!(r.get(5), None, "oldest dropped");
        assert_eq!(r.get(6), Some(("owner-pc", "m6")));
        r.record(6, "other", "replay");
        assert_eq!(r.get(6), Some(("owner-pc", "m6")), "first record of a seq wins");
        r.record(0, "x", "ignored");
        r.record(9999, "x", "  ");
        assert_eq!(r.get(9999), None);
        let long = "가".repeat(RECENT_TEXT_MAX_BYTES);
        r.record(10_000, "x", &long);
        let kept = r.get(10_000).unwrap().1;
        assert!(kept.len() <= RECENT_TEXT_MAX_BYTES && kept.chars().all(|c| c == '가'));
    }

    #[test]
    fn rooms_are_isolated() {
        let (mut a, b) = (Recent::default(), Recent::default());
        a.record(7, "owner-pc", "a 방 원문");
        assert!(matches!(expand("> #7: a\n\n답", &a, 15_000), Expansion::Hit { .. }));
        assert_eq!(expand("> #7: a\n\n답", &b, 15_000), Expansion::Miss { seq: 7 });
    }

    #[test]
    fn expands_a_hit_with_the_full_original() {
        let mut r = Recent::default();
        let original = format!("긴 원문 시작 {} 끝", "내용 ".repeat(100));
        r.record(1253, "gongmyung-bot", &original);
        let got = expand("> 공명✴️ #1253: 긴 원문 시작 …\n\n이거 다시 설명해줘", &r, 15_000);
        assert_eq!(got, Expansion::Hit { seq: 1253, text: format!("[답장 대상 #1253 · 공명✴️]\n{}\n\n이거 다시 설명해줘", original.trim_end()) });
        // No name in the head: the stored sender's actor.
        let Expansion::Hit { text, .. } = expand("> #1253: x\n\ny", &r, 15_000) else { panic!() };
        assert!(text.starts_with("[답장 대상 #1253 · gongmyung]\n긴 원문 시작"), "{text}");
    }

    #[test]
    fn misses_and_non_replies_leave_the_text() {
        let mut r = Recent::default();
        r.record(1, "owner-pc", "x");
        assert_eq!(expand("그냥 글", &r, 15_000), Expansion::NotReply);
        assert_eq!(expand("> 엄마: x\n\ny", &r, 15_000), Expansion::NotReply);
        assert_eq!(expand("> 엄마 #2: x\n\ny", &r, 15_000), Expansion::Miss { seq: 2 });
    }

    #[test]
    fn a_reply_to_a_reply_shows_the_original_body() {
        let mut r = Recent::default();
        r.record(3, "owner-pc", "> 봇 #2: 앞 글\n\n원래 내 말");
        let Expansion::Hit { text, .. } = expand("> 엄마 #3: 원래 내 말\n\n그래서?", &r, 15_000) else { panic!() };
        assert_eq!(text, "[답장 대상 #3 · 엄마]\n원래 내 말\n\n그래서?");
    }

    #[test]
    fn long_originals_are_cut_and_the_reply_is_kept_whole() {
        let mut r = Recent::default();
        r.record(4, "owner-pc", &"가".repeat(6000)); // 18 000 bytes, kept as ≤16 KiB
        let Expansion::Hit { text, .. } = expand("> #4: 가가\n\n짧은 답", &r, 15 * 1024) else { panic!() };
        assert!(text.ends_with("…(길어서 줄임)\n\n짧은 답"), "{}", &text[text.len() - 60..]);
        let quoted = text.split('\n').nth(1).unwrap();
        assert!(quoted.len() <= QUOTED_MAX_BYTES);
        // A reply that needs most of the budget shrinks the original further.
        let reply = "나".repeat(4000); // 12 000 bytes
        let Expansion::Hit { text, .. } = expand(&format!("> #4: 가가\n\n{reply}"), &r, 15 * 1024) else { panic!() };
        assert!(text.len() <= 15 * 1024 && text.ends_with(&reply), "{}", text.len());
        // A reply that fills the budget alone: unchanged (miss).
        let huge = "다".repeat(5200);
        assert_eq!(expand(&format!("> #4: 가가\n\n{huge}"), &r, 15 * 1024), Expansion::Miss { seq: 4 });
    }
}
