#!/usr/bin/env bash
#
# pre-upgrade-snapshot.sh - example PRE_UPGRADE_HOOK for safe-upgrade.sh
#
# Takes a filesystem snapshot as a rollback point, immediately before the first
# package change. safe-upgrade.sh runs this as root with a timeout; if it exits
# non-zero the upgrade aborts before any package is touched.
#
# THIS IS AN EXAMPLE YOU MUST ADAPT AND TEST. A snapshot you have never restored
# is not a backup. Know your restore procedure before relying on it.
#
# Configure via environment (set these in /etc/default/safe-upgrade or the unit):
#   SNAPSHOT_METHOD   lvm | btrfs   (required)
#
#   LVM:
#     LVM_VOLUME       logical volume to snapshot, e.g. /dev/vg0/root (required)
#     LVM_SNAPSHOT_SIZE  snapshot size, e.g. 5G (required; needs free VG space)
#     LVM_SNAPSHOT_NAME  snapshot LV name (default: pre-upgrade-<timestamp>)
#
#   btrfs:
#     BTRFS_SUBVOLUME  subvolume to snapshot, e.g. / or /@ (required)
#     BTRFS_SNAPSHOT_DIR  directory to hold snapshots, e.g. /.snapshots (required)
#     BTRFS_SNAPSHOT_NAME snapshot name (default: pre-upgrade-<timestamp>)
#
# Set SNAPSHOT_DRY_RUN=1 to print the command that would run without running it
# (useful for a first check and for the test suite).
#
set -euo pipefail

die() { echo "pre-upgrade-snapshot: $*" >&2; exit 1; }

# A timestamp for the default snapshot name. date is fine here (unlike inside
# safe-upgrade's resumable workflow, this is a plain one-shot script).
stamp=$(date +%Y%m%d-%H%M%S)

# Run a command, or just print it under SNAPSHOT_DRY_RUN.
run() {
  if [ "${SNAPSHOT_DRY_RUN:-0}" = 1 ]; then
    printf 'DRY-RUN:'; printf ' %q' "$@"; printf '\n'
    return 0
  fi
  "$@"
}

snapshot_lvm() {
  local name=${LVM_SNAPSHOT_NAME:-pre-upgrade-$stamp}
  [ -n "${LVM_VOLUME:-}" ] || die "LVM_VOLUME is required for SNAPSHOT_METHOD=lvm."
  [ -n "${LVM_SNAPSHOT_SIZE:-}" ] || die "LVM_SNAPSHOT_SIZE is required (e.g. 5G)."
  [[ "$LVM_SNAPSHOT_SIZE" =~ ^[0-9]+[kKmMgGtT]?$ ]] \
    || die "LVM_SNAPSHOT_SIZE '$LVM_SNAPSHOT_SIZE' is not a valid lvcreate size."
  if [ "${SNAPSHOT_DRY_RUN:-0}" != 1 ]; then
    command -v lvcreate >/dev/null 2>&1 || die "lvcreate not found; is LVM installed?"
    [ -e "$LVM_VOLUME" ] || die "LVM_VOLUME '$LVM_VOLUME' does not exist."
  fi
  echo "pre-upgrade-snapshot: LVM snapshot '$name' of $LVM_VOLUME (${LVM_SNAPSHOT_SIZE})"
  run lvcreate --snapshot --name "$name" --size "$LVM_SNAPSHOT_SIZE" "$LVM_VOLUME"
}

snapshot_btrfs() {
  local name=${BTRFS_SNAPSHOT_NAME:-pre-upgrade-$stamp}
  [ -n "${BTRFS_SUBVOLUME:-}" ] || die "BTRFS_SUBVOLUME is required for SNAPSHOT_METHOD=btrfs."
  [ -n "${BTRFS_SNAPSHOT_DIR:-}" ] || die "BTRFS_SNAPSHOT_DIR is required."
  if [ "${SNAPSHOT_DRY_RUN:-0}" != 1 ]; then
    command -v btrfs >/dev/null 2>&1 || die "btrfs command not found; is btrfs-progs installed?"
    [ -d "$BTRFS_SUBVOLUME" ] || die "BTRFS_SUBVOLUME '$BTRFS_SUBVOLUME' is not a directory."
    [ -d "$BTRFS_SNAPSHOT_DIR" ] || die "BTRFS_SNAPSHOT_DIR '$BTRFS_SNAPSHOT_DIR' does not exist."
  fi
  echo "pre-upgrade-snapshot: btrfs read-only snapshot of $BTRFS_SUBVOLUME at $BTRFS_SNAPSHOT_DIR/$name"
  run btrfs subvolume snapshot -r "$BTRFS_SUBVOLUME" "$BTRFS_SNAPSHOT_DIR/$name"
}

main() {
  case "${SNAPSHOT_METHOD:-}" in
    lvm)   snapshot_lvm ;;
    btrfs) snapshot_btrfs ;;
    "")    die "SNAPSHOT_METHOD is required (lvm or btrfs)." ;;
    *)     die "Unknown SNAPSHOT_METHOD '$SNAPSHOT_METHOD' (expected lvm or btrfs)." ;;
  esac
}

# Allow sourcing for tests without taking a snapshot.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
