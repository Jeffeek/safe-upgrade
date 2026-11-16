#!/usr/bin/env bash
#
# Real-systemd tests for safe-upgrade.sh.
#
# Run as root on a DISPOSABLE Linux VM where systemd is PID 1. GitHub-hosted
# Ubuntu runners are such VMs. (Docker containers are not: they have no
# systemd, which is why tests/integration/container-test.sh cannot cover
# POST_UPGRADE_SERVICES.)
#
# What is real here: systemd, its unit states, `systemctl show/cat`, and the
# contrib/systemd service running the script. What is scripted: apt-get and
# shutdown (fakes in /usr/local/bin), so no real packages change and the machine
# is never rebooted.
#
# The script writes to /etc/systemd/system, /etc/default, /usr/local, /var/lib,
# /var/log and /run, so it refuses to run unless it is told it is on a
# throw-away machine (GITHUB_ACTIONS=true or I_UNDERSTAND_THIS_MODIFIES_THE_SYSTEM=yes).
#
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(readlink -f "$HERE/../..")
SCRIPT=${SCRIPT:-$ROOT/safe-upgrade.sh}
CONTRIB=$ROOT/contrib/systemd

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root on a disposable VM." >&2; exit 2
fi
if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${I_UNDERSTAND_THIS_MODIFIES_THE_SYSTEM:-}" != yes ]; then
  echo "Refusing to run: this modifies the system. Set I_UNDERSTAND_THIS_MODIFIES_THE_SYSTEM=yes on a throw-away VM." >&2
  exit 2
fi
if [ ! -d /run/systemd/system ]; then
  echo "systemd is not running as PID 1 here; these tests need a real systemd." >&2
  exit 2
fi

UNITDIR=/etc/systemd/system
STATE=/var/lib/safe-upgrade
LOGF=/var/log/safe-upgrade.log
LOCKF=/run/safe-upgrade.lock
SHUTDOWN_MARK=/usr/local/bin/.shutdown-called
export FAKE_APT_LOG=/tmp/fake-apt.log
export FAKE_APT_FULL_SIM=/tmp/fake-full.sim
export FAKE_APT_AUTOREMOVE_SIM=/tmp/fake-autoremove.sim

FAILS=0; CUR=""; CUR_OK=1; OUT=""; RC=0

begin() { CUR=$1; CUR_OK=1; OUT=""; RC=0; }
fail()  { echo "  FAIL: $*"; CUR_OK=0; }
end() {
  if [ "$CUR_OK" -eq 1 ]; then
    echo "ok   - $CUR"
  else
    echo "FAIL - $CUR"
    printf '%s\n' "$OUT" | sed 's/^/    | /' | tail -n 30
    FAILS=$((FAILS + 1))
  fi
}
assert_rc()      { [ "$RC" -eq "$1" ] || fail "expected exit code $1, got $RC"; }
assert_out()     { grep -qF -- "$1" <<<"$OUT" || fail "output does not contain: $1"; }
assert_no_out()  { ! grep -qF -- "$1" <<<"$OUT" || fail "output unexpectedly contains: $1"; }
assert_file()    { [ -e "$1" ] || fail "missing file: $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "unexpected file: $1"; }
assert_file_has(){ grep -qE -- "$2" "$1" 2>/dev/null || fail "$1 does not match /$2/"; }

real_apt_calls() { grep -E "$1" "$FAKE_APT_LOG" 2>/dev/null | grep -vF -- ' -s ' || true; }

unit_prop() { systemctl show -p "$2" --value "$1" 2>/dev/null; }

# Poll until a unit property has the wanted value (max ~15s).
wait_prop() { # unit property value
  local i
  for i in $(seq 1 60); do
    [ "$(unit_prop "$1" "$2")" = "$3" ] && return 0
    sleep 0.25
  done
  return 1
}

reset_state() {
  rm -rf "$STATE" "$LOGF" "$LOCKF" /tmp/notify.out /run/reboot-required \
         "$FAKE_APT_LOG" "$FAKE_APT_FULL_SIM" "$FAKE_APT_AUTOREMOVE_SIM" "$SHUTDOWN_MARK"
  : > "$FAKE_APT_LOG"
}

# run_script [VAR=value ...] -- [script args ...]  ->  OUT, RC
run_script() {
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  OUT=$(env ${envs[@]+"${envs[@]}"} bash "$SCRIPT" "$@" 2>&1)
  RC=$?
}

sim_two_upgrades() {
  printf '%s\n' 'Inst curl [8.0.1] (8.1.0 Debian:stable [amd64])' \
                'Inst libcurl4 [8.0.1] (8.1.0 Debian:stable [amd64])' > "$FAKE_APT_FULL_SIM"
}

# ---------------------------------------------------------------------------
# Fakes and test units
# ---------------------------------------------------------------------------
install_fakes() {
  cat > /usr/local/bin/apt-get <<'EOF'
#!/bin/bash
# Fake apt-get for safe-upgrade integration tests.
echo "apt-get $*" >> "${FAKE_APT_LOG:-/tmp/fake-apt.log}"
cmd=""; sim=0
for a in "$@"; do
  case "$a" in
    --version) echo "apt 2.7.14 (amd64)"; exit 0 ;;
    -s) sim=1 ;;
    update|check|full-upgrade|autoremove|autoclean) cmd=$a ;;
  esac
