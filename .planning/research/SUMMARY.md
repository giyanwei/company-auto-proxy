# Project Research Summary

**Project:** Company Auto Proxy (CAP)
**Domain:** Windows proxy auto-switch / corporate network utility
**Researched:** 2026-05-06
**Confidence:** HIGH

## Executive Summary

Company Auto Proxy is a zero-dependency, PowerShell 5.1-based local proxy that auto-switches between corporate proxy and direct connections based on network context (WiFi SSID). The research consensus is clear: build on the existing foundation of PowerShell 5.1 + .NET Framework BCL with Windows Task Scheduler for persistence, extracting the current monolithic proxy-service.ps1 into a supervised multi-component model with a lightweight watchdog process, structured logging, and a circuit breaker for graceful fallback. No external packages are needed at runtime; the entire stack ships with Windows 10/11.

The recommended approach is to refactor the existing working code into well-bounded modules (Config, Logger, ProxyEngine, Fallback, NetworkMonitor, ControlAPI) before adding new capabilities. This "extract then extend" strategy de-risks the critical features (self-healing, fallback) by ensuring they are built on observable, testable components. The architecture keeps a single proxy service process with internal concurrency via RunspacePool, supervised by a separate watchdog process started via scheduled task.

The highest risk is the "bricked internet" problem: if the proxy process dies without restoring system proxy settings, all HTTP traffic fails system-wide. This single pitfall justifies the entire self-healing/watchdog design and must be the primary safety invariant. Secondary risks include PATH corruption during install, resource exhaustion from leaked TcpClient objects, and config corruption from unserialized writes. All are preventable with documented patterns (atomic writes, try/finally disposal, deduplication).

## Key Findings

### Recommended Stack

Pure PowerShell 5.1 with .NET Framework BCL. Zero external runtime dependencies. Everything ships with Windows 10/11.

**Core technologies:**
- **PowerShell 5.1**: Script runtime -- zero install requirement, every Windows 10/11 machine has it
- **.NET Framework 4.7.2+ BCL**: TCP/HTTP listeners, concurrent collections, timers, file system watchers -- all via `Add-Type`
- **Windows Task Scheduler**: Auto-start at logon + watchdog restart -- native OS facility, no admin for user-context tasks
- **JSON config + custom validation**: Settings storage -- PS 5.1 lacks `Test-Json`, custom validation gives better error messages
- **Pester 5.x** (dev only): Testing framework -- not shipped with the tool, only for contributors

### Expected Features

**Must have (table stakes):**
- Survive reboot without user intervention
- Graceful fallback to DIRECT when corporate proxy unreachable
- Config validation that catches typos before they break traffic
- Structured log file persistence (currently in-memory only)
- Self-healing restart after crashes
- Clean uninstall that removes ALL traces
- Single-command start/stop from any terminal

**Should have (differentiators):**
- Interactive installer wizard with proxy auto-detection from system settings
- Self-healing watchdog with exponential backoff
- Diagnostic export bundle (`cap diagnose`)
- Proactive upstream monitoring (switch to DIRECT before connections fail)
- Network change event subscription (instant reaction vs 30s polling)

**Defer (v2+):**
- Per-app proxy bypass (Proxifier territory)
- Shell-specific env propagation to running terminals
- Update mechanism (`cap update`)
- Multi-proxy failover (multiple upstream proxies)
- Toast notifications (requires complex COM or external dependency)

### Architecture Approach

Evolve from monolith to supervised multi-component model. The proxy service remains a single process (RunspacePool-based concurrency) but with extracted modules. A separate watchdog process supervises it. CLI, Tray, and Dashboard communicate exclusively via HTTP Control API.

**Major components:**
1. **Watchdog** (proxy-watchdog.ps1) -- spawns service, health-checks via TCP, restarts with backoff
2. **Config Module** -- load, validate, hot-reload via FileSystemWatcher with debounce
3. **Logger Module** -- structured JSON Lines output, rotation, level filtering, diagnostic export
4. **ProxyEngine** -- TCP listener, domain matching, route decision, byte relay
5. **Fallback / Circuit Breaker** -- per-upstream state machine (CLOSED/OPEN/HALF-OPEN)
6. **NetworkMonitor** -- WiFi SSID detection + upstream health probing
7. **ControlAPI** -- HTTP endpoints for runtime control (status, on/off, reload, logs)
8. **SystemProxy** -- registry manipulation + WinInet notification broadcast

