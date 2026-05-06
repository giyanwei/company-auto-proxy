# Technology Stack

**Project:** Company Auto Proxy (CAP)
**Researched:** 2026-05-06
**Constraint:** Pure PowerShell 5.1+ / .NET Framework BCL only / Zero external dependencies

## Recommended Stack

### Core Runtime

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| PowerShell 5.1 | Ships with Win10/11 | Script runtime | Zero install requirement; every target machine has it |
| .NET Framework 4.7.2+ | Ships with Win10/11 | BCL for TCP, HTTP, JSON | No NuGet, no package restore — just `Add-Type` |
| Windows Task Scheduler | Built-in | Service persistence, auto-start, watchdog | Native OS facility, no admin for user-context tasks |

### Service Management (Self-Healing)

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Scheduled Task (AtLogon + Repetition) | Native | Auto-start + watchdog restart | Already partially implemented; use repetition interval for self-healing |
| Named Mutex | .NET BCL | Single-instance enforcement | Already in codebase (`Global\CompanyProxyAutoServiceMutex`), prevents duplicate daemons |
| PID file + health check | Custom | Liveness detection | Simple TCP probe on control port — already the pattern in `Test-ServiceRunning` |

**Rationale: Task Scheduler over NSSM or Windows Services**

NSSM (Non-Sucking Service Manager) is powerful but introduces an external binary dependency and requires admin to install a Windows Service. The project constraint is "no external packages" and "must work without admin for daily use." Task Scheduler supports user-context tasks (no admin), has built-in restart-on-failure via repetition triggers, and is what the project already uses.

The self-healing pattern:
1. **Primary task**: `AtLogon` trigger starts the proxy service
2. **Watchdog task**: Repetition interval (every 5 minutes) runs a health-check script that verifies the control port is responsive; if not, kills stale process and restarts
3. **In-process**: The daemon itself catches unhandled exceptions in a try/finally and attempts graceful restart before dying

### Configuration & Validation

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| JSON config (config.json) | Native PS 5.1 | Settings storage | Already in use; human-readable, versionable, no schema language needed at runtime |
| PowerShell validation functions | Custom | Schema enforcement | PS 5.1 lacks `Test-Json -Schema`; use custom validation with clear error messages |
| config.default.json + config.json | Convention | Default vs user override | Already established pattern; installer creates config.json from default |

**Schema Validation Approach:**

