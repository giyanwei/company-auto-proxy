$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cliScript = Join-Path $scriptDir "proxy-cli.ps1"
if (-not (Test-Path $cliScript)) {
    $cliScript = Join-Path $scriptDir "..\src\proxy-cli.ps1"
}
if (-not (Test-Path $cliScript)) {
    $cliScript = Join-Path "$env:USERPROFILE\.proxy" "proxy-cli.ps1"
}
& $cliScript @args
