# Architecture Patterns

**Domain:** Windows proxy auto-switch tool (self-healing, configurable)
**Researched:** 2026-05-06
**Confidence:** HIGH (based on .NET/PowerShell platform capabilities, current codebase analysis, established patterns)

## Recommended Architecture

Evolve from the current monolith to a **supervised multi-component** model. The proxy service remains the core, but extract cross-cutting concerns into separate modules and add a lightweight watchdog as a parent process.

```text
                    ┌─────────────────────────────┐
                    │       Watchdog Process       │
                    │   (cap-watchdog.ps1)         │
                    │                              │
                    │  - Spawns proxy service      │
                    │  - Health-checks via TCP     │
                    │  - Restarts on crash         │
                    │  - Writes health log         │
                    └──────────────┬───────────────┘
                                   │ spawns & monitors
                                   ▼
┌──────────────────────────────────────────────────────────────────────┐
│                     Proxy Service Process                              │
│                     (proxy-service.ps1)                                │
│                                                                       │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────────┐  │
│  │ Config Module│  │ Logger Module│  │ Fallback / Circuit Breaker │  │
│  │ (hot-reload) │  │ (structured) │  │ (per upstream proxy)       │  │
│  └──────┬───────┘  └──────┬───────┘  └──────────────┬─────────────┘  │
│         │                  │                         │                │
│  ┌──────┴──────────────────┴─────────────────────────┴─────────────┐  │
│  │                     Core Proxy Engine                             │  │
│  │  TCP Listener → Domain Matcher → Route Decision → Relay          │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │              Control API (HTTP :8082)                              │  │
│  │  /status  /proxy/on|off  /config/reload  /health  /logs           │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │              Network Monitor                                       │  │
│  │  WiFi SSID detection + upstream proxy health check                │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
         ▲                    ▲                     ▲
         │ HTTP API           │ HTTP API            │ HTTP API
┌────────┴───┐    ┌──────────┴───────┐    ┌───────┴──────────┐
│  CLI (cap) │    │  System Tray     │    │  Web Dashboard   │
└────────────┘    └──────────────────┘    └──────────────────┘
```

**Key architectural decisions:**

1. **Watchdog is a separate process, not a Windows Service** -- because the tool must work without admin rights. A scheduled task at logon starts the watchdog, which in turn spawns and supervises the proxy service.

2. **Keep the service as a single process** -- do not split proxy and control API into separate processes. The RunspacePool pattern works well and shared-memory state via synchronized hashtables is simpler and faster than IPC between processes.

3. **Extract modules via dot-sourcing** -- break the monolith into logical files that are dot-sourced at startup. This improves maintainability without changing the runtime model.

4. **HTTP API remains the IPC mechanism** -- named pipes are more efficient but HTTP is already working, debuggable with curl, and the overhead is negligible at this scale (local loopback, infrequent control calls).

5. **Config hot-reload via FileSystemWatcher + API endpoint** -- dual mechanism: file changes trigger automatic reload, AND explicit `/config/reload` API endpoint for programmatic control.

---

## Component Boundaries

### Module Layout (file structure)

```
src/
├── proxy-service.ps1          # Entry point: loads modules, runs main loop
├── proxy-cli.ps1              # CLI interface (unchanged role)
├── proxy-tray.ps1             # System tray (unchanged role)
├── proxy-watchdog.ps1         # NEW: watchdog/supervisor process
├── dashboard.html             # Web dashboard (unchanged)
├── modules/
│   ├── Config.ps1             # Config loading, validation, hot-reload
│   ├── Logger.ps1             # Structured logging, rotation, export
│   ├── ProxyEngine.ps1        # TCP listener, connection handler, relay
│   ├── DomainMatcher.ps1      # Domain set management, matching logic
│   ├── NetworkMonitor.ps1     # WiFi SSID detection, upstream health
│   ├── Fallback.ps1           # Circuit breaker, fallback logic
│   ├── SystemProxy.ps1        # Registry/env var management
│   └── ControlAPI.ps1         # HTTP control API scriptblock
└── config.schema.json         # JSON Schema for validation
```

