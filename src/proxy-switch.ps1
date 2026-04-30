$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$config = Get-Content "$scriptDir\config.json" -Raw | ConvertFrom-Json

$installPath = $config.install_path -replace '%USERPROFILE%', $env:USERPROFILE
$proxy = $config.proxies[0]
$pacPort = $config.pac_port
$ssidPattern = $config.ssid_pattern
$pacUrl = "http://127.0.0.1:${pacPort}/proxy.pac"
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$stateFile = "$installPath\state"

$mutex = New-Object System.Threading.Mutex($false, "Global\CompanyProxyAutoMutex")
if (-not $mutex.WaitOne(0)) {
    exit
}

Start-Process -WindowStyle Hidden -FilePath "powershell" -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installPath\pac-server.ps1`""

Start-Sleep -Seconds 2

$lastState = $null

while ($true) {
    $wlanOutput = netsh wlan show interfaces
    $ssidLine = $wlanOutput | Select-String "^\s+SSID\s+:" | Select-Object -First 1
    $ssid = if ($ssidLine) { ($ssidLine -split ":\s*", 2)[1].Trim() } else { "" }

    $isTarget = $ssid -match $ssidPattern

    if ($isTarget -and $lastState -ne "CORP") {
        Set-ItemProperty -Path $regPath -Name AutoConfigURL -Value $pacUrl
        Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0
        git config --global http.https://github.com.proxy $proxy
        npm config set proxy $proxy
        npm config set https-proxy $proxy
        [System.Environment]::SetEnvironmentVariable("HTTPS_PROXY", $proxy, "User")
        [System.Environment]::SetEnvironmentVariable("HTTP_PROXY", $proxy, "User")
        Set-Content -Path $stateFile -Value "CORP" -NoNewline
        $lastState = "CORP"
    }
    elseif (-not $isTarget -and $lastState -ne "OTHER") {
        Remove-ItemProperty -Path $regPath -Name AutoConfigURL -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0
        git config --global --unset http.https://github.com.proxy 2>$null
        npm config delete proxy 2>$null
        npm config delete https-proxy 2>$null
        [System.Environment]::SetEnvironmentVariable("HTTPS_PROXY", $null, "User")
        [System.Environment]::SetEnvironmentVariable("HTTP_PROXY", $null, "User")
        Set-Content -Path $stateFile -Value "OTHER" -NoNewline
        $lastState = "OTHER"
    }

    Start-Sleep -Seconds 30
}