done
case "$cmd" in
  update)  echo "Hit:1 http://fake.invalid stable InRelease"; echo "Reading package lists..." ;;
  check)   ;;
  autoclean) echo "AUTOCLEAN EXECUTED" ;;
  full-upgrade)
    if [ "$sim" -eq 1 ]; then
      [ -r "${FAKE_APT_FULL_SIM:-/nonexistent}" ] && cat "$FAKE_APT_FULL_SIM"
      echo "0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded."
    else
      echo "FULL-UPGRADE EXECUTED"
      [ -z "${FAKE_APT_SLOW:-}" ] || sleep "$FAKE_APT_SLOW"
    fi ;;
  autoremove)
    if [ "$sim" -eq 1 ]; then
      [ -r "${FAKE_APT_AUTOREMOVE_SIM:-/nonexistent}" ] && cat "$FAKE_APT_AUTOREMOVE_SIM"
      true
    else
      echo "AUTOREMOVE EXECUTED"
    fi ;;
  *) echo "fake apt-get: unsupported: $*" >&2; exit 100 ;;
esac
exit 0
EOF
  cat > /usr/local/bin/shutdown <<'EOF'
#!/bin/bash
echo "shutdown $*" >> "${FAKE_APT_LOG:-/tmp/fake-apt.log}"
: > /usr/local/bin/.shutdown-called
EOF
  chmod +x /usr/local/bin/apt-get /usr/local/bin/shutdown
}

mkunit() { # name, then unit file text on stdin
  cat > "$UNITDIR/$1.service"
}

install_test_units() {
  mkunit su-test-active <<'EOF'
[Service]
Type=simple
ExecStart=/bin/sleep infinity
EOF
  mkunit su-test-stopped <<'EOF'
[Service]
Type=simple
ExecStart=/bin/sleep infinity
EOF
  mkunit su-test-oneshot-ok <<'EOF'
[Service]
Type=oneshot
ExecStart=/bin/true
EOF
  mkunit su-test-oneshot-rae <<'EOF'
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
EOF
  mkunit su-test-failed <<'EOF'
[Service]
Type=oneshot
ExecStart=/bin/false
EOF
  mkunit su-test-loop <<'EOF'
[Unit]
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/bin/false
Restart=always
RestartSec=60
EOF
  mkunit su-test-slow <<'EOF'
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sleep 4
EOF
  systemctl daemon-reload
}

cleanup() {
  systemctl stop safe-upgrade.service safe-upgrade.timer >/dev/null 2>&1
  for u in active stopped oneshot-ok oneshot-rae failed loop slow; do
    systemctl stop "su-test-$u.service" >/dev/null 2>&1
    rm -f "$UNITDIR/su-test-$u.service"
  done
  rm -f "$UNITDIR/safe-upgrade.service" "$UNITDIR/safe-upgrade.timer" \
        /etc/default/safe-upgrade /usr/local/sbin/safe-upgrade.sh /usr/local/sbin/su-test-notify.sh \
        /usr/local/bin/apt-get /usr/local/bin/shutdown "$SHUTDOWN_MARK"
  systemctl daemon-reload >/dev/null 2>&1
  systemctl reset-failed >/dev/null 2>&1
  rm -rf "$STATE" "$LOGF" "$LOCKF" /tmp/notify.out /run/reboot-required \
         "$FAKE_APT_LOG" "$FAKE_APT_FULL_SIM" "$FAKE_APT_AUTOREMOVE_SIM"
}
trap cleanup EXIT

