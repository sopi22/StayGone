# Pester 5 tests for StayGone's decision logic. They use fake package data
# only: nothing here reads or changes the real system.
# Copyright (c) 2026 Jhoana Sophia C. Munar. MIT License.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\StayGone.psm1') -Force -DisableNameChecking

    function New-Pkg($Name) {
        [pscustomobject]@{ Name = $Name; PackageFamilyName = "$($Name)_8wekyb3d8bbwe"; Version = '1.0.0.0' }
    }
    function New-Prov($Name) {
        [pscustomobject]@{ DisplayName = $Name; PackageName = "$($Name)_1.0.0.0_neutral_~_8wekyb3d8bbwe"; Version = '1.0.0.0' }
    }
}

Describe 'ConvertFrom-BlocklistText' {
    It 'ignores blank lines and comments, keeps entries' {
        $lines = @('# header', '', 'Microsoft.GamingApp', '  Clipchamp.Clipchamp   # video editor', '# Microsoft.BingWeather')
        $result = ConvertFrom-BlocklistText -Lines $lines
        $result | Should -Be @('Microsoft.GamingApp', 'Clipchamp.Clipchamp')
    }
    It 'returns an empty list for an empty file' {
        @(ConvertFrom-BlocklistText -Lines @()).Count | Should -Be 0
    }
}

Describe 'Test-StayGoneProtected' {
    It 'protects <Name>' -ForEach @(
        @{ Name = 'Microsoft.WindowsStore' }
        @{ Name = 'Microsoft.DesktopAppInstaller' }
        @{ Name = 'Microsoft.SecHealthUI' }
        @{ Name = 'Microsoft.VCLibs.140.00' }
        @{ Name = 'Microsoft.UI.Xaml.2.8' }
        @{ Name = 'Microsoft.Windows.Photos' }
    ) {
        Test-StayGoneProtected -Name $Name | Should -BeTrue
    }
    It 'does not protect bloatware' {
        Test-StayGoneProtected -Name 'Microsoft.GamingApp' | Should -BeFalse
    }
}

Describe 'Get-StayGonePlan' {
    It 'plans removal for an installed blocklisted app' {
        $plan = @(Get-StayGonePlan -Patterns @('Microsoft.GamingApp') -Installed @(New-Pkg 'Microsoft.GamingApp'))
        $plan.Count | Should -Be 1
        $plan[0].Action | Should -Be 'Remove'
        $plan[0].Installed | Should -BeTrue
        $plan[0].Provisioned | Should -BeFalse
    }
    It 'catches the hidden provisioned copy even when the app is not installed' {
        # This is the case that makes apps come back after updates.
        $plan = @(Get-StayGonePlan -Patterns @('Clipchamp.Clipchamp') -Provisioned @(New-Prov 'Clipchamp.Clipchamp'))
        $plan.Count | Should -Be 1
        $plan[0].Installed | Should -BeFalse
        $plan[0].Provisioned | Should -BeTrue
        $plan[0].Action | Should -Be 'Remove'
    }
    It 'merges installed and provisioned copies of the same app into one row' {
        $plan = @(Get-StayGonePlan -Patterns @('Microsoft.BingNews') -Installed @(New-Pkg 'Microsoft.BingNews') -Provisioned @(New-Prov 'Microsoft.BingNews'))
        $plan.Count | Should -Be 1
        $plan[0].Installed | Should -BeTrue
        $plan[0].Provisioned | Should -BeTrue
    }
    It 'ignores apps that are not on the blocklist' {
        $plan = @(Get-StayGonePlan -Patterns @('Microsoft.GamingApp') -Installed @(New-Pkg 'Microsoft.WindowsCalculator'; New-Pkg 'Spotify'))
        $plan.Count | Should -Be 0
    }
    It 'supports wildcards' {
        $plan = @(Get-StayGonePlan -Patterns @('Microsoft.Xbox*') -Installed @(New-Pkg 'Microsoft.XboxApp'; New-Pkg 'Microsoft.Xbox.TCUI'; New-Pkg 'Microsoft.GamingApp'))
        @($plan.Name) | Should -Be @('Microsoft.Xbox.TCUI', 'Microsoft.XboxApp')
    }
    It 'never plans removal of a protected app, even if blocklisted or matched by a wildcard' {
        $plan = @(Get-StayGonePlan -Patterns @('Microsoft.*') -Installed @(New-Pkg 'Microsoft.WindowsStore'; New-Pkg 'Microsoft.GamingApp'))
        ($plan | Where-Object Name -eq 'Microsoft.WindowsStore').Action | Should -Be 'Protected'
        ($plan | Where-Object Name -eq 'Microsoft.GamingApp').Action | Should -Be 'Remove'
    }
    It 'returns an empty plan when nothing matches' {
        @(Get-StayGonePlan -Patterns @('Microsoft.GamingApp')).Count | Should -Be 0
    }
}

