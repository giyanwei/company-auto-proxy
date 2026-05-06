# Codebase Structure

**Analysis Date:** 2026-05-06

## Directory Layout

```
company-auto-proxy/
├── bin/                        # CLI entry point shims (cross-shell `cap` command)
│   ├── cap                     # Bash entry point
│   ├── cap.cmd                 # Windows CMD entry point
│   └── cap.ps1                 # PowerShell entry point (resolves to proxy-cli.ps1)
├── cmd/                        # [EMPTY] Planned Go binary entry point (unused)
│   └── proxy/                  # [EMPTY]
├── internal/                   # [EMPTY] Planned Go internal packages (unused)
│   ├── config/                 # [EMPTY]
│   ├── dashboard/              # [EMPTY]
│   │   └── static/             # [EMPTY]
│   ├── matcher/                # [EMPTY]
│   ├── proxy/                  # [EMPTY]
│   └── service/                # [EMPTY]
├── shell/                      # Shell profile integration snippets
│   ├── bashrc-snippet.sh       # Bash prompt hook for env var sync
│   └── powershell-profile-snippet.ps1  # PS prompt hook for env var sync
├── src/                        # Core source code (PowerShell)
│   ├── config.json             # Runtime configuration (used by service)
│   ├── dashboard.html          # Web dashboard single-page app (294 lines)
│   ├── pac-server.ps1          # [LEGACY v1] PAC file HTTP server
│   ├── proxy.pac.template      # [LEGACY v1] PAC file template with placeholders
│   ├── proxy-cli.ps1           # CLI tool with all commands (403 lines)
│   ├── proxy-service.ps1       # Main daemon - proxy + control API (541 lines)
│   ├── proxy-switch.ps1        # [LEGACY v1] SSID-based proxy config switcher
│   ├── proxy-tray.ps1          # System tray icon application (271 lines)
│   └── start-proxy-switch.vbs  # [LEGACY v1] Silent VBScript launcher
├── config.default.json         # Default configuration template (v2)
├── config.example.json         # Example configuration (v1 format, has pac_port)
├── config.json                 # User configuration (v2 format, has proxy_port/control_port)
├── install.ps1                 # [LEGACY v1] Full installer (PAC gen, git/npm config, shell profiles)
├── proxy.exe                   # [COMPILED] Pre-built binary (purpose unclear, possibly planned Go rewrite)
├── README.md                   # Project documentation
└── uninstall.ps1               # [LEGACY v1] Full uninstaller
```

## Directory Purposes

**`bin/`:**
- Purpose: Cross-platform CLI entry points for the `cap` command
- Contains: Shell scripts (bash, cmd, ps1) that resolve and invoke `src/proxy-cli.ps1`
- Key files: `cap.ps1` is the primary dispatcher; `cap.cmd` for CMD; `cap` for Git Bash/WSL

**`src/`:**
- Purpose: All active PowerShell source code and the dashboard HTML
- Contains: Service daemon, CLI, tray app, dashboard UI, runtime config
- Key files: `proxy-service.ps1` (core daemon), `proxy-cli.ps1` (CLI), `proxy-tray.ps1` (tray), `dashboard.html` (web UI)

**`shell/`:**
- Purpose: Shell profile snippets injected during install for dynamic proxy env var sync
- Contains: Bash and PowerShell hooks that read state file on every prompt
- Key files: `bashrc-snippet.sh`, `powershell-profile-snippet.ps1`

**`cmd/` and `internal/`:**
- Purpose: Scaffolded directories for a planned Go rewrite (currently empty)
- Contains: Empty directories matching Go project layout conventions
- Key files: None (all empty)

## Key File Locations

**Entry Points:**
- `bin/cap.ps1`: PowerShell CLI entry point - resolves proxy-cli.ps1 location and invokes it
- `bin/cap.cmd`: CMD CLI entry point - same resolution logic in batch
- `bin/cap`: Bash CLI entry point - for Git Bash / WSL usage
- `src/proxy-service.ps1`: Service daemon entry point (launched by `cap start` or scheduled task)
- `src/proxy-tray.ps1`: System tray app entry point (launched by `cap start` in full mode or scheduled task)

**Configuration:**
- `config.default.json`: Canonical default config (v2 format with `proxy_port`, `control_port`, `upstream_proxies`, `install_path`)
- `config.json`: Root-level user config (v2 format, same schema as default)
- `src/config.json`: Runtime config copy (service reads from its own directory)
- `config.example.json`: Legacy v1 config format (has `proxies`, `pac_port` instead of v2 fields)

**Core Logic:**
- `src/proxy-service.ps1`: Entire proxy server + control API + WiFi monitor in one file
- `src/proxy-cli.ps1`: All CLI commands including install/uninstall

**User Interface:**
- `src/dashboard.html`: Single-file web dashboard (HTML + inline CSS + JS)
- `src/proxy-tray.ps1`: Windows Forms NotifyIcon-based tray application

**Shell Integration:**
- `shell/powershell-profile-snippet.ps1`: Hooks into PS prompt, reads state file, sets/unsets env vars
- `shell/bashrc-snippet.sh`: Hooks into PROMPT_COMMAND, reads state file, exports/unsets env vars

