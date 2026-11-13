#!/usr/bin/env bash
# install-node-bot.sh — put the native relay bot (steward mode) on a fleet node
# so that node can have its own 「한데」 room and its own agent
# (family-messenger #420 / ccc-node #2380, rollout per node). Root, idempotent.
#
# One node = one bot device `<node>-bot` whose actor is `<node>` (the device id's
# first `-` segment is the actor), one agent room (default `<node>`), one
# responder socket served by that node's ccc-node bridge (CCC_CHANNEL=hande).
#
# What it does:
#   1. system user/group native-relay-bot; /var/lib/native-relay-bot/{bot,rooms} 0700
#   2. /opt/native-relay-bot/bin/native-mls-bot (copied from --binary) + jwt-refresh.sh
#   3. native-relay-jwt-refresh.{service,timer} (12h): mints the 730h CF Access JWT
#      from the node's service token env file (--token-env, 0600, never printed).
#      The timer carries no Persistent= (#799): with it, a timer that had fired once
#      and was then disabled and enabled again in the same boot lost its next elapse
#      and never ran again, while still reporting enabled/active.
#   4. native-relay-bot.service (steward <node>-bot, identity/rooms/jwt files,
#      hardening as the gongmyoung lane) + drop-in 30-agent.conf (responder socket)
#   5. daemon-reload, enable + restart the timer, one jwt-refresh run through the
#      service unit, a check that the timer has a next elapse (fails the install
#      otherwise, #799), identity bootstrap, enable the bot,
#      then writes the enrollment candidate JSON the relay operator needs
#      ({actor, device_id, signing_key, subject}) to
#      /var/lib/native-relay-bot/bot/enrollment.json (0600) — NOT to stdout. The signing
#      key comes from `native-mls-bot identity-public-key` (#492), so the file is written
#      even when the responder socket is not up yet (bot before bridge); the journal's
#      `steward_ready` line is only the fallback for a binary without that subcommand.
#
# Identity bootstrap: steward mode only *loads* an identity file (it refuses to
# start without one — `identity file unreadable`, observed on the first three
# pilot nodes 2026-10-19). A fresh signer is created the way `session` mode
# creates one: a short bounded `session <node> <node>-bot --state-file …` run
# (NATIVE_MLS_BOT_MAX_SECS=8) writes the state file before its first relay POST,
# then `extract-identity` splits the signer out into identity.json and the state
# file is destroyed. Idempotent: an existing identity.json is kept.
#
# The bot starts before it is enrolled: every POST answers 403 and it retries,
# which is the documented first-boot state. After `native-devices -enroll-first`
# on the relay host (operator, approval) it joins without a restart.
#
# Usage: install-node-bot.sh --node <name> --relay-url http://<relay-tailnet>:18921
#          --relay-public-url https://<access-protected relay host>
#          --binary /path/to/native-mls-bot --token-env /root/.config/native-relay/bot-service-token.env
#          [--responder-socket /run/ccc-hande/responder.sock] [--owner-actor owner] [--attachments] [--dry-run]
#
# --attachments (#636, docs/FLEET-WORKER.md "첨부 turn"): the owner's photos/files become agent
# turns. Creates $STATE_DIR/attachments (bot-owned, group native-relay-bot, 2770 → spool files
# 0640), opens $STATE_DIR to its group for traversal only (0710), and writes the drop-in
# native-relay-bot.service.d/50-attachments.conf (the env + ReadWritePaths). The hande bridge
# must then set "attachment_frames": true and "attachment_spool_dir": "$STATE_DIR/attachments"
# — bridge first, then this (FLEET-WORKER order). A root bridge reads the files as root; a bridge
# user must be in the native-relay-bot group (it already is when it owns the responder socket).
# An existing node only needs this drop-in + directory: re-run with --attachments, or apply
# those two by hand. Undo: delete the drop-in, daemon-reload, restart the bot.
set -euo pipefail

