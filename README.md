# company-auto-proxy

Smart local proxy for Windows that intercepts all traffic and routes it based on a domain whitelist. Whitelisted domains go through your corporate upstream proxy; everything else connects directly.

## How It Works

```
┌──────────────────────────────────────────────────────────────┐
│  All traffic → 127.0.0.1:8081 (local proxy)                 │
│                                                              │
│  Domain in whitelist?                                        │
│    YES → forward to upstream corporate proxy                 │
│    NO  → connect directly (no proxy)                         │
│                                                              │
│  WiFi SSID matches corporate pattern?                        │
│    YES → whitelist routing active (CORP mode)                │
│    NO  → all traffic goes direct (OTHER mode)                │
└──────────────────────────────────────────────────────────────┘
```

On startup, the service sets:
- **Windows system proxy** (registry) → `127.0.0.1:8081`
- **HTTP_PROXY / HTTPS_PROXY** environment variables → `http://127.0.0.1:8081`

This captures traffic from browsers, git, gh, curl, pip, cargo, and any tool that respects system proxy or environment variables. On shutdown, both are cleared automatically.

## Quick Start

```powershell
# 1. Clone and enter the repo
git clone https://github.com/giyanwei/company-auto-proxy.git
cd company-auto-proxy
git checkout feature/powershell-proxy

# 2. Edit config (set your upstream proxy, SSID pattern, domains)
notepad src\config.json

# 3. Start the service
powershell -ExecutionPolicy Bypass -File src\proxy-cli.ps1 start -Dashboard

# 4. Open the dashboard
start http://127.0.0.1:8082/dashboard
```

## CLI Usage

```powershell
proxy-cli.ps1 start [-Dashboard]       # Start service (sets system proxy)
proxy-cli.ps1 stop                      # Stop service (clears system proxy)
proxy-cli.ps1 status                    # Show status and stats

proxy-cli.ps1 proxy on                  # Enable system proxy (service keeps running)
proxy-cli.ps1 proxy off                 # Disable system proxy (service keeps running)

proxy-cli.ps1 settings show             # Show current settings
proxy-cli.ps1 settings set wifi_detection true/false
proxy-cli.ps1 settings set ssid_pattern "YourWiFi"
proxy-cli.ps1 settings set auto_start true/false

proxy-cli.ps1 domains list              # List whitelisted domains
proxy-cli.ps1 domains add <group> <domain>
proxy-cli.ps1 domains remove <domain>

proxy-cli.ps1 dashboard on/off          # Toggle web dashboard
proxy-cli.ps1 reload                    # Reload config without restart
proxy-cli.ps1 install [-Mode cli|full]  # Install as startup service
proxy-cli.ps1 uninstall                 # Remove everything
```

## Dashboard

Web UI at `http://127.0.0.1:8082/dashboard` with:

- **Proxy ON/OFF button** — enable/disable system proxy interception
- **WiFi Detection toggle** — auto-detect corporate network by SSID
- **SSID Pattern** — editable regex for WiFi matching
- **Auto Start toggle** — register/unregister Windows startup task
- **Live stats** — total/proxied/direct requests, active connections
- **Request log** — real-time table of recent requests with routing info
- **Domain whitelist** — add/remove domains directly from the UI

## System Tray

Run `proxy-tray.ps1` for a system tray icon with:

- Proxy status indicator (orange = CORP, green = DIRECT, red = disabled, gray = stopped)
- Enable/Disable Proxy
- Start/Stop Service
- WiFi Detection on/off
- Auto Start on/off
- Open Dashboard
- Open Config / Reload Config

## Configuration

`src/config.json`:

```json
{
  "proxy_port": 8081,
  "control_port": 8082,
  "upstream_proxies": ["http://your-proxy:8080"],
  "ssid_pattern": "YourCompanyWiFi",
  "wifi_detection": true,
  "auto_start": false,
  "dashboard_enabled": false,
  "log_max_entries": 100,
  "domains": {
    "github": ["github.com", "githubusercontent.com"],
    "google": ["google.com", "googleapis.com"],
    "ai": ["openai.com", "anthropic.com", "claude.ai"],
    ...
  }
}
```

| Field | Description |
|-------|-------------|
| `proxy_port` | Local proxy listen port |
| `control_port` | Control API / Dashboard port |
| `upstream_proxies` | Corporate proxy servers (first = primary) |
| `ssid_pattern` | Regex to match corporate WiFi SSID |
| `wifi_detection` | Enable/disable WiFi-based auto-switching |
| `auto_start` | Register as Windows startup task |
| `dashboard_enabled` | Serve dashboard on start |
| `log_max_entries` | Max request log entries in memory |
| `domains` | Grouped domain whitelist (only these go through upstream proxy) |

## Control API

All endpoints on `http://127.0.0.1:8082`:

| Endpoint | Description |
|----------|-------------|
| `GET /status` | Full status (proxy_enabled, network_state, stats, settings) |
| `GET /proxy/on` | Enable system proxy |
| `GET /proxy/off` | Disable system proxy |
| `GET /settings` | Current settings |
| `GET /settings/auto_start?value=true` | Toggle auto-start |
| `GET /settings/wifi_detection?value=true` | Toggle WiFi detection |
| `GET /settings/ssid_pattern?value=X` | Change SSID pattern |
| `GET /domains` | List all whitelisted domains |
| `GET /domains/add?group=X&domain=Y` | Add a domain |
| `GET /domains/remove?domain=Y` | Remove a domain |
| `GET /reload` | Reload config from disk |
| `GET /stop` | Stop the service |
| `GET /api/stats` | Stats for dashboard |
| `GET /api/logs` | Request log for dashboard |

## File Structure

```
company-auto-proxy/
├── config.json                 # Your configuration
├── config.default.json         # Default configuration template
├── src/
│   ├── config.json             # Runtime config (used by service)
│   ├── proxy-service.ps1       # Main daemon (proxy + control API + dashboard)
│   ├── proxy-cli.ps1           # CLI tool
│   ├── proxy-tray.ps1          # System tray UI
│   ├── dashboard.html          # Web dashboard
│   ├── pac-server.ps1          # Legacy PAC server (unused in v2)
│   ├── proxy-switch.ps1        # Legacy network switcher (unused in v2)
│   ├── proxy.pac.template      # Legacy PAC template
│   └── start-proxy-switch.vbs  # Legacy silent launcher
├── shell/
│   ├── bashrc-snippet.sh
│   └── powershell-profile-snippet.ps1
├── install.ps1                 # Legacy installer
└── uninstall.ps1               # Legacy uninstaller
```

## Requirements

- Windows 10/11
- PowerShell 5.1+

## Notes

- The service must be running for proxy to work — it's the actual proxy server, not just a config tool
- Browsers using "Use system proxy settings" will automatically route through the local proxy
- CLI tools (git, curl, gh, pip, etc.) use the `HTTP_PROXY`/`HTTPS_PROXY` environment variables
- When WiFi detection is off, the service always operates in CORP mode (whitelist routing active)
- When WiFi detection is on and you're not on corporate WiFi, all traffic goes direct (no upstream proxy used)

## License

MIT
