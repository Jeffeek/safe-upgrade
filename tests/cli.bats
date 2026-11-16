#!/usr/bin/env bats
# Tests that execute the script as a program (no root, no package changes).

load test_helper

@test "file: the shebang is on line 1" {
  [ "$(head -n 1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
}

@test "file: no Windows line endings (CRLF)" {
  ! grep -q $'\r' "$SCRIPT"
}

@test "file: passes bash -n" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "--help prints usage and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: sudo safe-upgrade.sh"* ]]
  [[ "$output" == *"--dry-run"* ]]
}

@test "-h is the same as --help" {
  run bash "$SCRIPT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "--help wins even after other options" {
  run bash "$SCRIPT" --dry-run --no-reboot --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "an unknown option prints usage, an error and exits 1" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option: --bogus"* ]]
  [[ "$output" == *"Usage:"* ]]
}

@test "running without root is refused" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "already root"
  fi
  run bash "$SCRIPT" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"Run as root"* ]]
}

@test "a non-apt system (no apt-get) is refused with a clear message" {
  # Debian/Ubuntu-only guard: with apt-get absent, preflight must bail out
  # cleanly. Needs root to get past the earlier root check; the probe for
  # apt-get is shadowed so the real binary on the runner is ignored.
  if [ "$(id -u)" -ne 0 ]; then
    skip "needs root to reach the apt-get check in preflight"
  fi
  run bash -c '
    source "$1"
    command() { if [ "${1:-}" = -v ] && [ "${2:-}" = apt-get ]; then return 1; fi; builtin command "$@"; }
    preflight
  ' _ "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Debian/Ubuntu only"* ]]
}

