param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$SubCommand,

    [Parameter(Position = 2)]
    [string]$Arg1,

    [Parameter(Position = 3)]
    [string]$Arg2,

    [switch]$Short,
    [ValidateSet("cli", "full")]
    [string]$Mode = "cli"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$configFile = Join-Path $scriptDir "config.json"
if (-not (Test-Path $configFile)) {
    $defaultConfig = Join-Path (Split-Path -Parent $scriptDir) "config.default.json"
    if (Test-Path $defaultConfig) { Copy-Item $defaultConfig $configFile }
}
$config = if (Test-Path $configFile) { Get-Content $configFile -Raw | ConvertFrom-Json } else { $null }

if ($config) {
    if ($config.control) {
        $controlPort = $config.control.port
    } else {
        $controlPort = $config.control_port
    }
    if ($config.proxy) {
        $proxyPort = $config.proxy.port
    } else {
        $proxyPort = $config.proxy_port
    }
} else {
    $controlPort = 8082
    $proxyPort = 8081
}

function Test-ServiceRunning {
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $controlPort)
        $tcp.Close()
        return $true
    } catch {
        return $false
    }
}

function Send-ControlCommand {
    param([string]$Path)
    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:${controlPort}${Path}" -TimeoutSec 3
        return $resp
    } catch {
        return $null
    }
}

