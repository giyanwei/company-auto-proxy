# Codebase Concerns

**Analysis Date:** 2026-05-06

## Tech Debt

**Legacy Code Left In Place:**
- Issue: The v1 approach (PAC-based proxy with polling loop) is still present alongside the v2 service-based architecture. Files are acknowledged as "Legacy" in README but remain in the source tree and are part of the `install.ps1` flow.
- Files: `src/proxy-switch.ps1`, `src/pac-server.ps1`, `src/proxy.pac.template`, `src/start-proxy-switch.vbs`, `install.ps1`, `uninstall.ps1`
- Impact: Confusion about which install method is current; `install.ps1` runs the v1 flow (PAC server + polling loop), contradicting the v2 `proxy-cli.ps1 install` approach. Users may accidentally run the wrong installer.
- Fix approach: Remove legacy files or clearly gate them behind a `--legacy` flag. Delete `install.ps1`/`uninstall.ps1` at project root and direct all users to `cap install`.

**Duplicate Config Files:**
- Issue: Three near-identical config files exist at the root (`config.json`, `config.default.json`, `config.example.json`) plus a fourth copy at `src/config.json`. The runtime service loads from `src/config.json` while the root `install.ps1` uses root `config.json`.
- Files: `config.json`, `config.default.json`, `config.example.json`, `src/config.json`
- Impact: Config drift between root and src copies. `config.json` is in `.gitignore` but `src/config.json` is tracked in git with hardcoded corporate proxy URLs.
- Fix approach: Consolidate to a single `config.default.json` template at root. Have service resolve config from one canonical location (e.g., `%USERPROFILE%\.proxy\config.json`). Remove `src/config.json` from version control.

**Compiled Binary Without Source:**
- Issue: `proxy.exe` (10MB) is committed to the repo. The `internal/` and `cmd/` directories appear to be Go source for a compiled proxy but contain no `.go` files (likely the Go source was deleted or lives elsewhere).
- Files: `proxy.exe`, `internal/` (empty subdirs: config, dashboard, matcher, proxy, service), `cmd/proxy/`
- Impact: Cannot rebuild the binary. Unclear whether `proxy.exe` is even used in the current PowerShell-based architecture. Dead artifact consuming repo space.
- Fix approach: Either restore Go source with a build script, or remove `proxy.exe` and empty `internal/`/`cmd/` directories. Add to `.gitignore` if the binary should not be tracked.

**No Upstream Proxy Failover:**
- Issue: The service reads `upstream_proxies` array but only ever uses the first entry (`$script:Config.upstream_proxies[0]`). The second proxy is never tried on failure.
- Files: `src/proxy-service.ps1` (line 477)
- Impact: If the primary upstream proxy is down, all proxied connections fail with 502 despite a backup being configured.
- Fix approach: Implement round-robin or failover logic in `$proxyHandler` that tries subsequent proxies on connection failure.

## Known Bugs

**TcpClient Connection Leak in Test-ServiceRunning:**
- Symptoms: Each call to `Test-ServiceRunning` or `Test-Running` creates a `TcpClient` that is never closed/disposed.
- Files: `src/proxy-cli.ps1` (line 55), `src/proxy-tray.ps1` (line 26)
- Trigger: Calling `cap status` repeatedly or tray icon polling every 5 seconds.
- Workaround: Connections will eventually be garbage-collected, but under rapid polling this leaks sockets.

**HTTP Request Body Not Forwarded:**
- Symptoms: POST/PUT/PATCH requests forwarded via the HTTP (non-CONNECT) path do not read or forward the request body.
- Files: `src/proxy-service.ps1` (lines 401-443, specifically `$reqMsg` creation at line 421)
- Trigger: Any HTTP-method request (not HTTPS/CONNECT) that includes a body (e.g., `curl -X POST http://...` with data).
- Workaround: Most modern traffic uses HTTPS (CONNECT tunneling) where the full stream is tunneled, so this rarely manifests. Plain HTTP with bodies is affected.

