//! Command line and harness options: the Rust twin of fleet_worker's argparse
//! block and `harness_options()` (#396). The result is the `configure` frame
//! the Python adapter turns into ccc-node `Runtime(**runtime_options)` and
//! `SessionRequest(session_id=…, **request_options)` — the adapter adds nothing.

use crate::wire::is_name;
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;

pub const PROVIDERS: [&str; 2] = ["codex", "claude"];
pub const APPROVAL_POLICIES: [&str; 4] = ["never", "on-request", "on-failure", "untrusted"];
pub const SANDBOXES: [&str; 3] = ["dangerFullAccess", "readOnly", "workspaceWrite"];
/// ccc-node ClaudeRuntime permission modes (`claude_runtime_options._PERMISSION_MODES`).
pub const CLAUDE_PERMISSION_MODES: [&str; 5] = ["default", "acceptEdits", "plan", "dontAsk", "auto"];

/// One steward room tool (#372 P4): required args, optional args, model-facing description.
pub struct StewardTool {
    pub name: &'static str,
    pub required: &'static [&'static str],
    pub optional: &'static [&'static str],
    pub description: &'static str,
}

pub const STEWARD_SERVER: &str = "steward";
/// Same table, same text as fleet_worker `STEWARD_TOOLS`.
pub const STEWARD_TOOLS: &[StewardTool] = &[
    StewardTool {
        name: "room_create",
        required: &["room"],
        optional: &["mode"],
        description: "새 E2EE 대화방을 만든다(봇이 방장). mode 는 agent|silent(기본 silent: 봇이 답하지 않음). \
                      릴레이에는 첫 초대 때 생긴다. 오너(owner actor)가 보낸 메시지의 turn 에서만 실행된다.",
    },
    StewardTool {
        name: "room_join",
        required: &["room"],
        optional: &[],
        description: "다른 기기가 만든 방에 참여 요청(key package 게시). 그 방의 멤버가 봇을 초대해야 들어간다. \
                      오너 turn 전용.",
    },
    StewardTool {
        name: "room_invite",
        required: &["room", "device"],
        optional: &[],
        description: "기기를 방에 초대한다. 상대 기기가 먼저 그 방에 「참여 요청」(key package)을 해 두어야 한다. \
                      device 는 기기 ID(예: jungin-iphone-1b89e3). 오너 turn 전용.",
    },
    StewardTool {
        name: "room_remove",
        required: &["room", "device"],
        optional: &[],
        description: "기기를 방에서 제거한다(되돌릴 수 없음 — 다시 초대해야 한다). 오너 turn 전용.",
    },
    StewardTool {
        name: "room_close",
        required: &["room"],
        optional: &[],
        description: "방을 닫는다(되돌릴 수 없음 — 릴레이가 방을 닫아 모든 멤버에게 「닫힘」이 되고 다시 열 수 없다. \
                      다시 쓰려면 새 방을 만들어 초대한다). 봇이 답하는 agent 모드 방은 닫지 않는다(먼저 silent). \
                      오너 turn 전용.",
    },
    StewardTool {
        name: "room_members",
        required: &["room"],
        optional: &[],
        description: "방의 멤버 기기와 epoch·cursor 를 본다(읽기 전용). 오너 turn 전용.",
    },
    StewardTool {
        name: "room_mode",
        required: &["room", "mode"],
        optional: &[],
        description: "방 모드를 바꾼다: agent(봇이 답함, 한 방만) | silent(듣기만). 오너 turn 전용.",
    },
    StewardTool {
        name: "room_status",
        required: &[],
        optional: &[],
        description: "봇이 아는 모든 방의 상태(joined·epoch·cursor·mode·pending)를 본다(읽기 전용). 오너 turn 전용.",
    },
];
/// Read-only steward tools (#378): no MLS/relay side effect, so they may run
/// without the per-call room approval. The bot still enforces owner-only.
pub const STEWARD_READ_ONLY: [&str; 2] = ["room_status", "room_members"];

pub fn steward_tool(name: &str) -> Option<&'static StewardTool> {
    STEWARD_TOOLS.iter().find(|t| t.name == name)
}

/// SDK allow-list names (`mcp__steward__<tool>`) for the approval-free read-only tools.
pub fn steward_allowed_tools(approve_all: bool) -> Vec<String> {
    if approve_all {
        return Vec::new();
    }
    STEWARD_READ_ONLY
        .iter()
        .filter(|name| steward_tool(name).is_some())
        .map(|name| format!("mcp__{STEWARD_SERVER}__{name}"))
        .collect()
}

