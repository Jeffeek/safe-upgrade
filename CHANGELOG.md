# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/) (0.x = beta).

## [Unreleased]

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