**HTTP Request Headers Not Forwarded:**
- Symptoms: The proxy reads and discards all client request headers (the `while ($true)` loop at lines 358-361). Only the request line is preserved.
- Files: `src/proxy-service.ps1` (lines 358-361)
- Trigger: Any HTTP request where custom headers (Authorization, Content-Type, etc.) matter.
- Workaround: CONNECT-based tunneling (HTTPS) is unaffected since the full TCP stream is forwarded.

**Race Condition on Config File Writes:**
- Symptoms: Concurrent requests to the control API can corrupt `config.json` because multiple runspaces read/modify/write without locking.
- Files: `src/proxy-service.ps1` (multiple locations: lines 210, 224, 236, 265-267, 275-279)
- Trigger: Two API calls (e.g., `/domains/add` and `/settings/auto_start`) arriving simultaneously.
- Workaround: Unlikely in practice since the dashboard refreshes serially, but possible from concurrent CLI calls.

## Security Considerations

**Control API Has No Authentication:**
- Risk: Any process on localhost can send commands to the control API (enable/disable proxy, add domains, stop service, modify SSID pattern). While bound to 127.0.0.1, any local user or malware can manipulate the proxy.
- Files: `src/proxy-service.ps1` (line 129: listener bound to `http://127.0.0.1:${controlPort}/`)
- Current mitigation: Bound to loopback only.
- Recommendations: Add a shared secret token (stored in config, checked via header) or use a named pipe for IPC. Consider rate-limiting `/stop` and `/settings/*` endpoints.

**All API Mutations Use GET:**
- Risk: The entire control API uses GET for state-changing operations (`/proxy/on`, `/proxy/off`, `/stop`, `/domains/add`, `/settings/*`). This makes the API vulnerable to CSRF attacks from any webpage if a browser has access (which it does since system proxy routes through the local server).
- Files: `src/proxy-service.ps1` (all API endpoints), `src/dashboard.html` (uses `fetch()` with no method specified, defaulting to GET)
- Current mitigation: None.
- Recommendations: Use POST for state-changing operations. Add CSRF protection (origin check or token) for dashboard requests.

**Corporate Proxy URLs Committed to Git:**
- Risk: `config.default.json` and `src/config.json` contain internal corporate proxy hostnames (`proxy.pvgl.sap.corp:8080`, `proxy-cn.sin.sap.corp:8080`). This leaks internal infrastructure naming.
- Files: `config.default.json` (lines 4-7), `src/config.json` (lines 5-8)
- Current mitigation: None.
- Recommendations: Replace with placeholder URLs (e.g., `http://your-proxy:8080`) in committed files. Use `config.example.json` pattern properly and add real config to `.gitignore`.

**ExecutionPolicy Bypass Everywhere:**
- Risk: All process launches use `-ExecutionPolicy Bypass`, which disables PowerShell's script execution policy. While necessary for the tool to work, it trains users to accept bypass patterns and any script injected into the install path runs without restriction.
- Files: `src/proxy-cli.ps1` (line 68), `bin/cap.cmd` (line 3), `src/proxy-tray.ps1` (line 94), `install.ps1` (line 92), `src/start-proxy-switch.vbs` (line 6)
- Current mitigation: None.
- Recommendations: Sign scripts with a code-signing certificate, or scope bypass to just the service scripts.

**Dashboard XSS via Domain Names:**
- Risk: The dashboard renders domain names and host values from API responses directly into innerHTML without sanitization.
- Files: `src/dashboard.html` (lines 250-256 for logs, lines 266-269 for domains)
- Trigger: An attacker adds a domain containing HTML/JS (e.g., `<img onerror=alert(1)>`) via the unauthed API, then the dashboard renders it.
- Current mitigation: None.
- Recommendations: Use `textContent` instead of `innerHTML` or escape HTML entities before rendering.

**Proxy PID File World-Readable:**
- Risk: `proxy.pid` is written to the script directory with default permissions. On shared systems, any user can read the PID.
- Files: `src/proxy-service.ps1` (line 119)
- Current mitigation: Low severity since it only exposes a PID number.
- Recommendations: Place PID file in a user-specific temp directory.

## Performance Bottlenecks

