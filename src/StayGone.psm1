# StayGone - keeps removed Windows bloatware gone.
# Copyright (c) 2026 Jhoana Sophia C. Munar. MIT License.
#
# Design: the decision logic (which apps to remove, which are protected)
# is pure functions that take plain data, so it can be unit-tested on any
# machine. The thin "system" functions at the bottom are the only places
# that touch Appx, the Task Scheduler or the notification system.

Set-StrictMode -Version 2.0

$script:AppName    = 'StayGone'
$script:AppVersion = '0.1.0'
$script:Author     = 'Jhoana Sophia C. Munar'
$script:RepoUrl    = 'https://github.com/sopi22/StayGone'
$script:TaskName   = 'StayGone Watcher'

# Packages StayGone refuses to remove even if they are on the blocklist:
# removing them breaks the Store, app installs, security or core Windows UI.
$script:ProtectedPatterns = @(
    'Microsoft.WindowsStore'
    'Microsoft.StorePurchaseApp'
    'Microsoft.DesktopAppInstaller'
    'Microsoft.SecHealthUI'
    'Microsoft.Windows.SecHealthUI'
    'Microsoft.VCLibs*'
    'Microsoft.NET.Native*'
    'Microsoft.UI.Xaml*'
    'Microsoft.WindowsAppRuntime*'
    'Microsoft.Windows.Photos'
    'Microsoft.WindowsCalculator'
    'Microsoft.WindowsNotepad'
    'Microsoft.WindowsTerminal'
    'Microsoft.Windows.ShellExperienceHost'
    'Microsoft.Windows.StartMenuExperienceHost'
    'MicrosoftWindows.Client.*'
    'Microsoft.AAD.BrokerPlugin'
    'Microsoft.AccountsControl'
    'windows.immersivecontrolpanel'
)

# ---------------------------------------------------------------- paths

function Get-StayGoneDataDir {
    if ($env:STAYGONE_DATA_DIR) { return $env:STAYGONE_DATA_DIR }
    return (Join-Path $env:ProgramData 'StayGone')
}

function Get-StayGonePaths {
    $dir = Get-StayGoneDataDir
    [pscustomobject]@{
        DataDir   = $dir
        Blocklist = Join-Path $dir 'blocklist.txt'
        Log       = Join-Path $dir 'staygone.log'
        State     = Join-Path $dir 'removed.json'
        AppDir    = Join-Path $dir 'app'
    }
}

# ---------------------------------------------------------- pure logic

function ConvertFrom-BlocklistText {
    <# Turns blocklist file lines into package-name patterns.
       Blank lines and '#' comments are ignored; '*' wildcards are allowed. #>
    param([string[]]$Lines)
    $patterns = @()
    foreach ($line in $Lines) {
        $clean = ($line -replace '#.*$', '').Trim()
        if ($clean) { $patterns += $clean }
    }
    return $patterns
}

function Test-StayGoneProtected {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($p in $script:ProtectedPatterns) {
        if ($Name -like $p) { return $true }
    }
    return $false
}

function Test-StayGoneMatch {
    param([Parameter(Mandatory)][string]$Name, [string[]]$Patterns)
    foreach ($p in $Patterns) {
        if ($Name -like $p) { return $true }
    }
    return $false
}

function Get-StayGonePlan {
    <# Decides what to do with each blocklisted app.
       -Installed:   objects with Name, PackageFamilyName, Version (installed for some user)
       -Provisioned: objects with DisplayName, PackageName (the hidden copy Windows
                     uses to reinstall the app for every user, e.g. after updates)
       Returns one row per matched app with Action = Remove | Protected. #>
    param(
        [string[]]$Patterns,
        [object[]]$Installed = @(),
        [object[]]$Provisioned = @()
    )
    $rows = @{}
    foreach ($pkg in $Installed) {
        if (-not (Test-StayGoneMatch -Name $pkg.Name -Patterns $Patterns)) { continue }
        if (-not $rows.ContainsKey($pkg.Name)) {
            $rows[$pkg.Name] = [pscustomobject]@{
                Name = $pkg.Name; PackageFamilyName = $pkg.PackageFamilyName
                Version = $pkg.Version; Installed = $true; Provisioned = $false; Action = ''
            }
        }
    }
    foreach ($prov in $Provisioned) {
        if (-not (Test-StayGoneMatch -Name $prov.DisplayName -Patterns $Patterns)) { continue }
        if ($rows.ContainsKey($prov.DisplayName)) {
            $rows[$prov.DisplayName].Provisioned = $true
        } else {
            $rows[$prov.DisplayName] = [pscustomobject]@{
                Name = $prov.DisplayName; PackageFamilyName = ''
                Version = $prov.Version; Installed = $false; Provisioned = $true; Action = ''
            }
        }
    }
    foreach ($row in $rows.Values) {
        if (Test-StayGoneProtected -Name $row.Name) { $row.Action = 'Protected' } else { $row.Action = 'Remove' }
    }
    return @($rows.Values | Sort-Object Name)
}

