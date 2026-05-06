# Domain Pitfalls

**Domain:** Windows proxy auto-switch tool (PowerShell-based)
**Researched:** 2026-05-06
**Focus:** Reliability, installer, self-healing, open-source distribution, Windows proxy manipulation

---

## Critical Mistakes

Mistakes that cause total connectivity loss, data corruption, or require manual intervention to recover from.

### Pitfall 1: Orphaned System Proxy (The "Bricked Internet" Problem)

**What goes wrong:** The tool sets `HKCU:\...\Internet Settings\ProxyEnable = 1` and `ProxyServer = 127.0.0.1:8081` on startup. If the process is killed (Task Manager, BSOD, `Stop-Process -Force`, power loss), the proxy remains pointed at a dead port. All HTTP/HTTPS traffic fails system-wide. The user has no internet until they manually fix it.

**Why it happens:** `Disable-SystemProxy` only runs in the cooperative shutdown path (line 531 of proxy-service.ps1). A hard kill bypasses PowerShell's `try/finally` blocks entirely.

**Consequences:** Complete loss of internet connectivity. Non-technical users cannot self-recover. This is the single highest-severity bug possible in a proxy tool.

**Prevention:**
1. Implement a watchdog scheduled task (runs every 60s) that checks if port 8081 is alive; if not, clears the registry proxy.
2. Save pre-proxy state (original ProxyEnable, ProxyServer values) to a recovery file on startup. The watchdog restores these values, not just disables.
3. Register an `AppDomain.ProcessExit` event handler and a `Console.CancelKeyPress` handler as last-resort cleanup.
4. Consider using Windows ETW or a lightweight native helper that monitors the parent PID.

**Detection:** Users report "internet stopped working after reboot" or "had to manually go to Internet Options."

**Already present in codebase:** YES - identified in CONCERNS.md as a fragile area. No fix implemented yet.

---

### Pitfall 2: PATH Manipulation Corruption (Max Length Truncation)

**What goes wrong:** The Windows PATH environment variable (User scope) has a practical limit of ~2048 characters in the registry (REG_EXPAND_SZ) and a hard limit of ~32,767 characters. When an installer appends to PATH without checking length, it can:
- Silently truncate the value, destroying existing PATH entries
- Create duplicate entries on repeated installs
- Corrupt the value with malformed separators (trailing/leading semicolons, doubled semicolons)

**Why it happens:** Naive `[Environment]::SetEnvironmentVariable("PATH", $old + ";$new", "User")` without deduplication or length checking. Particularly dangerous because the `User` PATH is concatenated with the `System` PATH at runtime, and the combined value is what has the 32K limit.

**Consequences:** Other tools break (their PATH entries got truncated). The tool's own entry appears multiple times. Uninstall removes only one copy, leaving zombie entries.

**Prevention:**
1. Always parse PATH into an array, deduplicate, then rejoin.
2. Check total length before writing. Warn user if approaching limits.
3. Store the exact entry added in a sidecar file so uninstall can precisely remove it.
4. Use `[System.Environment]::GetEnvironmentVariable("PATH", "User")` (not `$env:PATH` which is the merged runtime value).
5. Never modify System PATH without explicit admin consent.

**Detection:** Run `$env:PATH.Split(';').Count` and look for duplicates or empty entries.

---

### Pitfall 3: Registry Writes Without Notifying WinInet (Proxy Doesn't Take Effect)

**What goes wrong:** Setting `ProxyEnable` and `ProxyServer` in the registry is necessary but NOT sufficient for all applications. Programs using WinInet cache their proxy settings at startup. Without calling `InternetSetOption` with `INTERNET_OPTION_SETTINGS_CHANGED` and `INTERNET_OPTION_REFRESH`, browsers and other apps won't pick up the change until restarted.

**Why it happens:** PowerShell's `Set-ItemProperty` writes the registry key but doesn't broadcast the change notification. The current code relies on apps eventually re-reading the registry.