PowerShell 5.1 does NOT have `Test-Json` (that's PS 6.1+). For PS 5.1 compatibility, use a custom validation function pattern:

```powershell
function Test-ProxyConfig {
    param([hashtable]$Config)
    $errors = @()
    
    # Required fields
    if (-not $Config.proxy_port) { $errors += "proxy_port is required" }
    if ($Config.proxy_port -and ($Config.proxy_port -lt 1024 -or $Config.proxy_port -gt 65535)) {
        $errors += "proxy_port must be between 1024-65535"
    }
    
    # Type checks
    if ($Config.domains -and $Config.domains -isnot [hashtable]) {
        $errors += "domains must be an object/hashtable"
    }
    
    return @{ Valid = ($errors.Count -eq 0); Errors = $errors }
}
```

This approach:
- Works on PS 5.1 (no external dependency)
- Provides actionable error messages (better than JSON Schema's cryptic errors)
- Can be reused in the interactive installer for real-time feedback
- Runs at startup, at config reload, and during `cap settings validate`

### Interactive Installer

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| `Read-Host` / `$Host.UI.PromptForChoice` | Native PS | User prompts | Zero dependency; works in any PS host |
| ANSI/VT100 escape sequences | Win10+ native | Colored output, progress | Windows 10+ console supports ANSI; fallback to `Write-Host -ForegroundColor` |
| Idempotent check-then-act pattern | Convention | Re-runnable installer | Already partially in place; expand to all steps |

**Installer Pattern (oh-my-posh style):**

Popular PowerShell tools follow this pattern:
1. **Detection phase**: Check what's already installed (PATH entries, scheduled tasks, profile snippets)
2. **Prompt phase**: Show what will change, ask for confirmation or choice
3. **Action phase**: Perform changes with clear [step/total] progress
4. **Verification phase**: Confirm success, show next steps

```powershell
# oh-my-posh-style PATH management
function Add-ToUserPath {
    param([string]$Directory)
    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($currentPath -split ";" -contains $Directory) { return $false }  # Already there
    [Environment]::SetEnvironmentVariable("PATH", "$currentPath;$Directory", "User")
    # Broadcast WM_SETTINGCHANGE so other processes pick it up
    Add-Type -TypeDefinition @"
        using System; using System.Runtime.InteropServices;
        public class WinAPI {
            [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
            public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, 
                UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
        }
"@
    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x1a
    $result = [UIntPtr]::Zero
    [WinAPI]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$result)
    return $true
}
```

### Logging

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Custom structured logger | .NET BCL | Structured logging with levels and rotation | No suitable PS 5.1 logging module without external deps |
| `[ConcurrentQueue]` | .NET BCL | Thread-safe log buffer (already in use) | Correct for runspace-based architecture |
| File rotation by size | Custom | Prevent disk fill | Simple: rename when > N MB, keep last M files |

**Logging Architecture:**

```powershell
# Structured log entry format (JSON lines for easy parsing)
function Write-ProxyLog {
    param(
        [ValidateSet("DEBUG","INFO","WARN","ERROR")]
        [string]$Level = "INFO",
        [string]$Message,
        [string]$Component = "core",
        [hashtable]$Data = @{}
    )
    $entry = @{
        ts = [DateTime]::UtcNow.ToString("o")
        level = $Level
        msg = $Message
        component = $Component
    }
    if ($Data.Count -gt 0) { $entry.data = $Data }
    
    $line = $entry | ConvertTo-Json -Compress
    # Write to file + in-memory buffer for dashboard
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    $script:LogBuffer.Enqueue($entry)
    
    # Rotation check
    if ((Get-Item $script:LogFile -ErrorAction SilentlyContinue).Length -gt $script:LogMaxSize) {
        Invoke-LogRotation
    }
}
```

**Rotation Strategy:**
- Max file size: 5 MB (configurable)
- Keep last 3 rotated files (cap.log, cap.log.1, cap.log.2, cap.log.3)
- Rotate on size threshold check (not time-based — simpler, catches bursts)
- Format: JSON Lines (`.jsonl`) for structured querying with `Get-Content | ConvertFrom-Json`

### CLI & PATH Integration

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| `bin/cap` (bash shim) | Custom | Unix shell CLI entry | Already exists; handles Git Bash/WSL |
| `bin/cap.cmd` (batch shim) | Custom | CMD CLI entry | Already exists; handles Windows CMD |
| `bin/cap.ps1` (PS shim) | Custom | PowerShell CLI entry | Already exists; handles PS console |
| User PATH entry | `[Environment]::SetEnvironmentVariable` | Global `cap` command | Add `bin/` directory to user PATH at install |

**Shell Detection for Installer:**

```powershell
function Get-ShellEnvironment {
    $shells = @()
    # PowerShell (always present)
    $shells += @{ Name = "PowerShell"; Profile = $PROFILE; Detected = $true }
    # Git Bash
    $gitBash = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($gitBash) { $shells += @{ Name = "Git Bash"; Profile = "$env:USERPROFILE\.bashrc"; Detected = $true } }
    # WSL
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wsl) { $shells += @{ Name = "WSL"; Profile = $null; Detected = $true } }
    # CMD (always present)
    $shells += @{ Name = "CMD"; Profile = $null; Detected = $true }
    return $shells
}
```

### Testing

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Pester 5.x | Latest stable | Unit & integration tests | De facto standard for PowerShell testing; ships with Win10+ |
| Pester Mocking | Built into Pester | Mock network/registry calls | Essential for testing proxy routing without real network |

**Note:** Pester 3.4.0 ships with Windows 10, but Pester 5.x is the modern version with better isolation and configuration. Recommend installing Pester 5.x in user scope for development:

```powershell
Install-Module Pester -Force -Scope CurrentUser -SkipPublisherCheck
```

This is a **development dependency only** — the shipping tool does not require Pester installed on the user's machine.

### Notifications & Tray

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| `System.Windows.Forms.NotifyIcon` | .NET Framework | Tray icon + balloon tips | Already in use; built-in, no dependency |
| `[System.Windows.Forms.MessageBox]` | .NET Framework | Error popups | Simple modal alerts for critical failures |
| BalloonTip notifications | .NET Framework | Non-intrusive status updates | Toast-like popups from tray icon for fallback alerts |

### Fallback & Health Monitoring

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| `System.Net.Sockets.TcpClient` | .NET BCL | Upstream proxy health check | Fast TCP connect test to corporate proxy |
| Timer-based polling | .NET `System.Timers.Timer` | Periodic health verification | Check upstream every 30s; switch to direct on 3 consecutive failures |
| WMI/CIM network events | Built-in | Network change detection | `Register-CimIndicationEvent` for real-time WiFi connect/disconnect |

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| Service mgmt | Task Scheduler | NSSM | External binary; requires admin install; violates zero-dependency constraint |
| Service mgmt | Task Scheduler | Windows Service (SC.exe) | Requires admin; complex to debug; overkill for single-user tool |
| Service mgmt | Task Scheduler | Startup folder shortcut | No restart-on-failure; no watchdog capability; less reliable |
| Config validation | Custom PS functions | JSON Schema + Test-Json | Test-Json requires PS 6.1+; JSON Schema errors are cryptic |
| Config validation | Custom PS functions | Pester-based config tests | Pester is overkill for runtime validation; saves dev-time but adds complexity |
| Logging | Custom JSON Lines logger | PSFramework logging | External module dependency; violates zero-dependency constraint |
| Logging | Custom JSON Lines logger | Windows Event Log | Requires admin to register source; harder to export/share diagnostics |
| Logging | Custom JSON Lines logger | Start-Transcript | No structured data; no levels; limited rotation control |
| Installer | Interactive PS script | Scoop/Winget manifest | Deferred per project scope; adds distribution complexity too early |
| Installer | Interactive PS script | MSI installer | Massive complexity; requires WiX toolset; overkill for developer tool |
| Notifications | BalloonTip/MessageBox | BurntToast module | External module dependency; PS 5.1 BalloonTip is sufficient |
| Testing | Pester 5.x | No testing | Project needs reliability guarantees for self-healing/fallback features |
| Runtime | PowerShell 5.1 | PowerShell 7 (pwsh) | Not installed by default on Windows; requiring it defeats zero-install goal |

## Key Libraries/Tools

### Built-in (Zero-Install) - Used at Runtime

| Library/API | Namespace | Purpose | Notes |
|-------------|-----------|---------|-------|
| TCP Listener | `System.Net.Sockets.TcpListener` | Proxy port listener | Core of proxy-service.ps1 |
| HTTP Listener | `System.Net.HttpListener` | Control API + dashboard | Used for REST endpoints |
| HTTP Client | `System.Net.Http.HttpClient` | Upstream proxy forwarding | For CONNECT tunnel setup |
| Concurrent Queue | `System.Collections.Concurrent.ConcurrentQueue` | Thread-safe log buffer | Already in use |
| Mutex | `System.Threading.Mutex` | Single-instance lock | Already in use |
| NotifyIcon | `System.Windows.Forms.NotifyIcon` | Tray icon | Already in use |
| Registry | `Microsoft.Win32.Registry` | System proxy settings | Via `Set-ItemProperty HKCU:` |
| Task Scheduler | `ScheduledTasks` module | Auto-start + watchdog | `Register-ScheduledTask` cmdlet |
| WMI/CIM | `Microsoft.Management.Infrastructure` | Network event subscription | For real-time network change detection |
| Timer | `System.Timers.Timer` | Periodic health checks | For upstream proxy liveness monitoring |
| P/Invoke (WinAPI) | Custom Add-Type | WM_SETTINGCHANGE broadcast | For notifying other processes of env var changes |

### Development Only (Not Shipped)

| Tool | Version | Purpose | Install Command |
|------|---------|---------|-----------------|
| Pester | 5.x | Testing framework | `Install-Module Pester -Force -Scope CurrentUser` |
| PSScriptAnalyzer | Latest | Linting/static analysis | `Install-Module PSScriptAnalyzer -Scope CurrentUser` |
| platyPS | Latest | Help documentation generation | `Install-Module platyPS -Scope CurrentUser` (optional) |

## Installation & Deployment

```powershell
# No package install needed for runtime. The tool IS the scripts.
# Development setup (for contributors):
Install-Module Pester -Force -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Force -Scope CurrentUser

# User installation (the interactive installer handles all of this):
# 1. Clone/download repo
# 2. Run: .\install.ps1
# 3. Installer handles: PATH, scheduled tasks, profile snippets, config generation
```

## Key Architecture Decisions

### Why Not a PowerShell Module?

The project is NOT structured as a traditional PowerShell module (no `.psd1` manifest, no `Import-Module`) because:

1. **Entry point is a daemon** — Not a collection of cmdlets users import into their session
2. **CLI shim pattern is simpler** — `cap` command routes through shell-appropriate shim to the CLI script
3. **No PSGallery distribution planned** — Direct install from repo; module packaging adds complexity without benefit
4. **Profile snippet is minimal** — Only sets env vars; doesn't import functions into the user's session

However, the **internal structure** should follow module best practices:
- Separate public API (CLI commands) from internal functions
- Use consistent naming conventions (`Verb-Noun` for internal functions)
- Keep scripts focused (single responsibility per file)

### Why JSON Lines for Logs?

1. **Parseable**: `Get-Content cap.log | ConvertFrom-Json` — instant structured access
2. **Appendable**: No JSON array brackets to manage; just append lines
3. **Streamable**: Can `tail -f` equivalent with `Get-Content -Wait`
4. **Exportable**: `cap log export` can filter by level/time/component and produce diagnostics bundle
5. **Dashboard-friendly**: Control API can serve last N entries as JSON array for live dashboard

### Why Custom Validation Over JSON Schema?

1. **PS 5.1 compatible**: No `Test-Json` available
2. **Actionable errors**: "proxy_port must be between 1024-65535" vs "instance does not match schema"
3. **Context-aware**: Can validate that `ssid_pattern` is a valid regex, not just a string
4. **Interactive installer integration**: Same validation runs during guided setup
5. **No schema file to maintain**: Validation logic lives next to the code that uses the config

## Confidence Levels

| Area | Confidence | Reason |
|------|------------|--------|
| PowerShell 5.1 BCL capabilities | HIGH | Verified via Context7 docs; matches existing working code |
| Task Scheduler for watchdog | HIGH | Native API, well-documented, already partially implemented |
| Custom config validation | HIGH | Necessity (no Test-Json in PS 5.1); pattern is straightforward |
| JSON Lines logging | HIGH | Standard pattern; proven in many tools; no dependencies needed |
| Interactive installer pattern | MEDIUM | Based on observed patterns from oh-my-posh/PSReadLine; not complex but needs UX iteration |
| Pester 5.x for testing | HIGH | De facto standard; well-documented via Context7; clear value |
| WM_SETTINGCHANGE for PATH | MEDIUM | Documented Win32 API; works but some terminals may not respond to broadcast |
| CIM event subscription for network | MEDIUM | Works but can be fragile; may need fallback to polling |

## Sources

- Context7: `/microsoftdocs/powershell-docs` — Module manifests, PSModulePath, environment variables, Test-Json availability
- Context7: `/pester/docs` — Pester 5.x configuration patterns
- Microsoft Learn: PowerShell Scheduled Jobs API documentation
- Microsoft Learn: Installing a PowerShell Module (PSModulePath management)
- Existing codebase analysis: `install.ps1`, `proxy-service.ps1`, `proxy-cli.ps1`, `uninstall.ps1`
