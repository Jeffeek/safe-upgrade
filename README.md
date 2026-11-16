# safe-upgrade

[![CI](https://github.com/Jeffeek/safe-upgrade/actions/workflows/ci.yml/badge.svg)](https://github.com/Jeffeek/safe-upgrade/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Status: beta](https://img.shields.io/badge/status-beta-orange.svg)

A guarded full system upgrade for Debian and Ubuntu. It wraps `apt-get full-upgrade` with pre-flight checks, policy guards, logging, post-upgrade verification and reboot handling, so it can be run unattended (for example from a systemd timer) with fewer surprises than a bare `apt-get`.

> **Read this first.** The script *reduces* common upgrade risks. It cannot make APT simulation and execution atomic, it does not roll anything back by itself, and it cannot protect against power loss. Use a tested snapshot hook (`PRE_UPGRADE_HOOK`) on any machine you care about.

> **Status: beta (v0.x).** It is a root-privileged script. Read it, run `--dry-run` first, and try it in a VM before using it on a machine you care about. The project was developed with AI assistance; see [AI assistance disclosure](#ai-assistance-disclosure).

---

## Table of contents

1. [Features](#features)
2. [Requirements](#requirements)
3. [Installation](#installation)
4. [Quick start](#quick-start)
5. [Command-line options](#command-line-options)
6. [Environment variables](#environment-variables)
7. [How a run works](#how-a-run-works)
8. [Protection and guard rules](#protection-and-guard-rules)
9. [Rollback point (PRE_UPGRADE_HOOK)](#rollback-point-pre_upgrade_hook)
10. [Notifications](#notifications)
11. [Post-upgrade service checks](#post-upgrade-service-checks)
12. [Reboot handling](#reboot-handling)
13. [Scheduling with systemd](#scheduling-with-systemd)
14. [Files and directories](#files-and-directories)
15. [Exit codes](#exit-codes)
16. [Usage examples](#usage-examples)
17. [Troubleshooting](#troubleshooting)
18. [Security notes](#security-notes)
19. [Known limitations](#known-limitations)
20. [Development, testing and CI](#development-testing-and-ci)
21. [AI assistance disclosure](#ai-assistance-disclosure)
22. [License](#license)

---

## Features

- **Simulate, validate, re-simulate, execute.** The plan from `apt-get -s full-upgrade` is checked against policy, then simulated again right before the real run to shrink the race window.
- **Removal guards.** Limits on how many packages may be removed, plus protected package names/globs. Essential, Protected, held and running-kernel packages are always protected and the check fails closed.
- **Pre-flight checks.** Free space and inodes on `/`, `/var` and `/boot`, read-only filesystem detection, missing mounts, dpkg state, APT version.
- **Lazy rollback point.** `PRE_UPGRADE_HOOK` runs only immediately before the first real change, so a run with nothing to do creates no snapshot.
- **Single instance.** `flock` with stale-lock detection.
- **Crash detection.** An interrupted earlier run blocks the next run until you review it.
- **Package inventories** before and after each run, with a summary of what changed.
- **Config drift report** (`.dpkg-dist`, `.dpkg-new`, `.ucf-dist`) because upgrades keep your existing config files (`--force-confold`).
- **Post-upgrade service checks** for units you list.
- **Reboot logic** with kernel-flavor-aware detection and reboot-loop protection.
- **Optional extras:** Flatpak (system installation), Snap refresh, `apt-get autoclean`.
- **Logging** to `/var/log/safe-upgrade.log` and optional failure/attention notifications.

### When to use this (and when not to)

For most machines, Debian/Ubuntu's own `unattended-upgrades` is the standard, well-tested tool, and this script is **not** a replacement for it. Consider `safe-upgrade.sh` when you want a guarded **`full-upgrade`** (which may install new dependencies and remove packages) with explicit limits on removals, protected packages, a rollback-hook point, service checks afterwards and reboot-loop protection, for example on a home server or a small fleet. If you only need unattended security updates, use `unattended-upgrades`.

## Requirements

| Requirement | Notes |
| --- | --- |
| Debian or Ubuntu | Uses `apt-get`, `dpkg-query`, `apt-mark` |
| Root | Must be run as root (`sudo`) |
| `bash` 4+ | Uses `BASH_REMATCH`, process substitution, arrays |
| `apt-get` >= 1.9.11 | Needed for `DPkg::Lock::Timeout`; checked at start |
| `flock`, `dpkg-query` | Required; script aborts if missing |
| `timeout`, `findmnt`, `mountpoint`, `systemd-inhibit`, `systemctl`, `shutdown` | Used when available; some are required only for specific features |
| `flatpak` | Only with `--flatpak` (not installed by default) |
| `snapd` | Only with `--snap` (default on Ubuntu only) |
| `needrestart` | Optional; honoured through `NEEDRESTART_MODE` |

## Installation

Three things must be true before the script will run:

1. **The file must be executable.** A downloaded or copied file usually is not. Without this you get `Permission denied` (or a confusing `command not found` when using `sudo`).
2. **The first line must be `#!/usr/bin/env bash`.** If your copy starts with stray lines (for example `/opt/` or `/`), delete them. Otherwise it is run by `sh`, which fails with `set: Illegal option -o pipefail`.
3. **Line endings must be Unix (LF), not Windows (CRLF).** CRLF shows up as garbled errors such as `: not foundh: 1:` (the `\r` overwrites part of the message). Check with `file safe-upgrade.sh`; fix with `sed -i 's/\r$//' safe-upgrade.sh`. Downloading a release asset or cloning the repository avoids this.

The file name is up to you. This document says `safe-upgrade.sh`; if your copy is called `upgrade.sh`, use that name everywhere below.

### Option A: install system-wide (recommended)

This puts the script in a directory that is in `PATH`, with the right owner and permissions. `install -m 0750` also sets the executable bit, so no separate `chmod` is needed.

```bash
sudo install -o root -g root -m 0750 safe-upgrade.sh /usr/local/sbin/safe-upgrade.sh

# Sanity checks
head -n 1 /usr/local/sbin/safe-upgrade.sh     # should print the shebang
bash -n /usr/local/sbin/safe-upgrade.sh       # syntax check
shellcheck /usr/local/sbin/safe-upgrade.sh    # optional, if installed

# Now it can be run by name
sudo safe-upgrade.sh --dry-run
```

### Option B: run from where you saved it (for example `/opt`)

Make the file executable once, then run it with an explicit path. A bare name only works for files in `PATH`, and the current directory is not in `PATH`, so the leading `./` is required.

```bash
cd /opt
sudo chmod +x safe-upgrade.sh
head -n 1 safe-upgrade.sh                     # should print the shebang
sudo ./safe-upgrade.sh --dry-run
```

Or skip `chmod` and run it through `bash` directly:

```bash
sudo bash safe-upgrade.sh --dry-run
```

Optional log rotation, `/etc/logrotate.d/safe-upgrade`:

```
/var/log/safe-upgrade.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
```

## Quick start

The examples in this document use the bare name `safe-upgrade.sh`, which assumes you installed it system-wide ([Option A](#option-a-install-system-wide-recommended)). If you run it from its own directory ([Option B](#option-b-run-from-where-you-saved-it-for-example-opt)), make it executable first (`sudo chmod +x safe-upgrade.sh`) and write `sudo ./safe-upgrade.sh` instead.

```bash
# 1. Preview: refresh lists and simulate; installs and removes nothing
sudo safe-upgrade.sh --dry-run

# 2. Run for real (interactive; asks before rebooting if one is needed)
sudo safe-upgrade.sh

# 3. Unattended style: upgrade, then reboot automatically if needed
sudo safe-upgrade.sh --reboot
```

## Command-line options

| Option | Description |
| --- | --- |
| `--dry-run` | Refresh APT package lists and simulate the upgrade. Installs and removes nothing, but **does** write `/var/lib/apt/lists` and takes transient locks. Does not write this script's log or state files and sends no notification. A tripped guard still exits non-zero. |
| `--reboot` | If a reboot is needed and no step failed, schedule one in 1 minute (cancel with `shutdown -c`). Suppressed if the current boot or the last automatic reboot is younger than `REBOOT_MIN_INTERVAL`. |
| `--no-reboot` | Never reboot automatically. |
| `--flatpak` | Also update the system (root) Flatpak installation and remove unused runtimes. Requires `flatpak`; checked before any change. |
| `--snap` | Also run `snap refresh`. Requires `snapd`; checked before any change. |
| `--clean` | Run `apt-get autoclean` afterwards. |
| `-h`, `--help` | Show usage and exit. |

With neither `--reboot` nor `--no-reboot`, the script is in "auto" mode: it asks `Reboot now? (y/N)` only if stdin is a terminal (120 s timeout, default no). When run non-interactively (cron, systemd) it does not reboot.

## Environment variables

All are optional. Set them only from trusted, root-owned configuration (systemd unit, drop-in, or `EnvironmentFile`).

| Variable | Default | Description |
| --- | --- | --- |
| `MAX_REMOVALS` | `5` | Maximum packages `full-upgrade` may remove (0 to 100000). |
| `MAX_AUTOREMOVALS` | `15` | Maximum packages `autoremove` may remove. |
| `PROTECTED_PKGS` | `openssh-server sudo systemd ufw network-manager netplan.io` | Space-separated names or globs that must never be removed. Architecture qualifiers (`:amd64`) are stripped, so a bare name covers all architectures. |
| `MIN_FREE_MB` | `1024` | Required free space on `/` and `/var`. |
| `MIN_BOOT_MB` | `150` | Required free space on `/boot`. Raise to about 300 on small `/boot` partitions. |
| `PRE_UPGRADE_HOOK` | *(empty)* | Command run via `bash -o pipefail -ec` before the first change. If it fails or times out, the run aborts before any package change. |
| `PRE_UPGRADE_TIMEOUT` | `600` | Seconds (1 to 86400) before the hook is killed. |
| `NOTIFY_CMD` | *(empty)* | Command run for notifications (30 s timeout). See [Notifications](#notifications). |
| `NOTIFY_ON` | `fail` | `fail`, `always` or `attention`. |
| `POST_UPGRADE_SERVICES` | *(empty)* | Space-separated systemd units to verify after upgrading. |
| `POST_UPGRADE_SETTLE_SECONDS` | `5` | Wait before service checks (0 to 3600). |
| `REBOOT_MIN_INTERVAL` | `3600` | Minimum seconds between automatic reboots and minimum uptime before one. `0` disables the protection. |
| `NEEDRESTART_MODE` | `a` | `a` = services restarted automatically; `l` = list only. |

Invalid values (non-numeric, out of range, bad enum) abort the run with a clear message.

> Because the script reads variables with `${VAR-default}`, a variable set to an **empty string** stays empty (for example `PROTECTED_PKGS=""` removes your configured list). The built-in protections still apply.

## How a run works

1. **Parse arguments** and **preflight**: root, tools, variable validation, APT version, optional tools (`flatpak`, `snap`, `shutdown`), symlink and ownership checks on log, state and lock paths.
2. **Logging** starts (not in `--dry-run`): output goes to the terminal and `/var/log/safe-upgrade.log`.
3. **Lock** (`/run/safe-upgrade.lock`). If another instance holds it, exit 75.
4. **Space check** on `/`, `/var`, `/boot`.
5. **Previous-run check** (real runs): any `run-*.status` that is empty or says `running` blocks the run.
6. **dpkg audit**: if dpkg is in a broken state, a real run takes the rollback point and repairs it (`dpkg --configure -a`, then `apt-get check`).
7. **Refresh package lists** with up to 3 attempts, 45 s apart. Partial index failures count as failure.
8. **Space re-check**, then **simulate** `full-upgrade`.
9. **Guards**: removal count, protected packages, malformed records, read-only `/boot` vs boot-related packages.
10. `--dry-run` stops here with exit 0.
11. **If there are upgrades:** run `PRE_UPGRADE_HOOK`, write the "before" inventory, **re-simulate**, re-apply guards, run `full-upgrade`, then `apt-get check`.
12. **Autoremove:** fresh simulation and guard. Anything above `MAX_AUTOREMOVALS` or touching a protected package is skipped and marks the run as failed.
13. **Optional:** `autoclean`, Flatpak, Snap.
14. **After any change:** "after" inventory and summary, config drift scan, post-upgrade service checks.
15. **Reboot handling** and exit.

If nothing was changed, no snapshot or inventory is created.

## Protection and guard rules

A removal is blocked when **any** of these apply:

- The number of removals exceeds `MAX_REMOVALS` (or `MAX_AUTOREMOVALS` for autoremove).
- A package matches `PROTECTED_PKGS`.
- A package is **Essential** or **Protected** according to dpkg (fail closed if dpkg metadata cannot be read).
- A package is **held** (`apt-mark showhold`).
- A package owns the **running kernel** image or modules (resolved from disk, plus conventional names as a safety net).
- The simulation output contains a malformed or unparseable removal record.

When `/boot` is mounted read-only, plans that install or remove `linux-image`, `initramfs-tools`, `grub`, `shim`, `systemd-boot`, `flash-kernel` or `u-boot` packages are refused.

## Rollback point (PRE_UPGRADE_HOOK)

The hook runs **lazily**, immediately before the first system mutation (dpkg repair, `full-upgrade`, `autoremove`, Flatpak, Snap). It runs with `umask 022`, a timeout, and with the script's lock descriptor closed.

Put the logic in a script and point the variable at it. Treat the following as **examples to adapt and test**, not drop-in solutions.

```bash
#!/usr/bin/env bash
# /usr/local/sbin/pre-upgrade-snapshot.sh   (chmod 0750, owned by root)
set -euo pipefail
stamp=$(date +%Y%m%d-%H%M%S)

# LVM (root on /dev/vg0/root; needs free space in the volume group)
lvcreate --snapshot --name "pre-upgrade-$stamp" --size 5G /dev/vg0/root

# btrfs (snapshots directory must exist)
# btrfs subvolume snapshot -r / "/.snapshots/pre-upgrade-$stamp"

# ZFS (adjust dataset name)
# zfs snapshot "rpool/ROOT/ubuntu@pre-upgrade-$stamp"
```

Then:

```bash
sudo PRE_UPGRADE_HOOK=/usr/local/sbin/pre-upgrade-snapshot.sh safe-upgrade.sh
```

For virtual machines, a hypervisor snapshot (via its CLI or API) is usually the strongest rollback point. Also write down and **test the restore procedure**; the script itself never restores anything.

## Notifications

`NOTIFY_CMD` runs through `bash -o pipefail -ec` with a 30 s timeout. It receives these environment variables:

| Variable | Meaning |
|---|---|
| `STATUS` | `ok` or `failed` |
| `EXIT_CODE` | The script's exit code |
| `LOG_FILE` | Path to the log |
| `HOST` | Hostname |
| `DRIFT_COUNT` | Number of new vendor config files saved this run |
| `REBOOT_PENDING` | `1` if a reboot is needed but was not scheduled, else `0` |

`NOTIFY_ON` controls when it fires:

- `fail` (default): only on a non-zero exit.
- `attention`: on failure, on config drift, or when a reboot is pending.
- `always`: after every real run that reaches the notification step.

Notifications are **not** sent for `--dry-run`, for lock conflicts (exit 75 or stale lock), or for usage and non-root errors, which happen before notification is armed. A failing `NOTIFY_CMD` never changes the upgrade's exit code.

Examples:

```bash
# Mail (requires a working mailx/mail setup)
NOTIFY_CMD='mail -s "safe-upgrade $STATUS on $HOST (exit $EXIT_CODE)" admin@example.com < "$LOG_FILE"'

# Webhook
NOTIFY_CMD='curl -fsS -m 20 -d "$HOST: safe-upgrade $STATUS (exit $EXIT_CODE)" https://ntfy.example.com/ops'
```

## Post-upgrade service checks

With `POST_UPGRADE_SERVICES="nginx postgresql ssh"`, after package changes the script waits `POST_UPGRADE_SETTLE_SECONDS`, then flags a unit that is:

- `failed`,
- stuck in an auto-restart loop or not stable after about 30 s of `activating`,
- not active when it should be (a oneshot without `RemainAfterExit` is considered healthy when inactive),
- or unknown to systemd.

Any flagged unit marks the run as failed (exit 1) and suppresses automatic reboot. If systemd is not running, the check is reported as failed.

## Reboot handling

A reboot is considered needed when `/run/reboot-required` exists, or when a newer kernel of the **same flavor** as the running one is installed in `/boot` (with an initramfs if the running kernel has one).

| Mode | Behaviour |
|---|---|
| `--reboot` | Schedules `shutdown -r +1` if no step failed and the interval protection allows it. Records the time in `/var/lib/safe-upgrade/last-auto-reboot`. |
| `--no-reboot` | Never reboots; reports that one is pending. |
| *(default)* | Prompts on a terminal; otherwise does not reboot. |

If any step failed, no automatic reboot is scheduled. Reboot-loop protection refuses an automatic reboot if uptime is below `REBOOT_MIN_INTERVAL`, the last automatic reboot was more recent, or the state file is unreadable (delete `/var/lib/safe-upgrade/last-auto-reboot` to re-enable). The interval protection applies to `--reboot`, not to the interactive prompt.

## Scheduling with systemd

A oneshot service plus a persistent timer is recommended: missed runs catch up after downtime and the job gets its own cgroup.

```bash
sudo install -m 0644 contrib/systemd/safe-upgrade.service contrib/systemd/safe-upgrade.timer /etc/systemd/system/
sudo install -m 0600 contrib/systemd/safe-upgrade.default /etc/default/safe-upgrade
sudo systemctl daemon-reload && sudo systemctl enable --now safe-upgrade.timer

# Check it is scheduled, and read the service log after a run
systemctl list-timers safe-upgrade.timer
journalctl -u safe-upgrade.service -e
```

Notes:

- In unit files, `%` and `$` are special. Prefer putting complex commands in a script file and referencing the path, as above.
- Avoid competition for APT locks. Disable or mask the competing automatic jobs, for example:

  ```bash
  sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer
  sudo systemctl mask unattended-upgrades.service   # only if you do not use it
  ```

- Use release codenames in APT sources (not `stable`) to avoid accidental distribution upgrades.

A cron entry also works (`30 3 * * 0 root /usr/local/sbin/safe-upgrade.sh --no-reboot`), but cron does not catch up missed runs.

## Files and directories

| Path | Purpose |
| --- | --- |
| `/var/log/safe-upgrade.log` | Log (mode 0640, root) |
| `/var/lib/safe-upgrade/` | State directory (mode 0750, root) |
| `packages-<stamp>.before` / `.after` | Installed package inventories (`name<TAB>version`); last 20 complete pairs kept |
| `run-<stamp>.status` | `running ...`, `success <epoch>` or `failed:<code> <epoch>`; last 20 kept |
| `marker-<stamp>` | Temporary marker used for drift detection |
| `last-auto-reboot` | Epoch time of the last automatic reboot |
| `/run/safe-upgrade.lock` | Lock file (holder PID and start time) |
| `/run/reboot-required` | Standard Debian/Ubuntu reboot flag (read only) |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success (or `--dry-run` completed, or `--help`) |
| `1` | Failure: a guard tripped, a check failed, a step failed, stale lock, unresolved earlier run, bad configuration |
| `75` | Another run is already in progress |
| `129` / `130` / `143` | Terminated by HUP / INT / TERM |

The reason for a failure is always in the log; only these codes are distinguished.

## Usage examples

```bash
# Preview only
sudo safe-upgrade.sh --dry-run

# Interactive upgrade, ask before rebooting
sudo safe-upgrade.sh

# Upgrade, never reboot
sudo safe-upgrade.sh --no-reboot

# Upgrade, reboot automatically if needed (and allowed)
sudo safe-upgrade.sh --reboot

# Also update Flatpak and Snap, and clean the package cache
sudo safe-upgrade.sh --flatpak --snap --clean

# Stricter removal limits, protect extra packages
sudo MAX_REMOVALS=0 MAX_AUTOREMOVALS=5 \
     PROTECTED_PKGS="openssh-server sudo systemd ufw postgresql-* nginx*" \
     safe-upgrade.sh

# Small /boot partition
sudo MIN_BOOT_MB=300 safe-upgrade.sh

# Snapshot first, then check services afterwards
sudo PRE_UPGRADE_HOOK=/usr/local/sbin/pre-upgrade-snapshot.sh \
     POST_UPGRADE_SERVICES="ssh nginx postgresql" \
     safe-upgrade.sh --no-reboot

# Don't restart services during the upgrade (list only)
sudo NEEDRESTART_MODE=l safe-upgrade.sh

# Notify on anything needing attention
sudo NOTIFY_ON=attention NOTIFY_CMD='logger -t safe-upgrade "$HOST $STATUS drift=$DRIFT_COUNT reboot=$REBOOT_PENDING"' \
     safe-upgrade.sh

# Review what changed in the last run
ls -1t /var/lib/safe-upgrade/packages-*.before | head -n 1
diff <(sort /var/lib/safe-upgrade/packages-<stamp>.before) \
     <(sort /var/lib/safe-upgrade/packages-<stamp>.after)

# Cancel a scheduled automatic reboot
sudo shutdown -c
```

## Troubleshooting

**`sudo: safe-upgrade.sh: command not found`, or `Permission denied`.**
This is the most common first-run problem. Check these in order:

1. **Not executable.** Fix with `sudo chmod +x safe-upgrade.sh`. Check with `ls -l safe-upgrade.sh`; you want an `x` in the permissions (for example `-rwxr-x---`).
2. **Not in `PATH`.** A bare name only works for files in a `PATH` directory. From the file's own directory use `sudo ./safe-upgrade.sh`, or install it with `sudo install -o root -g root -m 0750 safe-upgrade.sh /usr/local/sbin/`. Note that `sudo` uses its own restricted `PATH`, so a directory that works for your user may not work under `sudo`.
3. **Wrong name.** The file may be called something else (for example `upgrade.sh`). Run `ls` to check.
4. **Bad first line.** `head -n 1 safe-upgrade.sh` must print `#!/usr/bin/env bash`. Delete any stray lines above it.
5. **Workaround.** `sudo bash safe-upgrade.sh` runs it without the executable bit or `PATH`.

**`set: Illegal option -o pipefail`, or errors like `: not foundh: 1: /opt/`.**
Two copy problems at once: stray lines above the shebang (so `sh` runs the file instead of bash) and Windows line endings. Fix both:

```bash
head -n 4 safe-upgrade.sh                    # look for lines before #!/usr/bin/env bash
sudo sed -i '1,2d' safe-upgrade.sh           # only if the first two lines are the stray ones
sudo sed -i 's/\r$//' safe-upgrade.sh        # strip CRLF
head -n 1 safe-upgrade.sh                    # must print #!/usr/bin/env bash
file safe-upgrade.sh                         # must not mention CRLF
bash -n safe-upgrade.sh                      # no output = syntax OK
```

**"An earlier run appears to have been interrupted."**
A previous run died without finishing (power loss, SIGKILL). Verify the system, then remove the stale record:

```bash
sudo dpkg --audit
sudo apt-get check
sudo dpkg --configure -a        # if dpkg reported problems
sudo rm /var/lib/safe-upgrade/run-<stamp>.status
```

**"removal guard tripped."**
The plan would remove too many packages or a protected one. Inspect it, then decide:

```bash
apt-get -s full-upgrade | grep -E '^(Remv|Purg)'
```

Resolve the cause (a held or replaced package, a third-party repository), or raise the limit deliberately for one run.

**"Only NNN MB free on /boot".**
The script prints installed kernels and a suggested command. Purge an **old** kernel (never the running one, shown by `uname -r`), then re-run:

```bash
sudo apt-get --purge remove linux-image-<old-version> linux-modules-<old-version>
```

**"Another safe-upgrade run is already in progress" (exit 75).**
Normal if a run is active. If a run has held the lock for more than 6 hours, the script reports a possible hang and exits 1; check `ps` and the log.

**APT lock errors or `apt-get update` failures.**
Another APT process (unattended-upgrades, apt-daily) may be running. See the scheduling notes above. The script waits up to 300 s for the dpkg lock and retries `apt-get update` 3 times.

**Config drift reported.**
Existing config files were kept and the vendor versions saved beside them. Review and merge:

```bash
sudo find /etc -xdev -type f \( -name '*.dpkg-dist' -o -name '*.dpkg-new' -o -name '*.ucf-dist' \)
```

**A service failed after the upgrade.**

```bash
systemctl status <unit>
journalctl -u <unit> -e
```

The run exits 1 and no automatic reboot is scheduled.

**`PRE_UPGRADE_HOOK failed or timed out`.**
No packages were changed. Fix the hook (test it standalone as root) or raise `PRE_UPGRADE_TIMEOUT`.

## Security notes

- The script runs as root and executes `PRE_UPGRADE_HOOK` and `NOTIFY_CMD` as shell commands. Only trusted administrators may control its environment, unit files and hook scripts. Keep those files root-owned and not writable by others.
- It refuses symlinks at its log, state and lock paths and requires them to be root-owned.
- Child processes run with `umask 022` and without the lock file descriptor.
- `--force-confold` keeps your configuration on conflicts, so security-relevant changes in vendor defaults are not applied automatically; review drift reports.

## Known limitations

- **No atomicity.** APT cannot simulate, validate and execute the same plan atomically. Another APT process or a repository change after the final simulation can still alter the real transaction.
- **No built-in rollback.** Recovery depends on the snapshot you provide.
- **Interruption.** The script traps HUP, INT and TERM but cannot guarantee a clean stop in the middle of `dpkg`. Give systemd units a generous `TimeoutStopSec`.
- **Flatpak and Snap** are best-effort and have no pre-simulation or guards comparable to APT's.
- **Drift detection** is an indicator, not a full configuration diff.
- **Firmware updates on Raspberry Pi OS.** Kernels with non-Debian names are detected by comparing /lib/modules directories. Bootloader/EEPROM firmware updates have no reliable marker, so reboot manually after them.
- **Distribution upgrades** are out of scope; use release codenames in sources.

## Development, testing and CI

### Repository layout

``` layout
safe-upgrade.sh                    the script
tests/
  unit.bats                        unit tests (bats) for the script's functions
  cli.bats                         tests that execute the script (help, bad options, file hygiene)
  test_helper.bash, stubs.bash     helpers; external commands are replaced by shell functions
  integration/
    container-test.sh              end-to-end tests, run inside a disposable container
    systemd-test.sh                real-systemd tests (disposable VM only)
.github/workflows/ci.yml           lint + test matrix + Docker integration
.github/workflows/release.yml      tag-triggered release (runs CI first)
Makefile                           make lint | test | integration | check
```

### Running the tests locally

```bash
# Unit and CLI tests (install bats first: sudo apt-get install bats, or from bats-core)
make test

# Static checks (needs shellcheck)
make lint

# End-to-end tests in Docker, one container per image
make integration                      # real apt-get (needs network) + scripted phase
make integration SKIP_REAL_APT=1      # offline: scripted phase only
make integration IMAGES="debian:12"   # a single image
```

The integration script modifies `/var/log`, `/var/lib`, `/run` and `/usr/local/bin`, so it **refuses to run outside a container** unless you set `I_UNDERSTAND_THIS_MODIFIES_THE_SYSTEM=yes`. Do not do that on a real machine.

### What is tested

| Layer | How | What it covers |
| --- | --- | --- |
| Unit (`unit.bats`) | The script is sourced in a throw-away `bash`; `apt-mark`, `dpkg-query`, `uname`, `systemctl` are stubbed | Pattern matching, input validation, removal guards (limits, protected, essential, held, running kernel, malformed records, fail-closed paths), reboot detection and loop protection, state rotation, crash-record detection, inventory diffs, service-health logic, space checks, symlink and ownership checks |
| CLI (`cli.bats`) | The script is executed | `--help`, unknown options, non-root refusal, non-apt-system refusal, shebang, line endings, syntax |
| Integration A | Real `apt-get` in Debian/Ubuntu containers | `--dry-run`, a real run, an immediate second run, `--clean` |
| Integration B | A scripted fake `apt-get` and `shutdown` | Guards blocking before any change, hook success/failure/timeout, no snapshot on no-op runs, autoremove guard, lock conflict (exit 75), interrupted-run record, invalid configuration, notifications, reboot scheduling and suppression, SIGTERM handling |
| Systemd (systemd-test.sh) | Real systemd on GitHub runners; fake apt-get | Unit states for POST_UPGRADE_SERVICES, reboot blocking, the contrib service and timer, stopping the service mid-run. |

The tests were also checked by deliberately breaking the script in small ways (for example ignoring the removal limit, or sorting kernel versions as strings) and confirming that tests fail.

### What CI runs

| Job | Where | Purpose |
| --- | --- | --- |
| Lint | `ubuntu-24.04` | Shebang and line-ending check, `bash -n`, ShellCheck |
| Unit tests | `ubuntu-22.04`, `ubuntu-24.04`, `ubuntu-24.04-arm`, `ubuntu-26.04`, `ubuntu-26.04-arm` | Same tests on amd64 and arm64 (Raspberry Pi class CPUs), once as a normal user and once as root |
| Integration | `ubuntu-24.04` and `ubuntu-24.04-arm` x `debian:12`, `debian:13`, `ubuntu:22.04`, `ubuntu:24.04`, `ubuntu:26.04` | The end-to-end tests in 10 containers |
| CI passed | `ubuntu-24.04` | One aggregate check to require in branch protection |
| Real systemd | ubuntu-22.04, ubuntu-24.04, ubuntu-24.04-arm, ubuntu-26.04, ubuntu-26.04-arm | Integration systemd tests |
| Raspberry Pi OS (arm64) | `ubuntu-22.04` host, arm64 emulated via qemu-user | The offline integration phase on a real Pi OS userland (genuine `apt`/`dpkg`/`apt-mark` and the Pi `/boot` + `/lib/modules` layout). The kernel is the host runner's, so the Pi reboot path is *not* exercised here. |

CI runs on pushes to `main`, on pull requests, on demand, and **weekly**, so a change in a distribution's APT or dpkg behaviour is noticed even when the repository is quiet. Dependabot keeps the GitHub Actions versions current.

### What is *not* covered

- Real reboots, a real kernel upgrade, and `/boot` layouts of physical machines.
- Real systemd is covered on GitHub’s Ubuntu runners only, not on Debian or Raspberry Pi OS
- Snapshot hooks (LVM, btrfs, ZFS, hypervisor) and restoring from them.
- Flatpak and Snap flows.
- Raspberry Pi OS *kernels and firmware*. A CI job runs the offline integration
  tests against a real Pi OS arm64 userland (so `apt`/`dpkg` and the Pi `/boot` +
  `/lib/modules` layout are exercised), but it runs under qemu-user on the host
  kernel: `uname -r` is not a `+rpt-rpi-v8` string, so the Pi reboot-detection
  path and EEPROM/bootloader firmware updates are not covered there. The reboot
  logic itself is covered by the `FAKE_KERNEL` unit tests.
- Power loss or `kill -9` in the middle of `dpkg`.

Treat the test suite as evidence, not proof. Test on a copy of your own system before relying on it.

### Releasing

1. Update `CHANGELOG.md`.
2. Tag and push: `git tag v0.1.0 && git push origin v0.1.0`.
3. The **Release** workflow runs the full CI, then publishes a GitHub release with `safe-upgrade.sh`, a source tarball and `SHA256SUMS`. Versions `v0.*` and tags containing `-` are marked as pre-releases.
4. Users can verify a download: `sha256sum -c SHA256SUMS`.

In the repository settings, require the **CI passed** check on `main` so a failing test blocks merges.

### Contributing

Please add or update tests together with any behaviour change and run `make check` before opening a pull request. Bug reports are most useful with the log (`/var/log/safe-upgrade.log`), the distribution and version, and the `apt-get -s full-upgrade` output.

## AI assistance disclosure

This script, its documentation, and its test suite and CI configuration were developed with the assistance of an AI assistant, together with a human maintainer who reviewed, ran and adapted the result. AI-generated code can contain mistakes. The tests and CI in this repository exist to catch them, but they are not a substitute for reading a root-privileged script yourself and testing it in a VM before use.

## License

[MIT](LICENSE). Copyright holder: see the LICENSE file.
