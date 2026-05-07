<#
.SYNOPSIS
    company-auto-proxy service daemon.
.DESCRIPTION
    Local proxy with domain-based routing, control API, and WiFi SSID auto-detection.
    Automatically sets system proxy and environment variables to capture all traffic.
#>

param([switch]$Dashboard)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulesDir = Join-Path $scriptDir "modules"
. (Join-Path $modulesDir "Config.ps1")
. (Join-Path $modulesDir "DomainMatcher.ps1")
. (Join-Path $modulesDir "SystemProxy.ps1")

$script:Config = Initialize-Config -ScriptDir $scriptDir
if ($Dashboard) { $script:Config.control.dashboard_enabled = $true }

$script:DomainSet = Initialize-DomainSet -ScriptDir $scriptDir

$script:State = [hashtable]::Synchronized(@{
    Running         = $true
    ProxyEnabled    = $true
    TotalRequests   = [long]0
    ProxiedRequests = [long]0
    DirectRequests  = [long]0
    ActiveConns     = [long]0
    StartTime       = [DateTime]::UtcNow
    NetworkState    = "UNKNOWN"
    DashboardEnabled = [bool]$script:Config.control.dashboard_enabled
    WifiDetection   = [bool]$script:Config.network.wifi_detection
    AutoStart       = [bool]$script:Config.behavior.auto_start
    SsidPattern     = [string]$script:Config.network.ssid_pattern
})

$script:LogBuffer = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
$script:LogMax = if ($script:Config.logging.max_entries -gt 0) { $script:Config.logging.max_entries } else { 100 }

$mutex = New-Object System.Threading.Mutex($false, "Global\CompanyProxyAutoServiceMutex")
if (-not $mutex.WaitOne(0)) {
    Write-Host "Error: Another instance is already running." -ForegroundColor Red
    exit 1
}

Write-Host "company-auto-proxy service starting..." -ForegroundColor Cyan

# SSID check
function Get-CurrentSSID {
    try {
        $output = netsh wlan show interfaces 2>$null
        $line = $output | Select-String "^\s+SSID\s+:" | Select-Object -First 1
        if ($line) { return ($line -split ":\s*", 2)[1].Trim() }
    } catch {}
    return ""
}

if ($script:State.WifiDetection) {
    $ssid = Get-CurrentSSID
    $script:State.NetworkState = if ($ssid -match $script:State.SsidPattern) { "CORP" } else { "OTHER" }
} else {
    $script:State.NetworkState = "CORP"
}

Enable-SystemProxy -Port $script:Config.proxy.port

# PID file
Set-Content -Path (Join-Path $scriptDir "proxy.pid") -Value $PID -NoNewline

# Start config file watcher for hot-reload
$configPath = Join-Path $scriptDir "config.json"
$domainsPath = Join-Path $scriptDir "domains.json"
$watcher = Start-ConfigWatcher -ConfigPath $configPath -DomainsPath $domainsPath -State $script:State -DomainSet $script:DomainSet

