<#
.SYNOPSIS
    Install company-proxy-auto - network-aware proxy auto-switch for Windows.
.DESCRIPTION
    Reads config.json, generates PAC file, installs scripts, registers scheduled task,
    and configures shell profiles for dynamic proxy switching.
#>

param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Load config ---
$configFile = "$projectRoot\config.json"
if (-not (Test-Path $configFile)) {
    if (Test-Path "$projectRoot\config.example.json") {
        Copy-Item "$projectRoot\config.example.json" $configFile
        Write-Host "[!] config.json created from config.example.json" -ForegroundColor Yellow
        Write-Host "    Please edit config.json with your proxy settings, then re-run install.ps1" -ForegroundColor Yellow
        notepad $configFile
        exit 0
    } else {
        Write-Error "config.example.json not found. Cannot proceed."
    }
}

$config = Get-Content $configFile -Raw | ConvertFrom-Json
$installPath = $config.install_path -replace '%USERPROFILE%', $env:USERPROFILE
$proxy = $config.proxies[0]
$pacPort = $config.pac_port
$ssidPattern = $config.ssid_pattern

Write-Host "=== company-proxy-auto installer ===" -ForegroundColor Cyan
Write-Host "Install path: $installPath"
Write-Host "Proxy: $proxy"
Write-Host "SSID pattern: $ssidPattern"
Write-Host "PAC port: $pacPort"
Write-Host ""

# --- Create install directory ---
if (-not (Test-Path $installPath)) {
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
}

# --- Generate proxy.pac from template ---
Write-Host "[1/7] Generating proxy.pac..." -ForegroundColor Green

$allDomains = @()
$config.domains.PSObject.Properties | ForEach-Object {
    $_.Value | ForEach-Object { $allDomains += $_ }
}

$domainLines = ($allDomains | ForEach-Object { "        `"$_`"" }) -join ",`n"
$proxyString = ($config.proxies | ForEach-Object { "PROXY $($_ -replace 'http://','')" }) -join "; "
$proxyString += "; DIRECT"

$template = Get-Content "$projectRoot\src\proxy.pac.template" -Raw
$pacContent = $template -replace '\{\{DOMAINS\}\}', $domainLines -replace '\{\{PROXY_STRING\}\}', $proxyString
Set-Content -Path "$installPath\proxy.pac" -Value $pacContent -Encoding UTF8

# --- Copy scripts ---
Write-Host "[2/7] Copying scripts..." -ForegroundColor Green

Copy-Item "$projectRoot\src\proxy-switch.ps1" "$installPath\proxy-switch.ps1" -Force
Copy-Item "$projectRoot\src\pac-server.ps1" "$installPath\pac-server.ps1" -Force
Copy-Item "$projectRoot\src\start-proxy-switch.vbs" "$installPath\start-proxy-switch.vbs" -Force
Copy-Item $configFile "$installPath\config.json" -Force

# Write proxy URL file for shell snippets to read
Set-Content -Path "$installPath\.proxy_url" -Value $proxy -NoNewline

# --- Configure git proxy ---
Write-Host "[3/7] Configuring git proxy..." -ForegroundColor Green
git config --global http.https://github.com.proxy $proxy

# --- Configure npm proxy ---
Write-Host "[4/7] Configuring npm proxy..." -ForegroundColor Green
npm config set proxy $proxy 2>$null
npm config set https-proxy $proxy 2>$null

# --- Register scheduled task ---
Write-Host "[5/7] Registering scheduled task..." -ForegroundColor Green

$existingTask = Get-ScheduledTask -TaskName "CompanyProxyAuto" -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName "CompanyProxyAuto" -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$installPath\start-proxy-switch.vbs`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName "CompanyProxyAuto" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

# --- Configure shell profiles ---
Write-Host "[6/7] Configuring shell profiles..." -ForegroundColor Green

$marker = "company-proxy-auto"

# Bash
$bashrc = "$env:USERPROFILE\.bashrc"
$bashSnippet = Get-Content "$projectRoot\shell\bashrc-snippet.sh" -Raw
if (Test-Path $bashrc) {
    $bashContent = Get-Content $bashrc -Raw
    if ($bashContent -notmatch $marker) {
        Add-Content -Path $bashrc -Value "`n$bashSnippet"
        Write-Host "    .bashrc updated"
    } else {
        Write-Host "    .bashrc already configured, skipping"
    }
} else {
    Set-Content -Path $bashrc -Value $bashSnippet
    Write-Host "    .bashrc created"
}

# PowerShell
$psProfile = $PROFILE
$psDir = Split-Path -Parent $psProfile
if (-not (Test-Path $psDir)) {
    New-Item -ItemType Directory -Path $psDir -Force | Out-Null
}
$psSnippet = Get-Content "$projectRoot\shell\powershell-profile-snippet.ps1" -Raw
if (Test-Path $psProfile) {
    $psContent = Get-Content $psProfile -Raw
    if ($psContent -notmatch $marker) {
        Add-Content -Path $psProfile -Value "`n$psSnippet"
        Write-Host "    PowerShell profile updated"
    } else {
        Write-Host "    PowerShell profile already configured, skipping"
    }
} else {
    Set-Content -Path $psProfile -Value $psSnippet
    Write-Host "    PowerShell profile created"
}

# --- Start service ---
Write-Host "[7/7] Starting proxy switch service..." -ForegroundColor Green

Get-Process powershell | Where-Object {
    $_.MainWindowTitle -eq '' -and $_.Id -ne $PID
} | ForEach-Object {
    try {
        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
        if ($cmdLine -match "proxy-switch|pac-server") {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

Start-Process -WindowStyle Hidden -FilePath "wscript.exe" -ArgumentList "`"$installPath\start-proxy-switch.vbs`""

Start-Sleep -Seconds 3

# Verify
$stateFile = "$installPath\state"
if (Test-Path $stateFile) {
    $state = Get-Content $stateFile -Raw
    Write-Host ""
    Write-Host "=== Installation complete ===" -ForegroundColor Cyan
    Write-Host "Network state: $state"
    Write-Host "PAC server: http://127.0.0.1:${pacPort}/proxy.pac"
    Write-Host ""
    Write-Host "Restart your terminal for shell proxy integration to take effect." -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "=== Installation complete ===" -ForegroundColor Cyan
    Write-Host "Service started. State file will be created on next network check (within 30s)." -ForegroundColor Yellow
}