### Component Responsibility Matrix

| Component | Responsibility | State Owned | Communicates With |
|-----------|---------------|-------------|-------------------|
| **Watchdog** | Spawn service, health-check, restart on crash, health log | Own PID file, restart count | Service (TCP probe to control port) |
| **Config Module** | Load, validate, merge defaults, watch for changes, notify | Config object, FileSystemWatcher | All modules (publish changed config) |
| **Logger Module** | Structured log entries, rotation, level filtering, export | Log buffer, log file handle | All modules (they call Logger) |
| **ProxyEngine** | Accept TCP, parse HTTP/CONNECT, relay bytes | RunspacePool, active connections | DomainMatcher, Fallback, Logger |
| **DomainMatcher** | Determine if domain should be proxied | Synchronized domain hashtable | ProxyEngine (called by) |
| **NetworkMonitor** | Detect WiFi SSID, probe upstream proxy health | Network state, last check time | Fallback (triggers state change) |
| **Fallback** | Circuit breaker per upstream, failover logic | Breaker state per proxy | ProxyEngine (routing decision), Logger |
| **SystemProxy** | Set/clear Windows registry and env vars | None (writes to registry) | Config (reads proxy_port) |
| **ControlAPI** | HTTP endpoints for runtime control | HTTP listener | All modules (orchestrates) |
| **CLI** | User commands, display output | None (stateless client) | ControlAPI (HTTP calls) |
| **Tray** | Status icon, context menu | Icon state | ControlAPI (HTTP calls) |
| **Dashboard** | Browser-based status and controls | None (fetches via AJAX) | ControlAPI (HTTP calls) |

### Interaction Rules

1. **CLI/Tray/Dashboard never touch service internals** -- they only communicate via the Control API over HTTP.
2. **Modules communicate via shared state objects** -- not by calling each other's internal functions. The proxy-service.ps1 main script wires everything together.
3. **Config changes propagate via callback pattern** -- when Config module detects a change, it updates the shared config object. Modules that need to react check config state on their next cycle.
4. **Logger is fire-and-forget** -- modules call `Write-ProxyLog` and never wait for I/O completion. Logs buffer in memory and flush asynchronously.

---

## Data Flow

### Watchdog Supervision Flow

```
1. Scheduled task at logon runs: proxy-watchdog.ps1
2. Watchdog checks: is service already running? (TCP probe to control_port)
3. If not running: spawn proxy-service.ps1 as hidden process
4. Health loop (every 10 seconds):
   a. TCP connect to control_port
   b. If fails 3 consecutive times → declare dead
   c. Kill stale process if PID file exists
   d. Respawn proxy-service.ps1
   e. Log restart event (timestamp, attempt #, reason)
5. Watchdog itself is kept alive by scheduled task
   (Task Scheduler has built-in restart-on-failure for tasks)
6. Exponential backoff: if service crashes 5 times in 5 minutes,
   wait 60 seconds before next restart, notify user via popup
```

