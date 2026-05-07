<#
.SYNOPSIS
    Configuration management module for Company Auto Proxy.
.DESCRIPTION
    Provides config loading with schema validation, layered defaults (deep merge),
    atomic file writes, flat-to-nested migration, and FileSystemWatcher hot-reload.
#>

$script:Config = $null
$script:ConfigWatcher = $null
$script:ConfigDebounceTimer = $null

function Initialize-Config {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ScriptDir
    )

    $defaultPath = Join-Path $ScriptDir "config.default.json"
    $userPath = Join-Path $ScriptDir "config.json"
    $domainsPath = Join-Path $ScriptDir "domains.json"

    if (-not (Test-Path $defaultPath)) {
        throw "config.default.json not found at $defaultPath"
    }

    $defaults = Get-Content $defaultPath -Raw | ConvertFrom-Json

    if (Test-Path $userPath) {
        $userRaw = Get-Content $userPath -Raw | ConvertFrom-Json

        if (Test-FlatConfig -Config $userRaw) {
            $migrated = Convert-FlatToNested -FlatConfig $userRaw
            $userConfig = $migrated.Config
            if ($migrated.Domains -and -not (Test-Path $domainsPath)) {
                $domainsJson = $migrated.Domains | ConvertTo-Json -Depth 10
                [System.IO.File]::WriteAllText($domainsPath, $domainsJson)
            }
            $merged = Merge-ConfigDefaults -Defaults $defaults -UserConfig $userConfig
            Save-Config -Config $merged -Path $userPath | Out-Null
        } else {
            $merged = Merge-ConfigDefaults -Defaults $defaults -UserConfig $userRaw
        }
    } else {
        $merged = $defaults
    }

    $validation = Test-ConfigValid -Config $merged
    if (-not $validation.Valid) {
        $errorMsg = "Configuration validation failed:`n" + ($validation.Errors -join "`n")
        throw $errorMsg
    }
    if ($validation.Warnings.Count -gt 0) {
        foreach ($w in $validation.Warnings) {
            Write-Warning "Config: $w"
        }
    }

    $script:Config = $merged
    return $script:Config
}

function Merge-ConfigDefaults {
    param(
        [Parameter(Mandatory=$true)]
        $Defaults,
        [Parameter(Mandatory=$true)]
        $UserConfig
    )

    $result = $Defaults.PSObject.Copy()

    foreach ($prop in $UserConfig.PSObject.Properties) {
        $key = $prop.Name
        $userVal = $prop.Value
        $defaultVal = $null
        if ($result.PSObject.Properties[$key]) {
            $defaultVal = $result.$key
        }

        if ($null -ne $defaultVal -and $null -ne $userVal -and
            $defaultVal.PSObject.TypeNames -contains 'System.Management.Automation.PSCustomObject' -and
            $userVal.PSObject.TypeNames -contains 'System.Management.Automation.PSCustomObject') {
            $result.$key = Merge-ConfigDefaults -Defaults $defaultVal -UserConfig $userVal
        } else {
            if ($result.PSObject.Properties[$key]) {
                $result.$key = $userVal
            } else {
                $result | Add-Member -NotePropertyName $key -NotePropertyValue $userVal -Force
            }
        }
    }

    return $result
}

