<#
.SYNOPSIS
    Build company-proxy-auto Go binary.
.DESCRIPTION
    Compiles the proxy executable with embedded config and dashboard.
#>

param(
    [string]$Output = "proxy.exe",
    [switch]$Release
)

$ErrorActionPreference = "Stop"

Write-Host "=== Building company-proxy-auto ===" -ForegroundColor Cyan

# Check Go
$goVersion = go version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Go is not installed. Please install Go from https://go.dev/dl/"
}
Write-Host "Using: $goVersion"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $projectRoot

try {
    $ldflags = "-s -w"
    if ($Release) {
        Write-Host "Building release binary..." -ForegroundColor Green
        $env:CGO_ENABLED = "0"
        go build -ldflags $ldflags -trimpath -o $Output ./cmd/proxy/
    } else {
        Write-Host "Building debug binary..." -ForegroundColor Green
        go build -o $Output ./cmd/proxy/
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Build failed"
    }

    $size = (Get-Item $Output).Length / 1MB
    Write-Host ""
    Write-Host "Build successful!" -ForegroundColor Green
    Write-Host "  Output: $Output"
    Write-Host "  Size: $([math]::Round($size, 2)) MB"
    Write-Host ""
    Write-Host "Quick start:" -ForegroundColor Yellow
    Write-Host "  .\$Output start              # Start proxy"
    Write-Host "  .\$Output start --dashboard  # Start with dashboard"
    Write-Host "  .\$Output status             # Check status"
    Write-Host "  .\$Output install --full     # Install as service with dashboard"
} finally {
    Pop-Location
}
