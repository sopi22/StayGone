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
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'remove', 'watch-on', 'watch-off', 'status', 'restore', 'list', 'edit', 'log', 'about', 'help', 'run-watch')]
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

$paths = Initialize-StayGoneData -DefaultBlocklist $DefaultBlocklist

switch ($Command) {

    'check' {
        $admin = Test-StayGoneAdmin
        $state = Get-StayGoneSystemState -AllUsers:$admin
        $plan = @(Get-StayGonePlan -Patterns @(Get-StayGoneBlocklist) -Installed $state.Installed -Provisioned $state.Provisioned)
        if (-not $admin) {
            Write-Host "Not running as administrator: showing only YOUR apps, not other users' or the hidden copies." -ForegroundColor Yellow
        }
        Write-Plan $plan
        Write-Host "Blocklist: $($paths.Blocklist)"
    }

    'remove' {
        Assert-Admin 'remove'
        $state = Get-StayGoneSystemState -AllUsers
        $plan = @(Get-StayGonePlan -Patterns @(Get-StayGoneBlocklist) -Installed $state.Installed -Provisioned $state.Provisioned)
        Write-Plan $plan
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
        $plan = @(Get-StayGonePlan -Patterns @(Get-StayGoneBlocklist) -Installed $state.Installed -Provisioned $state.Provisioned)
        $removed = @(Invoke-StayGoneRemoval -Plan $plan -Trigger $trigger)
        Write-StayGoneLog "Watcher run ($trigger): $($removed.Count) removed"
        $note = Format-StayGoneNotification -Removed $removed -Trigger $trigger
        if ($note) { $null = Show-StayGoneNotification -Title $note.Title -Text $note.Text }
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
            Write-Host "Watcher: ON ($($task.State)). Last run: $($info.LastRunTime)  Result: $($info.LastTaskResult)" -ForegroundColor Green
        } else {
            Write-Host "Watcher: OFF. Turn it on with: .\StayGone.ps1 watch-on (as administrator)" -ForegroundColor Yellow
        }
        Write-Host "Blocklist: $(@(Get-StayGoneBlocklist).Count) entries in $($paths.Blocklist)"
        if (Test-Path $paths.State) {
            $n = @(Get-Content $paths.State -Raw | ConvertFrom-Json).Count
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
            $rec = @(Get-Content $paths.State -Raw | ConvertFrom-Json) | Where-Object { $_.Name -eq $Name -and $_.PackageFamilyName } | Select-Object -Last 1
            if ($rec) { $pfn = $rec.PackageFamilyName }
        }
        if ($pfn) {
            Write-Host "Opening its Microsoft Store page so you can reinstall it..."
            Start-Process "ms-windows-store://pdp/?PFN=$pfn"
        } else {
            Write-Host "To reinstall it, search for it in the Microsoft Store."
        }
    }

    'list' {
        $items = @(Get-StayGoneBlocklist)
        Write-Host "Blocklist ($($items.Count) entries) - $($paths.Blocklist)"
        $items | ForEach-Object { Write-Host "  $_" }
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
