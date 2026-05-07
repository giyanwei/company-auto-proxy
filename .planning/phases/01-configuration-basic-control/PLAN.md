# Phase 1 Plan: Configuration + Basic Control

**Phase:** 1
**Goal:** Every runtime behavior is driven by a validated config.json, and the user can immediately control and observe the proxy via CLI for daily use and testability
**Requirements:** CONF-01, CONF-02, CONF-03, CONF-04, CONF-05, CONF-06, CONF-07, CTRL-01, CTRL-04
**Planned:** 2026-05-07

## Plan Overview

Three plans executed sequentially:
1. **Config System** — Schema, validation, defaults, atomic writes, hot-reload
2. **CLI Refactor** — `cap on/off/start/stop/restart/status` with idempotent behavior
3. **Integration & Cleanup** — Wire config into service, remove legacy files, verify end-to-end

## Plan 1: Config System

**Goal:** Robust configuration system with schema validation, layered defaults, and hot-reload

### Tasks

#### 1.1 Create config schema and default file
- Define `config.default.json` with nested structure:
  - `proxy` section: `port`, `upstream_proxies`, `max_connections`
  - `network` section: `ssid_pattern`, `wifi_detection`, `auto_switch`, `detection_interval_sec`
  - `control` section: `port`, `dashboard_enabled`
  - `logging` section: `level`, `max_entries`
  - `behavior` section: `auto_start`, `install_path`
- Create `domains.json` as a separate file (current domain list is 238 lines)
- Write `config.schema.json` documenting each field's type, range, and description
- File: `src/config.default.json` (new structured format)
- File: `src/domains.json` (extracted from current config.json)
- File: `src/config.schema.json` (validation reference)

#### 1.2 Create Config module (src/modules/Config.ps1)
- `Initialize-Config` — load config.default.json, merge user config.json overrides (deep merge)
- `Test-ConfigValid` — validate merged config against schema rules:
  - Critical: port (1024-65535), upstream proxy URL format, control port
  - Lenient: log level fallback to "info", detection interval fallback to 30
  - Report ALL errors at once (collect then throw), not one-at-a-time
- `Save-Config` — atomic write pattern: write to `.tmp`, validate JSON roundtrip, rename to target
- `Merge-ConfigDefaults` — deep merge utility (user values win over defaults)
- File: `src/modules/Config.ps1`

#### 1.3 Create DomainMatcher module (src/modules/DomainMatcher.ps1)
- `Initialize-DomainSet` — build synchronized hashtable from domains.json
- `Test-DomainMatch` — exact match + subdomain match (existing logic extracted)
- `Add-Domain` / `Remove-Domain` — mutate domain set + persist to domains.json atomically
- File: `src/modules/DomainMatcher.ps1`

#### 1.4 Create SystemProxy module (src/modules/SystemProxy.ps1)
- `Enable-SystemProxy` — set registry + env vars (extracted from service)
- `Disable-SystemProxy` — clear registry + env vars (extracted from service)
- `Get-SystemProxyState` — read current registry state for status display
- File: `src/modules/SystemProxy.ps1`

#### 1.5 Implement FileSystemWatcher hot-reload
- Add to Config module: `Start-ConfigWatcher` function
- Watch both `config.json` and `domains.json` for changes
- Debounce 500ms via `System.Timers.Timer` (editors do write-rename)
- On invalid config: keep old config, log warning (no popup yet — Phase 2 adds logging)
- On valid config: update shared `$script:Config`, rebuild domain set if needed
- Port changes: log warning "Port change requires restart"
- File: extends `src/modules/Config.ps1`

#### 1.6 Migrate existing config.json format
- Write a one-time migration helper that converts flat config → nested structure
- Keep backward compatibility: if old flat format detected, auto-migrate and write new format
- Remove `src/config.json` from git tracking (add to .gitignore)
- File: migration logic in `src/modules/Config.ps1`

### Acceptance Criteria (Plan 1)
- [ ] `config.default.json` contains all fields with documented defaults in nested structure
- [ ] Loading with no user `config.json` produces a valid running config from defaults alone
- [ ] Invalid port (0, 99999, "abc") produces a clear multi-field error message
- [ ] Editing `config.json` while service runs triggers hot-reload within 1 second
- [ ] Domains live in separate `domains.json` file, loaded and hot-reloadable
- [ ] Atomic write prevents corruption on crash mid-save

