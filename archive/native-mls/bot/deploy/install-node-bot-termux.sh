#!/usr/bin/env bash
# install-node-bot-termux.sh — put the native relay bot (steward mode) on a Termux
# (aarch64 Android) fleet node (#492 ②; the systemd counterpart is install-node-bot.sh).
# Termux has no systemd and no root: the bot is a runit service under $SVDIR, the JWT
# refresh is a crontab line, everything runs as the Termux user (one uid with the
# ccc-node hande bridge, so the responder socket stays 0600). Idempotent.
#
# What it does:
#   1. ~/.native-relay-bot/{bin,bot,rooms,logs} 0700 (+ attachments with --attachments)
#   2. bin/native-mls-bot (copied from --binary; kept when omitted) + bin/jwt-refresh.sh
#      (mints the 730h CF Access JWT from --token-env, 0600, values never printed)
#   3. one jwt-refresh run + crontab line `17 */12 * * *` (never duplicated)
#   4. $PREFIX/etc/native-relay/bot-relay.env (NATIVE_RELAY_URL, no secret) when absent —
#      an existing file is kept; a different --relay-url is refused (use native-relay-repoint)
#   5. identity bootstrap exactly as install-node-bot.sh (bounded `session` run →
#      extract-identity → state file destroyed); an existing identity.json is kept
#   6. runit service $SVDIR/native-relay-bot/{run,finish,log/run}; a changed `run` is
#      backed up as run.bak-492-<UTC> first; `down` with --no-start
#   7. enrollment candidate bot/enrollment.json (0600) {actor, device_id, signing_key,
#      subject} for `native-devices -enroll-first` on the relay host (operator, approval).
#      The key comes from `native-mls-bot identity-public-key` (#492), so the file is
#      written even when the responder socket is not up yet (bot before bridge). A binary
#      without that subcommand falls back to the `steward_ready` line in the svlogd log.
#
# Binary: `aarch64-unknown-linux-musl` static build (no TLS, no C deps), e.g. the CI
# artifact `native-mls-bot-aarch64-unknown-linux-musl` — see deploy/TERMUX.md.
#
# Usage: install-node-bot-termux.sh --node <name> --relay-public-url https://<access-protected relay host>
#          [--relay-url http://<relay-tailnet>:18921] [--binary /path/to/native-mls-bot]
#          [--token-env ~/.config/native-relay/bot-service-token.env] [--owner-actor owner]
#          [--attachments [--caption-secs N]] [--no-start] [--dry-run]
# Env:   PREFIX (Termux), SVDIR ($PREFIX/var/service), HOME.
# Test seams (never set in production): INSTALL_NODE_BOT_TERMUX_SV (sv binary),
# INSTALL_NODE_BOT_TERMUX_CRONTAB (crontab binary), INSTALL_NODE_BOT_TERMUX_WAIT_SECS,
# INSTALL_NODE_BOT_TERMUX_ALLOW_ROOT=1 (lets the test suite run as root).
set -euo pipefail

NODE="" RELAY_URL="" RELAY_PUBLIC_URL="" BINARY="" TOKEN_ENV="" OWNER_ACTOR="owner"
ATTACHMENTS=0 CAPTION_SECS="" NO_START=0 DRY_RUN=0

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "install-node-bot-termux: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --node) NODE="${2:-}"; shift 2 ;;
    --relay-url) RELAY_URL="${2:-}"; shift 2 ;;
    --relay-public-url) RELAY_PUBLIC_URL="${2:-}"; shift 2 ;;
    --binary) BINARY="${2:-}"; shift 2 ;;
    --token-env) TOKEN_ENV="${2:-}"; shift 2 ;;
    --owner-actor) OWNER_ACTOR="${2:-}"; shift 2 ;;
    --attachments) ATTACHMENTS=1; shift ;;
    --caption-secs) CAPTION_SECS="${2:-}"; shift 2 ;;
    --no-start) NO_START=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

H="${HOME:?HOME must be set}"
P="${PREFIX:-/data/data/com.termux/files/usr}"
SVDIR_="${SVDIR:-$P/var/service}"
SV="${INSTALL_NODE_BOT_TERMUX_SV:-sv}"
CRONTAB="${INSTALL_NODE_BOT_TERMUX_CRONTAB:-crontab}"
WAIT_SECS="${INSTALL_NODE_BOT_TERMUX_WAIT_SECS:-30}"
TOKEN_ENV="${TOKEN_ENV:-$H/.config/native-relay/bot-service-token.env}"

