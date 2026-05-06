# Feature Landscape

**Domain:** Windows proxy auto-switch / corporate network utility
**Researched:** 2026-05-06
**Overall confidence:** MEDIUM (based on training data knowledge of Proxifier, CNTLM, px-proxy, Fiddler, Windows service patterns; web verification unavailable due to API issues)

## Table Stakes

Features users expect from a "configure once, forget about it" proxy tool. Missing any of these = the tool feels broken or requires constant babysitting.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Survive reboot** | Users expect utility to be there after restart without intervention | Low | Already have scheduled task; needs to be bulletproof |
| **Clean startup/shutdown** | No orphan processes, no stale registry entries, no leaked env vars | Low | Existing cleanup is good; add crash-state recovery |
| **Config validation on load** | Typo in config.json should not silently break everything | Low | JSON schema + meaningful error messages |
| **Graceful fallback to DIRECT** | When corporate proxy is unreachable, traffic should still flow | Medium | Critical for productivity; detect upstream timeout |
| **Status visibility** | User must always know: is proxy on? Which mode? Is it healthy? | Low | Tray icon color already does this well |
| **Single command start/stop** | `cap on` / `cap off` from any terminal, immediately | Low | Already exists; ensure PATH works from any shell |
| **Log file persistence** | Logs survive restarts, can be shared for debugging | Low | Currently in-memory only; need file output |
| **Auto-start toggle** | User can disable auto-start without uninstalling | Low | Already exists via settings API |
| **Connection test / health check** | Verify proxy chain works before committing to a mode | Medium | `cap test` command that validates end-to-end |
| **Idempotent install** | Running installer twice does not break anything | Low | Current install is mostly idempotent; formalize |
| **Clean uninstall** | Remove ALL traces: PATH, tasks, registry, env vars, profiles | Low | Already good; add verification step |

## Differentiators

Features that set this tool apart from alternatives. Not expected, but significantly valued by the target audience (developers behind corporate proxies).

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Interactive installer wizard** | Guides non-technical users; detects existing proxy config from system/browser | Medium | Ask: proxy URL, SSID pattern, shell preference, auto-start |
| **Self-healing watchdog** | Service restarts itself on crash; no manual intervention ever needed | Medium | Scheduled task with retry, PID file monitoring, heartbeat |
| **Structured diagnostic export** | `cap diagnose` bundles logs + config + network state for sharing | Medium | Developers love this for filing bug reports |
| **Proxy reachability monitoring** | Background pings to upstream proxy; switch to DIRECT before connections fail | High | Proactive vs reactive fallback |
| **Network change event subscription** | React to network changes instantly (not polling every 30s) | Medium | WMI/CIM event subscription vs polling |
| **Multi-proxy failover** | Try proxy A, if unreachable try proxy B, then DIRECT | Medium | Common in enterprise with multiple proxy endpoints |
| **Per-app proxy bypass** | Some apps (Teams, Outlook) already handle proxy; exclude them | High | Would need process-level routing (Proxifier territory) |
| **Popup notifications for state changes** | Toast notification when switching CORP/DIRECT or when fallback activates | Low | Balloon tips already exist; upgrade to toast for Win10/11 |
| **Config hot-reload** | Edit config.json, changes apply without restart | Low | `/reload` endpoint exists; add file watcher |
| **Shell-specific env propagation** | Update running terminals' env vars when proxy state changes | High | Very hard; signals/named pipes to running shells |
| **First-run detection** | Detect fresh install, offer guided setup, validate connectivity | Low | Check for config existence + first-run flag |
| **Update mechanism** | `cap update` to pull latest version from GitHub | Medium | Self-update for single-file tools is well-understood |

## Anti-Features

Features to explicitly NOT build. These add complexity without matching the tool's identity.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **GUI settings editor** | Power users prefer config files; GUI implies maintenance burden of forms/validation | Open config.json in editor; provide JSON schema for IntelliSense |
| **SSL/TLS certificate manipulation** | This is not a debugging proxy (Fiddler/Charles territory); MITM adds security concerns and trust issues | Pass CONNECT tunnels through transparently |
| **Per-request rule UI** | Proxifier-level rule building is a full product; we do domain-based routing only | Keep domain list in config.json; provide `cap domains add/remove` |
| **Authentication credential storage** | Storing NTLM/Kerberos creds is a security liability; CNTLM already does this well | Document how to chain with CNTLM for auth; or use Windows credential store |
| **Traffic inspection/logging body content** | Privacy concern; legal issues in corporate environments; performance hit | Log metadata only: host, method, timestamp, proxied/direct |
| **Multi-user/enterprise deployment** | Premature; adds GPO, centralized config, service account complexity | Keep single-user; document manual enterprise rollout if needed |
| **Cross-platform** | Dilutes Windows-specific quality; different proxy mechanisms per OS | Stay Windows-only; if demand grows, fork for macOS separately |
| **Browser extension** | Browsers handle PAC/system proxy already; extension adds attack surface | PAC server + system proxy interception covers browsers |
| **Proxy auto-discovery (WPAD)** | Enterprise IT already handles WPAD; implementing it adds DNS/DHCP complexity | Let users specify proxy URL explicitly; detect from system settings |
| **Bandwidth throttling** | Not the tool's purpose; adds TCP complexity | Out of scope entirely |

