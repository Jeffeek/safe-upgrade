#!/usr/bin/env bash
#
# safe-upgrade.sh - guarded full system upgrade for Debian/Ubuntu
#
# This script reduces common upgrade risks; it cannot make APT simulation and
# execution atomic, provide rollback by itself, or protect against power loss.
#
# LIMITATION: APT has no primitive to simulate, validate against a custom policy,
# and execute that exact plan atomically. This script re-simulates immediately
# before the real transaction to shrink, but not eliminate, the race: another
# APT process or a repository change between the final simulation and the real
# upgrade can still alter the plan. A tested filesystem/VM snapshot hook
# (PRE_UPGRADE_HOOK) is therefore strongly recommended, not merely optional.
#
# Run under a systemd oneshot timer for unattended maintenance. Give the unit a
# generous TimeoutStopSec; the script traps HUP/INT/TERM but cannot guarantee a
# clean shutdown mid-dpkg. Only trusted administrators may set the command
# hooks or other environment overrides when invoking this root-privileged script.
#
# Optional tools: --flatpak requires the 'flatpak' package and --snap requires
# 'snapd'. Neither is part of a default Debian install (snapd is default on
# Ubuntu only). Their presence is verified up front, before any package change;
# if a requested tool is missing the run aborts with a clear message.
#
# Rollback point: PRE_UPGRADE_HOOK runs lazily, immediately before the FIRST
# system mutation (dpkg repair, full-upgrade, autoremove, flatpak, snap). A run
# that finds nothing to do therefore does not create a snapshot.
#
# Note on NEEDRESTART_MODE: the default is 'a' (services are auto-restarted
# during the upgrade). This interacts with POST_UPGRADE_SERVICES checks and with
# your reboot policy; it is the intended behaviour for unattended upgrades. Set
# NEEDRESTART_MODE=l (list only) to disable automatic restarts.
#
# Environment overrides (all optional; configure only from trusted root-owned
# service/configuration files):
#   MAX_REMOVALS       max packages full-upgrade may remove (default 5)
#   MAX_AUTOREMOVALS   max packages autoremove may remove (default 15)
#   PROTECTED_PKGS     space-separated package names/glob patterns that must
#                      never be removed; built-in essential/protected, held,
#                      and running-kernel owner packages are protected
#                      independently and fail closed. Architecture qualifiers
#                      (:amd64 etc.) are stripped from patterns and package
#                      names, so the bare name protects every architecture.
#   MIN_FREE_MB        required free space on / and /var (default 1024)
#   MIN_BOOT_MB        required free space on /boot (default 150; increase to
#                      ~300 on small /boot partitions or if several kernels
#                      will coexist before rebooting)
#   PRE_UPGRADE_HOOK   trusted root command run before package changes. Use a
#                      real, tested rollback point; this script does not roll back.
#   PRE_UPGRADE_TIMEOUT  seconds (1..86400) before PRE_UPGRADE_HOOK is killed
#                      (default 600)
#   NOTIFY_CMD         trusted root command run on failure (and, depending on
#                      NOTIFY_ON, in other cases). Receives STATUS, EXIT_CODE,
#                      LOG_FILE, HOST, DRIFT_COUNT and REBOOT_PENDING in its
#                      environment.
#   NOTIFY_ON          fail (default) | always | attention. 'attention' notifies
#                      on failure, when vendor config files were saved next to
#                      kept configuration (config drift), or when a reboot is
#                      required but was not scheduled.
#   POST_UPGRADE_SERVICES  space-separated systemd unit names checked after
#                      package updates. A unit is flagged when it is 'failed',
#                      stuck in an auto-restart loop, or expected to be active
#                      (i.e. not a oneshot without RemainAfterExit) but is not.
#                      Unknown units are also flagged.
#   POST_UPGRADE_SETTLE_SECONDS  wait before service checks (default 5)
#   REBOOT_MIN_INTERVAL  minimum seconds between automatic reboots and minimum
#                      uptime before one is allowed (default 3600). Protects
#                      against reboot loops. 0 disables the protection.
#   NEEDRESTART_MODE   a (default) or l; see above.
#
# apt-get must be >= 1.9.11 for DPkg::Lock::Timeout. Newer APT versions support
# --error-on=any; the script probes this option directly (not via --help).
# Use release codenames in APT sources, not "stable", to avoid an accidental
# distribution upgrade.
#
# Contention: unattended-upgrades and apt-daily may hold locks concurrently.
# DPkg::Lock::Timeout waits for the dpkg lock, but the lists lock is not fully
# covered; 'apt-get update' is retried instead. If you schedule this script,
# mask or order the competing systemd units. Configuration/version errors are
# reported through NOTIFY_CMD; usage and non-root errors are not (they occur
# before notification is armed).
#
# Example logrotate config (/etc/logrotate.d/safe-upgrade):
#   /var/log/safe-upgrade.log { monthly rotate 6 compress missingok notifempty }
#
# Recommended scheduling: systemd oneshot service + persistent timer, so missed
# runs can catch up after downtime. A cron example is possible, but cron does not
# catch up missed schedules and does not provide a dedicated service cgroup.

set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

# ---------- configuration ----------
LOG_FILE=/var/log/safe-upgrade.log
STATE_DIR=/var/lib/safe-upgrade
LOCK_FILE=/run/safe-upgrade.lock
BOOT_DIR=/boot
REBOOT_FLAG=/run/reboot-required
MODULES_DIR=/lib/modules
MAX_REMOVALS="${MAX_REMOVALS-5}"
MAX_AUTOREMOVALS="${MAX_AUTOREMOVALS-15}"
PROTECTED_PKGS="${PROTECTED_PKGS-openssh-server sudo systemd ufw network-manager netplan.io}"
MIN_FREE_MB="${MIN_FREE_MB-1024}"
MIN_BOOT_MB="${MIN_BOOT_MB-150}"
PRE_UPGRADE_HOOK="${PRE_UPGRADE_HOOK-}"
PRE_UPGRADE_TIMEOUT="${PRE_UPGRADE_TIMEOUT-600}"
NOTIFY_CMD="${NOTIFY_CMD-}"
NOTIFY_ON="${NOTIFY_ON-fail}"
POST_UPGRADE_SERVICES="${POST_UPGRADE_SERVICES-}"
POST_UPGRADE_SETTLE_SECONDS="${POST_UPGRADE_SETTLE_SECONDS-5}"
REBOOT_MIN_INTERVAL="${REBOOT_MIN_INTERVAL-3600}"
NEEDRESTART_MODE="${NEEDRESTART_MODE-a}"
APT_LOCK_TIMEOUT=300
LOCK_STALE_SECONDS=21600
UPDATE_ATTEMPTS=3
UPDATE_RETRY_DELAY=45

