<#
.SYNOPSIS
    StayGone - keeps removed Windows bloatware gone.

.DESCRIPTION
    Removes the apps on your blocklist for all users (including the hidden
    "provisioned" copy Windows uses to reinstall them), and can install a
    watcher that does it again automatically after every Windows update and
    at sign-in.

    Copyright (c) 2026 Jhoana Sophia C. Munar. MIT License.
    https://github.com/sopi22/StayGone

.EXAMPLE
    .\StayGone.ps1 check            # read-only: what's on the blocklist and installed
    .\StayGone.ps1 remove -WhatIf   # show what would be removed, change nothing
    .\StayGone.ps1 remove           # remove now (run as administrator)
    .\StayGone.ps1 watch-on         # install the automatic watcher (administrator)
    .\StayGone.ps1 ask MSTeams      # let me choose before Teams is removed
    .\StayGone.ps1 review           # pick which blocklisted apps to remove now
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'remove', 'review', 'ask', 'always', 'watch-on', 'watch-off', 'status', 'restore', 'list', 'edit', 'log', 'about', 'help', 'run-watch')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Name,

    [int]$Tail = 20
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\StayGone.psm1') -Force -DisableNameChecking
$DefaultBlocklist = Join-Path $PSScriptRoot 'config\blocklist.default.txt'

function Assert-Admin([string]$What) {
    if (-not (Test-StayGoneAdmin)) {
        Write-Host "'$What' needs administrator rights." -ForegroundColor Yellow
        Write-Host "Open PowerShell with 'Run as administrator', then run the same command again."
        exit 2
    }
}

function Write-Plan([object[]]$Plan) {
    if ($Plan.Count -eq 0) {
        Write-Host "Nothing from your blocklist is installed. All clear." -ForegroundColor Green
        return
    }
    $Plan | Select-Object Name,
        @{ n = 'Installed'; e = { if ($_.Installed) { 'yes' } else { 'no' } } },
        @{ n = 'HiddenCopy'; e = { if ($_.Provisioned) { 'yes' } else { 'no' } } },
        Action | Format-Table -AutoSize | Out-Host
    $protected = @($Plan | Where-Object Action -eq 'Protected')
    if ($protected.Count) {
        Write-Host "Protected apps are never removed, even if listed: $(($protected.Name) -join ', ')" -ForegroundColor Yellow
    }
}

function Get-Plan($State) {
    $entries = @(Get-StayGoneBlocklist)
    $all = @($entries | ForEach-Object { $_.Pattern })
    $ask = @($entries | Where-Object Ask | ForEach-Object { $_.Pattern })
    return @(Get-StayGonePlan -Patterns $all -AskPatterns $ask -Installed $State.Installed -Provisioned $State.Provisioned)
}

function Select-AppsToRemove([object[]]$Rows, [string]$Title) {
    # Small selection window (built into Windows PowerShell). Returns the
    # chosen names, an empty list if the user chose none, or $null if no
    # window could be shown (e.g. no one is signed in).
    if ($Rows.Count -eq 0) { return @() }
    try {
        $view = $Rows | Select-Object @{ n = 'App'; e = { $_.Name } },
            @{ n = 'Installed'; e = { if ($_.Installed) { 'yes' } else { 'no' } } },
            @{ n = 'Mode'; e = { if ($_.Action -eq 'Ask') { 'ask first' } else { 'always remove' } } }
        return @($view | Out-GridView -Title $Title -OutputMode Multiple -ErrorAction Stop | ForEach-Object { $_.App })
    } catch {
        Write-StayGoneLog "Selection window not available: $($_.Exception.Message)"
        return $null
    }
}

