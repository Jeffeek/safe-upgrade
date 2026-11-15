#!/usr/bin/env bats
# Unit tests for the pure/stubbable functions of safe-upgrade.sh.

load test_helper

setup() {
  make_sandbox
}

# ---------------------------------------------------------------------------
# Sourcing
# ---------------------------------------------------------------------------

@test "sourcing the script does not run main()" {
  sh_run 'echo sourced-ok'
  [ "$status" -eq 0 ]
  [[ "$output" == *sourced-ok* ]]
  [[ "$output" != *"Starting system upgrade"* ]]
}

# ---------------------------------------------------------------------------
# matches_package_pattern
# ---------------------------------------------------------------------------

@test "matches_package_pattern: exact name matches" {
  sh_run 'matches_package_pattern sudo sudo'
  [ "$status" -eq 0 ]
}

@test "matches_package_pattern: a longer name does not match a shorter pattern" {
  sh_run 'matches_package_pattern sudoku sudo'
  [ "$status" -ne 0 ]
}

@test "matches_package_pattern: glob star matches" {
  sh_run 'matches_package_pattern postgresql-15 "postgresql-*"'
  [ "$status" -eq 0 ]
}

@test "matches_package_pattern: glob question mark matches one character" {
  sh_run 'matches_package_pattern libfoo1 "libfoo?"'
  [ "$status" -eq 0 ]
}

@test "matches_package_pattern: glob does not match unrelated names" {
  sh_run 'matches_package_pattern nginx "postgresql-*"'
  [ "$status" -ne 0 ]
}

@test "matches_package_pattern: architecture qualifier on the package is ignored" {
  sh_run 'matches_package_pattern sudo:amd64 sudo'
  [ "$status" -eq 0 ]
}

