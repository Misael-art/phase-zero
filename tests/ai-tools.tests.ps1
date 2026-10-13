$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsScriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
$uiScriptPath = Join-Path $repoRoot 'bootstrap-ui.ps1'
$installCliBatPath = Join-Path $repoRoot 'install-cli.bat'

function Get-LongPath {
    # Expande nome curto 8.3 (ex.: RUNNER~1 nos runners do GitHub) para a forma longa via
    # (Get-Location).Path - mesma resolucao que as funcoes sob teste usam (comprovado no runner).
    # Para arquivos, normaliza o diretorio pai e rejunta o nome.
    param([string]$Path)
    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            Push-Location -LiteralPath $Path
            try { return [string](Get-Location).Path } finally { Pop-Location }
        }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $dir = Split-Path -LiteralPath $Path -Parent
            $leaf = Split-Path -LiteralPath $Path -Leaf
            Push-Location -LiteralPath $dir
            try { return (Join-Path (Get-Location).Path $leaf) } finally { Pop-Location }
        }
    } catch { }
    return $Path
}

function New-AiToolsTestRoot {
    $root = Join-Path $env:TEMP ("PhaseZero AI Tools {0}" -f ([Guid]::NewGuid().ToString('N')))
    $null = New-Item -Path $root -ItemType Directory -Force
    return (Get-LongPath $root)
}

