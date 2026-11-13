#!/usr/bin/env bash
# Tests for install-node-bot-termux.sh (#492 ②) on a plain Linux host: a fake Termux
# PREFIX/HOME under a temp dir, a stub native-mls-bot (session / extract-identity /
# identity-public-key, or an "old" binary without the last one), and stub curl /
# crontab / sv. Nothing touches the real HOME, crontab or runit.
# shellcheck disable=SC2034  # out/rc/paths are read inside the eval'd ok() conditions
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/install-node-bot-termux.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  cond: $2"; fi; }

KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
LOGKEY=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
SECRET=s3cr3t-value-never-printed
mkdir -p "$TMP/stub"
cat > "$TMP/stub/native-mls-bot" <<'EOF'
#!/usr/bin/env bash
# stub: session writes a state file + identity event; extract-identity writes the
# identity; identity-public-key prints a fixed key unless STUB_OLD_BINARY=1.
args=("$@"); get() { local i; for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[i]}" = "$1" ] && { printf '%s' "${args[i+1]}"; return; }; done; }
case "${1:-}" in
  identity-public-key)
    [ "${STUB_OLD_BINARY:-0}" = 1 ] && { echo "usage: native-mls-bot ..." >&2; exit 2; }
    [ -s "$(get --identity-file)" ] || exit 1
    echo "$STUB_KEY"; exit 0 ;;
  extract-identity) printf '{"signer":"stub"}' > "$(get --identity-file)"; exit 0 ;;
esac
case "${2:-}" in
  session) printf '{"state":"stub"}' > "$(get --state-file)"; echo '{"event":"identity"}'; exit 1 ;;
  steward) echo "STEWARD url=$1 device=$3 socket=$NATIVE_MLS_BOT_RESPONDER_UNIX max=$NATIVE_MLS_BOT_MAX_SECS"; exit 0 ;;
esac
echo "stub: unexpected $*" >&2; exit 9
EOF
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
p=$(printf '{"common_name":"cn-test"}' | base64 | tr -d '=\n' | tr '+/' '-_')
printf 'HTTP/2 200\r\nset-cookie: CF_Authorization=hdr.%s.sig; Path=/\r\n\r\n' "$p"
EOF
cat > "$TMP/bin/crontab" <<'EOF'
#!/usr/bin/env bash
f="$STUB_CRON_FILE"
case "$1" in -l) [ -f "$f" ] && cat "$f" || exit 1 ;; -) cat > "$f" ;; esac
EOF
cat > "$TMP/bin/sv" <<'EOF'
#!/usr/bin/env bash
echo "SVDIR=$SVDIR $*" >> "$STUB_SV_LOG"
EOF
chmod +x "$TMP/stub/native-mls-bot" "$TMP/bin/"*

setup_node() { # fresh fake Termux prefix + home
  rm -rf "${TMP:?}/usr" "${TMP:?}/home" "${TMP:?}/cron" "${TMP:?}/sv.log"
  mkdir -p "$TMP/usr/bin" "$TMP/home/.config/native-relay"
  # generated scripts use Termux shebangs ($PREFIX/bin/bash, $PREFIX/bin/sh)
  ln -s "$(command -v bash)" "$TMP/usr/bin/bash"; ln -s "$(command -v sh)" "$TMP/usr/bin/sh"
  printf 'CF_ACCESS_CLIENT_ID=id-1\nCF_ACCESS_CLIENT_SECRET=%s\n' "$SECRET" > "$TMP/home/.config/native-relay/bot-service-token.env"
  chmod 600 "$TMP/home/.config/native-relay/bot-service-token.env"
}
inst() {
  HOME="$TMP/home" PREFIX="$TMP/usr" PATH="$TMP/bin:$PATH" STUB_KEY="$KEY" \
    STUB_CRON_FILE="$TMP/cron" STUB_SV_LOG="$TMP/sv.log" \
    INSTALL_NODE_BOT_TERMUX_SV="$TMP/bin/sv" INSTALL_NODE_BOT_TERMUX_CRONTAB="$TMP/bin/crontab" \
    INSTALL_NODE_BOT_TERMUX_ALLOW_ROOT=1 INSTALL_NODE_BOT_TERMUX_WAIT_SECS="${WAIT:-2}" \
    bash "$SCRIPT" --node testnode --relay-public-url https://relay.example.test "$@"
}
B="$TMP/home/.native-relay-bot"; SVC="$TMP/usr/var/service/native-relay-bot"
ENROLL="$B/bot/enrollment.json"; RELAY_ENV="$TMP/usr/etc/native-relay/bot-relay.env"
SOCK="$TMP/usr/var/run/ccc-hande/responder.sock"
mode() { stat -c %a "$1"; }