#[derive(Clone, Debug, PartialEq)]
pub struct Args {
    pub adapter_argv: Vec<String>,
    pub workdir: String,
    pub provider: String,
    pub codex_cli: Option<String>,
    pub claude_permission_mode: String,
    pub turn_timeout: f64,
    pub approval_timeout: f64,
    pub steward_tools: bool,
    pub tool_timeout: f64,
    pub steward_tools_approve_all: bool,
    pub memory_materializer: Option<String>,
    pub approval_policy: String,
    pub sandbox: String,
    pub working_state: String,
    pub model: Option<String>,
    pub effort: Option<String>,
}

impl Args {
    pub fn defaults() -> Self {
        Args {
            adapter_argv: Vec::new(),
            workdir: String::new(),
            provider: "codex".into(),
            codex_cli: None,
            claude_permission_mode: "default".into(),
            turn_timeout: 900.0,
            approval_timeout: 120.0,
            steward_tools: false,
            tool_timeout: 90.0,
            steward_tools_approve_all: false,
            memory_materializer: None,
            approval_policy: "never".into(),
            sandbox: "readOnly".into(),
            working_state: "off".into(),
            model: None,
            effort: None,
        }
    }

    pub fn timeouts(&self) -> Result<(Duration, Duration, Duration), String> {
        let mut out = Vec::new();
        for value in [self.turn_timeout, self.approval_timeout, self.tool_timeout] {
            if !value.is_finite() || value <= 0.0 {
                return Err("timeouts must be finite and positive".into());
            }
            // Python accepts any finite value; cap so `Instant + d` cannot overflow.
            out.push(Duration::from_secs_f64(value.min(MAX_TIMEOUT_SECS)));
        }
        Ok((out[0], out[1], out[2]))
    }
}

/// Ten years: longer timeouts behave the same and stay addable to `Instant`.
const MAX_TIMEOUT_SECS: f64 = 315_360_000.0;

pub const USAGE: &str = "usage: native-responder --adapter-argv-json '[\"python\",\"…/ccc_adapter.py\"]' --workdir DIR \
[--provider codex|claude] [--codex-cli PATH] [--claude-permission-mode MODE] [--turn-timeout S] \
[--approval-timeout S] [--steward-tools] [--tool-timeout S] [--steward-tools-approve-all] \
[--memory-materializer PATH] [--approval-policy P] [--sandbox S] [--working-state off|inherit] \
[--model M] [--effort E]   (env NATIVE_RESPONDER_ADAPTER_ARGV_JSON for the adapter argv)";

/// Parse argv (without the program name). `--flag value` and `--flag=value` both work.
pub fn parse_args(argv: &[String], adapter_env: Option<String>) -> Result<Args, String> {
    let mut args = Args::defaults();
    let mut adapter_json = adapter_env.filter(|v| !v.trim().is_empty());
    let mut workdir = None;
    let mut i = 0;
    while i < argv.len() {
        let (flag, inline) = match argv[i].split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f.to_string(), Some(v.to_string())),
            _ => (argv[i].clone(), None),
        };
        i += 1;
        let switch = matches!(flag.as_str(), "--steward-tools" | "--steward-tools-approve-all");
        if switch {
            if inline.is_some() {
                return Err(format!("{flag} takes no value"));
            }
            match flag.as_str() {
                "--steward-tools" => args.steward_tools = true,
                _ => args.steward_tools_approve_all = true,
            }
            continue;
        }
        let value = match inline {
            Some(v) => v,
            None => {
                let v = argv.get(i).cloned().ok_or_else(|| format!("{flag} needs a value"))?;
                i += 1;
                v
            }
        };
        let choice = |allowed: &[&str], v: String| -> Result<String, String> {
            if allowed.contains(&v.as_str()) { Ok(v) } else { Err(format!("{flag}: invalid choice")) }
        };
        let float = |v: &str| -> Result<f64, String> { v.trim().parse::<f64>().map_err(|_| format!("{flag}: not a number")) };
        match flag.as_str() {
            "--adapter-argv-json" => adapter_json = Some(value),
            "--workdir" => workdir = Some(value),
            "--provider" => args.provider = choice(&PROVIDERS, value)?,
            "--codex-cli" => args.codex_cli = Some(value),
            "--claude-permission-mode" => args.claude_permission_mode = choice(&CLAUDE_PERMISSION_MODES, value)?,
            "--turn-timeout" => args.turn_timeout = float(&value)?,
            "--approval-timeout" => args.approval_timeout = float(&value)?,
            "--tool-timeout" => args.tool_timeout = float(&value)?,
            "--memory-materializer" => args.memory_materializer = Some(value),
            "--approval-policy" => args.approval_policy = choice(&APPROVAL_POLICIES, value)?,
            "--sandbox" => args.sandbox = choice(&SANDBOXES, value)?,
            "--working-state" => args.working_state = choice(&["off", "inherit"], value)?,
            "--model" => args.model = Some(value),
            "--effort" => args.effort = Some(value),
            _ => return Err(format!("unknown argument {flag}")),
        }
    }
    args.workdir = workdir.ok_or("--workdir is required")?;
    let raw = adapter_json.ok_or("--adapter-argv-json (or NATIVE_RESPONDER_ADAPTER_ARGV_JSON) is required")?;
    let argv: Vec<String> = serde_json::from_str(&raw).map_err(|_| "adapter argv must be a JSON string array")?;
    if argv.is_empty() || argv.iter().any(|a| a.is_empty() || a.contains('\0')) {
        return Err("adapter argv must be a non-empty JSON string array".into());
    }
    args.adapter_argv = argv;
    Ok(args)
}