function Set-Mode([string]$App, [bool]$Ask) {
    if (-not $App) { Write-Host "Usage: .\StayGone.ps1 $(if ($Ask) {'ask'} else {'always'}) <AppName|all>"; exit 1 }
    $r = Set-BlocklistEntryMode -Lines (Get-Content $paths.Blocklist) -Name $App -Ask:$Ask
    if ($r.Changed) {
        Set-Content -Path $paths.Blocklist -Value $r.Lines -Encoding UTF8
        $mode = if ($Ask) { 'ask first' } else { 'always remove' }
        Write-StayGoneLog "Mode set to '$mode' for $App ($($r.Changed) entries)"
        Write-Host "$App -> $mode ($($r.Changed) entr$(if ($r.Changed -eq 1) {'y'} else {'ies'}) changed)." -ForegroundColor Green
    } else {
        Write-Host "No change: '$App' isn't an active blocklist entry, or it's already set that way."
    }
}

function Write-StaleNote($State) {
    $patterns = @(Get-StayGoneBlocklist | ForEach-Object { $_.Pattern })
    $n = @($State.Stale | Where-Object { Test-StayGoneMatch -Name $_.DisplayName -Patterns $patterns }).Count
    if ($n) { Write-Host "Ignored $n leftover record(s) of blocklisted apps whose files are already gone (harmless)." -ForegroundColor DarkGray }
}

$paths = Initialize-StayGoneData -DefaultBlocklist $DefaultBlocklist