function Format-StayGoneNotification {
    <# Builds the notification text for apps removed in one run. #>
    param([string[]]$Removed, [string]$Trigger)
    if (-not $Removed -or $Removed.Count -eq 0) { return $null }
    $names = ($Removed | ForEach-Object { $_ -replace '^Microsoft\.', '' }) -join ', '
    $when = switch ($Trigger) {
        'update' { 'after a Windows update' }
        'logon'  { 'at sign-in' }
        default  { 'just now' }
    }
    $noun = 'app'
    if ($Removed.Count -gt 1) { $noun = 'apps' }
    return [pscustomobject]@{
        Title = "StayGone removed $($Removed.Count) $noun $when"
        Text  = "$names came back and $(if ($Removed.Count -gt 1) {'were'} else {'was'}) removed again."
    }
}

function Set-BlocklistEntryRestored {
    <# Comments out an app's line in the blocklist text so the watcher
       stops removing it. Returns the new lines and whether anything changed. #>
    param([string[]]$Lines, [string]$Name, [string]$Date)
    $changed = $false
    $out = foreach ($line in $Lines) {
        $clean = ($line -replace '#.*$', '').Trim()
        if ($clean -and ($clean -ieq $Name)) {
            $changed = $true
            "# $clean    # restored $Date"
        } else { $line }
    }
    [pscustomobject]@{ Lines = @($out); Changed = $changed }
}

function Select-LiveProvisioned {
    <# Splits provisioned entries into live ones and stale leftovers.
       A stale entry points at an install folder that no longer exists:
       Windows can't reinstall anything from it, and removing it fails with
       "path not found", so StayGone ignores it. -PathExists is injectable
       so tests don't touch the disk. #>
    param([object[]]$Provisioned = @(), [scriptblock]$PathExists = { param($p) Test-Path -LiteralPath $p })
    $live = @(); $stale = @()
    foreach ($prov in $Provisioned) {
        $location = "$($prov.InstallLocation)"
        $folder = $location -replace '\\AppxMetadata\\[^\\]+$', '' -replace '\\[^\\]+\.xml$', ''
        if ($location -and -not (& $PathExists $folder)) { $stale += $prov } else { $live += $prov }
    }
    [pscustomobject]@{ Live = $live; Stale = $stale }
}

# ------------------------------------------------------- system helpers

function Test-StayGoneAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-StayGoneData {
    param([string]$DefaultBlocklist)
    $paths = Get-StayGonePaths
    if (-not (Test-Path $paths.DataDir)) { New-Item -ItemType Directory -Path $paths.DataDir -Force | Out-Null }
    if (-not (Test-Path $paths.Blocklist) -and $DefaultBlocklist -and (Test-Path $DefaultBlocklist)) {
        Copy-Item $DefaultBlocklist $paths.Blocklist
    }
    return $paths
}

function Write-StayGoneLog {
    param([string]$Message)
    $paths = Get-StayGonePaths
    try {
        if (-not (Test-Path $paths.DataDir)) { New-Item -ItemType Directory -Path $paths.DataDir -Force | Out-Null }
        Add-Content -Path $paths.Log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    } catch {
        Write-Warning "Could not write log: $($_.Exception.Message)"
    }
}

function Get-StayGoneBlocklist {
    $paths = Get-StayGonePaths
    if (-not (Test-Path $paths.Blocklist)) { return @() }
    return (ConvertFrom-BlocklistText -Lines (Get-Content $paths.Blocklist))
}