function Test-ConfigValid {
    param(
        [Parameter(Mandatory=$true)]
        $Config
    )

    $errors = @()
    $warnings = @()

    # Critical: proxy.port range
    if ($Config.proxy.port -lt 1024 -or $Config.proxy.port -gt 65535) {
        $errors += "proxy.port must be between 1024 and 65535 (got: $($Config.proxy.port))"
    }

    # Critical: control.port range
    if ($Config.control.port -lt 1024 -or $Config.control.port -gt 65535) {
        $errors += "control.port must be between 1024 and 65535 (got: $($Config.control.port))"
    }

    # Critical: upstream_proxies must be array with at least one valid URL
    $proxies = $Config.proxy.upstream_proxies
    if ($null -eq $proxies -or @($proxies).Count -eq 0) {
        $errors += "proxy.upstream_proxies must contain at least one URL"
    } else {
        $hasValid = $false
        foreach ($p in @($proxies)) {
            if ($p -match '^https?://.+') {
                $hasValid = $true
                break
            }
        }
        if (-not $hasValid) {
            $errors += "proxy.upstream_proxies must contain at least one URL matching http(s)://..."
        }
    }

    # Lenient: logging.level
    $validLevels = @('debug', 'info', 'warn', 'error')
    if ($Config.logging.level -and $validLevels -notcontains $Config.logging.level.ToLower()) {
        $warnings += "logging.level '$($Config.logging.level)' is invalid (expected: debug/info/warn/error). Falling back to 'info'."
        $Config.logging.level = "info"
    }

    # Lenient: detection_interval_sec
    if ($Config.network.detection_interval_sec -le 0) {
        $warnings += "network.detection_interval_sec must be > 0. Falling back to 30."
        $Config.network.detection_interval_sec = 30
    }

    return @{
        Valid = ($errors.Count -eq 0)
        Errors = $errors
        Warnings = $warnings
    }
}