DRY_RUN=0
REBOOT_MODE=auto
DO_FLATPAK=0
DO_SNAP=0
DO_CLEAN=0
FAILED=0
NOTIFY_ARMED=0
INHIBIT_OK=""
BOOT_READONLY=0
mutated=0
marker=""
before=""
after=""
run_status=""
tee_pid=""
logging_enabled=0
drift_count=0
reboot_pending=0
partial_inventory=0
declare -a PROTECTED_EFFECTIVE=()

# ---------- helpers ----------
log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}"; }
info() { log INFO "$@"; }
warn() { log WARN "$@" >&2; }
die()  { log ERROR "$@" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sudo safe-upgrade.sh [options]

  --dry-run    Refresh APT package lists and simulate the upgrade. It installs
               and removes nothing, but DOES write /var/lib/apt/lists and takes
               a transient lock. It does not write this script's log/state files.
  --reboot     If a reboot is needed and no step failed, schedule one in 1 minute
               (cancel with `shutdown -c`). Suppressed if the last automatic
               reboot, or the current boot, is younger than REBOOT_MIN_INTERVAL.
  --no-reboot  Never reboot automatically.
  --flatpak    Also update the system/root Flatpak installation. Requires the
               'flatpak' package (checked up front; not installed by default).
  --snap       Also refresh Snap packages. Requires 'snapd' (checked up front).
  --clean      Run guarded apt-get autoclean afterwards.
  -h, --help   Show this help.

Environment variables and security notes are documented at the top of the script.
Only trusted administrators should control environment overrides or invoke this
root-privileged script with custom PRE_UPGRADE_HOOK / NOTIFY_CMD values.
EOF
}

safe_path() {
  local path=$1
  [ ! -L "$path" ] || die "Refusing symlink at privileged path: $path"
}

check_owned_root_path() {
  local path=$1 owner
  safe_path "$path"
  if [ -e "$path" ]; then
    owner=$(stat -c '%u' -- "$path") || die "Cannot inspect ownership of $path"
    [ "$owner" -eq 0 ] || die "$path must be owned by root."
  fi
}

