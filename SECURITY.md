# Security policy

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting:
Security tab -> "Report a vulnerability".

Include the script version, distribution, and steps to reproduce. I aim to
acknowledge reports within 7 days.

## What counts

This script runs as root and executes commands from its environment
(`PRE_UPGRADE_HOOK`, `NOTIFY_CMD`). Examples of in-scope issues: privilege
escalation through its files or paths, symlink or race problems in
`/var/lib/safe-upgrade`, `/var/log` or `/run`, and bypasses of the removal
guards. Configuring the hooks to run something harmful as root is by design
and out of scope.