echo "systemd: $(systemctl --version | head -n1) | state: $(systemctl is-system-running 2>&1)"
install_fakes
install_test_units

# Bring the test units into the states the scenarios need.
systemctl start su-test-active.service
systemctl start su-test-oneshot-ok.service
systemctl start su-test-oneshot-rae.service
systemctl start su-test-failed.service 2>/dev/null || true
systemctl start su-test-loop.service 2>/dev/null || true
wait_prop su-test-loop.service SubState auto-restart || echo "note: su-test-loop did not reach auto-restart"
SVC_COMMON=(POST_UPGRADE_SETTLE_SECONDS=0)

# ===========================================================================
echo "== systemd unit-state checks =="

begin "S1 healthy services (active, oneshot, oneshot+RemainAfterExit) pass"
reset_state; sim_two_upgrades
run_script "${SVC_COMMON[@]}" POST_UPGRADE_SERVICES="su-test-active su-test-oneshot-ok su-test-oneshot-rae" -- --no-reboot
assert_rc 0
assert_no_out "Post-upgrade service"
end

begin "S2 a failed unit fails the run"
reset_state; sim_two_upgrades
run_script "${SVC_COMMON[@]}" POST_UPGRADE_SERVICES="su-test-failed" -- --no-reboot
assert_rc 1
assert_out "failed state: su-test-failed"
end

begin "S3 a stopped long-running unit fails the run"
reset_state; sim_two_upgrades
run_script "${SVC_COMMON[@]}" POST_UPGRADE_SERVICES="su-test-stopped" -- --no-reboot
assert_rc 1
assert_out "not active"
assert_out "su-test-stopped"
end

begin "S4 a unit in an auto-restart loop fails the run (without a 30s wait)"
reset_state; sim_two_upgrades
start=$(date +%s)
run_script "${SVC_COMMON[@]}" POST_UPGRADE_SERVICES="su-test-loop" -- --no-reboot
elapsed=$(( $(date +%s) - start ))
assert_rc 1
assert_out "not stable"
[ "$elapsed" -lt 25 ] || fail "took ${elapsed}s; a restart loop must not be waited on"
end

begin "S5 an unknown unit fails the run"
reset_state; sim_two_upgrades
run_script "${SVC_COMMON[@]}" POST_UPGRADE_SERVICES="su-test-does-not-exist" -- --no-reboot
assert_rc 1
assert_out "unknown unit: su-test-does-not-exist"
end

begin "S6 a unit that is still starting is waited for"
reset_state; sim_two_upgrades
systemctl stop su-test-slow.service 2>/dev/null
systemctl start --no-block su-test-slow.service
run_script "${SVC_COMMON[@]}" POST_UPGRADE_SERVICES="su-test-slow" -- --no-reboot
assert_rc 0
assert_no_out "not stable"
end

begin "S7 service checks run only when something changed"
reset_state     # no pending upgrades -> nothing mutated
run_script "${SVC_COMMON[@]}" POST_UPGRADE_SERVICES="su-test-failed" -- --no-reboot
assert_rc 0
assert_out "Nothing was changed"
end

begin "S8 a failed service check blocks the automatic reboot"
reset_state; sim_two_upgrades; touch /run/reboot-required
run_script "${SVC_COMMON[@]}" REBOOT_MIN_INTERVAL=0 POST_UPGRADE_SERVICES="su-test-failed" -- --reboot
assert_rc 1
assert_out "Not scheduling an automatic reboot"
assert_no_file "$SHUTDOWN_MARK"
end

begin "S9 (control) healthy services allow the automatic reboot"
reset_state; sim_two_upgrades; touch /run/reboot-required
run_script "${SVC_COMMON[@]}" REBOOT_MIN_INTERVAL=0 POST_UPGRADE_SERVICES="su-test-active" -- --reboot
assert_rc 0
assert_out "Scheduling reboot in 1 minute"
assert_file "$SHUTDOWN_MARK"
end

# ===========================================================================
echo "== contrib/systemd units =="

