# Requirements: Company Auto Proxy (CAP)

**Defined:** 2026-05-06
**Core Value:** The proxy "just works" — automatic switching with zero manual intervention

## v1 Requirements

Requirements for this milestone. Each maps to roadmap phases.

### Configuration

- [ ] **CONF-01**: User can define all proxy settings in a single config.json with documented schema
- [ ] **CONF-02**: System validates config on load and reports clear errors for invalid entries
- [ ] **CONF-03**: Config changes apply without restart (hot-reload via file watcher)
- [ ] **CONF-04**: User can configure proxy rules: domain lists, bypass patterns, upstream proxy URLs
- [ ] **CONF-05**: User can configure network detection: SSID patterns, detection interval, network test URL
- [ ] **CONF-06**: User can configure behavior: auto-start, log level, dashboard port, notification preferences
- [ ] **CONF-07**: Default config ships with sensible values; user only overrides what they need

### Logging

- [ ] **LOG-01**: All proxy events written to structured log file (JSON Lines format)
- [ ] **LOG-02**: User can configure log level (debug/info/warn/error) in config.json
- [ ] **LOG-03**: Log files rotate by size (configurable, default 10MB, keep last 5)
- [ ] **LOG-04**: User can export diagnostic bundle via `cap diagnose` (logs + config + network state)

### Stability

- [ ] **STAB-01**: Watchdog process monitors proxy health and auto-restarts on crash
- [ ] **STAB-02**: Watchdog uses exponential backoff (max 5 restarts in 10 minutes) to prevent restart loops
- [ ] **STAB-03**: On proxy crash, system proxy settings are cleaned up (no orphaned proxy)
- [ ] **STAB-04**: Proxy gracefully falls back to DIRECT when corporate proxy is unreachable
- [ ] **STAB-05**: Fallback activates within 5 seconds of detecting upstream proxy failure
- [ ] **STAB-06**: Proxy auto-recovers to corporate proxy when it becomes reachable again
- [ ] **STAB-07**: Error popup notification displayed when fallback activates or proxy encounters errors

### Installation

- [ ] **INST-01**: Interactive installer wizard guides user through setup (proxy URL, SSID, shell, auto-start)
- [ ] **INST-02**: Installer auto-detects existing proxy settings from Windows registry
- [ ] **INST-03**: Installer adds `cap` to user PATH (PowerShell, cmd, Git Bash)
- [ ] **INST-04**: Installer configures auto-start via Task Scheduler (user-context, no admin)
- [ ] **INST-05**: Install is idempotent — running twice does not break existing setup
- [ ] **INST-06**: Clean uninstall removes all traces: PATH entries, scheduled tasks, registry keys, env vars

### Control

- [ ] **CTRL-01**: User can start/stop proxy via `cap on` / `cap off` from any terminal
- [ ] **CTRL-02**: User can toggle proxy via single tray icon click
- [ ] **CTRL-03**: User can start/stop proxy from web dashboard control panel
- [ ] **CTRL-04**: `cap status` shows current state, mode (CORP/DIRECT), uptime, connection count
- [ ] **CTRL-05**: `cap test` validates proxy chain works end-to-end before committing

## v2 Requirements

Deferred to future milestone. Tracked but not in current roadmap.

### Distribution

- **DIST-01**: Package for scoop/winget/chocolatey
- **DIST-02**: `cap update` self-update from GitHub releases
- **DIST-03**: Authenticode code signing for script trust

### Advanced Features

- **ADV-01**: Network change event subscription (instant vs 30s polling)
- **ADV-02**: Multi-proxy failover (try A, then B, then DIRECT)
- **ADV-03**: First-run guided setup detection
- **ADV-04**: `cap domains add/remove` CLI for quick domain list edits

## Out of Scope

| Feature | Reason |
|---------|--------|
| SSL/TLS interception | Not a debugging proxy; MITM adds security concerns |
| Per-app process routing | Proxifier territory; keep it simple with domain-based routing |
| GUI settings editor | Power users prefer config files; provide JSON schema for IDE IntelliSense |
| Credential storage | Security liability; document CNTLM chaining instead |
| Traffic body logging | Privacy/legal concerns in corporate environments |
| Cross-platform | Windows-specific quality over breadth |
| Browser extension | PAC server + system proxy already covers browsers |
| WPAD auto-discovery | Enterprise IT handles this; explicit config is simpler |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| CONF-01 | Phase 1 | Pending |
| CONF-02 | Phase 1 | Pending |
| CONF-03 | Phase 1 | Pending |
| CONF-04 | Phase 1 | Pending |
| CONF-05 | Phase 1 | Pending |
| CONF-06 | Phase 1 | Pending |
| CONF-07 | Phase 1 | Pending |
| LOG-01 | Phase 2 | Pending |
| LOG-02 | Phase 2 | Pending |
| LOG-03 | Phase 2 | Pending |
| LOG-04 | Phase 2 | Pending |
| STAB-01 | Phase 4 | Pending |
| STAB-02 | Phase 4 | Pending |
| STAB-03 | Phase 4 | Pending |
| STAB-04 | Phase 3 | Pending |
| STAB-05 | Phase 3 | Pending |
| STAB-06 | Phase 3 | Pending |
| STAB-07 | Phase 3 | Pending |
| INST-01 | Phase 5 | Pending |
| INST-02 | Phase 5 | Pending |
| INST-03 | Phase 5 | Pending |
| INST-04 | Phase 5 | Pending |
| INST-05 | Phase 5 | Pending |
| INST-06 | Phase 5 | Pending |
| CTRL-01 | Phase 6 | Pending |
| CTRL-02 | Phase 6 | Pending |
| CTRL-03 | Phase 6 | Pending |
| CTRL-04 | Phase 6 | Pending |
| CTRL-05 | Phase 6 | Pending |

**Coverage:**
- v1 requirements: 26 total
- Mapped to phases: 26
- Unmapped: 0 ✓

---
*Requirements defined: 2026-05-06*
*Last updated: 2026-05-06 after initial definition*