Describe 'Format-StayGoneNotification' {
    It 'returns nothing when no apps were removed' {
        Format-StayGoneNotification -Removed @() -Trigger 'update' | Should -BeNullOrEmpty
    }
    It 'names the app and the trigger' {
        $n = Format-StayGoneNotification -Removed @('Microsoft.GamingApp') -Trigger 'update'
        $n.Title | Should -Be 'StayGone removed 1 app after a Windows update'
        $n.Text | Should -Be 'GamingApp came back and was removed again.'
    }
    It 'uses plural wording for several apps' {
        $n = Format-StayGoneNotification -Removed @('Microsoft.GamingApp', 'Clipchamp.Clipchamp') -Trigger 'logon'
        $n.Title | Should -Be 'StayGone removed 2 apps at sign-in'
        $n.Text | Should -Match 'were removed again'
    }
}

Describe 'Set-BlocklistEntryRestored' {
    It 'comments out the matching line and keeps the others' {
        $r = Set-BlocklistEntryRestored -Lines @('Microsoft.GamingApp', 'Clipchamp.Clipchamp') -Name 'clipchamp.clipchamp' -Date '2026-10-31'
        $r.Changed | Should -BeTrue
        $r.Lines[0] | Should -Be 'Microsoft.GamingApp'
        $r.Lines[1] | Should -Be '# Clipchamp.Clipchamp    # restored 2026-10-31'
        @(ConvertFrom-BlocklistText -Lines $r.Lines) | Should -Be @('Microsoft.GamingApp')
    }
    It 'reports no change when the app is not listed' {
        (Set-BlocklistEntryRestored -Lines @('Microsoft.GamingApp') -Name 'Spotify' -Date '2026-10-31').Changed | Should -BeFalse
    }
}

Describe 'New-StayGoneTaskXml' {
    BeforeAll {
        $xml = [xml](New-StayGoneTaskXml -UserId 'PC\Sophia & Co' -ScriptPath 'C:\ProgramData\StayGone\app\StayGone.ps1')
        $ns = @{ t = 'http://schemas.microsoft.com/windows/2004/02/mit/task' }
    }
    It 'is valid XML with a sign-in trigger and a Windows Update event trigger' {
        (Select-Xml -Xml $xml -XPath '//t:LogonTrigger' -Namespace $ns) | Should -Not -BeNullOrEmpty
        $sub = (Select-Xml -Xml $xml -XPath '//t:EventTrigger/t:Subscription' -Namespace $ns).Node.InnerText
        $sub | Should -Match "Microsoft-Windows-WindowsUpdateClient"
        $sub | Should -Match 'EventID=19'
    }
    It 'escapes special characters in the user name' {
        (Select-Xml -Xml $xml -XPath '//t:Principal/t:UserId' -Namespace $ns).Node.InnerText | Should -Be 'PC\Sophia & Co'
    }
    It 'runs the watcher script elevated' {
        (Select-Xml -Xml $xml -XPath '//t:Principal/t:RunLevel' -Namespace $ns).Node.InnerText | Should -Be 'HighestAvailable'
        (Select-Xml -Xml $xml -XPath '//t:Exec/t:Arguments' -Namespace $ns).Node.InnerText | Should -Match 'run-watch$'
    }
}