# --- argument checks ----------------------------------------------------------
setup_node
out="$(inst --node 'Bad!' 2>&1)"; rc=$?
ok "bad --node is refused" '[ "$rc" != 0 ] && grep -q "must match" <<<"$out"'
out="$(inst --relay-public-url http://plain 2>&1)"; rc=$?
ok "non-https --relay-public-url is refused" '[ "$rc" != 0 ] && grep -q "relay-public-url" <<<"$out"'
out="$(inst --caption-secs 30 --binary "$TMP/stub/native-mls-bot" --relay-url http://relay-a.tailnet.test:18921 2>&1)"; rc=$?
ok "--caption-secs without --attachments is refused" '[ "$rc" != 0 ] && grep -q "caption-secs" <<<"$out"'
chmod 644 "$TMP/home/.config/native-relay/bot-service-token.env"
out="$(inst --binary "$TMP/stub/native-mls-bot" --relay-url http://relay-a.tailnet.test:18921 2>&1)"; rc=$?
ok "token env not 0600 is refused" '[ "$rc" != 0 ] && grep -q "0600" <<<"$out"'
setup_node
out="$(inst --relay-url http://relay-a.tailnet.test:18921 2>&1)"; rc=$?
ok "no --binary and nothing installed is refused" '[ "$rc" != 0 ] && grep -q "binary required" <<<"$out"'
out="$(inst --binary "$TMP/stub/native-mls-bot" 2>&1)"; rc=$?
ok "first install without --relay-url is refused" '[ "$rc" != 0 ] && grep -q "relay-url required" <<<"$out" && [ ! -e "$ENROLL" ]'

# --- dry run writes nothing ---------------------------------------------------
setup_node
out="$(inst --binary "$TMP/stub/native-mls-bot" --relay-url http://relay-a.tailnet.test:18921 --dry-run 2>&1)"; rc=$?
ok "dry-run: rc=0 and nothing written" \
  '[ "$rc" = 0 ] && grep -q "would write" <<<"$out" && [ ! -e "$B" ] && [ ! -e "$SVC" ] && [ ! -e "$TMP/cron" ]'

# --- fresh install with NO responder socket (#492 acceptance) -----------------
setup_node
out="$(inst --binary "$TMP/stub/native-mls-bot" --relay-url http://relay-a.tailnet.test:18921 2>&1)"; rc=$?
ok "fresh install without a socket succeeds" '[ "$rc" = 0 ] && [ ! -S "$SOCK" ]'
ok "enrollment.json is written 0600 with the exact candidate" \
  '[ "$(mode "$ENROLL")" = 600 ] && [ "$(cat "$ENROLL")" = "{\"actor\": \"testnode\", \"device_id\": \"testnode-bot\", \"signing_key\": \"$KEY\", \"subject\": \"cn-test\"}" ]'
ok "identity created 0600, bootstrap state destroyed" \
  '[ "$(mode "$B/bot/identity.json")" = 600 ] && [ ! -e "$B/bot/bootstrap-state.json" ] && [ ! -e "$B/bot/bootstrap.log" ]'
ok "jwt + common_name minted 0600" '[ "$(mode "$B/bot/jwt")" = 600 ] && [ "$(cat "$B/bot/common_name")" = cn-test ]'
ok "relay env written once, 0600, no secret" \
  '[ "$(cat "$RELAY_ENV")" = "NATIVE_RELAY_URL=http://relay-a.tailnet.test:18921" ] && [ "$(mode "$RELAY_ENV")" = 600 ]'
ok "run sources the relay env and runs steward on the hande socket" \
  'grep -qF ". $RELAY_ENV" "$SVC/run" && grep -qF "NATIVE_MLS_BOT_RESPONDER_UNIX=$SOCK" "$SVC/run" && grep -qF "$B/bin/native-mls-bot \"\$NATIVE_RELAY_URL\" steward testnode-bot --identity-file $B/bot/identity.json" "$SVC/run" && ! grep -q ATTACHMENTS "$SVC/run"'
run_out="$(env -i PATH=/usr/bin:/bin sh "$SVC/run" 2>&1)"
ok "the generated run is valid sh and hands the env-file relay URL to steward" \
  '[ "$run_out" = "STEWARD url=http://relay-a.tailnet.test:18921 device=testnode-bot socket=$SOCK max=0" ]'