function Save-Config {
    param(
        [Parameter(Mandatory=$true)]
        $Config,
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    $tmpPath = "$Path.tmp"

    try {
        $json = $Config | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($tmpPath, $json)

        $readBack = [System.IO.File]::ReadAllText($tmpPath)
        $null = $readBack | ConvertFrom-Json

        if (Test-Path $Path) {
            Remove-Item $Path -Force
        }
        [System.IO.File]::Move($tmpPath, $Path)
        return $true
    } catch {
        if (Test-Path $tmpPath) {
            Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

function Start-ConfigWatcher {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ConfigPath,
        [Parameter(Mandatory=$true)]
        [string]$DomainsPath,
        [Parameter(Mandatory=$true)]
        [hashtable]$State,
        [Parameter(Mandatory=$true)]
        [hashtable]$DomainSet,
        [scriptblock]$OnReload
    )

    $directory = Split-Path -Parent $ConfigPath
    $configFile = Split-Path -Leaf $ConfigPath
    $domainsFile = Split-Path -Leaf $DomainsPath

    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $directory
    $watcher.Filter = "*.json"
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::FileName
    $watcher.IncludeSubdirectories = $false

    $timer = New-Object System.Timers.Timer
    $timer.Interval = 500
    $timer.AutoReset = $false
    $timer.Enabled = $false

    $script:ConfigDebounceTimer = $timer
    $script:ConfigWatcher = $watcher

    $reloadState = @{
        ConfigPath = $ConfigPath
        DomainsPath = $DomainsPath
        State = $State
        DomainSet = $DomainSet
        OnReload = $OnReload
        DefaultPath = Join-Path $directory "config.default.json"
    }

    Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action {
        $rs = $Event.MessageData
        try {
            $defaults = Get-Content $rs.DefaultPath -Raw | ConvertFrom-Json
            $userRaw = Get-Content $rs.ConfigPath -Raw | ConvertFrom-Json
            $merged = Merge-ConfigDefaults -Defaults $defaults -UserConfig $userRaw
            $validation = Test-ConfigValid -Config $merged

            if ($validation.Valid) {
                $oldProxyPort = $script:Config.proxy.port
                $oldControlPort = $script:Config.control.port
                $script:Config = $merged

                if (Test-Path $rs.DomainsPath) {
                    $domainsRaw = Get-Content $rs.DomainsPath -Raw | ConvertFrom-Json
                    $rs.DomainSet.Clear()
                    foreach ($group in $domainsRaw.PSObject.Properties) {
                        foreach ($d in $group.Value) {
                            $rs.DomainSet[$d.ToLower()] = $true
                        }
                    }
                }

                if ($merged.proxy.port -ne $oldProxyPort -or $merged.control.port -ne $oldControlPort) {
                    Write-Warning "Config: Port change requires restart"
                }

                if ($rs.OnReload) {
                    & $rs.OnReload
                }
            } else {
                foreach ($e in $validation.Errors) {
                    Write-Warning "Config reload failed: $e"
                }
            }
        } catch {
            Write-Warning "Config reload error: $($_.Exception.Message)"
        }
    } -MessageData $reloadState | Out-Null

    $watchAction = Register-ObjectEvent -InputObject $watcher -EventName Changed -Action {
        $changedFile = Split-Path -Leaf $EventArgs.FullPath
        $cs = $Event.MessageData
        if ($changedFile -eq (Split-Path -Leaf $cs.ConfigPath) -or $changedFile -eq (Split-Path -Leaf $cs.DomainsPath)) {
            $script:ConfigDebounceTimer.Stop()
            $script:ConfigDebounceTimer.Start()
        }
    } -MessageData $reloadState

    $renameAction = Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action {
        $changedFile = Split-Path -Leaf $EventArgs.FullPath
        $cs = $Event.MessageData
        if ($changedFile -eq (Split-Path -Leaf $cs.ConfigPath) -or $changedFile -eq (Split-Path -Leaf $cs.DomainsPath)) {
            $script:ConfigDebounceTimer.Stop()
            $script:ConfigDebounceTimer.Start()
        }
    } -MessageData $reloadState

    $watcher.EnableRaisingEvents = $true

    return $watcher
}

function Stop-ConfigWatcher {
    if ($script:ConfigWatcher) {
        $script:ConfigWatcher.EnableRaisingEvents = $false
        $script:ConfigWatcher.Dispose()
        $script:ConfigWatcher = $null
    }
    if ($script:ConfigDebounceTimer) {
        $script:ConfigDebounceTimer.Stop()
        $script:ConfigDebounceTimer.Dispose()
        $script:ConfigDebounceTimer = $null
    }
}

function Test-FlatConfig {
    param(
        [Parameter(Mandatory=$true)]
        $Config
    )

    return ($null -ne $Config.PSObject.Properties['proxy_port'])
}

function Convert-FlatToNested {
    param(
        [Parameter(Mandatory=$true)]
        $FlatConfig
    )

    $nested = [PSCustomObject]@{
        proxy = [PSCustomObject]@{
            port = if ($FlatConfig.proxy_port) { $FlatConfig.proxy_port } else { 8081 }
            upstream_proxies = if ($FlatConfig.upstream_proxies) { @($FlatConfig.upstream_proxies) } else { @() }
            max_connections = 20
        }
        network = [PSCustomObject]@{
            ssid_pattern = if ($FlatConfig.ssid_pattern) { $FlatConfig.ssid_pattern } else { "CORP" }
            wifi_detection = if ($null -ne $FlatConfig.wifi_detection) { [bool]$FlatConfig.wifi_detection } else { $true }
            auto_switch = if ($null -ne $FlatConfig.auto_switch) { [bool]$FlatConfig.auto_switch } else { $true }
            detection_interval_sec = 30
        }
        control = [PSCustomObject]@{
            port = if ($FlatConfig.control_port) { $FlatConfig.control_port } else { 8082 }
            dashboard_enabled = if ($null -ne $FlatConfig.dashboard_enabled) { [bool]$FlatConfig.dashboard_enabled } else { $false }
        }
        logging = [PSCustomObject]@{
            level = "info"
            max_entries = if ($FlatConfig.log_max_entries -gt 0) { $FlatConfig.log_max_entries } else { 100 }
        }
        behavior = [PSCustomObject]@{
            auto_start = if ($null -ne $FlatConfig.auto_start) { [bool]$FlatConfig.auto_start } else { $false }
            install_path = if ($FlatConfig.install_path) { $FlatConfig.install_path } else { "%USERPROFILE%\.proxy" }
        }
    }

    $domains = $null
    if ($FlatConfig.PSObject.Properties['domains']) {
        $domains = $FlatConfig.domains
    }

    return @{
        Config = $nested
        Domains = $domains
    }
}