if [ ! -f "$CONTRIB/safe-upgrade.service" ]; then
  echo "skip - contrib/systemd/ not found; skipping service tests"
else
  install -m 0755 "$SCRIPT" /usr/local/sbin/safe-upgrade.sh
  install -m 0644 "$CONTRIB/safe-upgrade.service" "$UNITDIR/safe-upgrade.service"
  install -m 0644 "$CONTRIB/safe-upgrade.timer"   "$UNITDIR/safe-upgrade.timer"
  cat > /usr/local/sbin/su-test-notify.sh <<'EOF'
#!/bin/sh
echo "$STATUS $EXIT_CODE" > /tmp/notify.out
EOF
  chmod +x /usr/local/sbin/su-test-notify.sh
  write_default() { # extra lines on stdin
    {
      echo "FAKE_APT_LOG=$FAKE_APT_LOG"
      echo "FAKE_APT_FULL_SIM=$FAKE_APT_FULL_SIM"
      echo "NOTIFY_ON=always"
      echo "NOTIFY_CMD=/usr/local/sbin/su-test-notify.sh"
      echo "POST_UPGRADE_SERVICES=su-test-active"
      echo "POST_UPGRADE_SETTLE_SECONDS=0"
      cat
    } > /etc/default/safe-upgrade
  }
  systemctl daemon-reload

  begin "U1 the shipped service and timer pass systemd-analyze verify"
  OUT=$(systemd-analyze verify "$UNITDIR/safe-upgrade.service" "$UNITDIR/safe-upgrade.timer" 2>&1); RC=$?
  assert_rc 0
  end

  begin "U2 the timer's OnCalendar expression is valid"
  cal=$(sed -n 's/^OnCalendar=//p' "$UNITDIR/safe-upgrade.timer")
  OUT=$(systemd-analyze calendar "$cal" 2>&1); RC=$?
  assert_rc 0
  assert_out "Next elapse"
  end

  begin "U3 the service runs the script to success, reads /etc/default/safe-upgrade, and notifies"
  reset_state; sim_two_upgrades; write_default </dev/null
  systemctl start safe-upgrade.service; RC=$?
  OUT=$(journalctl -u safe-upgrade.service --no-pager -o cat 2>&1)
  assert_rc 0
  [ "$(unit_prop safe-upgrade.service Result)" = success ] || fail "Result is not success"
  assert_out "Starting system upgrade"
  assert_out "Upgrading packages"
  assert_file_has /tmp/notify.out '^ok 0$'
  assert_file_has "$(ls "$STATE"/run-*.status 2>/dev/null | head -n1)" '^success '
  end

  begin "U4 the service fails (and notifies) when a monitored unit is down"
  reset_state; sim_two_upgrades; write_default <<<"POST_UPGRADE_SERVICES=su-test-failed"
  systemctl start safe-upgrade.service 2>/dev/null; RC=$?
  OUT=$(journalctl -u safe-upgrade.service --no-pager -o cat 2>&1)
  [ "$RC" -ne 0 ] || fail "systemctl start should report the failed run"
  [ "$(unit_prop safe-upgrade.service Result)" = exit-code ] || fail "Result is not exit-code"
  assert_out "failed state: su-test-failed"
  assert_file_has /tmp/notify.out '^failed 1$'
  systemctl reset-failed safe-upgrade.service 2>/dev/null
  end

  begin "U5 stopping the service mid-upgrade leaves a finalised 'failed' record, not 'running'"
  reset_state; sim_two_upgrades; write_default <<<"FAKE_APT_SLOW=30"
  systemctl start --no-block safe-upgrade.service
  for _ in $(seq 1 60); do
    [ -n "$(real_apt_calls 'full-upgrade')" ] && break
    sleep 0.25
  done
  systemctl stop safe-upgrade.service
  sleep 1
  OUT=$(journalctl -u safe-upgrade.service --no-pager -o cat 2>&1)
  rec=$(ls "$STATE"/run-*.status 2>/dev/null | head -n1)
  [ -n "$rec" ] || fail "no run-status record was written"
  assert_file_has "$rec" '^failed:'
  systemctl reset-failed safe-upgrade.service 2>/dev/null
  end
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All systemd scenarios passed."
else
  echo "$FAILS systemd scenario(s) FAILED."
fi
[ "$FAILS" -eq 0 ]