validate_uint() { # variable_name maximum
  local name=$1 maximum=$2 value=${!1} normalized
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer (got '$value')."
  [ "${#value}" -le 9 ] || die "$name is too large."
  normalized=$((10#$value))
  [ "$normalized" -le "$maximum" ] || die "$name must not exceed $maximum."
  printf -v "$name" '%d' "$normalized"
}

# Run a command with umask 022 so apt/dpkg hooks, flatpak, snap and the like do
# not inherit this script's restrictive umask 077 (which could leave root-only
# files in shared locations). Also closes fd 9 so the flock is never leaked into
# the child process tree.
with_clean_umask() {
  local old_umask rc=0
  old_umask=$(umask)
  umask 022
  "$@" 9>&- || rc=$?
  umask "$old_umask"
  return "$rc"
}

write_package_snapshot() {
  local target=$1
  # Only fully installed ('ii') packages, so config-files ('rc') leftovers are
  # not mistaken for still-present packages.
  dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n' \
    | awk -F'\t' '$1 ~ /^ii/ {print $2"\t"$3}' | sort > "$target"
}

run_notify() { # status_text exit_code
  local -a runner=()
  if command -v timeout >/dev/null 2>&1; then
    runner=(timeout -k 5s 30s)
  fi
  env STATUS="$1" EXIT_CODE="$2" LOG_FILE="$LOG_FILE" \
      HOST="$(hostname 2>/dev/null || echo unknown)" \
      DRIFT_COUNT="$drift_count" REBOOT_PENDING="$reboot_pending" \
      "${runner[@]+"${runner[@]}"}" bash -o pipefail -ec "$NOTIFY_CMD" 9>&-
}

on_exit() {
  local rc=$? status_text=failed waited=0 max_ticks=60 tee_hung=0 notify_wanted=0
  trap - EXIT ERR
  # We are exiting; a failure in cleanup must not mask the caller's exit code.
  set +e

  # Complete the package inventory on ordinary failures where possible. A SIGKILL
  # or power loss cannot run this handler; the next invocation detects stale state.
  if [ -n "$before" ] && [ -f "$before" ] && [ -n "$after" ] && [ ! -e "$after" ]; then
    if write_package_snapshot "$after.partial" 2>/dev/null \
       && mv -f -- "$after.partial" "$after" 2>/dev/null; then
      partial_inventory=1
    else
      rm -f -- "$after.partial" 2>/dev/null
    fi
  fi
  if [ "$partial_inventory" -eq 1 ]; then
    warn "Run ended before normal completion; captured a best-effort final package inventory."
  fi

  if [ -n "$run_status" ]; then
    if [ "$rc" -eq 0 ]; then
      printf 'success %s\n' "$(date +%s)" > "$run_status.tmp" 2>/dev/null \
        && mv -f -- "$run_status.tmp" "$run_status" 2>/dev/null
    else
      printf 'failed:%s %s\n' "$rc" "$(date +%s)" > "$run_status.tmp" 2>/dev/null \
        && mv -f -- "$run_status.tmp" "$run_status" 2>/dev/null
    fi
  fi
  if [ -n "$marker" ]; then rm -f -- "$marker" 2>/dev/null; fi

  # Close the tee pipe and wait (bounded, ~30s) for its final writes. If some
  # orphaned process still holds the write end, tee never sees EOF; do not hang.
  if [ "$logging_enabled" -eq 1 ]; then
    exec 1>&- 2>&-
    if [ -n "$tee_pid" ]; then
      while [ "$waited" -lt "$max_ticks" ] && kill -0 "$tee_pid" 2>/dev/null; do
        sleep 0.5
        waited=$((waited + 1))
      done
      if kill -0 "$tee_pid" 2>/dev/null; then
        tee_hung=1
        kill -TERM "$tee_pid" 2>/dev/null
        sleep 1
        kill -KILL "$tee_pid" 2>/dev/null
      fi
      wait "$tee_pid" 2>/dev/null
    fi
    exec 1>&3 2>&4
  fi
  if [ "$tee_hung" -eq 1 ]; then
    warn "Log writer did not exit within 30s (an orphaned process holds the log pipe); it was terminated."
  fi

  if [ "$NOTIFY_ARMED" -eq 1 ] && [ -n "$NOTIFY_CMD" ] && [ "$DRY_RUN" -eq 0 ]; then
    if [ "$rc" -ne 0 ]; then
      notify_wanted=1
    elif [ "$NOTIFY_ON" = always ]; then
      notify_wanted=1
    elif [ "$NOTIFY_ON" = attention ] \
         && { [ "$drift_count" -gt 0 ] || [ "$reboot_pending" -eq 1 ]; }; then
      notify_wanted=1
    fi
    if [ "$notify_wanted" -eq 1 ]; then
      [ "$rc" -eq 0 ] && status_text=ok
      run_notify "$status_text" "$rc" || {
        printf '%s [WARN] NOTIFY_CMD failed or timed out (upgrade exit code remains %s).\n' \
          "$(date '+%F %T')" "$rc" >&2
      }
    fi
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'rc=$?; log ERROR "Failed at line $LINENO (exit $rc). See $LOG_FILE" >&2' ERR

# Behave reasonably on signals: exit with the conventional status so the EXIT
# trap runs and the run-status file is finalised. Bash defers trap handlers
# until the current foreground command ends; under systemd the whole cgroup
# receives the signal, so apt/dpkg are told to stop as well.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------- APT/system helpers ----------
apt_version_check() {
  local version
  version=$(apt-get --version | sed -n '1s/^apt \([^ ]*\).*/\1/p')
  [ -n "$version" ] || die "Could not determine APT version."
  dpkg --compare-versions "$version" ge 1.9.11 \
    || die "APT $version is too old; this script requires apt >= 1.9.11 for lock timeouts."
}

can_inhibit() {
  if [ -z "$INHIBIT_OK" ]; then
    # Probe the exact inhibition set used by run_apt. Containers/chroots may not
    # have a working logind; in that case continue without inhibition.
    if command -v systemd-inhibit >/dev/null 2>&1 && [ -d /run/systemd/system ] \
       && systemd-inhibit --what=shutdown:sleep --who=safe-upgrade --why=probe true 9>&- 2>/dev/null; then
      INHIBIT_OK=yes
    else
      INHIBIT_OK=no
    fi
  fi
  [ "$INHIBIT_OK" = yes ]
}

run_apt() {
  if can_inhibit; then
    with_clean_umask systemd-inhibit --what=shutdown:sleep --who=safe-upgrade \
      --why="Package operation in progress" apt-get "$@"
  else
    with_clean_umask apt-get "$@"
  fi
}

_report_boot_space_recovery() {
  warn "Free space on $BOOT_DIR is insufficient. Candidate kernels on disk:"
  find "$BOOT_DIR" -maxdepth 1 -type f -name 'vmlinuz-*' -printf '    %f\n' 2>/dev/null >&2 || true
  warn "Installed linux-image packages (newest first):"
  dpkg-query -W -f='${binary:Package}\t${Version}\n' 'linux-image-*' 2>/dev/null \
    | sort -k2 -V -r | head -n 10 | sed 's/^/    /' >&2 || true
  warn "To free space manually, purge an OLD kernel package (and matching modules), e.g.:"
  warn "  apt-get --purge remove linux-image-<old-version> linux-modules-<old-version>"
  warn "Do NOT remove the running kernel: $(uname -r)"
  warn "Then re-run this script."
}

check_space() { # path minimum_mb
  local mp=$1 min=$2 free inode_total inode_free options

  if [ ! -d "$mp" ]; then
    if [ "$mp" = "$BOOT_DIR" ]; then
      info "$mp is not present (container or non-standard layout); skipping that check."
      return 0
    fi
    die "Required path does not exist: $mp"
  fi

  # If fstab declares this exact mountpoint, refuse to inspect the underlying
  # filesystem when that mount is absent.
  if command -v findmnt >/dev/null 2>&1 && findmnt --fstab --mountpoint "$mp" >/dev/null 2>&1; then
    mountpoint -q "$mp" || die "$mp is configured as a mountpoint but is not mounted."
  fi

  if [ "$mp" = "$BOOT_DIR" ] && command -v mountpoint >/dev/null 2>&1 \
     && ! mountpoint -q "$mp" 2>/dev/null; then
    info "$mp is not a separate mount; checking the containing filesystem instead."
  fi

  if command -v findmnt >/dev/null 2>&1; then
    options=$(findmnt -no OPTIONS -T "$mp" 2>/dev/null) || die "Cannot determine filesystem options for $mp."
    if [[ ",$options," == *,ro,* ]]; then
      if [ "$mp" = "$BOOT_DIR" ]; then
        # Not fatal by itself: only upgrades that write to /boot are blocked
        # (see boot_plan_ok). Space cannot be meaningfully checked here.
        BOOT_READONLY=1
        warn "$mp is mounted read-only; upgrades that write boot files will be refused."
        return 0
      fi
      die "Filesystem containing $mp is mounted read-only."
    fi
  fi

  free=$(df -Pm -- "$mp" 2>/dev/null | awk 'NR==2 {print $4}')
  [[ "$free" =~ ^[0-9]+$ ]] || die "Cannot determine free space for $mp."
  if [ "$free" -lt "$min" ]; then
    if [ "$mp" = "$BOOT_DIR" ]; then _report_boot_space_recovery; fi
    die "Only ${free}MB free on $mp (need ${min}MB)."
  fi

  # btrfs (and some other filesystems) report 0 inodes; treat that as N/A.
  inode_total=$(df -Pi -- "$mp" 2>/dev/null | awk 'NR==2 {print $2}')
  if [[ "$inode_total" =~ ^[0-9]+$ ]] && [ "$inode_total" -gt 0 ]; then
    inode_free=$(df -Pi -- "$mp" 2>/dev/null | awk 'NR==2 {print $4}')
    [[ "$inode_free" =~ ^[0-9]+$ ]] || die "Cannot determine free inodes for $mp."
    [ "$inode_free" -gt 0 ] || die "No free inodes on filesystem containing $mp."
  fi
}

check_all_space() {
  check_space /            "$MIN_FREE_MB"
  check_space /var         "$MIN_FREE_MB"
  check_space "$BOOT_DIR"  "$MIN_BOOT_MB"
}

# With a read-only /boot, refuse plans that install/remove boot-related
# packages, which would otherwise fail halfway and leave a half-configured kernel.
boot_plan_ok() { # simulation_output
  [ "$BOOT_READONLY" -eq 1 ] || return 0
  if grep -Eq '^(Inst|Remv|Purg) (linux-image|initramfs-tools|grub|shim|systemd-boot|flash-kernel|u-boot)' <<<"$1"; then
    return 1
  fi
  return 0
}

# Architecture qualifiers are ignored on both sides: apt prints native packages
# unqualified while dpkg/apt-mark print ':amd64'.
matches_package_pattern() { # package_name pattern
  local name=${1%%:*} pattern=${2%%:*}
  case "$pattern" in
    *'*'*|*'?'*|*'['*)
      # shellcheck disable=SC2053 # unquoted on purpose: glob match
      [[ "$name" == $pattern ]] ;;
    *) [[ "$name" == "$pattern" ]] ;;
  esac
}

build_protected_patterns() {
  local held_line package essential protected running_kernel metadata owner
  local -a configured=()
  PROTECTED_EFFECTIVE=()

  read -ra configured <<<"$PROTECTED_PKGS"
  for package in "${configured[@]+"${configured[@]}"}"; do
    PROTECTED_EFFECTIVE+=("${package%%:*}")
  done

  # Held packages (best effort; held packages are not removed by APT normally,
  # but some maintainer scenarios can bypass this).
  if held_line=$(apt-mark showhold 2>/dev/null); then
    while IFS= read -r package; do
      if [ -n "$package" ]; then
        PROTECTED_EFFECTIVE+=("${package%%:*}")
      fi
    done <<<"$held_line"
  else
    warn "Could not read held packages; continuing with configured protections only."
  fi

  # Essential/Protected metadata: fail closed. Some dpkg builds lack the
  # ${Protected} field; fall back to ${Essential}-only rather than skipping.
  if metadata=$(dpkg-query -W -f='${binary:Package}\t${Essential}\t${Protected}\n' 2>/dev/null); then
    while IFS=$'\t' read -r package essential protected; do
      if [ -n "$package" ] && { [ "$essential" = yes ] || [ "$protected" = yes ]; }; then
        PROTECTED_EFFECTIVE+=("${package%%:*}")
      fi
    done <<<"$metadata"
  elif metadata=$(dpkg-query -W -f='${binary:Package}\t${Essential}\n' 2>/dev/null); then
    warn "dpkg does not expose \${Protected}; falling back to \${Essential} only for removal protection."
    while IFS=$'\t' read -r package essential; do
      if [ -n "$package" ] && [ "$essential" = yes ]; then
        PROTECTED_EFFECTIVE+=("${package%%:*}")
      fi
    done <<<"$metadata"
  else
    warn "Cannot read installed-package safety metadata from dpkg; refusing to proceed without Essential/Protected removal guards."
    return 1
  fi

  # Running kernel: resolve the actual owning packages from disk rather than
  # relying on naming conventions. Conventional names are added as a safety net.
  running_kernel=$(uname -r)
  while IFS= read -r owner; do
    if [ -n "$owner" ]; then
      PROTECTED_EFFECTIVE+=("${owner%%:*}")
    fi
  done < <(
    {
      dpkg-query -S "$BOOT_DIR/vmlinuz-$running_kernel" 2>/dev/null || true
      dpkg-query -S "/lib/modules/$running_kernel" 2>/dev/null || true
    } | awk -F': ' '{n=split($1,a,/, */); for(i=1;i<=n;i++) print a[i]}'
  )
  PROTECTED_EFFECTIVE+=(
    "linux-image-$running_kernel"
    "linux-image-unsigned-$running_kernel"
    "linux-modules-$running_kernel"
    "linux-modules-extra-$running_kernel"
  )
}

guard_removals() { # label simulation_output limit
  local label=$1 sim=$2 limit=$3 list count records blocked=0 name p
  local -a pats=()

  if ! build_protected_patterns; then
    warn "$label: cannot build a trustworthy protection set; failing closed."
    return 1
  fi
  pats=("${PROTECTED_EFFECTIVE[@]+"${PROTECTED_EFFECTIVE[@]}"}")

  # Fail closed on unrecognized / malformed removal records.
  if grep -Eq '^(Remv|Purg)([^[:space:]]|[[:space:]]*$)' <<<"$sim"; then
    warn "$label simulation contains an unrecognized removal record."
    return 1
  fi
  list=$(awk '($1 == "Remv" || $1 == "Purg") && NF >= 2 {print $2}' <<<"$sim")
  count=$(awk '($1 == "Remv" || $1 == "Purg") && NF >= 2 {n++} END {print n+0}' <<<"$sim")
  records=$(grep -Ec '^(Remv|Purg) ' <<<"$sim" || true)
  if grep -qi 'will be REMOVED' <<<"$sim" && [ "$count" -eq 0 ]; then
    warn "$label simulation announced removals but no parseable package records were found."
    return 1
  fi
  if [ "$records" -ne "$count" ]; then
    warn "$label simulation has malformed removal records."
    return 1
  fi

  if [ "$count" -gt 0 ]; then
    warn "$label would remove $count package(s):"
    # shellcheck disable=SC2001 # per-line indent; sed is clearer here
    sed 's/^/    /' <<<"$list" >&2
  fi
  if [ "$count" -gt "$limit" ]; then
    warn "$label: removal count $count exceeds limit $limit"
    blocked=1
  fi

  while IFS= read -r name; do
    if [ -n "$name" ]; then
      for p in "${pats[@]+"${pats[@]}"}"; do
        if matches_package_pattern "$name" "$p"; then
          warn "$label would remove protected package: $name (matches '$p')"
          blocked=1
        fi
      done
    fi
  done <<<"$list"
  return "$blocked"
}

# Fallback reboot detection for kernels whose release string is not
# Debian-style (Raspberry Pi OS, custom kernels). Every kernel package populates
# /lib/modules/<release>, so a newer directory with the same suffix as the
# running release (e.g. "+rpt-rpi-v8") means a newer kernel is installed. This
# also covers packages that replace the running kernel's directory in place.
needs_reboot_by_modules() { # running_release
  local running=$1 prefix suffix f name base newest candidates=""
  prefix=${running%%[!0-9.]*}
  [ -n "$prefix" ] || return 1
  suffix=${running#"$prefix"}
  [ -n "$suffix" ] || return 1
  [ -d "$MODULES_DIR" ] || return 1

  for f in "$MODULES_DIR"/*; do
    [ -d "$f" ] || continue
    name=${f##*/}
    [[ "$name" == [0-9]*"$suffix" ]] || continue
    base=${name%"$suffix"}
    if [[ "$base" =~ ^[0-9][0-9.]*$ ]]; then
      candidates+="$name"$'\n'
    fi
  done
  [ -n "$candidates" ] || return 1

  newest=$(printf '%s' "$candidates" | sort -V | tail -n1)
  [ -n "$newest" ] || return 1
  [ "$newest" != "$running" ] || return 1
  [ "$(printf '%s\n%s\n' "$running" "$newest" | sort -V | tail -n1)" = "$newest" ]
}

# Return success when a reboot is needed. Kernels are only compared within the
# running kernel's flavor (so coexisting -generic/-lowlatency or
# amd64/cloud-amd64 kernels do not cause false positives), and a newer kernel
# without an initramfs (when the running one has one) is not considered bootable.
needs_reboot() {
  local running flavor f name base newest candidates=""
  [ -f "$REBOOT_FLAG" ] && return 0
  running=$(uname -r)
  if ! [[ "$running" =~ ^[0-9][0-9.]*-[0-9]+-(.+)$ ]]; then
    # Not a Debian/Ubuntu-style release string (for example Raspberry Pi OS:
    # 6.6.51+rpt-rpi-v8); fall back to the installed module directories.
    needs_reboot_by_modules "$running"
    return
  fi
  flavor=${BASH_REMATCH[1]}

  for f in "$BOOT_DIR"/vmlinuz-*; do
    [ -e "$f" ] || continue
    name=${f##*/vmlinuz-}
    if [[ "$name" == *"-$flavor" ]]; then
      base=${name%"-$flavor"}
      if [[ "$base" =~ ^[0-9][0-9.]*-[0-9]+$ ]]; then
        candidates+="$name"$'\n'
      fi
    fi
  done
  [ -n "$candidates" ] || return 1

  newest=$(printf '%s' "$candidates" | sort -V | tail -n1)
  [ -n "$newest" ] || return 1
  [ "$newest" != "$running" ] || return 1
  # Newest must actually be newer than running (not merely different).
  [ "$(printf '%s\n%s\n' "$running" "$newest" | sort -V | tail -n1)" = "$newest" ] || return 1
  if [ -e "$BOOT_DIR/initrd.img-$running" ] && [ ! -e "$BOOT_DIR/initrd.img-$newest" ]; then
    return 1
  fi
  return 0
}

# Reboot-loop protection: refuse when the machine booted recently or the last
# automatic reboot was recent. An unparseable state file also refuses (fail closed).
reboot_allowed_by_interval() {
  local file="$STATE_DIR/last-auto-reboot" last="" now age uptime_s
  [ "$REBOOT_MIN_INTERVAL" -gt 0 ] || return 0

  if [ -r /proc/uptime ]; then
    uptime_s=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "")
    if [[ "$uptime_s" =~ ^[0-9]+$ ]] && [ "$uptime_s" -lt "$REBOOT_MIN_INTERVAL" ]; then
      warn "System booted only ${uptime_s}s ago (< REBOOT_MIN_INTERVAL=${REBOOT_MIN_INTERVAL}s); not rebooting again automatically."
      return 1
    fi
  fi

  [ -f "$file" ] || return 0
  IFS= read -r last < "$file" || last=""
  if ! [[ "$last" =~ ^[0-9]{1,12}$ ]]; then
    warn "Cannot parse $file; refusing automatic reboot. Delete the file to re-enable."
    return 1
  fi
  now=$(date +%s)
  age=$(( now - 10#$last ))
  if [ "$age" -lt "$REBOOT_MIN_INTERVAL" ]; then
    warn "Last automatic reboot was ${age}s ago (< REBOOT_MIN_INTERVAL=${REBOOT_MIN_INTERVAL}s); not rebooting again automatically."
    return 1
  fi
  return 0
}

record_auto_reboot() {
  local file="$STATE_DIR/last-auto-reboot"
  if printf '%s\n' "$(date +%s)" > "$file.tmp" && mv -f -- "$file.tmp" "$file"; then
    :
  else
    warn "Could not record the automatic-reboot timestamp in $file."
  fi
}

# Probe --error-on directly: it is not listed by --help and, in current APT, is
# accepted only as an option of the 'update' command. The probe runs a real
# 'apt-get update' against an EMPTY source list and a private lists directory,
# so it touches nothing; an unknown option makes apt-get exit 100 immediately.
apt_supports_error_on() {
  local tmp rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/safe-upgrade-probe.XXXXXX") || return 1
  mkdir -p -- "$tmp/lists" "$tmp/parts"
  apt-get update --error-on=any \
    -o Dir::Etc::sourcelist=/dev/null \
    -o Dir::Etc::sourceparts="$tmp/parts" \
    -o Dir::State::Lists="$tmp/lists" >/dev/null 2>&1 9>&- || rc=$?
  rm -rf -- "$tmp"
  return "$rc"
}

refresh_package_lists() {
  local attempt use_error_on_any=0 rc output_file
  local -a update_opts=(
    -o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT"
    -o Acquire::Retries=2
    -o Acquire::http::Timeout=30
    -o Acquire::https::Timeout=30
  )
  if apt_supports_error_on; then
    use_error_on_any=1
    update_opts=(--error-on=any "${update_opts[@]}")
  fi

  output_file=$(mktemp "${TMPDIR:-/tmp}/safe-upgrade-update.XXXXXX") \
    || die "Cannot create a temp file for apt-get update output."

  for ((attempt=1; attempt<=UPDATE_ATTEMPTS; attempt++)); do
    info "Refreshing package lists (attempt $attempt/$UPDATE_ATTEMPTS)"
    : > "$output_file"
    if run_apt update "${update_opts[@]}" 2>&1 | tee "$output_file"; then
      rc=0
    else
      rc=1
    fi
    # Older APT may exit zero after partial index failures; detect those explicitly.
    if grep -Eqi '(^Err:|Failed to fetch|Some index files failed to download|The repository .* does not have a Release file)' "$output_file"; then
      rc=1
    fi
    if [ "$rc" -eq 0 ]; then
      rm -f -- "$output_file"
      return 0
    fi
    if [ "$attempt" -lt "$UPDATE_ATTEMPTS" ]; then
      warn "APT package-list refresh failed; retrying in ${UPDATE_RETRY_DELAY}s."
      sleep "$UPDATE_RETRY_DELAY"
    fi
  done
  rm -f -- "$output_file"
  [ "$use_error_on_any" -eq 1 ] || true
  die "apt-get update failed after $UPDATE_ATTEMPTS attempts."
}

report_package_changes() {
  local old=$1 new=$2
  awk -F '\t' '
    FNR == NR { before[$1] = $2; next }
    { after[$1] = $2 }
    END {
      for (p in before) {
        if (!(p in after)) removed++
        else if (before[p] != after[p]) upgraded++
      }
      for (p in after) if (!(p in before)) installed++
      printf "Package changes: %d installed, %d upgraded/reconfigured by version, %d removed.\n", installed, upgraded, removed
    }
  ' "$old" "$new"
}

check_previous_runs() {
  local f content unresolved=0 unresolved_list=""
  local -a files=()
  shopt -s nullglob
  files=( "$STATE_DIR"/run-*.status )
  shopt -u nullglob
  for f in "${files[@]+"${files[@]}"}"; do
    content=""
    IFS= read -r content < "$f" || content=""
    if [[ -z "$content" ]] || [[ "$content" == running* ]]; then
      warn "Found an unresolved prior run record: $f ($content)"
      unresolved=1
      unresolved_list+="$f "
    fi
  done
  [ "$unresolved" -eq 0 ] || die "An earlier run appears to have been interrupted. \
Review: ${unresolved_list% }. Run 'dpkg --audit' and 'apt-get check', then delete \
the stale run-*.status file(s) in $STATE_DIR once you have verified system state."
}

rotate_state() {
  local f
  local -a snapshots=() statuses=()
  shopt -s nullglob
  snapshots=( "$STATE_DIR"/packages-*.before )
  statuses=(  "$STATE_DIR"/run-*.status )
  shopt -u nullglob

  # Retain the 20 newest completed snapshot pairs. Never delete incomplete evidence.
  if [ "${#snapshots[@]}" -gt 20 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "${f%.before}.after" ] || continue
      rm -f -- "$f" "${f%.before}.after"
    done < <(printf '%s\n' "${snapshots[@]}" | sort | head -n "$(( ${#snapshots[@]} - 20 ))")
  fi

  # Retain the 20 newest run-status files (the current run is the newest and
  # therefore never selected for deletion).
  if [ "${#statuses[@]}" -gt 20 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rm -f -- "$f" "${f}.tmp"
    done < <(printf '%s\n' "${statuses[@]}" | sort | head -n "$(( ${#statuses[@]} - 20 ))")
  fi

  # Sweep orphaned temporary files and stale markers.
  find "$STATE_DIR" -maxdepth 1 \( -name '*.tmp' -o -name '*.partial' \) -mmin +60 -delete 2>/dev/null || true
  find "$STATE_DIR" -maxdepth 1 -name 'marker-*' -mmin +1440 -delete 2>/dev/null || true
}

# Called before the FIRST mutation of the system. Idempotent. Runs the rollback
# hook, then records the package inventory and the in-progress run record, so a
# run that has nothing to do leaves no snapshot behind.
begin_mutation() {
  local stamp
  [ "$mutated" -eq 0 ] || return 0

  if [ -n "$PRE_UPGRADE_HOOK" ]; then
    info "Running pre-upgrade hook (timeout ${PRE_UPGRADE_TIMEOUT}s)"
    if command -v timeout >/dev/null 2>&1; then
      with_clean_umask timeout -k 10s "${PRE_UPGRADE_TIMEOUT}s" bash -o pipefail -ec "$PRE_UPGRADE_HOOK" \
        || die "PRE_UPGRADE_HOOK failed or timed out after ${PRE_UPGRADE_TIMEOUT}s; aborting before package changes."
    else
      with_clean_umask bash -o pipefail -ec "$PRE_UPGRADE_HOOK" \
        || die "PRE_UPGRADE_HOOK failed; aborting before package changes."
    fi
  fi

  stamp=$(date +%Y%m%d-%H%M%S)-$$
  before="$STATE_DIR/packages-$stamp.before"
  after="$STATE_DIR/packages-$stamp.after"
  marker="$STATE_DIR/marker-$stamp"
  run_status="$STATE_DIR/run-$stamp.status"
  printf 'running pid=%s started=%s\n' "$$" "$(date +%s)" > "$run_status"
  chmod 0640 "$run_status"
  write_package_snapshot "$before"
  touch "$marker"
  rotate_state
  mutated=1
}

# Returns 0 when the unit is healthy. Reads key=value output from systemctl so
# the order of properties does not matter.
unit_is_healthy() { # unit
  local unit=$1 type="" rae="" active="" sub="" key val tries=0
  while :; do
    type="" rae="" active="" sub=""
    while IFS='=' read -r key val; do
      case "$key" in
        Type)            type=$val ;;
        RemainAfterExit) rae=$val ;;
        ActiveState)     active=$val ;;
        SubState)        sub=$val ;;
      esac
    done < <(systemctl show -p Type -p RemainAfterExit -p ActiveState -p SubState "$unit" 2>/dev/null)
    # A unit that is genuinely starting gets up to 30s; a restart loop does not.
    if [ "$active" = activating ] && [ "$sub" != auto-restart ] && [ "$tries" -lt 15 ]; then
      tries=$((tries + 1))
      sleep 2
      continue
    fi
    break
  done

  case "$active" in
    active|reloading)
      return 0 ;;
    failed)
      warn "Post-upgrade service is in failed state: $unit"
      return 1 ;;
    activating)
      warn "Post-upgrade service is not stable (state: $active/$sub): $unit"
      return 1 ;;
    *)
      # Oneshot units without RemainAfterExit are normally 'inactive' on success.
      if [ "$type" = oneshot ] && [ "$rae" != yes ]; then
        return 0
      fi
      warn "Post-upgrade service is not active (state: ${active:-unknown}/${sub:-unknown}): $unit"
      return 1 ;;
  esac
}