**Consequences:** Proxy appears "set" in Internet Options but Chrome/Edge/corporate apps continue using the old setting until manually refreshed or restarted.

**Prevention:**
```powershell
# After setting registry values, broadcast the change
$signature = @'
[DllImport("wininet.dll", SetLastError=true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int lpdwBufferLength);
'@
$wininet = Add-Type -MemberDefinition $signature -Name WinInet -Namespace Proxy -PassThru
$wininet::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)  # INTERNET_OPTION_SETTINGS_CHANGED
$wininet::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)  # INTERNET_OPTION_REFRESH
```

**Detection:** Set proxy, open a new browser tab, check `chrome://net-internals/#proxy` -- if it still shows "Direct", the notification wasn't sent.

---

### Pitfall 4: Self-Healing Restart Loop (Crash-Restart-Crash Spiral)

**What goes wrong:** A watchdog that blindly restarts a crashed service creates an infinite restart loop when the crash is caused by a persistent condition (port already in use, corrupt config, missing dependency). This consumes CPU, generates thousands of log entries, and may trigger enterprise endpoint protection alerts.

**Why it happens:** Watchdog has no concept of "crash budget" or backoff. It sees "process dead" and restarts immediately, every time.

**Consequences:** CPU exhaustion, disk filling with logs, security tools flagging the behavior as malware, user unable to kill the zombie pair (watchdog restarts it faster than Task Manager can kill it).

**Prevention:**
1. Implement exponential backoff: 1s, 2s, 4s, 8s, 16s, max 5 minutes between restarts.
2. Track crash count in a time window. If >3 crashes in 5 minutes, stop restarting and notify user.
3. Distinguish "clean exit" (user stopped it) from "crash" (unexpected termination). Only restart on crash.
4. Before restarting, validate prerequisites: port available, config parseable, dependencies present.
5. Write a "last crash reason" file that the watchdog checks.

**Detection:** Multiple instances in Task Manager, high CPU from PowerShell processes, Event Log flooding.

---

### Pitfall 5: TcpClient / Runspace Resource Exhaustion

**What goes wrong:** PowerShell runspaces are heavyweight (~2MB RAM each). The current code creates PowerShell instances per connection but the job cleanup loop only runs once per 20ms tick. Under burst traffic (browser opening 20+ connections simultaneously), the pool exhausts, new connections queue indefinitely, and the ArrayList of jobs grows unbounded if cleanup can't keep up.

Additionally, TcpClient objects in error paths may not be disposed (the proxy handler catches exceptions silently), leaking socket handles. Windows has a default limit of ~16,000 ephemeral ports and each leaked socket holds one.

**Why it happens:** The runspace pool is capped at 20 (hardcoded). The `Test-ServiceRunning` function (line 55) creates TcpClient objects without disposing them. The proxy handler's error path does `catch {}` without cleanup.

**Consequences:** Memory leak (eventually GBs), port exhaustion causing "An operation on a socket could not be performed because the system lacked sufficient buffer space," proxy becomes unresponsive requiring manual kill.

**Prevention:**
1. Always wrap TcpClient in `try/finally` with explicit `.Close()` and `.Dispose()`.
2. Make runspace pool size configurable with a sensible default (50-100 for a proxy).
3. Add connection timeout -- drop connections waiting >30s for a free runspace.
4. Track active connection count and reject new ones at capacity with HTTP 503.
5. Periodically log resource usage (handles, memory) as health metrics.

**Already present in codebase:** YES - TcpClient leak in Test-ServiceRunning, pool limit of 20, no disposal in error paths.

---

## Warning Signs

Issues that degrade experience, cause confusion, or create support burden without total failure.

### Pitfall 6: Execution Policy Blocks First-Run Experience

**What goes wrong:** Users clone the repo, run `.\install.ps1`, and get a red error: "running scripts is disabled on this system." They then Google solutions, find advice to run `Set-ExecutionPolicy Unrestricted`, which is an over-broad security change. Alternatively, they give up.