### Critical Pitfalls

1. **Orphaned System Proxy** -- Process dies, registry still points to dead port, all internet breaks. Fix: watchdog detects dead port and restores pre-proxy state from recovery file.
2. **TcpClient/Runspace Resource Exhaustion** -- Leaked sockets and unbounded job lists under burst traffic. Fix: try/finally disposal everywhere, configurable pool size, connection timeout.
3. **Self-Healing Restart Loop** -- Watchdog without backoff creates CPU-thrashing infinite restart spiral. Fix: exponential backoff, crash budget (3 in 5min = stop), pre-restart validation.
4. **PATH Manipulation Corruption** -- Naive append can truncate or duplicate PATH entries. Fix: parse-deduplicate-rejoin, length check, store exact entry for clean removal.
5. **Config File Race Condition** -- Concurrent writes from multiple runspaces corrupt JSON. Fix: atomic write pattern (write to .tmp, validate, rename) + .bak fallback chain.

## Implications for Roadmap

### Phase 1: Module Extraction + Config Foundation
**Rationale:** Every subsequent feature depends on clean module boundaries. Config touches everything; getting it right early prevents compound bugs.
**Delivers:** Refactored codebase with extracted modules, validated config system with atomic writes, config.json removed from git tracking.
**Addresses:** Config validation (table stakes), idempotent config handling, encoding correctness.
**Avoids:** Pitfall #12 (config race condition), Pitfall #7 (encoding), Pitfall #19 (JSON depth), Pitfall #15 (credential leak).

### Phase 2: Structured Logging
**Rationale:** Must be in place before adding complex features (watchdog, fallback) because they need observability for debugging.
**Delivers:** JSON Lines structured logger with rotation, level filtering, diagnostic export, `/logs` endpoint.
**Addresses:** Log file persistence (table stakes), diagnostic export (differentiator).
**Avoids:** Pitfall #5 (resource exhaustion -- now detectable), Pitfall #17 (port conflict -- now diagnosable).

### Phase 3: Circuit Breaker + Graceful Fallback
**Rationale:** High user-facing value -- the "just works" promise. Depends on logging for observability and config for tunable thresholds.
**Delivers:** Per-upstream circuit breaker, automatic fallback to DIRECT, WinInet notification broadcast, health endpoint.
**Addresses:** Graceful fallback to DIRECT (table stakes), proactive upstream monitoring (differentiator).
**Avoids:** Pitfall #1 (orphaned proxy -- partially), Pitfall #3 (WinInet notification), Pitfall #10 (env var scope).

### Phase 4: Watchdog + Self-Healing
**Rationale:** Outer wrapper works best when inner service is stable and instrumented. This phase addresses the highest-severity pitfall.
**Delivers:** Watchdog process with TCP health checks, exponential backoff, crash recovery, pre-proxy state restoration.
**Addresses:** Self-healing (table stakes), survive reboot (hardening).
**Avoids:** Pitfall #1 (orphaned proxy -- fully), Pitfall #4 (restart loop), Pitfall #11 (mutex starvation).

### Phase 5: Interactive Installer
**Rationale:** Once runtime is reliable, build a proper installer. Installer quality is make-or-break for adoption.
**Delivers:** Guided setup wizard, proxy auto-detection, PATH management, scheduled task registration, dry-run mode, install manifest for clean reversal.
**Addresses:** Interactive installer (differentiator), idempotent install (table stakes), clean uninstall (table stakes).
**Avoids:** Pitfall #2 (PATH corruption), Pitfall #6 (execution policy), Pitfall #9 (partial install), Pitfall #13 (admin requirements), Pitfall #16 (uninstall PATH).

### Phase 6: Control Polish + Open-Source Readiness
**Rationale:** Distribution concerns come last -- only release publicly after the tool is self-healing and properly installable.
**Delivers:** CLI/Tray/Dashboard polish, notification improvements, security hardening (XSS fix, input sanitization), pre-commit hooks for credential leak prevention.
**Addresses:** Multiple trigger methods, error notifications, open-source hygiene.
**Avoids:** Pitfall #14 (profile pollution), Pitfall #15 (credential leak), Pitfall #21 (XSS).

