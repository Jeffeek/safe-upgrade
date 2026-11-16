#!/usr/bin/env bash
#
# End-to-end tests for safe-upgrade.sh. Run as root INSIDE a disposable
# Debian/Ubuntu container or VM (it writes /var/log, /var/lib, /run and
# /usr/local/bin). Never run it on a machine you care about.
#
#   Phase A (needs network): the real apt-get, real repositories.
#   Phase B (offline):       a fake apt-get/shutdown in /usr/local/bin lets us
#                            script exact simulations, so every guard, hook,
#                            notification and exit code of main() is exercised
#                            without touching the real package set.
#
# Environment:
#   SCRIPT           path to safe-upgrade.sh (default: ../../safe-upgrade.sh)
#   SKIP_REAL_APT=1  skip phase A (offline runs)
#
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=${SCRIPT:-$HERE/../../safe-upgrade.sh}
SCRIPT=$(readlink -f "$SCRIPT")

if [ "$(id -u)" -ne 0 ]; then
  echo "This test must run as root inside a disposable container/VM." >&2
  exit 2
fi
if [ "${I_UNDERSTAND_THIS_MODIFIES_THE_SYSTEM:-}" != yes ] && [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ]; then
  echo "Refusing to run outside a container. Set I_UNDERSTAND_THIS_MODIFIES_THE_SYSTEM=yes to override." >&2
  exit 2
fi

STATE=/var/lib/safe-upgrade
LOGF=/var/log/safe-upgrade.log
LOCKF=/run/safe-upgrade.lock
export FAKE_APT_LOG=/tmp/fake-apt.log
export FAKE_APT_FULL_SIM=/tmp/fake-full.sim
export FAKE_APT_AUTOREMOVE_SIM=/tmp/fake-autoremove.sim

FAILS=0
CUR=""
CUR_OK=1
OUT=""
RC=0

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
assert_glob()    { compgen -G "$1" >/dev/null || fail "no file matches: $1"; }
assert_no_glob() { ! compgen -G "$1" >/dev/null || fail "unexpected file(s) match: $1"; }
assert_file_has(){ grep -qE -- "$2" "$1" 2>/dev/null || fail "$1 does not match /$2/"; }

# Real (non-simulated) apt-get calls recorded by the fake.
real_apt_calls() { grep -E "$1" "$FAKE_APT_LOG" 2>/dev/null | grep -vF -- ' -s ' || true; }
assert_real_apt()    { [ -n "$(real_apt_calls "$1")" ] || fail "fake apt-get never ran a real: $1"; }
assert_no_real_apt() { [ -z "$(real_apt_calls "$1")" ] || fail "fake apt-get unexpectedly ran a real: $1"; }

reset_state() {
  rm -rf "$STATE" "$LOGF" "$LOCKF" /tmp/hook-ran /tmp/notify.out /tmp/sig.out \
         "$FAKE_APT_LOG" "$FAKE_APT_FULL_SIM" "$FAKE_APT_AUTOREMOVE_SIM" \
         /run/reboot-required /usr/local/bin/.shutdown-called
  : > "$FAKE_APT_LOG"
  unset FAKE_APT_SLOW
}

# run_script [VAR=value ...] -- [script args ...]   ->  sets OUT and RC
run_script() {
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  OUT=$(env ${envs[@]+"${envs[@]}"} bash "$SCRIPT" "$@" 2>&1)
  RC=$?
}

# ---------------------------------------------------------------------------
# Fake apt-get / shutdown (phase B)
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

remove_fakes() {
  rm -f /usr/local/bin/apt-get /usr/local/bin/shutdown /usr/local/bin/.shutdown-called
}
trap remove_fakes EXIT

sim_two_upgrades() {
  printf '%s\n' 'Inst curl [8.0.1] (8.1.0 Debian:stable [amd64])' \
                'Inst libcurl4 [8.0.1] (8.1.0 Debian:stable [amd64])' > "$FAKE_APT_FULL_SIM"
}

