# Architecture

**Analysis Date:** 2026-05-06

## System Overview

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                        User Interfaces                                    │
├───────────────────┬───────────────────┬──────────────────────────────────┤
│   CLI (`cap`)     │  System Tray      │   Web Dashboard                  │
│  `bin/cap.ps1`    │ `src/proxy-tray`  │  `src/dashboard.html`            │
│  `bin/cap.cmd`    │  `.ps1`           │                                  │
│  `bin/cap`        │                   │                                  │
└────────┬──────────┴────────┬──────────┴───────────────┬──────────────────┘
         │                   │                          │
         ▼                   ▼                          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     Control API (HTTP on :8082)                           │
│            Embedded in `src/proxy-service.ps1` ($controlScriptBlock)      │
│  /status, /proxy/on, /proxy/off, /settings/*, /domains/*, /reload, etc.  │
└─────────────────────────────────────────┬───────────────────────────────┘
                                          │
                                          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                   Proxy Service Daemon                                    │
│                   `src/proxy-service.ps1`                                 │
│                                                                          │
│  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────────┐     │
│  │ TCP Listener     │  │ Domain Matcher   │  │ WiFi SSID Monitor  │     │
│  │ (:8081)          │  │ ($DomainSet)     │  │ (30s poll)         │     │
│  └────────┬─────────┘  └────────┬─────────┘  └────────┬───────────┘     │
│           │                      │                      │                │
│           ▼                      ▼                      ▼                │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │               RunspacePool (1-20 threads)                         │   │
│  │         Per-connection proxy handler ($proxyHandler)               │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────┬───────────────────────────────┘
                                          │
                    ┌─────────────────────┼─────────────────────┐
                    │                     │                     │
                    ▼                     ▼                     ▼
┌──────────────────────┐  ┌────────────────────┐  ┌────────────────────┐
│  Upstream Corporate  │  │  Direct Connection │  │  Windows Registry  │
│  Proxy               │  │  (DIRECT)          │  │  + Env Variables   │
│  (PROXY mode)        │  │                    │  │  (System Proxy)    │
└──────────────────────┘  └────────────────────┘  └────────────────────┘
```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| Proxy Service Daemon | Local HTTP/CONNECT proxy, domain routing, state management, WiFi monitoring | `src/proxy-service.ps1` |
| Control API | HTTP API for runtime control (embedded in service via RunspacePool) | `src/proxy-service.ps1` (lines 122-328) |
| CLI Tool | User-facing command interface, install/uninstall, config management | `src/proxy-cli.ps1` |
| System Tray | Windows notification area icon with status + menu controls | `src/proxy-tray.ps1` |
| Web Dashboard | Single-page HTML UI with real-time stats and controls | `src/dashboard.html` |
| Shell Integration (PS) | Per-prompt proxy env var sync from state file | `shell/powershell-profile-snippet.ps1` |
| Shell Integration (Bash) | Per-prompt proxy env var sync from state file | `shell/bashrc-snippet.sh` |
| CAP Shortcut | Cross-shell entry point dispatcher to proxy-cli.ps1 | `bin/cap.ps1`, `bin/cap.cmd`, `bin/cap` |
| PAC Server (legacy v1) | Serve proxy.pac file for browser autoconfiguration | `src/pac-server.ps1` |
| Proxy Switch (legacy v1) | SSID-poll loop that sets PAC URL + git/npm proxy config | `src/proxy-switch.ps1` |
| Legacy Installer | v1 install: PAC generation, shell snippets, scheduled task | `install.ps1` |
| Legacy Uninstaller | v1 cleanup: stop processes, remove task, clear settings | `uninstall.ps1` |

## Pattern Overview

**Overall:** Single-process daemon with embedded multi-threaded connection handling and HTTP control plane

**Key Characteristics:**
- Monolithic PowerShell script acts as both the proxy server and the control API
- RunspacePool provides concurrency (up to 20 parallel connection handlers)
- All communication between CLI/tray/dashboard and the service uses HTTP REST calls to `127.0.0.1:8082`
- Domain matching is done via an in-memory synchronized hashtable for O(1) exact-match + O(n) suffix-match
- System-wide interception via Windows registry proxy setting + environment variables

## Layers

**Presentation Layer:**
- Purpose: User interaction through CLI, system tray, and web dashboard
- Location: `src/proxy-cli.ps1`, `src/proxy-tray.ps1`, `src/dashboard.html`
- Contains: Command parsing, UI rendering, HTTP client calls to control API
- Depends on: Control API (HTTP)
- Used by: End users

**Control Layer (API):**
- Purpose: Runtime configuration, status queries, service lifecycle management
- Location: `src/proxy-service.ps1` ($controlScriptBlock, lines 122-328)
- Contains: HTTP listener on control_port, JSON endpoints, config persistence
- Depends on: Shared state ($script:State), config file, domain set
- Used by: CLI, Tray, Dashboard

**Proxy Layer (Data Plane):**
- Purpose: Accept TCP connections, parse HTTP/CONNECT requests, route traffic
- Location: `src/proxy-service.ps1` ($proxyHandler, lines 331-449)
- Contains: TCP accept loop, HTTP request forwarding, CONNECT tunnel relay
- Depends on: Domain matcher, upstream proxy URL, shared state
- Used by: Any application configured to use system proxy

**Domain Matching:**
- Purpose: Decide if a given hostname should be proxied or connected directly
- Location: `src/proxy-service.ps1` (Test-Match function, lines 334-341)
- Contains: Exact hashtable lookup + suffix matching loop
- Depends on: $script:DomainSet (synchronized hashtable)
- Used by: Proxy handler

**System Integration:**
- Purpose: Set/clear Windows system proxy, manage environment variables, scheduled tasks
- Location: `src/proxy-service.ps1` (Enable-SystemProxy, Disable-SystemProxy, Set-AutoStart)
- Contains: Registry writes, env var manipulation, scheduled task registration
- Depends on: Windows registry, Windows Task Scheduler
- Used by: Service startup/shutdown, control API

**Configuration:**
- Purpose: Persist user settings (ports, domains, WiFi pattern, flags)
- Location: `config.default.json`, `config.json`, `src/config.json`
- Contains: JSON configuration with domain groups, proxy addresses, feature flags
- Depends on: File system
- Used by: All components at startup; control API for live updates

## Data Flow

### Primary Request Path (CONNECT Tunnel - HTTPS)

1. Application sends `CONNECT host:443 HTTP/1.1` to `127.0.0.1:8081` (`src/proxy-service.ps1:492-493`)
2. TCP connection accepted, dispatched to RunspacePool handler (`src/proxy-service.ps1:494-504`)
3. Handler parses first line, extracts target host:port (`src/proxy-service.ps1:349-355`)
4. `Test-Match` checks hostname against DomainSet (`src/proxy-service.ps1:334-341`)
5. **If match (proxied):** Opens TCP to upstream corporate proxy, sends CONNECT, relays bidirectional (`src/proxy-service.ps1:369-386`)
6. **If no match (direct):** Opens TCP directly to target host, relays bidirectional (`src/proxy-service.ps1:388-398`)
7. Request logged to concurrent queue (`src/proxy-service.ps1:399-400`)

### Primary Request Path (HTTP - plain)

1. Application sends `GET http://host/path HTTP/1.1` to `127.0.0.1:8081` (`src/proxy-service.ps1:492-493`)
2. Handler parses URL, extracts hostname (`src/proxy-service.ps1:402-406`)
3. `Test-Match` determines routing (`src/proxy-service.ps1:406`)
4. **If match:** HttpClient with upstream WebProxy sends request (`src/proxy-service.ps1:411-413`)
5. **If no match:** HttpClient with UseProxy=false sends request directly (`src/proxy-service.ps1:415-416`)
6. Response headers and body streamed back to client (`src/proxy-service.ps1:423-436`)

### Control API Request Path

1. CLI/Tray/Dashboard sends HTTP GET to `127.0.0.1:8082/<path>` 
2. Control API listener (separate runspace) handles request (`src/proxy-service.ps1:132-138`)
3. Switch statement routes to handler based on path (`src/proxy-service.ps1:145-309`)
4. Handler reads/modifies shared state and/or config file
5. JSON response returned to caller

### WiFi SSID Detection Flow

1. Main loop checks every 30 seconds (`src/proxy-service.ps1:508-512`)
2. `Get-CurrentSSID` runs `netsh wlan show interfaces` (`src/proxy-service.ps1:99-105`)
3. SSID matched against configurable regex pattern
4. State.NetworkState updated to "CORP" or "OTHER"
5. When "OTHER", `Test-Match` always returns false (all traffic goes direct)

**State Management:**
- `$script:State` - Synchronized hashtable shared across all runspaces (running, proxy_enabled, counters, network_state, settings)
- `$script:DomainSet` - Synchronized hashtable of whitelisted domains
- `$script:LogBuffer` - ConcurrentQueue of recent request log entries (capped at log_max_entries)
- `config.json` - Persisted to disk on settings changes
- Windows Registry `HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings` - System proxy state
- User environment variables `HTTP_PROXY`, `HTTPS_PROXY` - Process-level proxy state

## Key Abstractions

**Synchronized State ($script:State):**
- Purpose: Thread-safe shared state between main loop, proxy handlers, and control API
- Examples: `src/proxy-service.ps1` lines 25-38
- Pattern: `[hashtable]::Synchronized(@{})` with Interlocked operations for counters

**Domain Set ($script:DomainSet):**
- Purpose: Fast domain lookup for routing decisions
- Examples: `src/proxy-service.ps1` lines 43-46
- Pattern: Synchronized hashtable with domain as key, exact + suffix matching

**RunspacePool:**
- Purpose: Parallel connection handling without blocking the main loop
- Examples: `src/proxy-service.ps1` lines 451-454
- Pattern: PowerShell runspace pool (1-20 threads), each connection gets its own runspace

**Control API (HTTP Listener):**
- Purpose: Decouple UI from service internals via REST
- Examples: `src/proxy-service.ps1` lines 122-328
- Pattern: Runs in its own runspace, shares state via synchronized objects

## Entry Points

**CLI Entry (`cap`):**
- Location: `bin/cap.ps1`, `bin/cap.cmd`, `bin/cap` (bash)
- Triggers: User runs `cap <command>` from terminal
- Responsibilities: Resolves path to `src/proxy-cli.ps1`, forwards all arguments

**Service Start:**
- Location: `src/proxy-service.ps1`
- Triggers: `cap start` (via proxy-cli.ps1), scheduled task at logon
- Responsibilities: Start proxy listener, control API, set system proxy, begin SSID monitoring

**Install:**
- Location: `src/proxy-cli.ps1` (install command, lines 281-334)
- Triggers: `cap install [-Mode cli|full]`
- Responsibilities: Copy files to install path, add to PATH, register scheduled task

**Legacy Install:**
- Location: `install.ps1`
- Triggers: Manual run of legacy v1 installer
- Responsibilities: Generate PAC, copy scripts, configure git/npm, register scheduled task, set up shell profiles

## Architectural Constraints

- **Threading:** RunspacePool with 1-20 threads for connection handlers; control API runs in a dedicated runspace; main loop polls on 20ms interval
- **Global state:** `$script:State`, `$script:DomainSet`, `$script:LogBuffer` are module-level synchronized objects shared across runspaces
- **Single instance:** Enforced via named Mutex `Global\CompanyProxyAutoServiceMutex` (`src/proxy-service.ps1:48-52`)
- **Windows-only:** Depends on Windows registry for system proxy, `netsh wlan` for SSID detection, Windows Task Scheduler for auto-start
- **Loopback-only listeners:** Both proxy (8081) and control API (8082) bind to 127.0.0.1 only
- **No authentication:** Control API has no auth; security relies on loopback binding

## Anti-Patterns

### Duplicated System Proxy Logic

**What happens:** The `Enable-SystemProxy`/`Disable-SystemProxy` logic is duplicated between the service main script (lines 59-76) and the control API scriptblock (lines 168-183)
**Why it's wrong:** Changes to proxy logic must be updated in two places; easy to introduce inconsistencies
**Do this instead:** Extract proxy management into a shared function or module that both contexts import

### Legacy Code Not Removed

**What happens:** `src/proxy-switch.ps1`, `src/pac-server.ps1`, `src/proxy.pac.template`, `src/start-proxy-switch.vbs`, `install.ps1`, `uninstall.ps1` remain in the repo despite being superseded by v2
**Why it's wrong:** New contributors may be confused about which components are active; maintenance burden
**Do this instead:** Move legacy files to a `legacy/` directory or remove them, with clear documentation about migration

### Config File Duplication

**What happens:** Three config files exist at the root (`config.json`, `config.default.json`, `config.example.json`) plus a runtime copy at `src/config.json`
**Why it's wrong:** Unclear which is the source of truth; `src/config.json` diverges from root configs
**Do this instead:** Single `config.default.json` as template, single `config.json` as user config (gitignored), with clear resolution chain

## Error Handling

**Strategy:** Fail-silently for non-critical operations; `$ErrorActionPreference = "Stop"` at script level with try/catch blocks around connection handling

**Patterns:**
- Connection handlers wrapped in try/catch/finally to ensure cleanup (`src/proxy-service.ps1:444-448`)
- Control API catches config read errors silently (`src/proxy-service.ps1:209-213`)
- CLI uses `Test-ServiceRunning` TCP check before issuing commands (`src/proxy-cli.ps1:53-59`)
- Graceful shutdown on `/stop`: stops listener, disables proxy, cleans PID file (`src/proxy-service.ps1:527-540`)

## Cross-Cutting Concerns

**Logging:** In-memory ConcurrentQueue (`$script:LogBuffer`) with configurable max entries. No file-based logging. Dashboard and `/api/logs` endpoint expose the log.

**Validation:** Minimal. Config is trusted as valid JSON. Domain names not validated. SSID pattern used as raw regex without error handling.

**Authentication:** None. Control API is unauthenticated, relying solely on loopback binding for security.

**Concurrency Control:** Named Mutex prevents multiple service instances. Synchronized hashtables for shared state. Interlocked operations for atomic counter increments.

---

*Architecture analysis: 2026-05-06*