switch ($Command) {

    'check' {
        $admin = Test-StayGoneAdmin
        $state = Get-StayGoneSystemState -AllUsers:$admin
        $plan = Get-Plan $state
        if (-not $admin) {
            Write-Host "Not running as administrator: showing only YOUR apps, not other users' or the hidden copies." -ForegroundColor Yellow
        }
        Write-Plan $plan
        Write-StaleNote $state
        Write-Host "Blocklist: $($paths.Blocklist)"
    }

    'remove' {
        Assert-Admin 'remove'
        $state = Get-StayGoneSystemState -AllUsers
        $plan = Get-Plan $state
        Write-Plan $plan
        Write-StaleNote $state
        $askRows = @($plan | Where-Object Action -eq 'Ask')
        if ($askRows.Count -and -not $WhatIfPreference) {
            $chosen = Select-AppsToRemove $askRows 'StayGone - these apps are set to "ask first". Select the ones to remove (Ctrl+click for several), then OK'
            if ($null -eq $chosen) { Write-Host "Skipped 'ask first' apps (no selection window). Use 'review' to choose." -ForegroundColor Yellow }
            else { foreach ($row in $askRows) { if ($chosen -contains $row.Name) { $row.Action = 'Remove' } } }
        } elseif ($askRows.Count) {
            Write-Host "'Ask first' apps would open a selection window: $(($askRows.Name) -join ', ')" -ForegroundColor Cyan
        }
        $removed = @(Invoke-StayGoneRemoval -Plan $plan -Trigger 'manual' -WhatIf:$WhatIfPreference)
        if ($WhatIfPreference) { Write-Host "WhatIf: nothing was changed." -ForegroundColor Cyan }
        elseif ($removed.Count) { Write-Host "Removed: $($removed -join ', ')" -ForegroundColor Green }
        else { Write-Host "Nothing removed." }
    }

    'run-watch' {
        # Called by the scheduled task. Trigger is a guess from recent update events.
        Assert-Admin 'run-watch'
        $trigger = 'logon'
        try {
            $recent = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19; StartTime = (Get-Date).AddMinutes(-15) } -MaxEvents 1 -ErrorAction Stop
            if ($recent) { $trigger = 'update' }
        } catch { }
        $state = Get-StayGoneSystemState -AllUsers
        $plan = Get-Plan $state
        $askRows = @($plan | Where-Object Action -eq 'Ask')
        $pending = @()
        if ($askRows.Count) {
            $when = if ($trigger -eq 'update') { 'after a Windows update' } else { 'since you last signed in' }
            $chosen = Select-AppsToRemove $askRows "StayGone - these apps came back $when. Select the ones to REMOVE (Ctrl+click for several). Unselected apps stay."
            if ($null -eq $chosen) { $pending = @($askRows.Name) }
            else {
                foreach ($row in $askRows) {
                    if ($chosen -contains $row.Name) { $row.Action = 'Remove' } else { Write-StayGoneLog "Kept $($row.Name) this time (your choice)" }
                }
            }
        }
        $removed = @(Invoke-StayGoneRemoval -Plan $plan -Trigger $trigger)
        Write-StayGoneLog "Watcher run ($trigger): $($removed.Count) removed, $($pending.Count) waiting for your choice"
        $note = Format-StayGoneNotification -Removed $removed -Trigger $trigger
        if ($note) { $null = Show-StayGoneNotification -Title $note.Title -Text $note.Text }
        $wait = Format-StayGonePendingNotification -Pending $pending
        if ($wait) { $null = Show-StayGoneNotification -Title $wait.Title -Text $wait.Text }
    }

    'review' {
        # Pick exactly which blocklisted apps to remove right now.
        Assert-Admin 'review'
        $state = Get-StayGoneSystemState -AllUsers
        $rows = @(Get-Plan $state | Where-Object { $_.Action -ne 'Protected' })
        if ($rows.Count -eq 0) { Write-Host "Nothing from your blocklist is installed. All clear." -ForegroundColor Green; break }
        $chosen = Select-AppsToRemove $rows 'StayGone - select the apps to remove now (Ctrl+click for several), then OK. Unselected apps stay.'
        if ($null -eq $chosen) { Write-Host "Couldn't open the selection window." -ForegroundColor Yellow; exit 1 }
        foreach ($row in $rows) { if ($chosen -contains $row.Name) { $row.Action = 'Remove' } else { $row.Action = 'Keep' } }
        $removed = @(Invoke-StayGoneRemoval -Plan $rows -Trigger 'review' -WhatIf:$WhatIfPreference)
        if ($removed.Count) { Write-Host "Removed: $($removed -join ', ')" -ForegroundColor Green } else { Write-Host "Nothing removed." }
    }

    'ask'    { Set-Mode $Name $true }

    'always' { Set-Mode $Name $false
    }

    'watch-on' {
        Assert-Admin 'watch-on'
        # The task runs a copy kept in ProgramData, so it keeps working even if
        # this folder is moved or deleted.
        New-Item -ItemType Directory -Path (Join-Path $paths.AppDir 'src') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $paths.AppDir 'config') -Force | Out-Null
        Copy-Item (Join-Path $PSScriptRoot 'StayGone.ps1') $paths.AppDir -Force
        Copy-Item (Join-Path $PSScriptRoot 'src\StayGone.psm1') (Join-Path $paths.AppDir 'src') -Force
        Copy-Item $DefaultBlocklist (Join-Path $paths.AppDir 'config') -Force
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $xml = New-StayGoneTaskXml -UserId $user -ScriptPath (Join-Path $paths.AppDir 'StayGone.ps1')
        Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null
        Write-StayGoneLog "Watcher installed for $user"
        Write-Host "Watcher is ON. It runs 2 minutes after you sign in and after every successful Windows update." -ForegroundColor Green
        Write-Host "Log: $($paths.Log)"
    }

    'watch-off' {
        Assert-Admin 'watch-off'
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-StayGoneLog 'Watcher removed'
            Write-Host "Watcher is OFF. Your blocklist and log are kept in $($paths.DataDir)." -ForegroundColor Green
        } else {
            Write-Host "The watcher wasn't installed."
        }
    }

    'status' {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) {
            $info = $task | Get-ScheduledTaskInfo
            # Windows reports a never-run task as year 1999 / code 267011.
            if ($info.LastRunTime.Year -lt 2000 -or $info.LastTaskResult -eq 267011) { $last = 'not yet (it runs after your next sign-in or Windows update)' }
            elseif ($info.LastTaskResult -eq 0) { $last = "$($info.LastRunTime) - finished OK" }
            else { $last = "$($info.LastRunTime) - ended with code $($info.LastTaskResult) (see: .\StayGone.ps1 log)" }
            Write-Host "Watcher: ON. Last run: $last" -ForegroundColor Green
        } else {
            Write-Host "Watcher: OFF. Turn it on with: .\StayGone.ps1 watch-on (as administrator)" -ForegroundColor Yellow
        }
        $entries = @(Get-StayGoneBlocklist)
        Write-Host "Blocklist: $($entries.Count) entries ($(@($entries | Where-Object Ask).Count) set to 'ask first') in $($paths.Blocklist)"
        if (Test-Path $paths.State) {
            $n = @(Get-StayGoneRemovedRecords).Count
            Write-Host "Removals recorded so far: $n"
        }
    }

    'restore' {
        if (-not $Name) { Write-Host "Usage: .\StayGone.ps1 restore <AppName>   e.g. restore Microsoft.BingWeather"; exit 1 }
        $result = Set-BlocklistEntryRestored -Lines (Get-Content $paths.Blocklist) -Name $Name -Date (Get-Date -Format 'yyyy-MM-dd')
        if ($result.Changed) {
            Set-Content -Path $paths.Blocklist -Value $result.Lines -Encoding UTF8
            Write-StayGoneLog "Restored $Name (taken off the blocklist)"
            Write-Host "$Name is off the blocklist, so StayGone won't remove it again." -ForegroundColor Green
        } else {
            Write-Host "$Name wasn't an active line in your blocklist."
        }
        $pfn = ''
        if (Test-Path $paths.State) {
            $rec = @(Get-StayGoneRemovedRecords) | Where-Object { $_.Name -eq $Name -and $_.PackageFamilyName } | Select-Object -Last 1
            if ($rec) { $pfn = $rec.PackageFamilyName }
        }
        if ($pfn) {
            Write-Host "Opening its Microsoft Store page so you can reinstall it..."
            Start-Process "ms-windows-store://pdp/?PFN=$pfn"
        } elseif ($result.Changed) {
            Write-Host "StayGone has no record of removing it, so if it's still installed there's nothing to reinstall."
            Write-Host "If it is missing, search for it in the Microsoft Store."
        }
    }

    'list' {
        $items = @(Get-StayGoneBlocklist)
        Write-Host "Blocklist ($($items.Count) entries) - $($paths.Blocklist)"
        $items | ForEach-Object { if ($_.Ask) { Write-Host "  $($_.Pattern)   (ask first)" -ForegroundColor Cyan } else { Write-Host "  $($_.Pattern)" } }
    }

    'edit' { Start-Process notepad.exe $paths.Blocklist }

    'log' {
        if (Test-Path $paths.Log) { Get-Content $paths.Log -Tail $Tail } else { Write-Host "No log yet." }
    }

    'about' {
        Write-Host "$AppName $AppVersion"
        Write-Host "Developed by $Author"
        Write-Host $RepoUrl
        Write-Host "MIT License. No telemetry, no network access."
    }

    default {
        Write-Host @"
$AppName $AppVersion - keeps removed Windows bloatware gone.

  check              Show which blocklisted apps are installed (read-only)
  remove [-WhatIf]   Remove them now for all users, incl. hidden copies  (admin)
  review             Pick exactly which blocklisted apps to remove now    (admin)
  ask <App|all>      Ask before removing this app (e.g. ask MSTeams)
  always <App|all>   Remove this app automatically again
  watch-on           Re-remove automatically after updates and at sign-in (admin)
  watch-off          Turn the automatic watcher off                       (admin)
  status             Is the watcher on? When did it last run?
  restore <App>      Take an app off the blocklist and open its Store page
  list / edit        Show / edit your blocklist
  log [-Tail N]      Show what StayGone did
  about              Version and author
"@
    }
}