**Why this approach:** Windows Task Scheduler already provides watchdog-like capability (restart on failure, run at logon). Rather than relying solely on it, we add a lightweight watchdog process that provides faster detection (10s vs Task Scheduler's minimum 1-minute granularity) and richer behavior (backoff, notifications, health logging).

### Config Hot-Reload Flow

```
1. FileSystemWatcher monitors config.json
2. On change event:
   a. Debounce: wait 500ms for writes to complete (editors do write-rename-replace)
   b. Read new config file
   c. Validate against schema (reject invalid configs silently, keep old)
   d. Diff against current config
   e. Update shared $script:Config object
   f. If domains changed: rebuild DomainSet hashtable
   g. If ports changed: log warning (requires restart)
   h. If log settings changed: update Logger
   i. Emit log entry: "Config reloaded: [changed keys]"
3. Alternatively: POST /config/reload triggers same logic manually
4. GET /config returns current effective config (for CLI display)
```

**Debounce is critical:** FileSystemWatcher fires multiple events per save (especially with editors that use temp files). Use a timer that resets on each event and only fires the reload after 500ms of quiet.

### Fallback / Circuit Breaker Flow

```
State machine per upstream proxy:

  CLOSED (normal) ──[failure]──► OPEN (bypassing)
       ▲                              │
       │                              │ [timeout: 30s]
       │                              ▼
       └──────[success]───── HALF-OPEN (probing)

CLOSED state:
  - All matching requests route through upstream proxy
  - Track consecutive failures (TCP connect timeout, HTTP 502/503)
  - After 3 consecutive failures → transition to OPEN

OPEN state:
  - All requests go DIRECT (bypass failed proxy)
  - Show notification to user: "Corporate proxy unreachable, using direct"
  - After 30 seconds → transition to HALF-OPEN

HALF-OPEN state:
  - Send next request through upstream proxy as a probe
  - If succeeds → transition to CLOSED, notify "Proxy recovered"
  - If fails → transition back to OPEN, reset timer

Multiple upstreams:
  - Each upstream has its own circuit breaker
  - If primary is OPEN, try secondary (if configured)
  - If all are OPEN, go DIRECT
```

**Why circuit breaker, not simple retry:** Retrying every request through a dead proxy adds latency to every connection. Circuit breaker fails fast and provides predictable degradation.

### Structured Logging Flow

```
Log entry structure:
{
  "ts": "2026-05-06T10:30:00.123Z",   // ISO 8601
  "level": "info",                      // debug|info|warn|error
  "component": "proxy",                 // proxy|config|network|control|watchdog
  "msg": "Connection proxied",
  "data": { "host": "github.com", "upstream": "proxy.corp:8080", "ms": 42 }
}

Pipeline:
  Module → Write-ProxyLog(level, component, msg, data)
    → Filter by configured level (default: info)
    → Add to ConcurrentQueue (in-memory ring buffer, 1000 entries)
    → If file logging enabled: append to log file (async)
    → If error level: increment error counter in State

Log rotation:
  - Check file size on each write (or every 100 writes for performance)
  - If > max_size (default 10MB): rename to .1, start new file
  - Keep max 3 rotated files (configurable)
  - On diagnostic export: zip all logs + current config + status snapshot
```

### Request Processing Flow (updated with fallback)

```
1. TCP connection accepted on :8081
2. Parse first line → extract target host
3. DomainMatcher.Test-Match(host) → { proxied: true/false }
4. If proxied AND network is CORP:
   a. Check circuit breaker state for primary upstream
   b. If CLOSED or HALF-OPEN: route through upstream
   c. If OPEN: check secondary upstream (same logic)
   d. If all OPEN: route DIRECT, log warning
5. If not proxied OR network is OTHER:
   a. Route DIRECT
6. On connection result:
   a. If success: report success to circuit breaker
   b. If failure (timeout, refused): report failure to circuit breaker
7. Log request with timing, route decision, and outcome
```

---

## Patterns to Follow

### Pattern 1: Module Dot-Sourcing with Initialization

PowerShell modules (`.psm1`) require explicit import and have scope complexities with runspaces. For this project, dot-sourced script files (`.ps1`) are simpler and work naturally with the existing RunspacePool pattern.

```powershell
# proxy-service.ps1 (entry point)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulesDir = Join-Path $scriptDir "modules"

# Load modules (order matters for dependencies)
. (Join-Path $modulesDir "Logger.ps1")
. (Join-Path $modulesDir "Config.ps1")
. (Join-Path $modulesDir "DomainMatcher.ps1")
. (Join-Path $modulesDir "SystemProxy.ps1")
. (Join-Path $modulesDir "Fallback.ps1")
. (Join-Path $modulesDir "NetworkMonitor.ps1")
. (Join-Path $modulesDir "ProxyEngine.ps1")
. (Join-Path $modulesDir "ControlAPI.ps1")

# Initialize shared state
$script:State = Initialize-ProxyState -Config $script:Config
$script:DomainSet = Initialize-DomainSet -Config $script:Config

# Start components
Start-ConfigWatcher -Path $configFile -OnReload { param($newConfig) ... }
Start-ControlAPI -State $script:State -Config $script:Config
Start-ProxyListener -State $script:State -Config $script:Config
```

**Caveat for RunspacePool:** Dot-sourced functions are not automatically available inside runspace scriptblocks. The proxy handler and control API scriptblocks must be self-contained or receive dependencies as arguments (the current pattern of passing shared objects as `AddArgument()` is correct).

### Pattern 2: FileSystemWatcher with Debounce

```powershell
function Start-ConfigWatcher {
    param(
        [string]$Path,
        [scriptblock]$OnReload
    )
    $dir = Split-Path -Parent $Path
    $file = Split-Path -Leaf $Path
    $watcher = [System.IO.FileSystemWatcher]::new($dir, $file)
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite

    $timer = [System.Timers.Timer]::new(500)  # 500ms debounce
    $timer.AutoReset = $false

    Register-ObjectEvent -InputObject $watcher -EventName Changed -Action {
        $timer.Stop()
        $timer.Start()
    }

    Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action {
        try {
            $newContent = Get-Content $Path -Raw | ConvertFrom-Json
            # Validate before applying
            if (Test-ConfigValid -Config $newContent) {
                & $OnReload $newContent
                Write-ProxyLog -Level info -Component config -Msg "Config reloaded"
            } else {
                Write-ProxyLog -Level warn -Component config -Msg "Invalid config, keeping previous"
            }
        } catch {
            Write-ProxyLog -Level error -Component config -Msg "Config reload failed: $_"
        }
    }

    $watcher.EnableRaisingEvents = $true
    return $watcher
}
```

### Pattern 3: Circuit Breaker State Machine

```powershell
function New-CircuitBreaker {
    param(
        [string]$Name,
        [int]$FailureThreshold = 3,
        [int]$RecoveryTimeoutSec = 30
    )
    return [hashtable]::Synchronized(@{
        Name = $Name
        State = "CLOSED"           # CLOSED | OPEN | HALF_OPEN
        Failures = 0
        FailureThreshold = $FailureThreshold
        LastFailureTime = $null
        RecoveryTimeout = $RecoveryTimeoutSec
    })
}

function Test-CircuitAllows {
    param([hashtable]$Breaker)
    switch ($Breaker.State) {
        "CLOSED"    { return $true }
        "OPEN"      {
            $elapsed = ([DateTime]::UtcNow - $Breaker.LastFailureTime).TotalSeconds
            if ($elapsed -ge $Breaker.RecoveryTimeout) {
                $Breaker.State = "HALF_OPEN"
                return $true  # allow one probe
            }
            return $false
        }
        "HALF_OPEN" { return $true }  # allow probe request
    }
}

function Report-CircuitSuccess {
    param([hashtable]$Breaker)
    $Breaker.Failures = 0
    $Breaker.State = "CLOSED"
}

function Report-CircuitFailure {
    param([hashtable]$Breaker)
    $Breaker.Failures++
    $Breaker.LastFailureTime = [DateTime]::UtcNow
    if ($Breaker.Failures -ge $Breaker.FailureThreshold) {
        $Breaker.State = "OPEN"
    }
}
```

### Pattern 4: Watchdog with Exponential Backoff

```powershell
# proxy-watchdog.ps1
param([string]$ServiceScript)

$maxRestarts = 5
$windowSeconds = 300  # 5 minute window
$restartHistory = [System.Collections.Generic.List[DateTime]]::new()
$baseDelay = 2  # seconds

while ($true) {
    # Spawn service
    $proc = Start-Process powershell -ArgumentList @(
        "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
        "-File", $ServiceScript
    ) -PassThru -WindowStyle Hidden

    # Monitor loop
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 10
        # Also verify TCP is responsive (not just process alive)
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $tcp.Connect("127.0.0.1", $controlPort)
            $tcp.Close()
        } catch {
            # Process alive but not responsive - give it a moment
            Start-Sleep -Seconds 5
            # Recheck
            try {
                $tcp = [System.Net.Sockets.TcpClient]::new()
                $tcp.Connect("127.0.0.1", $controlPort)
                $tcp.Close()
            } catch {
                # Kill unresponsive process
                $proc | Stop-Process -Force -ErrorAction SilentlyContinue
                break
            }
        }
    }

    # Service died - record and assess
    $now = [DateTime]::UtcNow
    $restartHistory.Add($now)

    # Prune old entries outside window
    $restartHistory.RemoveAll({ param($t) ($now - $t).TotalSeconds -gt $windowSeconds })

    if ($restartHistory.Count -ge $maxRestarts) {
        # Too many restarts - back off
        $delay = [Math]::Min(60, $baseDelay * [Math]::Pow(2, $restartHistory.Count - $maxRestarts))
        Write-ProxyLog -Level error -Component watchdog -Msg "Service crashed $($restartHistory.Count) times in ${windowSeconds}s, waiting ${delay}s"
        # Show notification to user
        Show-BalloonTip "Proxy Error" "Service is crashing repeatedly. Waiting before restart."
        Start-Sleep -Seconds $delay
    } else {
        Start-Sleep -Seconds $baseDelay
    }
}
```

### Pattern 5: Structured Log Writer

```powershell
function Write-ProxyLog {
    param(
        [ValidateSet("debug","info","warn","error")]
        [string]$Level = "info",
        [string]$Component = "general",
        [string]$Msg,
        [hashtable]$Data = @{}
    )

    # Level filtering
    $levels = @{ debug=0; info=1; warn=2; error=3 }
    $minLevel = $levels[$script:Config.log_level ?? "info"]
    if ($levels[$Level] -lt $minLevel) { return }

    $entry = @{
        ts = [DateTime]::UtcNow.ToString("o")
        level = $Level
        component = $Component
        msg = $Msg
        data = $Data
    }

    # In-memory buffer (ring buffer behavior)
    $script:LogBuffer.Enqueue($entry)
    while ($script:LogBuffer.Count -gt $script:LogMax) {
        $null = $script:LogBuffer.TryDequeue([ref]$null)
    }

    # File output (if configured)
    if ($script:LogFilePath) {
        $json = $entry | ConvertTo-Json -Compress
        [System.IO.File]::AppendAllText($script:LogFilePath, "$json`n")
    }
}
```

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Over-Splitting into Separate Processes

**What:** Running watchdog, proxy, control API, and config watcher as separate processes communicating via IPC.
**Why bad:** Massively increases complexity for a single-user desktop tool. Named pipes or sockets between 4+ processes is fragile, hard to debug, and unnecessary at this scale.
**Instead:** Keep proxy service as ONE process with internal concurrency (RunspacePool). Only the watchdog is a separate process because its job is to monitor the service process lifecycle.

### Anti-Pattern 2: Using PowerShell Modules (.psm1) for Runspace-Shared Code

**What:** Creating formal PowerShell modules and trying to import them into each runspace.
**Why bad:** PowerShell runspaces do not automatically inherit module state. You would need to explicitly import modules in every scriptblock, and module-scoped variables are not shared across runspaces.
**Instead:** Use dot-sourced `.ps1` files for the main process. For runspace scriptblocks, keep them self-contained and pass shared state as arguments (current pattern is correct).

### Anti-Pattern 3: Polling for Config Changes

**What:** Checking config file modification time on a timer (e.g., every 5 seconds).
**Why bad:** Either too slow (5s delay) or too frequent (wastes CPU). FileSystemWatcher is event-driven and instant.
**Instead:** FileSystemWatcher with debounce timer handles this correctly with zero polling overhead.

### Anti-Pattern 4: Blocking Health Checks in the Watchdog

**What:** Watchdog uses synchronous HTTP calls with long timeouts to check service health.
**Why bad:** If the service is hung (deadlocked), a 30-second timeout means 30 seconds of downtime before detection.
**Instead:** Use TCP connect with a 2-second timeout. If TCP connects but HTTP is unresponsive, that is also a failure signal. Fast fail, fast restart.

### Anti-Pattern 5: Storing Circuit Breaker State in Config File

**What:** Persisting circuit breaker state (OPEN/CLOSED) to disk.
**Why bad:** Circuit breaker is ephemeral runtime state. If the service restarts, it should start CLOSED (optimistic) and re-discover the network situation. Persisting stale state could prevent connectivity after a transient issue resolves.
**Instead:** Circuit breaker state is purely in-memory. Service restart always starts in CLOSED state.

---

## Build Order (What to Implement First)

Order is based on dependency analysis and incremental value delivery.

### Phase 1: Module Extraction (Foundation)

**Goal:** Break monolith into modules without changing behavior.

1. Create `src/modules/` directory
2. Extract `Logger.ps1` -- define `Write-ProxyLog` function (initially just wraps existing LogBuffer)
3. Extract `Config.ps1` -- config loading, validation helper, schema definition
4. Extract `SystemProxy.ps1` -- Enable/Disable-SystemProxy functions
5. Extract `DomainMatcher.ps1` -- domain set init + Test-Match
6. Extract `NetworkMonitor.ps1` -- SSID detection
7. Refactor `proxy-service.ps1` to dot-source modules
8. Verify nothing breaks (existing behavior preserved)

**Why first:** Every subsequent feature depends on clean module boundaries. This is pure refactoring with zero behavior change -- safest place to start and de-risks everything after it.

### Phase 2: Structured Logging

**Goal:** Replace ad-hoc Write-Host/LogBuffer with structured logging system.

1. Implement `Write-ProxyLog` with level, component, message, data
2. Add log level configuration to config.json
3. Add file-based log output with rotation
4. Add diagnostic export (zip logs + config + status)
5. Update all existing Write-Host calls to use Write-ProxyLog
6. Add `/logs` endpoint with level filtering and search

**Why second:** Logging must be in place before adding complex features (watchdog, fallback) because those features need observability to debug.

### Phase 3: Config Hot-Reload

**Goal:** Config changes apply without service restart.

1. Add `config.schema.json` with JSON Schema validation
2. Implement `Test-ConfigValid` validation function
3. Implement FileSystemWatcher with debounce in Config module
4. Add `/config/reload` API endpoint (manual trigger)
5. Handle domain list changes (rebuild DomainSet)
6. Handle non-restartable changes (port changes log warning)
7. Add `/config` GET endpoint to view effective config

**Why third:** Needed before watchdog (so watchdog config is reloadable) and before fallback (so circuit breaker thresholds are tunable at runtime).

### Phase 4: Circuit Breaker / Fallback

**Goal:** Graceful degradation when corporate proxy is unreachable.

1. Implement `New-CircuitBreaker` state machine
2. Create `Fallback.ps1` module with breaker per upstream proxy
3. Integrate into proxy handler routing decision
4. Add upstream health probe (separate from per-request tracking)
5. Add notification popup when fallback activates/recovers
6. Add `/health` API endpoint showing breaker states
7. Make thresholds configurable (failure count, recovery timeout)

**Why fourth:** Depends on logging (to observe breaker behavior) and config reload (to tune thresholds). High user-facing value -- the "just works" promise.

### Phase 5: Watchdog / Self-Healing

**Goal:** Service auto-restarts after crashes without user intervention.

1. Implement `proxy-watchdog.ps1` as separate script
2. TCP-based health check with failure counting
3. Process spawn and PID tracking
4. Exponential backoff on repeated crashes
5. Balloon notification on restart events
6. Integrate with installer (scheduled task runs watchdog, not service directly)
7. Add `cap watchdog status` CLI command
8. Watchdog writes its own structured log file

**Why fifth:** The watchdog is an outer wrapper -- it works best when the inner service is already stable and well-instrumented. Building it last means the service it monitors is mature.

### Phase 6: Control Enhancements

**Goal:** Multiple trigger methods work reliably.

1. Verify CLI `cap on/off` works from any terminal (PATH integration)
2. Single-click tray toggle (not menu → submenu)
3. Dashboard start/stop button with immediate feedback
4. Error popups via Windows toast notifications (BurntToast-style but no external deps)
5. Clean visual feedback for all state transitions

**Why last:** These are UI polish items that rely on all the underlying infrastructure being solid.

---

## Scalability Considerations

This is a single-user desktop tool, so "scale" means handling edge cases gracefully:

| Concern | Current | After Refactor |
|---------|---------|----------------|
| Many concurrent connections | RunspacePool 1-20 threads | Same, but with better cleanup and timeout |
| Large domain list (500+ entries) | O(1) exact + O(n) suffix | Same, acceptable performance |
| Frequent config changes | Requires restart | Hot-reload with debounce |
| Service crash | Manual restart needed | Auto-restart via watchdog in <15s |
| Upstream proxy down | Requests hang/fail | Circuit breaker, fallback to DIRECT in <5s |
| Log accumulation | In-memory only, lost on restart | File-based with rotation, persists across restarts |
| Multiple upstream proxies | Only first used | Try each in order, skip OPEN breakers |

---

## IPC Decision: HTTP API (Keep Current Pattern)

Evaluated alternatives:

| Method | Pros | Cons | Verdict |
|--------|------|------|---------|
| **HTTP API (current)** | Debuggable with curl, works from any language, already implemented | Slightly more overhead than pipes | **KEEP** |
| Named Pipes | Lower overhead, no port conflicts | Complex in PowerShell, poor cross-shell support, harder to debug | REJECT |
| Memory-mapped files | Fastest IPC | Very complex, overkill for control signals | REJECT |
| Shared file (JSON status file) | Simplest, no listener needed | Race conditions, no request/response, polling required | Use for status only |
| WMI events | Native Windows | Heavyweight, admin may be needed | REJECT |

**Recommendation:** Keep HTTP API as the primary IPC. Supplement with a status file (`proxy.status.json`) that the service writes periodically -- this allows the shell integration scripts to read status without making HTTP calls (faster prompt rendering).

```
Status file (written every 5 seconds by service):
{
  "running": true,
  "proxy_enabled": true,
  "network_state": "CORP",
  "upstreams": { "primary": "CLOSED", "secondary": "CLOSED" },
  "pid": 12345,
  "updated": "2026-05-06T10:30:00Z"
}
```

Shell integration reads this file (1 file read is faster than 1 HTTP call for per-prompt execution).

---

## Sources

- Current codebase analysis: `src/proxy-service.ps1` (541 lines), `src/proxy-cli.ps1`
- .NET Framework `System.IO.FileSystemWatcher` -- available in PowerShell 5.1+ via .NET BCL
- .NET Framework `System.Threading.Mutex` -- already used for single-instance enforcement
- .NET Framework `System.Net.Sockets.TcpClient` -- already used for health checks in CLI
- .NET Framework `System.Timers.Timer` -- available for debounce pattern
- Circuit breaker pattern: Michael Nygard's "Release It!" (industry-standard pattern)
- Windows Task Scheduler: supports "restart on failure" natively for scheduled tasks
- PowerShell RunspacePool: confirmed working pattern in current codebase for concurrent connection handling

**Confidence:** HIGH -- all recommended patterns use .NET BCL classes already available in PowerShell 5.1, and several (RunspacePool, TcpClient, Mutex) are already proven in the current codebase.