**Why it happens:** Windows default is `Restricted` execution policy. The tool requires `Bypass` but only sets it when launching child processes (not when the user first invokes the installer).

**Consequences:** Terrible first-run experience. Support issues. Users making overly permissive security changes.

**Prevention:**
1. Provide a one-liner bootstrap that handles policy: `irm https://raw.githubusercontent.com/.../install.ps1 | iex` (this runs in-memory, bypassing file-based policy).
2. Ship a `install.cmd` wrapper that calls `powershell -ExecutionPolicy Bypass -File install.ps1`.
3. Document the exact minimum command in README.
4. Consider script signing (Authenticode) for enterprise environments.
5. Never tell users to globally change ExecutionPolicy. Use `-Scope Process` if needed.

**Already present in codebase:** The `cap.cmd` wrapper does use `-ExecutionPolicy Bypass`, but the root install.ps1 does not have a .cmd wrapper.

---

### Pitfall 7: Encoding Mismatches (BOM, UTF-8, ANSI)

**What goes wrong:** PowerShell 5.1 defaults to writing files as UTF-16LE with BOM (when using `Out-File`) or System Default ANSI (when using `Set-Content`). Configuration files written with the wrong encoding cause:
- JSON parsers choking on BOM bytes
- Git showing every line as changed (encoding flip)
- Shell profile snippets with garbled characters in non-ASCII paths
- `ConvertFrom-Json` failing silently on null-byte-prefixed content

**Why it happens:** PowerShell 5.1's encoding defaults are inconsistent across cmdlets. `Set-Content` uses system ANSI, `Out-File` uses UTF-16LE, `Add-Content` uses system ANSI. PowerShell 7 defaults to UTF-8 NoBOM, creating cross-version inconsistency.

**Consequences:** Config corruption after round-trip write. Git diff noise. Profile scripts failing on machines with different locale.

**Prevention:**
1. Always specify `-Encoding UTF8` on every file write operation.
2. Be aware that PowerShell 5.1's `-Encoding UTF8` INCLUDES a BOM. Use `[System.IO.File]::WriteAllText($path, $content)` for BOM-free UTF-8.
3. Add encoding validation when reading config (detect and handle BOM).
4. Use `.editorconfig` in the repo to enforce UTF-8 for all text files.
5. Test on systems with non-English locale (CJK Windows) where ANSI != ASCII.

---

### Pitfall 8: Locale-Dependent Command Output Parsing

**What goes wrong:** `Get-CurrentSSID` parses `netsh wlan show interfaces` looking for the string `"SSID"`. On non-English Windows installations, this field is localized (e.g., German: "SSID", Japanese: "SSID", Chinese: "SSID" -- actually SSID is usually kept, but other fields like "State" become localized). More critically, if the output format changes between Windows versions, the regex breaks silently.

**Why it happens:** Text-parsing CLI output instead of using structured APIs (WMI/CIM, WinRT).

**Consequences:** WiFi detection silently fails, proxy stays in wrong mode (always CORP or always OTHER).

**Prevention:**
1. Use `Get-CimInstance` or WMI queries for structured data.
2. For SSID: Use `Get-NetConnectionProfile` (available since Windows 8.1) which returns structured objects.
3. For any `netsh`/`ipconfig` parsing: always have a fallback and log when parsing fails rather than returning empty string.
4. Test on at least English, German, and CJK Windows installations.

**Already present in codebase:** YES - identified in CONCERNS.md under "Dependencies at Risk."

---

### Pitfall 9: Installer Leaves Partial State on Failure

**What goes wrong:** The installer performs 7 sequential steps. If step 5 (scheduled task registration) fails because it requires admin rights, steps 1-4 have already executed (files copied, git config modified, npm config modified). The system is now in a half-installed state. Re-running the installer may not be idempotent.

**Why it happens:** No transactional install logic. No rollback on failure. Steps have side effects that persist independently.

