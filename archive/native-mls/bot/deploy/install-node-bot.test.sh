#!/usr/bin/env bash
# Tests for install-node-bot.sh's JWT refresh timer (#799). The installer itself needs root
# and a real node, so this does not run it: the timer unit text and the armed check are
# read out of the script. Part 1-3 are hermetic (a stub systemctl). Part 4 needs systemd
# plus root or passwordless sudo: it loads the installer's timer text as a throwaway unit
# under /run/systemd/system, disables and enables it again in the same boot — the sequence
# that left the old definition without a next elapse — and removes it. Skipped elsewhere.
# shellcheck disable=SC2034,SC2016  # conditions are eval'd by ok(); patterns are literal
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/install-node-bot.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  cond: $2"; fi; }

# --- 1. the timer unit the installer writes ------------------------------------------
timer="$(awk '/native-relay-jwt-refresh\.timer" 0644 <</{f=1; next} f && /^EOF$/{exit} f' "$SCRIPT")"
ok "timer unit text found in the installer" '[ -n "$timer" ]'
ok "refreshes after boot" 'grep -Eq "^OnBootSec=" <<<"$timer"'
ok "refreshes every 12h after the last run" 'grep -Eq "^OnUnitActiveSec=12h$" <<<"$timer"'
ok "enabled through timers.target" 'grep -Eq "^WantedBy=timers.target$" <<<"$timer"'
# #799: Persistent= on monotonic triggers is what lost the next elapse.
ok "no Persistent= without OnCalendar= (#799)" \
  'grep -Eq "^OnCalendar=" <<<"$timer" || ! grep -Eq "^[[:space:]]*Persistent=" <<<"$timer"'

# --- 2. jwt_timer_armed against a stub systemctl --------------------------------------
sed -n '/^jwt_timer_armed() {$/,/^}$/p' "$SCRIPT" > "$TMP/armed.sh"
ok "jwt_timer_armed found in the installer" '[ -s "$TMP/armed.sh" ]'
# shellcheck disable=SC1091
. "$TMP/armed.sh"
STUB_RC=0 STUB_MONO="" STUB_REAL=""
systemctl() { # show <unit> -p <property> --value
  [ "$STUB_RC" = 0 ] || return "$STUB_RC"
  case "$*" in
    *NextElapseUSecMonotonic*) printf '%s\n' "$STUB_MONO" ;;
    *NextElapseUSecRealtime*) printf '%s\n' "$STUB_REAL" ;;
    *) return 9 ;;
  esac
}
STUB_MONO="1w 4d 15h 42min 45.365526s" STUB_REAL=""
ok "monotonic timer with a next elapse is armed" 'jwt_timer_armed'
STUB_MONO="infinity" STUB_REAL=""
ok "timer that lost its next elapse is not armed" '! jwt_timer_armed'
STUB_MONO="0" STUB_REAL="Sat 2026-11-14 00:00:00 KST"
ok "calendar timer with a next elapse is armed" 'jwt_timer_armed'
STUB_MONO="" STUB_REAL=""
ok "empty answer is not armed" '! jwt_timer_armed'
STUB_MONO="0" STUB_REAL=""
ok "zero monotonic without a wallclock time is not armed" '! jwt_timer_armed'
STUB_RC=1 STUB_MONO="1w" STUB_REAL=""
ok "unreadable timer state is not armed" '! jwt_timer_armed'
STUB_RC=0
unset -f systemctl

# --- 3. what the installer does with the timer, in order -----------------------------
line() { grep -n -m1 -F -- "$1" "$SCRIPT" | cut -d: -f1; }
l_reload="$(line 'systemctl daemon-reload')"
l_enable="$(line 'systemctl enable native-relay-jwt-refresh.timer')"
l_restart="$(line 'systemctl restart native-relay-jwt-refresh.timer')"
l_mint="$(line 'systemctl start native-relay-jwt-refresh.service')"
l_check="$(line 'if jwt_timer_armed; then armed=1')"
l_die="$(line 'native-relay-jwt-refresh.timer has no next elapse')"
ok "reload → enable → restart → mint through the unit → check → fail closed" \
  '[ -n "$l_reload" ] && [ -n "$l_enable" ] && [ -n "$l_restart" ] && [ -n "$l_mint" ] && [ -n "$l_check" ] && [ -n "$l_die" ] &&
   [ "$l_reload" -lt "$l_enable" ] && [ "$l_enable" -lt "$l_restart" ] && [ "$l_restart" -lt "$l_mint" ] && [ "$l_mint" -lt "$l_check" ] && [ "$l_check" -lt "$l_die" ]'