## Feature Complexity Matrix

Mapping planned features to implementation effort, risk, and dependencies.

### Milestone 2 Features (Active Requirements)

| Feature | Effort | Risk | Dependencies | Phase Recommendation |
|---------|--------|------|--------------|---------------------|
| **Full configurability + schema validation** | 2-3 days | Low | None | Phase 1 - Foundation for everything else |
| **Structured logging** | 2-3 days | Low | Config schema (log levels/paths in config) | Phase 1 - Needed for debugging all other features |
| **Interactive installer wizard** | 3-4 days | Medium | Config schema, shell detection | Phase 2 - Builds on finalized config structure |
| **Self-healing / watchdog** | 3-4 days | Medium | Logging (to know why crashes happen) | Phase 2 - Requires logging for diagnosis |
| **Graceful fallback** | 2-3 days | Medium | Logging, notifications | Phase 3 - Needs health monitoring infrastructure |
| **Error popup notifications** | 1-2 days | Low | Fallback logic (to know WHEN to notify) | Phase 3 - Triggered by fallback/errors |
| **Multiple trigger methods** | 1-2 days | Low | None (already mostly exists) | Phase 1 - Polish existing CLI/tray/dashboard |
| **Clean uninstall** | 1 day | Low | None | Phase 1 - Straightforward enhancement |

### Implementation Dependencies Graph

```
Config Schema Validation
    |
    +---> Structured Logging
    |         |
    |         +---> Self-Healing (needs logs to diagnose crashes)
    |         |         |
    |         |         +---> Watchdog Process
    |         |
    |         +---> Health Monitoring
    |                   |
    |                   +---> Graceful Fallback
    |                             |
    |                             +---> Error Notifications (popup on fallback)
    |
    +---> Interactive Installer (needs to write valid config)
    |
    +---> Multiple Triggers (already exist; just needs config for customization)
```

## Competitive Analysis

### What Proxifier Offers (Commercial, $40)
- Per-application proxy rules (process name matching)
- Proxy chains (proxy through multiple hops)
- DNS resolution control (resolve locally vs at proxy)
- Live connection monitor with bandwidth stats
- Flexible rule system (IP ranges, ports, hostnames, wildcards)
- Profile import/export
- SOCKS4/5, HTTP/HTTPS proxy support
- **Takeaway:** We do NOT compete here. Proxifier is a packet-level tool. CAP is "auto-switch for developers."

### What CNTLM Offers (Open source)
- NTLM/NTLMv2 authentication to upstream proxy
- Multiple upstream proxies with failover
- ACL rules for bypass
- Runs as Windows service
- Config file-based
- **Takeaway:** Complementary tool. CAP should document CNTLM integration for auth scenarios.

### What px-proxy Offers (Open source, Python)
- Auto-detect proxy from system/IE settings
- NTLM/Kerberos auth via SSPI (Windows native)
- Runs as background process
- PAC file parsing
- Multi-platform
- **Takeaway:** Closest competitor to CAP's use case. CAP differentiates with: network-aware switching, zero-dependency (no Python), system tray UX.

### What Windows Users Expect from System Utilities
Based on patterns from: winget, scoop, oh-my-posh, PowerToys, Windows Terminal:

1. **Silent background operation** - no terminal windows popping up
2. **System tray presence** - visible but not intrusive
3. **Settings persistence** - survives updates and reboots
4. **Sensible defaults** - works out of box with minimal config
5. **Non-admin daily use** - admin only for install
6. **Clean Windows integration** - Task Scheduler, registry, PATH
7. **Diagnostic commands** - `tool --version`, `tool diagnose`

## Self-Healing Patterns (from Windows Services and Mature Daemons)

What mature system services do when things go wrong:

| Pattern | How It Works | Applicability to CAP |
|---------|--------------|---------------------|
| **Service Recovery Options** | Windows Services have built-in "restart on failure" with configurable delays (1st: restart, 2nd: restart, 3rd: restart with longer delay) | Use Scheduled Task restart triggers + PID monitoring |
| **Heartbeat file** | Write timestamp to file every N seconds; external watcher detects stale heartbeat | Simple, works with scheduled task as watcher |
| **PID file with validation** | On start, check PID file; if process dead, clean up and restart | Already have PID file; add staleness check |
| **Graceful degradation** | If proxy upstream unreachable, fall back to DIRECT instead of failing all connections | Critical for user experience |
| **Crash counter with backoff** | Track consecutive crashes; increase restart delay (1s, 5s, 30s, 60s) to prevent crash loops | Prevents CPU thrashing on persistent failures |
| **State persistence** | Write state to disk before shutdown; restore on restart so users don't notice | Save proxy-enabled/disabled state |
| **Mutex protection** | Named mutex prevents duplicate instances | Already implemented |
| **Cleanup on abnormal exit** | Register cleanup handler for SIGTERM/process exit | Clear system proxy even on crash |