function Remove-AiToolsTestRoot {
    param([string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-InstallCliBat {
    param(
        [Parameter(Mandatory = $true)][string[]]$Args,
        [int]$TimeoutMs = 240000
    )

    $argLiteral = ($Args | ForEach-Object {
        $v = [string]$_
        if ($v -match '[\s"]') { '"' + ($v -replace '"', '\"') + '"' } else { $v }
    }) -join ' '
    $cmdLine = ('/c ""{0}" {1}"' -f $installCliBatPath, $argLiteral)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = $cmdLine
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMs)) {
        try { $process.Kill() } catch { Write-Verbose $_.Exception.Message }
        throw "install-cli.bat timed out for args: $($Args -join ' ')"
    }

    return [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        Stdout = [string]$stdoutTask.Result
        Stderr = [string]$stderrTask.Result
    }
}

Describe 'AI coding tool support' {
    BeforeEach {
        $script:AiToolsTestRoot = New-AiToolsTestRoot
    }

    AfterEach {
        Remove-AiToolsTestRoot -Path $script:AiToolsTestRoot
        Remove-Variable -Scope Script -Name AiToolsTestRoot -ErrorAction SilentlyContinue
    }

    It 'declares a conservative official-source AI tool catalog' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $catalog = Get-BootstrapAiToolCatalog

        foreach ($toolName in @('rtk','claude-code','opencode','hermes-agent','hermes-desktop','openclaw','aionui','antigravity-workflows','ai-usagebar','ai-memory')) {
            $catalog.Contains($toolName) | Should Be $true
            [string]$catalog[$toolName].DocsUrl | Should Match '^https://'
            [string]$catalog[$toolName].InstallSupport | Should Not Be ''
        }

        [string]$catalog['claude-code'].PackageName | Should Be '@anthropic-ai/claude-code'
        [string]$catalog['opencode'].PackageName | Should Be 'opencode-ai'
        [string]$catalog['rtk'].GitHubRepo | Should Be 'rtk-ai/rtk'
        [bool]$catalog['rtk'].CargoFallbackAllowed | Should Be $false
        [string]$catalog['hermes-agent'].GitHubRepo | Should Be 'NousResearch/hermes-agent'
        [string]$catalog['hermes-agent'].InstallSupport | Should Be 'wsl-installer'
        [string]$catalog['hermes-agent'].Notes | Should Match 'WSL2'
        (@($catalog['hermes-agent'].ProbePaths) -contains '$env:USERPROFILE\.hermes\hermes-agent') | Should Be $true
        [string]$catalog['antigravity-workflows'].InstallSupport | Should Be 'workflow-only'
        [string]$catalog['ai-usagebar'].GitHubRepo | Should Be 'akitaonrails/ai-usagebar'
        [string]$catalog['ai-usagebar'].InstallSupport | Should Be 'linux-release'
        [string]$catalog['ai-usagebar'].ReleaseTag | Should Be 'v0.7.1'
        [string]$catalog['ai-usagebar'].ReleaseAssets['x86_64'].Name | Should Be 'ai-usagebar-linux-x86_64.tar.gz'
        [string]$catalog['ai-usagebar'].ReleaseAssets['x86_64'].Sha256 | Should Match '^[a-f0-9]{64}$'

        [string]$catalog['aionui'].ToolName | Should Be 'aionui'
        [string]$catalog['aionui'].DisplayName | Should Be 'AionUI'
        [string]$catalog['aionui'].WingetId | Should Be 'iOfficeAI.AionUi'
        [string]$catalog['aionui'].DownloadUrl | Should Be 'https://aionui.com/download/'
        [string]$catalog['aionui'].GitHubRepo | Should Be 'iOfficeAI/AionUi'
        [string]$catalog['aionui'].WikiUrl | Should Match 'LLM-Configuration'
        [string]$catalog['aionui'].InstallSupport | Should Be 'winget-official-exe'
        (@($catalog['aionui'].Architectures) -contains 'x64') | Should Be $true
        (@($catalog['aionui'].Architectures) -contains 'arm64') | Should Be $true
        (@($catalog['aionui'].Aliases) -contains 'aion-ui') | Should Be $true
    }

    It 'blocks OpenClaw usage actions but preserves explicit managed uninstall' {
        . $toolsScriptPath -BootstrapUiLibraryMode
        Mock Install-BootstrapAiNpmTool { throw 'OpenClaw npm install must not run' }
        Mock Invoke-BootstrapAiNativeCommand { throw 'OpenClaw npm uninstall must not run in dry-run' }

        foreach ($action in @('install','configure','start')) {
            $result = Invoke-BootstrapAiToolAction -ToolName 'openclaw' -Action $action -InstallRoot $script:AiToolsTestRoot -ProjectRoot $script:AiToolsTestRoot -DryRun -Yes
            [string]$result.status | Should Be 'blocked'
            [bool]$result.ready | Should Be $false
            [bool]$result.usageBlocked | Should Be $true
            [string]$result.blockedReason | Should Be 'connection-grant-not-enforceable'
        }

        Assert-MockCalled Install-BootstrapAiNpmTool -Times 0 -Exactly
        Assert-MockCalled Invoke-BootstrapAiNativeCommand -Times 0 -Exactly
        $uninstall = Invoke-BootstrapAiToolAction -ToolName 'openclaw' -Action 'uninstall' -InstallRoot $script:AiToolsTestRoot -ProjectRoot $script:AiToolsTestRoot -DryRun -Yes
        [string]$uninstall.status | Should Be 'planned'
        [string]$uninstall.message | Should Match 'npm uninstall -g --prefix'
        [string]$uninstall.message | Should Match ([regex]::Escape((Get-BootstrapAiNpmPrefix -InstallRoot $script:AiToolsTestRoot)))
        $directUninstall = Uninstall-BootstrapAiNpmTool -ToolName 'openclaw' -CatalogEntry (Get-BootstrapAiToolCatalog)['openclaw'] -InstallRoot $script:AiToolsTestRoot -DryRun
        [string]$directUninstall.status | Should Be 'planned'
        @(Get-ChildItem -LiteralPath $script:AiToolsTestRoot -Force).Count | Should Be 0

        $profiles = Get-BootstrapProfileCatalog
        (@($profiles['ai'].Items) -contains 'openclaw') | Should Be $false
        (@($profiles['legacy'].Items) -contains 'openclaw') | Should Be $false
        $capability = (Get-BootstrapAppCapabilityCatalog)['openClaw']
        [bool]$capability.autoInstall | Should Be $false
        [bool]$capability.authByFile | Should Be $false
        [bool]$capability.authByEnv | Should Be $false
        [bool]$capability.manualOnly | Should Be $true

        Mock Resolve-BootstrapAiToolCommandPath { return 'C:\External\openclaw.cmd' }
        Mock Invoke-NativeFirstLine { throw 'OpenClaw/node command must not run in blocked status.' }
        Mock Invoke-BootstrapDoctorCommandProbe { throw 'OpenClaw probe must not run.' }
        $openClawReport = Get-BootstrapOpenClawAiConfigReport
        [bool]$openClawReport.ready | Should Be $false
        [bool]$openClawReport.usageBlocked | Should Be $true
        [string]$openClawReport.smoke.status.status | Should Be 'blocked'
        Assert-MockCalled Invoke-NativeFirstLine -Times 0 -Exactly
        Assert-MockCalled Invoke-BootstrapDoctorCommandProbe -Times 0 -Exactly
    }

    It 'blocks direct OpenClaw npm helper before dry-run or mutation' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $message = ''
        try {
            Install-BootstrapAiNpmTool -ToolName 'openclaw' -CatalogEntry (Get-BootstrapAiToolCatalog)['openclaw'] -InstallRoot $script:AiToolsTestRoot -DryRun | Out-Null
        } catch {
            $message = [string]$_.Exception.Message
        }

        $message | Should Match 'connection-grant-not-enforceable'
        @(Get-ChildItem -LiteralPath $script:AiToolsTestRoot -Force).Count | Should Be 0
    }

    It 'declares ai-jail as an opt-in WSL sandbox tool and plans a dry-run install' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $catalog = Get-BootstrapAiToolCatalog
        $catalog.Contains('ai-jail') | Should Be $true
        [string]$catalog['ai-jail'].InstallSupport | Should Be 'wsl-installer'
        [string]$catalog['ai-jail'].GitHubRepo | Should Be 'akitaonrails/ai-jail'
        [bool]$catalog['ai-jail'].DefaultProfileAllowed | Should Be $false

        $plan = Invoke-BootstrapAiToolAction -ToolName 'ai-jail' -Action 'install' -InstallRoot $script:AiToolsTestRoot -ProjectRoot $repoRoot -DryRun -Yes
        [string]$plan.tool | Should Be 'ai-jail'
        [string]$plan.status | Should Be 'planned'

        $cmd = Get-BootstrapAiJailWslInstallCommand
        $cmd | Should Match 'ai-jail-linux'
        $cmd | Should Match 'bubblewrap'
    }

    It 'declares transcript opt-in AI tools with official sources and dry-run support' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $catalog = Get-BootstrapAiToolCatalog

        foreach ($toolName in @('printing-press','indextts2','odysseus','ollama','lm-studio','openwebui','n8n')) {
            $catalog.Contains($toolName) | Should Be $true
            [string]$catalog[$toolName].DocsUrl | Should Match '^https://'
            [string]$catalog[$toolName].InstallSupport | Should Not Be ''
            [string]$catalog[$toolName].RiskLevel | Should Match '^(safe|experimental|manual)$'
            [bool]$catalog[$toolName].DefaultProfileAllowed | Should Be $false
        }

        [string]$catalog['printing-press'].GitHubRepo | Should Be 'mvanhorn/cli-printing-press'
        [string]$catalog['printing-press'].InstallSupport | Should Be 'manual-workflow'
        [string]$catalog['indextts2'].GitHubRepo | Should Be 'index-tts/index-tts'
        [bool]$catalog['indextts2'].RequiresGpu | Should Be $true
        [string]$catalog['odysseus'].GitHubRepo | Should Be 'pewdiepie-archdaemon/odysseus'
        [string]$catalog['ollama'].InstallSupport | Should Be 'winget'
        [string]$catalog['openwebui'].InstallSupport | Should Be 'docker-manual'
        [string]$catalog['n8n'].InstallSupport | Should Be 'workflow-template'
    }

    It 'plans transcript experimental AI tool dry-runs without mutating the host' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        foreach ($toolName in @('printing-press','indextts2','odysseus')) {
            $result = Invoke-BootstrapAiToolAction -ToolName $toolName -Action 'install' -InstallRoot $script:AiToolsTestRoot -ProjectRoot $repoRoot -DryRun -Yes

            [string]$result.tool | Should Be $toolName
            [string]$result.status | Should Be 'planned'
            [string]$result.action | Should Be 'install'
            [string]$result.message | Should Match 'opt-in|manual|GPU|admin|oficial'
        }
    }

    It 'reports AI tool status without claiming missing tools are configured' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $rows = @(Get-BootstrapAiToolStatusRows -InstallRoot $script:AiToolsTestRoot -ProjectRoot $repoRoot)

        (@($rows | Where-Object { [string]$_['tool'] -eq 'claude-code' }).Count) | Should Be 1
        foreach ($row in @($rows)) {
            [string]$row['tool'] | Should Not Be ''
            [string]$row['status'] | Should Match '^(absent|installed|configured|manual|blocked|error)$'
            [string]$row['docs'] | Should Match '^https://'
        }
    }

    It 'supports dry-run install and idempotent uninstall for a path with spaces' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $rootWithSpaces = Join-Path $script:AiToolsTestRoot 'managed tools root'
        $install = Invoke-BootstrapAiToolAction -ToolName 'claude-code' -Action 'install' -InstallRoot $rootWithSpaces -ProjectRoot $repoRoot -DryRun -Yes
        $uninstall1 = Invoke-BootstrapAiToolAction -ToolName 'claude-code' -Action 'uninstall' -InstallRoot $rootWithSpaces -ProjectRoot $repoRoot -DryRun -Yes
        $uninstall2 = Invoke-BootstrapAiToolAction -ToolName 'claude-code' -Action 'uninstall' -InstallRoot $rootWithSpaces -ProjectRoot $repoRoot -DryRun -Yes

        [string]$install.status | Should Be 'planned'
        [string]$uninstall1.status | Should Be 'planned'
        [string]$uninstall2.status | Should Be 'planned'
        [string]$install.installRoot | Should Be $rootWithSpaces
    }

    It 'plans Hermes Agent install through the official WSL installer' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $result = Invoke-BootstrapAiToolAction -ToolName 'hermes-agent' -Action 'install' -InstallRoot $script:AiToolsTestRoot -ProjectRoot $repoRoot -DryRun -Yes

        [string]$result.status | Should Be 'planned'
        [string]$result.message | Should Match 'install\.sh'
        [string]$result.message | Should Match '--skip-setup'
        [string]$result.message | Should Match 'WSL2'
    }

    It 'plans AI Usagebar install through a verified official release path' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $result = Invoke-BootstrapAiToolAction -ToolName 'usagebar' -Action 'install' -InstallRoot $script:AiToolsTestRoot -ProjectRoot $repoRoot -DryRun -Yes

        [string]$result.tool | Should Be 'ai-usagebar'
        [string]$result.status | Should Be 'planned'
        [string]$result.message | Should Match 'akitaonrails/ai-usagebar'
        [string]$result.message | Should Match 'v0\.7\.1'
        [string]$result.message | Should Match 'sha256'
    }

    It 'keeps AI Usagebar TUI out of noninteractive validation probes' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $catalog = Get-BootstrapAiToolCatalog
        $command = Get-BootstrapAiUsagebarWslInstallCommand -CatalogEntry $catalog['ai-usagebar']

        [string]$command | Should Match 'ai-usagebar" --help'
        [string]$command | Should Match 'test -x ".+ai-usagebar-tui'
        [string]$command | Should Not Match 'ai-usagebar-tui" --help'
    }

    It 'does not mark AI Usagebar configured when the Windows binary is blocked by policy' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $binDir = Get-BootstrapAiBinDir -InstallRoot $script:AiToolsTestRoot
        $null = New-Item -Path $binDir -ItemType Directory -Force
        $binaryPath = Join-Path $binDir 'ai-usagebar.exe'
        $null = New-Item -Path $binaryPath -ItemType File -Force
        Mock Invoke-BootstrapAiUsagebarCommandProbe {
            return [ordered]@{
                ok = $false
                status = 'blocked'
                path = 'C:\fixture\ai-usagebar.exe'
                version = ''
                message = 'Application Control blocked this file.'
            }
        }
        Mock Test-BootstrapAiUsagebarNativeConfigured { return $true }
        Mock Test-BootstrapAiUsagebarWslConfigured { return $false }

        $emptyPath = Join-Path $script:AiToolsTestRoot 'empty-path'
        $null = New-Item -Path $emptyPath -ItemType Directory -Force
        $savedPath = $env:Path
        try {
            $env:Path = $emptyPath
            $row = @(Get-BootstrapAiToolStatusRows -InstallRoot $script:AiToolsTestRoot -ProjectRoot $repoRoot | Where-Object { [string]$_['tool'] -eq 'ai-usagebar' } | Select-Object -First 1)
        } finally {
            $env:Path = $savedPath
        }

        [string]$row[0]['status'] | Should Be 'blocked'
        [string]$row[0]['configured'] | Should Be 'False'
        [string]$row[0]['commandPath'] | Should Be $binaryPath
    }

    It 'declares AI Usagebar as an installable component outside safe public profiles' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $components = Get-BootstrapComponentCatalog
        $profiles = Get-BootstrapProfileCatalog

        $components.Contains('ai-usagebar') | Should Be $true
        [string]$components['ai-usagebar'].Kind | Should Be 'ai-usagebar'
        (@($components['ai-usagebar'].DependsOn) -contains 'git-core') | Should Be $true
        (@($profiles['ai'].Items) -contains 'ai-usagebar') | Should Be $true
        (@($profiles['safe-base'].Items) -contains 'ai-usagebar') | Should Be $false
        (@($profiles['public-beta'].Items) -contains 'ai-usagebar') | Should Be $false
    }

    It 'declares AionUI as an on-demand AI component outside safe-base' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $components = Get-BootstrapComponentCatalog
        $profiles = Get-BootstrapProfileCatalog
        $apps = @(Get-BootstrapOnDemandAppDefinitions)

        $components.Contains('aionui') | Should Be $true
        [string]$components['aionui'].Kind | Should Be 'aionui'
        (@($profiles['ai'].Items) -contains 'aionui') | Should Be $true
        (@($profiles['safe-base'].Items) -contains 'aionui') | Should Be $false
        (@($profiles['public-beta'].Items) -contains 'aionui') | Should Be $false
        (@($apps | Where-Object { [string]$_['id'] -eq 'app-aionui' }).Count) | Should Be 1
    }

    It 'generates Antigravity workflow templates without external dependencies' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $result = Invoke-BootstrapAiToolAction -ToolName 'antigravity-workflows' -Action 'configure' -InstallRoot $script:AiToolsTestRoot -ProjectRoot $script:AiToolsTestRoot -Yes

        [string]$result.status | Should Be 'configured'
        foreach ($name in @('planning.md','backend.md','frontend.md','tests.md','review.md')) {
            Test-Path -LiteralPath (Join-Path $script:AiToolsTestRoot (Join-Path '.antigravity\workflows' $name)) | Should Be $true
        }
    }

    It 'prefers Windows npm command shims over extensionless package files' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $prefix = Join-Path (Join-Path $script:AiToolsTestRoot 'managed tools root') 'npm-prefix'
        $null = New-Item -Path $prefix -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $prefix 'opencode') -Value '#!/bin/sh' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $prefix 'opencode.cmd') -Value '@echo off' -Encoding ascii

        $catalog = Get-BootstrapAiToolCatalog
        $resolved = Resolve-BootstrapAiToolCommandPath -CatalogEntry $catalog['opencode'] -InstallRoot (Join-Path $script:AiToolsTestRoot 'managed tools root')

        [System.IO.Path]::GetFileName($resolved) | Should Be 'opencode.cmd'
    }

    It 'exposes install-cli AI flags with structured JSON result' {
        $resultPath = Join-Path $script:AiToolsTestRoot 'result.json'
        $logPath = Join-Path $script:AiToolsTestRoot 'ai-tools.log'
        $rootWithSpaces = Join-Path $script:AiToolsTestRoot 'managed tools root'

        $result = Invoke-InstallCliBat -Args @('--tool','claude-code','--validate','--dry-run','--yes','--no-admin','--install-root',$rootWithSpaces,'--result-path',$resultPath,'--log-path',$logPath)

        $result.ExitCode | Should Be 0
        ([string]::IsNullOrWhiteSpace($result.Stderr)) | Should Be $true
        Test-Path -LiteralPath $resultPath | Should Be $true
        Test-Path -LiteralPath $logPath | Should Be $true
        $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        [string]$json.mode | Should Be 'ai-tools'
        [string]$json.action | Should Be 'validate'
        [string]$json.installRoot | Should Be $rootWithSpaces
        @($json.diagnostics).Count | Should Be 0
    }

    It 'accepts explicit install flag for transcript manual AI tools through install-cli' {
        $resultPath = Join-Path $script:AiToolsTestRoot 'printing-press-install-result.json'
        $logPath = Join-Path $script:AiToolsTestRoot 'printing-press-install.log'

        $result = Invoke-InstallCliBat -Args @('--tool','printing-press','--install','--dry-run','--yes','--no-admin','--install-root',$script:AiToolsTestRoot,'--result-path',$resultPath,'--log-path',$logPath)

        $result.ExitCode | Should Be 0
        ([string]::IsNullOrWhiteSpace($result.Stderr)) | Should Be $true
        $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        [string]$json.mode | Should Be 'ai-tools'
        [string]$json.action | Should Be 'install'
        [string]$json.tool | Should Be 'printing-press'
        [string]$json.status | Should Be 'planned'
        [bool]$json.dryRun | Should Be $true
    }

    It 'passes ai-proxy-suite start dry-run through install-cli without starting processes' {
        $resultPath = Join-Path $script:AiToolsTestRoot 'ai-proxy-start-result.json'
        $logPath = Join-Path $script:AiToolsTestRoot 'ai-proxy-start.log'
        $rootWithSpaces = Join-Path $script:AiToolsTestRoot 'proxy root with spaces'

        $result = Invoke-InstallCliBat -Args @('--tool','ai-proxy-suite','--start','--dry-run','--yes','--no-admin','--install-root',$rootWithSpaces,'--result-path',$resultPath,'--log-path',$logPath)

        $result.ExitCode | Should Be 0
        ([string]::IsNullOrWhiteSpace($result.Stderr)) | Should Be $true
        $jsonText = Get-Content -LiteralPath $resultPath -Raw
        $json = $jsonText | ConvertFrom-Json
        [string]$json.mode | Should Be 'ai-tools'
        [string]$json.action | Should Be 'start'
        [string]$json.tool | Should Be 'ai-proxy-suite'
        [string]$json.status | Should Be 'planned'
        @($json.results[0].startResults).Count | Should BeGreaterThan 0
        $jsonText | Should Not Match 'API_KEY|QWEN_PASSWORD|SERVICE_TOKEN|USER_ID|XIAOMI_CHATBOT_PH|sk-'
    }

    It 'lists individual AI proxy tools and accepts Antigravity proxy alias for start dry-run' {
        $list = Invoke-InstallCliBat -Args @('--list-tools','--yes','--no-admin')

        $list.ExitCode | Should Be 0
        ([string]::IsNullOrWhiteSpace($list.Stderr)) | Should Be $true
        foreach ($expected in @('kimiproxy','qwenproxy','deepsproxy','mimo-ai-proxy','antigravity-openai-adapter','antigravity-proxy')) {
            $list.Stdout | Should Match ([regex]::Escape($expected))
        }
        $list.Stdout | Should Match 'install'
        $list.Stdout | Should Match 'start'
        $list.Stdout | Should Match '(?m)^\s*\d+\.\s+\[tool\]\s+'

        $resultPath = Join-Path $script:AiToolsTestRoot 'antigravity-proxy-start-result.json'
        $logPath = Join-Path $script:AiToolsTestRoot 'antigravity-proxy-start.log'
        $rootWithSpaces = Join-Path $script:AiToolsTestRoot 'proxy root with spaces'

        $result = Invoke-InstallCliBat -Args @('--tool','antigravity-proxy','--start','--dry-run','--yes','--no-admin','--install-root',$rootWithSpaces,'--result-path',$resultPath,'--log-path',$logPath)

        $result.ExitCode | Should Be 0
        ([string]::IsNullOrWhiteSpace($result.Stderr)) | Should Be $true
        $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        [string]$json.mode | Should Be 'ai-tools'
        [string]$json.action | Should Be 'start'
        [string]$json.tool | Should Be 'antigravity-openai-adapter'
        [string]$json.status | Should Be 'planned'

        $mimo = Invoke-InstallCliBat -Args @('--tool','mimo','--install','--dry-run','--yes','--no-admin','--install-root',$rootWithSpaces)

        $mimo.ExitCode | Should Be 0
        ([string]::IsNullOrWhiteSpace($mimo.Stderr)) | Should Be $true
        $mimoJson = $mimo.Stdout | ConvertFrom-Json
        [string]$mimoJson.tool | Should Be 'mimo-ai-proxy'
        [string]$mimoJson.status | Should Be 'planned'
    }

    It 'returns non-zero when ai proxy start is blocked' {
        $resultPath = Join-Path $script:AiToolsTestRoot 'ai-proxy-start-blocked-result.json'
        $logPath = Join-Path $script:AiToolsTestRoot 'ai-proxy-start-blocked.log'
        $emptyRoot = Join-Path $script:AiToolsTestRoot 'empty proxy root'

        $result = Invoke-InstallCliBat -Args @('--tool','mimo-ai-proxy','--start','--yes','--no-admin','--install-root',$emptyRoot,'--result-path',$resultPath,'--log-path',$logPath)

        $result.ExitCode | Should Be 3
        $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        [string]$json.action | Should Be 'start'
        [string]$json.tool | Should Be 'mimo-ai-proxy'
        [string]$json.status | Should Be 'blocked'
    }

    It 'accepts AionUI validate through install-cli with redacted JSON' {
        $resultPath = Join-Path $script:AiToolsTestRoot 'aionui-result.json'
        $logPath = Join-Path $script:AiToolsTestRoot 'aionui.log'

        $result = Invoke-InstallCliBat -Args @('--tool','aionui','--validate','--yes','--no-admin','--install-root',$script:AiToolsTestRoot,'--result-path',$resultPath,'--log-path',$logPath)

        $result.ExitCode | Should Be 0
        ([string]::IsNullOrWhiteSpace($result.Stderr)) | Should Be $true
        $jsonText = Get-Content -LiteralPath $resultPath -Raw
        $json = $jsonText | ConvertFrom-Json
        [string]$json.tool | Should Be 'aionui'
        [string]$json.action | Should Be 'validate'
        $jsonText | Should Not Match 'sk-|sk-or-|sk-ant-|ghp_|github_pat_|protectedData'
        $jsonText | Should Not Match 'OPENAI_API_KEY|ANTHROPIC_API_KEY|GEMINI_API_KEY|GOOGLE_API_KEY|OPENROUTER_API_KEY'
    }

    It 'plans AionUI dry-run without downloading and reports arch plus env providers without values' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $oldOpenAi = $env:OPENAI_API_KEY
        $oldOpenRouter = $env:OPENROUTER_API_KEY
        if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) { $env:OPENAI_API_KEY = 'phasezero-test-openai-present' }
        if ([string]::IsNullOrWhiteSpace($env:OPENROUTER_API_KEY)) { $env:OPENROUTER_API_KEY = "phasezero-test-router-one`nphasezero-test-router-two" }
        try {
            $result = Invoke-BootstrapAiToolAction -ToolName 'aion-ui' -Action 'install' -InstallRoot $script:AiToolsTestRoot -ProjectRoot $repoRoot -DryRun -Yes -NoAdmin
            $json = $result | ConvertTo-Json -Depth 10

            [string]$result.tool | Should Be 'aionui'
            [string]$result.status | Should Be 'planned'
            [string]$result.source | Should Be 'winget'
            [string]$result.wingetId | Should Be 'iOfficeAI.AionUi'
            [string]$result.architecture | Should Match '^(x64|arm64)$'
            (@($result.providerEnv | Where-Object { [string]$_['provider'] -eq 'openai' -and [bool]$_['envPresent'] }).Count) | Should Be 1
            (@($result.providerEnv | Where-Object { [string]$_['provider'] -eq 'openrouter' -and [int]$_['keyCount'] -ge 1 }).Count) | Should Be 1
            $json | Should Not Match 'phasezero-test-openai-present|phasezero-test-router-one|phasezero-test-router-two'
            $json | Should Not Match 'OPENAI_API_KEY|OPENROUTER_API_KEY'
        } finally {
            if ($null -eq $oldOpenAi) { Remove-Item Env:\OPENAI_API_KEY -ErrorAction SilentlyContinue } else { $env:OPENAI_API_KEY = $oldOpenAi }
            if ($null -eq $oldOpenRouter) { Remove-Item Env:\OPENROUTER_API_KEY -ErrorAction SilentlyContinue } else { $env:OPENROUTER_API_KEY = $oldOpenRouter }
        }
    }

    It 'maps AionUI provider env candidates and preserves multi-key rotation metadata' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $names = @('OPENAI_API_KEY','ANTHROPIC_API_KEY','GEMINI_API_KEY','GOOGLE_API_KEY','OPENROUTER_API_KEY','DEEPSEEK_API_KEY','XAI_API_KEY','DASHSCOPE_API_KEY','QWEN_API_KEY','ZAI_API_KEY')
        $old = @{}
        foreach ($name in $names) {
            $old[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ([string]::IsNullOrWhiteSpace([string]$old[$name])) {
                [Environment]::SetEnvironmentVariable($name, ('phasezero-test-' + $name.ToLowerInvariant()), 'Process')
            }
        }
        [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', "phasezero-test-router-one,phasezero-test-router-two`nphasezero-test-router-three", 'Process')
        try {
            $candidates = @(Get-BootstrapAionUiEnvProviderCandidates)
            foreach ($provider in @('openai','anthropic','gemini','openrouter','deepseek','xai','dashscope','qwen','zai')) {
                (@($candidates | Where-Object { [string]$_['provider'] -eq $provider -and [bool]$_['envPresent'] }).Count) | Should Be 1
            }
            $openrouter = @($candidates | Where-Object { [string]$_['provider'] -eq 'openrouter' } | Select-Object -First 1)
            [int]$openrouter[0]['keyCount'] | Should Be 3
            [bool]$openrouter[0]['rotationSupported'] | Should Be $true
            ($candidates | ConvertTo-Json -Depth 8) | Should Not Match 'phasezero-test-|OPENROUTER_API_KEY|OPENAI_API_KEY'
        } finally {
            foreach ($name in $names) {
                [Environment]::SetEnvironmentVariable($name, $old[$name], 'Process')
            }
        }
    }

    It 'rejects unknown AI tools with a non-zero exit and diagnostic' {
        $result = Invoke-InstallCliBat -Args @('--tool','not-a-real-tool','--validate','--dry-run','--yes')

        ($result.ExitCode -ne 0) | Should Be $true
        ($result.Stdout + $result.Stderr) | Should Match 'not-a-real-tool'
    }

    It 'adds the AI Coding Tools UI controls and no known PT-BR mojibake' {
        $raw = Get-Content -LiteralPath $uiScriptPath -Raw

        $raw | Should Match 'AI Coding Tools'
        foreach ($name in @('PageAiTools','AiToolsGrid','AiToolsInstallButton','AiToolsValidateButton','AiToolsConfigureButton','AiToolsUninstallButton','AiToolsClearButton','AiToolsDocsButton','AiToolsStatusLabel')) {
            $raw | Should Match $name
        }
        $raw | Should Not Match 'Configurao|Verso|RPIDOS|Configuraes|sade|Resolucao'
    }

    It 'declares ai-memory catalog entry with native-release and verified fields' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $catalog = Get-BootstrapAiToolCatalog
        $catalog.Contains('ai-memory') | Should Be $true
        [string]$catalog['ai-memory'].GitHubRepo | Should Be 'akitaonrails/ai-memory'
        [string]$catalog['ai-memory'].InstallSupport | Should Be 'native-release'
        [string]$catalog['ai-memory'].ReleaseTag | Should Be 'v1.1.0'
        [string]$catalog['ai-memory'].ServerUrl | Should Be 'http://127.0.0.1:49374'
        [string]$catalog['ai-memory'].ReleaseAssets['windows'].Name | Should Be 'ai-memory-windows-x86_64.zip'
        [string]$catalog['ai-memory'].ReleaseAssets['windows'].Sha256 | Should Match '^[a-f0-9]{64}$'
    }

    It 'normalizes ai-memory aliases correctly' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        Normalize-BootstrapAiToolName -ToolName 'aimemory' | Should Be 'ai-memory'
        Normalize-BootstrapAiToolName -ToolName 'ai-mem' | Should Be 'ai-memory'
        Normalize-BootstrapAiToolName -ToolName 'memory' | Should Be 'ai-memory'
    }

    It 'reports ai-memory as missing when not installed' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        Mock Get-BootstrapAiMemoryExePath { return '' }
        Test-BootstrapAiToolConfigured -ToolName 'ai-memory' | Should Be $false
    }

    It 'plans ai-memory install through a verified native release path' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $catalog = Get-BootstrapAiToolCatalog
        $entry = $catalog['ai-memory']
        [string]$entry.InstallSupport | Should Be 'native-release'
        $entry.ReleaseAssets.Contains('windows') | Should Be $true
    }

    It 'keeps ai-memory doctor source free of secret logging' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $source = Get-Content -LiteralPath $toolsScriptPath -Raw
        $functionStart = $source.IndexOf('function New-BootstrapAiMemoryDoctorReport')
        $functionEnd = $source.IndexOf('function ', $functionStart + 10)
        if ($functionEnd -le $functionStart) { $functionEnd = $source.Length }
        $body = $source.Substring($functionStart, $functionEnd - $functionStart)

        $body | Should Not Match 'api_key|API_KEY|ApiKey'
        $body | Should Not Match 'ghp_|gho_|ghu_'
    }

    It 'adds ai-memory to the on-demand app catalog' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $onDemand = Get-BootstrapOnDemandAppDefinitions
        $memory = @($onDemand | Where-Object { $_.id -eq 'app-ai-memory' })
        $memory.Count | Should Be 1
        [string]$memory[0].category | Should Be 'ia'
    }

    It 'declares ai-memory in the tool catalog with correct metadata' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $catalog = Get-BootstrapAiToolCatalog
        $comp = $catalog['ai-memory']
        $comp | Should Not Be $null
        [string]$comp.ToolName | Should Be 'ai-memory'
        [string]$comp.InstallSupport | Should Be 'native-release'
        [string]$comp.ServerUrl | Should Be 'http://127.0.0.1:49374'
    }

    It 'includes ai-memory in the ai profile' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $profiles = Get-BootstrapProfileCatalog
        $aiProfile = $profiles['ai']
        $aiProfile | Should Not Be $null
        (@($aiProfile.Items) -contains 'ai-memory') | Should Be $true
    }

    It 'keeps WSL bash translation failures out of successful AI Usagebar Cargo fallback messages' {
        . $toolsScriptPath -BootstrapUiLibraryMode

        $catalog = Get-BootstrapAiToolCatalog

        Mock Test-BootstrapHostIsWindows { return $true }
        Mock Install-BootstrapAiUsagebarViaWsl { throw "Falha ao instalar ai-usagebar no WSL/Linux (exit=127). wsl: Failed to translate 'F:\Projects\PhaseZero' /bin/sh: bash: not found" }
        $script:UsagebarCargoBlockedReason = ''
        Mock Install-BootstrapAiUsagebarViaCargo {
            param(
                [System.Collections.IDictionary]$CatalogEntry,
                [string]$InstallRoot,
                [string]$ProjectRoot,
                [string]$BlockedReason
            )
            [void]$CatalogEntry
            [void]$InstallRoot
            [void]$ProjectRoot
            $script:UsagebarCargoBlockedReason = $BlockedReason
            $message = 'ai-usagebar instalado por fallback Cargo na tag oficial.'
            $fallbackNote = Get-BootstrapAiUsagebarWslFallbackNote -Reason $BlockedReason
            if (-not [string]::IsNullOrWhiteSpace($fallbackNote)) { $message = "$message $fallbackNote" }
            return [ordered]@{ status = 'installed'; message = $message }
        }

        $result = Install-BootstrapAiUsagebar -CatalogEntry $catalog['ai-usagebar'] -InstallRoot $script:AiToolsTestRoot -ProjectRoot $repoRoot

        [string]$result.status | Should Be 'installed'
        [string]$result.message | Should Match 'fallback Cargo'
        [string]$result.message | Should Match 'WSL indisponivel'
        [string]$result.message | Should Not Match 'Falha ao instalar'
        [string]$result.message | Should Not Match 'Failed to translate'
        [string]$result.message | Should Not Match 'bash: not found'
        $script:UsagebarCargoBlockedReason | Should Match 'Failed to translate'
        Assert-MockCalled Install-BootstrapAiUsagebarViaCargo -Times 1 -Exactly
        Remove-Variable -Scope Script -Name UsagebarCargoBlockedReason -ErrorAction SilentlyContinue
    }
}