Describe 'Select-LiveProvisioned' {
    It 'separates leftover records whose app folder is gone' {
        $live  = [pscustomobject]@{ DisplayName = 'Clipchamp.Clipchamp'; InstallLocation = 'C:\Program Files\WindowsApps\Clipchamp_1\AppxMetadata\AppxBundleManifest.xml' }
        $stale = [pscustomobject]@{ DisplayName = 'Microsoft.Getstarted'; InstallLocation = 'C:\Program Files\WindowsApps\Getstarted_1\AppxMetadata\AppxBundleManifest.xml' }
        $exists = { param($p) $p -like '*Clipchamp_1' }
        $r = Select-LiveProvisioned -Provisioned @($live, $stale) -PathExists $exists
        @($r.Live).DisplayName | Should -Be 'Clipchamp.Clipchamp'
        @($r.Stale).DisplayName | Should -Be 'Microsoft.Getstarted'
    }
    It 'checks the app folder, not the manifest file path' {
        $seen = [System.Collections.ArrayList]::new()
        $prov = [pscustomobject]@{ DisplayName = 'X'; InstallLocation = 'C:\WA\X_1\AppxMetadata\AppxBundleManifest.xml' }
        $null = Select-LiveProvisioned -Provisioned @($prov) -PathExists { param($p) $null = $seen.Add($p); $true }
        $seen[0] | Should -Be 'C:\WA\X_1'
    }
    It 'keeps entries with no install location as live' {
        $r = Select-LiveProvisioned -Provisioned @([pscustomobject]@{ DisplayName = 'Y'; InstallLocation = '' }) -PathExists { $false }
        @($r.Live).Count | Should -Be 1
    }
}


Describe 'Ask-first entries' {
    It 'parses a leading ? as "ask first"' {
        $e = @(ConvertFrom-BlocklistEntries -Lines @('Microsoft.GamingApp', '?MSTeams   # school term', '# ?Ignored'))
        $e.Count | Should -Be 2
        $e[0].Ask | Should -BeFalse
        $e[1].Pattern | Should -Be 'MSTeams'
        $e[1].Ask | Should -BeTrue
    }
    It 'still returns plain patterns for every entry' {
        @(ConvertFrom-BlocklistText -Lines @('?MSTeams', 'Clipchamp.Clipchamp')) | Should -Be @('MSTeams', 'Clipchamp.Clipchamp')
    }
    It 'marks ask-first apps as Ask in the plan, others as Remove' {
        $plan = @(Get-StayGonePlan -Patterns @('MSTeams', 'Clipchamp.Clipchamp') -AskPatterns @('MSTeams') -Installed @(New-Pkg 'MSTeams'; New-Pkg 'Clipchamp.Clipchamp'))
        ($plan | Where-Object Name -eq 'MSTeams').Action | Should -Be 'Ask'
        ($plan | Where-Object Name -eq 'Clipchamp.Clipchamp').Action | Should -Be 'Remove'
    }
    It 'keeps protection stronger than ask-first' {
        $plan = @(Get-StayGonePlan -Patterns @('Microsoft.WindowsStore') -AskPatterns @('Microsoft.WindowsStore') -Installed @(New-Pkg 'Microsoft.WindowsStore'))
        $plan[0].Action | Should -Be 'Protected'
    }
}

