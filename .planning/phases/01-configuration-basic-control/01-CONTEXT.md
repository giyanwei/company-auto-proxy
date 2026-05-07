# Phase 1 Context: Configuration + Basic Control

**Phase:** 1
**Date:** 2026-05-07
**Decisions:** 12

## Domain

This phase delivers a robust, validated configuration system that drives all proxy behavior, plus basic CLI control (`cap on/off/status/start/stop/restart`) for daily use and testability.

## Decisions

### Config Schema Structure
- **Nested sections** — migrate from flat keys to grouped sections
- 5 top-level sections in `config.json`: `proxy`, `network`, `control`, `logging`, `behavior`
- Domains move to a separate `domains.json` file (currently 238 lines, too large for config.json)
- JSON keys remain `snake_case` within sections

### Config Defaults Strategy
- **Layered merge** — `config.default.json` contains all fields with defaults; `config.json` only has user overrides
- Deep merge at load: user values win over defaults
- New version adding fields doesn't break existing user config

### Config Validation
- **Tiered validation** — critical fields (port, proxy URL) are strict (fail to start); optional fields (log level, dashboard port) are lenient (fallback to defaults + warn)
- On startup: validate merged config; report ALL errors at once (not one-at-a-time)

### Config File Location
- **Install directory** — all files (scripts + config) live in one folder
- Portable: clone/download a folder, run it
- No %APPDATA% split for now; revisit when package manager distribution happens

### Hot-Reload Behavior
- **FileSystemWatcher** with debounce (500ms) for instant detection
- Watch both Changed and Renamed events (editors use atomic save: write .tmp → rename)
- On invalid new config: keep old config in memory, show popup notification with error details, never modify user's file
- On valid new config: apply immediately, no restart needed

### CLI Command Design
- `cap on` / `cap off` — control proxy routing mode (CORP vs DIRECT)
- `cap start` / `cap stop` / `cap restart` — service lifecycle management
- `cap on` auto-starts service if not running (user never needs to think about it)
- `cap status` — full output by default (service state, mode, uptime, last-stop reason); accepts `--short` for minimal
- All commands are **idempotent**: `cap stop` when stopped = "Already stopped." (no error); `cap start` when running = "Already running."

### CLI Output Style
- **Docker/kubectl style** — colored status indicators + structured labels
- Colors: green=running, red=stopped, yellow=warning
- Example: `● Service: running | Mode: CORP | Uptime: 2h 15m | Connections: 47`

## Code Context

### Reusable Assets
- `src/proxy-cli.ps1` — existing CLI with `Send-ControlCommand` pattern (HTTP to control API)
- `src/proxy-service.ps1` — existing control API on port 8082 with endpoints: /status, /proxy/on, /proxy/off, /reload
- `config.json` — existing flat structure to migrate from
- `config.default.json` — already exists with some defaults

### Patterns to Follow
- PowerShell `Verb-Noun` naming for functions
- `$script:Config` for module-level state
- HTTP control API as IPC between CLI and service
- 4-space indentation, braces on same line

### Integration Points
- CLI reads config to find control port → calls HTTP API
- Service loads config at startup, FileSystemWatcher for hot-reload
- Config validation runs both at startup AND on hot-reload

## Canonical Refs

- `.planning/research/STACK.md` — Technology recommendations
- `.planning/research/ARCHITECTURE.md` — Module extraction and config patterns
- `.planning/codebase/CONVENTIONS.md` — Naming and code style patterns
- `config.json` — Current flat config structure (migration source)
- `config.default.json` — Current defaults file

## Deferred Ideas

- `cap config edit` — open config.json in user's $EDITOR (future CLI enhancement)
- JSON Schema file for IDE IntelliSense (nice-to-have, not in this phase)

---
*Generated: 2026-05-07 after discuss-phase*