check_post_upgrade_services() {
  local service
  local -a service_list=()
  [ -n "$POST_UPGRADE_SERVICES" ] || return 0

  if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    warn "POST_UPGRADE_SERVICES is set but systemd is not running; cannot check services."
    FAILED=1
    return 0
  fi
  if [ "$POST_UPGRADE_SETTLE_SECONDS" -gt 0 ]; then
    info "Waiting ${POST_UPGRADE_SETTLE_SECONDS}s before checking services"
    sleep "$POST_UPGRADE_SETTLE_SECONDS"
  fi
  read -ra service_list <<<"$POST_UPGRADE_SERVICES"
  for service in "${service_list[@]+"${service_list[@]}"}"; do
    if ! systemctl cat "$service" >/dev/null 2>&1; then
      warn "POST_UPGRADE_SERVICES references unknown unit: $service"
      FAILED=1
      continue
    fi
    if ! unit_is_healthy "$service"; then
      FAILED=1
    fi
  done
}

handle_reboot() {
  local do_reboot=0 reply=N
  reboot_pending=0
  if ! needs_reboot; then
    info "No reboot required."
    return 0
  fi

  warn "Reboot required."
  if [ -f "$REBOOT_FLAG.pkgs" ]; then
    warn "Triggered by: $(sort -u "$REBOOT_FLAG.pkgs" | tr '\n' ' ')"
  fi

  if [ "$FAILED" -ne 0 ]; then
    warn "Not scheduling an automatic reboot because one or more upgrade steps failed; review the log first."
  else
    case "$REBOOT_MODE" in
      yes)
        if reboot_allowed_by_interval; then do_reboot=1; fi
        ;;
      no)
        ;;
      auto)
        if [ -t 0 ]; then
          if read -r -t 120 -n 1 -p "Reboot now? (y/N; defaults to no after 120s) " reply; then
            printf '\n'
          else
            reply=N
            printf '\n'
            warn "Reboot prompt timed out or reached EOF; defaulting to no."
          fi
          if [[ "$reply" =~ ^[Yy]$ ]]; then do_reboot=1; fi
        fi
        ;;
    esac
  fi

  if [ "$do_reboot" -eq 1 ]; then
    info "Scheduling reboot in 1 minute (cancel with: shutdown -c)."
    if shutdown -r +1 "System rebooting after upgrades" 9>&-; then
      record_auto_reboot
    else
      warn "Failed to schedule reboot."
      FAILED=1
      reboot_pending=1
    fi
  else
    reboot_pending=1
    info "Not rebooting automatically. Reboot when convenient."
  fi
}

