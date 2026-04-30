$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$config = Get-Content "$scriptDir\config.json" -Raw | ConvertFrom-Json

$installPath = $config.install_path -replace '%USERPROFILE%', $env:USERPROFILE
$pacPort = $config.pac_port
$pacFile = "$installPath\proxy.pac"

$prefix = "http://127.0.0.1:${pacPort}/"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $response = $context.Response

    if ($context.Request.Url.LocalPath -eq "/proxy.pac") {
        $content = [System.IO.File]::ReadAllBytes($pacFile)
        $response.ContentType = "application/x-ns-proxy-autoconfig"
        $response.ContentLength64 = $content.Length
        $response.OutputStream.Write($content, 0, $content.Length)
    } else {
        $response.StatusCode = 404
    }

    $response.Close()
}