@test "matches_package_pattern: architecture qualifier on the pattern is ignored" {
  sh_run 'matches_package_pattern sudo "sudo:arm64"'
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# validate_uint
# ---------------------------------------------------------------------------

@test "validate_uint: accepts a plain number" {
  sh_run 'X=42; validate_uint X 100; echo "$X"'
  [ "$status" -eq 0 ]
  [ "$output" = "42" ]
}

@test "validate_uint: normalises leading zeros (no octal surprises)" {
  sh_run 'X=010; validate_uint X 100; echo "$X"'
  [ "$status" -eq 0 ]
  [ "$output" = "10" ]
}

@test "validate_uint: accepts zero" {
  sh_run 'X=0; validate_uint X 100; echo "$X"'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "validate_uint: rejects letters" {
  sh_run 'X=abc; validate_uint X 100'
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a non-negative integer"* ]]
}

@test "validate_uint: rejects negative numbers" {
  sh_run 'X=-1; validate_uint X 100'
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a non-negative integer"* ]]
}

@test "validate_uint: rejects an empty value" {
  sh_run 'X=""; validate_uint X 100'
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a non-negative integer"* ]]
}

@test "validate_uint: rejects values above the maximum" {
  sh_run 'X=101; validate_uint X 100'
  [ "$status" -eq 1 ]
  [[ "$output" == *"must not exceed 100"* ]]
}

@test "validate_uint: rejects absurdly long numbers" {
  sh_run 'X=1234567890; validate_uint X 99999999999'
  [ "$status" -eq 1 ]
  [[ "$output" == *"too large"* ]]
}

# ---------------------------------------------------------------------------
# boot_plan_ok
# ---------------------------------------------------------------------------

@test "boot_plan_ok: anything goes when /boot is writable" {
  sh_run 'BOOT_READONLY=0; boot_plan_ok "Inst linux-image-6.1.0-19-generic [x]"'
  [ "$status" -eq 0 ]
}

@test "boot_plan_ok: refuses a kernel install when /boot is read-only" {
  sh_run 'BOOT_READONLY=1; boot_plan_ok "Inst linux-image-6.1.0-19-generic [x]"'
  [ "$status" -eq 1 ]
}

@test "boot_plan_ok: refuses a grub removal when /boot is read-only" {
  sh_run 'BOOT_READONLY=1; boot_plan_ok "Remv grub-pc [2.06]"'
  [ "$status" -eq 1 ]
}

@test "boot_plan_ok: allows unrelated packages when /boot is read-only" {
  sh_run 'BOOT_READONLY=1; boot_plan_ok "Inst curl [8.0] (8.1 repo)"'
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# guard_removals
# ---------------------------------------------------------------------------

@test "guard_removals: no removals passes" {
  export SIM='Inst curl [8.0] (8.1 repo)'
  sh_run 'guard_removals test "$SIM" 5'
  [ "$status" -eq 0 ]
}

@test "guard_removals: a removal under the limit passes and is reported" {
  export SIM='Remv libfoo [1.0]'
  sh_run 'guard_removals test "$SIM" 5'
  [ "$status" -eq 0 ]
  [[ "$output" == *"would remove 1 package(s)"* ]]
}

@test "guard_removals: Purg records count as removals" {
  export SIM=$'Purg libfoo [1.0]\nPurg libbar [2.0]'
  sh_run 'guard_removals test "$SIM" 5'
  [ "$status" -eq 0 ]
  [[ "$output" == *"would remove 2 package(s)"* ]]
}

@test "guard_removals: exceeding the limit is blocked" {
  export SIM=$'Remv a [1]\nRemv b [1]\nRemv c [1]'
  sh_run 'guard_removals test "$SIM" 2'
  [ "$status" -eq 1 ]
  [[ "$output" == *"exceeds limit 2"* ]]
}

@test "guard_removals: exactly at the limit passes" {
  export SIM=$'Remv a [1]\nRemv b [1]'
  sh_run 'guard_removals test "$SIM" 2'
  [ "$status" -eq 0 ]
}

@test "guard_removals: default protected packages are blocked" {
  export SIM='Remv openssh-server [1:9.6]'
  sh_run 'guard_removals test "$SIM" 5'
  [ "$status" -eq 1 ]
  [[ "$output" == *"protected package: openssh-server"* ]]
}

@test "guard_removals: glob patterns in PROTECTED_PKGS are honoured" {
  export SIM='Remv postgresql-15 [15.1]'
  sh_run 'PROTECTED_PKGS="postgresql-*"; guard_removals test "$SIM" 5'
  [ "$status" -eq 1 ]
  [[ "$output" == *"protected package: postgresql-15"* ]]
}

@test "guard_removals: architecture-qualified names are still protected" {
  export SIM='Remv sudo:amd64 [1.9]'
  sh_run 'guard_removals test "$SIM" 5'
  [ "$status" -eq 1 ]
  [[ "$output" == *"protected package"* ]]
}

@test "guard_removals: an empty PROTECTED_PKGS removes only the configured list" {
  export SIM='Remv openssh-server [1:9.6]'
  sh_run 'PROTECTED_PKGS=""; guard_removals test "$SIM" 5'
  [ "$status" -eq 0 ]
}

@test "guard_removals: Essential packages are always protected" {
  export SIM='Remv coreutils [9.4]'
  sh_run 'FAKE_DPKG_META="coreutils\tyes\tno\n"; PROTECTED_PKGS=""; guard_removals test "$SIM" 5'
  [ "$status" -eq 1 ]
  [[ "$output" == *"protected package: coreutils"* ]]
}

@test "guard_removals: Protected: yes packages are always protected" {
  export SIM='Remv somepkg [1]'
  sh_run 'FAKE_DPKG_META="somepkg\tno\tyes\n"; PROTECTED_PKGS=""; guard_removals test "$SIM" 5'
  [ "$status" -eq 1 ]
}

@test "guard_removals: held packages are always protected" {
  export SIM='Remv held-pkg [1]'
  sh_run 'FAKE_HOLD="held-pkg\n"; PROTECTED_PKGS=""; guard_removals test "$SIM" 5'
  [ "$status" -eq 1 ]
  [[ "$output" == *"protected package: held-pkg"* ]]
}

@test "guard_removals: the running kernel image package is protected by name" {
  export SIM='Remv linux-image-6.1.0-18-generic [6.1.76]'
  sh_run 'PROTECTED_PKGS=""; guard_removals test "$SIM" 5'
  [ "$status" -eq 1 ]
}

@test "guard_removals: the running kernel's modules package is protected by name" {
  export SIM='Remv linux-modules-6.1.0-18-generic [6.1.76]'
  sh_run 'PROTECTED_PKGS=""; guard_removals test "$SIM" 5'
  [ "$status" -eq 1 ]
}

@test "guard_removals: the package that owns the running kernel file is protected" {
  export SIM='Remv custom-kernel-pkg [1]'
  sh_run 'FAKE_KERNEL_OWNER=custom-kernel-pkg; PROTECTED_PKGS=""; guard_removals test "$SIM" 5'
  [ "$status" -eq 1 ]
  [[ "$output" == *"protected package: custom-kernel-pkg"* ]]
}

@test "guard_removals: other kernels may be removed" {
  export SIM='Remv linux-image-6.1.0-10-generic [6.1.50]'
  sh_run 'PROTECTED_PKGS=""; guard_removals test "$SIM" 5'
  [ "$status" -eq 0 ]
}

@test "guard_removals: a bare 'Remv' record fails closed" {
  export SIM='Remv'
  sh_run 'guard_removals test "$SIM" 5'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unrecognized removal record"* ]]
}

@test "guard_removals: a glued 'Remvfoo' record fails closed" {
  export SIM='Remvfoo [1]'
  sh_run 'guard_removals test "$SIM" 5'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unrecognized removal record"* ]]
}

@test "guard_removals: announced removals without parseable records fail closed" {
  export SIM=$'The following packages will be REMOVED:\n  foo'
  sh_run 'guard_removals test "$SIM" 5'
  [ "$status" -eq 1 ]
  [[ "$output" == *"announced removals"* ]]
}

@test "guard_removals: unreadable dpkg metadata fails closed" {
  export SIM='Remv libfoo [1]'
  sh_run 'FAKE_DPKG_BROKEN=1; guard_removals test "$SIM" 5'
  [ "$status" -eq 1 ]
  [[ "$output" == *"failing closed"* ]]
}

@test "guard_removals: falls back to Essential-only when dpkg has no Protected field" {
  export SIM='Remv coreutils [9.4]'
  sh_run 'FAKE_NO_PROTECTED=1; FAKE_DPKG_META_ESS="coreutils\tyes\n"; PROTECTED_PKGS=""; guard_removals test "$SIM" 5'
  [ "$status" -eq 1 ]
  [[ "$output" == *"falling back"* ]]
}

# ---------------------------------------------------------------------------
# needs_reboot
# ---------------------------------------------------------------------------

@test "needs_reboot: /run/reboot-required triggers a reboot" {
  : > "$TEST_REBOOT_FLAG"
  sh_run 'needs_reboot'
  [ "$status" -eq 0 ]
}

@test "needs_reboot: only the running kernel installed means no reboot" {
  mk_kernel 6.1.0-18-generic
  sh_run 'needs_reboot'
  [ "$status" -eq 1 ]
}

@test "needs_reboot: a newer kernel of the same flavor means reboot" {
  mk_kernel 6.1.0-18-generic
  mk_kernel 6.1.0-19-generic
  sh_run 'needs_reboot'
  [ "$status" -eq 0 ]
}

@test "needs_reboot: uses version sort, not string sort (99 -> 100)" {
  mk_kernel 6.1.0-99-generic
  mk_kernel 6.1.0-100-generic
  sh_run 'FAKE_KERNEL=6.1.0-99-generic; needs_reboot'
  [ "$status" -eq 0 ]
}

@test "needs_reboot: picks the newest of several installed kernels" {
  mk_kernel 6.1.0-17-generic
  mk_kernel 6.1.0-18-generic
  mk_kernel 6.1.0-19-generic
  sh_run 'needs_reboot'
  [ "$status" -eq 0 ]
}

@test "needs_reboot: an older kernel alone does not trigger a reboot" {
  mk_kernel 6.1.0-17-generic
  sh_run 'needs_reboot'
  [ "$status" -eq 1 ]
}

@test "needs_reboot: a newer kernel of another flavor is ignored" {
  mk_kernel 6.1.0-18-generic
  mk_kernel 6.1.0-20-lowlatency
  sh_run 'needs_reboot'
  [ "$status" -eq 1 ]
}

@test "needs_reboot: a newer kernel without an initramfs is not bootable" {
  mk_kernel 6.1.0-18-generic
  mk_kernel 6.1.0-19-generic noinitrd
  sh_run 'needs_reboot'
  [ "$status" -eq 1 ]
}

@test "needs_reboot: no kernels in /boot means no reboot" {
  sh_run 'needs_reboot'
  [ "$status" -eq 1 ]
}

@test "needs_reboot: a Raspberry Pi style kernel name is not detected (documented limitation)" {
  mk_kernel 6.6.51+rpt-rpi-v8
  mk_kernel 6.6.62+rpt-rpi-v8
  sh_run 'FAKE_KERNEL=6.6.51+rpt-rpi-v8; needs_reboot'
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# reboot_allowed_by_interval / record_auto_reboot
# ---------------------------------------------------------------------------

@test "reboot_allowed_by_interval: interval 0 disables the protection" {
  sh_run 'REBOOT_MIN_INTERVAL=0; reboot_allowed_by_interval'
  [ "$status" -eq 0 ]
}

@test "reboot_allowed_by_interval: refuses when the machine booted recently" {
  sh_run 'REBOOT_MIN_INTERVAL=999999999; reboot_allowed_by_interval'
  [ "$status" -eq 1 ]
  [[ "$output" == *"booted only"* ]]
}

@test "reboot_allowed_by_interval: allows when there is no state file" {
  sh_run 'REBOOT_MIN_INTERVAL=5; reboot_allowed_by_interval'
  [ "$status" -eq 0 ]
}

@test "reboot_allowed_by_interval: refuses right after an automatic reboot" {
  sh_run 'REBOOT_MIN_INTERVAL=5; date +%s > "$STATE_DIR/last-auto-reboot"; reboot_allowed_by_interval'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Last automatic reboot"* ]]
}

@test "reboot_allowed_by_interval: allows when the last reboot was long ago" {
  sh_run 'REBOOT_MIN_INTERVAL=5; echo $(( $(date +%s) - 1000 )) > "$STATE_DIR/last-auto-reboot"; reboot_allowed_by_interval'
  [ "$status" -eq 0 ]
}

@test "reboot_allowed_by_interval: an unparseable state file fails closed" {
  sh_run 'REBOOT_MIN_INTERVAL=5; echo garbage > "$STATE_DIR/last-auto-reboot"; reboot_allowed_by_interval'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot parse"* ]]
}

@test "record_auto_reboot: writes a numeric timestamp" {
  sh_run 'record_auto_reboot; cat "$STATE_DIR/last-auto-reboot"'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# check_previous_runs
# ---------------------------------------------------------------------------

@test "check_previous_runs: passes with no records" {
  sh_run 'check_previous_runs'
  [ "$status" -eq 0 ]
}

@test "check_previous_runs: finished runs do not block" {
  echo "success 1700000000" > "$TEST_STATE_DIR/run-1.status"
  echo "failed:1 1700000001" > "$TEST_STATE_DIR/run-2.status"
  sh_run 'check_previous_runs'
  [ "$status" -eq 0 ]
}

@test "check_previous_runs: a 'running' record blocks the next run" {
  echo "running pid=123 started=1700000000" > "$TEST_STATE_DIR/run-1.status"
  sh_run 'check_previous_runs'
  [ "$status" -eq 1 ]
  [[ "$output" == *"earlier run appears to have been interrupted"* ]]
}

@test "check_previous_runs: an empty record blocks the next run" {
  : > "$TEST_STATE_DIR/run-1.status"
  sh_run 'check_previous_runs'
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# rotate_state
# ---------------------------------------------------------------------------

@test "rotate_state: keeps the 20 newest completed snapshot pairs" {
  for i in $(seq -w 1 25); do
    : > "$TEST_STATE_DIR/packages-202601010000$i-1.before"
    : > "$TEST_STATE_DIR/packages-202601010000$i-1.after"
  done
  sh_run 'rotate_state'
  [ "$status" -eq 0 ]
  [ "$(ls "$TEST_STATE_DIR"/packages-*.before | wc -l)" -eq 20 ]
  [ "$(ls "$TEST_STATE_DIR"/packages-*.after  | wc -l)" -eq 20 ]
  [ ! -e "$TEST_STATE_DIR/packages-20260101000001-1.before" ]
  [ -e "$TEST_STATE_DIR/packages-20260101000025-1.before" ]
}

@test "rotate_state: never deletes an incomplete snapshot (no .after)" {
  : > "$TEST_STATE_DIR/packages-20250101000000-1.before"
  for i in $(seq -w 1 25); do
    : > "$TEST_STATE_DIR/packages-202601010000$i-1.before"
    : > "$TEST_STATE_DIR/packages-202601010000$i-1.after"
  done
  sh_run 'rotate_state'
  [ "$status" -eq 0 ]
  [ -e "$TEST_STATE_DIR/packages-20250101000000-1.before" ]
}

@test "rotate_state: keeps the 20 newest run-status files" {
  for i in $(seq -w 1 25); do
    echo "success 1" > "$TEST_STATE_DIR/run-202601010000$i-1.status"
  done
  sh_run 'rotate_state'
  [ "$status" -eq 0 ]
  [ "$(ls "$TEST_STATE_DIR"/run-*.status | wc -l)" -eq 20 ]
  [ -e "$TEST_STATE_DIR/run-20260101000025-1.status" ]
  [ ! -e "$TEST_STATE_DIR/run-20260101000001-1.status" ]
}

@test "rotate_state: does nothing when below the retention limit" {
  echo "success 1" > "$TEST_STATE_DIR/run-1.status"
  : > "$TEST_STATE_DIR/packages-1.before"
  : > "$TEST_STATE_DIR/packages-1.after"
  sh_run 'rotate_state'
  [ "$status" -eq 0 ]
  [ -e "$TEST_STATE_DIR/run-1.status" ]
  [ -e "$TEST_STATE_DIR/packages-1.before" ]
}

# ---------------------------------------------------------------------------
# write_package_snapshot / report_package_changes
# ---------------------------------------------------------------------------

@test "write_package_snapshot: lists only fully installed packages, sorted" {
  export FAKE_PKGS=$'ii \tcurl\t8.0\nrc \told-pkg\t1.0\nii \tbash\t5.2\n'
  export OUT="$BATS_TEST_TMPDIR/snapshot"
  sh_run 'write_package_snapshot "$OUT"; cat "$OUT"'
  [ "$status" -eq 0 ]
  [ "$output" = $'bash\t5.2\ncurl\t8.0' ]
}

@test "report_package_changes: counts installed, upgraded and removed" {
  printf 'bash\t5.1\ncurl\t8.0\ngone\t1.0\n' > "$BATS_TEST_TMPDIR/old"
  printf 'bash\t5.2\ncurl\t8.0\nnew\t2.0\n'  > "$BATS_TEST_TMPDIR/new"
  export OLD="$BATS_TEST_TMPDIR/old" NEW="$BATS_TEST_TMPDIR/new"
  sh_run 'report_package_changes "$OLD" "$NEW"'
  [ "$status" -eq 0 ]
  [ "$output" = "Package changes: 1 installed, 1 upgraded/reconfigured by version, 1 removed." ]
}

@test "report_package_changes: identical inventories report no changes" {
  printf 'bash\t5.2\n' > "$BATS_TEST_TMPDIR/old"
  cp "$BATS_TEST_TMPDIR/old" "$BATS_TEST_TMPDIR/new"
  export OLD="$BATS_TEST_TMPDIR/old" NEW="$BATS_TEST_TMPDIR/new"
  sh_run 'report_package_changes "$OLD" "$NEW"'
  [ "$status" -eq 0 ]
  [ "$output" = "Package changes: 0 installed, 0 upgraded/reconfigured by version, 0 removed." ]
}

# ---------------------------------------------------------------------------
# unit_is_healthy
# ---------------------------------------------------------------------------

@test "unit_is_healthy: an active service is healthy" {
  export FAKE_UNIT=$'Type=simple\nRemainAfterExit=no\nActiveState=active\nSubState=running\n'
  sh_run 'unit_is_healthy demo.service'
  [ "$status" -eq 0 ]
}

@test "unit_is_healthy: a reloading service is healthy" {
  export FAKE_UNIT=$'Type=simple\nRemainAfterExit=no\nActiveState=reloading\nSubState=reload\n'
  sh_run 'unit_is_healthy demo.service'
  [ "$status" -eq 0 ]
}

@test "unit_is_healthy: a failed service is unhealthy" {
  export FAKE_UNIT=$'Type=simple\nRemainAfterExit=no\nActiveState=failed\nSubState=failed\n'
  sh_run 'unit_is_healthy demo.service'
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed state"* ]]
}

@test "unit_is_healthy: an inactive long-running service is unhealthy" {
  export FAKE_UNIT=$'Type=simple\nRemainAfterExit=no\nActiveState=inactive\nSubState=dead\n'
  sh_run 'unit_is_healthy demo.service'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not active"* ]]
}

@test "unit_is_healthy: an inactive oneshot without RemainAfterExit is healthy" {
  export FAKE_UNIT=$'Type=oneshot\nRemainAfterExit=no\nActiveState=inactive\nSubState=dead\n'
  sh_run 'unit_is_healthy demo.service'
  [ "$status" -eq 0 ]
}

@test "unit_is_healthy: an inactive oneshot WITH RemainAfterExit is unhealthy" {
  export FAKE_UNIT=$'Type=oneshot\nRemainAfterExit=yes\nActiveState=inactive\nSubState=dead\n'
  sh_run 'unit_is_healthy demo.service'
  [ "$status" -eq 1 ]
}

@test "unit_is_healthy: a restart loop is unhealthy without waiting" {
  export FAKE_UNIT=$'Type=simple\nRemainAfterExit=no\nActiveState=activating\nSubState=auto-restart\n'
  sh_run 'unit_is_healthy demo.service'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not stable"* ]]
}

@test "unit_is_healthy: property order does not matter" {
  export FAKE_UNIT=$'SubState=running\nActiveState=active\nRemainAfterExit=no\nType=simple\n'
  sh_run 'unit_is_healthy demo.service'
  [ "$status" -eq 0 ]
}

@test "unit_is_healthy: no output from systemctl is unhealthy" {
  export FAKE_UNIT=''
  sh_run 'unit_is_healthy demo.service'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown/unknown"* ]]
}

# ---------------------------------------------------------------------------
# check_space / path safety
# ---------------------------------------------------------------------------

@test "check_space: a missing /boot is skipped" {
  sh_run 'BOOT_DIR=/nonexistent/boot; check_space "$BOOT_DIR" 150'
  [ "$status" -eq 0 ]
  [[ "$output" == *"not present"* ]]
}

@test "check_space: any other missing path is fatal" {
  sh_run 'check_space /nonexistent/path 1'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required path does not exist"* ]]
}

@test "check_space: passes with a tiny requirement" {
  sh_run 'check_space / 1'
  [ "$status" -eq 0 ]
}

@test "check_space: fails when free space is below the requirement" {
  sh_run 'check_space / 1000000000'
  [ "$status" -eq 1 ]
  [[ "$output" == *"MB free on /"* ]]
}

@test "safe_path: a regular file is accepted" {
  : > "$BATS_TEST_TMPDIR/regular"
  export P="$BATS_TEST_TMPDIR/regular"
  sh_run 'safe_path "$P"'
  [ "$status" -eq 0 ]
}

@test "safe_path: a symlink is refused" {
  ln -s /etc "$BATS_TEST_TMPDIR/link"
  export P="$BATS_TEST_TMPDIR/link"
  sh_run 'safe_path "$P"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing symlink"* ]]
}

@test "check_owned_root_path: a missing path is accepted (it will be created)" {
  export P="$BATS_TEST_TMPDIR/does-not-exist"
  sh_run 'check_owned_root_path "$P"'
  [ "$status" -eq 0 ]
}

@test "check_owned_root_path: a file owned by someone else is refused" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "needs a non-root user to create a non-root-owned file"
  fi
  : > "$BATS_TEST_TMPDIR/mine"
  export P="$BATS_TEST_TMPDIR/mine"
  sh_run 'check_owned_root_path "$P"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be owned by root"* ]]
}