---

## Plan 2: CLI Refactor

**Goal:** `cap on/off/start/stop/restart/status` works from any terminal with idempotent behavior and docker-style output

### Tasks

#### 2.1 Redesign CLI command routing
- `cap on` — enable proxy routing (set system proxy to local port). Auto-starts service if not running.
- `cap off` — disable proxy routing (clear system proxy). Service keeps running.
- `cap start` — start service if not running. Idempotent: "Already running." if running.
- `cap stop` — stop service gracefully. Idempotent: "Already stopped." if stopped.
- `cap restart` — stop + start (graceful restart)
- `cap status` — show full status; supports `--short` for minimal output
- `cap version` — show version
- `cap help` — show usage
- Remove old commands that are subsumed: `proxy on/off`, `settings show/set`, `config show/set/reset`, `domains list/add/remove`, `dashboard on/off`, `install`, `uninstall`, `reload`
- Preserve domain management: `cap domains list/add/remove`
- Preserve config management: `cap config show/set/reset/edit`
- File: `src/proxy-cli.ps1` (rewrite)

#### 2.2 Implement status output (docker/kubectl style)
- Default full output:
  ```
  ● Service: running    Mode: CORP    Uptime: 2h 15m
    Listen:    127.0.0.1:8081
    Control:   127.0.0.1:8082
    Network:   CORP (SSID: SAP-Corp)
    Requests:  47 total (32 proxied, 15 direct)
    Active:    3 connections
  ```
- `--short` output: `running CORP 2h15m` (single line for scripts)
- Stopped state: `○ Service: stopped`
- Colors: green=running, red=stopped/error, yellow=warning, cyan=info
- File: extends `src/proxy-cli.ps1`

#### 2.3 Fix TcpClient leak in connection check
- `Test-ServiceRunning` must dispose TcpClient in finally block
- Pattern: `try { $tcp = [TcpClient]::new(...); $tcp.Close(); $true } catch { $false }`
- File: `src/proxy-cli.ps1`

#### 2.4 Update bin/cap scripts for new CLI
- `bin/cap.ps1`, `bin/cap.cmd`, `bin/cap` — ensure they forward to new CLI correctly
- Map `cap on` → `proxy-cli.ps1 on` (direct, no subcommand nesting)
- File: `bin/cap.ps1`, `bin/cap.cmd`, `bin/cap`

### Acceptance Criteria (Plan 2)
- [ ] `cap on` from any terminal type (PS, cmd, Git Bash) enables system proxy
- [ ] `cap on` when service is stopped auto-starts it first
- [ ] `cap off` disables system proxy without stopping service
- [ ] `cap stop` when already stopped shows "Already stopped." (no error code)
- [ ] `cap start` when already running shows "Already running." (no error code)
- [ ] `cap status` shows service state, mode, uptime, connection stats
- [ ] `cap status --short` returns single parseable line

---

## Plan 3: Integration & Cleanup

**Goal:** Wire the new config system into the proxy service, remove legacy files, verify end-to-end

### Tasks

#### 3.1 Refactor proxy-service.ps1 to use modules
- Create `src/modules/` directory
- Dot-source Config, DomainMatcher, SystemProxy modules at startup
- Replace inline config loading with `Initialize-Config`
- Replace inline domain set building with `Initialize-DomainSet`
- Replace inline proxy enable/disable with module functions
- Start `Start-ConfigWatcher` in main script
- Keep RunspacePool, control API, and proxy handler as-is (service rewrite is not in scope)
- File: `src/proxy-service.ps1` (refactored)

#### 3.2 Update control API for new config structure
- `/status` — return nested config-derived values
- `/proxy/on` and `/proxy/off` — delegate to SystemProxy module (already modular)
- `/reload` — trigger config reload explicitly (in addition to FileSystemWatcher)
- `/config` — return effective merged config
- `/domains` — read from domains.json
- `/domains/add`, `/domains/remove` — delegate to DomainMatcher module with atomic save
- Remove settings endpoints that duplicate config (`/settings/wifi_detection`, `/settings/ssid_pattern`, `/settings/auto_start`) — config.json is now the single source of truth
- File: `src/proxy-service.ps1` (control API section)

