$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

Describe 'Bootstrap quality gates' {
    It 'keeps PSScriptAnalyzer errors at zero and warnings within the tracked baseline' {
        $module = Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $module) {
            throw 'PSScriptAnalyzer not found. Install with: Install-Module PSScriptAnalyzer -Scope CurrentUser -Force'
        }

        Import-Module PSScriptAnalyzer -Force
        $trackedPs1 = @(& git -C $repoRoot ls-files '*.ps1')
        if (@($trackedPs1).Count -eq 0) {
            throw 'No tracked PowerShell files found for PSScriptAnalyzer budget.'
        }

        $results = @()
        foreach ($relativePath in @($trackedPs1)) {
            $fullPath = Join-Path $repoRoot $relativePath
            $results += @(Invoke-ScriptAnalyzer -Path $fullPath -Severity Warning,Error -ExcludeRule 'PSUseShouldProcessForStateChangingFunctions','PSAvoidUsingInvokeExpression')
        }

        $errors = @($results | Where-Object { $_.Severity -eq 'Error' })
        $warnings = @($results | Where-Object { $_.Severity -eq 'Warning' })
        $errorText = (($errors | Select-Object ScriptName, Line, RuleName, Message | Format-Table -AutoSize | Out-String).Trim())
        $errorText | Should Be ''
        if ($warnings.Count -gt 0) {
            Write-Host "PSScriptAnalyzer warnings: $($warnings.Count) (rules: $((@($warnings | Select-Object -ExpandProperty RuleName -Unique)).Count))"
            $warnings | Group-Object RuleName | Sort-Object Count -Descending | ForEach-Object {
                Write-Host ("  {0,5}  {1}" -f $_.Count, $_.Name)
            }
        }
        # Baseline medida com PSScriptAnalyzer 1.25.0: 921 warnings no Windows
        # Server 2025 runner atual. Errors continuam em 0; qualquer warning novo
        # precisa atualizar o baseline com evidencia e revisao do delta.
        ([int]$warnings.Count -le 921) | Should Be $true
    }

    It 'keeps mutating bootstrap functions registered or explicitly allow-listed' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $scriptPath), [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            throw (($errors | ForEach-Object { $_.Message }) -join '; ')
        }

        $mutatingCommands = @(
            'Set-ItemProperty',
            'New-ItemProperty',
            'Remove-ItemProperty',
            'Set-Service',
            'Remove-Item'
        )
        $allowList = @(
            'Invoke-BootstrapRollback',
            'Invoke-BootstrapAutoRollback',
            'Reset-BootstrapFileCmdlets',
            'Get-BootstrapWslStatusProbe',
            'Install-BootstrapSteamDeckShellMenu',
            'Get-BootstrapDockerInstallInfo',
            'Install-BootstrapNotepadPlusPlusPlugin',
            'Invoke-WingetListIdProbe',
            'Ensure-Goose',
            'Ensure-OpenClaw',
            'Repair-BootstrapFastStartup',
            'Test-BootstrapDirectoryWritable',
            'Ensure-BootstrapSteamDeckToolsRuntime',
            'Ensure-BootstrapChocolateyCore',
            'Write-BootstrapAtomicText',
            'Install-BootstrapRtkTool',
            'Uninstall-BootstrapRtkTool',
            'Uninstall-BootstrapAiUsagebar',
            'Install-BootstrapAiUsagebarViaCargo',
            'Unlock-BootstrapSecretsFile',
            'Clear-BootstrapDirectoryContents',
            'Invoke-BootstrapHostHealthCleanup',
            'Disable-BootstrapRunEntries',
            'Set-BootstrapServiceStartupTypes',
            'Invoke-BootstrapHostHealthTelemetry',
            'Invoke-NativeFirstLine',
            'New-BootstrapSupportBundle',
            'New-BootstrapReleasePack',
            'Write-BootstrapAiProxyEnvFile',
            'Clear-BootstrapPlaywrightStaleLock',
            'Expand-BootstrapZipArchiveSafe',
            'Install-BootstrapAiMemoryViaRelease',
            'Uninstall-BootstrapAiMemory',
            'Install-BootstrapAmdDriverRelease',
            'Resolve-BootstrapWebAppIconLocation'
        )

        $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $unexpected = @()
        foreach ($functionAst in $functions) {
            $commands = @($functionAst.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object {
                    $name = $_.GetCommandName()
                    if ([string]::IsNullOrWhiteSpace($name)) { return }
                    (($name -split '\\')[-1])
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            $hasMutation = (@($commands | Where-Object { $mutatingCommands -contains $_ }).Count -gt 0)
            if (-not $hasMutation) { continue }

            $hasChangeRegistration = (@($commands | Where-Object { $_ -in @('Register-BootstrapChange', 'Register-BootstrapFileChange') }).Count -gt 0)
            if ($hasChangeRegistration) { continue }

            if ($allowList -notcontains $functionAst.Name) {
                $unexpected += ('{0}:{1}' -f $functionAst.Name, $functionAst.Extent.StartLineNumber)
            }
        }

        (($unexpected | Sort-Object) -join "`n") | Should Be ''
    }
}