# ---------- argument parsing / preflight ----------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)   DRY_RUN=1 ;;
      --reboot)    REBOOT_MODE=yes ;;
      --no-reboot) REBOOT_MODE=no ;;
      --flatpak)   DO_FLATPAK=1 ;;
      --snap)      DO_SNAP=1 ;;
      --clean)     DO_CLEAN=1 ;;
      -h|--help)   usage; exit 0 ;;
      *)           usage >&2; die "Unknown option: $1" ;;
    esac
    shift
  done
}

preflight() {
  [ "$EUID" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }
  command -v apt-get    >/dev/null 2>&1 || { echo "apt-get not found; Debian/Ubuntu only." >&2; exit 1; }
  command -v dpkg-query >/dev/null 2>&1 || die "dpkg-query not found."
  command -v flock      >/dev/null 2>&1 || die "flock not found."

  # From here on, configuration/version errors are reported via NOTIFY_CMD.
  NOTIFY_ARMED=1

  validate_uint MAX_REMOVALS                 100000
  validate_uint MAX_AUTOREMOVALS             100000
  validate_uint MIN_FREE_MB                  100000000
  validate_uint MIN_BOOT_MB                  100000000
  validate_uint PRE_UPGRADE_TIMEOUT          86400
  validate_uint POST_UPGRADE_SETTLE_SECONDS  3600
  validate_uint REBOOT_MIN_INTERVAL          31536000
  [ "$PRE_UPGRADE_TIMEOUT" -ge 1 ] || die "PRE_UPGRADE_TIMEOUT must be at least 1."
  case "$NOTIFY_ON" in
    fail|always|attention) ;;
    *) die "NOTIFY_ON must be 'fail', 'always' or 'attention'." ;;
  esac
  case "$NEEDRESTART_MODE" in
    a|l) ;;
    *) die "NEEDRESTART_MODE must be 'a' or 'l'." ;;
  esac
  apt_version_check

  # Optional tools are verified BEFORE any package change, so a missing tool is a
  # clear configuration error rather than a failure discovered after the upgrade.
  if [ "$DO_FLATPAK" -eq 1 ]; then
    command -v flatpak >/dev/null 2>&1 \
      || die "--flatpak was requested but flatpak is not installed (it is not part of a default Debian/Ubuntu install). Install it with 'apt-get install flatpak' or drop --flatpak."
    flatpak --version >/dev/null 2>&1 \
      || die "--flatpak was requested but the flatpak command does not run correctly."
  fi
  if [ "$DO_SNAP" -eq 1 ]; then
    command -v snap >/dev/null 2>&1 \
      || die "--snap was requested but snap is not installed (install 'snapd' with 'apt-get install snapd' or drop --snap)."
  fi
  if [ "$REBOOT_MODE" = yes ]; then
    command -v shutdown >/dev/null 2>&1 \
      || die "--reboot was requested but the shutdown command is not available."
  fi

  # Create/check privileged paths without following pre-existing symlinks.
  check_owned_root_path "$LOG_FILE"
  check_owned_root_path "$STATE_DIR"
  check_owned_root_path "$LOCK_FILE"
}

