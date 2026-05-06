# Roadmap: Company Auto Proxy (CAP)

**Phases:** 6
**Granularity:** Standard
**Coverage:** 26/26 v1 requirements mapped

## Phases

- [ ] **Phase 1: Configuration + Basic Control** - Full config system with schema validation, hot-reload, defaults, plus testable CLI on/off/status
- [ ] **Phase 2: Structured Logging** - JSON Lines logging with rotation, level filtering, and diagnostic export
- [ ] **Phase 3: Graceful Fallback** - Circuit breaker pattern for automatic DIRECT fallback with auto-recovery
- [ ] **Phase 4: Watchdog & Self-Healing** - Supervisor process with health checks, crash recovery, and proxy state cleanup
- [ ] **Phase 5: Interactive Installer** - Guided setup wizard with PATH management, auto-start, and clean uninstall
- [ ] **Phase 6: Control Polish** - Tray icon toggle, dashboard button, and end-to-end test command

## Phase Details

### Phase 1: Configuration + Basic Control
**Goal**: Every runtime behavior is driven by a validated config.json, and the user can immediately control and observe the proxy via CLI for daily use and testability
**Depends on**: Nothing (first phase)
**Requirements**: CONF-01, CONF-02, CONF-03, CONF-04, CONF-05, CONF-06, CONF-07, CTRL-01, CTRL-04
**Success Criteria** (what must be TRUE):
  1. User can open config.json and understand every field via inline comments or companion schema doc
  2. User receives a clear, actionable error message when config contains invalid values (bad port, malformed URL, unknown key)
  3. User can edit config.json while proxy is running and see changes take effect within seconds without restart
  4. Default config works out of the box -- user only needs to set their corporate proxy URL and SSID
  5. User can run `cap on` and `cap off` from any terminal type (PowerShell, cmd, Git Bash) and proxy responds immediately
  6. User can run `cap status` and see current state (running/stopped), mode (CORP/DIRECT), and uptime
**Plans**: TBD
**Notes**: This is the foundation layer. Every subsequent phase reads settings from this config system. Including basic CLI control here enables immediate manual testing of all future phases without waiting for Phase 6. Use atomic write pattern (write .tmp, validate, rename) to prevent corruption. FileSystemWatcher with debounce for hot-reload.

### Phase 2: Structured Logging
**Goal**: All proxy activity is observable through structured, rotated log files that enable rapid diagnosis of issues
**Depends on**: Phase 1 (log settings live in config.json)
**Requirements**: LOG-01, LOG-02, LOG-03, LOG-04
**Success Criteria** (what must be TRUE):
  1. User can find a log file with timestamped JSON entries for every proxy connection, network change, and error
  2. User can set log level to "debug" in config.json and see verbose connection details; set to "error" and see only failures
  3. Log files never grow unbounded -- old logs are automatically rotated away, keeping disk usage predictable
  4. User can run `cap diagnose` and receive a single zip bundle containing recent logs, sanitized config, and network state snapshot
**Plans**: TBD
**Notes**: Must be in place before Phases 3-4 because fallback and watchdog need observability to debug their own behavior. JSON Lines format (one object per line) for easy parsing.

### Phase 3: Graceful Fallback
**Goal**: Internet connectivity never breaks because of the proxy -- when corporate proxy is unreachable, traffic flows direct automatically and recovers when the proxy returns
**Depends on**: Phase 1 (fallback thresholds in config), Phase 2 (fallback events logged)
**Requirements**: STAB-04, STAB-05, STAB-06, STAB-07
**Success Criteria** (what must be TRUE):
  1. User unplugs from corporate network and web browsing continues working within 5 seconds (no manual intervention)
  2. User reconnects to corporate network and traffic resumes routing through corporate proxy automatically
  3. User sees a popup notification when fallback activates, explaining what happened and that connectivity is maintained
  4. User can observe current mode (CORP/DIRECT) via `cap status` at any time
**Plans**: TBD
**Notes**: Implements circuit breaker pattern (CLOSED/OPEN/HALF-OPEN) per upstream. This delivers the core "just works" promise. Error popup mechanism (STAB-07) uses BalloonTip for non-blocking notifications.

