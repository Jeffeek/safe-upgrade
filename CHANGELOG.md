# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/) (0.x = beta).

## [Released]

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