/// `(runtime_options, request_options)` exactly as fleet_worker `harness_options`.
/// `environment` feeds `--working-state inherit` (the service unit's env).
pub fn harness_options(args: &Args, environment: &BTreeMap<String, String>) -> Result<(Value, Value), String> {
    if !PROVIDERS.contains(&args.provider.as_str()) {
        return Err("unknown provider".into());
    }
    if args.provider != "claude" && args.steward_tools {
        return Err("--steward-tools needs --provider claude (SDK MCP tools)".into());
    }
    let workdir = resolve(&args.workdir);
    let mut request = Map::new();
    request.insert("working_directory".into(), json!(workdir));
    let add_names = |request: &mut Map<String, Value>| -> Result<(), String> {
        for (key, value) in [("model", &args.model), ("effort", &args.effort)] {
            if let Some(v) = value {
                if !is_name(v) {
                    return Err(format!("invalid {key}"));
                }
                request.insert(key.into(), json!(v));
            }
        }
        Ok(())
    };
    if args.provider == "claude" {
        if args.memory_materializer.is_some() {
            return Err("memory materializer is a Codex binding; Claude reads the harness from the workdir".into());
        }
        if args.sandbox != "readOnly" || args.approval_policy != "never" {
            return Err("--sandbox/--approval-policy are Codex flags; use --claude-permission-mode".into());
        }
        if !CLAUDE_PERMISSION_MODES.contains(&args.claude_permission_mode.as_str()) {
            return Err("unknown Claude permission mode".into());
        }
        request.insert("approval_policy".into(), json!(args.claude_permission_mode));
        add_names(&mut request)?;
        return Ok((json!({}), Value::Object(request)));
    }
    let cli = args.codex_cli.as_ref().ok_or("--codex-cli is required for the codex provider")?;
    let mut runtime = Map::new();
    runtime.insert("cli_path".into(), json!(cli));
    let working_state = if args.working_state == "inherit" {
        json!(environment)
    } else {
        json!({"CCC_WORKING_STATE_ARCHIVE": "0"})
    };
    runtime.insert("working_state_environment".into(), working_state);
    if let Some(path) = &args.memory_materializer {
        let p = Path::new(path);
        if !p.is_absolute() || !p.is_file() {
            return Err("memory materializer unavailable".into());
        }
        runtime.insert("memory_materializer_path".into(), json!(path));
    }
    if !APPROVAL_POLICIES.contains(&args.approval_policy.as_str()) || !SANDBOXES.contains(&args.sandbox.as_str()) {
        return Err("unknown execution policy".into());
    }
    let sandbox = match args.sandbox.as_str() {
        "workspaceWrite" => json!({"type": "workspaceWrite", "networkAccess": false}),
        other => json!({"type": other}),
    };
    request.insert("approval_policy".into(), json!(args.approval_policy));
    request.insert("sandbox_policy".into(), sandbox);
    add_names(&mut request)?;
    Ok((Value::Object(runtime), Value::Object(request)))
}

