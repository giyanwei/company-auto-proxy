# Coding Conventions

**Analysis Date:** 2026-05-06

## Naming Patterns

**Files:**
- PowerShell scripts use `kebab-case`: `proxy-cli.ps1`, `proxy-service.ps1`, `proxy-tray.ps1`
- Shell snippets use `kebab-case` with purpose suffix: `powershell-profile-snippet.ps1`, `bashrc-snippet.sh`
- CLI shortcut files are single word: `cap`, `cap.cmd`, `cap.ps1`
- Config files use `dot-separated` with qualifier: `config.json`, `config.default.json`, `config.example.json`
- Template files use `.template` suffix: `proxy.pac.template`

**Functions (PowerShell):**
- Use `PascalCase` with approved PowerShell verbs: `Enable-SystemProxy`, `Disable-SystemProxy`, `Get-CurrentSSID`, `Set-AutoStart`
- Helper/utility functions use `Verb-Noun` pattern: `Send-ControlCommand`, `Test-ServiceRunning`, `Send-Command`, `Test-Running`
- Internal match functions use short names: `Test-Match`
- Tray UI builder functions: `New-TrayIcon`, `Update-TrayState`, `Get-Status`

**Functions (Shell snippets):**
- Bash uses `__double_underscore_prefix` with snake_case: `__proxy_switch`
- PowerShell profile uses `__PascalCasePrefix`: `__CompanyProxySwitch`

**Variables:**
- Script-scoped state uses `$script:PascalCase`: `$script:Config`, `$script:State`, `$script:LogBuffer`, `$script:LogMax`, `$script:DomainSet`
- Local variables use `$camelCase`: `$controlPort`, `$proxyPort`, `$configFile`, `$scriptDir`, `$installPath`
- Loop/temp variables use short names: `$d`, `$h`, `$n`, `$hp`
- Config JSON keys use `snake_case`: `proxy_port`, `control_port`, `upstream_proxies`, `wifi_detection`, `auto_start`

**Constants/Globals:**
- Registry path stored in local variable: `$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"`
- Mutex names use Pascal format: `"Global\CompanyProxyAutoServiceMutex"`, `"Global\CompanyProxyAutoMutex"`
- Scheduled task names use PascalCase: `"CompanyProxyAuto"`, `"CompanyProxyAutoTray"`

## Code Style

**Formatting:**
- No automated formatter configured (no `.editorconfig`, PSScriptAnalyzer, or Prettier)
- Consistent 4-space indentation throughout all PowerShell scripts
- Opening braces on same line as statement
- Single blank line between logical sections
- Comments with `#` followed by space, often with `---` section dividers: `# --- System proxy management ---`

**Line Length:**
- No enforced limit; lines commonly extend to 100-140 characters
- Long `Write-Host` statements kept on single lines for readability

**Linting:**
- No linting tools configured
- No PSScriptAnalyzer settings file present
- No `.editorconfig` file

## Script Header Pattern

All main scripts use PowerShell comment-based help:
```powershell
<#
.SYNOPSIS
    Brief one-line description.
.DESCRIPTION
    More detailed explanation of what the script does.
.EXAMPLE
    .\script.ps1 command
#>
```

Only major scripts (`proxy-cli.ps1`, `proxy-service.ps1`, `proxy-tray.ps1`, `install.ps1`, `uninstall.ps1`) include these headers. Utility scripts (`pac-server.ps1`, `proxy-switch.ps1`, `cap.ps1`) omit them.

## Import Organization

**PowerShell assembly loading:**
- `.NET` types added at script top via `Add-Type -AssemblyName`:
  ```powershell
  Add-Type -AssemblyName System.Net.Http
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  ```

**Script directory resolution:**
- Every script resolves its own location first:
  ```powershell
  $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
  ```

**Config loading pattern:**
- Immediately after `$scriptDir`, load config with fallback:
  ```powershell
  $configFile = Join-Path $scriptDir "config.json"
  if (-not (Test-Path $configFile)) {
      $defaultConfig = Join-Path (Split-Path -Parent $scriptDir) "config.default.json"
      if (Test-Path $defaultConfig) { Copy-Item $defaultConfig $configFile }
  }
  $config = Get-Content $configFile -Raw | ConvertFrom-Json
  ```

## Error Handling

**Patterns:**
- `$ErrorActionPreference = "Stop"` set at top of main scripts for fail-fast behavior
- `$ErrorActionPreference = "SilentlyContinue"` used in `uninstall.ps1` for graceful cleanup
- `try { ... } catch {}` with empty catch blocks used extensively for non-critical operations (network checks, process cleanup)
- `-ErrorAction SilentlyContinue` appended to commands that may fail gracefully (registry operations, task removal)
- No structured error logging or error propagation to callers