### Phase 4: Watchdog & Self-Healing
**Goal**: The proxy survives crashes and reboots without leaving the system in a broken state -- if it dies, it comes back; if it cannot come back, it cleans up after itself
**Depends on**: Phase 1 (watchdog config), Phase 2 (crash events logged), Phase 3 (understands upstream health state)
**Requirements**: STAB-01, STAB-02, STAB-03
**Success Criteria** (what must be TRUE):
  1. User kills the proxy process and it automatically restarts within seconds without any user action
  2. If the proxy crashes repeatedly (5+ times in 10 minutes), the watchdog stops retrying and alerts the user instead of burning CPU
  3. After any crash or unclean exit, Windows system proxy settings are restored to pre-proxy state (no orphaned proxy pointing at dead port)
**Plans**: TBD
**Notes**: Addresses the highest-severity pitfall (orphaned system proxy = bricked internet). Watchdog is a separate lightweight process. Uses TCP health check against proxy port. Stores pre-proxy registry state in recovery file for guaranteed restoration.

### Phase 5: Interactive Installer
**Goal**: A new user can go from download to working proxy in under 2 minutes via a guided wizard that handles all system integration
**Depends on**: Phase 4 (installer needs to set up watchdog/scheduled task for a stable runtime)
**Requirements**: INST-01, INST-02, INST-03, INST-04, INST-05, INST-06
**Success Criteria** (what must be TRUE):
  1. User runs the installer and is guided through setup: proxy URL (auto-detected from registry), corporate SSID, shell preference, auto-start choice
  2. After install, user can type `cap status` in a new terminal window (PowerShell, cmd, or Git Bash) and get a response
  3. Running the installer a second time does not duplicate PATH entries, create extra scheduled tasks, or break the existing setup
  4. After running uninstall, no traces remain: no PATH entries, no scheduled tasks, no registry keys, no environment variables
**Plans**: TBD
**Notes**: Install manifest pattern -- record every change made during install so uninstall can reverse exactly those changes. PATH manipulation must parse-deduplicate-rejoin to avoid corruption. Admin detection with graceful fallback to user-context alternatives.

### Phase 6: Control Polish
**Goal**: Users can interact with the proxy through tray icon and dashboard, and validate connectivity end-to-end -- completing the multi-interface control story
**Depends on**: Phase 1-5 (all runtime capabilities stable, cap command in PATH)
**Requirements**: CTRL-02, CTRL-03, CTRL-05
**Success Criteria** (what must be TRUE):
  1. User can single-click the tray icon to toggle proxy state (no menu diving for the common action)
  2. Dashboard start/stop button reflects real-time proxy state and controls it without page refresh
  3. User can run `cap test` and get a pass/fail result confirming the full proxy chain works end-to-end before committing to proxy mode
**Plans**: TBD
**UI hint**: yes
**Notes**: All control interfaces communicate via the existing HTTP Control API (port 8082). This phase polishes GUI controls and adds the diagnostic test command. Focus on consistency across tray/dashboard interfaces.

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|---------------|--------|-----------|
| 1. Configuration + Basic Control | 0/? | Not started | - |
| 2. Structured Logging | 0/? | Not started | - |
| 3. Graceful Fallback | 0/? | Not started | - |
| 4. Watchdog & Self-Healing | 0/? | Not started | - |
| 5. Interactive Installer | 0/? | Not started | - |
| 6. Control Polish | 0/? | Not started | - |

## Coverage Validation

| Category | Requirements | Phase | Count |
|----------|-------------|-------|-------|
| Configuration | CONF-01, CONF-02, CONF-03, CONF-04, CONF-05, CONF-06, CONF-07 | Phase 1 | 7 |
| Control (Basic) | CTRL-01, CTRL-04 | Phase 1 | 2 |
| Logging | LOG-01, LOG-02, LOG-03, LOG-04 | Phase 2 | 4 |
| Stability (Fallback) | STAB-04, STAB-05, STAB-06, STAB-07 | Phase 3 | 4 |
| Stability (Self-Healing) | STAB-01, STAB-02, STAB-03 | Phase 4 | 3 |
| Installation | INST-01, INST-02, INST-03, INST-04, INST-05, INST-06 | Phase 5 | 6 |
| Control (Polish) | CTRL-02, CTRL-03, CTRL-05 | Phase 6 | 3 |

**Total mapped: 26/26 -- No orphans, no duplicates.**

---
*Roadmap created: 2026-05-06*
*Roadmap revised: 2026-05-06 -- moved CTRL-01, CTRL-04 into Phase 1 for testability*
*Granularity: standard | Phases: 6 | Mode: yolo*