function Get-StayGoneSystemState {
    <# Reads installed + provisioned packages. Without admin rights Windows
       only shows the current user's apps and no provisioned copies. #>
    param([switch]$AllUsers)
    $installed = @()
    $provisioned = @()
    $stale = @()
    if ($AllUsers) {
        $installed = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
        $split = Select-LiveProvisioned -Provisioned @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
        $provisioned = $split.Live
        $stale = $split.Stale
    } else {
        $installed = @(Get-AppxPackage -ErrorAction SilentlyContinue)
    }
    [pscustomobject]@{ Installed = $installed; Provisioned = $provisioned; Stale = $stale }
}

function Invoke-StayGoneRemoval {
    <# Removes each 'Remove' row for all users, plus its provisioned copy.
       Returns the names that were actually removed. Honors -WhatIf. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([object[]]$Plan, [string]$Trigger = 'manual')
    $removed = @()
    foreach ($row in $Plan) {
        if ($row.Action -ne 'Remove') { continue }
        if (-not $PSCmdlet.ShouldProcess($row.Name, 'Remove for all users and deprovision')) { continue }
        $ok = $true
        if ($row.Installed) {
            try {
                Get-AppxPackage -AllUsers -Name $row.Name -ErrorAction Stop |
                    Remove-AppxPackage -AllUsers -ErrorAction Stop
            } catch { $ok = $false; Write-StayGoneLog "FAILED to remove $($row.Name): $($_.Exception.Message)" }
        }
        if ($row.Provisioned) {
            try {
                Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $row.Name } |
                    Remove-AppxProvisionedPackage -Online -AllUsers -ErrorAction Stop | Out-Null
            } catch { $ok = $false; Write-StayGoneLog "FAILED to deprovision $($row.Name): $($_.Exception.Message)" }
        }
        if ($ok) {
            $removed += $row.Name
            Write-StayGoneLog "Removed $($row.Name) (trigger: $Trigger)"
            Add-StayGoneRemovedRecord -Row $row -Trigger $Trigger
        }
    }
    return $removed
}

function Add-StayGoneRemovedRecord {
    param([object]$Row, [string]$Trigger)
    $paths = Get-StayGonePaths
    $records = @()
    if (Test-Path $paths.State) {
        try { $records = @(Get-Content $paths.State -Raw | ConvertFrom-Json) } catch { $records = @() }
    }
    $records += [pscustomobject]@{
        Name = $Row.Name; PackageFamilyName = $Row.PackageFamilyName; Version = "$($Row.Version)"
        RemovedAt = (Get-Date -Format 's'); Trigger = $Trigger
    }
    ConvertTo-Json -InputObject @($records) -Depth 3 | Set-Content -Path $paths.State -Encoding UTF8
}

function Show-StayGoneNotification {
    <# Windows toast notification via the built-in WinRT API (no modules needed).
       Falls back silently if the notification system is unavailable. #>
    param([string]$Title, [string]$Text)
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $template.GetElementsByTagName('text')
        $null = $nodes.Item(0).AppendChild($template.CreateTextNode($Title))
        $null = $nodes.Item(1).AppendChild($template.CreateTextNode($Text))
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
            [Windows.UI.Notifications.ToastNotification]::new($template))
        return $true
    } catch {
        Write-StayGoneLog "Notification not shown: $($_.Exception.Message)"
        return $false
    }
}

function New-StayGoneTaskXml {
    <# Scheduled task definition: runs at sign-in (2 min delay) and whenever
       Windows Update logs a successful install (System log, event 19). #>
    param([string]$UserId, [string]$ScriptPath)
    $user = [Security.SecurityElement]::Escape($UserId)
    $arguments = [Security.SecurityElement]::Escape("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" run-watch")
    $query = [Security.SecurityElement]::Escape("<QueryList><Query Id=`"0`" Path=`"System`"><Select Path=`"System`">*[System[Provider[@Name='Microsoft-Windows-WindowsUpdateClient'] and EventID=19]]</Select></Query></QueryList>")
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>$($script:AppName)</Author>
    <Description>Re-removes blocklisted apps that Windows reinstalled. $($script:RepoUrl)</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled><UserId>$user</UserId><Delay>PT2M</Delay></LogonTrigger>
    <EventTrigger><Enabled>true</Enabled><Subscription>$query</Subscription><Delay>PT1M</Delay></EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author"><UserId>$user</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>powershell.exe</Command><Arguments>$arguments</Arguments></Exec>
  </Actions>
</Task>
"@
}

Export-ModuleMember -Function * -Variable AppName, AppVersion, Author, RepoUrl, TaskName
