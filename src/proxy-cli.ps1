<#
.SYNOPSIS
    company-auto-proxy CLI tool.
.DESCRIPTION
    Command-line interface for controlling the proxy service.
.EXAMPLE
    .\proxy-cli.ps1 start
    .\proxy-cli.ps1 status
    .\proxy-cli.ps1 proxy on
    .\proxy-cli.ps1 settings show
#>

param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$SubCommand,

    [Parameter(Position = 2)]
    [string]$Arg1,

    [Parameter(Position = 3)]
    [string]$Arg2,

    [switch]$Dashboard,
    [ValidateSet("cli", "full")]
    [string]$Mode = "cli"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Load config
$configFile = Join-Path $scriptDir "config.json"
if (-not (Test-Path $configFile)) {
    $defaultConfig = Join-Path (Split-Path -Parent $scriptDir) "config.default.json"
    if (Test-Path $defaultConfig) { Copy-Item $defaultConfig $configFile }
}
$config = if (Test-Path $configFile) { Get-Content $configFile -Raw | ConvertFrom-Json } else { @{ control_port = 8082; proxy_port = 8081 } }
$controlPort = $config.control_port

function Send-ControlCommand {
    param([string]$Path)
    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:${controlPort}${Path}" -TimeoutSec 3
        return $resp
    } catch {
        return $null
    }
}

function Test-ServiceRunning {
    try {
        $null = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $controlPort)
        return $true
    } catch {
        return $false
    }
}