**Consequences:** Partially working system. User doesn't know what to undo manually. `uninstall.ps1` may not clean up the specific partial state.

**Prevention:**
1. Pre-flight check ALL requirements before making changes (admin rights, port availability, file write permissions, tool availability).
2. Implement dry-run mode that reports what would change without changing it.
3. Make each step idempotent (running it twice produces the same result).
4. On failure, either rollback completed steps or clearly report what was done and what remains.
5. Use a state file that records completed install steps so uninstall knows what to undo.

---

### Pitfall 10: Environment Variable Scope Confusion

**What goes wrong:** Setting `HTTP_PROXY` and `HTTPS_PROXY` with `[System.Environment]::SetEnvironmentVariable(..., "User")` modifies the registry (persistent). But running processes (including the terminal that invoked the change) don't see it until restarted. Meanwhile, `$env:HTTP_PROXY = "..."` sets it for the current process only. This creates confusion:
- The proxy "works" in new terminals but not the current one
- Tools like `git` read `$env:HTTP_PROXY` at the process level, missing the registry change
- Docker, WSL, and other subsystems may not inherit the user-level env vars at all

**Why it happens:** Windows has three env var scopes: Machine (system), User (registry), and Process (in-memory). They don't automatically synchronize.

**Consequences:** "Proxy works in PowerShell but not in Git Bash." "Proxy works after reboot but not right now." "WSL doesn't use the proxy."

**Prevention:**
1. Set BOTH the registry value (for persistence) AND the process-level value (for immediate effect in child processes).
2. Broadcast `WM_SETTINGCHANGE` after registry env var changes so Explorer and new processes pick it up.
3. Document clearly that existing terminals need restart.
4. For Git Bash / WSL, provide separate integration (`.bashrc` snippet that reads from a shared state file).
5. Never assume `$env:HTTP_PROXY` reflects the registry value.

**Already present in codebase:** Partially. The service sets User-scope env vars but doesn't broadcast WM_SETTINGCHANGE. Existing terminals don't pick up changes.

---

### Pitfall 11: Mutex Starvation After Crash

**What goes wrong:** The single-instance guard uses a named mutex (`Global\CompanyProxyAutoServiceMutex`). If the owning process is hard-killed, the mutex becomes "abandoned." The next `WaitOne(0)` call will actually SUCCEED with an `AbandonedMutexException` in .NET, but PowerShell's wrapper may not handle this case, causing the new instance to think another is running and refuse to start.

**Why it happens:** The code does `$mutex.WaitOne(0)` which returns `$false` if the mutex is held. An abandoned mutex may or may not return `$true` depending on the .NET runtime's handling.

**Consequences:** After a crash, the service refuses to restart with "Another instance is already running" until reboot or manual mutex release.

**Prevention:**
1. Use PID file validation as primary guard: read PID from file, check if that PID is alive AND is a PowerShell process running proxy-service.
2. Keep the mutex as a secondary check but catch `AbandonedMutexException`.
3. Add a `--force` flag that skips the single-instance check.
4. On startup failure, report the PID of the alleged conflicting process.

**Already present in codebase:** YES - identified in CONCERNS.md as fragile.

---

### Pitfall 12: Config File Race Condition and Corruption

**What goes wrong:** Multiple runspaces (control API, main loop) read `config.json`, modify it in memory, and write it back without file locking. Concurrent writes corrupt the file (partial JSON, interleaved writes). Once corrupted, the service cannot restart (parse failure on next load).

**Why it happens:** No file locking mechanism. `Set-Content` is not atomic on Windows (it truncates then writes, creating a window where the file is empty/partial).

**Consequences:** Config file becomes unparseable. Service won't start. User must manually fix or delete config.

**Prevention:**
1. Use atomic write pattern: write to `config.json.tmp`, then `Move-Item -Force` (rename is atomic on NTFS within the same volume).
2. Keep a `config.json.bak` before every write.
3. On startup, if `config.json` fails to parse, try `config.json.bak`, then fall back to `config.default.json`.
4. Use a mutex or lock file for write serialization.
5. Validate JSON structure before writing (schema validation).

