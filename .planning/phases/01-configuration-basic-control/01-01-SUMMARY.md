---
phase: 1
plan: 1
subsystem: config
tags: [powershell, config, validation, hot-reload, domain-matching]
dependency_graph:
  requires: []
  provides: [config-system, domain-matcher, system-proxy, config-watcher]
  affects: [proxy-service, cli, control-api]
tech_stack:
  added: [FileSystemWatcher, System.Timers.Timer]
  patterns: [atomic-write, deep-merge, debounce, synchronized-hashtable]
key_files:
  created:
    - src/modules/Config.ps1
    - src/modules/DomainMatcher.ps1
    - src/modules/SystemProxy.ps1
    - src/config.default.json
    - src/domains.json
    - src/config.schema.json
  modified: []
decisions:
  - Used synchronized hashtable for DomainSet (thread-safe for RunspacePool access)
  - Progressive subdomain stripping instead of wildcard matching (deterministic O(depth) lookup)
  - Timer-based debounce for FileSystemWatcher (avoids duplicate events from editors)
metrics:
  duration: 6m
  completed: 2026-05-07
  tasks: 6
  files_created: 6
---

# Phase 1 Plan 1: Config System Summary

Modular config system with JSON schema validation, layered defaults via deep merge, atomic NTFS writes, domain separation, and FileSystemWatcher hot-reload with debounce.

## Tasks Completed

| Task | Description | Status |
|------|-------------|--------|
| 1.1 | Config schema and default file | Done |
| 1.2 | Config module (Initialize, Merge, Validate, Save) | Done |
| 1.3 | DomainMatcher module (Initialize, Test, Add, Remove) | Done |
| 1.4 | SystemProxy module (Enable, Disable, Get-State) | Done |
| 1.5 | FileSystemWatcher hot-reload | Done |
| 1.6 | Migration helper (flat-to-nested) | Done |

## Implementation Details

### Config Module (src/modules/Config.ps1)
- `Initialize-Config`: Loads defaults, merges user config, auto-migrates flat format, validates
- `Merge-ConfigDefaults`: Recursive deep merge (user values win, PSCustomObject detection for nesting)
- `Test-ConfigValid`: Collects all errors/warnings; critical checks fail startup, lenient checks fallback
- `Save-Config`: Write-to-tmp, validate roundtrip, atomic rename
- `Start-ConfigWatcher`: FileSystemWatcher + 500ms debounce timer, validates before applying
- `Stop-ConfigWatcher`: Cleanup watcher and timer resources
- `Test-FlatConfig` / `Convert-FlatToNested`: Migration from old format

### DomainMatcher Module (src/modules/DomainMatcher.ps1)
- `Initialize-DomainSet`: Loads domains.json into synchronized hashtable (182 domains, 20 groups)
- `Test-DomainMatch`: O(1) exact + progressive subdomain stripping; bypasses localhost and non-CORP networks
- `Add-Domain` / `Remove-Domain`: Runtime mutation with atomic persistence

### SystemProxy Module (src/modules/SystemProxy.ps1)
- `Enable-SystemProxy`: Sets registry ProxyEnable=1, ProxyServer, HTTP_PROXY, HTTPS_PROXY
- `Disable-SystemProxy`: Clears all proxy settings
- `Get-SystemProxyState`: Reads current state from registry and environment

## Verification

Functional tests confirmed:
- Flat config detection on existing src/config.json
- Conversion produces correct nested structure (port 8081, SAP pattern, 20 groups)
- Deep merge preserves user values while filling defaults
- Validation passes on valid config, would catch port/URL errors
- Domain matching: exact (github.com), subdomain (foo.github.com), miss (unknown.example.org)
- Localhost bypass, OTHER-network bypass both work correctly

## Deviations from Plan

None - plan executed exactly as written.

## Commits

| Hash | Message |
|------|---------|
| 9ccfda1 | feat(config): add modular config system with validation, hot-reload, and domain separation |

## Self-Check: PASSED

All 6 created files verified present on disk. Commit 9ccfda1 verified in git log.
