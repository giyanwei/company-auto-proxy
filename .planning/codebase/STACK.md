# Technology Stack

**Analysis Date:** 2026-05-06

## Languages

**Primary:**
- PowerShell 5.1+ - All service logic, CLI, tray UI, installation scripts (`src/proxy-service.ps1`, `src/proxy-cli.ps1`, `src/proxy-tray.ps1`)
- HTML/CSS/JavaScript - Web dashboard single-file application (`src/dashboard.html`)

**Secondary:**
- Batch (CMD) - Windows command-line entry point (`bin/cap.cmd`)
- Bash - Git Bash / WSL entry point (`bin/cap`)
- VBScript - Legacy silent launcher (`src/start-proxy-switch.vbs`)
- JavaScript (PAC) - Proxy auto-config template (`src/proxy.pac.template`)
- JSON - Configuration files (`config.json`, `config.default.json`, `config.example.json`)

**Legacy (compiled, source not present):**
- Go (presumed) - `proxy.exe` binary (~10MB); empty `cmd/proxy/` and `internal/` directory structure suggests a prior Go implementation that was compiled but source removed from the active branch

## Runtime

**Environment:**
- Windows PowerShell 5.1+ (ships with Windows 10/11)
- .NET Framework (used via `Add-Type` for System.Net.Http, System.Windows.Forms, System.Drawing)

**Package Manager:**
- None - No package manager is used. All dependencies are .NET BCL assemblies loaded via `Add-Type`.

**Lockfile:**
- Not applicable - No external dependency management

## Frameworks

**Core:**
- .NET Framework BCL - Network I/O, HTTP client, TCP sockets (loaded via `Add-Type -AssemblyName`)
- System.Net.HttpListener - Control API / dashboard HTTP server
- System.Net.Sockets.TcpListener - Proxy server TCP listener
- System.Net.Http.HttpClient - Outbound HTTP forwarding
- System.Windows.Forms - System tray UI and application message loop
- System.Drawing - Tray icon bitmap generation

**Testing:**
- None detected - No test framework or test files present

**Build/Dev:**
- None - No build step required; scripts run directly via PowerShell interpreter

## Key Dependencies

**Critical (all .NET BCL, loaded at runtime):**
- `System.Net.Http` - HTTP proxy forwarding for non-CONNECT requests
- `System.Net.Sockets` - TCP proxy server (CONNECT tunneling)
- `System.Net.HttpListener` - Control API HTTP server
- `System.Collections.Concurrent` - Thread-safe request log buffer (`ConcurrentQueue`)
- `System.Threading` - Mutex for single-instance enforcement, Interlocked counters

**UI:**
- `System.Windows.Forms` - NotifyIcon, ContextMenuStrip, Timer, Application.Run
- `System.Drawing` - Bitmap/Graphics for tray icon creation

**System Integration:**
- Windows Registry (`HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings`) - System proxy control
- `netsh wlan show interfaces` - WiFi SSID detection
- Windows Task Scheduler - Auto-start registration
- User environment variables (`HTTP_PROXY`, `HTTPS_PROXY`) - CLI tool proxy configuration

## Configuration

**Environment:**
- JSON-based configuration at `src/config.json` (runtime) and `config.default.json` (template)
- Key settings: `proxy_port` (default 8081), `control_port` (default 8082), `upstream_proxies`, `ssid_pattern`, `wifi_detection`, `auto_start`, `dashboard_enabled`
- Domain whitelist organized by category groups (github, google, ai, npm, etc.)
- Install path configurable via `install_path` with `%USERPROFILE%` expansion

**No .env files used** - All configuration is in JSON files. Sensitive values (upstream proxy URLs) are stored in `config.json`.

**Build:**
- No build configuration - PowerShell scripts run directly
- `proxy.exe` is a pre-compiled binary (no build toolchain in repo)

## Platform Requirements

**Development:**
- Windows 10 or 11
- PowerShell 5.1+ (built into Windows)
- No additional tooling required

**Production:**
- Windows 10 or 11
- PowerShell 5.1+ with ExecutionPolicy Bypass
- Network access to upstream corporate proxy servers
- WiFi adapter (for SSID-based auto-detection, optional)
- Administrator privileges NOT required (user-level registry, user-level scheduled tasks, user-level environment variables)

## Concurrency Model

**RunspacePool:**
- `proxy-service.ps1` uses a `[RunspaceFactory]::CreateRunspacePool(1, 20)` with up to 20 concurrent runspaces
- Each incoming TCP connection spawns a new PowerShell runspace from the pool
- Control API runs in its own dedicated runspace
- Shared state via `[hashtable]::Synchronized` and `[System.Threading.Interlocked]` atomic operations
- Main loop polls `TcpListener.Pending()` every 20ms

## Entry Points

| Entry Point | Purpose | Invocation |
|-------------|---------|------------|
| `bin/cap.ps1` | PowerShell CLI wrapper | `cap <command>` from PowerShell |
| `bin/cap.cmd` | CMD CLI wrapper | `cap <command>` from CMD |
| `bin/cap` | Bash CLI wrapper | `cap <command>` from Git Bash |
| `src/proxy-cli.ps1` | Full CLI tool | Direct PowerShell execution |
| `src/proxy-service.ps1` | Service daemon | Started by CLI or scheduled task |
| `src/proxy-tray.ps1` | System tray UI | Started by CLI install (full mode) |
| `install.ps1` | Legacy installer | One-time setup (v1 PAC approach) |
| `uninstall.ps1` | Legacy uninstaller | Cleanup |

## Version

- Application version: `v2.1.0` (reported by `cap version` command in `src/proxy-cli.ps1:367`)

---

*Stack analysis: 2026-05-06*
