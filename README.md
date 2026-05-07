# company-auto-proxy

Smart local proxy for Windows that routes traffic based on domain lists. Whitelisted domains go through your corporate upstream proxy; everything else connects directly.

## Quick Start

```powershell
# 1. Copy default config (edit to set your upstream proxy URL)
copy src\config.default.json src\config.json
notepad src\config.json

# 2. Edit domain list (add corporate-only domains)
notepad src\domains.json

# 3. Start the service
powershell -ExecutionPolicy Bypass -File src\proxy-cli.ps1 start

# 4. Check status
powershell -ExecutionPolicy Bypass -File src\proxy-cli.ps1 status
```

After install, use `cap` from any terminal:

```powershell
cap start    # Start proxy service
cap status   # Check status
```

## CLI Commands

```
cap on                       Enable system proxy (auto-starts service)
cap off                      Disable system proxy (service keeps running)
cap start                    Start proxy service
cap stop                     Stop proxy service
cap restart                  Restart proxy service
cap status [--short]         Show status and statistics

cap domains list             List routed domains by group
cap domains add <grp> <d>    Add domain to a group
cap domains remove <d>       Remove domain from all groups

cap config show              Show current configuration
cap config set <key> <val>   Set a config value (e.g. proxy.port, network.ssid_pattern)
cap config reset             Reset to defaults

cap install [-Mode cli|full] Install as startup service
cap uninstall                Remove service and clean up
```

## Configuration

Two files in `src/`:

**config.json** (or config.default.json as template):
```json
{
  "proxy": { "port": 8081, "upstream_proxies": ["http://proxy.example.com:8080"], "max_connections": 20 },
  "network": { "ssid_pattern": "CORP", "wifi_detection": true, "auto_switch": true, "detection_interval_sec": 30 },
  "control": { "port": 8082, "dashboard_enabled": false },
  "logging": { "level": "info", "max_entries": 100 },
  "behavior": { "auto_start": false, "install_path": "%USERPROFILE%\\.proxy" }
}
```

**domains.json** (grouped domain lists):
```json
{
  "github": ["github.com", "githubusercontent.com", "ghcr.io"],
  "google": ["google.com", "googleapis.com", "gstatic.com"],
  "ai": ["openai.com", "anthropic.com", "claude.ai"]
}
```

Only domains in this file are routed through the upstream proxy. Everything else goes direct.

## How It Works

```
Browser/CLI -> 127.0.0.1:8081 (local proxy)
                    |
                    v
             Domain in list?
            /              \
          YES               NO
           |                 |
  Upstream proxy        Direct connection
  (corporate)           (no proxy)
```

On startup the service sets the Windows system proxy (registry) and HTTP_PROXY/HTTPS_PROXY environment variables to `127.0.0.1:8081`. On shutdown both are cleared.

WiFi detection (optional): when enabled, the service checks the current SSID against a pattern. If on corporate WiFi, domain routing is active. Otherwise all traffic goes direct.

The control API runs on port 8082 with endpoints for status, proxy on/off, reload, domain management, and a web dashboard.

## Requirements

- Windows 10/11
- PowerShell 5.1+

## File Structure

```
src/
  proxy-service.ps1      Main daemon (proxy + control API)
  proxy-cli.ps1          CLI tool
  config.default.json    Default configuration template
  config.json            User configuration (gitignored)
  domains.json           Domain routing lists
  modules/
    Config.ps1           Config loading, validation, hot-reload
    DomainMatcher.ps1    Domain lookup and persistence
    SystemProxy.ps1      Registry and env var management
bin/
  cap, cap.cmd, cap.ps1  CLI entry points
```

## License

MIT