#### 3.3 Remove legacy files
- Delete: `src/proxy-switch.ps1` (v1 polling proxy switch)
- Delete: `src/pac-server.ps1` (v1 PAC server)
- Delete: `src/proxy.pac.template` (v1 PAC template)
- Delete: `src/start-proxy-switch.vbs` (v1 VBS launcher)
- Delete: root `install.ps1` and `uninstall.ps1` (superseded by `cap install/uninstall`)
- Delete: `proxy.exe` and empty `internal/`/`cmd/` directories (dead Go artifacts)
- Delete: root `config.json`, `config.default.json`, `config.example.json` (consolidated into src/)
- Update `.gitignore`: add `src/config.json`, `*.pid`, `proxy.exe`
- File: multiple deletions

#### 3.4 Update README.md
- Document the new config structure (nested sections)
- Document CLI commands: `cap on/off/start/stop/restart/status`
- Remove references to legacy v1 approach
- Add quick-start section
- File: `README.md`

#### 3.5 End-to-end smoke test (manual verification)
- Start service via `cap start`
- Verify `cap status` shows running state
- Edit `config.json` → verify hot-reload (change SSID pattern, verify via status)
- `cap off` → verify system proxy cleared
- `cap on` → verify system proxy re-enabled
- `cap stop` → verify clean shutdown, system proxy cleared
- `cap start` when already running → "Already running."
- `cap stop` when stopped → "Already stopped."
- Test from cmd.exe: `cap status`
- Test from Git Bash: `cap status`

### Acceptance Criteria (Plan 3)
- [ ] Service starts using modular config system (Initialize-Config)
- [ ] Hot-reload works end-to-end (edit file → service picks up change)
- [ ] Legacy v1 files removed from repository
- [ ] `cap` command works from PowerShell, cmd.exe, and Git Bash
- [ ] Clean shutdown restores system proxy to pre-proxy state
- [ ] No regression: existing proxy routing (CONNECT tunneling, HTTP forwarding) still works

---

## Execution Order

```
Plan 1 (Config System)     ━━━━━━━━━━━━━━━━━━━━━━━━━
                                                      \
Plan 2 (CLI Refactor)      ━━━━━━━━━━━━━━━━━━━━━━━━━  } can overlap
                                                      /
Plan 3 (Integration)       ━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Plans 1 and 2 are independent and can be developed in parallel. Plan 3 depends on both being complete since it wires them together.

## Threat Model (Phase 1 scope)

| Threat | Mitigation |
|--------|-----------|
| Config corruption on crash mid-write | Atomic write pattern (write .tmp → validate → rename) |
| Invalid config bricks service | Tiered validation: critical fields fail-fast, optional fields fallback |
| Hot-reload applies partial config | Read entire file, validate entire file, then apply atomically |
| Race condition: two writers | Config writes use file lock attempt; second writer retries after delay |
| Domains.json grows unbounded | No hard limit (user manages manually); future: add max-domain-count warning |

## Dependencies

- **Blocks Phase 2:** Logging reads log_level from config system built here
- **Blocks Phase 3:** Fallback thresholds live in config
- **Blocks Phase 4:** Watchdog config (restart limits, health interval) in config
- **Blocks Phase 5:** Installer writes config.json as part of setup
- **Blocks Phase 6:** All control interfaces use config for port discovery

## Estimated Effort

| Plan | Tasks | Complexity | Estimate |
|------|-------|-----------|----------|
| Config System | 6 | Medium | ~2 sessions |
| CLI Refactor | 4 | Low-Medium | ~1 session |
| Integration & Cleanup | 5 | Medium | ~1-2 sessions |
| **Total** | **15** | | **~4-5 sessions** |

---
*Plan created: 2026-05-07*
*Plans: 3 | Tasks: 15 | Requirements covered: 9 (CONF-01 through CONF-07, CTRL-01, CTRL-04)*