/// `Path(p).resolve()`: canonical when it exists, else absolute as given.
fn resolve(path: &str) -> String {
    std::fs::canonicalize(path)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| path.to_string())
}

/// fleet_worker `main()` path checks, then the full `configure` frame for the adapter.
pub fn configure_frame(args: &Args, environment: &BTreeMap<String, String>) -> Result<Value, String> {
    if !Path::new(&args.workdir).is_dir() {
        return Err("worker paths unavailable".into());
    }
    if args.provider == "codex" && !args.codex_cli.as_deref().map(|p| Path::new(p).is_file()).unwrap_or(false) {
        return Err("worker paths unavailable".into());
    }
    let (runtime, request) = harness_options(args, environment)?;
    let steward = if args.steward_tools {
        let tools: Vec<Value> = STEWARD_TOOLS
            .iter()
            .map(|t| {
                let arguments: Vec<&str> = t.required.iter().chain(t.optional.iter()).copied().collect();
                json!({"name": t.name, "description": t.description, "arguments": arguments})
            })
            .collect();
        json!({"server": STEWARD_SERVER, "tools": tools,
               "allowed_tools": steward_allowed_tools(args.steward_tools_approve_all)})
    } else {
        Value::Null
    };
    Ok(json!({"type": "configure", "protocol": 1, "provider": args.provider,
              "runtime_options": runtime, "request_options": request, "steward": steward}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env() -> BTreeMap<String, String> {
        [("CCC_WORKING_STATE_DIR", "/x"), ("HOME", "/h")].iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    fn codex() -> Args {
        Args { workdir: "/tmp".into(), codex_cli: Some("/usr/bin/codex".into()), ..Args::defaults() }
    }

    fn claude() -> Args {
        Args { workdir: "/tmp".into(), provider: "claude".into(), ..Args::defaults() }
    }

    #[test]
    fn defaults_reproduce_read_only_pilot_binding() {
        let (runtime, request) = harness_options(&codex(), &env()).unwrap();
        assert_eq!(runtime, json!({"cli_path": "/usr/bin/codex", "working_state_environment": {"CCC_WORKING_STATE_ARCHIVE": "0"}}));
        assert_eq!(request, json!({"working_directory": "/tmp", "approval_policy": "never", "sandbox_policy": {"type": "readOnly"}}));
    }

    #[test]
    fn harness_flags_bind_memory_policy_and_model() {
        let dir = std::env::temp_dir().join(format!("nr-harness-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("materialize.py");
        std::fs::write(&script, "").unwrap();
        let script = script.to_string_lossy().into_owned();
        let args = Args {
            memory_materializer: Some(script.clone()),
            working_state: "inherit".into(),
            approval_policy: "on-request".into(),
            sandbox: "workspaceWrite".into(),
            model: Some("gpt-6-astra".into()),
            effort: Some("high".into()),
            ..codex()
        };
        let (runtime, request) = harness_options(&args, &env()).unwrap();
        assert_eq!(runtime, json!({"cli_path": "/usr/bin/codex", "working_state_environment": {"CCC_WORKING_STATE_DIR": "/x", "HOME": "/h"},
                                   "memory_materializer_path": script}));
        assert_eq!(request, json!({"working_directory": "/tmp", "approval_policy": "on-request",
                                   "sandbox_policy": {"type": "workspaceWrite", "networkAccess": false},
                                   "model": "gpt-6-astra", "effort": "high"}));
        let missing = dir.join("missing.py").to_string_lossy().into_owned();
        for bad in [
            Args { memory_materializer: Some(missing), ..codex() },
            Args { memory_materializer: Some("relative.py".into()), ..codex() },
            Args { model: Some("gpt 6".into()), ..codex() },
            Args { effort: Some("x".repeat(65)), ..codex() },
            Args { sandbox: "full".into(), ..codex() },
            Args { approval_policy: "auto".into(), ..codex() },
        ] {
            assert!(harness_options(&bad, &env()).is_err(), "{bad:?}");
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn claude_provider_builds_bare_runtime_and_permission_mode() {
        let args = Args { model: Some("claude-opus-5-5".into()), effort: Some("high".into()), ..claude() };
        let (runtime, request) = harness_options(&args, &env()).unwrap();
        assert_eq!(runtime, json!({}), "ClaudeRuntime is constructed bare");
        assert_eq!(request, json!({"working_directory": "/tmp", "approval_policy": "default", "model": "claude-opus-5-5", "effort": "high"}));
        for bad in [
            Args { memory_materializer: Some("/x/m.py".into()), ..claude() },
            Args { sandbox: "workspaceWrite".into(), ..claude() },
            Args { approval_policy: "on-request".into(), ..claude() },
            Args { claude_permission_mode: "bypassPermissions".into(), ..claude() },
            Args { model: Some("claude opus".into()), ..claude() },
            Args { provider: "gemini".into(), ..codex() },
            Args { codex_cli: None, ..codex() },
        ] {
            assert!(harness_options(&bad, &env()).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn steward_tools_need_claude_and_never_add_servers_here() {
        assert!(harness_options(&Args { steward_tools: true, ..codex() }, &env()).is_err());
        let (_, request) = harness_options(&Args { steward_tools: true, ..claude() }, &env()).unwrap();
        assert!(request.get("mcp_servers").is_none(), "the adapter builds the server object");
    }

    #[test]
    fn read_only_allow_list_never_includes_write_tools() {
        let allowed = steward_allowed_tools(false);
        assert_eq!(allowed, vec!["mcp__steward__room_status", "mcp__steward__room_members"]);
        for name in ["room_create", "room_join", "room_invite", "room_remove", "room_close", "room_mode"] {
            assert!(!allowed.contains(&format!("mcp__steward__{name}")));
            assert!(steward_tool(name).is_some());
        }
        assert!(steward_allowed_tools(true).is_empty());
    }

    #[test]
    fn configure_frame_carries_the_tool_table_for_the_adapter() {
        let frame = configure_frame(&Args { steward_tools: true, ..claude() }, &env()).unwrap();
        assert_eq!(frame["provider"], "claude");
        let tools = frame["steward"]["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 8);
        let invite = tools.iter().find(|t| t["name"] == "room_invite").unwrap();
        assert_eq!(invite["arguments"], json!(["room", "device"]));
        assert_eq!(frame["steward"]["allowed_tools"], json!(["mcp__steward__room_status", "mcp__steward__room_members"]));
        assert_eq!(configure_frame(&claude(), &env()).unwrap()["steward"], Value::Null);
        assert!(configure_frame(&Args { workdir: "/nonexistent-nr".into(), ..claude() }, &env()).is_err());
        assert!(configure_frame(&Args { codex_cli: Some("/nonexistent-cli".into()), ..codex() }, &env()).is_err());
    }

    #[test]
    fn cli_parses_the_live_unit_flags() {
        let argv: Vec<String> = "--provider claude --workdir /home/g --model claude-opus-5-5 --effort high \
            --claude-permission-mode default --approval-timeout 600 --turn-timeout 1100 --steward-tools --tool-timeout=90"
            .split_whitespace().map(String::from).collect();
        let args = parse_args(&argv, Some(r#"["/venv/bin/python","/opt/nr/ccc_adapter.py"]"#.into())).unwrap();
        assert_eq!(args.adapter_argv, vec!["/venv/bin/python", "/opt/nr/ccc_adapter.py"]);
        assert_eq!((args.turn_timeout, args.approval_timeout, args.tool_timeout), (1100.0, 600.0, 90.0));
        assert!(args.steward_tools && !args.steward_tools_approve_all);
        assert_eq!(args.provider, "claude");
        assert!(parse_args(&argv, None).is_err(), "adapter argv is required");
        assert!(parse_args(&argv, Some("[]".into())).is_err());
        let mut extra = argv.clone();
        extra.push("--bogus".into());
        assert!(parse_args(&extra, Some(r#"["p"]"#.into())).is_err());
        let bad = vec!["--workdir".to_string(), "/tmp".into(), "--provider".into(), "gemini".into()];
        assert!(parse_args(&bad, Some(r#"["p"]"#.into())).is_err());
    }

    #[test]
    fn invalid_timeouts_rejected() {
        for t in [0.0, -1.0, f64::NAN, f64::INFINITY] {
            assert!(Args { turn_timeout: t, ..claude() }.timeouts().is_err());
            assert!(Args { tool_timeout: t, ..claude() }.timeouts().is_err());
        }
        assert!(claude().timeouts().is_ok());
        assert!(Args { turn_timeout: 1e20, ..claude() }.timeouts().is_ok(), "huge but finite is accepted, capped");
    }
}