# ===========================================================================
# Phase A - real apt-get (network required)
# ===========================================================================
if [ "${SKIP_REAL_APT:-0}" != 1 ]; then
  echo "== Phase A: real apt-get =="
  export DEBIAN_FRONTEND=noninteractive

  begin "A1 --dry-run completes and changes nothing"
  reset_state
  run_script -- --dry-run
  assert_rc 0
  assert_out "Dry run complete"
  assert_no_file "$LOGF"
  assert_no_glob "$STATE/run-*.status"
  end

  begin "A2 real run succeeds, writes status, log and (if anything changed) inventories"
  reset_state
  run_script -- --no-reboot
  assert_rc 0
  assert_file "$LOGF"
  assert_file_has "$LOGF" "Starting system upgrade"
  if grep -q "Nothing was changed" <<<"$OUT"; then
    assert_no_glob "$STATE/run-*.status"
  else
    assert_glob "$STATE/packages-*.before"
    assert_glob "$STATE/packages-*.after"
    assert_file_has "$(ls "$STATE"/run-*.status | head -n1)" '^success '
  fi
  end

  begin "A3 an immediate second run is a clean no-op"
  run_script -- --no-reboot
  assert_rc 0
  end

  begin "A4 --clean works with the real apt-get"
  run_script -- --no-reboot --clean
  assert_rc 0
  assert_out "Cleaning obsolete cached packages"
  end
fi

# ===========================================================================
# Phase B - fake apt-get (offline, deterministic)
# ===========================================================================
echo "== Phase B: scripted apt-get =="
install_fakes

begin "B1 --dry-run with pending upgrades installs nothing and writes no state"
reset_state; sim_two_upgrades
run_script -- --dry-run
assert_rc 0
assert_out "Simulation: 2 package(s) to install/upgrade"
assert_out "Dry run complete"
assert_no_real_apt 'full-upgrade'
assert_no_file "$LOGF"
assert_no_glob "$STATE/*.status"
end

begin "B2 real run: upgrades, writes inventories and a success record"
reset_state; sim_two_upgrades
run_script -- --no-reboot
assert_rc 0
assert_out "Upgrading packages"
assert_real_apt 'full-upgrade'
assert_glob "$STATE/packages-*.before"
assert_glob "$STATE/packages-*.after"
assert_file_has "$(ls "$STATE"/run-*.status 2>/dev/null | head -n1)" '^success '
assert_file_has "$LOGF" "Upgrading packages"
end

begin "B3 nothing to do: no hook, no snapshot, no state"
reset_state
run_script PRE_UPGRADE_HOOK='touch /tmp/hook-ran' -- --no-reboot
assert_rc 0
assert_out "No packages need upgrading"
assert_out "Nothing was changed"
assert_no_file /tmp/hook-ran
assert_no_glob "$STATE/packages-*"
assert_no_glob "$STATE/run-*.status"
end

begin "B4 PRE_UPGRADE_HOOK runs before the upgrade"
reset_state; sim_two_upgrades
run_script PRE_UPGRADE_HOOK='touch /tmp/hook-ran' -- --no-reboot
assert_rc 0
assert_file /tmp/hook-ran
assert_real_apt 'full-upgrade'
end

begin "B5 a failing PRE_UPGRADE_HOOK aborts before any package change"
reset_state; sim_two_upgrades
run_script PRE_UPGRADE_HOOK='false' -- --no-reboot
assert_rc 1
assert_out "PRE_UPGRADE_HOOK failed"
assert_no_real_apt 'full-upgrade'
assert_no_real_apt 'autoremove'
end

begin "B6 a hanging PRE_UPGRADE_HOOK is killed by the timeout"
reset_state; sim_two_upgrades
run_script PRE_UPGRADE_HOOK='sleep 30' PRE_UPGRADE_TIMEOUT=1 -- --no-reboot
assert_rc 1
assert_out "failed or timed out"
assert_no_real_apt 'full-upgrade'
end