**Error response in proxy handler:**
```powershell
} catch {
    $stream.Write([System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 502 Bad Gateway`r`n`r`n"), 0, 30)
}
```

**Service conflict detection:**
- Mutex pattern prevents duplicate instances:
  ```powershell
  $mutex = New-Object System.Threading.Mutex($false, "Global\CompanyProxyAutoServiceMutex")
  if (-not $mutex.WaitOne(0)) {
      Write-Host "Error: Another instance is already running." -ForegroundColor Red
      exit 1
  }
  ```

## Logging

**Framework:** Console output via `Write-Host` with color coding

**Patterns:**
- Success messages: `Write-Host "message" -ForegroundColor Green`
- Warnings/status: `Write-Host "message" -ForegroundColor Yellow`
- Errors: `Write-Host "message" -ForegroundColor Red`
- Informational: `Write-Host "message" -ForegroundColor Cyan`
- Secondary info: `Write-Host "  detail" -ForegroundColor Gray`
- No file-based logging; runtime request logs stored in `ConcurrentQueue[hashtable]` in memory only

**Request logging (in-memory):**
```powershell
$logBuffer.Enqueue(@{
    time = [DateTime]::UtcNow.ToString("o")
    method = "CONNECT"
    host = $hostPort
    proxied = $shouldProxy
    status = 200
})
while ($logBuffer.Count -gt $logMax) { $null = $logBuffer.TryDequeue([ref]$null) }
```

## Comments

**When to Comment:**
- Section dividers for major blocks: `# --- System proxy management ---`
- Brief inline comments for non-obvious logic: `# SSID check`, `# PID file`
- No JSDoc-style documentation on individual functions
- No parameter documentation beyond script-level `.SYNOPSIS`

**Marker comments for shell integration:**
```powershell
# >>> company-auto-proxy >>>
# ... snippet code ...
# <<< company-auto-proxy <<<
```

## Function Design

**Size:** Functions are small (5-20 lines), single-purpose. Large logic lives inline in script blocks and switch statements.

**Parameters:**
- Named parameters with `param()` blocks for scripts
- Simple `param([string]$Path)` for helper functions
- Positional parameters used for CLI: `[Parameter(Position = 0)]`
- Switch parameters for boolean flags: `[switch]$Dashboard`, `[switch]$Force`
- ValidateSet for constrained values: `[ValidateSet("cli", "full")]`

**Return Values:**
- Functions return `$true`/`$false` for test functions
- Functions return `$null` on failure (REST call helpers)
- No explicit `return` needed in many cases; PowerShell implicit output

## Module Design

**No module system used.** Each `.ps1` file is self-contained with its own config loading and function definitions.

**Code duplication across files:**
- `Send-ControlCommand` / `Send-Command` duplicated in `proxy-cli.ps1` and `proxy-tray.ps1`
- `Test-ServiceRunning` / `Test-Running` duplicated in `proxy-cli.ps1` and `proxy-tray.ps1`
- `Enable-SystemProxy` / `Disable-SystemProxy` logic duplicated in service and control API runspace
- Config loading pattern repeated in every script

**CLI dispatch pattern:**
- Uses `switch ($Command)` with nested `switch ($SubCommand)` for subcommand routing
- Default case shows usage or calls help

## Configuration Pattern

**Three-tier config system:**
1. `config.example.json` - Template for initial setup (legacy v1 format with `proxies[]` array and `pac_port`)
2. `config.default.json` - Defaults for v2 format (uses `upstream_proxies[]`, `proxy_port`, `control_port`)
3. `config.json` - Runtime config (gitignored, auto-created from defaults)

**Config access:**
- Always read fresh from disk for mutations: `Get-Content $configFile -Raw | ConvertFrom-Json`
- Write back with: `$cfg | ConvertTo-Json -Depth 5 | Set-Content $configFile -Encoding UTF8`
- Runtime state stored separately in synchronized hashtable, not in config object

## Control API Pattern

**Internal HTTP API on localhost:**
- Simple path-based routing with `switch -Wildcard ($path)`
- Query parameters for values: `$req.QueryString["value"]`
- All responses are JSON with `Content-Type: application/json`
- Success responses: `'{"ok":true}'` (raw string, not object)
- Status responses: hashtable piped to `ConvertTo-Json -Compress`

## Output Formatting

**CLI output uses structured columns:**
```powershell
Write-Host "Status:      running" -ForegroundColor Green
Write-Host "Proxy:       ENABLED"
Write-Host "Uptime:      $($status.uptime)"
```

**Installer uses numbered progress steps:**
```powershell
Write-Host "[1/7] Generating proxy.pac..." -ForegroundColor Green
Write-Host "[2/7] Copying scripts..." -ForegroundColor Green
```

---

*Convention analysis: 2026-05-06*