# The first mint must go through the service unit (its activation is the base
# OnUnitActiveSec counts from), not through a direct call of the script.
ok "no direct jwt-refresh.sh call in the install steps" '! grep -Eq "^\"\\\$BIN_DIR/jwt-refresh\.sh\"[[:space:]]*$" "$SCRIPT"'
ok "installer still parses" 'bash -n "$SCRIPT"'

# --- 4. live round trip on systemd (root or passwordless sudo) ------------------------
SUDO=""
live=0
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  if [ "$(id -u)" = 0 ]; then live=1
  elif sudo -n true 2>/dev/null; then SUDO="sudo -n"; live=1; fi
fi
if [ "$live" = 1 ]; then
  LAB="fm799-test-jwt-refresh-$$"
  UD=/run/systemd/system
  lab_clean() {
    $SUDO systemctl disable --runtime --now "$LAB.timer" >/dev/null 2>&1
    $SUDO systemctl stop "$LAB.timer" "$LAB.service" >/dev/null 2>&1
    $SUDO rm -f "$UD/$LAB.timer" "$UD/$LAB.service" "/var/lib/systemd/timers/stamp-$LAB.timer"
    $SUDO systemctl daemon-reload >/dev/null 2>&1
  }
  trap 'lab_clean; rm -rf "$TMP"' EXIT
  # The installer's own check, pointed at the throwaway unit.
  systemctl() { command $SUDO systemctl "${@/native-relay-jwt-refresh.timer/$LAB.timer}"; }
  wait_armed() { local _; for _ in 1 2 3 4 5 6 7 8 9 10; do jwt_timer_armed && return 0; sleep 1; done; return 1; }
  round_trip() { # <timer text> → 0 when the timer is armed after disable → enable
    printf '[Unit]\nDescription=fm799 test (harmless)\n[Service]\nType=oneshot\nExecStart=/bin/true\n' | $SUDO tee "$UD/$LAB.service" >/dev/null
    printf '%s\n' "$1" | $SUDO tee "$UD/$LAB.timer" >/dev/null
    command $SUDO systemctl daemon-reload
    command $SUDO systemctl enable --runtime --now "$LAB.timer" >/dev/null 2>&1
    wait_armed || { echo "  (first start never armed)"; return 2; }
    command $SUDO systemctl disable --runtime --now "$LAB.timer" >/dev/null 2>&1
    sleep 1
    command $SUDO systemctl enable --runtime --now "$LAB.timer" >/dev/null 2>&1
    wait_armed
  }
  round_trip "$timer"; rt=$?
  ok "installer's timer keeps a next elapse after disable → enable (#799)" '[ "$rt" = 0 ]'
  lab_clean
  # Informational: the definition before #799. Not asserted — it documents the systemd
  # behaviour this test guards against and may differ on another systemd version.
  old="$(printf '%s\n' "$timer" | sed 's/^OnUnitActiveSec=12h$/OnUnitActiveSec=12h\nPersistent=true/')"
  round_trip "$old"; rt_old=$?
  echo "info: pre-#799 definition after disable → enable: $([ "$rt_old" = 0 ] && echo armed || echo 'no next elapse') ($(command systemctl --version | head -1))"
  lab_clean
  unset -f systemctl
else
  echo "SKIP: live systemd round trip (needs systemd and root or passwordless sudo)"
fi

echo "install-node-bot.test: $pass passed, $fail failed"
[ "$fail" = 0 ]
