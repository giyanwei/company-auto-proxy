<#
.SYNOPSIS
    Domain matching module for Company Auto Proxy.
.DESCRIPTION
    Loads domain lists, provides O(1) hashtable lookup with subdomain stripping,
    and supports runtime add/remove with atomic persistence.
#>

$script:DomainSet = $null

function Initialize-DomainSet {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ScriptDir
    )

    $domainsPath = Join-Path $ScriptDir "domains.json"
    if (-not (Test-Path $domainsPath)) {
        throw "domains.json not found at $domainsPath"
    }

    $domainsRaw = Get-Content $domainsPath -Raw | ConvertFrom-Json
    $domainSet = [hashtable]::Synchronized(@{})

    foreach ($group in $domainsRaw.PSObject.Properties) {
        foreach ($d in $group.Value) {
            $domainSet[$d.ToLower()] = $true
        }
    }

    $script:DomainSet = $domainSet
    return $script:DomainSet
}

function Test-DomainMatch {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Host_,
        [Parameter(Mandatory=$true)]
        [hashtable]$DomainSet,
        [Parameter(Mandatory=$true)]
        [hashtable]$State
    )

    $h = $Host_.ToLower()

    # Strip port if present
    if ($h -match '^(.+):(\d+)$') {
        $h = $Matches[1]
    }

    # Localhost bypass
    if ($h -eq 'localhost' -or $h -eq '127.0.0.1' -or $h -eq '::1') {
        return $false
    }

    # Non-corporate network bypass
    if ($State.NetworkState -eq "OTHER") {
        return $false
    }

    # Exact match (O(1))
    if ($DomainSet.ContainsKey($h)) {
        return $true
    }

    # Progressive subdomain stripping
    $parts = $h.Split('.')
    for ($i = 1; $i -lt $parts.Count - 1; $i++) {
        $parent = ($parts[$i..($parts.Count - 1)]) -join '.'
        if ($DomainSet.ContainsKey($parent)) {
            return $true
        }
    }

    return $false
}

function Add-Domain {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Group,
        [Parameter(Mandatory=$true)]
        [string]$Domain,
        [Parameter(Mandatory=$true)]
        [string]$DomainsPath,
        [Parameter(Mandatory=$true)]
        [hashtable]$DomainSet
    )

    $domain = $Domain.ToLower()
    $DomainSet[$domain] = $true

    if (-not (Test-Path $DomainsPath)) {
        return $false
    }

    try {
        $domainsRaw = Get-Content $DomainsPath -Raw | ConvertFrom-Json

        $existing = @()
        if ($domainsRaw.PSObject.Properties[$Group]) {
            $existing = @($domainsRaw.$Group)
        }

        if ($existing -notcontains $domain) {
            $existing += $domain
        }

        if ($domainsRaw.PSObject.Properties[$Group]) {
            $domainsRaw.$Group = $existing
        } else {
            $domainsRaw | Add-Member -NotePropertyName $Group -NotePropertyValue $existing -Force
        }

        $tmpPath = "$DomainsPath.tmp"
        $json = $domainsRaw | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($tmpPath, $json)

        $readBack = [System.IO.File]::ReadAllText($tmpPath)
        $null = $readBack | ConvertFrom-Json

        if (Test-Path $DomainsPath) {
            Remove-Item $DomainsPath -Force
        }
        [System.IO.File]::Move($tmpPath, $DomainsPath)
        return $true
    } catch {
        if (Test-Path "$DomainsPath.tmp") {
            Remove-Item "$DomainsPath.tmp" -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

function Remove-Domain {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Domain,
        [Parameter(Mandatory=$true)]
        [string]$DomainsPath,
        [Parameter(Mandatory=$true)]
        [hashtable]$DomainSet
    )

    $domain = $Domain.ToLower()
    $DomainSet.Remove($domain)

    if (-not (Test-Path $DomainsPath)) {
        return $false
    }

    try {
        $domainsRaw = Get-Content $DomainsPath -Raw | ConvertFrom-Json

        foreach ($prop in $domainsRaw.PSObject.Properties) {
            $prop.Value = @($prop.Value | Where-Object { $_.ToLower() -ne $domain })
        }

        $tmpPath = "$DomainsPath.tmp"
        $json = $domainsRaw | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($tmpPath, $json)

        $readBack = [System.IO.File]::ReadAllText($tmpPath)
        $null = $readBack | ConvertFrom-Json

        if (Test-Path $DomainsPath) {
            Remove-Item $DomainsPath -Force
        }
        [System.IO.File]::Move($tmpPath, $DomainsPath)
        return $true
    } catch {
        if (Test-Path "$DomainsPath.tmp") {
            Remove-Item "$DomainsPath.tmp" -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}