begin "B7 removing a protected package is blocked before anything runs"
reset_state
printf '%s\n' 'Inst curl [8.0.1] (8.1.0 Debian:stable [amd64])' \
              'Remv openssh-server [1:9.2]' > "$FAKE_APT_FULL_SIM"
run_script -- --no-reboot
assert_rc 1
assert_out "protected package: openssh-server"
assert_out "removal guard tripped"
assert_no_real_apt 'full-upgrade'
end

begin "B8 too many removals are blocked"
reset_state
{ echo 'Inst curl [8.0.1] (8.1.0 Debian:stable [amd64])'
  for i in 1 2 3 4 5 6; do echo "Remv libgone$i [1.0]"; done; } > "$FAKE_APT_FULL_SIM"
run_script -- --no-reboot
assert_rc 1
assert_out "exceeds limit 5"
assert_no_real_apt 'full-upgrade'
end

begin "B9 MAX_REMOVALS raises the limit"
reset_state
{ echo 'Inst curl [8.0.1] (8.1.0 Debian:stable [amd64])'
  for i in 1 2 3 4 5 6; do echo "Remv libgone$i [1.0]"; done; } > "$FAKE_APT_FULL_SIM"
run_script MAX_REMOVALS=10 -- --no-reboot
assert_rc 0
assert_real_apt 'full-upgrade'
end

begin "B10 a malformed removal record fails closed"
reset_state
printf '%s\n' 'Inst curl [8.0.1] (8.1.0 Debian:stable [amd64])' 'Remv' > "$FAKE_APT_FULL_SIM"
run_script -- --no-reboot
assert_rc 1
assert_out "unrecognized removal record"
assert_no_real_apt 'full-upgrade'
end

begin "B11 an autoremove that would hit a protected package is skipped and fails the run"
reset_state; sim_two_upgrades
printf '%s\n' 'Remv sudo [1.9]' > "$FAKE_APT_AUTOREMOVE_SIM"
run_script -- --no-reboot
assert_rc 1
assert_real_apt 'full-upgrade'
assert_no_real_apt 'autoremove'
assert_out "Autoremove skipped by removal guard"
end

begin "B12 a safe autoremove is executed"
reset_state
printf '%s\n' 'Remv libunused1 [1.0]' > "$FAKE_APT_AUTOREMOVE_SIM"
run_script -- --no-reboot
assert_rc 0
assert_real_apt 'autoremove'
assert_out "Removing unneeded dependencies"
end

begin "B13 --clean runs autoclean"
reset_state
run_script -- --no-reboot --clean
assert_rc 0
assert_out "Cleaning obsolete cached packages"
assert_real_apt 'autoclean'
end

begin "B14 an interrupted earlier run blocks the next one"
reset_state; mkdir -p "$STATE"
echo "running pid=1 started=1" > "$STATE/run-stale.status"
run_script -- --no-reboot
assert_rc 1
assert_out "earlier run appears to have been interrupted"
assert_no_real_apt 'full-upgrade'
end

begin "B15 a second instance exits 75 while the lock is held"
reset_state
( flock "$LOCKF" sleep 6 ) &
holder=$!
sleep 1
run_script -- --no-reboot
assert_rc 75
assert_out "already in progress"
wait "$holder" 2>/dev/null || true
end

begin "B16 invalid configuration is rejected"
reset_state
run_script MAX_REMOVALS=abc -- --dry-run
assert_rc 1
assert_out "MAX_REMOVALS must be a non-negative integer"
run_script NOTIFY_ON=sometimes -- --dry-run
[ "$RC" -eq 1 ] || fail "NOTIFY_ON=sometimes should exit 1, got $RC"
grep -qF "NOTIFY_ON must be" <<<"$OUT" || fail "missing NOTIFY_ON message"
end