**O(n) Domain Matching on Every Request:**
- Problem: For each CONNECT/HTTP request, `Test-Match` does a hashtable lookup (O(1)) for exact match but then iterates ALL domain keys checking `$h.EndsWith(".$d")` for subdomain matching.
- Files: `src/proxy-service.ps1` (lines 334-342)
- Cause: The `foreach ($d in @($ds.Keys))` loop with `.EndsWith()` is O(n) where n = total domain count (~150+ entries).
- Improvement path: Pre-build a suffix-tree or at minimum extract the registerable domain from the hostname and check that against the set. Alternatively, split each domain on dots and check progressively (parent domain lookup).

**RunspacePool Limited to 20 Concurrent Connections:**
- Problem: The pool ceiling is hardcoded to 20 runspaces. Under heavy load (many browser tabs + CLI tools), connections queue up waiting for a free runspace.
- Files: `src/proxy-service.ps1` (line 452: `[RunspaceFactory]::CreateRunspacePool(1, 20)`)
- Cause: Arbitrary fixed limit, no dynamic scaling.
- Improvement path: Increase the pool maximum or make it configurable. Consider a connection timeout for queued requests. For truly high concurrency, the PowerShell runspace model is fundamentally limited; the Go binary approach (`proxy.exe`) would be more appropriate.

**Polling Loop at 20ms with Busy Wait:**
- Problem: The main loop busy-polls `$tcpListener.Pending()` every 20ms regardless of whether connections arrive. This wastes CPU cycles.
- Files: `src/proxy-service.ps1` (lines 491-524)
- Cause: `TcpListener.Pending()` is a non-blocking check; the pattern uses `Start-Sleep -Milliseconds 20` between checks.
- Improvement path: Use `AcceptTcpClientAsync()` or `BeginAcceptTcpClient()` with a proper async callback instead of polling.

**HttpClient Created Per Request (HTTP path):**
- Problem: Each non-CONNECT HTTP request creates a new `HttpClientHandler` + `HttpClient`, issues the request, then disposes. This prevents connection pooling.
- Files: `src/proxy-service.ps1` (lines 409-443)
- Cause: No shared HttpClient instance.
- Improvement path: Create a shared `HttpClient` per upstream configuration (proxied vs. direct) and reuse it across requests.

**Shell Profile Snippet Runs on Every Prompt:**
- Problem: The PowerShell profile snippet reads two files from disk (`state` and `.proxy_url`) on every single prompt invocation.
- Files: `shell/powershell-profile-snippet.ps1` (lines 3-8)
- Cause: The `prompt` function override calls `__CompanyProxySwitch` which does file I/O on every keystroke/command.
- Improvement path: Cache the state in a variable and only re-read on a timer or when a signal file's timestamp changes.

## Fragile Areas

**System Proxy Restoration on Crash:**
- Files: `src/proxy-service.ps1` (lines 57-76, 530-531)
- Why fragile: If the PowerShell process is killed (Task Manager, system crash, BSOD), the system proxy remains set to `127.0.0.1:8081` but nothing is listening. All network connectivity breaks until the user manually clears the proxy.
- Safe modification: Add a watchdog script or scheduled task that periodically checks if the proxy port is alive and clears system proxy if not.
- Test coverage: None.

**Mutex-Based Single Instance Guard:**
- Files: `src/proxy-service.ps1` (lines 48-52), `src/proxy-switch.ps1` (lines 12-15)
- Why fragile: The mutex name `Global\CompanyProxyAutoServiceMutex` is process-lifetime. If a previous PowerShell host crashes without releasing the mutex, a new instance cannot start until the abandoned mutex is released by the OS.
- Safe modification: Use PID file validation (check if recorded PID is still alive) as a secondary check.
- Test coverage: None.

**Control API Shutdown Ordering:**
- Files: `src/proxy-service.ps1` (lines 163-165, 527-539)
- Why fragile: The `/stop` endpoint sets `$state.Running = $false` which signals the main loop. But the main loop only checks this every 20ms. Meanwhile the control API sends `{"ok":true}` and continues running. If the client immediately tries to reconnect, the behavior is undefined.
- Safe modification: Add a graceful shutdown sequence with a drain period for active connections.
- Test coverage: None.

