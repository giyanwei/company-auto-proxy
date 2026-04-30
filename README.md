# company-proxy-auto

Network-aware proxy auto-switch for Windows. Automatically enables/disables proxy based on your WiFi network, with PAC-based domain routing.

## Features

- **Network-aware**: Detects WiFi SSID and only enables proxy on corporate network
- **Domain whitelist**: PAC file routes only specified domains through proxy, everything else goes direct
- **Failover support**: Multiple proxy servers with automatic failover
- **CLI integration**: Dynamic `HTTPS_PROXY` environment variable for git, gh, curl, pip, etc.
- **Shell hooks**: Real-time proxy switching in already-open terminals (Bash + PowerShell)
- **Auto-start**: Windows scheduled task starts on login, runs silently in background

## Quick Start

```powershell
# 1. Clone the repo
git clone https://github.com/giyanwei/company-proxy-auto.git
cd company-proxy-auto

# 2. Create your config (edit with your proxy settings)
cp config.example.json config.json
# Edit config.json - set your proxy addresses, WiFi SSID pattern, and domains

# 3. Install
powershell -ExecutionPolicy Bypass -File install.ps1
```

## Configuration

Edit `config.json`:

```json
{
  "proxies": ["http://your-proxy:8080"],
  "ssid_pattern": "YourCompanyWiFi",
  "install_path": "%USERPROFILE%\\.proxy",
  "pac_port": 7999,
  "domains": {
    "github": ["github.com", "githubusercontent.com"],
    "google": ["google.com", "googleapis.com"],
    ...
  }
}
```

| Field | Description |
|-------|-------------|
| `proxies` | Proxy server URLs (first = primary, rest = failover) |
| `ssid_pattern` | Regex pattern to match corporate WiFi SSID |
| `install_path` | Where to install runtime files |
| `pac_port` | Local HTTP port for PAC file server |
| `domains` | Categorized domain whitelist (only these go through proxy) |

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│ proxy-switch.ps1 (background, every 30s)                │
│                                                         │
│  WiFi SSID ──match?──► Enable PAC + set env vars        │
│             no match──► Clear PAC + unset env vars       │
└─────────────────────────────────────────────────────────┘
         │                        │
         ▼                        ▼
┌─────────────────┐    ┌──────────────────────┐
│ pac-server.ps1  │    │ state file           │
│ localhost:7999  │    │ "CORP" or "OTHER"    │
│ serves PAC file │    │ read by shell hooks  │
└─────────────────┘    └──────────────────────┘
         │                        │
         ▼                        ▼
┌─────────────────┐    ┌──────────────────────┐
│ Browser         │    │ Terminal (bash/ps)    │
│ reads PAC       │    │ PROMPT_COMMAND reads  │
│ per-domain      │    │ state → sets proxy   │
│ routing         │    │ env var dynamically   │
└─────────────────┘    └──────────────────────┘
```

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1

# Keep install directory (only remove task + settings):
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -KeepFiles
```

## File Structure

```
company-proxy-auto/
├── config.example.json        # Configuration template
├── install.ps1                # One-click installer
├── uninstall.ps1              # Clean uninstaller
├── src/
│   ├── proxy.pac.template     # PAC template (populated at install time)
│   ├── proxy-switch.ps1       # Main daemon (network detection + switch)
│   ├── pac-server.ps1         # Local HTTP server for PAC
│   └── start-proxy-switch.vbs # Silent launcher (no window popup)
└── shell/
    ├── bashrc-snippet.sh              # Git Bash integration
    └── powershell-profile-snippet.ps1 # PowerShell integration
```

## Requirements

- Windows 10/11
- PowerShell 5.1+
- Git for Windows (for Git Bash support)
- Node.js (for npm proxy config, optional)

## Notes

- Browsers must be set to "Use system proxy" (disable proxy plugins or set them to system mode)
- PAC file is served via `http://127.0.0.1:7999/proxy.pac` because Chromium browsers reject `file://` PAC
- CLI tools (git, npm) have their own proxy config set by the installer
- Other CLI tools (gh, curl, pip, cargo, etc.) use `HTTPS_PROXY` environment variable via shell hooks

## License

MIT