ok "finish sleeps 10, log/run is svlogd into ~/.native-relay-bot/logs" \
  'grep -qx "sleep 10" "$SVC/finish" && grep -qF "exec svlogd -tt $B/logs" "$SVC/log/run"'
ok "one jwt-refresh crontab line, sv up called" \
  '[ "$(grep -c jwt-refresh.sh "$TMP/cron")" = 1 ] && grep -q "up native-relay-bot" "$TMP/sv.log"'
ok "missing socket is reported, token secret never printed" \
  'grep -q "responder socket .* not up yet" <<<"$out" && ! grep -qF "$SECRET" <<<"$out" && ! grep -rqF "$SECRET" "$SVC" "$ENROLL"'

# --- re-run is idempotent ----------------------------------------------------
id_before="$(sha256sum "$B/bot/identity.json")"
out="$(inst 2>&1)"; rc=$?
ok "re-run without --binary/--relay-url keeps everything" \
  '[ "$rc" = 0 ] && grep -q "identity: keeping existing" <<<"$out" && grep -q "relay env: keeping" <<<"$out" && [ "$(sha256sum "$B/bot/identity.json")" = "$id_before" ]'
ok "re-run adds no second cron line and no run backup" \
  '[ "$(grep -c jwt-refresh.sh "$TMP/cron")" = 1 ] && ! compgen -G "$SVC/run.bak-492-*" >/dev/null'

# --- a different relay URL belongs to native-relay-repoint ---------------------
out="$(inst --relay-url http://relay-b.tailnet.test:18921 2>&1)"; rc=$?
ok "different --relay-url is refused and the env file kept" \
  '[ "$rc" != 0 ] && grep -q "native-relay-repoint" <<<"$out" && grep -qx "NATIVE_RELAY_URL=http://relay-a.tailnet.test:18921" "$RELAY_ENV"'

# --- attachments --------------------------------------------------------------
out="$(inst --attachments --caption-secs 30 2>&1)"; rc=$?
ok "--attachments adds the spool env and backs up the changed run" \
  '[ "$rc" = 0 ] && grep -qF "NATIVE_MLS_BOT_AGENT_ATTACHMENTS=1 NATIVE_MLS_BOT_ATTACHMENT_CAPTION_SECS=30 NATIVE_MLS_BOT_ATTACHMENT_SPOOL=$B/attachments" "$SVC/run" && [ "$(mode "$B/attachments")" = 700 ] && compgen -G "$SVC/run.bak-492-*" >/dev/null'

# --- binary without identity-public-key: svlogd fallback ----------------------
setup_node
mkdir -p "$B/logs"
printf '@4000000065 {"event":"steward_ready","public_key":"%s","rooms":[]}\n' "$LOGKEY" > "$B/logs/current"
out="$(STUB_OLD_BINARY=1 inst --binary "$TMP/stub/native-mls-bot" --relay-url http://relay-a.tailnet.test:18921 2>&1)"; rc=$?
ok "old binary: key taken from steward_ready in svlogd current" \
  '[ "$rc" = 0 ] && grep -q "falling back" <<<"$out" && grep -qF "\"signing_key\": \"$LOGKEY\"" "$ENROLL"'
setup_node
out="$(STUB_OLD_BINARY=1 WAIT=1 inst --binary "$TMP/stub/native-mls-bot" --relay-url http://relay-a.tailnet.test:18921 2>&1)"; rc=$?
ok "old binary and no steward_ready: fails loudly, no enrollment.json" \
  '[ "$rc" != 0 ] && grep -q "no signing key" <<<"$out" && [ ! -e "$ENROLL" ]'

# --- --no-start ----------------------------------------------------------------
setup_node
out="$(inst --binary "$TMP/stub/native-mls-bot" --relay-url http://relay-a.tailnet.test:18921 --no-start 2>&1)"; rc=$?
ok "--no-start: down file, no sv up, enrollment still written" \
  '[ "$rc" = 0 ] && [ -e "$SVC/down" ] && [ ! -e "$TMP/sv.log" ] && grep -qF "$KEY" "$ENROLL"'
out="$(inst 2>&1)"; rc=$?
ok "a normal re-run removes down and starts" '[ "$rc" = 0 ] && [ ! -e "$SVC/down" ] && grep -q "up native-relay-bot" "$TMP/sv.log"'

echo "----"; echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