[[ "$NODE" =~ ^[a-z0-9_]{1,32}$ ]] || die "--node must match [a-z0-9_]{1,32}"
[[ "$RELAY_PUBLIC_URL" =~ ^https://[0-9A-Za-z.-]+$ ]] || die "--relay-public-url must be https://<host> (CF Access app host used to mint the JWT)"
[ -z "$RELAY_URL" ] || [[ "$RELAY_URL" =~ ^http://[0-9A-Za-z.:-]+(:[0-9]+)?$ ]] || die "--relay-url must be the relay's tailnet http URL (the bot speaks plain HTTP inside the tailnet)"
[[ "$OWNER_ACTOR" =~ ^[A-Za-z0-9_]{1,32}$ ]] || die "--owner-actor must match [A-Za-z0-9_]{1,32}"
[ -z "$CAPTION_SECS" ] || { [ "$ATTACHMENTS" = 1 ] && [[ "$CAPTION_SECS" =~ ^[0-9]{1,3}$ ]] && [ "$CAPTION_SECS" -le 120 ]; } \
  || die "--caption-secs needs --attachments and an integer 0..120"
[ "$(id -u)" != 0 ] || [ "${INSTALL_NODE_BOT_TERMUX_ALLOW_ROOT:-0}" = 1 ] \
  || die "run as the Termux user, not root (systemd nodes: install-node-bot.sh)"
[ -d "$P/bin" ] || die "PREFIX $P has no bin/ — not a Termux prefix"
[ -f "$TOKEN_ENV" ] || die "--token-env $TOKEN_ENV missing — place the CF Access service token env there first (0600)"
[ "$(stat -c %a "$TOKEN_ENV")" = "600" ] || die "--token-env must be mode 0600"
grep -q '^CF_ACCESS_CLIENT_ID=' "$TOKEN_ENV" && grep -q '^CF_ACCESS_CLIENT_SECRET=' "$TOKEN_ENV" || die "--token-env lacks CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET"

DEVICE="$NODE-bot"
B="$H/.native-relay-bot"
BIN="$B/bin/native-mls-bot"
IDENTITY="$B/bot/identity.json"
SOCK="$P/var/run/ccc-hande/responder.sock"   # served by ccc-node install-hande-bridge-termux.sh
RELAY_ENV="$P/etc/native-relay/bot-relay.env"
SVC_DIR="$SVDIR_/native-relay-bot"
if [ -n "$BINARY" ]; then
  [ -f "$BINARY" ] && [ -x "$BINARY" ] || die "--binary must be an executable native-mls-bot"
elif [ ! -x "$BIN" ]; then
  die "--binary required: no $BIN installed yet"
fi

say() { printf '%s\n' "$*"; }
run() { if [ "$DRY_RUN" = 1 ]; then say "would: $*"; else "$@"; fi; }
write_file() { # <path> <mode>; content on stdin
  local path="$1" mode="$2" tmp
  if [ "$DRY_RUN" = 1 ]; then say "would write $path ($mode)"; cat >/dev/null; return 0; fi
  tmp="$(mktemp "$(dirname "$path")/.tmp.XXXXXX")"; cat >"$tmp"; chmod "$mode" "$tmp"; mv -f "$tmp" "$path"; say "wrote $path"
}

say "== install-node-bot-termux: node=$NODE device=$DEVICE socket=$SOCK svc=$SVC_DIR"
umask 077

# 1. dirs
run mkdir -p "$B/bin" "$B/bot" "$B/rooms" "$B/logs" "$P/etc/native-relay"
run chmod 0700 "$B" "$B/bin" "$B/bot" "$B/rooms" "$B/logs"
[ "$ATTACHMENTS" = 0 ] || { run mkdir -p "$B/attachments"; run chmod 0700 "$B/attachments"; }

# 2. binary + jwt refresh script
if [ -n "$BINARY" ]; then
  if [ "$DRY_RUN" = 1 ]; then say "would install $BINARY -> $BIN (0755)"
  else tmp="$(mktemp "$B/bin/.tmp.XXXXXX")"; cp "$BINARY" "$tmp"; chmod 0755 "$tmp"; mv -f "$tmp" "$BIN"; say "installed $BIN"; fi
fi
write_file "$B/bin/jwt-refresh.sh" 0700 <<EOF
#!$P/bin/bash
# $NODE bot lane (Termux): mint the 730h CF Access JWT from this node's own service token.
# Values never leave this device: the env file and the JWT are 0600.
set -euo pipefail; umask 077
set -a; . "$TOKEN_ENV"; set +a
out=$B/bot/jwt
hdr=\$(curl -s -o /dev/null -D - --max-time 25 "$RELAY_PUBLIC_URL/v2/health" -H "CF-Access-Client-Id: \$CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: \$CF_ACCESS_CLIENT_SECRET")
jwt=\$(printf '%s' "\$hdr" | grep -i '^set-cookie: CF_Authorization=' | sed -E 's/^[^=]*=([^;]*).*/\\1/' | tr -d '\\r' | head -1)
[ -n "\$jwt" ] || { echo "jwt-refresh: no CF_Authorization cookie (status \$(printf '%s' "\$hdr" | head -1 | tr -d '\\r'))" >&2; exit 1; }
cn=\$(python3 - "\$jwt" <<'PY'
import sys, json, base64
p = sys.argv[1].split(".")[1]; p += "=" * (-len(p) % 4)
print(json.loads(base64.urlsafe_b64decode(p))["common_name"])
PY
)
printf '%s' "\$jwt" > "\$out.tmp"; chmod 600 "\$out.tmp"; mv -f "\$out.tmp" "\$out"
printf '%s' "\$cn" > $B/bot/common_name.tmp; chmod 600 $B/bot/common_name.tmp; mv -f $B/bot/common_name.tmp $B/bot/common_name
echo "jwt-refresh: ok (\$(wc -c < "\$out") B, 730h)"
EOF

# 3. relay URL env (one place, no secret; native-relay-repoint owns later changes)
if [ -f "$RELAY_ENV" ]; then
  current="$(sed -n 's/^NATIVE_RELAY_URL=//p' "$RELAY_ENV" | tail -1)"
  [ -n "$current" ] || die "$RELAY_ENV has no NATIVE_RELAY_URL= line"
  [ -z "$RELAY_URL" ] || [ "$RELAY_URL" = "$current" ] \
    || die "$RELAY_ENV already points elsewhere — change it with native-relay-repoint, not this installer"
  say "relay env: keeping $RELAY_ENV"
else
  [ -n "$RELAY_URL" ] || die "--relay-url required: $RELAY_ENV does not exist yet"
  write_file "$RELAY_ENV" 0600 <<<"NATIVE_RELAY_URL=$RELAY_URL"
fi

# 4. runit service (written before any start; `down` keeps it from starting with --no-start)
run mkdir -p "$SVC_DIR/log"
env_line="NATIVE_MLS_BOT_MAX_SECS=0 NATIVE_MLS_BOT_RESPONDER_UNIX=$SOCK NATIVE_MLS_BOT_OWNER_ACTOR=$OWNER_ACTOR"
if [ "$ATTACHMENTS" = 1 ]; then
  env_line="NATIVE_MLS_BOT_AGENT_ATTACHMENTS=1${CAPTION_SECS:+ NATIVE_MLS_BOT_ATTACHMENT_CAPTION_SECS=$CAPTION_SECS} NATIVE_MLS_BOT_ATTACHMENT_SPOOL=$B/attachments $env_line"
fi
run_body="#!$P/bin/sh
exec 2>&1
. $RELAY_ENV  # #699 P0-d relay URL
exec env $env_line $BIN \"\$NATIVE_RELAY_URL\" steward $DEVICE --identity-file $IDENTITY --rooms-dir $B/rooms --access-jwt-file $B/bot/jwt"
if [ -f "$SVC_DIR/run" ] && [ "$(cat "$SVC_DIR/run")" != "$run_body" ]; then
  bak="$SVC_DIR/run.bak-492-$(date -u +%Y%m%dT%H%M%SZ)"
  if [ "$DRY_RUN" = 1 ]; then say "would back up changed run -> $bak"
  else cp -p "$SVC_DIR/run" "$bak"; say "backed up changed run -> $bak"; fi
fi
write_file "$SVC_DIR/run" 0700 <<<"$run_body"
write_file "$SVC_DIR/finish" 0700 <<<"#!$P/bin/sh
sleep 10"
write_file "$SVC_DIR/log/run" 0700 <<<"#!$P/bin/sh
exec svlogd -tt $B/logs"
if [ "$NO_START" = 1 ]; then
  write_file "$SVC_DIR/down" 0600 <<<"# family-messenger #492: installed with --no-start; rm this file (or sv up native-relay-bot) to start"
fi

if [ "$DRY_RUN" = 1 ]; then say "dry-run: not minting, bootstrapping or starting"; exit 0; fi

# 5. mint + cron
"$B/bin/jwt-refresh.sh"
cron_line="17 */12 * * * $B/bin/jwt-refresh.sh >>$B/logs/jwt-refresh.log 2>&1  # hande bot JWT (730h)"
if ! "$CRONTAB" -l 2>/dev/null | grep -qF "$B/bin/jwt-refresh.sh"; then
  { "$CRONTAB" -l 2>/dev/null || true; printf '%s\n' "$cron_line"; } | "$CRONTAB" -
  say "crontab: added jwt-refresh (12h)"
else
  say "crontab: jwt-refresh already present"
fi

# 6. identity bootstrap (same as install-node-bot.sh): session run → state file → extract-identity
if [ -s "$IDENTITY" ]; then
  say "identity: keeping existing $IDENTITY"
else
  relay_now="${RELAY_URL:-$(sed -n 's/^NATIVE_RELAY_URL=//p' "$RELAY_ENV" | tail -1)}"
  boot_state="$B/bot/bootstrap-state.json" boot_log="$B/bot/bootstrap.log"
  rm -f "$boot_state" "$boot_log"
  # Exits non-zero on its deadline (403 until enrolled) — expected; the state file is
  # flushed before the first POST, which is all this step needs.
  NATIVE_MLS_BOT_MAX_SECS=8 "$BIN" "$relay_now" session "$NODE" "$DEVICE" \
    --state-file "$boot_state" --access-jwt-file "$B/bot/jwt" >"$boot_log" 2>&1 || true
  grep -q '"event":"identity"' "$boot_log" && [ -s "$boot_state" ] \
    || { sed -n '1,3p' "$boot_log" | cut -c1-200 >&2; rm -f "$boot_state" "$boot_log"; die "identity bootstrap: session run produced no identity/state (relay URL or jwt?)"; }
  "$BIN" extract-identity "$NODE" "$DEVICE" --state-file "$boot_state" --identity-file "$IDENTITY" >/dev/null \
    || { rm -f "$boot_state" "$boot_log"; die "identity bootstrap: extract-identity failed"; }
  chmod 600 "$IDENTITY"; shred -u "$boot_state" 2>/dev/null || rm -f "$boot_state"; rm -f "$boot_log"
  say "identity: created $IDENTITY (0600, signer only)"
fi

# 7. key first (offline, #492), then start, then the enrollment candidate
key="$("$BIN" identity-public-key "$DEVICE" --identity-file "$IDENTITY" 2>/dev/null)" || key=""
[[ "$key" =~ ^[0-9a-f]{64}$ ]] || key=""
if [ "$NO_START" = 0 ]; then
  [ ! -e "$SVC_DIR/down" ] || { rm -f "$SVC_DIR/down"; say "removed $SVC_DIR/down"; }
  SVDIR="$SVDIR_" "$SV" up native-relay-bot >/dev/null 2>&1 || say "sv up native-relay-bot: not supervised yet (runsvdir scans every ~5 s)"
fi
if [ -z "$key" ]; then
  # Fallback (binary without identity-public-key): steward mode logs `steward_ready`
  # (public_key) to svlogd's current file. `|| key=""`: a grep miss under pipefail must
  # keep polling, not end the script via set -e.
  say "identity-public-key unavailable — falling back to steward_ready in $B/logs/current"
  for _ in $(seq 1 "$WAIT_SECS"); do
    key="$(grep '"event":"steward_ready"' "$B/logs/current" 2>/dev/null | tail -1 | sed -E 's/.*"public_key":"([0-9a-f]{64})".*/\1/')" || key=""
    [[ "$key" =~ ^[0-9a-f]{64}$ ]] && break
    key=""; sleep 1
  done
  [ -n "$key" ] || die "no signing key: binary lacks identity-public-key and no steward_ready in $B/logs/current — upgrade the binary or start the bot, then re-run"
fi
subject="$(cat "$B/bot/common_name")"
write_file "$B/bot/enrollment.json" 0600 <<EOF
{"actor": "$NODE", "device_id": "$DEVICE", "signing_key": "$key", "subject": "$subject"}
EOF
say "enrollment candidate: $B/bot/enrollment.json (0600) — carry it to the relay host for 'native-devices -enroll-first' (operator, approval)."
[ -S "$SOCK" ] || say "note: responder socket $SOCK not up yet — install the hande bridge (ccc-node install-hande-bridge-termux.sh); the bot retries until it is"
say "rollback: SVDIR=$SVDIR_ $SV down native-relay-bot; rm -rf $SVC_DIR; drop the jwt-refresh crontab line; $B keeps the identity"