Describe 'Set-BlocklistEntryMode' {
    It 'switches one app to ask-first and keeps its comment' {
        $r = Set-BlocklistEntryMode -Lines @('Microsoft.GamingApp', 'MSTeams   # meetings') -Name 'msteams' -Ask
        $r.Changed | Should -Be 1
        $r.Lines[0] | Should -Be 'Microsoft.GamingApp'
        $r.Lines[1] | Should -Be '?MSTeams   # meetings'
    }
    It 'switches back to always-remove' {
        $r = Set-BlocklistEntryMode -Lines @('?MSTeams') -Name 'MSTeams'
        $r.Lines[0] | Should -Be 'MSTeams'
    }
    It 'switches every active entry with "all" and leaves comments alone' {
        $r = Set-BlocklistEntryMode -Lines @('# header', 'A', '?B', 'C') -Name 'all' -Ask
        $r.Changed | Should -Be 2
        $r.Lines | Should -Be @('# header', '?A', '?B', '?C')
    }
    It 'reports no change for an unknown app' {
        (Set-BlocklistEntryMode -Lines @('A') -Name 'Z' -Ask).Changed | Should -Be 0
    }
    It 'lets restore find an ask-first entry' {
        $r = Set-BlocklistEntryRestored -Lines @('?MSTeams') -Name 'MSTeams' -Date '2026-10-31'
        $r.Changed | Should -BeTrue
        $r.Lines[0] | Should -Be '# MSTeams    # restored 2026-10-31'
    }
}

Describe 'Format-StayGonePendingNotification' {
    It 'tells the user to run review' {
        $n = Format-StayGonePendingNotification -Pending @('MSTeams')
        $n.Title | Should -Match '1 app\(s\) came back'
        $n.Text | Should -Match 'review'
    }
    It 'returns nothing when nothing is pending' {
        Format-StayGonePendingNotification -Pending @() | Should -BeNullOrEmpty
    }
}

Describe 'Removal record (removed.json)' {
    It 'recovers every record from a file scrambled by v0.1.0' {
        $json = Get-Content (Join-Path $PSScriptRoot 'fixtures\removed-v0.1.0.json') -Raw
        $records = @(ConvertFrom-StayGoneRecordJson -Json $json)
        # Only 3 records survived the v0.1.0 bug inside the file itself...
        $records.Count | Should -Be 3
        ($records | Where-Object Name -eq 'MSTeams').PackageFamilyName | Should -Match '^MSTeams_'
    }
    It 'rebuilds the lost records from the log, without duplicates' {
        $json = Get-Content (Join-Path $PSScriptRoot 'fixtures\removed-v0.1.0.json') -Raw
        $log = Get-Content (Join-Path $PSScriptRoot 'fixtures\staygone-v0.1.0.log')
        $all = @(Merge-StayGoneLogRecords -Records @(ConvertFrom-StayGoneRecordJson -Json $json) -LogLines $log)
        # ...and the log has all 11 removals.
        $all.Count | Should -Be 11
        @($all.Name | Sort-Object -Unique).Count | Should -Be 11
        ($all | Where-Object Name -eq 'Clipchamp.Clipchamp').Trigger | Should -Be 'manual'
        ($all | Where-Object Name -eq 'MSTeams').PackageFamilyName | Should -Match '^MSTeams_'
    }
    It 'writes a plain array that reads back identically' {
        $in = @(
            [pscustomobject]@{ Name = 'A'; PackageFamilyName = 'A_x'; Version = '1'; RemovedAt = '2026-10-31T01:00:00'; Trigger = 'manual' }
            [pscustomobject]@{ Name = 'B'; PackageFamilyName = 'B_x'; Version = '2'; RemovedAt = '2026-10-31T02:00:00'; Trigger = 'update' }
        )
        $json = ConvertTo-StayGoneRecordJson -Records $in
        $json | Should -Not -Match '"value"'
        $out = @(ConvertFrom-StayGoneRecordJson -Json $json)
        $out.Count | Should -Be 2
        $out[1].Trigger | Should -Be 'update'
    }
    It 'handles a single record and an empty file' {
        @(ConvertFrom-StayGoneRecordJson -Json (ConvertTo-StayGoneRecordJson -Records @([pscustomobject]@{ Name = 'A' }))).Count | Should -Be 1
        @(ConvertFrom-StayGoneRecordJson -Json '').Count | Should -Be 0
    }
}
