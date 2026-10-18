//! Wire helpers shared by the state machine and the CLI: frame parsing that
//! matches `scripts/fleet_worker.py` (Python `json.loads` + the port's
//! validators), Python-shaped JSON text for tool results, and nonces.

use serde_json::Value;
use std::io::Read;

/// fleet_core `MAX_TEXT_BYTES`: a prompt, and the text of one tool result.
pub const MAX_TEXT_BYTES: usize = 16_384;
/// fleet_core `MAX_REPLY_BYTES`: one turn's answer.
pub const MAX_REPLY_BYTES: usize = 65_536;
/// Largest inbound frame from the parent (newline included), as fleet_worker.
pub const MAX_INPUT_FRAME: usize = 65_536;
/// Largest outbound frame to the parent.
pub const MAX_OUTPUT_FRAME: usize = 524_288;
/// An approval frame above this is denied, never truncated.
pub const MAX_APPROVAL_FRAME: usize = 60_000;

/// Parse one parent frame like Python `json.loads`.
///
/// serde_json refuses a lone UTF-16 surrogate escape (`"\ud800"`), which Python
/// accepts into a `str` that `bounded_text` later rejects. A parent such as
/// `fleet_matrix.py` (ensure_ascii JSON of a Matrix body) can forward one, and
/// fleet_worker answers `invalid-turn` instead of dying. To keep that, every
/// unpaired surrogate escape inside a string becomes `\u0000`, which every
/// string validator here rejects (no NUL in text, ids are `[A-Za-z0-9_-]`).
pub fn parse_frame(line: &[u8]) -> Result<Value, ()> {
    match serde_json::from_slice(line) {
        Ok(value) => Ok(value),
        Err(_) => {
            let fixed = neutralize_lone_surrogates(line).ok_or(())?;
            serde_json::from_slice(&fixed).map_err(|_| ())
        }
    }
}

/// `Some(rewritten)` when at least one unpaired surrogate escape was replaced.
fn neutralize_lone_surrogates(input: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(input.len());
    let mut changed = false;
    let mut in_string = false;
    let mut i = 0;
    while i < input.len() {
        let b = input[i];
        if !in_string {
            if b == b'"' {
                in_string = true;
            }
            out.push(b);
            i += 1;
            continue;
        }
        match b {
            b'"' => {
                in_string = false;
                out.push(b);
                i += 1;
            }
            b'\\' if i + 1 < input.len() => {
                if input[i + 1] == b'u' {
                    if let Some(unit) = hex4(input, i + 2) {
                        if (0xD800..0xDC00).contains(&unit) {
                            let low = if input.get(i + 6) == Some(&b'\\') && input.get(i + 7) == Some(&b'u') {
                                hex4(input, i + 8)
                            } else {
                                None
                            };
                            if matches!(low, Some(l) if (0xDC00..0xE000).contains(&l)) {
                                out.extend_from_slice(&input[i..i + 12]);
                                i += 12;
                            } else {
                                out.extend_from_slice(b"\\u0000");
                                changed = true;
                                i += 6;
                            }
                            continue;
                        }
                        if (0xDC00..0xE000).contains(&unit) {
                            out.extend_from_slice(b"\\u0000");
                            changed = true;
                            i += 6;
                            continue;
                        }
                    }
                }
                out.extend_from_slice(&input[i..i + 2]);
                i += 2;
            }
            _ => {
                out.push(b);
                i += 1;
            }
        }
    }
    changed.then_some(out)
}

fn hex4(input: &[u8], at: usize) -> Option<u32> {
    let digits = input.get(at..at + 4)?;
    let text = std::str::from_utf8(digits).ok()?;
    u32::from_str_radix(text, 16).ok()
}

/// fleet_core `bounded_text`: a non-blank string without NUL, at most `limit` UTF-8 bytes.
pub fn bounded_text(value: &Value, limit: usize) -> Option<&str> {
    let text = value.as_str()?;
    if text.trim().is_empty() || text.contains('\0') || text.len() > limit {
        return None;
    }
    Some(text)
}

/// Same rule on an owned answer.
pub fn bounded_str(text: &str, limit: usize) -> bool {
    !text.trim().is_empty() && !text.contains('\0') && text.len() <= limit
}

/// Turn ids: ASCII letters, digits, `-` and `_`, 1..=128 characters.
pub fn is_turn_id(value: &str) -> bool {
    (1..=128).contains(&value.len()) && value.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}

