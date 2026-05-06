# External Integrations

**Analysis Date:** 2026-05-06

## APIs & External Services

**Corporate Proxy Servers (Upstream):**
- SAP Corporate HTTP Proxies - Traffic forwarding for whitelisted domains
  - Client: `System.Net.Sockets.TcpClient` (CONNECT) and `System.Net.Http.HttpClient` (HTTP)
  - Configuration: `config.json` → `upstream_proxies` array
  - Primary: `http://proxy.pvgl.sap.corp:8080`
  - Fallback: `http://proxy-cn.sin.sap.corp:8080`
  - Auth: None (no authentication headers observed)

**WiFi Interface (Windows OS):**
- `netsh wlan show interfaces` - SSID detection for network-aware auto-switching
  - Used by: `src/proxy-service.ps1` (function `Get-CurrentSSID`)
  - Polling interval: Every 30 seconds
  - Pattern matching: Regex match against `ssid_pattern` config value (default: `"SAP"`)

## Data Storage

**Databases:**
- None - No database used

**File Storage:**
- Local filesystem only
  - `src/config.json` - Runtime configuration (read/write by service and CLI)
  - `config.default.json` - Default template for config reset
  - `$installPath/proxy.pid` - PID file for running service instance
  - `$installPath/state` - Legacy state file (`CORP` or `OTHER`) for shell snippets
  - `$installPath/.proxy_url` - Legacy proxy URL file for shell snippets

**Caching:**
- In-memory only
  - Domain lookup: `[hashtable]::Synchronized` loaded from config at startup
  - Request log: `ConcurrentQueue[hashtable]` with configurable max entries (default: 100)
  - Stats counters: Atomic `[long]` values in synchronized hashtable

## Authentication & Identity

**Auth Provider:**
- None - No user authentication
- All API endpoints are unauthenticated (localhost-only binding provides security)
- Upstream proxy: No proxy authentication implemented (no `Proxy-Authorization` header)

## Monitoring & Observability

**Error Tracking:**
- None - Errors are silently caught in proxy handler (`catch {}`)

**Logs:**
- In-memory request log buffer (circular, max 100 entries)
  - Accessible via: `GET /api/logs` on control port
  - Fields: `time` (ISO 8601), `method`, `host`, `proxied` (bool), `status` (HTTP status code)
- Console output on service start (suppressed when running hidden via `-WindowStyle Hidden`)
- No persistent log files

**Metrics:**
- Built-in counters in `$script:State`:
  - `TotalRequests`, `ProxiedRequests`, `DirectRequests`, `ActiveConns`
  - Accessible via: `GET /status` and `GET /api/stats`
  - Reset on service restart (no persistence)

## CI/CD & Deployment

**Hosting:**
- Local Windows machine - Runs as a user-level background process
- No cloud deployment

**CI Pipeline:**
- None detected - No CI/CD configuration files (no `.github/workflows/`, no `Jenkinsfile`, etc.)

**Distribution:**
- Git clone from GitHub: `https://github.com/giyanwei/company-auto-proxy.git`
- Branch: `feature/powershell-proxy`

## Control API (Internal HTTP Service)

**Endpoint:** `http://127.0.0.1:{control_port}/` (default port 8082)

**Implementation:** `src/proxy-service.ps1` (lines 122-328, `$controlScriptBlock`)

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `GET /status` | GET | Full service status JSON |
| `GET /stop` | GET | Graceful shutdown |
| `GET /proxy/on` | GET | Enable system proxy |
| `GET /proxy/off` | GET | Disable system proxy |
| `GET /settings` | GET | Current settings |
| `GET /settings/auto_start?value=true\|false` | GET | Toggle auto-start |
| `GET /settings/wifi_detection?value=true\|false` | GET | Toggle WiFi detection |
| `GET /settings/ssid_pattern?value=X` | GET | Change SSID pattern |
| `GET /reload` | GET | Reload config from disk |
| `GET /dashboard/on` | GET | Enable dashboard |
| `GET /dashboard/off` | GET | Disable dashboard |
| `GET /domains` | GET | List all domains |
| `GET /domains/add?group=X&domain=Y` | GET | Add domain to whitelist |
| `GET /domains/remove?domain=Y` | GET | Remove domain |
| `GET /config` | GET | Full config JSON |
| `GET /api/stats` | GET | Stats for dashboard polling |
| `GET /api/logs` | GET | Request log entries |
| `GET /dashboard` | GET | Serve dashboard HTML |

**Security:** Bound to `127.0.0.1` only (loopback). No authentication. No CORS headers.

## Windows Registry Integration

**Registry Path:** `HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings`

**Keys Modified:**
| Key | Values Set | Purpose |
|-----|-----------|---------|
| `ProxyEnable` | `1` (on) / `0` (off) | Enable/disable Windows system proxy |
| `ProxyServer` | `127.0.0.1:8081` | System proxy address |
| `AutoConfigURL` | (legacy only) `http://127.0.0.1:7999/proxy.pac` | PAC file URL (v1 approach) |

**Modified by:**
- `src/proxy-service.ps1` - Enable on start, disable on stop/shutdown
- `src/proxy-cli.ps1` - During uninstall cleanup
- `src/proxy-switch.ps1` - Legacy network switcher
- `install.ps1` / `uninstall.ps1` - Legacy installer/uninstaller

## Environment Variables Integration

**Variables Set (User-level):**
| Variable | Value When Active | Set By |
|----------|-------------------|--------|
| `HTTP_PROXY` | `http://127.0.0.1:8081` | `src/proxy-service.ps1` |
| `HTTPS_PROXY` | `http://127.0.0.1:8081` | `src/proxy-service.ps1` |

**Cleared on:** Service stop, uninstall

**Shell Integration (legacy approach for per-session env vars):**
- `shell/powershell-profile-snippet.ps1` - Reads state file on every prompt, sets/unsets env vars
- `shell/bashrc-snippet.sh` - Same approach for Bash via `PROMPT_COMMAND`

## Windows Task Scheduler Integration

**Task Name:** `CompanyProxyAuto`
- Trigger: At logon
- Action: Run `proxy-service.ps1` hidden
- Execution time limit: Unlimited
- Registered by: `cap install` or `src/proxy-cli.ps1 install`

**Task Name:** `CompanyProxyAutoTray` (full mode only)
- Trigger: At logon
- Action: Run `proxy-tray.ps1` hidden
- Registered by: `cap install -Mode full`

## External Tool Configuration (Legacy Installer)

**Git:**
- Sets: `git config --global http.https://github.com.proxy <proxy-url>`
- Clears on uninstall: `git config --global --unset http.https://github.com.proxy`

**npm:**
- Sets: `npm config set proxy <proxy-url>` and `npm config set https-proxy <proxy-url>`
- Clears on uninstall: `npm config delete proxy`, `npm config delete https-proxy`

**Note:** These are only set by the legacy `install.ps1`. The v2 approach (`proxy-service.ps1`) relies on system proxy + environment variables instead of per-tool configuration.

## Webhooks & Callbacks

**Incoming:**
- None

**Outgoing:**
- None

## Environment Configuration

**Required configuration (in `config.json`):**
- `upstream_proxies` - At least one upstream corporate proxy URL
- `ssid_pattern` - Regex for corporate WiFi network detection
- `proxy_port` - Local proxy listen port (default: 8081)
- `control_port` - Control API / dashboard port (default: 8082)
- `domains` - Domain whitelist groups

**No secrets/API keys required** - The tool operates with network-level proxy forwarding, no API authentication.

---

*Integration audit: 2026-05-06*
