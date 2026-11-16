#!/usr/bin/env bats
# Tests for contrib/hooks/pre-upgrade-snapshot.sh.
#
# The hook is sourced (it guards main() behind BASH_SOURCE==$0) or executed with
# SNAPSHOT_DRY_RUN=1, so no real snapshot is ever taken.

HOOK="${BATS_TEST_DIRNAME}/../contrib/hooks/pre-upgrade-snapshot.sh"

# Run the hook as a program with SNAPSHOT_DRY_RUN=1 and the given env.
dry() { run env SNAPSHOT_DRY_RUN=1 "$@" bash "$HOOK"; }

@test "file: passes bash -n" {
  run bash -n "$HOOK"
  [ "$status" -eq 0 ]
}

@test "no SNAPSHOT_METHOD is a clear error" {
  run bash "$HOOK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SNAPSHOT_METHOD is required"* ]]
}

@test "unknown SNAPSHOT_METHOD is rejected" {
  run env SNAPSHOT_METHOD=zfs bash "$HOOK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown SNAPSHOT_METHOD"* ]]
}

# --- LVM ---

@test "lvm: missing LVM_VOLUME is rejected" {
  dry SNAPSHOT_METHOD=lvm LVM_SNAPSHOT_SIZE=5G
  [ "$status" -ne 0 ]
  [[ "$output" == *"LVM_VOLUME is required"* ]]
}

@test "lvm: missing LVM_SNAPSHOT_SIZE is rejected" {
  dry SNAPSHOT_METHOD=lvm LVM_VOLUME=/dev/vg0/root
  [ "$status" -ne 0 ]
  [[ "$output" == *"LVM_SNAPSHOT_SIZE is required"* ]]
}

@test "lvm: a bogus size is rejected" {
  dry SNAPSHOT_METHOD=lvm LVM_VOLUME=/dev/vg0/root LVM_SNAPSHOT_SIZE=huge
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid lvcreate size"* ]]
}

@test "lvm: forms the expected lvcreate command" {
  dry SNAPSHOT_METHOD=lvm LVM_VOLUME=/dev/vg0/root LVM_SNAPSHOT_SIZE=5G LVM_SNAPSHOT_NAME=snap1
  [ "$status" -eq 0 ]
  [[ "$output" == *"lvcreate --snapshot --name snap1 --size 5G /dev/vg0/root"* ]]
}

@test "lvm: default snapshot name is used when unset" {
  dry SNAPSHOT_METHOD=lvm LVM_VOLUME=/dev/vg0/root LVM_SNAPSHOT_SIZE=5G
  [ "$status" -eq 0 ]
  [[ "$output" == *"--name pre-upgrade-"* ]]
}

# --- btrfs ---

@test "btrfs: missing BTRFS_SUBVOLUME is rejected" {
  dry SNAPSHOT_METHOD=btrfs BTRFS_SNAPSHOT_DIR=/.snapshots
  [ "$status" -ne 0 ]
  [[ "$output" == *"BTRFS_SUBVOLUME is required"* ]]
}

@test "btrfs: missing BTRFS_SNAPSHOT_DIR is rejected" {
  dry SNAPSHOT_METHOD=btrfs BTRFS_SUBVOLUME=/
  [ "$status" -ne 0 ]
  [[ "$output" == *"BTRFS_SNAPSHOT_DIR is required"* ]]
}

@test "btrfs: forms the expected read-only snapshot command" {
  dry SNAPSHOT_METHOD=btrfs BTRFS_SUBVOLUME=/ BTRFS_SNAPSHOT_DIR=/.snapshots BTRFS_SNAPSHOT_NAME=snap1
  [ "$status" -eq 0 ]
  [[ "$output" == *"btrfs subvolume snapshot -r / /.snapshots/snap1"* ]]
}