# --- Control API ---
$controlScriptBlock = {
    param($controlPort, $proxyPort, $state, $logBuffer, $logMax, $configFile, $domainSet, $dashFile, $scriptDir, $domainsFile, $defaultConfigPath)

    $dashHtml = if (Test-Path $dashFile) { [System.IO.File]::ReadAllText($dashFile) } else { "" }
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:${controlPort}/")
    $listener.Start()

    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

    while ($state.Running) {
        $result = $listener.BeginGetContext($null, $null)
        while (-not $result.AsyncWaitHandle.WaitOne(500)) {
            if (-not $state.Running) { $listener.Stop(); return }
        }
        $context = $listener.EndGetContext($result)
        $req = $context.Request
        $resp = $context.Response
        $path = $req.Url.LocalPath

        $jsonOut = $null
        $htmlOut = $null

        switch -Wildcard ($path) {
            "/status" {
                $jsonOut = @{
                    running = $true
                    proxy_enabled = $state.ProxyEnabled
                    uptime = [DateTime]::UtcNow.Subtract($state.StartTime).ToString("hh\:mm\:ss")
                    proxy_addr = "127.0.0.1:$proxyPort"
                    network_state = $state.NetworkState
                    dashboard_enabled = $state.DashboardEnabled
                    wifi_detection = $state.WifiDetection
                    auto_start = $state.AutoStart
                    ssid_pattern = $state.SsidPattern
                    total_requests = $state.TotalRequests
                    proxied_requests = $state.ProxiedRequests
                    direct_requests = $state.DirectRequests
                    active_conns = $state.ActiveConns
                } | ConvertTo-Json -Compress
            }
            "/stop" {
                $jsonOut = '{"ok":true}'
                $state.Running = $false
            }
            "/proxy/on" {
                $proxyAddr = "127.0.0.1:$proxyPort"
                $proxyUrl = "http://$proxyAddr"
                Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 1
                Set-ItemProperty -Path $regPath -Name ProxyServer -Value $proxyAddr
                [System.Environment]::SetEnvironmentVariable("HTTP_PROXY", $proxyUrl, "User")
                [System.Environment]::SetEnvironmentVariable("HTTPS_PROXY", $proxyUrl, "User")
                $state.ProxyEnabled = $true
                $jsonOut = '{"ok":true}'
            }
            "/proxy/off" {
                Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0
                Remove-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction SilentlyContinue
                [System.Environment]::SetEnvironmentVariable("HTTP_PROXY", $null, "User")
                [System.Environment]::SetEnvironmentVariable("HTTPS_PROXY", $null, "User")
                $state.ProxyEnabled = $false
                $jsonOut = '{"ok":true}'
            }
            "/settings" {
                $jsonOut = @{
                    auto_start = $state.AutoStart
                    wifi_detection = $state.WifiDetection
                    ssid_pattern = $state.SsidPattern
                    proxy_enabled = $state.ProxyEnabled
                } | ConvertTo-Json -Compress
            }
            "/reload" {
                try {
                    $defaults = Get-Content $defaultConfigPath -Raw | ConvertFrom-Json
                    $userCfg = if (Test-Path $configFile) { Get-Content $configFile -Raw | ConvertFrom-Json } else { $defaults }
                    $domainSet.Clear()
                    $domainsRaw = Get-Content $domainsFile -Raw | ConvertFrom-Json
                    foreach ($grp in $domainsRaw.PSObject.Properties) {
                        foreach ($d in $grp.Value) { $domainSet[$d.ToLower()] = $true }
                    }
                    $state.WifiDetection = [bool]$userCfg.network.wifi_detection
                    $state.AutoStart = [bool]$userCfg.behavior.auto_start
                    $state.SsidPattern = [string]$userCfg.network.ssid_pattern
                } catch {}
                $jsonOut = '{"ok":true}'
            }
            "/dashboard/on" { $state.DashboardEnabled = $true; $jsonOut = '{"ok":true}' }
            "/dashboard/off" { $state.DashboardEnabled = $false; $jsonOut = '{"ok":true}' }
            "/domains" {
                $domainsRaw = Get-Content $domainsFile -Raw
                $jsonOut = $domainsRaw
            }
            "/domains/add" {
                $group = $req.QueryString["group"]; $domain = $req.QueryString["domain"]
                if ($group -and $domain) {
                    $domainsRaw = Get-Content $domainsFile -Raw | ConvertFrom-Json
                    $existing = @()
                    if ($domainsRaw.PSObject.Properties[$group]) { $existing = @($domainsRaw.$group) }
                    if ($existing -notcontains $domain) { $existing += $domain }
                    if ($domainsRaw.PSObject.Properties[$group]) { $domainsRaw.$group = $existing }
                    else { $domainsRaw | Add-Member -NotePropertyName $group -NotePropertyValue $existing -Force }
                    $json = $domainsRaw | ConvertTo-Json -Depth 10
                    [System.IO.File]::WriteAllText($domainsFile, $json)
                    $domainSet[$domain.ToLower()] = $true
                }
                $jsonOut = '{"ok":true}'
            }
            "/domains/remove" {
                $domain = $req.QueryString["domain"]
                if ($domain) {
                    $domainsRaw = Get-Content $domainsFile -Raw | ConvertFrom-Json
                    foreach ($prop in $domainsRaw.PSObject.Properties) {
                        $prop.Value = @($prop.Value | Where-Object { $_ -ne $domain })
                    }
                    $json = $domainsRaw | ConvertTo-Json -Depth 10
                    [System.IO.File]::WriteAllText($domainsFile, $json)
                    $domainSet.Remove($domain.ToLower())
                }
                $jsonOut = '{"ok":true}'
            }
            "/config" {
                $cfg = Get-Content $configFile -Raw
                $jsonOut = $cfg
            }
            "/api/stats" {
                $jsonOut = @{
                    uptime = $state.StartTime.ToString("o")
                    proxy_enabled = $state.ProxyEnabled
                    total_requests = $state.TotalRequests
                    proxied_requests = $state.ProxiedRequests
                    direct_requests = $state.DirectRequests
                    active_conns = $state.ActiveConns
                    network_state = $state.NetworkState
                    wifi_detection = $state.WifiDetection
                    auto_start = $state.AutoStart
                    ssid_pattern = $state.SsidPattern
                } | ConvertTo-Json -Compress
            }
            "/api/logs" {
                $logs = @($logBuffer.ToArray())
                $jsonOut = if ($logs.Count -gt 0) { ConvertTo-Json $logs -Compress -Depth 3 } else { "[]" }
            }
            default {
                if (($path -eq "/dashboard" -or $path -eq "/") -and $state.DashboardEnabled -and $dashHtml) {
                    $htmlOut = $dashHtml
                } else { $resp.StatusCode = 404 }
            }
        }

        try {
            if ($jsonOut) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
                $resp.ContentType = "application/json"
                $resp.ContentLength64 = $bytes.Length
                $resp.OutputStream.Write($bytes, 0, $bytes.Length)
            } elseif ($htmlOut) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($htmlOut)
                $resp.ContentType = "text/html; charset=utf-8"
                $resp.ContentLength64 = $bytes.Length
                $resp.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            $resp.Close()
        } catch {}
    }
    $listener.Stop()
}

