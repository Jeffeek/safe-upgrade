# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/) (0.x = beta).

## [Unreleased]

### Added

- `--show-config`: prints the effective configuration (every environment
  override and the key paths) and exits. Does not require root, changes nothing,
  and never prints `PRE_UPGRADE_HOOK` / `NOTIFY_CMD` contents (only set/unset).
- `contrib/hooks/pre-upgrade-snapshot.sh`: a tested LVM/btrfs rollback-snapshot
  hook example, with input validation and a `SNAPSHOT_DRY_RUN=1` mode, plus
  `tests/hooks.bats` covering it.
- CLI test asserting the Debian/Ubuntu-only guard: on a system without
  `apt-get`, the script refuses cleanly with a clear message.
- CI job running the offline integration tests against a real Raspberry Pi OS
  arm64 userland (via `arm-runner-action`/qemu-user), covering genuine
  `apt`/`dpkg`/`apt-mark` behaviour and the Pi `/boot` + `/lib/modules` layout.
  The job runs on the host kernel, so the Pi reboot-detection path is not
  exercised there (it remains covered by the `FAKE_KERNEL` unit tests).

### Changed

- Documentation now states plainly that the tool is apt/dpkg-only by design
  (Debian/Ubuntu and close derivatives) and will not become a generic
  multi-distro upgrader, because its safety comes from being apt-specific. For
  security-only updates it continues to point at `unattended-upgrades`.
- `contrib/systemd/safe-upgrade.default` now documents every supported
  environment override (commented), so the config file is self-describing.
- `make lint` and the CI lint step now also ShellCheck `systemd-test.sh` and the
  contrib snapshot hook; `make test` and the CI unit-test jobs now run
  `tests/hooks.bats`.
- CI now also tests on Ubuntu 26.04 (amd64 and arm64) across the unit, systemd
  and Docker integration matrices, and the Docker integration adds an
  `ubuntu:26.04` image. `make integration` picks it up by default too.

### Fixed

- Documentation: corrected the `systemd-test.sh` path in the repository layout,
  removed a stray editing artifact in the reboot-handling section, de-duplicated
  the systemd scheduling commands, and aligned the CI table's runner labels with
  the pinned `ubuntu-24.04` jobs.
- Removed a dead no-op line from `refresh_package_lists`, and an unused loop
  variable in `systemd-test.sh` flagged once it was added to ShellCheck.

## [0.2.0] - 2026-11-16

### Added

- Reboot detection for kernels with non-Debian release names (for example
  Raspberry Pi OS, `6.6.51+rpt-rpi-v8`): the script now compares the
  `/lib/modules` directories and reports a pending reboot when a newer kernel
  of the same flavor is installed, or when the running kernel's modules were
  replaced in place. Debian/Ubuntu behavior is unchanged.
- Nine unit tests covering the new fallback (newer, older, replaced in place,
  other flavor, version sort, no `/lib/modules`, precedence of
  `/run/reboot-required`, Debian-style kernels unaffected).
- `contrib/systemd/` with a ready-to-install service, weekly timer and an
  example `/etc/default/safe-upgrade` environment file.
- `SECURITY.md` and GitHub private vulnerability reporting.
- Issue forms for bug reports and feature requests; blank issues are disabled
  and security reports are redirected to private reporting.
- CI job and `tests/integration/systemd-test.sh`: the script's service checks
  and the shipped `contrib/systemd` units are now tested against a real systemd
  (Ubuntu 22.04/24.04, amd64 and arm64).

### Changed

- Automatic reboot (`--reboot`, and `NOTIFY_ON=attention` notifications) can
  now trigger on Raspberry Pi OS after a kernel update; previously no reboot
  was ever detected there.
- The provided systemd service starts with `--no-reboot`; switch to `--reboot`
  once you trust the setup.
- CI jobs are pinned to `ubuntu-24.04` instead of `ubuntu-latest`, so a runner
  image change cannot break lint or releases unexpectedly.
- README: systemd section now points to `contrib/systemd/`; the Raspberry Pi
  limitation was narrowed to firmware (EEPROM/bootloader) updates, which still
  have no reliable marker.

### Dependencies

- `actions/checkout` updated from v4 to v7 (Dependabot).

## [0.1.0] - 2026-11-15

### Added
- Initial public release of `safe-upgrade.sh`: guarded `apt-get full-upgrade`
  with removal guards, protected packages, lazy rollback hook, lock handling,
  crash detection, post-upgrade service checks, reboot handling and
  notifications.
- Documentation (`README.md`).
- Test suite: bats unit and CLI tests, and container-based end-to-end tests
  (real `apt-get` plus a scripted fake `apt-get`).
- GitHub Actions: lint, test matrix (amd64 and arm64), Docker integration on
  Debian 12/13 and Ubuntu 22.04/24.04, weekly scheduled run, tag-triggered
  release.

[Unreleased]: https://github.com/Jeffeek/safe-upgrade/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Jeffeek/safe-upgrade/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Jeffeek/safe-upgrade/releases/tag/v0.1.0