begin "B16b --show-config prints effective values and changes nothing"
reset_state; sim_two_upgrades
run_script MAX_REMOVALS=0 PROTECTED_PKGS="nginx*" -- --show-config
assert_rc 0
assert_out "Effective configuration"
assert_out "MAX_REMOVALS                0"
assert_out "nginx*"
assert_no_real_apt 'full-upgrade'
assert_no_file "$LOGF"
assert_no_glob "$STATE/run-*.status"
end

begin "B17 --flatpak without flatpak installed is a clear error"
reset_state
if command -v flatpak >/dev/null 2>&1; then
  echo "  (flatpak is installed here; skipping)"
else
  run_script -- --dry-run --flatpak
  assert_rc 1
  assert_out "flatpak is not installed"
fi
end

begin "B18 insufficient disk space fails and notifies"
reset_state
run_script MIN_FREE_MB=100000000 NOTIFY_CMD='echo "$STATUS $EXIT_CODE" > /tmp/notify.out' -- --no-reboot
assert_rc 1
assert_out "MB free on /"
assert_file_has /tmp/notify.out '^failed 1$'
end

begin "B19 NOTIFY_ON=always reports success"
reset_state
run_script NOTIFY_ON=always NOTIFY_CMD='echo "$STATUS $EXIT_CODE" > /tmp/notify.out' -- --no-reboot
assert_rc 0
assert_file_has /tmp/notify.out '^ok 0$'
end

begin "B20 the default NOTIFY_ON=fail stays quiet on success"
reset_state
run_script NOTIFY_CMD='echo "$STATUS" > /tmp/notify.out' -- --no-reboot
assert_rc 0
assert_no_file /tmp/notify.out
end

begin "B21 --dry-run never notifies, even on failure"
reset_state
run_script MIN_FREE_MB=100000000 NOTIFY_CMD='echo x > /tmp/notify.out' -- --dry-run
assert_rc 1
assert_no_file /tmp/notify.out
end

begin "B22 pending reboot + --no-reboot: not scheduled, NOTIFY_ON=attention fires"
reset_state; touch /run/reboot-required
run_script NOTIFY_ON=attention NOTIFY_CMD='echo "$REBOOT_PENDING" > /tmp/notify.out' -- --no-reboot
assert_rc 0
assert_out "Reboot required"
assert_no_file /usr/local/bin/.shutdown-called
assert_file_has /tmp/notify.out '^1$'
end

begin "B23 pending reboot + --reboot: scheduled once and recorded"
reset_state; touch /run/reboot-required
run_script REBOOT_MIN_INTERVAL=0 -- --reboot
assert_rc 0
assert_out "Scheduling reboot in 1 minute"
assert_file /usr/local/bin/.shutdown-called
assert_file_has "$STATE/last-auto-reboot" '^[0-9]+$'
end

begin "B24 --reboot is suppressed when the machine booted recently"
reset_state; touch /run/reboot-required
run_script REBOOT_MIN_INTERVAL=31536000 -- --reboot
assert_rc 0
assert_out "not rebooting again automatically"
assert_no_file /usr/local/bin/.shutdown-called
end

begin "B25 SIGTERM during the upgrade finalises the run as failed:143"
reset_state; sim_two_upgrades
export FAKE_APT_SLOW=4
bash "$SCRIPT" --no-reboot > /tmp/sig.out 2>&1 &
pid=$!
for _ in $(seq 1 40); do
  [ -n "$(real_apt_calls 'full-upgrade')" ] && break
  sleep 0.25
done
kill -TERM "$pid" 2>/dev/null
RC=0; wait "$pid" || RC=$?
OUT=$(cat /tmp/sig.out 2>/dev/null)
unset FAKE_APT_SLOW
assert_rc 143
assert_file_has "$(ls "$STATE"/run-*.status 2>/dev/null | head -n1)" '^failed:143 '
end

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All integration scenarios passed."
else
  echo "$FAILS integration scenario(s) FAILED."
fi
reset_state
[ "$FAILS" -eq 0 ]