# --- Proxy connection handler ---
$proxyHandler = {
    param($client, $upstreamProxy, $domainSet, $state, $logBuffer, $logMax)

    function Test-Match($h, $ds, $st) {
        $h = $h.ToLower()
        if ($h -match '^(.+):(\d+)$') { $h = $Matches[1] }
        if ($h -eq 'localhost' -or $h -eq '127.0.0.1' -or $h -eq '::1') { return $false }
        if ($st.NetworkState -eq "OTHER") { return $false }
        if ($ds.ContainsKey($h)) { return $true }
        foreach ($d in @($ds.Keys)) { if ($h.EndsWith(".$d")) { return $true } }
        return $false
    }

    try {
        [System.Threading.Interlocked]::Increment([ref]$state.ActiveConns) | Out-Null
        $stream = $client.GetStream()
        $stream.ReadTimeout = 10000
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 4096, $true)
        $firstLine = $reader.ReadLine()
        if (-not $firstLine) { $client.Close(); return }

        $parts = $firstLine -split '\s+', 3
        if ($parts.Length -lt 3) { $client.Close(); return }
        $method = $parts[0].ToUpper()
        $target = $parts[1]

        # Read headers
        while ($true) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrEmpty($line)) { break }
        }

        if ($method -eq 'CONNECT') {
            $hostPort = $target
            if ($hostPort -notmatch ':') { $hostPort += ":443" }
            $shouldProxy = Test-Match $hostPort $domainSet $state
            [System.Threading.Interlocked]::Increment([ref]$state.TotalRequests) | Out-Null

            if ($shouldProxy) {
                [System.Threading.Interlocked]::Increment([ref]$state.ProxiedRequests) | Out-Null
                $proxyUri = [Uri]$upstreamProxy
                $pHost = $proxyUri.Host; $pPort = if ($proxyUri.Port -gt 0) { $proxyUri.Port } else { 8080 }
                $remote = New-Object System.Net.Sockets.TcpClient($pHost, $pPort)
                $remoteStream = $remote.GetStream()
                $connReq = [System.Text.Encoding]::ASCII.GetBytes("CONNECT $hostPort HTTP/1.1`r`nHost: $hostPort`r`n`r`n")
                $remoteStream.Write($connReq, 0, $connReq.Length)
                $buf = New-Object byte[] 4096
                $n = $remoteStream.Read($buf, 0, $buf.Length)
                $connResp = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
                if ($connResp -notmatch ' 200 ') { $client.Close(); $remote.Close(); return }
                $ok = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 Connection Established`r`n`r`n")
                $stream.Write($ok, 0, $ok.Length)
                $t1 = $stream.CopyToAsync($remoteStream)
                $t2 = $remoteStream.CopyToAsync($stream)
                [System.Threading.Tasks.Task]::WaitAny(@($t1, $t2)) | Out-Null
                try { $remote.Close() } catch {}
            } else {
                [System.Threading.Interlocked]::Increment([ref]$state.DirectRequests) | Out-Null
                $hp = $hostPort -split ':'
                $remote = New-Object System.Net.Sockets.TcpClient($hp[0], [int]$hp[1])
                $remoteStream = $remote.GetStream()
                $ok = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 Connection Established`r`n`r`n")
                $stream.Write($ok, 0, $ok.Length)
                $t1 = $stream.CopyToAsync($remoteStream)
                $t2 = $remoteStream.CopyToAsync($stream)
                [System.Threading.Tasks.Task]::WaitAny(@($t1, $t2)) | Out-Null
                try { $remote.Close() } catch {}
            }
            $logBuffer.Enqueue(@{ time=[DateTime]::UtcNow.ToString("o"); method="CONNECT"; host=$hostPort; proxied=$shouldProxy; status=200 })
            while ($logBuffer.Count -gt $logMax) { $null = $logBuffer.TryDequeue([ref]$null) }
        } else {
            # HTTP
            $uri = try { [Uri]$target } catch { $null }
            if (-not $uri) { $client.Close(); return }
            $hostName = $uri.Host
            $shouldProxy = Test-Match $hostName $domainSet $state
            [System.Threading.Interlocked]::Increment([ref]$state.TotalRequests) | Out-Null

            $handler = New-Object System.Net.Http.HttpClientHandler
            if ($shouldProxy) {
                [System.Threading.Interlocked]::Increment([ref]$state.ProxiedRequests) | Out-Null
                $handler.Proxy = New-Object System.Net.WebProxy($upstreamProxy)
                $handler.UseProxy = $true
            } else {
                [System.Threading.Interlocked]::Increment([ref]$state.DirectRequests) | Out-Null
                $handler.UseProxy = $false
            }
            $hc = New-Object System.Net.Http.HttpClient($handler)
            $hc.Timeout = [TimeSpan]::FromSeconds(30)
            try {
                $reqMsg = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]$method, $target)
                $resp_ = $hc.SendAsync($reqMsg).GetAwaiter().GetResult()
                $sc = [int]$resp_.StatusCode
                $respLine = "HTTP/1.1 $sc $($resp_.ReasonPhrase)`r`n"
                $stream.Write([System.Text.Encoding]::ASCII.GetBytes($respLine), 0, $respLine.Length)
                foreach ($h in $resp_.Headers) {
                    $l = "$($h.Key): $($h.Value -join ', ')`r`n"
                    $stream.Write([System.Text.Encoding]::ASCII.GetBytes($l), 0, $l.Length)
                }
                foreach ($h in $resp_.Content.Headers) {
                    $l = "$($h.Key): $($h.Value -join ', ')`r`n"
                    $stream.Write([System.Text.Encoding]::ASCII.GetBytes($l), 0, $l.Length)
                }
                $stream.Write([System.Text.Encoding]::ASCII.GetBytes("`r`n"), 0, 2)
                $body = $resp_.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
                $logBuffer.Enqueue(@{ time=[DateTime]::UtcNow.ToString("o"); method=$method; host=$hostName; proxied=$shouldProxy; status=$sc })
            } catch {
                $stream.Write([System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 502 Bad Gateway`r`n`r`n"), 0, 30)
                $logBuffer.Enqueue(@{ time=[DateTime]::UtcNow.ToString("o"); method=$method; host=$hostName; proxied=$shouldProxy; status=502 })
            }
            while ($logBuffer.Count -gt $logMax) { $null = $logBuffer.TryDequeue([ref]$null) }
            $hc.Dispose(); $handler.Dispose()
        }
    } catch {} finally {
        [System.Threading.Interlocked]::Decrement([ref]$state.ActiveConns) | Out-Null
        try { $client.Close() } catch {}
    }
}

