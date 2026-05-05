<#
.SYNOPSIS
    Uninstall company-auto-proxy.
.DESCRIPTION
    Stops services, removes scheduled task, clears proxy settings,
    removes shell profile snippets, and optionally deletes the install directory.
#>

param(
    [switch]$KeepFiles
)

$ErrorActionPreference = "SilentlyContinue"

# --- Load config ---
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = "$projectRoot\config.json"
if (Test-Path $configFile) {
    $config = Get-Content $configFile -Raw | ConvertFrom-Json
    $installPath = $config.install_path -replace '%USERPROFILE%', $env:USERPROFILE
} else {
    $installPath = "$env:USERPROFILE\.proxy"
}

Write-Host "=== company-auto-proxy uninstaller ===" -ForegroundColor Cyan
Write-Host ""

# --- Stop running processes ---
Write-Host "[1/6] Stopping services..." -ForegroundColor Green
Get-Process powershell | Where-Object { $_.MainWindowTitle -eq '' } | ForEach-Object {
    try {
        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
        if ($cmdLine -match "proxy-switch|pac-server") {
            Stop-Process -Id $_.Id -Force
        }
    } catch {}
}

# --- Remove scheduled task ---
Write-Host "[2/6] Removing scheduled task..." -ForegroundColor Green
Unregister-ScheduledTask -TaskName "CompanyProxyAuto" -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "ProxySwitch" -Confirm:$false -ErrorAction SilentlyContinue

# --- Clear registry proxy settings ---
Write-Host "[3/6] Clearing proxy settings..." -ForegroundColor Green
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
Remove-ItemProperty -Path $regPath -Name AutoConfigURL -ErrorAction SilentlyContinue
Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0

# --- Clear git/npm proxy ---
Write-Host "[4/6] Clearing git/npm proxy..." -ForegroundColor Green
git config --global --unset http.https://github.com.proxy 2>$null
npm config delete proxy 2>$null
npm config delete https-proxy 2>$null

# --- Clear environment variables ---
Write-Host "[5/6] Clearing environment variables..." -ForegroundColor Green
[System.Environment]::SetEnvironmentVariable("HTTPS_PROXY", $null, "User")
[System.Environment]::SetEnvironmentVariable("HTTP_PROXY", $null, "User")
$env:HTTPS_PROXY = $null
$env:HTTP_PROXY = $null

# --- Remove shell profile snippets ---
Write-Host "[6/6] Removing shell profile snippets..." -ForegroundColor Green

$marker_start = "# >>> company-auto-proxy >>>"
$marker_end = "# <<< company-auto-proxy <<<"

# Bash
$bashrc = "$env:USERPROFILE\.bashrc"
if (Test-Path $bashrc) {
    $lines = Get-Content $bashrc
    $inBlock = $false
    $newLines = @()
    foreach ($line in $lines) {
        if ($line -match [regex]::Escape($marker_start)) { $inBlock = $true; continue }
        if ($line -match [regex]::Escape($marker_end)) { $inBlock = $false; continue }
        if (-not $inBlock) { $newLines += $line }
    }
    $result = ($newLines -join "`n").TrimEnd()
    if ($result) {
        Set-Content -Path $bashrc -Value $result
    } else {
        Remove-Item $bashrc
    }
    Write-Host "    .bashrc cleaned"
}

# PowerShell
$psProfile = $PROFILE
if (Test-Path $psProfile) {
    $lines = Get-Content $psProfile
    $inBlock = $false
    $newLines = @()
    foreach ($line in $lines) {
        if ($line -match [regex]::Escape($marker_start)) { $inBlock = $true; continue }
        if ($line -match [regex]::Escape($marker_end)) { $inBlock = $false; continue }
        if (-not $inBlock) { $newLines += $line }
    }
    $result = ($newLines -join "`n").TrimEnd()
    if ($result) {
        Set-Content -Path $psProfile -Value $result
    } else {
        Remove-Item $psProfile
    }
    Write-Host "    PowerShell profile cleaned"
}

# --- Remove install directory ---
if (-not $KeepFiles) {
    if (Test-Path $installPath) {
        Remove-Item -Path $installPath -Recurse -Force
        Write-Host ""
        Write-Host "Install directory removed: $installPath"
    }
} else {
    Write-Host ""
    Write-Host "Install directory kept: $installPath" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Uninstall complete ===" -ForegroundColor Cyan
Write-Host "Restart your terminal for changes to take full effect." -ForegroundColor Yellow
