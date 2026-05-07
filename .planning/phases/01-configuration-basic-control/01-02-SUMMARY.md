---
phase: "01"
plan: "02"
subsystem: cli
tags: [cli, refactor, idempotent, status]
dependency_graph:
  requires: []
  provides: [cli-command-routing, idempotent-ops, status-display]
  affects: [bin/cap.ps1, bin/cap.cmd, bin/cap]
tech_stack:
  added: []
  patterns: [flat-command-routing, unicode-status-indicators, dual-config-format]
key_files:
  created: [bin/cap.ps1, bin/cap.cmd, bin/cap]
  modified: [src/proxy-cli.ps1]
decisions:
  - Flattened proxy on/off to top-level cap on/off for ergonomics
  - Used unicode bullet indicators for status (works in Windows Terminal and cmd.exe)
  - Dual config support (nested and flat) for transition period
metrics:
  duration: 362s
  completed: "2026-05-07T07:18:31Z"
---

# Phase 1 Plan 2: CLI Refactor Summary

Rewrite CLI with flat command routing, idempotent behavior, docker-style status, and TcpClient leak fix.

## Tasks Completed

| Task | Description | Commit | Key Changes |
|------|-------------|--------|-------------|
| 2.1 | Rewrite CLI command routing | db1852a | Flat top-level commands (on/off/start/stop/restart/status), subcommand groups (domains/config/install/uninstall) |
| 2.2 | Implement status output | db1852a | Unicode indicators, color coding, --short flag, Format-Uptime helper |
| 2.3 | Fix TcpClient leak | db1852a | Added $tcp.Close() after successful connection test |
| 2.4 | Verify bin/cap scripts | db1852a | Confirmed @args passthrough works with new CLI structure |

## Key Implementation Details

- `cap on` auto-starts service (5s timeout) then enables proxy via API
- `cap off` when service not running prints yellow warning, exits 0
- `cap start/stop` are idempotent (no error for redundant operations)
- Status uses Write-Host with -NoNewline for colored multi-part lines
- Dual config detection: checks for `$config.control.port` (nested) or `$config.control_port` (flat)
- File writes use `[System.IO.File]::WriteAllText()` for BOM-free UTF-8

## Deviations from Plan

None - plan executed exactly as written.

## Known Stubs

None - all commands are functional (service-dependent commands gracefully handle service-not-running state).

## Self-Check: PASSED

- src/proxy-cli.ps1: FOUND
- bin/cap.ps1: FOUND
- bin/cap.cmd: FOUND
- bin/cap: FOUND
- Commit db1852a: FOUND