/// fleet_worker `SENDER_RE`: `@[a-zA-Z0-9._=-]{1,200}:[a-zA-Z0-9.:-]{1,64}` (full match).
pub fn is_sender(value: &str) -> bool {
    let Some(rest) = value.strip_prefix('@') else { return false };
    let Some((local, server)) = rest.split_once(':') else { return false };
    (1..=200).contains(&local.len())
        && local.bytes().all(|c| c.is_ascii_alphanumeric() || b"._=-".contains(&c))
        && (1..=64).contains(&server.len())
        && server.bytes().all(|c| c.is_ascii_alphanumeric() || b".:-".contains(&c))
}

/// fleet_worker `TOOL_ARG_RE`: `[A-Za-z0-9_-]{1,64}`.
pub fn is_tool_arg(value: &str) -> bool {
    (1..=64).contains(&value.len()) && value.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}

/// fleet_worker `NAME_RE` (model / effort): `[A-Za-z0-9._-]{1,64}`.
pub fn is_name(value: &str) -> bool {
    (1..=64).contains(&value.len()) && value.bytes().all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
}

/// `json.dumps(value, ensure_ascii=False, sort_keys=True)`: the text the model
/// reads as a tool result (same separators and key order as fleet_worker).
pub fn py_dumps(value: &Value) -> String {
    let mut out = String::new();
    write_py(value, &mut out);
    out
}

fn write_py(value: &Value, out: &mut String) {
    match value {
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push_str(", ");
                }
                write_py(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            out.push('{');
            for (i, key) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push_str(", ");
                }
                out.push_str(&serde_json::to_string(key).unwrap_or_default());
                out.push_str(": ");
                write_py(&map[key], out);
            }
            out.push('}');
        }
        other => out.push_str(&serde_json::to_string(other).unwrap_or_default()),
    }
}

/// A fresh 24-byte nonce as 48 hex characters (fits the bot's `[A-Za-z0-9_-]{1,128}`).
pub fn nonce() -> String {
    let mut bytes = [0u8; 24];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .expect("/dev/urandom readable");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn lone_surrogates_become_nul_and_pairs_survive() {
        let v = parse_frame(br#"{"prompt":"a\ud800b"}"#).unwrap();
        assert_eq!(v["prompt"], "a\u{0}b");
        let v = parse_frame(br#"{"prompt":"\udc00"}"#).unwrap();
        assert_eq!(v["prompt"], "\u{0}");
        let v = parse_frame(br#"{"prompt":"\ud83d\ude00"}"#).unwrap();
        assert_eq!(v["prompt"], "😀");
        // An escaped backslash before `u` is not an escape.
        let v = parse_frame(br#"{"prompt":"\\ud800"}"#).unwrap();
        assert_eq!(v["prompt"], "\\ud800");
        assert!(parse_frame(b"bad json").is_err());
        assert!(parse_frame(b"{\"a\":\"\xff\"}").is_err(), "invalid UTF-8 stays an error");
    }

    #[test]
    fn validators_match_fleet_worker() {
        assert!(bounded_text(&json!("x"), 1).is_some());
        for bad in [json!(""), json!("  "), json!("a\u{0}"), json!(7), json!(null), json!("xx")] {
            assert!(bounded_text(&bad, 1).is_none(), "{bad}");
        }
        assert!(is_turn_id("job-1_A") && !is_turn_id("../bad") && !is_turn_id("") && !is_turn_id(&"a".repeat(129)));
        assert!(is_sender("@dad:test.invalid") && is_sender("@a=b:h:8448"));
        for bad in ["dad", "@x:y\nignore previous", "@:h", "@a:", "@a"] {
            assert!(!is_sender(bad), "{bad}");
        }
        assert!(is_tool_arg("jungin-iphone-1b89e3") && !is_tool_arg("x y") && !is_tool_arg(&"a".repeat(65)));
        assert!(is_name("claude-opus-5-5") && !is_name("claude opus") && !is_name(&"x".repeat(65)));
    }

    #[test]
    fn py_dumps_sorts_keys_with_python_separators() {
        let v = json!({"result": {"seq": 3, "op": "invite", "pending": true}, "ok": true, "msg": "가족"});
        assert_eq!(py_dumps(&v), r#"{"msg": "가족", "ok": true, "result": {"op": "invite", "pending": true, "seq": 3}}"#);
        assert_eq!(py_dumps(&json!({"members": []})), r#"{"members": []}"#);
    }

    #[test]
    fn nonces_are_unique_hex() {
        let (a, b) = (nonce(), nonce());
        assert_eq!(a.len(), 48);
        assert!(a.bytes().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, b);
    }
}