**Already present in codebase:** YES - identified in CONCERNS.md as a known bug.

---

## Moderate Pitfalls

### Pitfall 13: Scheduled Task Requires Admin but Daily Use Should Not

**What goes wrong:** `Register-ScheduledTask` requires administrative privileges. If the installer runs without admin, this step fails. But the tool is designed to "work without admin rights for daily use." This creates a confusing permissions model.

**Prevention:**
1. Clearly separate "install" (one-time, needs admin) from "run" (daily, no admin).
2. For non-admin install, use `HKCU:\...\Run` registry key instead of Scheduled Tasks (no admin needed).
3. Alternatively, use a startup shortcut in the user's Startup folder (`shell:startup`).
4. Detect admin rights and choose the appropriate auto-start method.

---

### Pitfall 14: PowerShell Profile Pollution

**What goes wrong:** The installer injects code into the user's PowerShell `$PROFILE`. If the snippet has a bug, EVERY PowerShell session fails to start. The user may not know how to fix their profile. This is especially bad because the snippet runs on every prompt (I/O on every keystroke).

**Prevention:**
1. Profile snippet should be minimal: just source an external file that can be fixed independently.
2. Wrap the snippet in `try/catch` so errors don't break the profile.
3. The sourced file should have a version check and graceful degradation.
4. Test that profile load time stays under 100ms.
5. Provide a `cap profile-repair` command that removes/fixes the snippet.

---

### Pitfall 15: Open-Source Credential Leak

**What goes wrong:** The config contains corporate proxy URLs (`proxy.pvgl.sap.corp:8080`), internal SSID patterns, and potentially authentication details. If a user forks the repo and commits their personalized config, they leak internal infrastructure details.

**Prevention:**
1. NEVER track user-specific config in git. Only track `config.example.json` with placeholder values.
2. Add `config.json` to `.gitignore` (already done, but `src/config.json` is tracked!).
3. The installer should create `config.json` from the example, not copy a pre-filled one.
4. Add a pre-commit hook or CI check that rejects commits containing real proxy hostnames.
5. Document this clearly in CONTRIBUTING.md.

**Already present in codebase:** YES - `src/config.json` with real corporate URLs is tracked in git.

---

### Pitfall 16: Uninstall Fails to Clean PATH

**What goes wrong:** The current uninstall script (`uninstall.ps1`) removes shell profile snippets and scheduled tasks but does NOT remove the `bin/` directory from PATH. If the installer added the tool to PATH, the uninstaller leaves a dangling PATH entry pointing to a deleted directory.

**Prevention:**
1. Track exactly what PATH modifications were made (store in a manifest file during install).
2. Uninstall must parse PATH, find the exact entry, and remove it.
3. Verify after removal that PATH is still valid (no empty entries, no dangling semicolons).
4. Broadcast `WM_SETTINGCHANGE` after PATH modification.

---

### Pitfall 17: Port Conflict Without Clear Error

**What goes wrong:** If port 8081 or 8082 is already in use (by another proxy tool, development server, or previous zombie instance), `TcpListener.Start()` throws a generic "address already in use" error. The user sees a red error and doesn't know what's conflicting.

**Prevention:**
1. Before binding, check if the port is in use and identify the owning process (via `Get-NetTCPConnection` and `Get-Process`).
2. Report: "Port 8081 is in use by process 'node.exe' (PID 12345). Either stop that process or change proxy_port in config.json."
3. Consider auto-selecting an available port if the configured one is occupied (with user notification).

---

### Pitfall 18: Git Config Global Proxy Conflicts

**What goes wrong:** The installer sets `git config --global http.https://github.com.proxy`. This affects ALL git operations to GitHub, even when the proxy tool isn't running. If the user is on a personal network without the proxy, git clone fails.

