$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$uiScriptPath = Join-Path $repoRoot 'bootstrap-ui.ps1'

function Import-UiFunctionsForTest {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    $raw = Get-Content -Path $uiScriptPath -Raw
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ($errors | Out-String) }

    foreach ($name in $Names) {
        $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if (-not $functionAst) { throw ("Function not found: {0}" -f $name) }
        Invoke-Expression ("function global:{0} {1}" -f $name, $functionAst.Body.Extent.Text)
    }
}

function New-TestDataRoot {
    return (Join-Path $env:TEMP ("bootstrap_ui_{0}" -f ([Guid]::NewGuid().ToString('N'))))
}

function Remove-TestDataRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Microsoft.PowerShell.Management\Test-Path $Path) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Bootstrap UI launcher' {
    BeforeEach {
        $script:TestDataRoot = New-TestDataRoot
    }

    AfterEach {
        Remove-TestDataRoot -Path $script:TestDataRoot
        Remove-Variable -Scope Script -Name TestDataRoot -ErrorAction SilentlyContinue
    }

    It 'routes MCP repair through an artifact-producing command instead of direct synchronous repair' {
        $raw = Get-Content -LiteralPath $uiScriptPath -Raw

        $raw | Should Match 'HealthRepairMcpButton\.Add_Click'
        $raw | Should Match '--repair-mcp'
        $raw | Should Match '--result-path'
        $raw | Should Match '--log-path'
        $raw | Should Not Match '\$result\s*=\s*Invoke-BootstrapMcpConfigRepair\s*\r?\n\s*\$verify\s*=\s*Invoke-BootstrapMcpConfigRepair -DryRun'
    }

    It 'agrupa os perfis por familia na arvore de perfis (Servidor caseiro)' {
        $raw = Get-Content -LiteralPath $uiScriptPath -Raw

        $raw | Should Match '\$familyNodes'
        $raw | Should Match '\$profile\.family'
        $raw | Should Match '\$familyNodes\[\$familyName\]\.Items\.Add'
    }

    It 'supports smoke test execution from Windows PowerShell file mode' {
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $uiStatePath = Join-Path $script:TestDataRoot 'ui-state.json'
        $uiLogPath = Join-Path $script:TestDataRoot 'bootstrap-ui.log'

        $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $uiScriptPath -UiStatePath $uiStatePath -UiLogPath $uiLogPath -SmokeTest 2>&1
        $exitCode = $LASTEXITCODE
        $text = ((@($output) -join [Environment]::NewLine)).Trim()

        $exitCode | Should Be 0
        ([string]::IsNullOrWhiteSpace($text)) | Should Be $false

        $result = $text | ConvertFrom-Json -ErrorAction Stop
        (@($result.pages) -contains 'welcome') | Should Be $true
        (@($result.pages) -contains 'health') | Should Be $true
        (@($result.pages) -contains 'app-tuning') | Should Be $true
        (@($result.pages) -contains 'api-center') | Should Be $true
        (@($result.pages) -contains 'api-catalog') | Should Be $true
        (@($result.languages) -contains 'pt-BR') | Should Be $true
        $result.statePath | Should Be $uiStatePath
        (Test-Path $uiStatePath) | Should Be $true

        $state = Get-Content -LiteralPath $uiStatePath -Raw | ConvertFrom-Json
        @($state.selectedProfiles) | Should Be @('safe-base')
        [string]$state.hostHealth | Should Be 'off'
        [string]$state.appTuningMode | Should Be 'off'
    }

    It 'loads full WPF window wiring after backend import' {
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $uiStatePath = Join-Path $script:TestDataRoot 'ui-state.json'
        $uiLogPath = Join-Path $script:TestDataRoot 'bootstrap-ui.log'

        $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -STA -File $uiScriptPath -UiStatePath $uiStatePath -UiLogPath $uiLogPath -SmokeTestWindow 2>&1
        $exitCode = $LASTEXITCODE
        $text = ((@($output) -join [Environment]::NewLine)).Trim()

        $exitCode | Should Be 0
        ([string]::IsNullOrWhiteSpace($text)) | Should Be $false

        $result = $text | ConvertFrom-Json -ErrorAction Stop
        [bool]$result.windowLoaded | Should Be $true
        [bool]$result.handlersRegistered | Should Be $true
        (@($result.pages) -contains 'health') | Should Be $true
    }

    It 'normalizes persisted artifact paths to strings during state roundtrip' {
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $uiStatePath = Join-Path $script:TestDataRoot 'ui-state.json'
        $uiLogPath = Join-Path $script:TestDataRoot 'bootstrap-ui.log'
        New-Item -ItemType Directory -Force -Path $script:TestDataRoot | Out-Null
        $seedState = [ordered]@{
            selectedProfiles = @('safe-base')
            lastLogPath = [ordered]@{ Length = 12 }
            lastResultPath = [ordered]@{ Length = 13 }
            lastReportPath = [ordered]@{ Length = 14 }
        }
        [System.IO.File]::WriteAllText($uiStatePath, ($seedState | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))

        $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $uiScriptPath -UiStatePath $uiStatePath -UiLogPath $uiLogPath -SmokeTest 2>&1
        $LASTEXITCODE | Should Be 0
        $null = ((@($output) -join [Environment]::NewLine).Trim()) | ConvertFrom-Json -ErrorAction Stop
        $state = Get-Content -LiteralPath $uiStatePath -Raw | ConvertFrom-Json

        [string]$state.lastLogPath | Should Be ''
        [string]$state.lastResultPath | Should Be ''
        [string]$state.lastReportPath | Should Be ''
        ($state.lastLogPath -is [pscustomobject]) | Should Be $false
        ($state.lastResultPath -is [pscustomobject]) | Should Be $false
        ($state.lastReportPath -is [pscustomobject]) | Should Be $false
    }

    It 'keeps the embedded XAML parseable' {
        $raw = Get-Content -Path $uiScriptPath -Raw
        $match = [regex]::Match($raw, '(?s)\[xml\]\$xaml = @''\r?\n(.*?)\r?\n''@')

        $match.Success | Should Be $true
        { [xml]$null = $match.Groups[1].Value } | Should Not Throw
    }

    It 'does not use closure snapshots for UI event wiring' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Not Match '\.GetNewClosure\(\)'
    }

    It 'loads the embedded XAML with the WPF runtime' {
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $script = @"
`$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace(`$env:WINDIR) -and -not [string]::IsNullOrWhiteSpace(`$env:SystemRoot)) { `$env:WINDIR = `$env:SystemRoot }
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
`$raw = Get-Content -Path '$uiScriptPath' -Raw
`$match = [regex]::Match(`$raw, '(?s)\[xml\]\`$xaml = @''\r?\n(.*?)\r?\n''@')
if (-not `$match.Success) { throw 'XAML block not found' }
`$reader = New-Object System.Xml.XmlNodeReader ([xml]`$match.Groups[1].Value)
`$null = [Windows.Markup.XamlReader]::Load(`$reader)
'WPF_XAML_OK'
"@

        $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -STA -Command $script

        (@($output) -join [Environment]::NewLine).Trim() | Should Be 'WPF_XAML_OK'
    }

    It 'keeps grid and dropdown text readable in the dark theme' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'SystemColors\.WindowBrushKey'
        $raw | Should Match 'SystemColors\.WindowTextBrushKey'
        $raw | Should Match 'SystemColors\.HighlightTextBrushKey'
        $raw | Should Match 'TargetType="ListBoxItem"'
        $raw | Should Match 'TargetType="ComboBoxItem"'
        $raw | Should Match 'TargetType="DataGridColumnHeader"'
        $raw | Should Match 'TargetType="DataGridCell"'
        $raw | Should Match 'SelectionBrush'
        $raw | Should Match 'CaretBrush'
        $raw | Should Not Match 'LightSlateGray'
    }

    It 'exposes unknown external display classification actions' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'PendingExternalStatusLabel'
        $raw | Should Match 'ClassifyMonitorButton'
        $raw | Should Match 'ClassifyTvButton'
        $raw | Should Match 'Monitor/Dev'
        $raw | Should Match 'TV/Game'
    }

    It 'guards run execution against duplicate starts and missing result files' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'PageHealth'
        $raw | Should Match 'HealthDoctorButton'
        $raw | Should Match 'HealthSupportBundleButton'
        $raw | Should Match 'HealthRepairPlanButton'
        $raw | Should Match 'HealthDeckStatusText'
        $raw | Should Match 'HealthGithubStatusText'
        $raw | Should Match 'doctor\.deck'
        $raw | Should Match 'doctor\.githubCliAuth'
        $raw | Should Match 'Get-UiGithubCliStatusTextFromResult'
        $raw | Should Match 'Start-RunExecution -MaintenanceIntent ''doctor'''
        $raw | Should Match 'Start-RunExecution -MaintenanceIntent ''support-bundle'''
        $raw | Should Match 'Start-RunExecution -MaintenanceIntent ''repair-plan'''
        $raw | Should Match 'DispatcherUnhandledException'
        $raw | Should Match 'Append-RunLog'
        $raw | Should Match 'LogTimer tick'
        $raw | Should Match 'Complete-RunExecutionWithoutResult'
        $raw | Should Match '\$ui\.RunProcess -and -not \$ui\.RunProcess\.HasExited'
        $raw | Should Match '\$ui\.StartRunButton\.IsEnabled = \$false'
        $raw | Should Match '\$ui\.StartRunButton\.IsEnabled = \$true'
        $raw | Should Match 'fallbackResult'
        $raw | Should Match 'Backend saiu sem result\.json'
        $raw | Should Match 'artifactPaths'
        $raw | Should Match 'diagnostics'
        $raw | Should Match 'scope'
        $raw | Should Match 'rollback'
        $raw | Should Match 'function Start-RunExecution'
        $raw | Should Match '\[string\]\$MaintenanceIntent = ''none'''
        $raw | Should Match 'Start-RunExecution -MaintenanceIntent ''audit'''
        $raw | Should Match 'Start-RunExecution -MaintenanceIntent ''rollback'''
        $raw | Should Match 'MaintenanceMode\s+=\s+''none'''
        $raw | Should Match 'Write-UiFallbackResult'
        $raw | Should Match 'Falha ao iniciar backend'
        $raw | Should Match 'Processo elevado encerrou antes do backend inicializar'
        $raw | Should Match 'Read-UiBackendResultWithRetry'
        $raw | Should Match 'Get-UiRunStatusTextFromResult'
    }

    It 'finalizes a ready result when LogTimer process polling throws' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'LogTimer tick'
        $raw | Should Match '(?s)catch \{\s*try \{\s*Write-UiLog.*?Test-UiBackendResultFileReady -Path \(\[string\]\$ui\.CurrentResultPath\).*?Finalize-RunFromResult.*?return'
        $raw | Should Match '(?s)catch \{\s*try \{\s*Write-UiLog.*?Complete-RunExecutionWithoutResult.*?return'
    }

    It 'renders Health as an operational dashboard with all required cards and actions' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        foreach ($controlName in @(
            'HealthWslStatusText',
            'HealthWingetStatusText',
            'HealthRebootStatusText',
            'HealthSecretsStatusText',
            'HealthGithubStatusText',
            'HealthAiUsagebarStatusText',
            'HealthAiMemoryStatusText',
            'HealthAionUiStatusText',
            'HealthDeckStatusText',
            'HealthRollbackStatusText',
            'HealthCopyDiagnosticButton'
        )) {
            $raw | Should Match $controlName
        }
        foreach ($label in @('WSL','winget','Reinício','Chaves','GitHub CLI','ai-usagebar','ai-memory','AionUI','Steam Deck','Reversão')) {
            $raw | Should Match ([regex]::Escape($label))
        }
        foreach ($statusText in @('OK','Aten.*o','Cr.*tico','Ausente','Bloqueado')) {
            $raw | Should Match $statusText
        }
        $raw | Should Match 'Start-RunExecution -MaintenanceIntent ''doctor'''
        $raw | Should Match 'Start-RunExecution -MaintenanceIntent ''support-bundle'''
        $raw | Should Match 'Start-RunExecution -MaintenanceIntent ''repair-plan'''
        $raw | Should Match 'Copy-HealthDiagnostic'
    }

    It 'maps Doctor result fields into Health card status text' {
        Import-UiFunctionsForTest -Names @('Get-UiHealthStatusLabel','Get-UiDoctorCheckById','Get-UiHealthCardStatusText')

        $result = [pscustomobject]@{
            doctor = [pscustomobject]@{
                checks = @(
                    [pscustomobject]@{ id = 'winget'; status = 'healthy'; summary = 'winget ok' },
                    [pscustomobject]@{ id = 'pending-reboot'; status = 'warning'; pending = $true; summary = 'reboot pending' },
                    [pscustomobject]@{ id = 'rollback-gate'; status = 'healthy'; summary = 'rollback ok' }
                )
                secrets = [pscustomobject]@{ providers = @([pscustomobject]@{ provider = 'openai'; status = 'present' }) }
                aiUsagebar = [pscustomobject]@{ installed = $true; configured = $true; primaryVendor = 'openrouter' }
                aionui = [pscustomobject]@{ installed = $true; providersConfigured = @('openai','gemini'); providersRejected = @('openrouter'); configStatus = 'manual' }
                wslRepair = [pscustomobject]@{ status = 'blocked'; corruptionKind = 'REGDB_E_CLASSNOTREG'; recommendedAction = 'repair elevated' }
            }
        }

        (Get-UiHealthCardStatusText -Result $result -Card 'wsl') | Should Match 'Bloqueado.*REGDB_E_CLASSNOTREG'
        (Get-UiHealthCardStatusText -Result $result -Card 'winget') | Should Match 'OK.*winget ok'
        (Get-UiHealthCardStatusText -Result $result -Card 'reboot') | Should Match 'Aten.*o.*reboot pending'
        (Get-UiHealthCardStatusText -Result $result -Card 'secrets') | Should Match 'OK'
        (Get-UiHealthCardStatusText -Result $result -Card 'ai-usagebar') | Should Match 'OK.*openrouter'
        (Get-UiHealthCardStatusText -Result $result -Card 'aionui') | Should Match 'Aten.*o.*openrouter'
        (Get-UiHealthCardStatusText -Result $result -Card 'rollback') | Should Match 'OK.*rollback ok'
    }

    It 'formats blocked result status by blocker action instead of always saying reboot' {
        Import-UiFunctionsForTest -Names @('Get-UiRunStatusTextFromResult')
        $strings = [pscustomobject]@{
            RunCompleted = 'Execução concluída.'
            RunFailed = 'Execução falhou.'
        }

        $reboot = Get-UiRunStatusTextFromResult -Result ([pscustomobject]@{
                status = 'blocked'
                blockerKind = 'pending-reboot-msi'
                action = 'restart-required'
                error = 'reboot required'
                howToFix = 'restart'
            }) -Strings $strings
        $ghost = Get-UiRunStatusTextFromResult -Result ([pscustomobject]@{
                status = 'blocked'
                blockerKind = 'winget-ghost-unresolved'
                action = 'manual-ghost-cleanup'
                error = 'ghost'
                howToFix = 'cleanup'
            }) -Strings $strings

        $reboot | Should Match 'Rein.*cio necess.*rio'
        $ghost | Should Match 'A.*necess.*ria'
        $ghost | Should Not Match 'Rein.cio necess.rio'
    }

    It 'quotes backend arguments containing shell-sensitive characters' {
        Import-UiFunctionsForTest -Names @('ConvertTo-CommandLineArgument','ConvertTo-ArgumentString')

        $line = ConvertTo-ArgumentString -Tokens @('plain','C:\Path With Space\tool.ps1','A&B','Group(Value)','caret^value','he said "hi"')

        $line | Should Be 'plain "C:\Path With Space\tool.ps1" "A&B" "Group(Value)" "caret^value" "he said \"hi\""'
    }

    It 'waits until result json is parseable instead of accepting a partial file' {
        Import-UiFunctionsForTest -Names @('Read-UiBackendResultWithRetry')
        $path = Join-Path $script:TestDataRoot 'partial.result.json'
        $null = New-Item -Path $script:TestDataRoot -ItemType Directory -Force
        [System.IO.File]::WriteAllText($path, '{"status":', [System.Text.UTF8Encoding]::new($false))
        $job = Start-Job -ScriptBlock {
            param([string]$ResultPath)
            Start-Sleep -Milliseconds 120
            [System.IO.File]::WriteAllText($ResultPath, '{"status":"success","exitCode":0}', [System.Text.UTF8Encoding]::new($false))
        } -ArgumentList $path
        try {
            $result = Read-UiBackendResultWithRetry -Path $path -MaxWaitMs 6000 -StepMs 100
        } finally {
            Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }

        [string]$result.status | Should Be 'success'
        [int]$result.exitCode | Should Be 0
    }

    It 'constrains Steam Deck monitor mode editing to supported modes' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        ([regex]::Matches($raw, 'DataGridComboBoxColumn Header="Perfil"').Count -ge 2) | Should Be $true
        $raw | Should Match 'HANDHELD'
        $raw | Should Match 'DOCKED_MONITOR'
        $raw | Should Match 'DOCKED_TV'
        $raw | Should Match 'Validate-SteamDeckGridModeRows'
    }

    It 'lists the internal Steam Deck display with primary flag and real status columns' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'Get-UiSteamDeckProfileRows'
        $raw | Should Match 'target = ''internal'''
        $raw | Should Match 'Header="Principal"'
        $raw | Should Match 'Header="Status"'
        $raw | Should Match 'desativado: so desktop externo'
    }

    It 'exposes configurable Windows display modes with extend as the safe default' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'SteamDeckDisplayModes'
        $raw | Should Match '<sys:String>extend</sys:String>'
        $raw | Should Match '<sys:String>internal</sys:String>'
        $raw | Should Match '<sys:String>external</sys:String>'
        $raw | Should Match '<sys:String>clone</sys:String>'
        $raw | Should Match '\$settings\[''displayMode''\] = \$displayMode'
    }

    It 'keeps API organization and project reference separate' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'ApiProjectRefTextBox'
        $raw | Should Match 'projectRef = \$ui\.ApiProjectRefTextBox\.Text\.Trim\(\)'
        $raw | Should Not Match 'projectRef = \$ui\.ApiOrganizationTextBox\.Text\.Trim\(\)'
    }

    It 'exposes a full API key catalog page with requested columns' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'ApiCatalogButton'
        $raw | Should Match 'PageApiCatalog'
        $raw | Should Match 'ApiFullCatalogGrid'
        $raw | Should Match 'Refresh-ApiCatalogControls'
        foreach ($header in @('Ja possui','Quantidade','Configuradas','Provedor','O que faz','Voce vai precisar','Criar Chave','Ajuda')) {
            $raw | Should Match ([regex]::Escape(('Header="{0}"' -f $header)))
        }
    }

    It 'exposes AppTuning page with category and item selection controls' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match '<ScrollViewer x:Name="PageAppTuning"'
        $raw | Should Match 'ClearAllSelectionButton'
        $raw | Should Match 'Clear-UiAllSelections'
        $raw | Should Match 'AppTuningModeCombo'
        $raw | Should Match 'AppTuningSearchBox'
        $raw | Should Match 'AppTuningStatusFilterCombo'
        $raw | Should Match 'AppTuningCategoryList'
        $raw | Should Match 'AppTuningItemsGrid'
        $raw | Should Match 'Refresh-AppTuningControls'
        foreach ($header in @('Ativo','Categoria','App','Otimização','Perfil','Risco','Instalado','Configurado','Atualizado','Admin')) {
            $raw | Should Match ([regex]::Escape(('Header="{0}"' -f $header)))
        }
        foreach ($buttonName in @('AppTuningRecommendedButton','AppTuningMarkCategoryButton','AppTuningClearCategoryButton','AppTuningAuditButton','AppTuningClearAllButton','AppTuningInstallButton','AppTuningConfigureButton','AppTuningUpdateButton','AppTuningRunNowButton')) {
            $raw | Should Match $buttonName
        }
        $raw | Should Match 'Get-BootstrapAppTuningStatusRows'
        $raw | Should Not Match 'Apps sob demanda'
        $raw | Should Match 'Invoke-AppTuningSingleRowAction'
        $raw | Should Match 'Add_MouseDoubleClick'
    }

    It 'uses checked AppTuning rows for toolbar actions instead of the highlighted row' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'Get-CheckedAppTuningRowList'
        $raw | Should Match 'Complete-UiGridEdit'
        $raw | Should Match 'Queue-AppTuningInstallOrUpdate -ActionName ''Instalação'' -Rows @\(Get-CheckedAppTuningRowList\)'
        $raw | Should Match 'Queue-AppTuningConfigure -Rows @\(Get-CheckedAppTuningRowList\)'
        $raw | Should Match 'Queue-AppTuningInstallOrUpdate -ActionName ''Atualização'' -Rows @\(Get-CheckedAppTuningRowList\)'
    }

    It 'adds explicit checkbox selection and multi-tool actions to AI Coding Tools' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'selectedAiTools'
        $raw | Should Match 'DataGridCheckBoxColumn Header="Ativo"'
        $raw | Should Match 'SelectionMode="Extended"'
        $raw | Should Match 'Read-AiToolSelectionFromControl'
        $raw | Should Match 'Get-SelectedAiToolNameList'
        $raw | Should Match 'foreach \(\$toolName in @\(\$toolNames\)\)'
        $raw | Should Match 'Load-WpfGridRows -Grid \$ui\.AiToolsGrid -Items \$viewRows -Columns @\(''active'',''tool'''
    }

    It 'surfaces AppTuning risk controls and security-impact confirmation' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'AppTuningRiskFilterCombo'
        $raw | Should Match 'AppTuningRiskWarningLabel'
        $raw | Should Match 'SecurityImpact'
        $raw | Should Match 'rollbackScope'
        $raw | Should Match 'Confirm-AppTuningSecurityImpact'
        $raw | Should Match 'impacto de segurança'
        foreach ($risk in @('conservative','advanced','aggressive')) {
            $raw | Should Match $risk
        }
    }

    It 'surfaces component safety badges from the UI contract' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        foreach ($expected in @('Seguro','Experimental','Manual','Requer GPU','Requer login')) {
            $raw | Should Match $expected
        }
        foreach ($field in @('riskLevel','manualReason','requiresGpu','requiresInteractiveLogin','officialSource')) {
            $raw | Should Match $field
        }
    }

    It 'surfaces compact AppTuning badges and artifact actions in the UI' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'Header="Selos"'
        $raw | Should Match 'Binding="\{Binding badges\}"'
        foreach ($buttonName in @('AppTuningOpenFolderButton','AppTuningViewLogButton')) {
            $raw | Should Match $buttonName
        }
        foreach ($badge in @('Docker','BYOK','Seguro','Manual')) {
            $raw | Should Match $badge
        }
    }

    It 'exposes Windows Boot Manager controls beyond GRUB detection' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        foreach ($name in @('WindowsBootEntriesGrid','WindowsBootDefaultCombo','WindowsBootTimeoutTextBox','ApplyWindowsBootButton','BackupWindowsBootButton')) {
            $raw | Should Match $name
        }
        $raw | Should Match 'Get-BootstrapWindowsBootManagerState'
        $raw | Should Match 'Set-BootstrapWindowsBootManager'
    }

    It 'persists AppTuning state fields and passes them to preview/backend' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        foreach ($stateField in @('appTuningMode','selectedAppTuningCategories','selectedAppTuningItems','excludedAppTuningItems')) {
            $raw | Should Match $stateField
        }
        $raw | Should Match '-RequestedAppTuningMode'
        $raw | Should Match '-AppTuningCategory'
        $raw | Should Match '-ExcludeAppTuningItem'
    }

    It 'loads ordered dictionary rows into WPF grids' {
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $script = @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace(`$env:WINDIR) -and -not [string]::IsNullOrWhiteSpace(`$env:SystemRoot)) { `$env:WINDIR = `$env:SystemRoot }
Add-Type -AssemblyName PresentationFramework
`$raw = Get-Content -Path '$uiScriptPath' -Raw
`$tokens = `$null
`$errors = `$null
`$ast = [System.Management.Automation.Language.Parser]::ParseInput(`$raw, [ref]`$tokens, [ref]`$errors)
if (`$errors.Count -gt 0) { throw (`$errors | Out-String) }
`$functionAst = `$ast.Find({ param(`$node) `$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and `$node.Name -eq 'Load-WpfGridRows' }, `$true)
if (-not `$functionAst) { throw 'Load-WpfGridRows not found' }
Invoke-Expression `$functionAst.Extent.Text
`$grid = New-Object System.Windows.Controls.DataGrid
Load-WpfGridRows -Grid `$grid -Items @([ordered]@{ provider = 'OpenAI'; total = '1' }) -Columns @('provider', 'total')
`$row = `$grid.ItemsSource[0].Row
('{0}|{1}' -f [string]`$row['provider'], [string]`$row['total'])
"@

        $output = & $powershellExe -NoProfile -STA -Command $script

        (@($output) -join [Environment]::NewLine).Trim() | Should Be 'OpenAI|1'
    }

    It 'anchors API credentials and Steam Deck monitor grids at the top of their cards' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match '(?s)<Border Grid\.Column="0" Style="\{StaticResource Card\}">\s*<StackPanel>\s*<TextBlock x:Name="ApiCredentialsLabel"'
        $raw | Should Match '(?s)<TextBlock x:Name="MonitorProfilesLabel"[^>]+/>\s*<DataGrid\s+x:Name="MonitorProfilesGrid"'
        $raw | Should Match '(?s)<TextBlock x:Name="MonitorFamiliesLabel"[^>]+/>\s*<DataGrid\s+x:Name="MonitorFamiliesGrid"'
    }

    It 'shows profile-resolved components as checked in the install column' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'Get-UiResolvedComponentNameSet'
        $raw | Should Match 'resolvedComponentLookup'
        $raw | Should Match '\$cb\.IsChecked = \(\(\$isExplicitComponent -or \$isResolvedComponent\) -and -not \$isExcludedComponent\)'
        $raw | Should Match 'Desmarcar item vindo de perfil adiciona em N.*instalar'
    }

    It 'shows actionable selection impact and rollback metadata' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'Get-UiSelectionImpact'
        $raw | Should Match 'Get-UiComponentImpact'
        $raw | Should Match 'Selecionados:'
        $raw | Should Match 'RollbackNotes'
        $raw | Should Match 'SelectionErrorLabel\.Text = \$message'
    }

    It 'surfaces resilient run artifacts and rollback availability' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'Update-RunArtifactButtons'
        $raw | Should Match 'rollbackAvailable'
        $raw | Should Match 'howToFix'
        $raw | Should Match 'Reversão disponível'
    }

    It 'captures elevated backend stdout and stderr inside the elevated process' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'Build-ElevatedBackendCommand'
        $raw | Should Match 'CurrentStdoutPath'
        $raw | Should Match 'CurrentStderrPath'
        $raw | Should Match '1>'
        $raw | Should Match '2>'
        $raw | Should Not Match 'Backend stream redirection disabled because elevation uses ShellExecute'
    }

    It 'keeps backend parameter names unquoted in the elevated command' {
        Import-UiFunctionsForTest -Names @('ConvertTo-PowerShellLiteral','Get-UiBackendParameterBindingSpec','ConvertTo-ElevatedBackendInvocationParts','Get-UiBackendTokenValue','New-UiElevatedBackendWrapperCommand','Build-ElevatedBackendCommand')
        $scriptPath = Join-Path $script:TestDataRoot 'Dir & (A)\probe.ps1'
        $resultPath = Join-Path $script:TestDataRoot 'Result Dir\result.json'
        $stdoutPath = Join-Path $script:TestDataRoot 'Streams\stdout.log'
        $stderrPath = Join-Path $script:TestDataRoot 'Streams\stderr.log'
        $global:ui = [pscustomobject]@{
            CurrentStdoutPath = $stdoutPath
            CurrentStderrPath = $stderrPath
        }

        try {
            $tokens = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,'-NonInteractive','-Profile','full','-ResultPath',$resultPath)
            $elevated = Build-ElevatedBackendCommand -BackendTokens $tokens
            $command = [string]$elevated[-1]

            $command | Should Match ([regex]::Escape("-Profile 'full'"))
            $command | Should Match ([regex]::Escape("-ResultPath '$resultPath'"))
            $command | Should Not Match ([regex]::Escape("'-Profile' 'full'"))
            $command | Should Match '1>'
            $command | Should Match '2>'
        } finally {
            Remove-Variable -Name ui -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'binds elevated backend arguments correctly when command is executed without UAC' {
        Import-UiFunctionsForTest -Names @('ConvertTo-PowerShellLiteral','Get-UiBackendParameterBindingSpec','ConvertTo-ElevatedBackendInvocationParts','Get-UiBackendTokenValue','New-UiElevatedBackendWrapperCommand','Build-ElevatedBackendCommand')
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $probeRoot = Join-Path $script:TestDataRoot 'Probe & (Elevated)'
        $null = New-Item -Path $probeRoot -ItemType Directory -Force
        $probePath = Join-Path $probeRoot 'probe.ps1'
        $resultPath = Join-Path $probeRoot 'result.json'
        $stdoutPath = Join-Path $probeRoot 'stdout.log'
        $stderrPath = Join-Path $probeRoot 'stderr.log'
        [System.IO.File]::WriteAllText($probePath, @'
param(
    [switch]$NonInteractive,
    [string]$Profile,
    [string]$ResultPath
)
[ordered]@{
    status = 'success'
    mode = 'probe'
    exitCode = 0
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding utf8
[ordered]@{
    NonInteractive = [bool]$NonInteractive
    Profile = [string]$Profile
    ResultPath = [string]$ResultPath
} | ConvertTo-Json -Compress
'@, [System.Text.UTF8Encoding]::new($false))
        $global:ui = [pscustomobject]@{
            CurrentStdoutPath = $stdoutPath
            CurrentStderrPath = $stderrPath
        }

        try {
            $tokens = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$probePath,'-NonInteractive','-Profile','full','-ResultPath',$resultPath)
            $elevated = Build-ElevatedBackendCommand -BackendTokens $tokens
            & $powershellExe @elevated | Out-Null
            $LASTEXITCODE | Should Be 0

            Test-Path -LiteralPath $resultPath | Should Be $true
            $stdoutLines = @(Get-Content -LiteralPath $stdoutPath -ErrorAction Stop | Where-Object { [string]$_ -match '^\s*\{' })
            $bound = ($stdoutLines[-1] | ConvertFrom-Json -ErrorAction Stop)
            [bool]$bound.NonInteractive | Should Be $true
            [string]$bound.Profile | Should Be 'full'
            [string]$bound.ResultPath | Should Be $resultPath
            ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue))) | Should Be $true
        } finally {
            Remove-Variable -Name ui -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'writes an elevated fallback result when backend cannot start' {
        Import-UiFunctionsForTest -Names @('ConvertTo-PowerShellLiteral','Get-UiBackendParameterBindingSpec','ConvertTo-ElevatedBackendInvocationParts','Get-UiBackendTokenValue','New-UiElevatedBackendWrapperCommand','Build-ElevatedBackendCommand')
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $probeRoot = Join-Path $script:TestDataRoot 'Missing Probe'
        $null = New-Item -Path $probeRoot -ItemType Directory -Force
        $missingScript = Join-Path $probeRoot 'missing.ps1'
        $resultPath = Join-Path $probeRoot 'result.json'
        $stdoutPath = Join-Path $probeRoot 'stdout.log'
        $stderrPath = Join-Path $probeRoot 'stderr.log'
        $global:ui = [pscustomobject]@{
            CurrentStdoutPath = $stdoutPath
            CurrentStderrPath = $stderrPath
        }

        try {
            $tokens = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$missingScript,'-NonInteractive','-Profile','full','-ResultPath',$resultPath)
            $elevated = Build-ElevatedBackendCommand -BackendTokens $tokens
            & $powershellExe @elevated | Out-Null
            ($LASTEXITCODE -ne 0) | Should Be $true

            Test-Path -LiteralPath $resultPath | Should Be $true
            $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$result.status | Should Be 'error'
            [string]$result.mode | Should Be 'ui-elevated'
            [string]$result.error | Should Match 'Elevated backend wrapper failed'
        } finally {
            Remove-Variable -Name ui -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'supports per-run AppTuning scope override (isolated vs profile)' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'ExecutionScopeOverride'
        $raw | Should Match 'New-ExecutionScopeSnapshot'
        $raw | Should Match 'Get-CurrentExecutionScopeSnapshot'
        $raw | Should Match 'Assert-ExecutionScopeSnapshot'
        $raw | Should Match 'Get-IsolatedAppTuningExecutionOverride'
        $raw | Should Match 'Get-ProfileExecutionOverride'
        $raw | Should Match 'Whitelist forte: escopo isolado ignora historico global'
        $raw | Should Match 'Escopo isolado invalido: ExcludeAppTuningItem deve estar vazio'
        $raw | Should Match 'Refresh-ReviewPage'
        $raw | Should Match 'scopeSnapshot = Get-CurrentExecutionScopeSnapshot'
        $raw | Should Match 'Escopo: \$\(\[string\]\$scopeSnapshot\.scopeLabel\)'
        $raw | Should Match 'Execution scope snapshot\. Source='
        $raw | Should Match 'ArgumentList acima do limite seguro'
        $raw | Should Match 'YesNoCancel'
        $raw | Should Match 'scopeMode=\{0\}'
        $raw | Should Match 'Clear-ExecutionScopeOverride'
        $raw | Should Match 'Escopo:'
    }

    It 'requires explicit execution scope when profiles and isolated components coexist' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'Confirm-UiExecutionScope'
        $raw | Should Match 'Get-IsolatedComponentExecutionOverride'
        $raw | Should Match 'Escopo amb'
        $raw | Should Match 'Somente componentes selecionados'
        $raw | Should Match 'Perfil atual \+ componentes'
        $raw | Should Match 'Confirm-UiExecutionScope -MaintenanceIntent \$MaintenanceIntent'
    }

    It 'sanitizes component-only execution scope before backend args' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'Normalize-UiComponentOnlyExecutionScope'
        $raw | Should Match 'Instalação isolada'
        $raw | Should Match '\$snapshot\.hostHealth = ''off'''
        $raw | Should Match '\$snapshot\.appTuningMode = ''off'''
        $raw | Should Match '\$snapshot\.excludedAppTuningItems = @\(\)'
    }

    It 'requires accepted review before normal execution and shows blocked results as user action' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'ReviewAcceptedCheckBox'
        $raw | Should Match 'Test-UiReviewAcceptedForRun'
        $raw | Should Match 'Revis.*obrigat.*ria'
        $raw | Should Match '\$status -eq ''blocked'''
        $raw | Should Match 'Get-UiRunStatusTextFromResult'
        $raw | Should Match 'A.*necess.*ria'
    }

    It 'separates critical actions behind explicit confirmation modals' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'function Confirm-UiCriticalAction'
        $raw | Should Match 'CriticalAction'
        $raw | Should Match 'REINICIAR'
        $raw | Should Match 'Confirmar reversão'
        $raw | Should Match 'Confirmar BCD'
    }

    It 'defines visible focus states for keyboard navigation' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'FocusVisualBrush'
        $raw | Should Match 'IsKeyboardFocusWithin'
        $raw | Should Match 'TargetType="DataGridRow"'
        $raw | Should Match 'TargetType="CheckBox"'
        $raw | Should Match 'TargetType="TextBox"'
    }

    It 'debounces AppTuning search refresh and wraps dense toolbar actions' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'AppTuningRefreshTimer'
        $raw | Should Match 'Request-AppTuningRefresh'
        $raw | Should Match 'FromMilliseconds\(300\)'
        $raw | Should Match '<WrapPanel'
    }

    It 'clears profile, component, quick option, host health and AppTuning state together' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'function Clear-UiAllSelections'
        $raw | Should Match '\$ui\.State\.selectedProfiles = @\(\)'
        $raw | Should Match '\$ui\.State\.selectedComponents = @\(\)'
        $raw | Should Match '\$ui\.State\.excludedComponents = @\(\)'
        $raw | Should Match '\$ui\.State\.hostHealth = ''off'''
        $raw | Should Match '\$ui\.State\.appTuningMode = ''off'''
        $raw | Should Match '\$ui\.State\.enableClaudeCodeProjectMcps = \$false'
        $raw | Should Match '\$ui\.State\.offlineMode = \$false'
        $raw | Should Match 'Refresh-HostSetupControls'
    }

    It 'guards required components from UI exclusion' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'Repair-UiExcludedComponents'
        $raw | Should Match 'Test-UiComponentCanExclude'
        $raw | Should Match 'Componente obrigatorio/dependencia base'
        $raw | Should Match 'Remove-UiStringValue'
    }

    It 'runs the Btrfs UI readiness check with real partition scan enabled' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'Get-BootstrapBtrfsReadiness -ScanPartitions'
    }

    It 'does not ship known mojibake in visible UI strings' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Not Match 'sesses|genrico|Resoluo|Validao|Execuo|Reviso|Relatrios|manuteno'
        $raw | Should Not Match 'PRESETS RPIDOS|Configurao|Verso|EXCLUSES|Execucao|Revisao|Relatorios|Opcoes rapidas|Nao instalar|manutencao'
    }

    It 'keeps UTF-8 BOM on PowerShell files that contain user-facing accents' {
        foreach ($path in @($uiScriptPath, (Join-Path $repoRoot 'bootstrap-tools.ps1'))) {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $bytes.Length | Should BeGreaterThan 3
            $bytes[0] | Should Be 0xEF
            $bytes[1] | Should Be 0xBB
            $bytes[2] | Should Be 0xBF
        }

        $raw = Get-Content -Path $uiScriptPath -Raw
        $raw | Should Match 'Avançar'
        $raw | Should Match 'Catálogo'
        $raw | Should Not Match 'AvanÃ§ar|CatÃ¡logo|ConfiguraÃ§Ã£o|ExecuÃ§Ã£o'
    }

    It 'runs the batch launcher smoke test without stderr noise' {
        $stdoutPath = Join-Path $script:TestDataRoot 'stdout.txt'
        $stderrPath = Join-Path $script:TestDataRoot 'stderr.txt'
        $command = ('.\bootstrap-ui.bat -SmokeTest 1> "{0}" 2> "{1}"' -f $stdoutPath, $stderrPath)

        $null = New-Item -Path $script:TestDataRoot -ItemType Directory -Force

        Push-Location $repoRoot
        try {
            & cmd /c $command | Out-Null
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $exitCode | Should Be 0

        $stdout = ''
        if (Test-Path $stdoutPath) {
            $stdout = (Get-Content -Path $stdoutPath -Raw)
        }

        $stderr = ''
        if (Test-Path $stderrPath) {
            $stderr = (Get-Content -Path $stderrPath -Raw)
        }

        $result = $stdout | ConvertFrom-Json -ErrorAction Stop
        (@($result.pages) -contains 'welcome') | Should Be $true
        $stdout | Should Not Match '\[INFO\]'
        ([string]::IsNullOrWhiteSpace($stderr)) | Should Be $true
    }

    It 'starts the operational Health page first in smoke contract' {
        $stdoutPath = Join-Path $script:TestDataRoot 'health-first.stdout.txt'
        $stderrPath = Join-Path $script:TestDataRoot 'health-first.stderr.txt'
        $command = ('.\bootstrap-ui.bat -SmokeTest 1> "{0}" 2> "{1}"' -f $stdoutPath, $stderrPath)

        $null = New-Item -Path $script:TestDataRoot -ItemType Directory -Force

        Push-Location $repoRoot
        try {
            & cmd /c $command | Out-Null
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $exitCode | Should Be 0
        $result = (Get-Content -Path $stdoutPath -Raw) | ConvertFrom-Json -ErrorAction Stop
        [string]@($result.pages)[0] | Should Be 'health'
        [string]$result.startPage | Should Be 'health'
        [string]$result.primaryAction | Should Be 'doctor'
        [string]::IsNullOrWhiteSpace((Get-Content -Path $stderrPath -Raw)) | Should Be $true
    }

    It 'keeps launcher console output concise by default' {
        $raw = Get-Content -Path (Join-Path $repoRoot 'bootstrap-ui.bat') -Raw

        $raw | Should Match 'BOOTSTRAP_UI_VERBOSE'
        $raw | Should Match ':resolve_timestamp'
        $raw | Should Match '-STA'
        $raw | Should Match '-WindowStyle Hidden'
        $raw | Should Not Match 'TS=unknown'
        $raw | Should Not Match 'if not "%BOOTSTRAP_SMOKE_TEST%"=="1" echo\(!LOG_LINE!'
    }

    It 'maps every direct UI event handler target before startup wiring' {
        $raw = Get-Content -Path $uiScriptPath -Raw
        $assigned = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($match in [regex]::Matches($raw, '(?m)^\s*(\w+)\s*=\s*\(Get-Control\s+''([^'']+)''\)')) {
            [void]$assigned.Add($match.Groups[1].Value)
        }

        foreach ($match in [regex]::Matches($raw, '\$ui\.(\w+)\.Add_')) {
            $target = $match.Groups[1].Value
            ($assigned.Contains($target) -or $target -in @('LogTimer')) | Should Be $true
        }
    }
}

Describe 'Health scoped validation per card' {
    It 'uses plain Portuguese labels for Health primary actions and result areas' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        foreach ($expected in @(
            'Text="Após rodar diagnóstico:"',
            'Text="&#9679; atenção"',
            'Text="&#9679; crítico/bloqueado"',
            'Text="DIAGNÓSTICO"',
            'Text="PACOTE DE SUPORTE"',
            'Text="REPAROS"',
            'Content="Rodar diagnóstico"',
            'Content="Exportar pacote"',
            'Content="Ver reparos"',
            'Text="ÚLTIMO RESULTADO"'
        )) {
            $raw | Should Match ([regex]::Escape($expected))
        }

        foreach ($legacy in @(
            'Text="Apos rodar Doctor:"',
            'Text="DOCTOR"',
            'Text="SUPPORT BUNDLE"',
            'Text="REPAIR QUEUE"',
            'Content="Rodar Doctor"',
            'Content="Exportar bundle"',
            'Content="Ver fila de reparo"',
            'Text="ULTIMO RESULTADO"'
        )) {
            $raw | Should Not Match ([regex]::Escape($legacy))
        }
    }

    It 'keeps technical repair terms out of visible Health action button content' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        foreach ($expected in @(
            'Content="Memória e eficiência"',
            'Content="Reparar tokens/memória"',
            'Content="Compilador Windows"',
            'Content="Otimizar Windows"',
            'Content="Validar conexões de IA"',
            'Content="Reparar conexões de IA"',
            'Content="Verificar mudanças"',
            'Content="Agendar verificação semanal"'
        )) {
            $raw | Should Match ([regex]::Escape($expected))
        }

        $visibleContent = @([regex]::Matches($raw, '<Button x:Name="Health[^"]+"[^>]*Content="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        @($visibleContent | Where-Object { $_ -match '\bMSVC\b|MCPs|npx|drift|Doctor|Bundle|Rollback|Audit' }).Count | Should Be 0
    }

    It 'renders the 10 health cards as clickable scope buttons with tooltips' {
        $raw = Get-Content -Path $uiScriptPath -Raw
        $expected = @{
            'HealthWslCard' = 'wsl'; 'HealthWingetCard' = 'winget'; 'HealthRebootCard' = 'reboot';
            'HealthSecretsCard' = 'secrets'; 'HealthGithubCard' = 'github'; 'HealthAiUsagebarCard' = 'ai-usagebar';
            'HealthAiMemoryCard' = 'ai-memory'; 'HealthAionUiCard' = 'aionui'; 'HealthDeckCard' = 'steamdeck';
            'HealthRollbackCard' = 'rollback'
        }
        foreach ($name in $expected.Keys) {
            $raw | Should Match ([regex]::Escape('x:Name="' + $name + '"'))
            $raw | Should Match ([regex]::Escape('Tag="' + $expected[$name] + '"'))
        }
        $raw | Should Match 'HealthCardButton'
        $raw | Should Match 'Validar somente'
    }

    It 'opens memory management and scopes diagnostics for the other health cards' {
        $raw = Get-Content -Path $uiScriptPath -Raw
        foreach ($scope in @('wsl','winget','reboot','secrets','github','ai-usagebar','aionui','steamdeck','rollback')) {
            $raw | Should Match ([regex]::Escape("Invoke-UiHealthScopedDoctor -Scope '" + $scope + "'"))
        }
        $raw | Should Match ([regex]::Escape("Show-PhaseZeroMemoryWindow -Owner `$window -RepoRoot `$PSScriptRoot"))
        $raw | Should Match ([regex]::Escape("windows/ai/memory-ui.ps1"))
        # O helper de card deve disparar Start-RunExecution com intent doctor e o escopo do card.
        $raw | Should Match "Start-RunExecution -MaintenanceIntent 'doctor' -DoctorScope \`$Scope"
    }

    It 'adds token memory, Windows optimization, AI connection and compiler buttons with their scopes' {
        $raw = Get-Content -Path $uiScriptPath -Raw
        $raw | Should Match ([regex]::Escape('x:Name="HealthAgentToolsButton"'))
        $raw | Should Match ([regex]::Escape('Memória e eficiência'))
        $raw | Should Match ([regex]::Escape("Show-PhaseZeroEconomyWindow -Owner `$window -RepoRoot `$PSScriptRoot"))
        $raw | Should Match ([regex]::Escape("Invoke-UiHealthScopedDoctor -Scope 'windows-optimization'"))
        $raw | Should Match ([regex]::Escape("Invoke-UiHealthScopedDoctor -Scope 'mcp'"))
        $raw | Should Match ([regex]::Escape("Invoke-UiHealthScopedDoctor -Scope 'msvc'"))
        $raw | Should Match ([regex]::Escape('x:Name="HealthValidateMcpButton"'))
    }

    It 'passes -DoctorScope to the backend for doctor runs' {
        $raw = Get-Content -Path $uiScriptPath -Raw
        $raw | Should Match "tokens \+= @\('-DoctorScope'"
    }

    It 'builds a human summary above the JSON for the last result' {
        Import-UiFunctionsForTest -Names @('Get-UiDoctorHumanSummary')
        $result = [pscustomobject]@{
            status = 'warning'
            doctor = [pscustomobject]@{
                status = 'degraded'
                scopes = @('agent-tools')
                agentTools = [pscustomobject]@{ status = 'degraded'; summary = 'RTK=absent; ai-memory=available' }
            }
        }
        $summary = Get-UiDoctorHumanSummary -Result $result -Scopes @('agent-tools')
        $summary | Should Match 'agent-tools'
        $summary | Should Match 'Tokens/memória'
        $summary | Should Match 'RTK=absent'
    }
}

Describe 'Health tokens/memory validation and repair flow' {
    It 'opens project and agent efficiency settings from the memory action' {
        $raw = Get-Content -Path $uiScriptPath -Raw
        $raw | Should Match ([regex]::Escape('x:Name="HealthAgentToolsButton"'))
        $raw | Should Match ([regex]::Escape("Show-PhaseZeroEconomyWindow -Owner `$window -RepoRoot `$PSScriptRoot"))
    }

    It 'adds a confirmation-gated repair that computes a scoped plan and applies each item by its real flow' {
        $raw = Get-Content -Path $uiScriptPath -Raw
        $raw | Should Match ([regex]::Escape('x:Name="HealthAgentToolsRepairButton"'))
        $raw | Should Match ([regex]::Escape('Invoke-UiHealthAgentToolsRepair'))
        $body = [regex]::Match($raw, 'function Invoke-UiHealthAgentToolsRepair.*?\n\}', 'Singleline').Value
        $body | Should Not Be ''
        # Confirma antes de aplicar.
        $body | Should Match 'Confirm-UiCriticalAction'
        # Gera o plano scoped em processo (agent-tools) e NAO so um repair-plan que nao aplica.
        $body | Should Match 'New-BootstrapAgentToolsDoctorReport'
        $body | Should Match 'New-BootstrapRepairPlan'
        # Aplica de fato cada item pelo seu fluxo real, com artefatos.
        $body | Should Match "repairKind -eq 'component'"
        $body | Should Match "repairKind -eq 'app-tuning'"
        $body | Should Match "repairKind -eq 'ai-tool'"
        $body | Should Match '-ResultPath'
        $body | Should Match 'install-cli'
    }

    It 'passes -DoctorScope to the backend for both doctor and repair-plan runs' {
        Import-UiFunctionsForTest -Names @('Build-BackendArguments')
        $raw = Get-Content -Path $uiScriptPath -Raw
        # repair-plan tambem precisa emitir -DoctorScope (nao so doctor).
        $raw | Should Match "maint -in @\('doctor', 'repair-plan'\)"
        $raw | Should Match "tokens \+= @\('-DoctorScope'"
    }

    It 'keeps card validation on the Health page (no navigation away for scoped card clicks)' {
        $raw = Get-Content -Path $uiScriptPath -Raw
        $body = [regex]::Match($raw, 'function Invoke-UiHealthScopedDoctor.*?\n\}', 'Singleline').Value
        $body | Should Not Be ''
        # O handler de card NAO deve navegar para outra pagina (fica na tela Saude).
        ($body -match 'Navigate-ToPage') | Should Be $false
        $body | Should Match "Start-RunExecution -MaintenanceIntent 'doctor' -DoctorScope \`$Scope"
    }
}

Describe 'Health drive labels UI and CLI flow' {
    It 'renders a dedicated drive labels panel with diagnose, advanced apply and result grid' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match ([regex]::Escape('x:Name="HealthDriveLabelsButton"'))
        $raw | Should Match ([regex]::Escape('Diagnosticar drives'))
        $raw | Should Match ([regex]::Escape('x:Name="HealthDriveLabelsAdvancedCheck"'))
        $raw | Should Match ([regex]::Escape('x:Name="HealthDriveLabelsApplyButton"'))
        $raw | Should Match ([regex]::Escape('Aplicar rótulos seguros'))
        $raw | Should Match ([regex]::Escape('x:Name="HealthDriveLabelsGrid"'))
        $raw | Should Match 'PARTI'
    }

    It 'routes drive diagnosis and apply through dedicated backend modes' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match "ValidateSet\('none', 'audit', 'rollback', 'doctor', 'support-bundle', 'repair-plan', 'partition-labels', 'partition-labels-apply'\)"
        $raw | Should Not Match "ValidateSet\('none', 'audit', 'rollback', 'doctor', 'support-bundle', 'repair-plan'\)"
        $raw | Should Match "Start-RunExecution -MaintenanceIntent 'partition-labels'"
        $raw | Should Match "Start-RunExecution -MaintenanceIntent 'partition-labels-apply'"
        $raw | Should Match "maint -eq 'partition-labels'"
        $raw | Should Match "tokens \+= @\('-PartitionLabels'\)"
        $raw | Should Match "maint -eq 'partition-labels-apply'"
        $raw | Should Match "tokens \+= @\('-PartitionLabels', '-ApplyPartitionLabels'\)"
        $raw | Should Match "'-PartitionLabels'"
        $raw | Should Match "'-ApplyPartitionLabels'"
    }

    It 'gates drive label application behind advanced mode, typed confirmation and env opt-in' {
        $raw = Get-Content -Path $uiScriptPath -Raw
        $body = [regex]::Match($raw, 'function Invoke-UiHealthPartitionLabelsApply.*?\n\}', 'Singleline').Value

        $body | Should Not Be ''
        $body | Should Match 'HealthDriveLabelsAdvancedCheck'
        $body | Should Match 'Confirm-UiCriticalAction'
        $body | Should Match 'RequiredToken'
        $body | Should Match 'APLICAR ROTULOS'
        $body | Should Match 'PHASEZERO_PARTITION_LABEL_APPLY'
    }

    It 'updates the Health panel from partition-labels results without navigating away' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'function Update-UiPartitionLabelsHealthResult'
        $raw | Should Match "modeText -eq 'partition-labels'"
        $raw | Should Match 'Update-UiPartitionLabelsHealthResult -Result \$result'
        $raw | Should Match 'HealthDriveLabelsGrid'
    }

    It 'formats empty partition-label results without Count/null errors' {
        Import-UiFunctionsForTest -Names @('Get-UiObjectValue','Get-UiObjectArray','ConvertTo-UiBoolean','Get-UiPartitionLabelPlanFromResult','Get-UiPartitionLabelRows','Get-UiPartitionLabelSummaryText')
        $result = [pscustomobject]@{
            mode = 'partition-labels'
            status = 'success'
            plan = [pscustomobject]@{}
            counts = [pscustomobject]@{ total = 0; renameable = 0; blocked = 0; guideOnly = 0 }
            partitionLabels = [pscustomobject]@{ result = [pscustomobject]@{} }
        }

        @((Get-UiPartitionLabelRows -Result $result)).Count | Should Be 0
        (Get-UiPartitionLabelSummaryText -Result $result) | Should Match '0 part'
    }
}
