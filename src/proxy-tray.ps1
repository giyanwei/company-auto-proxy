<#
.SYNOPSIS
    company-auto-proxy system tray icon.
.DESCRIPTION
    Displays a system tray icon with proxy status and control menu.
    Communicates with the running proxy-service via control API.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = Join-Path $scriptDir "config.json"
$config = if (Test-Path $configFile) { Get-Content $configFile -Raw | ConvertFrom-Json } else { @{ control_port = 8082; proxy_port = 8081 } }
$controlPort = $config.control_port

# --- Helper functions ---
function Send-Command {
    param([string]$Path)
    try {
        return Invoke-RestMethod -Uri "http://127.0.0.1:${controlPort}${Path}" -TimeoutSec 2
    } catch { return $null }
}

function Test-Running {
    try { $null = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $controlPort); return $true }
    catch { return $false }
}

function Get-Status {
    if (-not (Test-Running)) { return $null }
    return Send-Command "/status"
}

# --- Create icon bitmaps ---
function New-TrayIcon {
    param([string]$Color)
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = "AntiAlias"
    $brush = switch ($Color) {
        "green"  { [System.Drawing.Brushes]::LimeGreen }
        "orange" { [System.Drawing.Brushes]::Orange }
        "gray"   { [System.Drawing.Brushes]::Gray }
        default  { [System.Drawing.Brushes]::Gray }
    }
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$iconGreen  = New-TrayIcon "green"
$iconOrange = New-TrayIcon "orange"
$iconGray   = New-TrayIcon "gray"

# --- System tray setup ---
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Text = "Company Proxy Auto"
$notifyIcon.Icon = $iconGray
$notifyIcon.Visible = $true

# --- Context menu ---
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

$statusItem = $contextMenu.Items.Add("Status: checking...")
$statusItem.Enabled = $false

$contextMenu.Items.Add("-") | Out-Null

$startItem = $contextMenu.Items.Add("Start Proxy")
$startItem.Add_Click({
    $args_ = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptDir\proxy-service.ps1`" -Dashboard"
    Start-Process powershell -ArgumentList $args_ -WindowStyle Hidden
    Start-Sleep -Seconds 2
    Update-TrayState
    $notifyIcon.ShowBalloonTip(2000, "Proxy", "Proxy service started", [System.Windows.Forms.ToolTipIcon]::Info)
})

$stopItem = $contextMenu.Items.Add("Stop Proxy")
$stopItem.Add_Click({
    Send-Command "/stop" | Out-Null
    Start-Sleep -Seconds 1
    Update-TrayState
    $notifyIcon.ShowBalloonTip(2000, "Proxy", "Proxy service stopped", [System.Windows.Forms.ToolTipIcon]::Info)
})

$contextMenu.Items.Add("-") | Out-Null

$dashboardItem = $contextMenu.Items.Add("Open Dashboard")
$dashboardItem.Add_Click({
    Start-Process "http://127.0.0.1:${controlPort}/dashboard"
})

$contextMenu.Items.Add("-") | Out-Null

$domainsMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Domains")
$contextMenu.Items.Add($domainsMenu) | Out-Null

$contextMenu.Items.Add("-") | Out-Null

$settingsItem = $contextMenu.Items.Add("Open Config")
$settingsItem.Add_Click({
    if (Test-Path $configFile) { Start-Process notepad $configFile }
})

$reloadItem = $contextMenu.Items.Add("Reload Config")
$reloadItem.Add_Click({
    Send-Command "/reload" | Out-Null
    $notifyIcon.ShowBalloonTip(1000, "Proxy", "Configuration reloaded", [System.Windows.Forms.ToolTipIcon]::Info)
})

$contextMenu.Items.Add("-") | Out-Null

$exitItem = $contextMenu.Items.Add("Exit Tray")
$exitItem.Add_Click({
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.ContextMenuStrip = $contextMenu

# --- Double-click to open dashboard ---
$notifyIcon.Add_DoubleClick({
    Start-Process "http://127.0.0.1:${controlPort}/dashboard"
})

# --- State update ---
$script:lastNetworkState = ""

function Update-TrayState {
    $status = Get-Status
    if ($status) {
        $state = $status.network_state
        if ($state -eq "CORP") {
            $notifyIcon.Icon = $iconOrange
            $statusItem.Text = "Status: CORP (proxied)"
            $notifyIcon.Text = "Proxy: CORP - $($status.total_requests) requests"
        } else {
            $notifyIcon.Icon = $iconGreen
            $statusItem.Text = "Status: DIRECT"
            $notifyIcon.Text = "Proxy: DIRECT - $($status.total_requests) requests"
        }
        $startItem.Enabled = $false
        $stopItem.Enabled = $true
        $dashboardItem.Enabled = $true

        # Notify on state change
        if ($script:lastNetworkState -and $script:lastNetworkState -ne $state) {
            $notifyIcon.ShowBalloonTip(3000, "Network Changed", "Mode: $state", [System.Windows.Forms.ToolTipIcon]::Info)
        }
        $script:lastNetworkState = $state

        # Update domains menu
        $domainsMenu.DropDownItems.Clear()
        $domains = Send-Command "/domains"
        if ($domains) {
            foreach ($prop in $domains.PSObject.Properties) {
                $groupItem = New-Object System.Windows.Forms.ToolStripMenuItem("$($prop.Name) ($($prop.Value.Count))")
                $groupItem.Enabled = $false
                $domainsMenu.DropDownItems.Add($groupItem) | Out-Null
            }
        }
    } else {
        $notifyIcon.Icon = $iconGray
        $statusItem.Text = "Status: stopped"
        $notifyIcon.Text = "Proxy: stopped"
        $startItem.Enabled = $true
        $stopItem.Enabled = $false
        $dashboardItem.Enabled = $false
        $script:lastNetworkState = ""
    }
}

# --- Timer for periodic state refresh ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-TrayState })
$timer.Start()

# Initial state
Update-TrayState

# --- Run message loop ---
[System.Windows.Forms.Application]::Run()