# --- Start RunspacePool ---
$maxConns = if ($script:Config.proxy.max_connections -gt 0) { $script:Config.proxy.max_connections } else { 20 }
$pool = [RunspaceFactory]::CreateRunspacePool(1, $maxConns)
$pool.Open()
$jobs = [System.Collections.ArrayList]::new()

# Start control API runspace
$controlPS = [PowerShell]::Create()
$controlPS.RunspacePool = $pool
$dashFile = Join-Path $scriptDir "dashboard.html"
$defaultConfigPath = Join-Path $scriptDir "config.default.json"
$controlPS.AddScript($controlScriptBlock).
    AddArgument($script:Config.control.port).
    AddArgument($script:Config.proxy.port).
    AddArgument($script:State).
    AddArgument($script:LogBuffer).
    AddArgument($script:LogMax).
    AddArgument($configPath).
    AddArgument($script:DomainSet).
    AddArgument($dashFile).
    AddArgument($scriptDir).
    AddArgument($domainsPath).
    AddArgument($defaultConfigPath) | Out-Null
$controlHandle = $controlPS.BeginInvoke()

# Start proxy TcpListener
$proxyPort = $script:Config.proxy.port
$tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $proxyPort)
$tcpListener.Start()

$upstreamProxy = if (@($script:Config.proxy.upstream_proxies).Count -gt 0) { $script:Config.proxy.upstream_proxies[0] } else { "" }