**Legacy (v1 - PAC-based approach):**
- `src/proxy-switch.ps1`: SSID polling loop that sets PAC URL + git/npm proxy
- `src/pac-server.ps1`: HTTP listener serving proxy.pac file
- `src/proxy.pac.template`: PAC file template with `{{DOMAINS}}` and `{{PROXY_STRING}}` placeholders
- `src/start-proxy-switch.vbs`: VBScript to launch proxy-switch.ps1 silently
- `install.ps1`: v1 installer (generates PAC, copies scripts, registers task, configures shells)
- `uninstall.ps1`: v1 uninstaller (stops processes, removes task, clears settings, cleans profiles)

## Naming Conventions

**Files:**
- PowerShell scripts: `kebab-case.ps1` (e.g., `proxy-service.ps1`, `proxy-cli.ps1`)
- Shell scripts: `kebab-case.sh` or plain name (e.g., `bashrc-snippet.sh`, `cap`)
- Config files: `kebab-case.json` (e.g., `config.default.json`)
- Entry point shims: short name without extension or with platform extension (`cap`, `cap.cmd`, `cap.ps1`)

**Directories:**
- Lowercase, short names (`bin/`, `src/`, `shell/`, `cmd/`, `internal/`)
- Go-style layout for planned rewrite (`cmd/proxy/`, `internal/config/`, etc.)

## Where to Add New Code

**New Service Feature (e.g., new API endpoint):**
- Add endpoint handler in the `switch -Wildcard ($path)` block in `src/proxy-service.ps1` (lines 145-309)
- If it needs shared state, add field to `$script:State` hashtable (line 25)

**New CLI Command:**
- Add case in the `switch ($Command)` block in `src/proxy-cli.ps1` (line 62)
- Update the help text at line 370

**New Tray Menu Item:**
- Add to context menu setup in `src/proxy-tray.ps1` (around lines 65-177)
- Update `Update-TrayState` function if it needs status tracking

**New Configuration Key:**
- Add to `config.default.json` with default value
- Add to `src/config.json` 
- Handle in `src/proxy-service.ps1` initialization section (lines 22-46)
- Add CLI support in `src/proxy-cli.ps1` config set command (lines 190-222)

**New Shell Integration:**
- Add snippet file to `shell/` directory
- Update `install.ps1` or `src/proxy-cli.ps1` install command to inject it

**New Dashboard Feature:**
- Modify `src/dashboard.html` (single-file app, all inline)
- If new API data needed, add endpoint to control API in `src/proxy-service.ps1`

**Go Rewrite Components:**
- Entry point: `cmd/proxy/main.go`
- Config loading: `internal/config/`
- Domain matching: `internal/matcher/`
- Proxy handler: `internal/proxy/`
- Service lifecycle: `internal/service/`
- Dashboard static assets: `internal/dashboard/static/`

## Special Directories

**`cmd/` and `internal/`:**
- Purpose: Scaffolded for Go rewrite (standard Go project layout)
- Generated: No (manually created as structure placeholder)
- Committed: Yes (empty directories tracked via git)
- Status: Currently unused; `proxy.exe` in root may be a pre-built Go binary

**`.planning/`:**
- Purpose: Project planning and codebase analysis documents
- Generated: By tooling (GSD workflow)
- Committed: Yes

**Install Directory (`%USERPROFILE%\.proxy/`):**
- Purpose: Runtime installation location on user's machine
- Generated: Yes (by `cap install` or `install.ps1`)
- Committed: No (exists only on user's machine)
- Contains: Copied scripts, runtime config, state file, PID file

## Two-Version Architecture

The codebase contains two distinct architectures:

**v1 (Legacy - PAC-based):**
- Uses `install.ps1` / `uninstall.ps1` as entry points
- Runs `proxy-switch.ps1` as a background polling daemon
- Serves `proxy.pac` via `pac-server.ps1` on port 7999
- Sets browser to use PAC URL for auto-configuration
- Directly configures git/npm proxy settings
- Shell snippets read state file to sync env vars per-prompt

**v2 (Current - Local proxy interception):**
- Uses `cap` CLI (`bin/cap.*` -> `src/proxy-cli.ps1`) as entry point
- Runs `proxy-service.ps1` as a full local proxy server on port 8081
- Sets Windows system proxy registry + env vars to redirect ALL traffic through local proxy
- Domain matching happens inside the proxy (not in PAC file)
- Includes control API, web dashboard, and system tray UI
- Install/uninstall embedded in CLI (`cap install` / `cap uninstall`)

**Active components (v2):** `src/proxy-service.ps1`, `src/proxy-cli.ps1`, `src/proxy-tray.ps1`, `src/dashboard.html`, `bin/cap*`, `config.default.json`

**Legacy components (v1):** `src/proxy-switch.ps1`, `src/pac-server.ps1`, `src/proxy.pac.template`, `src/start-proxy-switch.vbs`, `install.ps1`, `uninstall.ps1`, `config.example.json`

## Config File Resolution

The service (`proxy-service.ps1`) resolves config as follows:
1. Look for `config.json` in `$scriptDir` (same directory as the script)
2. If not found, copy from `config.default.json` in parent directory
3. If neither found, error and exit

The CLI (`proxy-cli.ps1`) uses the same resolution, falling back to hardcoded defaults `{ control_port: 8082, proxy_port: 8081 }` if no config exists.

---

*Structure analysis: 2026-05-06*