switch ($Command) {
    "start" {
        if (Test-ServiceRunning) {
            Write-Host "Proxy is already running." -ForegroundColor Yellow
            return
        }
        $args_ = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptDir\proxy-service.ps1`""
        if ($Dashboard) { $args_ += " -Dashboard" }
        Start-Process powershell -ArgumentList $args_ -WindowStyle Hidden
        Start-Sleep -Seconds 2
        if (Test-ServiceRunning) {
            Write-Host "Proxy started on 127.0.0.1:$($config.proxy_port)" -ForegroundColor Green
            Write-Host "Control API on 127.0.0.1:$controlPort" -ForegroundColor Green
            Write-Host "System proxy set to 127.0.0.1:$($config.proxy_port)" -ForegroundColor Green
            if ($Dashboard) { Write-Host "Dashboard on http://127.0.0.1:${controlPort}/dashboard" -ForegroundColor Green }
        } else {
            Write-Host "Failed to start proxy service." -ForegroundColor Red
        }
    }

    "stop" {
        if (-not (Test-ServiceRunning)) {
            Write-Host "Proxy is not running." -ForegroundColor Yellow
            return
        }
        Send-ControlCommand "/stop" | Out-Null
        Write-Host "Stop signal sent. System proxy will be cleared." -ForegroundColor Green
    }

    "status" {
        if (-not (Test-ServiceRunning)) {
            Write-Host "Status: stopped" -ForegroundColor Gray
            return
        }
        $status = Send-ControlCommand "/status"
        if ($status) {
            Write-Host "Status:      running" -ForegroundColor Green
            Write-Host "Proxy:       $(if ($status.proxy_enabled) { 'ENABLED' } else { 'DISABLED' })"
            Write-Host "Uptime:      $($status.uptime)"
            Write-Host "Listen:      $($status.proxy_addr)"
            Write-Host "Network:     $($status.network_state)"
            Write-Host "WiFi Detect: $(if ($status.wifi_detection) { 'on' } else { 'off' }) (pattern: $($status.ssid_pattern))"
            Write-Host "Auto Start:  $(if ($status.auto_start) { 'on' } else { 'off' })"
            Write-Host "Dashboard:   $(if ($status.dashboard_enabled) { 'on' } else { 'off' })"
            Write-Host "Requests:    $($status.total_requests) total, $($status.proxied_requests) proxied, $($status.direct_requests) direct"
            Write-Host "Active:      $($status.active_conns) connections"
        }
    }

    "proxy" {
        switch ($SubCommand) {
            "on" {
                if (-not (Test-ServiceRunning)) { Write-Host "Proxy service is not running. Start it first." -ForegroundColor Red; return }
                Send-ControlCommand "/proxy/on" | Out-Null
                Write-Host "System proxy enabled (127.0.0.1:$($config.proxy_port))" -ForegroundColor Green
            }
            "off" {
                if (-not (Test-ServiceRunning)) { Write-Host "Proxy service is not running." -ForegroundColor Red; return }
                Send-ControlCommand "/proxy/off" | Out-Null
                Write-Host "System proxy disabled" -ForegroundColor Green
            }
            default { Write-Host "Usage: proxy-cli.ps1 proxy <on|off>" }
        }
    }

    "settings" {
        switch ($SubCommand) {
            "show" {
                if (Test-ServiceRunning) {
                    $settings = Send-ControlCommand "/settings"
                    if ($settings) {
                        Write-Host "Proxy Enabled:  $(if ($settings.proxy_enabled) { 'yes' } else { 'no' })"
                        Write-Host "WiFi Detection: $(if ($settings.wifi_detection) { 'on' } else { 'off' })"
                        Write-Host "SSID Pattern:   $($settings.ssid_pattern)"
                        Write-Host "Auto Start:     $(if ($settings.auto_start) { 'on' } else { 'off' })"
                    }
                } else {
                    Write-Host "WiFi Detection: $(if ($config.wifi_detection) { 'on' } else { 'off' })"
                    Write-Host "SSID Pattern:   $($config.ssid_pattern)"
                    Write-Host "Auto Start:     $(if ($config.auto_start) { 'on' } else { 'off' })"
                }
            }
            "set" {
                if (-not $Arg1 -or -not $Arg2) { Write-Host "Usage: proxy-cli.ps1 settings set <key> <value>"; return }
                switch ($Arg1) {
                    "wifi_detection" {
                        if (Test-ServiceRunning) {
                            Send-ControlCommand "/settings/wifi_detection?value=$Arg2" | Out-Null
                        } else {
                            $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
                            $cfg.wifi_detection = $Arg2 -eq "true"
                            $cfg | ConvertTo-Json -Depth 5 | Set-Content $configFile -Encoding UTF8
                        }
                        Write-Host "WiFi detection: $Arg2" -ForegroundColor Green
                    }
                    "ssid_pattern" {
                        if (Test-ServiceRunning) {
                            Send-ControlCommand "/settings/ssid_pattern?value=$([uri]::EscapeDataString($Arg2))" | Out-Null
                        } else {
                            $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
                            $cfg.ssid_pattern = $Arg2
                            $cfg | ConvertTo-Json -Depth 5 | Set-Content $configFile -Encoding UTF8
                        }
                        Write-Host "SSID pattern: $Arg2" -ForegroundColor Green
                    }
                    "auto_start" {
                        if (Test-ServiceRunning) {
                            Send-ControlCommand "/settings/auto_start?value=$Arg2" | Out-Null
                        } else {
                            $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
                            $cfg.auto_start = $Arg2 -eq "true"
                            $cfg | ConvertTo-Json -Depth 5 | Set-Content $configFile -Encoding UTF8
                        }
                        Write-Host "Auto start: $Arg2" -ForegroundColor Green
                    }
                    default { Write-Host "Unknown setting: $Arg1. Available: wifi_detection, ssid_pattern, auto_start" -ForegroundColor Red }
                }
            }
            default { Write-Host "Usage: proxy-cli.ps1 settings <show|set>" }
        }
    }

    "reload" {
        if (-not (Test-ServiceRunning)) { Write-Host "Proxy is not running." -ForegroundColor Red; return }
        Send-ControlCommand "/reload" | Out-Null
        Write-Host "Configuration reloaded." -ForegroundColor Green
    }

    "config" {
        switch ($SubCommand) {
            "show" {
                $cfg = if (Test-ServiceRunning) { Send-ControlCommand "/config" } else { $config }
                $cfg | ConvertTo-Json -Depth 5 | Write-Host
            }
            "set" {
                if (-not $Arg1 -or -not $Arg2) { Write-Host "Usage: proxy-cli.ps1 config set <key> <value>"; return }
                $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
                switch ($Arg1) {
                    "proxy_port" { $cfg.proxy_port = [int]$Arg2 }
                    "control_port" { $cfg.control_port = [int]$Arg2 }
                    "ssid_pattern" { $cfg.ssid_pattern = $Arg2 }
                    "auto_switch" { $cfg.auto_switch = $Arg2 -eq "true" }
                    "wifi_detection" { $cfg.wifi_detection = $Arg2 -eq "true" }
                    "auto_start" { $cfg.auto_start = $Arg2 -eq "true" }
                    "dashboard_enabled" { $cfg.dashboard_enabled = $Arg2 -eq "true" }
                    default { Write-Host "Unknown key: $Arg1" -ForegroundColor Red; return }
                }
                $cfg | ConvertTo-Json -Depth 5 | Set-Content $configFile -Encoding UTF8
                Write-Host "Set $Arg1 = $Arg2" -ForegroundColor Green
                if (Test-ServiceRunning) { Send-ControlCommand "/reload" | Out-Null; Write-Host "(live reload applied)" }
            }
            "reset" {
                $defaultConfig = Join-Path (Split-Path -Parent $scriptDir) "config.default.json"
                if (Test-Path $defaultConfig) {
                    Copy-Item $defaultConfig $configFile -Force
                    Write-Host "Configuration reset to defaults." -ForegroundColor Green
                    if (Test-ServiceRunning) { Send-ControlCommand "/reload" | Out-Null }
                }
            }
            default { Write-Host "Usage: proxy-cli.ps1 config <show|set|reset>" }
        }
    }

    "domains" {
        switch ($SubCommand) {
            "list" {
                $domains = if (Test-ServiceRunning) { Send-ControlCommand "/domains" } else { $config.domains }
                $total = 0
                foreach ($prop in $domains.PSObject.Properties) {
                    Write-Host "`n[$($prop.Name)] ($($prop.Value.Count))" -ForegroundColor Cyan
                    foreach ($d in $prop.Value) { Write-Host "  $d"; $total++ }
                }
                Write-Host "`nTotal: $total domains in $($domains.PSObject.Properties.Name.Count) groups" -ForegroundColor Yellow
            }
            "add" {
                if (-not $Arg1 -or -not $Arg2) { Write-Host "Usage: proxy-cli.ps1 domains add <group> <domain>"; return }
                if (Test-ServiceRunning) {
                    Send-ControlCommand "/domains/add?group=$Arg1&domain=$Arg2" | Out-Null
                } else {
                    $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
                    $list = [System.Collections.ArrayList]@($cfg.domains.$Arg1)
                    $list.Add($Arg2) | Out-Null
                    $cfg.domains | Add-Member -NotePropertyName $Arg1 -NotePropertyValue @($list) -Force
                    $cfg | ConvertTo-Json -Depth 5 | Set-Content $configFile -Encoding UTF8
                }
                Write-Host "Added $Arg2 to group [$Arg1]" -ForegroundColor Green
            }
            "remove" {
                if (-not $Arg1) { Write-Host "Usage: proxy-cli.ps1 domains remove <domain>"; return }
                if (Test-ServiceRunning) {
                    Send-ControlCommand "/domains/remove?domain=$Arg1" | Out-Null
                } else {
                    $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
                    foreach ($prop in $cfg.domains.PSObject.Properties) {
                        $prop.Value = @($prop.Value | Where-Object { $_ -ne $Arg1 })
                    }
                    $cfg | ConvertTo-Json -Depth 5 | Set-Content $configFile -Encoding UTF8
                }
                Write-Host "Removed $Arg1" -ForegroundColor Green
            }
            default { Write-Host "Usage: proxy-cli.ps1 domains <list|add|remove>" }
        }
    }

    "dashboard" {
        if (-not (Test-ServiceRunning)) { Write-Host "Proxy is not running. Start it first." -ForegroundColor Red; return }
        switch ($SubCommand) {
            "on" {
                Send-ControlCommand "/dashboard/on" | Out-Null
                Write-Host "Dashboard activated: http://127.0.0.1:${controlPort}/dashboard" -ForegroundColor Green
            }
            "off" {
                Send-ControlCommand "/dashboard/off" | Out-Null
                Write-Host "Dashboard deactivated." -ForegroundColor Green
            }
            default { Write-Host "Usage: proxy-cli.ps1 dashboard <on|off>" }
        }
    }

    "install" {
        $installPath = $config.install_path -replace '%USERPROFILE%', $env:USERPROFILE
        if (-not $installPath) { $installPath = "$env:USERPROFILE\.proxy" }
        if (-not (Test-Path $installPath)) { New-Item -ItemType Directory -Path $installPath -Force | Out-Null }

        # Copy scripts
        Copy-Item "$scriptDir\proxy-service.ps1" "$installPath\" -Force
        Copy-Item "$scriptDir\proxy-cli.ps1" "$installPath\" -Force
        Copy-Item "$scriptDir\proxy-tray.ps1" "$installPath\" -Force -ErrorAction SilentlyContinue
        Copy-Item "$scriptDir\dashboard.html" "$installPath\" -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path "$installPath\config.json")) {
            $defaultCfg = Join-Path (Split-Path -Parent $scriptDir) "config.default.json"
            if (Test-Path $defaultCfg) { Copy-Item $defaultCfg "$installPath\config.json" }
        }

        # Register scheduled task
        $existingTask = Get-ScheduledTask -TaskName "CompanyProxyAuto" -ErrorAction SilentlyContinue
        if ($existingTask) { Unregister-ScheduledTask -TaskName "CompanyProxyAuto" -Confirm:$false }

        $dashArg = if ($Mode -eq "full") { " -Dashboard" } else { "" }
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installPath\proxy-service.ps1`"$dashArg"
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName "CompanyProxyAuto" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

        # Install tray if full mode
        if ($Mode -eq "full" -and (Test-Path "$installPath\proxy-tray.ps1")) {
            $trayAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installPath\proxy-tray.ps1`""
            $existingTray = Get-ScheduledTask -TaskName "CompanyProxyAutoTray" -ErrorAction SilentlyContinue
            if ($existingTray) { Unregister-ScheduledTask -TaskName "CompanyProxyAutoTray" -Confirm:$false }
            Register-ScheduledTask -TaskName "CompanyProxyAutoTray" -Action $trayAction -Trigger $trigger -Settings $settings -Force | Out-Null
        }

        Write-Host "Installation complete!" -ForegroundColor Green
        Write-Host "  Path: $installPath" -ForegroundColor Gray
        Write-Host "  Mode: $Mode" -ForegroundColor Gray
        Write-Host "  System proxy will be set automatically when service starts" -ForegroundColor Gray
        Write-Host "`n  Restart your terminal for env vars to take effect." -ForegroundColor Yellow
    }

    "uninstall" {
        # Stop service
        if (Test-ServiceRunning) { Send-ControlCommand "/stop" | Out-Null; Start-Sleep -Seconds 1 }

        # Remove scheduled tasks
        Unregister-ScheduledTask -TaskName "CompanyProxyAuto" -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName "CompanyProxyAutoTray" -Confirm:$false -ErrorAction SilentlyContinue

        # Clear env vars and system proxy
        [System.Environment]::SetEnvironmentVariable("HTTP_PROXY", $null, "User")
        [System.Environment]::SetEnvironmentVariable("HTTPS_PROXY", $null, "User")
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0
        Remove-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction SilentlyContinue

        Write-Host "Uninstalled." -ForegroundColor Green
        Write-Host "  Removed scheduled tasks" -ForegroundColor Gray
        Write-Host "  Cleared system proxy and HTTP_PROXY/HTTPS_PROXY" -ForegroundColor Gray
        Write-Host "  Config preserved at: $configFile" -ForegroundColor Gray
    }

    "version" { Write-Host "company-auto-proxy v2.1.0 (PowerShell)" }

    "help" {
        Write-Host @"
company-auto-proxy - Smart local proxy with domain-based routing

Usage:
  proxy-cli.ps1 <command> [options]

Commands:
  start [-Dashboard]       Start proxy service (sets system proxy automatically)
  stop                     Stop proxy service (clears system proxy)
  status                   Show status and statistics
  proxy on|off             Enable/disable system proxy (service keeps running)
  settings show            Show current settings
  settings set <key> <val> Set: wifi_detection, ssid_pattern, auto_start
  reload                   Reload configuration
  config show              Show current configuration
  config set <key> <val>   Set a config value
  config reset             Reset to defaults
  domains list             List whitelisted domains
  domains add <grp> <d>    Add domain to a group
  domains remove <d>       Remove domain
  dashboard on|off         Activate/deactivate web dashboard
  install [-Mode cli|full] Install as startup service
  uninstall                Remove service and clean up
  version                  Show version
  help                     Show this help
"@
    }

    default {
        if ($Command) { Write-Host "Unknown command: $Command`n" -ForegroundColor Red }
        & $MyInvocation.MyCommand.Path -Command help
    }
}