### Phase Ordering Rationale

- **Config before logging** because log settings live in config; validated config prevents cascading failures.
- **Logging before fallback/watchdog** because both need observability to debug their own behavior.
- **Fallback before watchdog** because the watchdog's proxy-state-recovery behavior depends on the fallback module's understanding of upstream health.
- **Installer after runtime** because you cannot build a reliable installer for an unreliable runtime -- the installer needs to validate that the installed service actually works.
- **Open-source last** because security issues are amplified when code is public.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 4 (Watchdog):** `AppDomain.ProcessExit` reliability in PS 5.1, PID file vs named pipe for health checking, Task Scheduler recovery options configuration.
- **Phase 5 (Installer):** `WM_SETTINGCHANGE` broadcasting reliability, admin detection and graceful fallback to `HKCU:\...\Run`, script signing for enterprise environments.

Phases with standard patterns (skip research):
- **Phase 1 (Config):** Atomic writes, JSON validation, FileSystemWatcher -- all well-documented .NET BCL patterns.
- **Phase 2 (Logging):** Structured logging with rotation is a solved problem.
- **Phase 3 (Fallback):** Circuit breaker is an industry-standard pattern (Release It!).

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Verified against existing working code + .NET BCL documentation; zero-dependency constraint is clear |
| Features | MEDIUM | Based on training data knowledge of Proxifier/CNTLM/px-proxy; no live verification of competitor features |
| Architecture | HIGH | All patterns use .NET BCL classes already proven in the current codebase |
| Pitfalls | HIGH | Most pitfalls directly observed in existing code or documented in CONCERNS.md |

**Overall confidence:** HIGH

### Gaps to Address

- **WinInet InternetSetOption P/Invoke:** Needs testing across Windows 10/11 versions to confirm proxy notification reaches all apps (especially Edge, Chrome, corporate tools).
- **CIM event subscription for network changes:** Known to be fragile; may need fallback to polling. Validate during Phase 3 implementation.
- **Non-admin scheduled task registration:** `Register-ScheduledTask` behavior without admin needs validation. Fallback to `HKCU:\...\Run` registry key or Startup folder may be necessary.
- **Abandoned mutex handling in PS 5.1:** .NET's `AbandonedMutexException` handling through PowerShell is unclear. Validate or switch to PID-file-only approach.
- **Encoding behavior of PS 5.1 `-Encoding UTF8`:** Confirmed to include BOM; all file writes must use `[System.IO.File]::WriteAllText()` for BOM-free output. Needs consistent enforcement.

## Open Questions

1. **Admin rights model:** Should install require admin (for Task Scheduler) with daily use non-admin? Or should the tool work entirely without admin (using Startup folder / HKCU Run key)?
2. **Port conflict resolution:** Auto-select available port, or fail with clear error? Auto-select is more user-friendly but complicates the config story.
3. **Git global config:** Stop modifying git global config entirely (rely on HTTP_PROXY env var), or keep it with dynamic set/unset tied to proxy state?
4. **Multi-proxy support scope:** Is single upstream proxy sufficient for v1, or do users need failover to secondary proxy before falling back to DIRECT?
5. **Notification mechanism:** BalloonTip (deprecated but functional) vs MessageBox (blocking) -- when to use each? Is the user-annoyance tradeoff acceptable for critical failures?

## Sources

### Primary (HIGH confidence)
- Context7: `/microsoftdocs/powershell-docs` -- PS 5.1 capabilities, module patterns, Test-Json availability
- Context7: `/pester/docs` -- Pester 5.x testing patterns
- Direct codebase analysis: `src/proxy-service.ps1`, `src/proxy-cli.ps1`, `install.ps1`, `uninstall.ps1`
- `.planning/codebase/CONCERNS.md` -- existing known issues (validated against code)

### Secondary (MEDIUM confidence)
- Proxifier, CNTLM, px-proxy feature sets -- from training data, not live documentation
- Windows Service recovery patterns -- well-known but not verified against current docs
- oh-my-posh, scoop installer UX patterns -- from training data

### Tertiary (LOW confidence)
- WinInet InternetSetOption behavior across Windows versions -- needs live testing
- CIM event subscription reliability for network change detection -- anecdotal

---
*Research completed: 2026-05-06*
*Ready for roadmap: yes*
