# Company Auto Proxy (CAP)

> Windows proxy auto-switch tool — automatic corporate/direct routing based on network detection.

## Project Context

- **Stack**: PowerShell 5.1 + .NET Framework BCL (zero external dependencies)
- **Architecture**: Proxy daemon + Control API + CLI/Tray/Dashboard interfaces
- **Planning**: `.planning/` directory contains roadmap, requirements, research, codebase map

## Quick Commands

```powershell
# Run proxy service
pwsh src/proxy-service.ps1

# CLI control
bin/cap on | off | status

# Install/Uninstall
pwsh install.ps1
pwsh uninstall.ps1
```

## GSD Workflow

This project uses structured planning. Key commands:

- `/gsd-progress` — check current state and next steps
- `/gsd-plan-phase N` — plan a specific phase
- `/gsd-execute-phase N` — execute a planned phase
- `/gsd-verify-work` — validate completed work

## Current State

See `.planning/STATE.md` for active phase and progress.

## Code Conventions

- PowerShell 5.1 compatible (no PS 7+ features)
- .NET types loaded via `Add-Type -AssemblyName`
- Config via JSON files (no external modules)
- UTF-8 encoding for all text files
- Structured logging in JSON Lines format (when implemented)
