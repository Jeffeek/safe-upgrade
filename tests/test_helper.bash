# Shared helpers for the bats tests.
#
# The script is exercised by sourcing it inside a throw-away `bash -c`. This
# keeps its EXIT/ERR traps and `set -e` away from the bats process, and lets
# stubs.bash replace external commands with shell functions (the script resets
# PATH when sourced, so PATH-based stubs would not work).

SCRIPT="${BATS_TEST_DIRNAME}/../safe-upgrade.sh"
STUBS="${BATS_TEST_DIRNAME}/stubs.bash"

# sh_run '<bash code>': run the code in a fresh bash that has already sourced
# safe-upgrade.sh and stubs.bash. Sets $status and $output (stdout + stderr).
sh_run() {
  run bash -c 'source "$1"; source "$2"; eval "$3"' _ "$SCRIPT" "$STUBS" "$1"
}

# Create a fake kernel in the fake /boot: mk_kernel <release> [noinitrd]
mk_kernel() {
  : > "$TEST_BOOT_DIR/vmlinuz-$1"
  if [ "${2-}" != noinitrd ]; then
    : > "$TEST_BOOT_DIR/initrd.img-$1"
  fi
}

# Per-test sandbox directories, wired into the script via stubs.bash.
make_sandbox() {
  export TEST_BOOT_DIR="$BATS_TEST_TMPDIR/boot"
  export TEST_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export TEST_REBOOT_FLAG="$BATS_TEST_TMPDIR/reboot-required"
  mkdir -p "$TEST_BOOT_DIR" "$TEST_STATE_DIR"
}
