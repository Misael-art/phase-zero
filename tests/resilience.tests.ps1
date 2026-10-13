$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

Describe 'Resilience Architecture' {
    BeforeAll {
        . $scriptPath -BootstrapUiLibraryMode
    }

    Context 'Disk Space Check' {
        It 'Get-BootstrapFreeSpace returns a number' {
            $space = Get-BootstrapFreeSpace -Path 'C:\'
            $space | Should BeGreaterThan -1
        }

        It 'Test-BootstrapDiskSpace logs warnings if space is low (Mocked)' {
            Mock Get-BootstrapFreeSpace { return 0.5 } # 0.5 GB
            Mock Write-Log

            $selection = @{ Profiles = @('full') }
            $components = @('c1', 'c2')

            try {
                Test-BootstrapDiskSpace -Selection $selection -ResolvedComponents $components -ResolvedWorkspaceRoot 'C:\'
            } catch { }

            Assert-MockCalled Write-Log -ParameterFilter { $Message -match 'Espaco em disco insuficiente' -and $Level -eq 'WARN' }
        }

        It 'Test-BootstrapDiskSpace does not block config-only AppTuning on a tight system drive' {
            Mock Get-BootstrapFreeSpace { return 0.5 } # 0.5 GB
            Mock Write-Log

            $selection = @{
                Profiles = @()
                Components = @()
                AppTuningItems = @('agent-config-claude-rtk-template')
                AppTuningCategories = @()
            }

            { Test-BootstrapDiskSpace -Selection $selection -ResolvedComponents @() -ResolvedWorkspaceRoot '' } | Should Not Throw
        }

        It 'Assert-BootstrapDiskSpace throws if space is low' {
            Mock Get-BootstrapFreeSpace { return 0.5 } # 0.5 GB
            { Assert-BootstrapDiskSpace -RequiredGB 1.0 } | Should Throw 'Espaco em disco insuficiente'
        }

        It 'Assert-BootstrapDiskSpace passes if space is enough' {
            Mock Get-BootstrapFreeSpace { return 5.0 }
            { Assert-BootstrapDiskSpace -RequiredGB 1.0 } | Should Not Throw
        }
    }

    Context 'Checkpoint & Resume' {
        It 'Save and Load checkpoint' {
            $selection = @{ Profiles = @('base'); Components = @() }
            $completed = @('system-core', 'git-core')
            $tuning = @(@{ id = 'test-tune'; status = 'applied' })

            Save-BootstrapCheckpoint -Selection $selection -CompletedComponents $completed -AppTuningResults $tuning

            $loaded = Load-BootstrapCheckpoint
            $loaded.ProfileSelection | Should Be @('base')
            $loaded.CompletedComponents | Should Be @('system-core', 'git-core')
            $loaded.AppTuningResults[0].id | Should Be 'test-tune'

            # Cleanup
            Remove-Item (Get-BootstrapCheckpointPath) -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'Offline Mode & Cache' {
        It 'Invoke-WebRequestWithRetry uses cache if available' {
            $tempDir = Join-Path $env:TEMP ('bootstrap-test-' + ([Guid]::NewGuid().ToString()))
            $null = New-Item -Path $tempDir -ItemType Directory -Force
            $cacheDir = Join-Path $tempDir 'cache'
            $null = New-Item -Path $cacheDir -ItemType Directory -Force

            $script:CacheDir = $cacheDir
            $Global:BootstrapOfflineOverride = $true

            $testFile = Join-Path $cacheDir 'out.txt'
            [System.IO.File]::WriteAllText($testFile, 'hello', [System.Text.UTF8Encoding]::new($false))
            Mock Copy-Item {
                param([string]$Path, [string]$Destination, [switch]$Force)
                [System.IO.File]::Copy($Path, $Destination, $true) | Out-Null
            }

            $outFile = Join-Path $tempDir 'out.txt'

            # Should NOT throw because it's in cache
            Invoke-WebRequestWithRetry -Uri 'http://dummy' -OutFile $outFile

            Get-Content $outFile | Should Be 'hello'

            # Should throw if NOT in cache
            { Invoke-WebRequestWithRetry -Uri 'http://dummy2' -OutFile (Join-Path $tempDir 'missing.txt') } | Should Throw 'Modo OFFLINE'

            # Cleanup
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            $script:CacheDir = ''
            Remove-Variable -Name 'BootstrapOfflineOverride' -Scope Global -ErrorAction SilentlyContinue
        }
    }

    Context 'Rollback' {
        It 'restores an existing file from a registered rollback backup' {
            $tempDir = Join-Path $env:TEMP ('bootstrap-file-rollback-test-' + ([Guid]::NewGuid().ToString()))
            $null = New-Item -Path $tempDir -ItemType Directory -Force
            try {
                $target = Join-Path $tempDir 'config.json'
                [System.IO.File]::WriteAllText($target, 'before', [System.Text.UTF8Encoding]::new($false))
                $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot $tempDir -ResolvedCloneBaseDir $tempDir
                $state.ChangeManifestPath = Join-Path $tempDir 'changes.json'

                Register-BootstrapFileChange -State $state -Target $target -Operation 'test-file-update' -Component 'test'
                [System.IO.File]::WriteAllText($target, 'after', [System.Text.UTF8Encoding]::new($false))
                Invoke-BootstrapRollback -ChangesPath $state.ChangeManifestPath | Out-Null

                [string](Get-Content -LiteralPath $target -Raw) | Should Be 'before'
            } finally {
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Registers changes and rolls them back' {
            $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\' -ResolvedCloneBaseDir 'C:\'
            Mock Remove-ItemProperty
            Mock Set-ItemProperty
            Mock Write-Log

            Register-BootstrapChange -State $state -Type 'Registry' -Target 'HKCU:\Test' -Name 'MyKey' -OldValue $null
            Register-BootstrapChange -State $state -Type 'Registry' -Target 'HKCU:\Test2' -Name 'MyKey2' -OldValue 'prev'

            $state.Changes.Count | Should Be 2

            Invoke-BootstrapAutoRollback -State $state

            Assert-MockCalled Remove-ItemProperty -ParameterFilter { $Path -eq 'HKCU:\Test' -and $Name -eq 'MyKey' }
            Assert-MockCalled Set-ItemProperty -ParameterFilter { $Path -eq 'HKCU:\Test2' -and $Name -eq 'MyKey2' -and $Value -eq 'prev' }
        }

        It 'writes a change manifest with auditable rollback metadata' {
            $tempDir = Join-Path $env:TEMP ('bootstrap-manifest-test-' + ([Guid]::NewGuid().ToString()))
            $null = New-Item -Path $tempDir -ItemType Directory -Force
            try {
                $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\' -ResolvedCloneBaseDir 'C:\'
                $state.ChangeManifestPath = Join-Path $tempDir 'changes.json'
                $state.CurrentComponent = 'test-component'

                Register-BootstrapChange -State $state -Type 'EnvVar' -Target 'PHASEZERO_TEST' -OldValue 'old' -NewValue 'new'

                Test-Path $state.ChangeManifestPath | Should Be $true
                $manifest = Get-Content -Path $state.ChangeManifestPath -Raw | ConvertFrom-Json
                $manifest.summary.total | Should Be 1
                $manifest.changes[0].Component | Should Be 'test-component'
                $manifest.changes[0].RollbackAction | Should Be 'restore-env-var'
            } finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'rolls back registry values from a manifest before legacy fallback' {
            $tempDir = Join-Path $env:TEMP ('bootstrap-rollback-test-' + ([Guid]::NewGuid().ToString()))
            $null = New-Item -Path $tempDir -ItemType Directory -Force
            $manifestPath = Join-Path $tempDir 'changes.json'
            try {
                $manifest = [ordered]@{
                    changes = @(
                        [ordered]@{ Type = 'Registry'; Target = 'HKCU:\PhaseZeroTest'; Name = 'Value'; OldValue = 'old'; Reversible = 'partial' }
                    )
                }
                [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
                Mock Set-ItemProperty
                Mock Write-Log

                Invoke-BootstrapRollback -ChangesPath $manifestPath

                Assert-MockCalled Set-ItemProperty -ParameterFilter { $Path -eq 'HKCU:\PhaseZeroTest' -and $Name -eq 'Value' -and $Value -eq 'old' }
            } finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'plans rollback from a manifest in dry-run without mutating system state' {
            $tempDir = Join-Path $env:TEMP ('bootstrap-rollback-dryrun-test-' + ([Guid]::NewGuid().ToString()))
            $null = New-Item -Path $tempDir -ItemType Directory -Force
            $manifestPath = Join-Path $tempDir 'changes.json'
            try {
                $manifest = [ordered]@{
                    changes = @(
                        [ordered]@{ Type = 'EnvVar'; Target = 'PHASEZERO_ROLLBACK_DRYRUN'; Name = ''; OldValue = 'old'; NewValue = 'new'; Reversible = 'partial' },
                        [ordered]@{ Type = 'Package'; Target = 'Example.Tool'; Name = ''; OldValue = $null; NewValue = 'installed'; RollbackAction = 'winget-uninstall'; Reversible = 'manual' }
                    )
                }
                [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
                Mock Get-Winget { 'winget.exe' }
                Mock Invoke-NativeWithLog { 0 }
                Mock Write-Log

                $result = Invoke-BootstrapRollback -ChangesPath $manifestPath -DryRun

                $result.dryRun | Should Be $true
                $result.status | Should Be 'planned'
                @($result.plannedActions).Count | Should Be 2
                Assert-MockCalled Invoke-NativeWithLog -Times 0
            } finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'rolls back service and Defender exclusion changes from a manifest' {
            $tempDir = Join-Path $env:TEMP ('bootstrap-rollback-service-defender-test-' + ([Guid]::NewGuid().ToString()))
            $null = New-Item -Path $tempDir -ItemType Directory -Force
            $manifestPath = Join-Path $tempDir 'changes.json'
            try {
                $manifest = [ordered]@{
                    changes = @(
                        [ordered]@{ Type = 'DefenderExclusion'; Target = 'C:\PhaseZero'; Name = 'ExclusionPath'; OldValue = $null; NewValue = 'C:\PhaseZero'; Reversible = 'partial' },
                        [ordered]@{ Type = 'Service'; Target = 'DiagTrack'; Name = 'StartupType'; OldValue = [ordered]@{ StartType = 'Manual'; Status = 'Running' }; NewValue = 'Disabled'; Reversible = 'partial' }
                    )
                }
                [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
                Mock Set-Service
                Mock Start-Service
                Mock Remove-MpPreference
                Mock Write-Log

                Invoke-BootstrapRollback -ChangesPath $manifestPath

                Assert-MockCalled Remove-MpPreference -ParameterFilter { $ExclusionPath -eq 'C:\PhaseZero' } -Times 1
                Assert-MockCalled Set-Service -ParameterFilter { $Name -eq 'DiagTrack' -and $StartupType -eq 'Manual' } -Times 1
                Assert-MockCalled Start-Service -ParameterFilter { $Name -eq 'DiagTrack' } -Times 1
            } finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Reversibility Contract' {
        It 'infers package and manual reversibility metadata' {
            $winget = [pscustomobject]@{ Kind = 'winget'; Name = 'git-core' }
            $manual = [pscustomobject]@{ Kind = 'manual-required'; Name = 'steamdeck-manual' }

            (@((Get-BootstrapComponentReversibility -ComponentDef $winget).changeTypes) -contains 'package') | Should Be $true
            (Get-BootstrapComponentReversibility -ComponentDef $manual).reversible | Should Be 'none'
        }
    }

    Context 'Audit & Repair' {
        It 'Invoke-BootstrapAuditMode performs repair' {
            $catalog = @{
                'broken-comp' = [pscustomobject]@{
                    Name = 'broken-comp'
                    Description = 'Broken test component'
                    Kind = 'test'
                    DependsOn = @()
                    Data = @{ CommandName = 'non-existent-cmd' }
                    VersionCheckCommand = ''
                }
            }
            $resolution = @{
                ResolvedComponents = @('broken-comp')
                Catalog = $catalog
            }
            $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\' -ResolvedCloneBaseDir 'C:\'

            Mock Get-BootstrapComponentCatalog { $catalog }
            Mock Invoke-BootstrapComponent {
                param($Name, $State)
                $State.Completed[$Name] = @{ Status = 'Repaired' }
            }

            $results = Invoke-BootstrapAuditMode -Resolution $resolution -State $state -Repair
            $results[0].Status | Should Be 'Repaired'
            Assert-MockCalled Invoke-BootstrapComponent
        }

        It 'maps legacy audit statuses into actionable severities' {
            $optionalDef = [pscustomobject]@{ Optional = $true }
            $requiredDef = [pscustomobject]@{ Optional = $false }

            (Convert-BootstrapAuditStatusToSeverity -Status 'Healthy' -ComponentDef $requiredDef).Severity | Should Be 'Ready'
            (Convert-BootstrapAuditStatusToSeverity -Status 'Missing' -ComponentDef $requiredDef).Severity | Should Be 'NeedsInstall'
            (Convert-BootstrapAuditStatusToSeverity -Status 'Missing' -ComponentDef $optionalDef).Severity | Should Be 'OptionalMissing'
            (Convert-BootstrapAuditStatusToSeverity -Status 'GhostInstall' -ComponentDef $requiredDef).Severity | Should Be 'NeedsRepair'
            (Convert-BootstrapAuditStatusToSeverity -Status 'RequiresRestart' -ComponentDef $requiredDef).Severity | Should Be 'RequiresRestart'
            (Convert-BootstrapAuditStatusToSeverity -Status 'Skipped' -ComponentDef $requiredDef).Severity | Should Be 'UnsupportedAudit'
            (Convert-BootstrapAuditStatusToSeverity -Status 'Unknown' -ComponentDef $requiredDef).Critical | Should Be $false
        }

        It 'summarizes audit by severity and excludes UnsupportedAudit from critical count' {
            $rows = @(
                [pscustomobject]@{ Severity = 'Ready' },
                [pscustomobject]@{ Severity = 'NeedsInstall' },
                [pscustomobject]@{ Severity = 'UnsupportedAudit' }
            )

            $summary = New-BootstrapAuditSeveritySummary -Rows $rows

            [int]$summary.total | Should Be 3
            [int]$summary.Ready | Should Be 1
            [int]$summary.NeedsInstall | Should Be 1
            [int]$summary.UnsupportedAudit | Should Be 1
            [int]$summary.critical | Should Be 1
        }

        It 'summarizes audit duration and timeout counts' {
            $rows = @(
                [pscustomobject]@{ Severity = 'Ready'; DurationMs = 12; TimedOut = $false },
                [pscustomobject]@{ Severity = 'UnsupportedAudit'; DurationMs = 38; TimedOut = $true }
            )

            $summary = New-BootstrapAuditSeveritySummary -Rows $rows

            [int]$summary.durationMs | Should Be 50
            [int]$summary.timedOut | Should Be 1
        }

        It 'adds audit timing metadata to rows' {
            $row = New-BootstrapAuditRow -Component 'slow-winget' -Status 'Unknown' -Detail 'winget timeout' -DurationMs 42 -TimedOut $true -ProbeSource 'winget-list-id'

            [int]$row.DurationMs | Should Be 42
            [bool]$row.TimedOut | Should Be $true
            [string]$row.ProbeSource | Should Be 'winget-list-id'
        }

        It 'uses the short audit winget probe for generic winget fallback' {
            $catalog = @{
                'slow-winget' = [pscustomobject]@{
                    Name = 'slow-winget'
                    Description = 'Slow winget component'
                    Kind = 'winget'
                    DependsOn = @()
                    Optional = $false
                    Id = 'Example.Slow'
                    ProbePaths = @()
                    VersionCheckCommand = ''
                }
            }
            $resolution = @{
                ResolvedComponents = @('slow-winget')
                Catalog = $catalog
            }

            Mock Get-BootstrapComponentCatalog { $catalog }
            Mock Get-Winget { return 'winget.exe' }
            Mock Test-WingetPackageInstalled { throw '120s fallback should not be used by audit' }
            Mock Invoke-WingetListIdProbe {
                return @{ stdout = ''; stderr = 'timeout'; exitCode = 124; timedOut = $true }
            }

            $results = Invoke-BootstrapAuditMode -Resolution $resolution -ComponentTimeoutSeconds 1

            [string]$results[0].Component | Should Be 'slow-winget'
            [string]$results[0].Status | Should Be 'Unknown'
            [bool]$results[0].TimedOut | Should Be $true
            [string]$results[0].ProbeSource | Should Be 'winget-list-id'
            Assert-MockCalled Test-WingetPackageInstalled -Times 0 -Scope It
            Assert-MockCalled Invoke-WingetListIdProbe -Scope It -ParameterFilter { $Id -eq 'Example.Slow' -and $TimeoutMs -le 8000 }
        }

        It 'Java JDK audit rejects java runtime without javac' {
            Mock Resolve-CommandPath {
                param([string]$Name)
                if ($Name -eq 'java') { return (Join-Path $env:SystemRoot 'System32\cmd.exe') }
                return $null
            }
            Mock Get-AuditFirstExistingPathGlobal { return '' }
            Mock Test-AuditWingetInstalledGlobal { return $false }

            $row = Get-BootstrapJavaJdkAuditRow -ComponentName 'java-core'

            [string]$row.Status | Should Not Be 'Healthy'
            [string]$row.Severity | Should Be 'NeedsInstall'
            [string]$row.Detail | Should Match 'javac'
        }

        It 'audits npm components with declared commands instead of UnsupportedAudit' {
            $catalog = @{
                'npm-tool' = New-BootstrapComponentDefinition -Name 'npm-tool' -Description 'npm tool' -Kind 'npm' -Data @{ Package = 'pkg'; DisplayName = 'Pkg'; CommandNames = @('pkgcmd') }
            }
            $resolution = @{ ResolvedComponents = @('npm-tool') }
            Mock Get-BootstrapComponentCatalog { $catalog }
            Mock Get-Winget { return $null }
            Mock Resolve-CommandPath {
                param([string]$Name)
                if ($Name -eq 'pkgcmd') { return 'C:\Tools\pkgcmd.cmd' }
                return $null
            }

            $rows = @(Invoke-BootstrapAuditMode -Resolution $resolution)

            [string]$rows[0].Status | Should Be 'Healthy'
            [string]$rows[0].Severity | Should Be 'Ready'
            [string]$rows[0].Detail | Should Match 'pkgcmd'
        }

        It 'audits repo-clone target folders instead of UnsupportedAudit' {
            $root = Join-Path $env:TEMP ('phasezero-audit-repo-' + [guid]::NewGuid().ToString('N'))
            try {
                $target = Join-Path $root 'gemini-cli'
                New-Item -ItemType Directory -Path (Join-Path $target '.git') -Force | Out-Null
                $catalog = @{
                    'repo-test' = New-BootstrapComponentDefinition -Name 'repo-test' -Description 'repo test' -Kind 'repo-clone' -Data @{ RepoUrl = 'https://example.invalid/repo.git'; TargetName = 'gemini-cli' }
                }
                $resolution = @{ ResolvedComponents = @('repo-test') }
                $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot $root -ResolvedCloneBaseDir $root
                Mock Get-BootstrapComponentCatalog { $catalog }
                Mock Get-Winget { return $null }

                $rows = @(Invoke-BootstrapAuditMode -Resolution $resolution -State $state)

                [string]$rows[0].Status | Should Be 'Healthy'
                [string]$rows[0].Severity | Should Be 'Ready'
                [string]$rows[0].Detail | Should Match 'gemini-cli'
            } finally {
                if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'audits manual-required optional components as OptionalMissing with action text' {
            $catalog = @{
                'manual-test' = New-BootstrapComponentDefinition -Name 'manual-test' -Description 'manual test' -Optional $true -Kind 'manual-required' -Data @{ DisplayName = 'Manual Test'; Instructions = 'Install Manual Test manually.' }
            }
            $resolution = @{ ResolvedComponents = @('manual-test') }
            Mock Get-BootstrapComponentCatalog { $catalog }
            Mock Get-Winget { return $null }

            $rows = @(Invoke-BootstrapAuditMode -Resolution $resolution)

            [string]$rows[0].Status | Should Be 'Missing'
            [string]$rows[0].Severity | Should Be 'OptionalMissing'
            [string]$rows[0].HowToFix | Should Match 'Manual Test'
        }

        It 'audits command-backed custom AI tools instead of UnsupportedAudit' {
            $oldUserProfile = $env:USERPROFILE
            $tempUserProfile = Join-Path $env:TEMP ("bootstrap_audit_ai_tools_{0}" -f ([Guid]::NewGuid().ToString('N')))
            $catalog = @{
                'opencode' = New-BootstrapComponentDefinition -Name 'opencode' -Description 'OpenCode' -Kind 'opencode'
                'openclaw' = New-BootstrapComponentDefinition -Name 'openclaw' -Description 'OpenClaw' -Kind 'openclaw'
                'goose' = New-BootstrapComponentDefinition -Name 'goose' -Description 'Goose' -Kind 'goose'
            }
            try {
                New-Item -Path $tempUserProfile -ItemType Directory -Force | Out-Null
                $env:USERPROFILE = $tempUserProfile
                $resolution = @{ ResolvedComponents = @('opencode','openclaw','goose') }
                Mock Get-BootstrapComponentCatalog { $catalog }
                Mock Get-Winget { return $null }
                Mock Resolve-CommandPath {
                    param([string]$Name)
                    switch ($Name) {
                        'opencode' { return 'C:\Tools\opencode.exe' }
                        'openclaw' { return 'C:\Tools\openclaw.cmd' }
                        default { return $null }
                    }
                }

                $rows = @(Invoke-BootstrapAuditMode -Resolution $resolution)

                ([string[]]@($rows | ForEach-Object { [string]$_.Severity }) -contains 'UnsupportedAudit') | Should Be $false
                $gooseRow = $rows | Where-Object Component -eq 'goose' | Select-Object -First 1
                [string]$gooseRow.Status | Should Be 'Missing'
            } finally {
                $env:USERPROFILE = $oldUserProfile
                if (Test-Path -LiteralPath $tempUserProfile) { Remove-Item -LiteralPath $tempUserProfile -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'audits WSL and VS Code extension components without UnsupportedAudit' {
            $catalog = @{
                'wsl-core' = New-BootstrapComponentDefinition -Name 'wsl-core' -Description 'WSL' -Optional $false -Kind 'wsl-core'
                'vscode-extensions' = New-BootstrapComponentDefinition -Name 'vscode-extensions' -Description 'VS Code extensions' -Optional $true -Kind 'vscode-extensions'
            }
            $resolution = @{ ResolvedComponents = @('wsl-core','vscode-extensions') }
            Mock Get-BootstrapComponentCatalog { $catalog }
            Mock Get-Winget { return $null }
            Mock Resolve-CommandPath {
                param([string]$Name)
                switch ($Name) {
                    'wsl.exe' { return 'C:\Windows\System32\wsl.exe' }
                    'code' { return 'C:\Users\Test\AppData\Local\Programs\Microsoft VS Code\bin\code.cmd' }
                    default { return $null }
                }
            }
            Mock Test-BootstrapAppxPackageInstalled { return $true }
            Mock Get-Service { return [pscustomobject]@{ Name = 'LxssManager'; Status = 'Running' } }
            Mock Get-BootstrapWslStatusProbe { return @{ exitCode = 0; stdout = 'WSL version: 2.6.1'; stderr = ''; timedOut = $false } }

            $rows = @(Invoke-BootstrapAuditMode -Resolution $resolution)

            $statuses = @($rows | ForEach-Object { [string]$_.Status })
            $severities = @($rows | ForEach-Object { [string]$_.Severity })
            ($statuses -contains 'UnsupportedAudit') | Should Be $false
            ($severities -contains 'UnsupportedAudit') | Should Be $false
            Assert-MockCalled Get-BootstrapWslStatusProbe -Times 1
        }

        It 'audits WSL MSI registration corruption as unhealthy instead of healthy' {
            $catalog = @{
                'wsl-core' = New-BootstrapComponentDefinition -Name 'wsl-core' -Description 'WSL' -Optional $false -Kind 'wsl-core'
            }
            $resolution = @{ ResolvedComponents = @('wsl-core') }
            Mock Get-BootstrapComponentCatalog { $catalog }
            Mock Get-Winget { return $null }
            Mock Resolve-CommandPath {
                param([string]$Name)
                if ($Name -eq 'wsl.exe') { return 'C:\Windows\System32\wsl.exe' }
                return $null
            }
            Mock Test-BootstrapAppxPackageInstalled { return $true }
            Mock Get-Service { return [pscustomobject]@{ Name = 'LxssManager'; Status = 'Running' } }
            Mock Get-BootstrapWslStatusProbe { return @{ exitCode = 1; stdout = ''; stderr = 'Wsl/CallMsi/Install/REGDB_E_CLASSNOTREG'; timedOut = $false } }

            $rows = @(Invoke-BootstrapAuditMode -Resolution $resolution)

            [string]$rows[0].Status | Should Be 'Unhealthy'
            [string]$rows[0].Severity | Should Be 'NeedsRepair'
            [string]$rows[0].HowToFix | Should Match 'administrador|wsl --update|Microsoft.WSL'
        }

        It 'blocks WSL core repair without admin when MSI registration is corrupt' {
            Mock Ensure-BootstrapSystemCore {}
            Mock Test-IsAdmin { return $false }
            Mock Resolve-CommandPath {
                param([string]$Name)
                if ($Name -eq 'wsl.exe') { return 'C:\Windows\System32\wsl.exe' }
                return $null
            }
            Mock Get-BootstrapWslStatusProbe { return @{ exitCode = 1; stdout = ''; stderr = 'Wsl/CallMsi/Install/REGDB_E_CLASSNOTREG'; timedOut = $false } }
            Mock Write-Log {}
            $caught = $null

            try {
                Ensure-WslCore -State @{}
            } catch {
                $caught = $_
            }

            $caught | Should Not Be $null
            [string]$caught.Exception.Data['BootstrapStatus'] | Should Be 'blocked'
            [string]$caught.Exception.Data['BootstrapBlockerKind'] | Should Be 'wsl-msi-registration-broken'
            [string]$caught.Exception.Data['BootstrapAction'] | Should Be 'rerun-elevated-or-repair-wsl'
        }

        It 'marks WSL repair as restart-required after enabling Windows features' {
            Mock Test-IsAdmin { return $true }
            Mock Get-WindowsOptionalFeatureState { return 'Disabled' }
            Mock Invoke-NativeWithLog { return 0 }
            Mock Invoke-NativeCaptureWithLog { return @{ exitCode = 0; stdout = ''; stderr = ''; timedOut = $false } }
            Mock Write-Log {}
            $caught = $null

            try {
                Repair-BootstrapWslCorruption -WslExe 'C:\Windows\System32\wsl.exe' -State @{}
            } catch {
                $caught = $_
            }

            $caught | Should Not Be $null
            [string]$caught.Exception.Data['BootstrapStatus'] | Should Be 'blocked'
            [string]$caught.Exception.Data['BootstrapBlockerKind'] | Should Be 'wsl-requires-reboot'
            [string]$caught.Exception.Data['BootstrapAction'] | Should Be 'restart-and-resume'
        }

        It 'stops WSL core setup after newly enabled features and asks for resume' {
            Mock Ensure-BootstrapSystemCore {}
            Mock Test-IsAdmin { return $true }
            Mock Resolve-CommandPath {
                param([string]$Name)
                if ($Name -eq 'wsl.exe') { return 'C:\Windows\System32\wsl.exe' }
                return $null
            }
            Mock Assert-BootstrapWslNotCorrupt { return @{ exitCode = 0; stdout = ''; stderr = ''; timedOut = $false } }
            Mock Get-WindowsOptionalFeatureState { return 'Disabled' }
            Mock Invoke-NativeWithLog { return 0 }
            Mock Invoke-NativeCaptureWithLog { throw 'wsl --update must not run before reboot after enabling features' }
            Mock Write-Log {}
            $caught = $null

            try {
                Ensure-WslCore -State @{}
            } catch {
                $caught = $_
            }

            $caught | Should Not Be $null
            [string]$caught.Exception.Data['BootstrapStatus'] | Should Be 'blocked'
            [string]$caught.Exception.Data['BootstrapBlockerKind'] | Should Be 'wsl-requires-reboot'
            [string]$caught.Exception.Data['BootstrapAction'] | Should Be 'restart-and-resume'
        }

        It 'marks WSL as restart-required when only the AppX package is present' {
            $catalog = @{
                'wsl-core' = New-BootstrapComponentDefinition -Name 'wsl-core' -Description 'WSL' -Optional $false -Kind 'wsl-core'
            }
            $resolution = @{ ResolvedComponents = @('wsl-core') }
            Mock Get-BootstrapComponentCatalog { $catalog }
            Mock Get-Winget { return $null }
            Mock Resolve-CommandPath {
                param([string]$Name)
                if ($Name -eq 'wsl.exe') { return 'C:\Windows\System32\wsl.exe' }
                return $null
            }
            Mock Test-BootstrapAppxPackageInstalled { return $true }
            Mock Get-Service { throw 'service missing' }
            Mock Get-BootstrapWslStatusProbe { return @{ exitCode = 0; stdout = ''; stderr = ''; timedOut = $false } }

            $rows = @(Invoke-BootstrapAuditMode -Resolution $resolution)

            [string]$rows[0].Status | Should Be 'RequiresRestart'
            [string]$rows[0].Severity | Should Be 'RequiresRestart'
            [string]$rows[0].HowToFix | Should Match 'Reinicie'
            Assert-MockCalled Get-BootstrapWslStatusProbe -Times 1
        }
    }

    Context 'Result JSON contract matrix' {
        It 'writes schema for success warning blocked and error statuses' {
            $root = Join-Path $env:TEMP ('phasezero-result-matrix-' + [guid]::NewGuid().ToString('N'))
            try {
                New-Item -ItemType Directory -Path $root -Force | Out-Null
                foreach ($case in @(
                    @{ Name = 'success'; Status = 'success'; Exit = 0; DiagnosticCount = 0 },
                    @{ Name = 'warning'; Status = 'warning'; Exit = 0; DiagnosticCount = 1 },
                    @{ Name = 'blocked'; Status = 'blocked'; Exit = 2; DiagnosticCount = 1 },
                    @{ Name = 'error'; Status = 'error'; Exit = 1; DiagnosticCount = 1 }
                )) {
                    $path = Join-Path $root ("{0}.result.json" -f $case.Name)
                    Write-BootstrapExecutionResultFile -Path $path -Value ([ordered]@{
                        status = [string]$case.Status
                        mode = 'matrix-test'
                        error = $(if ([int]$case.DiagnosticCount -gt 0) { "matrix $($case.Status)" } else { '' })
                        howToFix = 'matrix fix'
                    })

                    Test-Path -LiteralPath $path | Should Be $true
                    $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                    [string]$json.status | Should Be ([string]$case.Status)
                    [int]$json.exitCode | Should Be ([int]$case.Exit)
                    [string]$json.resultPath | Should Be $path
                    [string]$json.logPath | Should Match '\.log$'
                    [string]$json.artifactPaths.resultPath | Should Be $path
                    $json.PSObject.Properties.Name -contains 'scope' | Should Be $true
                    $json.PSObject.Properties.Name -contains 'rollback' | Should Be $true
                    @($json.diagnostics).Count | Should Be ([int]$case.DiagnosticCount)
                }
            } finally {
                if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'serializa strings escalares em arrays e caminhos sem objetos Length' {
            $root = Join-Path $env:TEMP ('phasezero-result-scalars-' + [guid]::NewGuid().ToString('N'))
            try {
                New-Item -ItemType Directory -Path $root -Force | Out-Null
                $resultPath = Join-Path $root 'scalar.result.json'
                $changesPath = Join-Path $root 'changes.json'

                Write-BootstrapExecutionResultFile -Path $resultPath -Value ([ordered]@{
                    status = 'success'
                    changesPath = $changesPath
                    preflight = [ordered]@{
                        pendingRebootReasons = @('PendingFileRenameOperations')
                        pendingRebootMsiBlockers = @()
                    }
                })

                $rawJson = Get-Content -LiteralPath $resultPath -Raw
                $json = $rawJson | ConvertFrom-Json
                [string]$json.changesPath | Should Be $changesPath
                ($json.preflight.pendingRebootReasons[0] -is [string]) | Should Be $true
                [string]$json.preflight.pendingRebootReasons[0] | Should Be 'PendingFileRenameOperations'
                ($rawJson -match '"Length"\s*:') | Should Be $false
                [string]$json.artifactPaths.changesPath | Should Be $changesPath
                [string]$json.rollback.changesPath | Should Be $changesPath
            } finally {
                if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    Context 'AppTuning log lines (StrictMode safe)' {
        It 'materializes empty AppTuning filter lists without null.Count' {
            $selection = [pscustomobject]@{
                AppTuningCategories    = @()
                AppTuningItems         = @()
                ExcludedAppTuningItems = @()
            }
            $reqItems = @(
                foreach ($it in @($selection.AppTuningItems)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$it)) { [string]$it }
                }
            )
            ($null -eq $reqItems) | Should Be $false
            $reqItems.Length | Should Be 0

            $plan = [ordered]@{ items = @() }
            $planItemIds = @(
                foreach ($planItem in @($plan.items)) {
                    $planItemId = [string]$planItem.id
                    if (-not [string]::IsNullOrWhiteSpace($planItemId)) { $planItemId }
                }
            )
            $planItemIds.Length | Should Be 0
        }

        It 'DryRun notepadpp with custom AppTuning logs param lines without throwing' {
            $log = Join-Path $env:TEMP ("bt-apptun-{0}.log" -f ([Guid]::NewGuid().ToString('N')))
            $res = Join-Path $env:TEMP ("bt-apptun-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
            Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $res -Force -ErrorAction SilentlyContinue
            $pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $invokeArgs = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
                '-NonInteractive', '-DryRun', '-LogPath', $log, '-ResultPath', $res,
                '-Component', 'notepadpp', '-AppTuning', 'custom'
            )
            $proc = Start-Process -FilePath $pwsh -ArgumentList $invokeArgs -Wait -PassThru -NoNewWindow
            $proc.ExitCode | Should Be 0
            $raw = Get-Content -LiteralPath $log -Raw -ErrorAction Stop
            $raw | Should Match 'AppTuning itens \(param\):'
            $raw | Should Match 'AppTuning plano:'
            Remove-Item -LiteralPath $log, $res -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'Git path resolution e Join-Path (repo-clone)' {
        It 'Set-UserEnvVar normaliza Value em colecao para o primeiro elemento nao vazio' {
            Mock Write-Log
            $name = 'PHASEZERO_MULTI_SETUSERTEST'
            $oldUser = [Environment]::GetEnvironmentVariable($name, 'User')
            $oldProc = [Environment]::GetEnvironmentVariable($name, 'Process')
            try {
                [Environment]::SetEnvironmentVariable($name, $null, 'User')
                [Environment]::SetEnvironmentVariable($name, $null, 'Process')
                Set-UserEnvVar -Name $name -Value @('  primeiro  ', 'segundo')
                [Environment]::GetEnvironmentVariable($name, 'User') | Should Be 'primeiro'
            } finally {
                if ($null -ne $oldUser) { [Environment]::SetEnvironmentVariable($name, $oldUser, 'User') } else { [Environment]::SetEnvironmentVariable($name, $null, 'User') }
                if ($null -ne $oldProc) { [Environment]::SetEnvironmentVariable($name, $oldProc, 'Process') } else { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
            }
        }

        It 'Get-GitBashExe retorna um FullName quando variavel User tem wildcard e varios ficheiros' {
            $td = Join-Path $env:TEMP ("pz-gitbash-wc-" + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $td -Force
            $oldUser = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'User')
            try {
                [System.IO.File]::WriteAllText((Join-Path $td 'bash1.exe'), 'stub', [System.Text.ASCIIEncoding]::new())
                [System.IO.File]::WriteAllText((Join-Path $td 'bash2.exe'), 'stub', [System.Text.ASCIIEncoding]::new())
                $pat = Join-Path $td 'bash?.exe'
                [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $pat, 'User')
                $r = Get-GitBashExe
                @($r).Count | Should Be 1
                [string]$r | Should Match 'bash[12]\.exe$'
            } finally {
                if ($null -ne $oldUser) { [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $oldUser, 'User') } else { [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $null, 'User') }
                Remove-Item -LiteralPath $td -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Resolve-BootstrapPythonExecutable ignora stub WindowsApps e usa instalacao local' {
            $oldLocalAppData = $env:LOCALAPPDATA
            $root = Join-Path $env:TEMP ("bootstrap_python_resolve_{0}" -f ([Guid]::NewGuid().ToString('N')))
            $pythonDir = Join-Path $root 'Programs\Python\Python313'
            $pythonExe = Join-Path $pythonDir 'python.exe'
            try {
                $env:LOCALAPPDATA = $root
                New-Item -Path $pythonDir -ItemType Directory -Force | Out-Null
                New-Item -Path $pythonExe -ItemType File -Force | Out-Null
                Mock Resolve-CommandPath {
                    param([string]$Name)
                    if ($Name -eq 'python') { return 'C:\Users\misae\AppData\Local\Microsoft\WindowsApps\python.exe' }
                    return $null
                }
                Mock Get-BootstrapCommandPathCandidates { return @() }
                Mock Refresh-SessionPath { }

                # Expande 8.3 (RUNNER~1 nos runners) para a forma longa via (Get-Location).Path
                # (mesma resolucao da funcao), normalizando o diretorio pai e rejuntando o nome.
                $expectedExe = $pythonExe
                Push-Location -LiteralPath $pythonDir
                try { $expectedExe = Join-Path (Get-Location).Path 'python.exe' } finally { Pop-Location }
                Resolve-BootstrapPythonExecutable | Should Be $expectedExe
            } finally {
                $env:LOCALAPPDATA = $oldLocalAppData
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Resolve-BootstrapPythonExecutable ignora venv Hermes e usa Python real' {
            Mock Get-BootstrapCommandPathCandidates {
                return @(
                    'C:\Users\misae\.hermes\hermes-agent\venv\Scripts\python.exe',
                    'C:\Users\misae\AppData\Local\Programs\Python\Python313\python.exe',
                    'C:\Users\misae\AppData\Local\Microsoft\WindowsApps\python.exe'
                )
            }
            Mock Refresh-SessionPath { }
            Mock Resolve-CommandPath { return $null }

            Resolve-BootstrapPythonExecutable | Should Be 'C:\Users\misae\AppData\Local\Programs\Python\Python313\python.exe'
        }

        It 'Convert-HookItemIfNeeded converte hooks Bonsai Windows para paths Git Bash' {
            $item = [pscustomobject]@{
                type = 'command'
                command = 'C:\Users\misae\AppData\Local\Microsoft\WinGet\Packages\OpenJS.NodeJS.LTS_Microsoft.Winget.Source_8wekyb3d8bbwe\node-v24.15.0-win-x64\node.exe C:\Users\misae\AppData\Local\Microsoft\WinGet\Packages\OpenJS.NodeJS.LTS_Microsoft.Winget.Source_8wekyb3d8bbwe\node-v24.15.0-win-x64\node_modules\@bonsai-ai\cli\dist\cli.js internal snapshot'
            }

            $fixed = Convert-HookItemIfNeeded -Item $item -GitBashPath 'C:\Program Files\Git\bin\bash.exe'

            $fixed.command | Should Match '"/c/Users/misae/.+node\.exe"'
            $fixed.command | Should Match '"/c/Users/misae/.+cli\.js"'
            $fixed.command | Should Not Match 'C:\\Users'
        }

        It 'Repair-BootstrapBonsaiCliSnapshotHooks corrige gerador transiente de hooks do Bonsai' {
            $root = Join-Path $env:TEMP ("bootstrap_bonsai_cli_{0}" -f ([Guid]::NewGuid().ToString('N')))
            $dist = Join-Path $root 'node_modules\@bonsai-ai\cli\dist'
            $cli = Join-Path $dist 'cli.js'
            try {
                New-Item -Path $dist -ItemType Directory -Force | Out-Null
                [System.IO.File]::WriteAllText($cli, 'function zW1(){let D=`${process.argv[0]} ${process.argv[1]} internal snapshot`;return JSON.stringify({hooks:{SessionStart:[{hooks:[{command:D}]}]}})}', [System.Text.UTF8Encoding]::new($false))
                Mock Copy-Item {
                    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
                    [System.IO.File]::Copy($LiteralPath, $Destination, $true) | Out-Null
                }

                $result = @(Repair-BootstrapBonsaiCliSnapshotHooks -CliPath $cli | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'Status') })[0]
                $updated = Get-Content -Path $cli -Raw -Encoding utf8

                $result.Status | Should Be 'patched'
                [bool](Test-Path -LiteralPath $result.BackupPath) | Should Be $true
                $updated | Should Match '\[process\.argv\[0\],process\.argv\[1\],"internal","snapshot"\]'
                $updated | Should Match 'JSON\.stringify\(C\)\}\)\.join\(" "\)'
                $updated | Should Not Match 'let D=`\$\{process\.argv\[0\]\}'

                $second = @(Repair-BootstrapBonsaiCliSnapshotHooks -CliPath $cli | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'Status') })[0]
                $second.Status | Should Be 'already-patched'
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Invoke-BootstrapComponent repo-clone falha se TargetName for colecao com mais de um valor' {
            Mock Write-Log
            Mock Ensure-BootstrapGitCore { }
            Mock Ensure-RepoClone { }
            $bad = New-BootstrapComponentDefinition -Name 'bad-repo' -Description 'test' -Kind 'repo-clone' -Optional $false -DependsOn @() -Data @{ RepoUrl = 'https://example.com/x.git'; TargetName = @('a', 'b') }
            $catalog = @{ 'bad-repo' = $bad }
            Mock Get-BootstrapComponentCatalog { $catalog }
            $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\' -ResolvedCloneBaseDir 'D:\clones'
            $state.GitInfo = @{ Git = 'C:\Program Files\Git\cmd\git.exe'; Bash = 'C:\Program Files\Git\bin\bash.exe' }
            { Invoke-BootstrapComponent -Name 'bad-repo' -State $state } | Should Throw 'TargetName deve ser uma unica string'
        }

        It 'Invoke-BootstrapComponent repo-clone usa primeiro TargetName quando e array de um elemento' {
            Mock Write-Log
            Mock Ensure-BootstrapGitCore { }
            $captured = $null
            Mock Ensure-RepoClone {
                param($GitExe, $RepoUrl, $TargetDir)
                $script:capturedRepoCloneTarget = $TargetDir
            }
            $one = New-BootstrapComponentDefinition -Name 'one-repo' -Description 'test' -Kind 'repo-clone' -Optional $false -DependsOn @() -Data @{ RepoUrl = 'https://example.com/x.git'; TargetName = @('onlyname') }
            $catalog = @{ 'one-repo' = $one }
            Mock Get-BootstrapComponentCatalog { $catalog }
            $state = New-BootstrapState -Selection @{} -ResolvedWorkspaceRoot 'C:\' -ResolvedCloneBaseDir 'D:\clones'
            $state.GitInfo = @{ Git = 'C:\Program Files\Git\cmd\git.exe'; Bash = 'C:\Program Files\Git\bin\bash.exe' }
            Invoke-BootstrapComponent -Name 'one-repo' -State $state
            $script:capturedRepoCloneTarget | Should Be (Join-Path 'D:\clones' 'onlyname')
        }
    }

    Context 'Invoke-NativeFirstLine ps1' {
        It 'executa .ps1 via powershell -File em vez de cmd (evita dialogo Abrir com)' {
            $tmp = Join-Path $env:TEMP ("pz-nfl-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
            [System.IO.File]::WriteAllText($tmp, 'Write-Output "hello-from-nfl-test"', [System.Text.UTF8Encoding]::new($false))
            try {
                $line = Invoke-NativeFirstLine -Exe $tmp -Args @()
                [string]$line | Should Match 'hello-from-nfl-test'
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Test-BootstrapDotNetSdkListHasEntry' {
        It 'retorna true quando ha linha major.minor.patch' {
            $out = @"
8.0.416 [C:\Program Files\dotnet\sdk]
6.0.428 [C:\Program Files\dotnet\sdk]
"@
            Test-BootstrapDotNetSdkListHasEntry -ListSdksOutput $out | Should Be $true
        }

        It 'retorna false quando vazio ou so espacos' {
            Test-BootstrapDotNetSdkListHasEntry -ListSdksOutput '' | Should Be $false
            Test-BootstrapDotNetSdkListHasEntry -ListSdksOutput "   `n  " | Should Be $false
        }

        It 'retorna false quando saida sem versao SDK (mensagens apenas)' {
            $out = @'
Welcome to .NET 8.0!
---------------------
'@
            Test-BootstrapDotNetSdkListHasEntry -ListSdksOutput $out | Should Be $false
        }
    }

    Context 'Normalize-BootstrapPathSegment' {
        It 'retorna primeiro elemento quando valor e colecao' {
            Normalize-BootstrapPathSegment -Value @('C:\primeiro', 'C:\segundo') | Should Be 'C:\primeiro'
        }

        It 'retorna string vazia para null' {
            Normalize-BootstrapPathSegment -Value $null | Should Be ''
        }
    }

    Context 'Get-BootstrapChangeManifestPath com RunId colecao' {
        It 'normaliza RunId para primeiro segmento e gera um unico ficheiro changes.json' {
            Mock Get-BootstrapDataRoot { return 'D:\fakeDataRoot' }
            $st = @{
                RunId              = @('runA', 'runB')
                ChangeManifestPath = ''
                Changes            = (New-Object 'System.Collections.Generic.List[object]')
            }
            $p = Get-BootstrapChangeManifestPath -State $st
            $p | Should Be 'D:\fakeDataRoot\runs\runA\changes.json'
            $st.ChangeManifestPath | Should Be 'D:\fakeDataRoot\runs\runA\changes.json'
        }
    }

    Context 'Test-BootstrapDotNetSdkListHasMajorBand' {
        It 'retorna true quando existe SDK 8.x' {
            $out = "6.0.428 [C:\sdk]`n8.0.416 [C:\sdk]"
            Test-BootstrapDotNetSdkListHasMajorBand -ListSdksOutput $out -Major 8 | Should Be $true
        }

        It 'retorna false quando so SDK 6' {
            $out = "6.0.428 [C:\Program Files\dotnet\sdk]"
            Test-BootstrapDotNetSdkListHasMajorBand -ListSdksOutput $out -Major 8 | Should Be $false
        }

        It 'usa probe especifico de SDK 8 ao instalar dotnet-core' {
            $script:dotnetProbePaths = @()
            Mock Get-DotNetExe { return 'C:\Program Files\dotnet\dotnet.exe' }
            Mock Get-DotNetListSdksOutput { return "10.0.203 [C:\Program Files\dotnet\sdk]" }
            Mock Ensure-WingetPackage {
                param($WingetPath, $Id, $DisplayName, $AllowFailureWhenNotAdmin, $ProbePaths)
                $script:dotnetProbePaths = @($ProbePaths)
            }
            Mock Refresh-SessionPath {}

            { Ensure-DotNetSdkAndVerify -WingetPath 'winget.exe' } | Should Throw 'SDK 8.x'

            ($script:dotnetProbePaths -join '|') | Should Match '\\dotnet\\sdk\\8\.\*\\dotnet\.dll'
            ($script:dotnetProbePaths -join '|') | Should Not Match '\\dotnet\\dotnet\.exe'
        }
    }

    Context 'Winget list probe (Invoke-WingetListIdProbe)' {
        It 'Invoke-WingetListIdProbe le stdout/stderr apos Start-Process com redirecionamento (Start-Process mock)' {
            Mock Start-Process {
                param(
                    [string]$FilePath,
                    [string[]]$ArgumentList,
                    [string]$RedirectStandardOutput,
                    [string]$RedirectStandardError
                )
                if (-not [string]::IsNullOrWhiteSpace($RedirectStandardOutput)) {
                    [System.IO.File]::WriteAllText($RedirectStandardOutput, "Nome Id Versao`nPkg Microsoft.WindowsTerminal 1.0 winget")
                }
                if (-not [string]::IsNullOrWhiteSpace($RedirectStandardError)) {
                    [System.IO.File]::WriteAllText($RedirectStandardError, '')
                }
                $fake = New-Object psobject -Property @{ Id = 424242; ExitCode = 0 }
                $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param([int]$milliseconds = 0) $true } -Force
                return $fake
            }
            $cap = Invoke-WingetListIdProbe -WingetPath 'C:\Fake\winget.exe' -Id 'Microsoft.WindowsTerminal' -TimeoutMs 5000
            $probe = @($cap | Where-Object { $_ -is [System.Collections.IDictionary] })[0]
            [bool]$probe['timedOut'] | Should Be $false
            [int]$probe['exitCode'] | Should Be 0
            [string]$probe['stdout'] | Should Match 'Microsoft\.WindowsTerminal'
            Assert-MockCalled Start-Process -Times 1 -Exactly
        }

        It 'Test-WingetPackageInstalled com exit -1978335212 regista INFO e nao WARN de assume-se nao instalado' {
            Mock Invoke-WingetListIdProbe {
                return [ordered]@{
                    exitCode = -1978335212
                    timedOut = $false
                    stdout   = ''
                    stderr   = ''
                }
            }
            Mock Write-Log
            $r = Test-WingetPackageInstalled -WingetPath 'C:\Windows\System32\cmd.exe' -Id 'OpenJS.NodeJS.LTS'
            $r | Should Be $false
            Assert-MockCalled Write-Log -ParameterFilter { $Message -match 'NO_APPLICATIONS_FOUND' } -Times 1 -Exactly
            Assert-MockCalled Write-Log -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'assume-se nao instalado' } -Times 0 -Exactly
        }

        It 'Test-WingetPackageInstalled nao chama Invoke-NativeCaptureWithLog' {
            Mock Invoke-NativeCaptureWithLog { throw 'Invoke-NativeCaptureWithLog nao deve ser usado para winget list' }
            Mock Invoke-WingetListIdProbe {
                return [ordered]@{
                    exitCode = -1978335212
                    timedOut = $false
                    stdout   = ''
                    stderr   = ''
                }
            }
            Mock Write-Log
            { Test-WingetPackageInstalled -WingetPath 'C:\Windows\System32\cmd.exe' -Id 'X.Y.Z' } | Should Not Throw
            Assert-MockCalled Invoke-NativeCaptureWithLog -Times 0 -Exactly
        }
    }

    Context 'Winget install modo silencioso preferencial' {
        It 'Ensure-WingetPackage bloqueia instalacao winget antes de mutar quando reboot pendente hostil a MSI existe' {
            Mock Test-WingetPackageInstalled { return $false }
            Mock Test-BootstrapPackageArtifactsPresent { return $false }
            Mock Get-BootstrapMsiHostilePendingRebootReasons { return @('PendingFileRenameOperations') }
            Mock Invoke-NativeWithRetry { throw 'winget install nao deve executar com reboot pendente hostil' }
            Mock Write-Log {}

            $caught = $null
            try {
                Ensure-WingetPackage -WingetPath 'fake.exe' -Id 'Test.Pending' -DisplayName 'PendingPkg' -ProbePaths @('C:\missing\pending.exe')
            } catch {
                $caught = $_
            }

            $caught | Should Not Be $null
            [string]$caught.Exception.Data['BootstrapStatus'] | Should Be 'blocked'
            [string]$caught.Exception.Data['BootstrapBlockerKind'] | Should Be 'pending-reboot-msi'
            [string]$caught.Exception.Data['BootstrapAction'] | Should Be 'restart-required'
            Assert-MockCalled Invoke-NativeWithRetry -Times 0 -Exactly -Scope It
        }

        It 'Ensure-WingetPackage tenta --silent primeiro e faz fallback sem --silent' {
            Mock Test-WingetPackageInstalled { return $false }
            Mock Get-BootstrapMsiHostilePendingRebootReasons { return @() }
            Mock Invoke-NativeWithRetry {
                param([string]$Exe, [string[]]$Args, [string]$OperationName)
                if ($OperationName -match '--silent') { return 1 }
                return 0
            }
            Mock Refresh-SessionPath { }
            Mock Write-Log { }

            { Ensure-WingetPackage -WingetPath 'C:\Fake\winget.exe' -Id 'Notepad++.Notepad++' -DisplayName 'Notepad++' -PreferUserScope $true -AllowFailureWhenNotAdmin $false } | Should Not Throw

            Assert-MockCalled Invoke-NativeWithRetry -ParameterFilter { $OperationName -eq 'Notepad++ via winget --scope user --silent' } -Times 1 -Exactly
            Assert-MockCalled Invoke-NativeWithRetry -ParameterFilter { $OperationName -eq 'Notepad++ via winget --scope user' } -Times 1 -Exactly
            Assert-MockCalled Refresh-SessionPath -Times 1 -Exactly
        }

        It 'Ensure-WingetPackage evita fallback machine sem admin quando user-scope falha' {
            Mock Test-WingetPackageInstalled { return $false }
            Mock Get-BootstrapMsiHostilePendingRebootReasons { return @() }
            Mock Test-IsAdmin { return $false }
            Mock Invoke-NativeWithRetry { return -1978335216 }
            Mock Refresh-SessionPath { throw 'Refresh-SessionPath nao deve executar quando pacote foi pulado' }
            Mock Write-Log { }
            $state = @{
                ComponentStatus = @{}
                SkippedComponents = New-Object System.Collections.Generic.List[object]
                Warnings = New-Object System.Collections.Generic.List[string]
            }

            { Ensure-WingetPackage -WingetPath 'C:\Fake\winget.exe' -Id 'Google.Chrome' -DisplayName 'Google Chrome' -PreferUserScope $true -AllowFailureWhenNotAdmin $true -State $state -ComponentName 'chrome' } | Should Not Throw

            Assert-MockCalled Invoke-NativeWithRetry -ParameterFilter { $OperationName -eq 'Google Chrome via winget --scope user --silent' } -Times 1 -Exactly
            Assert-MockCalled Invoke-NativeWithRetry -ParameterFilter { $OperationName -eq 'Google Chrome via winget --scope user' } -Times 0 -Exactly
            Assert-MockCalled Invoke-NativeWithRetry -ParameterFilter { $OperationName -eq 'Google Chrome via winget --scope user --silent' -and $TimeoutMs -eq 300000 } -Times 1 -Exactly
            Assert-MockCalled Invoke-NativeWithRetry -ParameterFilter { $OperationName -eq 'Google Chrome via winget --silent' } -Times 0 -Exactly
            Assert-MockCalled Invoke-NativeWithRetry -ParameterFilter { $OperationName -eq 'Google Chrome via winget' } -Times 0 -Exactly
            Assert-MockCalled Write-Log -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'nao tem instalador aplicavel' } -Times 1 -Exactly
            @($state.SkippedComponents.ToArray()).Count | Should Be 1
            [string]$state.SkippedComponents[0].component | Should Be 'chrome'
            [string]$state.ComponentStatus['chrome'].status | Should Be 'skipped'
            @($state.Warnings.ToArray()).Count | Should Be 1
        }

        It 'Ensure-WingetPackage bloqueia fallback machine sem admin para pacote requerido' {
            Mock Test-WingetPackageInstalled { return $false }
            Mock Get-BootstrapMsiHostilePendingRebootReasons { return @() }
            Mock Test-IsAdmin { return $false }
            Mock Invoke-NativeWithRetry { return -1978335216 }
            Mock Refresh-SessionPath { throw 'Refresh-SessionPath nao deve executar quando pacote foi bloqueado' }
            Mock Write-Log { }

            $caught = $null
            try {
                Ensure-WingetPackage -WingetPath 'C:\Fake\winget.exe' -Id 'Microsoft.DotNet.SDK.8' -DisplayName 'Microsoft .NET SDK 8' -PreferUserScope $true -AllowFailureWhenNotAdmin $false
            } catch {
                $caught = $_
            }

            $caught | Should Not Be $null
            [string]$caught.Exception.Data['BootstrapStatus'] | Should Be 'blocked'
            [string]$caught.Exception.Data['BootstrapBlockerKind'] | Should Be 'winget-machine-scope-requires-admin'
            [string]$caught.Exception.Data['BootstrapAction'] | Should Be 'rerun-elevated-or-install-manually'
            Assert-MockCalled Invoke-NativeWithRetry -ParameterFilter { $OperationName -eq 'Microsoft .NET SDK 8 via winget --scope user --silent' } -Times 1 -Exactly
            Assert-MockCalled Invoke-NativeWithRetry -ParameterFilter { $OperationName -eq 'Microsoft .NET SDK 8 via winget --silent' } -Times 0 -Exactly
            Assert-MockCalled Invoke-NativeWithRetry -ParameterFilter { $OperationName -eq 'Microsoft .NET SDK 8 via winget' } -Times 0 -Exactly
        }

        It 'Ensure-WingetPackage pula apos timeout user-scope sem retentar non-silent em non-admin' {
            Mock Test-WingetPackageInstalled { return $false }
            Mock Get-BootstrapMsiHostilePendingRebootReasons { return @() }
            Mock Test-IsAdmin { return $false }
            Mock Invoke-NativeWithRetry { return 124 }
            Mock Refresh-SessionPath { throw 'Refresh-SessionPath nao deve executar quando pacote foi pulado' }
            Mock Write-Log { }
            $state = @{
                ComponentStatus = @{}
                SkippedComponents = New-Object System.Collections.Generic.List[object]
                Warnings = New-Object System.Collections.Generic.List[string]
            }

            { Ensure-WingetPackage -WingetPath 'C:\Fake\winget.exe' -Id 'Google.Antigravity' -DisplayName 'Antigravity' -PreferUserScope $true -AllowFailureWhenNotAdmin $true -State $state -ComponentName 'antigravity' } | Should Not Throw

            Assert-MockCalled Invoke-NativeWithRetry -ParameterFilter { $OperationName -eq 'Antigravity via winget --scope user --silent' -and $NonRetryableExitCodes -contains 124 -and $NonRetryableExitCodes -contains -1978335226 } -Times 1 -Exactly
            Assert-MockCalled Invoke-NativeWithRetry -ParameterFilter { $OperationName -eq 'Antigravity via winget --scope user' } -Times 0 -Exactly
            [string]$state.ComponentStatus['antigravity'].status | Should Be 'skipped'
            [int]$state.SkippedComponents[0].exitCode | Should Be 124
        }

        It 'Ensure-WingetPackage treats NO_APPLICATIONS_FOUND as install failure not soft success' {
            Mock Test-WingetPackageInstalled { return $false }
            Mock Get-BootstrapMsiHostilePendingRebootReasons { return @() }
            Mock Test-IsAdmin { return $true }
            Mock Test-BootstrapPackageArtifactsPresent { return $false }
            Mock Refresh-SessionPath { throw 'Refresh-SessionPath must not run after package-not-found install failure' }
            Mock Invoke-NativeWithRetry {
                param([string]$Exe, [string[]]$Args, [string]$OperationName, [int[]]$SoftSuccessExitCodes)
                if ($SoftSuccessExitCodes -contains -1978335212) { throw 'NO_APPLICATIONS_FOUND must not be a winget install soft success' }
                return -1978335212
            }
            Mock Write-Log { }

            $caught = $null
            try {
                Ensure-WingetPackage -WingetPath 'C:\Fake\winget.exe' -Id 'iOfficeAI.AionUi' -DisplayName 'AionUI' -PreferUserScope $false -AllowFailureWhenNotAdmin $false -ProbePaths @('C:\missing\aionui.exe')
            } catch {
                $caught = $_
            }

            $caught | Should Not Be $null
            [string]$caught.Exception.Data['BootstrapStatus'] | Should Be 'blocked'
            [string]$caught.Exception.Data['BootstrapBlockerKind'] | Should Be 'winget-package-not-found'
            [string]$caught.Exception.Data['BootstrapAction'] | Should Be 'check-winget-id-or-source'
            Assert-MockCalled Test-BootstrapPackageArtifactsPresent -Times 1 -Exactly -Scope It
            Assert-MockCalled Refresh-SessionPath -Times 0 -Exactly -Scope It
        }
    }

    Context 'Perfis e preflight manual/reboot' {
        It 'perfil base nao inclui google-app-desktop; utilities inclui' {
            $baseRes = Resolve-BootstrapComponents -SelectedProfiles @('base') -SelectedComponents @() -ExcludedComponents @()
            @($baseRes.ResolvedComponents) -contains 'google-app-desktop' | Should Be $false

            $utilRes = Resolve-BootstrapComponents -SelectedProfiles @('utilities') -SelectedComponents @() -ExcludedComponents @()
            @($utilRes.ResolvedComponents) -contains 'google-app-desktop' | Should Be $true
        }

        It 'Invoke-BootstrapExecutionPreflight falha com RequireNoPendingReboot quando ha reboot pendente' {
            $prev = $script:RequireNoPendingReboot
            $prevAllow = $script:AllowPendingReboot
            try {
                $script:RequireNoPendingReboot = $true
                $script:AllowPendingReboot = $false
                Mock Test-BootstrapDiskSpace { }
                Mock Get-BootstrapPreflightRequirements {
                    return [ordered]@{
                        RequiresNetwork = $false
                        RequiresWinget = $false
                        ConnectivityGroups = @()
                    }
                }
                Mock Get-BootstrapPendingRebootReasons { return @('WindowsUpdate') }
                $sel = New-BootstrapSelectionObject -SelectedProfiles @() -SelectedComponents @('system-core') -ExcludedComponents @()
                $state = New-BootstrapState -Selection $sel -ResolvedWorkspaceRoot 'C:\' -ResolvedCloneBaseDir 'C:\'
                { Invoke-BootstrapExecutionPreflight -State $state -ResolvedComponents @('system-core') } | Should Throw 'RequireNoPendingReboot'
            } finally {
                $script:RequireNoPendingReboot = $prev
                $script:AllowPendingReboot = $prevAllow
            }
        }

        It 'Invoke-BootstrapExecutionPreflight bloqueia apply winget quando ha reboot pendente por padrao' {
            $prev = $script:RequireNoPendingReboot
            $prevAllow = $script:AllowPendingReboot
            try {
                $script:RequireNoPendingReboot = $false
                $script:AllowPendingReboot = $false
                Mock Test-BootstrapDiskSpace { }
                Mock Get-BootstrapPreflightRequirements {
                    return [ordered]@{
                        RequiresNetwork = $false
                        RequiresWinget = $true
                        ConnectivityGroups = @()
                    }
                }
                Mock Get-BootstrapPendingRebootReasons { return @('PendingFileRenameOperations') }
                Mock Get-BootstrapPendingFileRenameOperationRecords {
                    return @(
                        [pscustomobject]@{
                            source = '\??\C:\Windows\System32\drivers\sample.sys'
                            destination = ''
                            category = 'driver'
                            msiHostile = $false
                        }
                    )
                }
                Mock Get-Winget { throw 'Get-Winget nao deve executar antes do bloqueio de reboot' }
                $sel = New-BootstrapSelectionObject -SelectedProfiles @() -SelectedComponents @('dotnet-core') -ExcludedComponents @()
                $state = New-BootstrapState -Selection $sel -ResolvedWorkspaceRoot 'C:\' -ResolvedCloneBaseDir 'C:\' -IsDryRun:$false

                $caught = $null
                try {
                    Invoke-BootstrapExecutionPreflight -State $state -ResolvedComponents @('system-core','dotnet-core')
                } catch {
                    $caught = $_
                }

                $caught | Should Not Be $null
                [string]$caught.Exception.Data['BootstrapStatus'] | Should Be 'blocked'
                [string]$caught.Exception.Data['BootstrapBlockerKind'] | Should Be 'pending-reboot-before-install'
                [string]$caught.Exception.Data['BootstrapAction'] | Should Be 'restart-required'
            } finally {
                $script:RequireNoPendingReboot = $prev
                $script:AllowPendingReboot = $prevAllow
            }
        }

        It 'classifica PendingFileRenameOperations de spool e GamingServices como aviso nao hostil a MSI' {
            Mock Get-BootstrapPendingFileRenameOperationRecords {
                return @(
                    [pscustomobject]@{
                        source = '\??\C:\Windows\System32\gamingservicesproxy_e.dll.0'
                        destination = ''
                        category = 'gaming-services'
                        msiHostile = $false
                    },
                    [pscustomobject]@{
                        source = '\??\C:\Windows\System32\spool\drivers\x64\3\New\UNIDRV.DLL'
                        destination = '\??\C:\Windows\System32\spool\drivers\x64\3\UNIDRV.DLL'
                        category = 'print-driver'
                        msiHostile = $false
                    }
                )
            }

            $blockers = @(Get-BootstrapMsiHostilePendingRebootReasons -Reasons @('PendingFileRenameOperations'))

            @($blockers).Count | Should Be 0
        }

        It 'classifica PendingFileRenameOperations de installer/cache como bloqueio MSI-hostil' {
            Mock Get-BootstrapPendingFileRenameOperationRecords {
                return @(
                    [pscustomobject]@{
                        source = '\??\C:\Windows\Installer\1234.tmp'
                        destination = '\??\C:\Windows\Installer\1234.msi'
                        category = 'installer'
                        msiHostile = $true
                    }
                )
            }

            $blockers = @(Get-BootstrapMsiHostilePendingRebootReasons -Reasons @('PendingFileRenameOperations'))

            @($blockers).Count | Should Be 1
            [string]$blockers[0] | Should Be 'PendingFileRenameOperations'
        }

        It 'inclui detalhes categorizados do pending reboot no diagnostico de preflight' {
            Mock Get-BootstrapPendingFileRenameOperationRecords {
                return @(
                    [pscustomobject]@{
                        source = '\??\C:\Windows\System32\spool\drivers\x64\3\New\UNIDRV.DLL'
                        destination = '\??\C:\Windows\System32\spool\drivers\x64\3\UNIDRV.DLL'
                        category = 'print-driver'
                        msiHostile = $false
                    }
                )
            }

            $details = @(Get-BootstrapPendingRebootDetails -Reasons @('PendingFileRenameOperations'))

            @($details).Count | Should Be 1
            [string]$details[0].reason | Should Be 'PendingFileRenameOperations'
            [string]$details[0].category | Should Be 'print-driver'
            [bool]$details[0].msiHostile | Should Be $false
        }
    }
    Context 'Winget ghost install handling' {
        It 'Ensure-WingetPackage detecta ghost install via ProbePaths' {
            $script:WingetGhostProbeCheckCount = 0
            Mock Test-WingetPackageInstalled { return $true }
            Mock Test-WingetProbePathsOnDisk {
                $script:WingetGhostProbeCheckCount++
                return ($script:WingetGhostProbeCheckCount -ge 3)
            }
            Mock Invoke-NativeWithRetry { return 0 }
            Mock Refresh-SessionPath {}
            Mock Write-Log {}
            Mock Get-BootstrapPendingRebootReasons { return @() }
            Mock Get-BootstrapProcessesByName { return @() }

            # Nao deve lancar excecao
            { Ensure-WingetPackage -WingetPath 'fake.exe' -Id 'Test.Ghost' -DisplayName 'GhostPkg' -ProbePaths @('C:\fake\ghost.exe') } | Should Not Throw
            Assert-MockCalled Get-BootstrapProcessesByName -Times 3 -Exactly -Scope It
        }

        It 'Ensure-WingetPackage classifica ghost-recovery como Blocked quando PendingFileRenameOperations bloqueia MSI' {
            Mock Test-WingetPackageInstalled { return $true }
            Mock Test-WingetProbePathsOnDisk { return $false }
            Mock Invoke-NativeWithRetry { return 0 }
            Mock Refresh-SessionPath {}
            Mock Write-Log {}
            Mock Get-BootstrapMsiHostilePendingRebootReasons { return @('PendingFileRenameOperations') }

            $caught = $null
            try {
                Ensure-WingetPackage -WingetPath 'fake.exe' -Id 'Test.Ghost' -DisplayName 'GhostPkg' -ProbePaths @('C:\fake\ghost.exe')
            } catch {
                $caught = $_
            }

            $caught | Should Not Be $null
            [string]$caught.Exception.Data['BootstrapStatus'] | Should Be 'blocked'
            [string]$caught.Exception.Data['BootstrapBlockerKind'] | Should Be 'pending-reboot-msi'
            [string]$caught.Exception.Data['BootstrapAction'] | Should Be 'restart-required'
            Assert-MockCalled Invoke-NativeWithRetry -Times 0 -Exactly -Scope It
        }

        It 'Ensure-WingetPackage prossegue ghost-recovery quando pending rename e benigno' {
            $script:WingetGhostProbeCheckCount = 0
            Mock Test-WingetPackageInstalled { return $true }
            Mock Test-WingetProbePathsOnDisk {
                $script:WingetGhostProbeCheckCount++
                return ($script:WingetGhostProbeCheckCount -ge 3)
            }
            Mock Get-BootstrapMsiHostilePendingRebootReasons { return @() }
            Mock Invoke-BootstrapGhostPackageRecovery { return $true }
            Mock Get-BootstrapProcessesByName { return @() }
            Mock Invoke-NativeWithRetry { return 0 }
            Mock Refresh-SessionPath {}
            Mock Write-Log {}

            { Ensure-WingetPackage -WingetPath 'fake.exe' -Id 'Test.Ghost' -DisplayName 'GhostPkg' -ProbePaths @('C:\fake\ghost.exe') } | Should Not Throw

            Assert-MockCalled Invoke-BootstrapGhostPackageRecovery -Times 1 -Exactly -Scope It
            Assert-MockCalled Invoke-NativeWithRetry -Times 1 -Scope It
        }

        It 'Ensure-WingetPackage nao faz ghost-recovery para runtimes protegidos' {
            Mock Test-WingetPackageInstalled { return $true }
            Mock Test-WingetProbePathsOnDisk { return $false }
            Mock Invoke-BootstrapGhostPackageRecovery { throw 'ghost-recovery nao deve rodar para runtime protegido' }
            Mock Invoke-NativeWithRetry { return 0 }
            Mock Refresh-SessionPath {}
            Mock Write-Log {}

            { Ensure-WingetPackage -WingetPath 'fake.exe' -Id 'Microsoft.VCRedist.2015+.x64' -DisplayName 'VC++' -ProbePaths @('C:\Windows\System32\vcruntime140.dll') } | Should Not Throw

            Assert-MockCalled Invoke-BootstrapGhostPackageRecovery -Times 0 -Exactly -Scope It
            Assert-MockCalled Invoke-NativeWithRetry -Times 0 -Exactly -Scope It
        }

        It 'Ensure-WingetPackage prossegue ghost-recovery quando reboot pendente nao bloqueia MSI' {
            $script:WingetGhostProbeCheckCount = 0
            Mock Test-WingetPackageInstalled { return $true }
            Mock Test-WingetProbePathsOnDisk {
                $script:WingetGhostProbeCheckCount++
                return ($script:WingetGhostProbeCheckCount -ge 3)
            }
            Mock Invoke-NativeWithRetry { return 0 }
            Mock Refresh-SessionPath {}
            Mock Write-Log {}
            Mock Get-BootstrapPendingRebootReasons { return @('Component Based Servicing') }
            Mock Get-BootstrapMsiHostilePendingRebootReasons { return @() }
            Mock Get-BootstrapProcessesByName { return @() }
            Mock Invoke-BootstrapGhostPackageRecovery { return $true }

            { Ensure-WingetPackage -WingetPath 'fake.exe' -Id 'Test.Ghost' -DisplayName 'GhostPkg' -ProbePaths @('C:\fake\ghost.exe') } | Should Not Throw
            Assert-MockCalled Get-BootstrapProcessesByName -Times 3 -Exactly -Scope It
        }

        It 'Invoke-BootstrapGhostPackageRecovery tenta --all-versions quando winget reporta multiplas versoes' {
            $root = Join-Path $env:TEMP ("phasezero-allversions-{0}" -f ([Guid]::NewGuid().ToString('N')))
            try {
                New-Item -Path $root -ItemType Directory -Force | Out-Null
                $childPath = Join-Path $root 'run.ps1'
                $stdoutPath = Join-Path $root 'out.txt'
                $stderrPath = Join-Path $root 'err.txt'
                $escapedScriptPath = $scriptPath.Replace("'", "''")
                $childScript = @(
                    ". '$escapedScriptPath' -BootstrapUiLibraryMode"
                    "function Write-Log { param([string]`$Message, [string]`$Level) }"
                    "`$script:allVersionsUninstallCalled = `$false"
                    "function Invoke-NativeWithRetry {"
                    "    param(`$Exe, [string[]]`$Args, `$OperationName)"
                    "    `$callArgs = @(`$PSBoundParameters['Args'])"
                    "    if (`$callArgs -contains '--all-versions') {"
                    "        `$script:allVersionsUninstallCalled = `$true"
                    "        return 0"
                    "    }"
                    "    return -1978335210"
                    "}"
                    "`$cleaned = Invoke-BootstrapGhostPackageRecovery -WingetPath 'fake.exe' -Id 'SST.OpenCodeDesktop' -DisplayName 'OpenCode Desktop'"
                    "'CLEANED=' + `$cleaned"
                    "'ALLVERSIONS=' + `$script:allVersionsUninstallCalled"
                    "if (-not `$cleaned) { exit 20 }"
                    "if (-not `$script:allVersionsUninstallCalled) { exit 21 }"
                    "exit 0"
                ) -join "`r`n"
                [System.IO.File]::WriteAllText($childPath, $childScript, [System.Text.UTF8Encoding]::new($false))
                $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $proc = Start-Process -FilePath $powershellExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$childPath) -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
                $stdout = Get-Content -Raw -LiteralPath $stdoutPath -ErrorAction SilentlyContinue
                $stderr = Get-Content -Raw -LiteralPath $stderrPath -ErrorAction SilentlyContinue

                $proc.ExitCode | Should Be 0
                $stdout | Should Match 'CLEANED=True'
                $stdout | Should Match 'ALLVERSIONS=True'
                [string]::IsNullOrWhiteSpace($stderr) | Should Be $true
            } finally {
                if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'Ensure-WingetPackage bloqueia quando ghost-recovery nao limpa estado' {
            Mock Test-WingetPackageInstalled { return $true }
            Mock Test-WingetProbePathsOnDisk { return $false }
            Mock Get-BootstrapPendingRebootReasons { return @() }
            Mock Invoke-BootstrapGhostPackageRecovery { return $false }
            Mock Invoke-NativeWithRetry { throw 'install nao deve ser chamado com ghost pendente' }
            Mock Refresh-SessionPath {}
            Mock Write-Log {}

            $caught = $null
            try {
                Ensure-WingetPackage -WingetPath 'fake.exe' -Id 'Test.Ghost' -DisplayName 'GhostPkg' -ProbePaths @('C:\fake\ghost.exe')
            } catch {
                $caught = $_
            }

            $caught | Should Not Be $null
            [string]$caught.Exception.Data['BootstrapStatus'] | Should Be 'blocked'
            [string]$caught.Exception.Data['BootstrapBlockerKind'] | Should Be 'winget-ghost-unresolved'
            [string]$caught.Exception.Data['BootstrapAction'] | Should Be 'manual-ghost-cleanup'
            Assert-MockCalled Invoke-NativeWithRetry -Times 0 -Exactly -Scope It
        }

        It 'Ensure-WingetPackage bloqueia sucesso winget sem binario em ProbePaths' {
            Mock Test-WingetPackageInstalled { return $false }
            Mock Test-WingetProbePathsOnDisk { return $false }
            Mock Invoke-NativeWithRetry { return 0 }
            Mock Refresh-SessionPath {}
            Mock Start-Sleep {}
            Mock Write-Log {}

            $caught = $null
            try {
                Ensure-WingetPackage -WingetPath 'fake.exe' -Id 'Test.NoBinary' -DisplayName 'NoBinaryPkg' -ProbePaths @('C:\fake\missing.exe')
            } catch {
                $caught = $_
            }

            $caught | Should Not Be $null
            [string]$caught.Exception.Data['BootstrapStatus'] | Should Be 'blocked'
            [string]$caught.Exception.Data['BootstrapBlockerKind'] | Should Be 'winget-post-install-unverified'
            [string]$caught.Exception.Data['BootstrapAction'] | Should Be 'inspect-or-reinstall'
            Assert-MockCalled Invoke-NativeWithRetry -Times 1 -Scope It
        }

        It 'Ensure-WingetPackage bloqueia sucesso winget sem pacote Appx esperado' {
            Mock Test-WingetPackageInstalled { return $false }
            Mock Test-BootstrapAppxPackageInstalled { return $false }
            Mock Invoke-NativeWithRetry { return 0 }
            Mock Refresh-SessionPath {}
            Mock Start-Sleep {}
            Mock Write-Log {}

            $caught = $null
            try {
                Ensure-WingetPackage -WingetPath 'fake.exe' -Id 'Microsoft.WindowsTerminal' -DisplayName 'Windows Terminal' -AppxPackageNames @('Microsoft.WindowsTerminal')
            } catch {
                $caught = $_
            }

            $caught | Should Not Be $null
            [string]$caught.Exception.Data['BootstrapStatus'] | Should Be 'blocked'
            [string]$caught.Exception.Data['BootstrapBlockerKind'] | Should Be 'winget-post-install-unverified'
            [string]$caught.Exception.Data['BootstrapAction'] | Should Be 'inspect-or-reinstall'
        }

        It 'Wait-BootstrapWingetMsiIdle retorna false quando MSI/Winget continuam ocupados' {
            Mock Get-BootstrapProcessesByName {
                return @([pscustomobject]@{ ProcessName = 'msiexec'; Id = 1234 })
            }
            Mock Start-Sleep {}
            Mock Write-Log {}

            $idle = Wait-BootstrapWingetMsiIdle -TimeoutSeconds 1 -HeartbeatSeconds 1

            $idle | Should Be $false
        }

        It 'Wait-BootstrapWingetMsiIdle ignora servicos stale de msiexec e WindowsPackageManagerServer' {
            $old = (Get-Date).AddHours(-2)
            Mock Get-BootstrapProcessesByName {
                param([string]$Name)
                if ($Name -eq 'msiexec') {
                    return @([pscustomobject]@{ ProcessName = 'msiexec'; Id = 2200; StartTime = $old; Path = ''; CommandLine = '' })
                }
                if ($Name -eq 'WindowsPackageManagerServer') {
                    return @([pscustomobject]@{ ProcessName = 'WindowsPackageManagerServer'; Id = 18356; StartTime = $old; Path = 'C:\Program Files\WindowsApps\WindowsPackageManagerServer.exe'; CommandLine = '"WindowsPackageManagerServer.exe" -Embedding' })
                }
                return @()
            }
            Mock Start-Sleep {}
            Mock Write-Log {}

            $idle = Wait-BootstrapWingetMsiIdle -TimeoutSeconds 1 -HeartbeatSeconds 1

            $idle | Should Be $true
        }
    }

    Context 'Invoke-NativeWithRetry soft-success exit codes' {
        It 'Exit code -1978335189 (UPDATE_NOT_APPLICABLE) curto-circuita retries' {
            Mock Invoke-NativeWithLog { return -1978335189 }
            Mock Write-Log {}
            $r = Invoke-NativeWithRetry -Exe 'fake.exe' -Args @('install') -OperationName 'pkg-test' -MaxAttempts 5 -InitialDelaySeconds 1 -SoftSuccessExitCodes $script:WingetSoftSuccessExitCodes
            $r | Should Be 0
            Assert-MockCalled Invoke-NativeWithLog -Times 1 -Exactly
        }

        It 'Sem SoftSuccessExitCodes, exit -1978335189 ainda dispara retries ate o limite' {
            Mock Invoke-NativeWithLog { return -1978335189 }
            Mock Write-Log {}
            Mock Start-Sleep {}
            $maxAttempts = 3
            $r = Invoke-NativeWithRetry -Exe 'fake.exe' -Args @('install-no-soft') -OperationName 'pkg-test-no-soft' -MaxAttempts $maxAttempts -InitialDelaySeconds 1
            $r | Should Be -1978335189
            # Filtro pelo arg unico deste teste para nao contar chamadas do It vizinho.
            Assert-MockCalled Invoke-NativeWithLog -ParameterFilter { $Args -contains 'install-no-soft' } -Times $maxAttempts -Exactly
        }

        It 'NonRetryableExitCodes corta retries de falha deterministica' {
            Mock Invoke-NativeWithLog { return -1978335216 }
            Mock Write-Log {}
            Mock Start-Sleep {}

            $r = Invoke-NativeWithRetry -Exe 'fake.exe' -Args @('install-no-applicable') -OperationName 'pkg-test-no-applicable' -MaxAttempts 5 -InitialDelaySeconds 1 -NonRetryableExitCodes @(-1978335216)

            $r | Should Be -1978335216
            Assert-MockCalled Invoke-NativeWithLog -ParameterFilter { $Args -contains 'install-no-applicable' } -Times 1 -Exactly
            Assert-MockCalled Write-Log -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'falha nao retentavel' } -Times 1 -Exactly
        }

        It 'retries native nonzero commands without terminating the PowerShell host' {
            $root = Join-Path $env:TEMP ("phasezero-native-retry-{0}" -f ([Guid]::NewGuid().ToString('N')))
            try {
                New-Item -Path $root -ItemType Directory -Force | Out-Null
                $cmdPath = Join-Path $root 'fail.cmd'
                $attemptsPath = Join-Path $root 'attempts.txt'
                $childPath = Join-Path $root 'run.ps1'
                $stdoutPath = Join-Path $root 'child.out'
                $stderrPath = Join-Path $root 'child.err'
                $logPath = Join-Path $root 'native.log'
                $cmdScript = @(
                    '@echo off'
                    "echo attempt>>`"$attemptsPath`""
                    'echo native failure'
                    'exit /b 7'
                ) -join "`r`n"
                [System.IO.File]::WriteAllText($cmdPath, $cmdScript, [System.Text.ASCIIEncoding]::new())
                $escapedScriptPath = $scriptPath.Replace("'", "''")
                $escapedLogPath = $logPath.Replace("'", "''")
                $escapedAttemptsPath = $attemptsPath.Replace("'", "''")
                $escapedCmdPath = $cmdPath.Replace("'", "''")
                $childScript = @"
. '{0}' -BootstrapUiLibraryMode
`$script:LogPath = '{1}'
function Start-Sleep {{ param([int]`$Seconds, [int]`$Milliseconds) }}
`$nativeExit = Invoke-NativeWithRetry -Exe `$env:ComSpec -Args @('/d','/s','/c','{2}') -OperationName 'native-retry-real' -MaxAttempts 2 -InitialDelaySeconds 1
Write-Output ('RETRY_EXIT=' + `$nativeExit)
if (`$nativeExit -ne 7) {{ exit 20 }}
if (@(Get-Content -LiteralPath '{3}').Count -ne 2) {{ exit 21 }}
if ((Get-Content -Raw -LiteralPath '{1}') -notmatch 'native failure') {{ exit 22 }}
exit 0
"@ -f $escapedScriptPath, $escapedLogPath, $escapedCmdPath, $escapedAttemptsPath
                [System.IO.File]::WriteAllText($childPath, $childScript, [System.Text.UTF8Encoding]::new($false))

                $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $proc = Start-Process -FilePath $powershellExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$childPath) -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

                $stdout = Get-Content -Raw -LiteralPath $stdoutPath -ErrorAction SilentlyContinue
                $stderr = Get-Content -Raw -LiteralPath $stderrPath -ErrorAction SilentlyContinue
                $proc.ExitCode | Should Be 0
                $stdout | Should Match 'RETRY_EXIT=7'
                [string]::IsNullOrWhiteSpace($stderr) | Should Be $true
            } finally {
                if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'Test-WingetSoftSuccessExit reconhece todos os codigos catalogados' {
            Test-WingetSoftSuccessExit -ExitCode -1978335189 | Should Be $true
            Test-WingetSoftSuccessExit -ExitCode -1978335212 | Should Be $false
            Test-WingetSoftSuccessExit -ExitCode -1978335215 | Should Be $true
            Test-WingetSoftSuccessExit -ExitCode 0 | Should Be $false
            Test-WingetSoftSuccessExit -ExitCode -1 | Should Be $false
        }
    }

    Context 'Test-WingetListOutputContainsId parser' {
        It 'casa Id em linha tabular real' {
            $output = @'
Name              Id                   Version  Source
-----------------------------------------------------
Python 3.13       Python.Python.3.13   3.13.13  winget
'@
            Test-WingetListOutputContainsId -Output $output -Id 'Python.Python.3.13' | Should Be $true
        }

        It 'NAO casa Id quando aparece apenas em frase de log narrativa' {
            $output = 'Foi encontrado um pacote existente ja instalado. Tentando atualizar o pacote instalado...'
            Test-WingetListOutputContainsId -Output $output -Id 'Python.Python.3.13' | Should Be $false
        }

        It 'NAO casa Id quando saida vazia' {
            Test-WingetListOutputContainsId -Output '' -Id 'X.Y' | Should Be $false
        }

        It 'ignora linha de cabecalho mesmo se Id se repete depois' {
            $output = "Name  Id  Version`nFoo  X.Y  1.0"
            Test-WingetListOutputContainsId -Output $output -Id 'X.Y' | Should Be $true
        }
    }

    Context 'Test-WingetProbePathsOnDisk' {
        It 'retorna true quando algum probe path existe' {
            Mock Test-Path { param($LiteralPath) return ($LiteralPath -eq 'C:\real\bin.exe') }
            Test-WingetProbePathsOnDisk -ProbePaths @('C:\nope\bin.exe', 'C:\real\bin.exe') | Should Be $true
        }

        It 'retorna false quando nenhum probe existe' {
            Mock Test-Path { return $false }
            Mock Get-ChildItem { return @() }
            Test-WingetProbePathsOnDisk -ProbePaths @('C:\a\bin.exe', 'C:\b\bin.exe') | Should Be $false
        }

        It 'retorna false para lista vazia' {
            Test-WingetProbePathsOnDisk -ProbePaths @() | Should Be $false
        }

        It 'expande $env: em paths antes de testar' {
            $expectedExpanded = [Environment]::ExpandEnvironmentVariables('%LOCALAPPDATA%\Programs\Foo\bin.exe')
            Mock Test-Path { param($LiteralPath) return ($LiteralPath -eq $expectedExpanded) }
            Test-WingetProbePathsOnDisk -ProbePaths @('$env:LOCALAPPDATA\Programs\Foo\bin.exe') | Should Be $true
        }
    }

    Context 'Ensure-WingetPackage curto-circuito por ProbePaths' {
        It 'Pula winget completamente quando binario ja existe em disco' {
            Mock Test-WingetProbePathsOnDisk { return $true }
            Mock Test-WingetPackageInstalled { throw 'nao deve ser chamado' }
            Mock Invoke-NativeWithRetry { throw 'nao deve ser chamado' }
            Mock Write-Log {}
            { Ensure-WingetPackage -WingetPath 'fake.exe' -Id 'Foo.Bar' -DisplayName 'Foo' -ProbePaths @('C:\real\foo.exe') } | Should Not Throw
            Assert-MockCalled Test-WingetProbePathsOnDisk -Times 1 -Exactly
            Assert-MockCalled Test-WingetPackageInstalled -Times 0 -Exactly
        }
    }

    Context 'Instaladores nao-winget com validacao de artefato' {
        It 'catalogo npm declara command validation para CLIs conhecidas' {
            $catalog = Get-BootstrapComponentCatalog
            $expected = @{
                'gemini-cli' = 'gemini'
                'kilo-cli' = 'kilo'
                'bonsai-cli' = 'bonsai'
                'grok-cli' = 'grok'
                'qwen-code' = 'qwen'
                'copilot-cli' = 'copilot'
                'codex-cli' = 'codex'
                'promptfoo' = 'promptfoo'
                'n8n' = 'n8n'
            }
            foreach ($name in @($expected.Keys)) {
                (Test-BootstrapMapContainsKey -Map $catalog -Key $name) | Should Be $true
                $commands = @()
                if ($catalog[$name].PSObject.Properties.Name -contains 'CommandNames') { $commands = @($catalog[$name].CommandNames) }
                (@($commands) -contains [string]$expected[$name]) | Should Be $true
            }
        }

        It 'Ensure-NpmGlobalPackage bloqueia quando comando declarado nao aparece apos npm install' {
            Mock Invoke-NpmWithLog { return 0 }
            Mock Resolve-CommandPath { return $null }
            Mock Write-Log {}
            $caught = $null

            try {
                Ensure-NpmGlobalPackage -NpmCmd 'npm.cmd' -Package '@openai/codex' -DisplayName 'Codex CLI' -CommandNames @('codex')
            } catch {
                $caught = $_
            }

            $caught | Should Not Be $null
            [string]$caught.Exception.Data['BootstrapStatus'] | Should Be 'blocked'
            [string]$caught.Exception.Data['BootstrapBlockerKind'] | Should Be 'npm-command-unverified'
            [string]$caught.Exception.Data['BootstrapAction'] | Should Be 'repair-node-path-or-reinstall'
        }

        It 'Ensure-ChocolateyPackage bloqueia quando ProbePaths nao aparece apos sucesso' {
            Mock Invoke-NativeWithLog { return 0 }
            Mock Test-WingetProbePathsOnDisk { return $false }
            Mock Write-Log {}
            $caught = $null

            try {
                Ensure-ChocolateyPackage -ChocoPath 'choco.exe' -Package 'glossi' -DisplayName 'GlosSI' -ProbePaths @('C:\missing\GlosSIConfig.exe')
            } catch {
                $caught = $_
            }

            $caught | Should Not Be $null
            [string]$caught.Exception.Data['BootstrapStatus'] | Should Be 'blocked'
            [string]$caught.Exception.Data['BootstrapBlockerKind'] | Should Be 'chocolatey-post-install-unverified'
            [string]$caught.Exception.Data['BootstrapAction'] | Should Be 'inspect-or-reinstall'
        }
    }

    Context 'OpenClaw request grant gate' {
        It 'blocks explicit install before npm probes or mutation' {
            $npm = Join-Path $TestDrive 'npm.cmd'
            Mock Invoke-NpmWithLog { throw 'npm must not run' }
            Mock Invoke-NativeFirstLine { throw 'OpenClaw must not run' }
            Mock Ensure-BootstrapNodeCore { throw 'Node setup must not run' }

            $ensureMessage = ''
            try { Ensure-OpenClaw -NpmCmd $npm } catch { $ensureMessage = [string]$_.Exception.Message }
            $ensureMessage | Should Match 'connection-grant-not-enforceable'

            $componentMessage = ''
            try { Invoke-BootstrapComponent -Name 'openclaw' -State @{ Completed = @{} } } catch { $componentMessage = [string]$_.Exception.Message }
            $componentMessage | Should Match 'connection-grant-not-enforceable'

            Assert-MockCalled Invoke-NpmWithLog -Times 0 -Exactly
            Assert-MockCalled Invoke-NativeFirstLine -Times 0 -Exactly
            Assert-MockCalled Ensure-BootstrapNodeCore -Times 0 -Exactly
        }
    }
}
