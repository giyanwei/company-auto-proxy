$script:BypassList = $null

function Initialize-BypassList {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ScriptDir
    )

    $bypassPath = Join-Path $ScriptDir "bypass.json"
    if (-not (Test-Path $bypassPath)) {
        $script:BypassList = [hashtable]::Synchronized(@{
            Exact = [hashtable]::Synchronized(@{})
            Prefix = [System.Collections.ArrayList]::new()
            Suffix = [System.Collections.ArrayList]::new()
            Cidr = [System.Collections.ArrayList]::new()
            Raw = [System.Collections.ArrayList]::new()
        })
        return $script:BypassList
    }

    $entries = Get-Content $bypassPath -Raw | ConvertFrom-Json
    $script:BypassList = Build-BypassStructure -Entries @($entries)
    return $script:BypassList
}

function Build-BypassStructure {
    param([string[]]$Entries)

    $exact = [hashtable]::Synchronized(@{})
    $prefix = [System.Collections.ArrayList]::new()
    $suffix = [System.Collections.ArrayList]::new()
    $cidr = [System.Collections.ArrayList]::new()
    $raw = [System.Collections.ArrayList]::new()

    foreach ($entry in $Entries) {
        $e = $entry.Trim()
        if (-not $e) { continue }
        $raw.Add($e) | Out-Null

        if ($e -match '^(.+)/(\d+)$') {
            $network = $Matches[1]
            $bits = [int]$Matches[2]
            $parsed = $null
            if ([System.Net.IPAddress]::TryParse($network, [ref]$parsed)) {
                $cidr.Add(@{ Network = $parsed; Bits = $bits }) | Out-Null
                continue
            }
        }

        if ($e.StartsWith("*.")) {
            $suffix.Add($e.Substring(1).ToLower()) | Out-Null
        } elseif ($e.EndsWith(".*")) {
            $prefix.Add($e.Substring(0, $e.Length - 1).ToLower()) | Out-Null
        } else {
            $exact[$e.ToLower()] = $true
        }
    }

    return [hashtable]::Synchronized(@{
        Exact = $exact
        Prefix = $prefix
        Suffix = $suffix
        Cidr = $cidr
        Raw = $raw
    })
}

function Test-Bypass {
    param(
        [Parameter(Mandatory=$true)]
        [string]$HostName,
        [Parameter(Mandatory=$true)]
        [hashtable]$BypassList
    )

    $h = $HostName.ToLower()
    if ($h -match '^(.+):(\d+)$') { $h = $Matches[1] }

    if ($BypassList.Exact.ContainsKey($h)) { return $true }

    foreach ($s in $BypassList.Suffix) {
        if ($h.EndsWith($s) -or $h -eq $s.Substring(1)) { return $true }
    }

    foreach ($p in $BypassList.Prefix) {
        if ($h.StartsWith($p)) { return $true }
    }

    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($h, [ref]$parsed) -and $BypassList.Cidr.Count -gt 0) {
        $ipBytes = $parsed.GetAddressBytes()
        foreach ($c in $BypassList.Cidr) {
            $netBytes = $c.Network.GetAddressBytes()
            $bits = $c.Bits
            $match = $true
            for ($i = 0; $i -lt 4; $i++) {
                $maskByte = if ($bits -ge 8) { 255 } elseif ($bits -gt 0) { [byte](256 - [Math]::Pow(2, 8 - $bits)) } else { 0 }
                if (($ipBytes[$i] -band $maskByte) -ne ($netBytes[$i] -band $maskByte)) {
                    $match = $false
                    break
                }
                $bits = [Math]::Max(0, $bits - 8)
            }
            if ($match) { return $true }
        }
    }

    return $false
}

function Get-NoProxyString {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$BypassList
    )
    return ($BypassList.Raw -join ',')
}

function Get-ProxyOverrideString {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$BypassList
    )
    $entries = @($BypassList.Raw) + @("<local>")
    return ($entries -join ';')
}

function Add-BypassEntry {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Pattern,
        [Parameter(Mandatory=$true)]
        [string]$BypassPath,
        [Parameter(Mandatory=$true)]
        [hashtable]$BypassList
    )

    $pattern = $Pattern.Trim()
    if ($BypassList.Raw -contains $pattern) { return $false }

    $BypassList.Raw.Add($pattern) | Out-Null
    $p = $pattern.ToLower()
    if ($p -match '^(.+)/(\d+)$') {
        $network = $Matches[1]; $bits = [int]$Matches[2]
        $parsed = $null
        if ([System.Net.IPAddress]::TryParse($network, [ref]$parsed)) {
            $BypassList.Cidr.Add(@{ Network = $parsed; Bits = $bits }) | Out-Null
        }
    } elseif ($p.StartsWith("*.")) {
        $BypassList.Suffix.Add($p.Substring(1)) | Out-Null
    } elseif ($p.EndsWith(".*")) {
        $BypassList.Prefix.Add($p.Substring(0, $p.Length - 1)) | Out-Null
    } else {
        $BypassList.Exact[$p] = $true
    }

    $json = ConvertTo-Json @($BypassList.Raw) -Depth 5
    $tmpPath = "$BypassPath.tmp"
    [System.IO.File]::WriteAllText($tmpPath, $json)
    if (Test-Path $BypassPath) { Remove-Item $BypassPath -Force }
    [System.IO.File]::Move($tmpPath, $BypassPath)
    return $true
}

function Remove-BypassEntry {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Pattern,
        [Parameter(Mandatory=$true)]
        [string]$BypassPath,
        [Parameter(Mandatory=$true)]
        [hashtable]$BypassList
    )

    $pattern = $Pattern.Trim()
    if ($BypassList.Raw -notcontains $pattern) { return $false }

    $remaining = @($BypassList.Raw | Where-Object { $_ -ne $pattern })
    $newList = Build-BypassStructure -Entries $remaining
    $BypassList.Exact = $newList.Exact
    $BypassList.Prefix = $newList.Prefix
    $BypassList.Suffix = $newList.Suffix
    $BypassList.Cidr = $newList.Cidr
    $BypassList.Raw = $newList.Raw

    $json = ConvertTo-Json @($BypassList.Raw) -Depth 5
    $tmpPath = "$BypassPath.tmp"
    [System.IO.File]::WriteAllText($tmpPath, $json)
    if (Test-Path $BypassPath) { Remove-Item $BypassPath -Force }
    [System.IO.File]::Move($tmpPath, $BypassPath)
    return $true
}