function Start-ProxyService {
    $serviceScript = Join-Path $scriptDir "proxy-service.ps1"
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$serviceScript`"" -WindowStyle Hidden
    $timeout = 50
    for ($i = 0; $i -lt $timeout; $i++) {
        Start-Sleep -Milliseconds 100
        if (Test-ServiceRunning) { return $true }
    }
    return $false
}

function Format-Uptime {
    param([string]$UptimeString)
    if (-not $UptimeString) { return "0s" }
    $parts = $UptimeString -split ':'
    if ($parts.Count -eq 3) {
        $h = [int]$parts[0]
        $m = [int]$parts[1]
        $s = [int]$parts[2] -replace '\..*', ''
        if ($h -gt 0) { return "${h}h ${m}m" }
        if ($m -gt 0) { return "${m}m ${s}s" }
        return "${s}s"
    }
    return $UptimeString
}

switch ($Command) {
    "on" {
        if (-not (Test-ServiceRunning)) {
            $started = Start-ProxyService
            if (-not $started) {
                Write-Host "Failed to start proxy service." -ForegroundColor Red
                exit 1
            }
        }
        $result = Send-ControlCommand "/proxy/on"
        if ($null -eq $result) {
            Write-Host "Failed to enable proxy." -ForegroundColor Red
            exit 1
        }
        Write-Host "Proxy enabled (127.0.0.1:$proxyPort)" -ForegroundColor Green
    }

    "off" {
        if (-not (Test-ServiceRunning)) {
            Write-Host "Service not running. Proxy already off." -ForegroundColor Yellow
            exit 0
        }
        $result = Send-ControlCommand "/proxy/off"
        if ($null -eq $result) {
            Write-Host "Failed to disable proxy." -ForegroundColor Red
            exit 1
        }
        Write-Host "Proxy disabled." -ForegroundColor Green
    }

    "start" {
        if (Test-ServiceRunning) {
            Write-Host "Already running." -ForegroundColor Yellow
            exit 0
        }
        $started = Start-ProxyService
        if ($started) {
            Write-Host "Service started on 127.0.0.1:$proxyPort" -ForegroundColor Green
        } else {
            Write-Host "Failed to start proxy service." -ForegroundColor Red
            exit 1
        }
    }

    "stop" {
        if (-not (Test-ServiceRunning)) {
            Write-Host "Already stopped." -ForegroundColor Yellow
            exit 0
        }
        Send-ControlCommand "/stop" | Out-Null
        Write-Host "Service stopped." -ForegroundColor Green
    }

    "restart" {
        if (Test-ServiceRunning) {
            Send-ControlCommand "/stop" | Out-Null
            Start-Sleep -Milliseconds 500
            $waitStop = 20
            for ($i = 0; $i -lt $waitStop; $i++) {
                if (-not (Test-ServiceRunning)) { break }
                Start-Sleep -Milliseconds 100
            }
        }
        $started = Start-ProxyService
        if ($started) {
            Write-Host "Service restarted on 127.0.0.1:$proxyPort" -ForegroundColor Green
        } else {
            Write-Host "Failed to restart proxy service." -ForegroundColor Red
            exit 1
        }
    }

    "status" {
        if (-not (Test-ServiceRunning)) {
            if ($Short) {
                Write-Host "stopped"
            } else {
                Write-Host ([char]0x25CB) -NoNewline -ForegroundColor Red
                Write-Host " Service: " -NoNewline -ForegroundColor Gray
                Write-Host "stopped" -ForegroundColor Red
            }
            exit 0
        }
        $status = Send-ControlCommand "/status"
        if (-not $status) {
            Write-Host "Service unreachable." -ForegroundColor Red
            exit 1
        }
        $uptime = Format-Uptime $status.uptime
        $mode = if ($status.network_state) { $status.network_state.ToUpper() } else { "UNKNOWN" }
        if ($Short) {
            Write-Host "running $mode $($uptime -replace ' ', '')"
            exit 0
        }
        $network = $mode
        if ($status.ssid_pattern) { $network += " (SSID: $($status.ssid_pattern))" }
        $totalReq = if ($status.total_requests) { $status.total_requests } else { 0 }
        $proxiedReq = if ($status.proxied_requests) { $status.proxied_requests } else { 0 }
        $directReq = if ($status.direct_requests) { $status.direct_requests } else { 0 }
        $activeConns = if ($status.active_conns) { $status.active_conns } else { 0 }

        Write-Host ([char]0x25CF) -NoNewline -ForegroundColor Green
        Write-Host " Service: " -NoNewline -ForegroundColor Gray
        Write-Host "running" -NoNewline -ForegroundColor Green
        Write-Host "    Mode: " -NoNewline -ForegroundColor Gray
        Write-Host "$mode" -NoNewline -ForegroundColor Cyan
        Write-Host "    Uptime: " -NoNewline -ForegroundColor Gray
        Write-Host "$uptime" -ForegroundColor Cyan
        Write-Host "  Listen:    " -NoNewline -ForegroundColor Gray
        Write-Host "127.0.0.1:$proxyPort" -ForegroundColor White
        Write-Host "  Control:   " -NoNewline -ForegroundColor Gray
        Write-Host "127.0.0.1:$controlPort" -ForegroundColor White
        Write-Host "  Network:   " -NoNewline -ForegroundColor Gray
        Write-Host "$network" -ForegroundColor Cyan
        Write-Host "  Requests:  " -NoNewline -ForegroundColor Gray
        Write-Host "$totalReq total ($proxiedReq proxied, $directReq direct)" -ForegroundColor White
        Write-Host "  Active:    " -NoNewline -ForegroundColor Gray
        Write-Host "$activeConns connections" -ForegroundColor White
    }

    "domains" {
        switch ($SubCommand) {
            "list" {
                $domains = if (Test-ServiceRunning) { Send-ControlCommand "/domains" } else { $config.domains }
                if (-not $domains) {
                    Write-Host "No domains configured." -ForegroundColor Yellow
                    exit 0
                }
                $total = 0
                foreach ($prop in $domains.PSObject.Properties) {
                    Write-Host "`n[$($prop.Name)] ($($prop.Value.Count))" -ForegroundColor Cyan
                    foreach ($d in $prop.Value) { Write-Host "  $d"; $total++ }
                }
                Write-Host "`nTotal: $total domains in $($domains.PSObject.Properties.Name.Count) groups" -ForegroundColor Yellow
            }
            "add" {
                if (-not $Arg1 -or -not $Arg2) {
                    Write-Host "Usage: cap domains add <group> <domain>" -ForegroundColor Red
                    exit 1
                }
                if (Test-ServiceRunning) {
                    Send-ControlCommand "/domains/add?group=$Arg1&domain=$Arg2" | Out-Null
                } else {
                    $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
                    $list = [System.Collections.ArrayList]@($cfg.domains.$Arg1)
                    $list.Add($Arg2) | Out-Null
                    $cfg.domains | Add-Member -NotePropertyName $Arg1 -NotePropertyValue @($list) -Force
                    $json = $cfg | ConvertTo-Json -Depth 5
                    [System.IO.File]::WriteAllText($configFile, $json)
                }
                Write-Host "Added $Arg2 to group [$Arg1]" -ForegroundColor Green
            }
            "remove" {
                if (-not $Arg1) {
                    Write-Host "Usage: cap domains remove <domain>" -ForegroundColor Red
                    exit 1
                }
                if (Test-ServiceRunning) {
                    Send-ControlCommand "/domains/remove?domain=$Arg1" | Out-Null
                } else {
                    $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
                    foreach ($prop in $cfg.domains.PSObject.Properties) {
                        $prop.Value = @($prop.Value | Where-Object { $_ -ne $Arg1 })
                    }
                    $json = $cfg | ConvertTo-Json -Depth 5
                    [System.IO.File]::WriteAllText($configFile, $json)
                }
                Write-Host "Removed $Arg1" -ForegroundColor Green
            }
            default {
                Write-Host "Usage: cap domains <list|add|remove>" -ForegroundColor Yellow
            }
        }
    }

    "config" {
        switch ($SubCommand) {
            "show" {
                $cfg = if (Test-ServiceRunning) { Send-ControlCommand "/config" } else { $config }
                $cfg | ConvertTo-Json -Depth 5 | Write-Host
            }
            "set" {
                if (-not $Arg1 -or -not $Arg2) {
                    Write-Host "Usage: cap config set <key> <value>" -ForegroundColor Red
                    exit 1
                }
                $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
                switch ($Arg1) {
                    "proxy_port" { $cfg.proxy_port = [int]$Arg2 }
                    "control_port" { $cfg.control_port = [int]$Arg2 }
                    "ssid_pattern" { $cfg.ssid_pattern = $Arg2 }
                    "auto_switch" { $cfg.auto_switch = $Arg2 -eq "true" }
                    "wifi_detection" { $cfg.wifi_detection = $Arg2 -eq "true" }
                    "auto_start" { $cfg.auto_start = $Arg2 -eq "true" }
                    "dashboard_enabled" { $cfg.dashboard_enabled = $Arg2 -eq "true" }
                    default {
                        Write-Host "Unknown key: $Arg1" -ForegroundColor Red
                        exit 1
                    }
                }
                $json = $cfg | ConvertTo-Json -Depth 5
                [System.IO.File]::WriteAllText($configFile, $json)
                Write-Host "Set $Arg1 = $Arg2" -ForegroundColor Green
                if (Test-ServiceRunning) {
                    Send-ControlCommand "/reload" | Out-Null
                    Write-Host "(live reload applied)" -ForegroundColor Gray
                }
            }
            "reset" {
                $defaultConfig = Join-Path (Split-Path -Parent $scriptDir) "config.default.json"
                if (Test-Path $defaultConfig) {
                    Copy-Item $defaultConfig $configFile -Force
                    Write-Host "Configuration reset to defaults." -ForegroundColor Green
                    if (Test-ServiceRunning) { Send-ControlCommand "/reload" | Out-Null }
                } else {
                    Write-Host "No default config file found." -ForegroundColor Red
                    exit 1
                }
            }
            default {
                Write-Host "Usage: cap config <show|set|reset>" -ForegroundColor Yellow
            }
        }
    }

    "install" {
        $installPath = if ($config -and $config.install_path) { $config.install_path -replace '%USERPROFILE%', $env:USERPROFILE } else { "$env:USERPROFILE\.proxy" }
        if (-not (Test-Path $installPath)) { New-Item -ItemType Directory -Path $installPath -Force | Out-Null }

        Copy-Item "$scriptDir\proxy-service.ps1" "$installPath\" -Force
        Copy-Item "$scriptDir\proxy-cli.ps1" "$installPath\" -Force
        Copy-Item "$scriptDir\proxy-tray.ps1" "$installPath\" -Force -ErrorAction SilentlyContinue
        Copy-Item "$scriptDir\dashboard.html" "$installPath\" -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path "$installPath\config.json")) {
            $defaultCfg = Join-Path (Split-Path -Parent $scriptDir) "config.default.json"
            if (Test-Path $defaultCfg) { Copy-Item $defaultCfg "$installPath\config.json" }
        }

        $binDir = Join-Path (Split-Path -Parent $scriptDir) "bin"
        if (Test-Path $binDir) {
            Copy-Item "$binDir\cap.ps1" "$installPath\" -Force
            Copy-Item "$binDir\cap.cmd" "$installPath\" -Force
            Copy-Item "$binDir\cap" "$installPath\" -Force
        }

        $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
        if ($userPath -notlike "*$installPath*") {
            [System.Environment]::SetEnvironmentVariable("PATH", "$installPath;$userPath", "User")
            Write-Host "  Added $installPath to PATH" -ForegroundColor Gray
        }

        $existingTask = Get-ScheduledTask -TaskName "CompanyProxyAuto" -ErrorAction SilentlyContinue
        if ($existingTask) { Unregister-ScheduledTask -TaskName "CompanyProxyAuto" -Confirm:$false }

        $dashArg = if ($Mode -eq "full") { " -Dashboard" } else { "" }
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installPath\proxy-service.ps1`"$dashArg"
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName "CompanyProxyAuto" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

        if ($Mode -eq "full" -and (Test-Path "$installPath\proxy-tray.ps1")) {
            $trayAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installPath\proxy-tray.ps1`""
            $existingTray = Get-ScheduledTask -TaskName "CompanyProxyAutoTray" -ErrorAction SilentlyContinue
            if ($existingTray) { Unregister-ScheduledTask -TaskName "CompanyProxyAutoTray" -Confirm:$false }
            Register-ScheduledTask -TaskName "CompanyProxyAutoTray" -Action $trayAction -Trigger $trigger -Settings $settings -Force | Out-Null
        }

        Write-Host "Installation complete!" -ForegroundColor Green
        Write-Host "  Path: $installPath" -ForegroundColor Gray
        Write-Host "  Mode: $Mode" -ForegroundColor Gray
        Write-Host "  CLI shortcut: cap <command>" -ForegroundColor Gray
        Write-Host "`n  Restart your terminal for PATH to take effect." -ForegroundColor Yellow
    }

    "uninstall" {
        if (Test-ServiceRunning) {
            Send-ControlCommand "/stop" | Out-Null
            Start-Sleep -Seconds 1
        }

        Unregister-ScheduledTask -TaskName "CompanyProxyAuto" -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName "CompanyProxyAutoTray" -Confirm:$false -ErrorAction SilentlyContinue

        [System.Environment]::SetEnvironmentVariable("HTTP_PROXY", $null, "User")
        [System.Environment]::SetEnvironmentVariable("HTTPS_PROXY", $null, "User")
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0
        Remove-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction SilentlyContinue

        $installPath = if ($config -and $config.install_path) { $config.install_path -replace '%USERPROFILE%', $env:USERPROFILE } else { "$env:USERPROFILE\.proxy" }
        $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
        if ($userPath -like "*$installPath*") {
            $newPath = ($userPath -split ';' | Where-Object { $_ -ne $installPath }) -join ';'
            [System.Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        }

        Write-Host "Uninstalled." -ForegroundColor Green
        Write-Host "  Removed scheduled tasks" -ForegroundColor Gray
        Write-Host "  Cleared system proxy and HTTP_PROXY/HTTPS_PROXY" -ForegroundColor Gray
        Write-Host "  Removed from PATH" -ForegroundColor Gray
        Write-Host "  Config preserved at: $configFile" -ForegroundColor Gray
    }

    "version" {
        Write-Host "company-auto-proxy v2.1.0"
    }

    "help" {
        Write-Host @"
company-auto-proxy - Smart local proxy with domain-based routing

Usage:
  cap <command> [options]

Commands:
  on                       Enable system proxy (auto-starts service if needed)
  off                      Disable system proxy (service keeps running)
  start                    Start proxy service
  stop                     Stop proxy service
  restart                  Restart proxy service
  status [--short]         Show service status and statistics

  domains list             List routed domains by group
  domains add <grp> <d>    Add domain to a group
  domains remove <d>       Remove domain from all groups

  config show              Show current configuration
  config set <key> <val>   Set a config value
  config reset             Reset to defaults

  install [-Mode cli|full] Install as startup service
  uninstall                Remove service and clean up
  version                  Show version
  help                     Show this help
"@
    }

    default {
        if ($Command) {
            Write-Host "Unknown command: $Command" -ForegroundColor Red
            Write-Host ""
        }
        & $MyInvocation.MyCommand.Path -Command help
    }
}
