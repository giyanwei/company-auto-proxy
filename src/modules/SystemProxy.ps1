<#
.SYNOPSIS
    System proxy management module for Company Auto Proxy.
.DESCRIPTION
    Manages Windows system proxy settings via registry (Internet Settings)
    and user-level environment variables (HTTP_PROXY, HTTPS_PROXY).
#>

$script:RegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

function Enable-SystemProxy {
    param(
        [Parameter(Mandatory=$true)]
        [int]$Port
    )

    $proxyAddr = "127.0.0.1:$Port"
    $proxyUrl = "http://$proxyAddr"

    Set-ItemProperty -Path $script:RegistryPath -Name ProxyEnable -Value 1
    Set-ItemProperty -Path $script:RegistryPath -Name ProxyServer -Value $proxyAddr

    [System.Environment]::SetEnvironmentVariable("HTTP_PROXY", $proxyUrl, "User")
    [System.Environment]::SetEnvironmentVariable("HTTPS_PROXY", $proxyUrl, "User")
}

function Disable-SystemProxy {
    Set-ItemProperty -Path $script:RegistryPath -Name ProxyEnable -Value 0
    Remove-ItemProperty -Path $script:RegistryPath -Name ProxyServer -ErrorAction SilentlyContinue

    [System.Environment]::SetEnvironmentVariable("HTTP_PROXY", $null, "User")
    [System.Environment]::SetEnvironmentVariable("HTTPS_PROXY", $null, "User")
}

function Get-SystemProxyState {
    $enabled = $false
    $server = ""

    try {
        $enableVal = Get-ItemProperty -Path $script:RegistryPath -Name ProxyEnable -ErrorAction SilentlyContinue
        if ($enableVal) {
            $enabled = [bool]$enableVal.ProxyEnable
        }

        $serverVal = Get-ItemProperty -Path $script:RegistryPath -Name ProxyServer -ErrorAction SilentlyContinue
        if ($serverVal -and $serverVal.ProxyServer) {
            $server = $serverVal.ProxyServer
        }
    } catch {
        # Registry keys may not exist
    }

    $httpProxy = [System.Environment]::GetEnvironmentVariable("HTTP_PROXY", "User")
    $httpsProxy = [System.Environment]::GetEnvironmentVariable("HTTPS_PROXY", "User")

    return @{
        Enabled = $enabled
        Server = $server
        EnvVars = @{
            HTTP_PROXY = if ($httpProxy) { $httpProxy } else { "" }
            HTTPS_PROXY = if ($httpsProxy) { $httpsProxy } else { "" }
        }
    }
}