setup_logging() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  mkdir -p -- "$STATE_DIR"
  chown root:root "$STATE_DIR"
  chmod 0750 "$STATE_DIR"
  touch -- "$LOG_FILE"
  chown root:root "$LOG_FILE"
  chmod 0640 "$LOG_FILE"
  exec 3>&1 4>&2
  exec > >(tee -a "$LOG_FILE") 2>&1
  tee_pid=$!
  logging_enabled=1
}

# Only one instance at a time. The holder writes "pid epoch" into the lock file
# AFTER taking the lock, so a second instance judges staleness from the holder's
# own start time rather than from file mtimes. A conflict is normally
# informational; a lock held past LOCK_STALE_SECONDS is escalated (non-zero exit)
# so unattended monitoring can detect likely hangs. Neither case sends a
# notification: a lock conflict is not an upgrade failure.
acquire_lock() {
  local holder_start="" age
  exec 9<>"$LOCK_FILE"
  if ! flock -n 9; then
    NOTIFY_ARMED=0
    IFS=' ' read -r _ holder_start < "$LOCK_FILE" || holder_start=""
    if [[ "$holder_start" =~ ^[0-9]{1,12}$ ]]; then
      age=$(( $(date +%s) - 10#$holder_start ))
      if [ "$age" -gt "$LOCK_STALE_SECONDS" ]; then
        warn "Another run has held the lock for ${age}s; it may be hung. Check the process and logs."
        die "Upgrade lock appears stale; refusing to start a second package transaction."
      fi
    fi
    warn "Another safe-upgrade run is already in progress."
    exit 75
  fi
  printf '%s %s\n' "$$" "$(date +%s)" > "$LOCK_FILE"
}

# ---------- main ----------
main() {
  local sim asim summary upgrades acount drift

  parse_args "$@"
  preflight
  setup_logging
  acquire_lock

  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE
  export APT_LISTCHANGES_FRONTEND=none
  export UCF_FORCE_CONFOLD=1

  APT_OPTS=(
    -y
    -o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT"
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
    -o Acquire::Retries=2
    -o Acquire::http::Timeout=30
    -o Acquire::https::Timeout=30
  )

  info "Starting system upgrade (dry-run=$DRY_RUN)"
  check_all_space

  # Detect crashed prior runs BEFORE any mutation (including dpkg repair), so a
  # stale record is reported against the pre-repair state.
  if [ "$DRY_RUN" -eq 0 ]; then
    check_previous_runs
  fi

  if [ -n "$(dpkg --audit 2>/dev/null)" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "dpkg is in a broken/interrupted state; a real run would repair it first. Simulation may be unreliable."
    else
      warn "dpkg reports a broken/interrupted state; attempting repair."
      begin_mutation   # rollback point first: the repair itself is a mutation
      with_clean_umask dpkg --configure -a --force-confdef --force-confold
      run_apt check || die "APT dependency check failed after dpkg repair."
    fi
  fi

  local held
  held=$(apt-mark showhold 2>/dev/null || true)
  [ -z "$held" ] || info "Held packages (protected from removal; not upgraded): $(tr '\n' ' ' <<<"$held")"

  refresh_package_lists
  # Package metadata refresh can consume space, so re-check before simulation/install.
  check_all_space

  if ! sim=$(run_apt -s "${APT_OPTS[@]}" full-upgrade 2>&1); then
    printf '%s\n' "$sim" >&2
    die "Upgrade simulation failed (output above)."
  fi
  upgrades=$(grep -c '^Inst ' <<<"$sim" || true)
  info "Simulation: $upgrades package(s) to install/upgrade"
  summary=$(grep -E '^[0-9]+ upgraded,' <<<"$sim" || true)
  [ -z "$summary" ] || info "APT summary: $summary"
  guard_removals "full-upgrade" "$sim" "$MAX_REMOVALS" || die "Aborting: removal guard tripped. Review manually."
  boot_plan_ok "$sim" || die "Aborting: $BOOT_DIR is read-only but this upgrade changes boot-related packages. Remount it read-write and re-run."

  if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run complete; no packages were installed or removed. APT lists were refreshed."
    exit 0
  fi

  # ---------- upgrade ----------
  if [ "$upgrades" -gt 0 ]; then
    begin_mutation

    # Re-simulate immediately before the actual transaction to reduce (not
    # eliminate) the simulation/execution race. The hook may have taken minutes.
    if ! sim=$(run_apt -s "${APT_OPTS[@]}" full-upgrade 2>&1); then
      printf '%s\n' "$sim" >&2
      die "Final upgrade simulation failed."
    fi
    guard_removals "final full-upgrade" "$sim" "$MAX_REMOVALS" || die "Aborting: final removal guard tripped."
    boot_plan_ok "$sim" || die "Aborting: $BOOT_DIR became read-only or the plan changed; boot-related packages would be touched."

    info "Upgrading packages"
    run_apt "${APT_OPTS[@]}" full-upgrade

    # Verify package dependency consistency before autoremove.
    run_apt check || die "APT dependency check failed after full-upgrade."
  else
    info "No packages need upgrading."
  fi

  # Autoremove has its own fresh simulation and protection set.
  if asim=$(run_apt -s autoremove "${APT_OPTS[@]}" 2>&1); then
    acount=$(grep -Ec '^(Remv|Purg) ' <<<"$asim" || true)
    if guard_removals "autoremove" "$asim" "$MAX_AUTOREMOVALS"; then
      if [ "$acount" -gt 0 ]; then
        begin_mutation
        info "Removing unneeded dependencies"
        run_apt "${APT_OPTS[@]}" autoremove
      fi
    else
      warn "Autoremove skipped by removal guard; review with: apt-get -s autoremove"
      FAILED=1
    fi
  else
    warn "Autoremove simulation failed; skipping autoremove."
    FAILED=1
  fi

  if [ "$DO_CLEAN" -eq 1 ]; then
    info "Cleaning obsolete cached packages"
    if run_apt autoclean -o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT"; then
      :
    else
      warn "apt-get autoclean failed."
      FAILED=1
    fi
  fi

  # ---------- optional extras ----------
  # Re-verify: an upgrade can in principle remove these tools.
  if [ "$DO_FLATPAK" -eq 1 ]; then
    if command -v flatpak >/dev/null 2>&1; then
      begin_mutation
      info "Updating Flatpak system/root installation"
      with_clean_umask flatpak update --system -y --noninteractive \
        || { warn "Flatpak update failed."; FAILED=1; }
      with_clean_umask flatpak uninstall --system --unused -y --noninteractive \
        || { warn "Flatpak unused-runtime cleanup failed."; FAILED=1; }
    else
      warn "flatpak disappeared during the run; skipping Flatpak update."
      FAILED=1
    fi
  fi
  if [ "$DO_SNAP" -eq 1 ]; then
    if command -v snap >/dev/null 2>&1; then
      begin_mutation
      info "Refreshing Snap packages (Snap may restart services during refresh)."
      with_clean_umask snap refresh || { warn "Snap refresh failed."; FAILED=1; }
    else
      warn "snap disappeared during the run; skipping Snap refresh."
      FAILED=1
    fi
  fi

  # ---------- package inventory + config drift + service checks ----------
  if [ "$mutated" -eq 1 ]; then
    write_package_snapshot "$after"
    report_package_changes "$before" "$after"
    info "Package inventories: before=$before after=$after"

    # --force-confold preserves existing files; report dpkg/ucf vendor defaults
    # saved during this run. Best-effort indicator, not a complete config diff.
    drift=$(find /etc -xdev -type f \( -name '*.dpkg-dist' -o -name '*.dpkg-new' -o -name '*.ucf-dist' \) \
      -cnewer "$marker" 2>/dev/null || true)
    if [ -n "$drift" ]; then
      drift_count=$(grep -c . <<<"$drift" || true)
      warn "New vendor configuration files were saved alongside existing configuration ($drift_count):"
      # shellcheck disable=SC2001 # per-line indent; sed is clearer here
      sed 's/^/    /' <<<"$drift" >&2
    fi
    rm -f -- "$marker"
    marker=""

    check_post_upgrade_services
  else
    info "Nothing was changed; no rollback point or inventory was created."
  fi

  # ---------- reboot handling ----------
  handle_reboot

  exit "$FAILED"
}

# Allow sourcing for tests without running the upgrade.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
