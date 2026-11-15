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