**Prevention:**
1. Don't modify git global config. Instead, use `http.proxy` via environment variables that are set/unset dynamically.
2. Or use git's `includeIf` conditional config based on network state.
3. If you must set global config, ALWAYS unset it when proxy stops (not just on uninstall).
4. Better: teach users to use `$env:HTTP_PROXY` which git respects automatically.

---

## Minor Pitfalls

### Pitfall 19: ConvertTo-Json Depth Limit

**What goes wrong:** PowerShell 5.1's `ConvertTo-Json` defaults to depth 2. Nested config structures get serialized as type names (e.g., `"System.Object[]"` instead of the actual array). The code uses `-Depth 5` in some places but may miss others.

**Prevention:** Always specify `-Depth 10` or higher on every `ConvertTo-Json` call. Add a wrapper function.

---

### Pitfall 20: Start-Process Detachment on Windows

**What goes wrong:** `Start-Process powershell -WindowStyle Hidden` creates a child process that may or may not survive the parent's death, depending on how the parent exits. The job object inheritance behavior changed between Windows 10 versions.

**Prevention:** Use `-WindowStyle Hidden` combined with process creation flags that explicitly detach. Or use scheduled tasks for truly independent background processes.

---

### Pitfall 21: Dashboard innerHTML XSS

**What goes wrong:** Domain names from the API are rendered via `innerHTML`, allowing script injection if a malicious domain name is added through the unauthenticated API.

**Prevention:** Use `textContent` for all user-controlled data. Sanitize API inputs.

**Already present in codebase:** YES - identified in CONCERNS.md.

---

## Prevention Strategies

### Strategy 1: Defensive Proxy State Management

```
RULE: The system proxy must NEVER be left pointing at a dead port.

Implementation:
1. On startup: Save current proxy state to recovery file
2. During run: Watchdog verifies port liveness every 30s
3. On shutdown: Restore pre-proxy state (not just disable)
4. On crash (watchdog detects): Restore pre-proxy state
5. On machine boot: Verify proxy state matches reality
```

### Strategy 2: Atomic Configuration Writes

```
RULE: Config files must never be in a corrupt state on disk.

Implementation:
1. Write to .tmp file
2. Validate .tmp file parses correctly
3. Copy current to .bak
4. Rename .tmp to target (atomic on NTFS)
5. On read failure: try .bak, then .default
```

### Strategy 3: Idempotent Installation

```
RULE: Running the installer twice must produce the same result as running it once.

Implementation:
1. Pre-flight: check all preconditions
2. Each step: check if already done before doing it
3. PATH: deduplicate before writing
4. Profile: use markers, check for existing markers
5. Scheduled task: unregister before re-registering
6. Track all changes in an install manifest
```

### Strategy 4: Graceful Degradation

```
RULE: Partial failure should not cause total failure.

Implementation:
1. Upstream proxy unreachable? Fall back to direct.
2. WiFi detection fails? Default to configured mode.
3. Config unreadable? Use defaults + warn user.
4. Port in use? Try next port + notify.
5. Dashboard fails? Proxy still works.
6. Tray icon fails? CLI still works.
```

### Strategy 5: Self-Healing with Budget

```
RULE: Auto-recovery must have limits to prevent cascading failures.

Implementation:
1. Track restart count in sliding 5-minute window
2. Exponential backoff: 1s, 2s, 4s, 8s, 16s, ..., max 5min
3. After 3 failures in 5 minutes: stop, notify user, require manual restart
4. Before restart: validate config, check port, verify no conflicting process
5. Log every restart with reason and crash context
```

### Strategy 6: Clean Resource Management

```
RULE: Every resource acquisition must have a guaranteed release path.

Implementation:
1. TcpClient: always in try/finally with .Close()/.Dispose()
2. Runspaces: EndInvoke + Dispose in the cleanup loop, add timeout
3. HttpListener: Stop() in finally block
4. File handles: use [System.IO.File] methods that auto-close
5. Mutex: ReleaseMutex in finally, handle AbandonedMutexException
```

