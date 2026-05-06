# Testing Patterns

**Analysis Date:** 2026-05-06

## Test Framework

**Runner:**
- None. No test framework is configured or used in this project.

**Assertion Library:**
- None.

**Run Commands:**
```bash
# No test commands available
# No test scripts in package manifest or Makefile
```

## Test File Organization

**Location:**
- No test files exist anywhere in the repository.
- No `tests/`, `test/`, `__tests__/`, or `spec/` directories.
- No `*.test.ps1`, `*.Tests.ps1`, `*.spec.ps1` files (Pester convention).
- No `*_test.go` files (the `internal/` and `cmd/` directories are empty placeholder structures).

**Naming:**
- Not applicable.

## Test Coverage

**Requirements:** None enforced. No coverage tooling configured.

**Current Coverage:** 0% - no automated tests exist.

## CI/CD

**Pipeline:**
- No CI/CD configuration exists.
- No `.github/workflows/` directory.
- No `Jenkinsfile`, `.gitlab-ci.yml`, `azure-pipelines.yml`, or equivalent.
- No `Makefile` or build script beyond `install.ps1`.

**Deployment:**
- Manual installation via `install.ps1` or `cap install`
- No automated release process
- `proxy.exe` binary checked into repository (no build pipeline)

## Testing Gap Analysis

**Critical untested areas:**

| Area | Files | Risk |
|------|-------|------|
| Proxy routing logic | `src/proxy-service.ps1` (lines 334-342, `Test-Match` function) | Domain matching could silently fail, routing traffic incorrectly |
| System proxy enable/disable | `src/proxy-service.ps1` (lines 59-76) | Registry manipulation could leave system in broken proxy state |
| Config loading/fallback | All scripts (config loading pattern) | Missing config could crash service silently |
| Control API endpoints | `src/proxy-service.ps1` (lines 122-328) | API could return malformed JSON or fail on edge cases |
| CONNECT tunnel handling | `src/proxy-service.ps1` (lines 363-399) | Network errors during tunnel setup could leak connections |
| WiFi SSID detection | `src/proxy-service.ps1` (lines 99-106, `Get-CurrentSSID`) | Regex parsing of `netsh` output is fragile |
| Install/uninstall lifecycle | `install.ps1`, `uninstall.ps1` | Could leave orphaned tasks, broken PATH, or stale registry entries |
| Shell profile injection | `install.ps1` (lines 100-136) | Marker-based injection could corrupt user profiles |

## Recommended Test Strategy

**If adding tests, use Pester (PowerShell testing framework):**

```powershell
# Recommended: Install Pester 5.x
# Install-Module -Name Pester -Force -SkipPublisherCheck

# Suggested test file structure:
# tests/
#   proxy-service.Tests.ps1
#   proxy-cli.Tests.ps1
#   domain-matcher.Tests.ps1
#   config-loader.Tests.ps1
```

**Suggested Pester test pattern for this codebase:**

```powershell
# tests/domain-matcher.Tests.ps1
Describe "Test-Match" {
    BeforeAll {
        # Extract the function from proxy-service.ps1 or refactor into module
        function Test-Match($h, $ds, $st) {
            $h = $h.ToLower()
            if ($h -match '^(.+):(\d+)$') { $h = $Matches[1] }
            if ($h -eq 'localhost' -or $h -eq '127.0.0.1' -or $h -eq '::1') { return $false }
            if ($st.NetworkState -eq "OTHER") { return $false }
            if ($ds.ContainsKey($h)) { return $true }
            foreach ($d in @($ds.Keys)) { if ($h.EndsWith(".$d")) { return $true } }
            return $false
        }

        $domainSet = @{ "github.com" = $true; "google.com" = $true }
    }

    It "matches exact domain" {
        $state = @{ NetworkState = "CORP" }
        Test-Match "github.com" $domainSet $state | Should -Be $true
    }

    It "matches subdomain" {
        $state = @{ NetworkState = "CORP" }
        Test-Match "api.github.com" $domainSet $state | Should -Be $true
    }

    It "skips localhost" {
        $state = @{ NetworkState = "CORP" }
        Test-Match "localhost" $domainSet $state | Should -Be $false
    }

    It "skips all when network is OTHER" {
        $state = @{ NetworkState = "OTHER" }
        Test-Match "github.com" $domainSet $state | Should -Be $false
    }

    It "strips port from host" {
        $state = @{ NetworkState = "CORP" }
        Test-Match "github.com:443" $domainSet $state | Should -Be $true
    }
}
```

**Integration test approach:**
```powershell
# tests/control-api.Tests.ps1
Describe "Control API" {
    BeforeAll {
        # Start service in background for integration tests
        $proc = Start-Process powershell -ArgumentList "-File src/proxy-service.ps1" -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 3
    }

    AfterAll {
        Invoke-RestMethod -Uri "http://127.0.0.1:8082/stop" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }

    It "returns status JSON" {
        $status = Invoke-RestMethod -Uri "http://127.0.0.1:8082/status"
        $status.running | Should -Be $true
        $status.proxy_addr | Should -Be "127.0.0.1:8081"
    }

    It "toggles proxy off and on" {
        Invoke-RestMethod -Uri "http://127.0.0.1:8082/proxy/off"
        $status = Invoke-RestMethod -Uri "http://127.0.0.1:8082/status"
        $status.proxy_enabled | Should -Be $false

        Invoke-RestMethod -Uri "http://127.0.0.1:8082/proxy/on"
        $status = Invoke-RestMethod -Uri "http://127.0.0.1:8082/status"
        $status.proxy_enabled | Should -Be $true
    }
}
```

## Manual Testing

**Current approach is entirely manual:**

1. Run `.\src\proxy-cli.ps1 start` and verify console output
2. Run `.\src\proxy-cli.ps1 status` to confirm service is running
3. Test proxy routing by visiting whitelisted domains in browser
4. Check system proxy settings in Windows Internet Options
5. Run `.\src\proxy-cli.ps1 stop` and verify cleanup

**No documented test plan or QA checklist exists in the repository.**

## Test Infrastructure Blockers

**Challenges to adding tests:**

1. **No module structure** - Functions are defined inline within scripts, not exported from modules. Testing requires either:
   - Extracting functions into `.psm1` modules
   - Dot-sourcing scripts (risks side effects from script-level code)
   - Duplicating function definitions in test files

2. **System side effects** - Scripts modify Windows registry, environment variables, and scheduled tasks. Tests need:
   - Mocking of `Set-ItemProperty`, `Register-ScheduledTask`, etc.
   - Sandboxed registry hive or cleanup fixtures
   - Non-admin test mode

3. **Network dependencies** - Proxy handler requires actual TCP connections. Tests need:
   - Mock TCP clients/servers
   - Loopback-only test configuration

4. **No separation of concerns** - `proxy-service.ps1` is a 540-line monolith containing proxy logic, control API, state management, and system integration all in one file.

---

*Testing analysis: 2026-05-06*