## Scaling Limits

**In-Memory Request Log:**
- Current capacity: 100 entries (configurable via `log_max_entries`).
- Limit: All logs are in a `ConcurrentQueue` in memory. No persistence, no export, no aggregation.
- Scaling path: Add optional file-based logging or rotate logs to disk. Consider structured log format for analysis.

**Domain List Size:**
- Current capacity: ~150 domains across 18 groups.
- Limit: The O(n) subdomain matching degrades linearly. At 1000+ domains, each request incurs noticeable overhead.
- Scaling path: Switch to suffix-tree or trie-based matching. Or pre-compile a regex for all domains.

**Single-Process Architecture:**
- Current capacity: Handles typical developer workstation traffic (tens of concurrent connections).
- Limit: PowerShell runspaces are heavyweight (~2MB RAM each). The 20-runspace pool caps at 20 concurrent TCP connections being actively proxied.
- Scaling path: Port the proxy layer to Go (the `proxy.exe` binary and empty `internal/` directories suggest this was already attempted).

## Dependencies at Risk

**PowerShell 5.1 Assumptions:**
- Risk: The code uses `System.Net.Http.HttpClient` via `Add-Type -AssemblyName System.Net.Http` which behaves differently on PowerShell 7 (uses .NET Core). Also uses Windows-specific registry manipulation and `netsh wlan`.
- Impact: Cannot run on PowerShell 7 cross-platform or on machines where PowerShell 5.1 is deprecated.
- Migration plan: Test on PowerShell 7. Abstract platform-specific calls (registry, netsh) behind an interface.

**netsh wlan Dependency:**
- Risk: WiFi SSID detection relies on `netsh wlan show interfaces` output parsing. This command's output format varies by Windows locale (English vs. other languages).
- Impact: WiFi detection silently fails on non-English Windows installations where "SSID" label is localized.
- Migration plan: Use WMI/CIM queries (`Get-CimInstance -Namespace root/WMI -ClassName MSNdis_80211_ServiceSetIdentifier`) or the Windows.Devices.WiFi WinRT API for locale-independent SSID retrieval.

## Missing Critical Features

**No Proxy Authentication Support:**
- Problem: The upstream proxy connection sends bare `CONNECT host:port HTTP/1.1` without Proxy-Authorization headers.
- Blocks: Cannot work with upstream proxies that require NTLM, Basic, or Kerberos authentication.
- Files: `src/proxy-service.ps1` (line 375: CONNECT request construction)

**No HTTPS for Control API/Dashboard:**
- Problem: The control API and dashboard are served over plain HTTP. While on localhost, this still allows network-adjacent attackers on shared machines to sniff dashboard traffic.
- Blocks: Any enterprise security scanning tool will flag the open HTTP listener.

**No Logging to File:**
- Problem: All service output goes to the PowerShell console (hidden window). No persistent logs exist for troubleshooting.
- Blocks: Post-mortem debugging when the service crashes or misbehaves. Users cannot provide logs for bug reports.

**No Graceful Handling of Network Disconnection:**
- Problem: If the upstream proxy becomes unreachable mid-connection, the `CopyToAsync` operations hang until TCP timeout (potentially minutes).
- Blocks: Quick failover. Users experience long hangs instead of immediate errors.
- Files: `src/proxy-service.ps1` (lines 383-385, proxy CONNECT tunnel)

**No Health Check Endpoint:**
- Problem: External monitoring cannot verify proxy health beyond "port is open."
- Blocks: Integration with enterprise monitoring systems.

## Test Coverage Gaps

**No Tests Exist:**
- What's not tested: The entire codebase has zero automated tests. No unit tests, no integration tests, no end-to-end tests.
- Files: All `src/*.ps1` files
- Risk: Any change to domain matching, proxy routing, config handling, or API endpoints could introduce regressions undetected.
- Priority: High. Key areas to test first:
  1. Domain matching logic (`Test-Match` function in `src/proxy-service.ps1`)
  2. Config loading/saving (JSON round-trip, edge cases)
  3. System proxy enable/disable (registry operations)
  4. Control API endpoint responses

---

*Concerns audit: 2026-05-06*