NODE="" RELAY_URL="" RELAY_PUBLIC_URL="" BINARY="" TOKEN_ENV="" OWNER_ACTOR="owner"
RESPONDER_SOCKET="/run/ccc-hande/responder.sock" DRY_RUN=0 ATTACHMENTS=0
BOT_USER="native-relay-bot"
STATE_DIR="/var/lib/native-relay-bot"
BIN_DIR="/opt/native-relay-bot/bin"
UNIT_DIR="/etc/systemd/system"

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "install-node-bot: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --node) NODE="${2:-}"; shift 2 ;;
    --relay-url) RELAY_URL="${2:-}"; shift 2 ;;
    --relay-public-url) RELAY_PUBLIC_URL="${2:-}"; shift 2 ;;
    --binary) BINARY="${2:-}"; shift 2 ;;
    --token-env) TOKEN_ENV="${2:-}"; shift 2 ;;
    --responder-socket) RESPONDER_SOCKET="${2:-}"; shift 2 ;;
    --owner-actor) OWNER_ACTOR="${2:-}"; shift 2 ;;
    --attachments) ATTACHMENTS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$NODE" =~ ^[a-z0-9_]{1,32}$ ]] || die "--node must match [a-z0-9_]{1,32}"
[[ "$RELAY_URL" =~ ^http://[0-9A-Za-z.:-]+(:[0-9]+)?$ ]] || die "--relay-url must be the relay's tailnet http URL (the bot speaks plain HTTP inside the tailnet)"
[[ "$RELAY_PUBLIC_URL" =~ ^https://[0-9A-Za-z.-]+$ ]] || die "--relay-public-url must be https://<host> (CF Access app host used to mint the JWT)"
[ -f "$BINARY" ] && [ -x "$BINARY" ] || die "--binary must be an executable native-mls-bot"
[ -f "$TOKEN_ENV" ] || die "--token-env $TOKEN_ENV missing — place the CF Access service token env there first (0600, root)"
[ "$(stat -c %a "$TOKEN_ENV")" = "600" ] || die "--token-env must be mode 0600"
grep -q '^CF_ACCESS_CLIENT_ID=' "$TOKEN_ENV" && grep -q '^CF_ACCESS_CLIENT_SECRET=' "$TOKEN_ENV" || die "--token-env lacks CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET"
[[ "$OWNER_ACTOR" =~ ^[A-Za-z0-9_]{1,32}$ ]] || die "--owner-actor must match [A-Za-z0-9_]{1,32}"
[ "$(id -u)" = 0 ] || die "run as root"
DEVICE="$NODE-bot"

say() { printf '%s\n' "$*"; }
run() { if [ "$DRY_RUN" = 1 ]; then say "would: $*"; else "$@"; fi; }
# #799: a timer without a next elapse never fires again, yet `is-enabled`/`is-active`
# still say enabled/active. Armed = systemd reports a next elapse on either clock
# (monotonic timers: a time span; calendar timers: a wallclock time). An unreadable
# answer counts as not armed.
jwt_timer_armed() {
  local mono real
  mono="$(systemctl show native-relay-jwt-refresh.timer -p NextElapseUSecMonotonic --value 2>/dev/null)" || mono=""
  real="$(systemctl show native-relay-jwt-refresh.timer -p NextElapseUSecRealtime --value 2>/dev/null)" || real=""
  [ -n "$real" ] || { [ -n "$mono" ] && [ "$mono" != "infinity" ] && [ "$mono" != "0" ]; }
}
write_file() { # <path> <mode> [owner]; content on stdin
  local path="$1" mode="$2" owner="${3:-root}" tmp
  if [ "$DRY_RUN" = 1 ]; then say "would write $path ($mode $owner)"; cat >/dev/null; return 0; fi
  tmp="$(mktemp "$(dirname "$path")/.tmp.XXXXXX")"; cat >"$tmp"; chmod "$mode" "$tmp"; chown "$owner" "$tmp"; mv -f "$tmp" "$path"; say "wrote $path"
}

say "== install-node-bot: node=$NODE device=$DEVICE relay=$RELAY_URL socket=$RESPONDER_SOCKET"

# 1. user + dirs
if ! getent passwd "$BOT_USER" >/dev/null; then
  run useradd --system --home-dir "$STATE_DIR" --shell /usr/sbin/nologin --user-group "$BOT_USER"
fi
run install -d -m 0700 -o "$BOT_USER" -g "$BOT_USER" "$STATE_DIR" "$STATE_DIR/bot" "$STATE_DIR/rooms"
run install -d -m 0755 "$BIN_DIR"

# 2. binary + jwt refresh script
run install -m 0755 "$BINARY" "$BIN_DIR/native-mls-bot"
write_file "$BIN_DIR/jwt-refresh.sh" 0755 <<EOF
#!/usr/bin/env bash
# $NODE bot lane: mint the 730h CF Access JWT from this node's own service token.
# Values never leave this host: the env file is 0600 root, the JWT 0600 $BOT_USER.
set -euo pipefail; umask 077
set -a; . "$TOKEN_ENV"; set +a
out=$STATE_DIR/bot/jwt
hdr=\$(curl -s -o /dev/null -D - --max-time 25 "$RELAY_PUBLIC_URL/v2/health" -H "CF-Access-Client-Id: \$CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: \$CF_ACCESS_CLIENT_SECRET")
jwt=\$(printf '%s' "\$hdr" | grep -i '^set-cookie: CF_Authorization=' | sed -E 's/^[^=]*=([^;]*).*/\\1/' | tr -d '\\r' | head -1)
[ -n "\$jwt" ] || { echo "jwt-refresh: no CF_Authorization cookie (status \$(printf '%s' "\$hdr" | head -1 | tr -d '\\r'))" >&2; exit 1; }
cn=\$(python3 - "\$jwt" <<'PY'
import sys, json, base64
p = sys.argv[1].split(".")[1]; p += "=" * (-len(p) % 4)
print(json.loads(base64.urlsafe_b64decode(p))["common_name"])
PY
)
printf '%s' "\$jwt" > "\$out.tmp"; chown $BOT_USER:$BOT_USER "\$out.tmp"; chmod 600 "\$out.tmp"; mv -f "\$out.tmp" "\$out"
printf '%s' "\$cn" > $STATE_DIR/bot/common_name.tmp; chown $BOT_USER:$BOT_USER $STATE_DIR/bot/common_name.tmp; chmod 600 $STATE_DIR/bot/common_name.tmp; mv -f $STATE_DIR/bot/common_name.tmp $STATE_DIR/bot/common_name
echo "jwt-refresh: ok (\$(wc -c < "\$out") B, 730h)"
EOF

# 3. jwt refresh units
write_file "$UNIT_DIR/native-relay-jwt-refresh.service" 0644 <<EOF
[Unit]
Description=native-relay bot lane ($NODE) — mint CF Access JWT from the service token
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$BIN_DIR/jwt-refresh.sh
EOF
write_file "$UNIT_DIR/native-relay-jwt-refresh.timer" 0644 <<'EOF'
[Unit]
Description=native-relay JWT refresh every 12h (token lifetime 730h)
[Timer]
# No Persistent= here (#799). It only applies to OnCalendar=, and on these monotonic
# triggers its saved last-trigger time made a timer that was disabled and enabled
# again in the same boot treat OnBootSec as already spent, with no base left for
# OnUnitActiveSec: no next elapse, no refresh, and the bot's JWT expired 730h later.
OnBootSec=2min
OnUnitActiveSec=12h
[Install]
WantedBy=timers.target
EOF

# 4. bot unit (steward mode) + responder drop-in
write_file "$UNIT_DIR/native-relay-bot.service" 0644 <<EOF
[Unit]
Description=family-messenger native-mls bot ($NODE, steward $DEVICE) — relay over tailnet
After=network-online.target tailscaled.service native-relay-jwt-refresh.service
Wants=network-online.target

[Service]
User=$BOT_USER
Group=$BOT_USER
Environment=NATIVE_MLS_BOT_MAX_SECS=0
ExecStart=$BIN_DIR/native-mls-bot $RELAY_URL steward $DEVICE --identity-file $STATE_DIR/bot/identity.json --rooms-dir $STATE_DIR/rooms --access-jwt-file $STATE_DIR/bot/jwt
Restart=on-failure
RestartSec=10
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$STATE_DIR/bot $STATE_DIR/rooms
PrivateTmp=yes
PrivateDevices=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF
run install -d -m 0755 "$UNIT_DIR/native-relay-bot.service.d"
write_file "$UNIT_DIR/native-relay-bot.service.d/30-agent.conf" 0644 <<EOF
# Agent mode (#354): the responder is this node's ccc-node bridge (CCC_CHANNEL=hande).
[Service]
Environment=NATIVE_MLS_BOT_RESPONDER_UNIX=$RESPONDER_SOCKET
Environment=NATIVE_MLS_BOT_OWNER_ACTOR=$OWNER_ACTOR
EOF
if [ "$ATTACHMENTS" = 1 ]; then
  # #636: the spool the hande bridge takes files over from (rename, same filesystem).
  run install -d -m 2770 -o "$BOT_USER" -g "$BOT_USER" "$STATE_DIR/attachments"
  run chmod 0710 "$STATE_DIR"
  write_file "$UNIT_DIR/native-relay-bot.service.d/50-attachments.conf" 0644 <<EOF
# #636 attachment turns (docs/FLEET-WORKER.md "첨부 turn"). Undo: delete this file, daemon-reload, restart.
[Service]
ReadWritePaths=$STATE_DIR/attachments
Environment=NATIVE_MLS_BOT_AGENT_ATTACHMENTS=1
Environment=NATIVE_MLS_BOT_ATTACHMENT_SPOOL=$STATE_DIR/attachments
EOF
fi

# 5. reload, mint, start, enrollment candidate
if [ "$DRY_RUN" = 1 ]; then say "dry-run: not reloading/starting"; exit 0; fi
systemctl daemon-reload
systemctl enable native-relay-jwt-refresh.timer >/dev/null
# restart, not `enable --now`: a re-run on a node whose timer is already active must
# pick up a changed unit file (#799).
systemctl restart native-relay-jwt-refresh.timer
# Mint through the unit, not by calling the script: the service's activation is the
# base OnUnitActiveSec counts from, and a timer that had lost its next elapse gets it
# back here. If the timer has just started the service, this joins that run.
systemctl start native-relay-jwt-refresh.service \
  || die "jwt-refresh failed — see: journalctl -u native-relay-jwt-refresh.service"
armed=0
for _ in $(seq 1 30); do if jwt_timer_armed; then armed=1; break; fi; sleep 1; done
[ "$armed" = 1 ] || die "native-relay-jwt-refresh.timer has no next elapse (systemctl list-timers shows n/a) — the JWT would never be refreshed (#799)"
# identity bootstrap (see header): session run → state file → extract-identity
IDENTITY="$STATE_DIR/bot/identity.json"
if [ -s "$IDENTITY" ]; then
  say "identity: keeping existing $IDENTITY"
else
  systemctl stop native-relay-bot.service 2>/dev/null || true
  boot_state="$STATE_DIR/bot/bootstrap-state.json" boot_log="$STATE_DIR/bot/bootstrap.log"
  rm -f "$boot_state" "$boot_log"
  # Exits non-zero on its deadline (403 until enrolled) — expected; the state file
  # is flushed before the first POST, which is all this step needs.
  runuser -u "$BOT_USER" -- env NATIVE_MLS_BOT_MAX_SECS=8 "$BIN_DIR/native-mls-bot" "$RELAY_URL" session "$NODE" "$DEVICE" \
    --state-file "$boot_state" --access-jwt-file "$STATE_DIR/bot/jwt" >"$boot_log" 2>&1 || true
  grep -q '"event":"identity"' "$boot_log" && [ -s "$boot_state" ] \
    || { sed -n '1,3p' "$boot_log" | cut -c1-200 >&2; rm -f "$boot_state" "$boot_log"; die "identity bootstrap: session run produced no identity/state (relay URL or jwt?)"; }
  runuser -u "$BOT_USER" -- "$BIN_DIR/native-mls-bot" extract-identity "$NODE" "$DEVICE" --state-file "$boot_state" --identity-file "$IDENTITY" >/dev/null \
    || { rm -f "$boot_state" "$boot_log"; die "identity bootstrap: extract-identity failed"; }
  chmod 600 "$IDENTITY"
  shred -u "$boot_state" 2>/dev/null || rm -f "$boot_state"; rm -f "$boot_log"
  say "identity: created $IDENTITY (0600, signer only)"
fi
# #492: the signing key straight from identity.json — the value `steward_ready` reports,
# computed offline, so enrollment.json does not wait on the responder socket or the journal.
key="$(runuser -u "$BOT_USER" -- "$BIN_DIR/native-mls-bot" identity-public-key "$DEVICE" --identity-file "$IDENTITY" 2>/dev/null)" || key=""
[[ "$key" =~ ^[0-9a-f]{64}$ ]] || key=""
systemctl enable --now native-relay-bot.service >/dev/null
if [ -z "$key" ]; then
  # Fallback (binary without identity-public-key): steward mode announces itself with
  # `steward_ready` (public_key, rooms); wait for this start's line. `|| key=""`: a grep
  # miss under pipefail must keep polling, not end the script silently via set -e.
  say "identity-public-key unavailable — falling back to steward_ready in the journal"
  for _ in $(seq 1 30); do
    key="$(journalctl -u native-relay-bot --since '-2min' --no-pager -o cat 2>/dev/null | grep '"event":"steward_ready"' | tail -1 | sed -E 's/.*"public_key":"([0-9a-f]{64})".*/\1/')" || key=""
    [ -n "$key" ] && [[ "$key" =~ ^[0-9a-f]{64}$ ]] && break
    sleep 1
  done
  [ -n "${key:-}" ] && [[ "$key" =~ ^[0-9a-f]{64}$ ]] || die "bot started but no steward_ready event in its journal yet — check: journalctl -u native-relay-bot"
fi
subject="$(cat "$STATE_DIR/bot/common_name")"
write_file "$STATE_DIR/bot/enrollment.json" 0600 <<EOF
{"actor": "$NODE", "device_id": "$DEVICE", "signing_key": "$key", "subject": "$subject"}
EOF
# The key no longer comes from the running bot (#492), so this run no longer proves the bot
# started. Settle briefly and warn (not die): before the hande bridge exists the bot may still
# be retrying its responder socket, which is expected and must not fail the install.
sleep 5
systemctl is-active --quiet native-relay-bot \
  || say "warning: native-relay-bot is not active ($(systemctl is-active native-relay-bot || true)) — check: journalctl -u native-relay-bot"
say "bot: $(systemctl is-active native-relay-bot) · timer: $(systemctl is-active native-relay-jwt-refresh.timer)"
say "enrollment candidate: $STATE_DIR/bot/enrollment.json (0600) — carry it to the relay host for 'native-devices -enroll-first' (operator, approval)."
say "fingerprint (sha256 of signing key, for the owner's out-of-band check): $(printf '%s' "$key" | xxd -r -p | sha256sum | cut -c1-16)…"
say "until enrolled the bot logs 403 and retries; no restart is needed after enrollment."