---

## Phase Mapping

Which phase of the roadmap should address each pitfall, based on the active requirements.

| Phase Topic | Pitfall(s) | Priority | Rationale |
|-------------|-----------|----------|-----------|
| **Self-healing & Watchdog** | #1 (Orphaned proxy), #4 (Restart loop), #11 (Mutex starvation) | CRITICAL | These are the highest-severity issues. A proxy tool that breaks internet is worse than no tool. |
| **Interactive Installer** | #2 (PATH corruption), #6 (Execution policy), #9 (Partial install), #13 (Admin requirements), #16 (Uninstall PATH) | HIGH | First-run experience is make-or-break for adoption. |
| **Full Configurability** | #12 (Config race condition), #19 (JSON depth), #7 (Encoding) | HIGH | Config is touched by every feature. Get it right early. |
| **Structured Logging** | #5 (Resource exhaustion detection), #8 (Locale detection), #17 (Port conflict) | MEDIUM | Logging enables debugging all other pitfalls. |
| **Graceful Fallback** | #3 (WinInet notification), #10 (Env var scope), #18 (Git config conflicts) | HIGH | Proxy must handle network transitions without breaking tools. |
| **Multiple Trigger Methods** | #14 (Profile pollution), #20 (Process detachment) | MEDIUM | Trigger methods touch user shell config. |
| **Open-Source Distribution** | #6 (Execution policy), #15 (Credential leak), #21 (XSS) | HIGH | Security issues are amplified when code is public. |
| **Clean Uninstall** | #2 (PATH), #9 (Partial state), #14 (Profile), #16 (Uninstall PATH) | MEDIUM | Must reverse everything the installer did. |

### Recommended Phase Ordering (Pitfall-Informed)

1. **Config + Logging first** -- Without reliable config and observable logging, you cannot debug any other feature. Fix the config race condition and encoding issues as foundation.
2. **Self-healing + Fallback second** -- These address the critical "bricked internet" scenario. Must be rock-solid before wider distribution.
3. **Installer third** -- Once the runtime is reliable, build a proper installer that avoids partial-state and PATH issues.
4. **Triggers + Open-source last** -- These are distribution concerns; only release publicly after the tool is self-healing and properly installable.

---

## Phase-Specific Research Flags

| Phase | Needs Deeper Research? | What to Investigate |
|-------|----------------------|---------------------|
| Self-healing | YES | Windows service recovery options, PID file vs named pipe for health checking, `AppDomain.ProcessExit` reliability in PowerShell 5.1 |
| Installer | YES | MSI vs script installer tradeoffs, Windows Installer best practices for PATH modification, `WM_SETTINGCHANGE` broadcasting from PowerShell |
| Config | NO | Standard patterns (atomic write, schema validation) are well-understood |
| Logging | NO | PowerShell transcript + structured file logging is straightforward |
| Fallback | MAYBE | Need to test `InternetSetOption` P/Invoke reliability across Windows 10/11 versions |
| Open-source | YES | Code signing costs/process, PowerShell Gallery publishing requirements, license compatibility with .NET BCL usage |

---

## Sources

- Direct codebase analysis: `src/proxy-service.ps1`, `src/proxy-cli.ps1`, `install.ps1`, `uninstall.ps1`, `bin/cap.cmd`
- `.planning/codebase/CONCERNS.md` (comprehensive existing analysis)
- Domain expertise: Windows registry proxy settings behavior, PowerShell runspace lifecycle, NTFS file operations semantics
- Confidence: HIGH for codebase-specific pitfalls (directly observed), MEDIUM for Windows API behavior (based on documented .NET/Win32 behavior), could not verify against live Microsoft documentation due to network restrictions

---

*Note: Web research tools were unavailable during this session (network restrictions). All findings are based on codebase analysis and domain expertise. Pitfalls related to Windows API behavior (InternetSetOption, WM_SETTINGCHANGE) should be validated against current Microsoft documentation during implementation.*
