# >>> company-proxy-auto >>>
function __CompanyProxySwitch {
    $stateFile = "$env:USERPROFILE\.proxy\state"
    if (Test-Path $stateFile) {
        $state = Get-Content $stateFile -Raw
        if ($state -eq "CORP") {
            $proxyUrl = Get-Content "$env:USERPROFILE\.proxy\.proxy_url" -Raw -ErrorAction SilentlyContinue
            $env:HTTPS_PROXY = $proxyUrl
            $env:HTTP_PROXY = $proxyUrl
        } else {
            $env:HTTPS_PROXY = $null
            $env:HTTP_PROXY = $null
        }
    } else {
        $env:HTTPS_PROXY = $null
        $env:HTTP_PROXY = $null
    }
}

$__cpaOriginalPrompt = $function:prompt
function prompt {
    __CompanyProxySwitch
    & $__cpaOriginalPrompt
}
# <<< company-proxy-auto <<<