Write-Host "  Proxy listening on 127.0.0.1:$proxyPort" -ForegroundColor Green
Write-Host "  Control API on http://127.0.0.1:$($script:Config.control.port)/" -ForegroundColor Green
Write-Host "  System proxy enabled (registry + env vars)" -ForegroundColor Green
if ($script:State.DashboardEnabled) {
    Write-Host "  Dashboard on http://127.0.0.1:$($script:Config.control.port)/dashboard" -ForegroundColor Green
}
Write-Host "  Network state: $($script:State.NetworkState)" -ForegroundColor Yellow
Write-Host ""

$lastSsidCheck = [DateTime]::Now
$detectionInterval = if ($script:Config.network.detection_interval_sec -gt 0) { $script:Config.network.detection_interval_sec } else { 30 }

# --- Main loop ---
while ($script:State.Running) {
    while ($tcpListener.Pending()) {
        $client = $tcpListener.AcceptTcpClient()
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        $ps.AddScript($proxyHandler).
            AddArgument($client).
            AddArgument($upstreamProxy).
            AddArgument($script:DomainSet).
            AddArgument($script:State).
            AddArgument($script:LogBuffer).
            AddArgument($script:LogMax) | Out-Null
        $handle = $ps.BeginInvoke()
        $jobs.Add(@{ PS = $ps; Handle = $handle }) | Out-Null
    }

    # SSID check at configured interval
    if ($script:State.WifiDetection -and ([DateTime]::Now - $lastSsidCheck).TotalSeconds -ge $detectionInterval) {
        $ssid = Get-CurrentSSID
        $script:State.NetworkState = if ($ssid -match $script:State.SsidPattern) { "CORP" } else { "OTHER" }
        $lastSsidCheck = [DateTime]::Now
    }

    # Cleanup completed jobs
    for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
        if ($jobs[$i].Handle.IsCompleted) {
            try { $jobs[$i].PS.EndInvoke($jobs[$i].Handle) } catch {}
            $jobs[$i].PS.Dispose()
            $jobs.RemoveAt($i)
        }
    }

    Start-Sleep -Milliseconds 20
}

# --- Shutdown ---
Write-Host "`nShutting down..." -ForegroundColor Yellow
$tcpListener.Stop()

Disable-SystemProxy
Write-Host "  System proxy cleared" -ForegroundColor Green

Stop-ConfigWatcher

try { $controlPS.EndInvoke($controlHandle) } catch {}
$controlPS.Dispose()
foreach ($j in $jobs) { try { $j.PS.Dispose() } catch {} }
$pool.Close()
Remove-Item (Join-Path $scriptDir "proxy.pid") -ErrorAction SilentlyContinue
$mutex.ReleaseMutex()
Write-Host "Stopped." -ForegroundColor Green
