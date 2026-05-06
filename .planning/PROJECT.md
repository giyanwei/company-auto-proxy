# Company Auto Proxy (CAP)

## What This Is

A Windows proxy auto-switch tool that detects network changes and automatically routes traffic through corporate or direct proxies based on domain rules. It provides a local proxy daemon with CLI, system tray, and web dashboard interfaces — designed for developers who work across corporate and personal networks.

## Core Value

The proxy "just works" — when you're on corporate WiFi it routes through the corporate proxy, when you're off-network it goes direct, and you never have to manually toggle or configure anything.

## Requirements

### Validated

- ✓ TCP proxy listener on configurable port (8081) — existing
- ✓ Domain-based routing (corporate proxy vs direct) — existing
- ✓ WiFi SSID-based network detection — existing
- ✓ System proxy interception (Windows registry + env vars) — existing
- ✓ CLI control via `cap` command (on/off/status) — existing
- ✓ System tray icon with context menu — existing
- ✓ Web dashboard with status display — existing
- ✓ Control API on port 8082 — existing
- ✓ PAC server for browser auto-configuration — existing
- ✓ JSON-based configuration file — existing
- ✓ Install/uninstall scripts — existing

### Active

- [ ] Full configurability — all proxy rules, network detection, behavior settings exposed in config.json with schema validation
- [ ] Interactive installer wizard — guides user through setup, adds to PATH, configures auto-start, detects shell type
- [ ] Self-healing — auto-restart on crash, health monitoring, watchdog process
- [ ] Graceful fallback — direct connection when corporate proxy unreachable, with popup notification
- [ ] Structured logging — levels (debug/info/warn/error), log rotation, diagnostic export
- [ ] Multiple trigger methods — `cap on/off` from any terminal, single tray-icon click toggle, dashboard start/stop button
- [ ] Error popup notifications — user-facing alerts when proxy fails or fallback activates
- [ ] Clean uninstall — removes PATH entries, scheduled tasks, registry keys, config files

### Out of Scope

- Linux/macOS support — Windows-only for now, may revisit after strong Windows foundation
- Package manager distribution (scoop/winget) — defer until tool is more mature and stable
- GUI settings editor — config.json is sufficient for power users; dashboard shows status not config
- Multi-user/enterprise deployment — personal tool first, enterprise later

## Context

- Brownfield project with working prototype (4 commits, ~2000 lines of PowerShell)
- Existing architecture: proxy daemon, control API, CLI, tray icon, dashboard
- No test framework currently in place
- No CI/CD pipeline
- Target audience: developers behind corporate proxies who switch networks frequently
- Planned to be open-source on GitHub
- proxy.exe binary exists (likely compiled Go) but project has shifted to pure PowerShell

## Constraints

- **Runtime**: PowerShell 5.1+ (ships with Windows 10/11, no extra installs)
- **Dependencies**: .NET Framework BCL only (no external packages)
- **Permissions**: Must work without admin rights for daily use (install may require admin)
- **Compatibility**: Windows 10/11 only
- **Architecture**: Single-machine, single-user (no server component)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Pure PowerShell (drop Go binary) | Zero dependencies, ships with Windows, easy to modify | — Pending |
| Interactive installer before package manager | Need stability first, package manager adds distribution complexity | — Pending |
| config.json as single source of truth | Simple, versionable, human-readable | — Pending |
| Open-source on GitHub | Build community, get feedback, personal portfolio | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-05-06 after initialization*