## Installer UX Patterns (from Popular PowerShell Tools)

What popular installers ask and how:

| Tool | Install Pattern | What They Ask |
|------|----------------|---------------|
| **oh-my-posh** | One-liner, auto-detects shell | Nothing; detects everything |
| **scoop** | One-liner, creates dirs | Nothing; uses defaults |
| **winget** | Built into Windows | Source preference |
| **Chocolatey** | One-liner + admin | Nothing; post-install config |
| **PSReadLine** | Module install | Nothing; auto-configures |

**Best practice for CAP installer:**
1. Detect existing proxy settings from IE/system registry
2. Ask only what cannot be auto-detected: SSID pattern for corporate WiFi
3. Show what will be changed (PATH, scheduled task, profile)
4. Offer "express" (all defaults) vs "custom" (choose options)
5. Validate connectivity at end (can reach proxy? can reach internet?)
6. Show clear summary of what was installed and how to use

### Minimal Interactive Questions:
```
1. Corporate proxy URL [auto-detected: http://proxy.corp:8080]: ___
2. Corporate WiFi SSID pattern [Company*]: ___
3. Install auto-start? [Y/n]: ___
4. Add to PATH? [Y/n]: ___
```

## Notification Patterns for Windows 10/11

| Method | Pros | Cons | Recommendation |
|--------|------|------|----------------|
| **BalloonTip (NotifyIcon)** | Already implemented; no dependencies; works in PS5.1 | Deprecated in Win10 (still works but redirects to Action Center); limited formatting | Use for now; upgrade later |
| **Toast Notifications (WinRT)** | Rich content, actions, images; native Win10/11 | Requires app identity or COM registration; complex from PowerShell | AVOID for now; too complex without dependencies |
| **BurntToast (PS module)** | Easy toast from PowerShell; rich formatting | External dependency (violates zero-dependency constraint) | AVOID; breaks constraints |
| **Windows.UI.Notifications (COM)** | Native API; no dependencies | Complex COM interop from PS; fragile across Windows versions | Future option |
| **Simple MessageBox popup** | Zero-dependency; always works; modal | Blocks UI thread; annoying if frequent | Use only for critical errors (proxy dead, fallback activated) |

**Recommendation:** 
- Use BalloonTip for informational notifications (state changes, mode switches)
- Use MessageBox for critical alerts requiring user attention (proxy unreachable, persistent failure)
- Do NOT use toast notifications unless willing to take BurntToast dependency

## MVP Feature Priority (This Milestone)

### Must Have (blocks other work or core to "configure once, forget" promise):
1. **Config schema validation** - prevents silent failures from typos
2. **Structured logging to file** - needed to debug everything else
3. **Graceful fallback to DIRECT** - core reliability feature
4. **Self-healing restart** - "forget about it" means it recovers from crashes
5. **Clean uninstall enhancement** - trust requires reversibility

### Should Have (significant UX improvement):
6. **Interactive installer** - reduces setup friction dramatically
7. **Error popup notifications** - user awareness when things go wrong
8. **Health check command** (`cap diagnose`) - self-service debugging

### Nice to Have (polish, can defer):
9. **Network event subscription** (replace 30s polling) - faster response
10. **Config hot-reload via file watcher** - convenience
11. **First-run guided setup** - one-time wizard

## Feature Dependencies on Architecture

| Feature | Requires |
|---------|----------|
| Schema validation | JSON schema definition; validation function |
| Structured logging | Log rotation logic; configurable paths/levels |
| Self-healing | Separate watchdog script OR scheduled task recovery settings |
| Graceful fallback | Upstream reachability test; connection timeout handling |
| Interactive installer | Shell detection; proxy auto-detection from registry |
| Notifications | Decision: BalloonTip vs MessageBox; notification throttling |
| Clean uninstall | Registry of all modifications made during install |

## Sources

- Proxifier documentation (proxifier.com/docs) - feature comparison (MEDIUM confidence, from training data)
- CNTLM documentation (cntlm.sourceforge.net) - authentication proxy features (MEDIUM confidence, from training data)
- px-proxy GitHub (github.com/genotrance/px) - auto-detection features (MEDIUM confidence, from training data)
- Windows Service Recovery documentation (learn.microsoft.com) - self-healing patterns (HIGH confidence, well-known Windows behavior)
- Windows Notification APIs (learn.microsoft.com) - BalloonTip, Toast, WinRT (HIGH confidence, well-documented)
- BurntToast module (github.com/Windos/BurntToast) - PS toast notifications (MEDIUM confidence, from training data)
- oh-my-posh, scoop installer patterns - UX patterns (HIGH confidence, widely used tools)

**Note:** Web search API was unavailable during research. All findings are based on training data knowledge of these tools (verified against existing codebase patterns where possible). Confidence is MEDIUM overall because no live verification was performed against current documentation.
