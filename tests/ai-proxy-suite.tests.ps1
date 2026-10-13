$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsScriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

. $toolsScriptPath -BootstrapUiLibraryMode
Reset-BootstrapFileCmdlets
$script:RealAiProxyCatalogForTests = Get-BootstrapAiProxyCatalog

function New-AiProxySuiteTestRoot {
    $tempRoot = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($tempRoot)) { $tempRoot = $env:TMPDIR }
    if ([string]::IsNullOrWhiteSpace($tempRoot)) { $tempRoot = [System.IO.Path]::GetTempPath() }
    $root = Join-Path $tempRoot ("PhaseZero AI Proxy Suite {0}" -f ([Guid]::NewGuid().ToString('N')))
    $null = New-Item -Path $root -ItemType Directory -Force
    return $root
}

Describe 'AI proxy suite support' {
    BeforeEach {
        $script:AiProxySuiteRoot = New-AiProxySuiteTestRoot
    }

    AfterEach {
        Remove-Item -LiteralPath $script:AiProxySuiteRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name AiProxySuiteRoot -ErrorAction SilentlyContinue
    }

    It 'matches the cross-OS proxy manifest on repo and port (PZ-AUD-019)' {
        $issues = @(Test-PhaseZeroProxyManifestParity)
        $issues.Count | Should Be 0
        $manifest = Get-PhaseZeroProxyManifest
        $manifest | Should Not Be $null
        # Known divergences stay recorded as migrations, never silent.
        $mimo = @($manifest.proxies | Where-Object { $_.id -eq 'mimo-ai-proxy' })[0]
        [string]$mimo.auth.windows | Should Be 'env-session'
        [string]$mimo.migration.windowsAuth | Should Match 'PZ-AUD-019'
        $deeps = @($manifest.proxies | Where-Object { $_.id -eq 'deepsproxy' })[0]
        [string]$deeps.migration.windowsDefaultModel | Should Match 'PZ-AUD-019'
    }

    It 'declares pedrofariasx proxies and Docker Native Manager as default AI managed tools' {
        $catalog = Get-BootstrapAiToolCatalog
        $components = Get-BootstrapComponentCatalog
        $profiles = Get-BootstrapProfileCatalog
        $contract = Get-BootstrapUiContract

        $catalog.Contains('ai-proxy-suite') | Should Be $true
        foreach ($toolName in @('kimiproxy','qwenproxy','deepsproxy','mimo-ai-proxy','antigravity-openai-adapter','dockernativemanager')) {
            $catalog.Contains($toolName) | Should Be $true
            [string]$catalog[$toolName].GitHubRepo | Should Match '^pedrofariasx/'
            [string]$catalog[$toolName].RepoUrl | Should Match '^https://github.com/pedrofariasx/'
            [string]$catalog[$toolName].InstallSupport | Should Match '^git-'
            $components.Contains($toolName) | Should Be $true
            (@($profiles['legacy'].Items) -contains $toolName) | Should Be $true
            (@($profiles['ai'].Items) -contains $toolName) | Should Be $true
            (@($profiles['safe-base'].Items) -contains $toolName) | Should Be $false
            (@($profiles['public-beta'].Items) -contains $toolName) | Should Be $false
        }

        [bool]$contract.capabilities.aiProxySuite | Should Be $true
        [string]$catalog['kimiproxy'].DefaultModel | Should Be 'k2d6-thinking'
        [bool]$catalog['kimiproxy'].PreferredDefault | Should Be $true

        $ports = @('kimiproxy','qwenproxy','deepsproxy','mimo-ai-proxy','antigravity-openai-adapter' | ForEach-Object { [int]$catalog[$_].Port })
        @($ports | Select-Object -Unique).Count | Should Be $ports.Count

        foreach ($toolName in @('kimiproxy','qwenproxy','deepsproxy','mimo-ai-proxy')) {
            [bool]$catalog[$toolName].RequiresWebLoginValidation | Should Be $true
            [string]$catalog[$toolName].WebValidationKind | Should Match '^(browser-session|env-session)$'
        }
    }

    It 'plans KimiProxy install with unique port, Playwright and Kimi as preferred model' {
        $result = Invoke-BootstrapAiToolAction -ToolName 'kimi-proxy' -Action 'install' -InstallRoot $script:AiProxySuiteRoot -ProjectRoot $repoRoot -DryRun -Yes

        [string]$result.tool | Should Be 'kimiproxy'
        [string]$result.status | Should Be 'planned'
        [string]$result.repoUrl | Should Be 'https://github.com/pedrofariasx/kimiproxy.git'
        [int]$result.port | Should Be 3010
        [string]$result.baseUrl | Should Be 'http://127.0.0.1:3010/v1'
        [string]$result.defaultModel | Should Be 'k2d6-thinking'
        [bool]$result.playwright | Should Be $true
        [string]$result.message | Should Match 'npm install'
        [string]$result.message | Should Match 'playwright install chromium'
    }

    It 'repairs a managed proxy repository when fast-forward update diverges' {
        $catalog = Get-BootstrapAiProxyCatalog
        $sourceRoot = Get-BootstrapAiProxySourceRoot -ToolName 'qwenproxy' -InstallRoot $script:AiProxySuiteRoot
        New-Item -Path (Join-Path $sourceRoot '.git') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceRoot '.env') -Value 'API_KEY=redacted-test' -Encoding UTF8
        $script:ManagedRepoRepairCalled = $false

        Mock Resolve-CommandPath { return 'C:\Tools\git.exe' } -ParameterFilter { $Name -eq 'git' }
        Mock Invoke-BootstrapAiProxyInstallCommand {
            if ($Label -eq 'git pull') { throw "git pull falhou (exit=128). Diverging branches can't be fast-forwarded" }
            return [ordered]@{ exitCode = 0 }
        }
        Mock Repair-BootstrapAiProxyManagedRepository {
            $script:ManagedRepoRepairCalled = $true
            return [ordered]@{ repaired = $true; backupPath = 'C:\PhaseZero\repo-backup'; envRestored = $true }
        }

        Sync-BootstrapAiProxyRepository -CatalogEntry $catalog['qwenproxy'] -SourceRoot $sourceRoot

        [bool]$script:ManagedRepoRepairCalled | Should Be $true
        Assert-MockCalled Invoke-BootstrapAiProxyInstallCommand -ParameterFilter { $Label -eq 'git pull' } -Times 1 -Scope It
        Assert-MockCalled Repair-BootstrapAiProxyManagedRepository -Times 1 -Exactly -Scope It
    }

    It 'writes proxy env and manifest without exposing env secret values in result' {
        $oldQwenEmail = $env:QWEN_EMAIL
        $oldQwenPassword = $env:QWEN_PASSWORD
        $env:QWEN_EMAIL = 'phasezero-qwen@example.test'
        $env:QWEN_PASSWORD = 'phasezero-qwen-password-secret'
        try {
            $result = Invoke-BootstrapAiToolAction -ToolName 'qwenproxy' -Action 'configure' -InstallRoot $script:AiProxySuiteRoot -ProjectRoot $repoRoot -Yes
            $json = $result | ConvertTo-Json -Depth 12
            $envPath = [string]$result.envPath
            $envText = Get-Content -LiteralPath $envPath -Raw -Encoding UTF8

            [string]$result.status | Should Be 'configured'
            Test-Path -LiteralPath $envPath | Should Be $true
            $envText | Should Match 'PORT=3011'
            $envText | Should Match 'QWEN_EMAIL=phasezero-qwen@example.test'
            $envText | Should Match 'QWEN_PASSWORD=phasezero-qwen-password-secret'
        $json | Should Not Match 'phasezero-qwen@example.test|phasezero-qwen-password-secret'
        $json | Should Not Match 'QWEN_PASSWORD|QWEN_EMAIL'
        } finally {
            if ($null -eq $oldQwenEmail) { Remove-Item Env:\QWEN_EMAIL -ErrorAction SilentlyContinue } else { $env:QWEN_EMAIL = $oldQwenEmail }
            if ($null -eq $oldQwenPassword) { Remove-Item Env:\QWEN_PASSWORD -ErrorAction SilentlyContinue } else { $env:QWEN_PASSWORD = $oldQwenPassword }
        }
    }

    It 'adds a redacted web validation result to configure for browser-login proxies' {
        $result = Invoke-BootstrapAiToolAction -ToolName 'qwenproxy' -Action 'configure' -InstallRoot $script:AiProxySuiteRoot -ProjectRoot $repoRoot -Yes
        $json = $result | ConvertTo-Json -Depth 14

        [string]$result.status | Should Be 'configured'
        [bool]$result.webValidation.required | Should Be $true
        [string]$result.webValidation.kind | Should Be 'browser-session'
        [string]$result.webValidation.status | Should Be 'not-ready'
        [string]$result.webValidation.command | Should Be 'npm run login'
        $json | Should Not Match 'QWEN_PASSWORD|QWEN_EMAIL|phasezero-qwen|API_KEY'
    }

    It 'reports Mimo web session requirements without exposing secret env names or values' {
        $oldServiceToken = $env:SERVICE_TOKEN
        $oldServiceTokens = $env:SERVICE_TOKENS
        $oldUserId = $env:USER_ID
        $oldUserIds = $env:USER_IDS
        $oldPh = $env:XIAOMI_CHATBOT_PH
        $oldPhs = $env:XIAOMI_CHATBOT_PHS
        Remove-Item Env:\SERVICE_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\SERVICE_TOKENS -ErrorAction SilentlyContinue
        Remove-Item Env:\USER_ID -ErrorAction SilentlyContinue
        Remove-Item Env:\USER_IDS -ErrorAction SilentlyContinue
        Remove-Item Env:\XIAOMI_CHATBOT_PH -ErrorAction SilentlyContinue
        Remove-Item Env:\XIAOMI_CHATBOT_PHS -ErrorAction SilentlyContinue
        try {
            $result = Invoke-BootstrapAiToolAction -ToolName 'mimo-ai-proxy' -Action 'configure' -InstallRoot $script:AiProxySuiteRoot -ProjectRoot $repoRoot -Yes
            $json = $result | ConvertTo-Json -Depth 14

            [bool]$result.webValidation.required | Should Be $true
            [string]$result.webValidation.kind | Should Be 'env-session'
            [string]$result.webValidation.status | Should Be 'missing-credentials'
            @($result.webValidation.missing).Count | Should Be 3
            $json | Should Not Match 'SERVICE_TOKEN|SERVICE_TOKENS|USER_ID|USER_IDS|XIAOMI_CHATBOT_PH|XIAOMI_CHATBOT_PHS|API_KEY'
        } finally {
            if ($null -eq $oldServiceToken) { Remove-Item Env:\SERVICE_TOKEN -ErrorAction SilentlyContinue } else { $env:SERVICE_TOKEN = $oldServiceToken }
            if ($null -eq $oldServiceTokens) { Remove-Item Env:\SERVICE_TOKENS -ErrorAction SilentlyContinue } else { $env:SERVICE_TOKENS = $oldServiceTokens }
            if ($null -eq $oldUserId) { Remove-Item Env:\USER_ID -ErrorAction SilentlyContinue } else { $env:USER_ID = $oldUserId }
            if ($null -eq $oldUserIds) { Remove-Item Env:\USER_IDS -ErrorAction SilentlyContinue } else { $env:USER_IDS = $oldUserIds }
            if ($null -eq $oldPh) { Remove-Item Env:\XIAOMI_CHATBOT_PH -ErrorAction SilentlyContinue } else { $env:XIAOMI_CHATBOT_PH = $oldPh }
            if ($null -eq $oldPhs) { Remove-Item Env:\XIAOMI_CHATBOT_PHS -ErrorAction SilentlyContinue } else { $env:XIAOMI_CHATBOT_PHS = $oldPhs }
        }
    }

    It 'configures KimiProxy as default provider for IDE targets' {
        $oldUserProfile = $env:USERPROFILE
        $oldAppData = $env:APPDATA
        $oldLocalAppData = $env:LOCALAPPDATA
        $oldDataRoot = $env:BOOTSTRAP_DATA_ROOT
        $projectRoot = Join-Path $script:AiProxySuiteRoot 'Project'
        $env:USERPROFILE = Join-Path $script:AiProxySuiteRoot 'User'
        $env:APPDATA = Join-Path $script:AiProxySuiteRoot 'User\AppData\Roaming'
        $env:LOCALAPPDATA = Join-Path $script:AiProxySuiteRoot 'User\AppData\Local'
        $env:BOOTSTRAP_DATA_ROOT = Join-Path $script:AiProxySuiteRoot 'Data'
        New-Item -Path $projectRoot,$env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA,$env:BOOTSTRAP_DATA_ROOT -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $env:APPDATA 'clawdbot') -ItemType Directory -Force | Out-Null
        Write-BootstrapJsonFile -Path (Join-Path $env:USERPROFILE '.openclaw\openclaw.json') -Value ([ordered]@{
            mcpServers = [ordered]@{
                existing = [ordered]@{
                    command = 'npx'
                    args = @('-y','existing-mcp')
                    enabled = $true
                }
            }
            env = [ordered]@{
                LEGACY_VAR = 'kept'
            }
        })
        $openClawPath = Join-Path $env:USERPROFILE '.openclaw\openclaw.json'
        $openClawBefore = Get-Content -LiteralPath $openClawPath -Raw -Encoding UTF8
        try {
            $kimi = Invoke-BootstrapAiToolAction -ToolName 'kimiproxy' -Action 'configure' -InstallRoot $script:AiProxySuiteRoot -ProjectRoot $projectRoot -Yes
            $envMap = Read-BootstrapDotEnvFile -Path ([string]$kimi.envPath)
            $localKey = [string]$envMap['API_KEY']

            $result = Invoke-BootstrapAiToolAction -ToolName 'ai-proxy-suite' -Action 'configure' -InstallRoot $script:AiProxySuiteRoot -ProjectRoot $projectRoot -Yes
            $json = $result | ConvertTo-Json -Depth 20

            [string]$result.status | Should Be 'configured'
            [string]$result.defaultProvider | Should Be 'kimiproxy'
            [string]$result.defaultBaseUrl | Should Be 'http://127.0.0.1:3010/v1'
            [string]$result.defaultModel | Should Be 'k2d6-thinking'

            $continueConfig = Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.continue\config.yaml') -Raw -Encoding UTF8
            $continueEnv = Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.continue\.env') -Raw -Encoding UTF8
            $continueConfig | Should Match 'PhaseZero KimiProxy'
            $continueConfig | Should Match 'model: k2d6-thinking'
            $continueConfig | Should Match 'apiBase: http://127.0.0.1:3010/v1'
            $continueConfig | Should Match '\$\{\{ secrets.KIMIPROXY_API_KEY \}\}'
            $continueEnv | Should Match 'KIMIPROXY_API_KEY='
            $continueEnv | Should Match 'OPENAI_MODEL="?k2d6-thinking"?'

            $openCode = Read-BootstrapJsonFile -Path (Join-Path $env:USERPROFILE '.config\opencode\opencode.json')
            [string]$openCode.model | Should Be 'phasezero-kimi/k2d6-thinking'
            [string]$openCode.provider['phasezero-kimi'].options.baseURL | Should Be 'http://127.0.0.1:3010/v1'
            [string]$openCode.provider['phasezero-kimi'].options.apiKey | Should Be $localKey
            $openCodeAuth = Read-BootstrapJsonFile -Path (Join-Path $env:USERPROFILE '.local\share\opencode\auth.json')
            [string]$openCodeAuth['phasezero-kimi'].type | Should Be 'api'
            [string]$openCodeAuth['phasezero-kimi'].key | Should Be $localKey

            $kiloConfig = Read-BootstrapJsonFile -Path (Join-Path $env:USERPROFILE '.config\kilo\opencode.json')
            [string]$kiloConfig.model | Should Be 'phasezero-kimi/k2d6-thinking'
            [string]$kiloConfig.provider['phasezero-kimi'].options.baseURL | Should Be 'http://127.0.0.1:3010/v1'
            $kiloAuth = Read-BootstrapJsonFile -Path (Join-Path $env:USERPROFILE '.local\share\kilo\auth.json')
            [string]$kiloAuth['phasezero-kimi'].type | Should Be 'api'
            [string]$kiloAuth['phasezero-kimi'].key | Should Be $localKey

            $hermes = Read-BootstrapJsonFile -Path (Join-Path $projectRoot '.hermes\opencloud.json')
            [string]$hermes.env.OPENAI_BASE_URL | Should Be 'http://127.0.0.1:3010/v1'
            [string]$hermes.env.OPENAI_MODEL | Should Be 'k2d6-thinking'
            $hermesEnv = Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.hermes\.env') -Raw -Encoding UTF8
            $hermesConfig = Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.hermes\config.yaml') -Raw -Encoding UTF8
            $hermesEnv | Should Match 'KIMIPROXY_API_KEY='
            $hermesEnv | Should Match 'OPENAI_BASE_URL="?http://127\.0\.0\.1:3010/v1"?'
            $hermesConfig | Should Match 'custom_providers:'
            $hermesConfig | Should Match 'name: phasezero-kimi'
            $hermesConfig | Should Match 'provider: custom:phasezero-kimi'
            $hermesConfig | Should Match 'default: k2d6-thinking'

            (Get-Content -LiteralPath $openClawPath -Raw -Encoding UTF8) | Should Be $openClawBefore
            (Test-Path -LiteralPath (Join-Path $env:APPDATA 'clawdbot\clawdbot.json5')) | Should Be $false
            $directOpenClawWrite = Ensure-BootstrapOpenClawCompatibleConfigFile -Path $openClawPath -Target ([ordered]@{ env = [ordered]@{ OPENAI_API_KEY = $localKey } }) -Label 'OpenClaw config'
            [bool]$directOpenClawWrite | Should Be $false
            $directOpenClawSecrets = Ensure-BootstrapOpenClawSecrets -ResolvedTargets @{ openClaw = [ordered]@{ env = [ordered]@{ OPENAI_API_KEY = $localKey } } }
            [bool]$directOpenClawSecrets | Should Be $false
            (Get-Content -LiteralPath $openClawPath -Raw -Encoding UTF8) | Should Be $openClawBefore

            $coverage = Get-BootstrapAppChannelCoverageSummary -ResolvedTargets @{ openClaw = @{ env = @{ OPENAI_API_KEY = $localKey }; mcpServers = @{ fixture = @{ command = 'fixture' } } } } -OpenAiCompatible @{ status = 'selected' }
            $openClawCoverage = @($coverage.apps | Where-Object { [string]$_['id'] -eq 'openClaw' })[0]
            [string]$openClawCoverage.status | Should Be 'blocked'
            [bool]$openClawCoverage.byokApplied | Should Be $false
            [bool]$openClawCoverage.mcpApplied | Should Be $false

            $json | Should Not Match ([regex]::Escape($localKey))
        } finally {
            if ($null -eq $oldUserProfile) { Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue } else { $env:USERPROFILE = $oldUserProfile }
            if ($null -eq $oldAppData) { Remove-Item Env:\APPDATA -ErrorAction SilentlyContinue } else { $env:APPDATA = $oldAppData }
            if ($null -eq $oldLocalAppData) { Remove-Item Env:\LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $oldLocalAppData }
            if ($null -eq $oldDataRoot) { Remove-Item Env:\BOOTSTRAP_DATA_ROOT -ErrorAction SilentlyContinue } else { $env:BOOTSTRAP_DATA_ROOT = $oldDataRoot }
        }
    }

    It 'adds redacted proxy diagnostics to Doctor and SupportBundle' {
        $report = New-BootstrapAiProxySuiteDoctorReport -InstallRoot $script:AiProxySuiteRoot
        $doctor = [ordered]@{
            aiProxies = $report
            checks = @()
            auditResults = @()
            auditSummary = [ordered]@{ critical = 0; timedOut = 0 }
        }
        $repair = [ordered]@{ items = @() }
        $bundlePath = Join-Path $script:AiProxySuiteRoot 'support.zip'
        $bundle = New-BootstrapSupportBundle -DoctorReport $doctor -RepairPlan $repair -ResultPayload ([ordered]@{ status = 'success'; doctor = $doctor }) -DestinationPath $bundlePath

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $extractRoot = Join-Path $script:AiProxySuiteRoot 'extract'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($bundlePath, $extractRoot)
        # Normaliza para a forma longa: no runner $env:TEMP e 8.3 (RUNNER~1) e Get-ChildItem.FullName
        # retorna a forma longa; sem isso o Substring deixa o final de "extract" (ct\) como prefixo.
        Push-Location $extractRoot
        try { $extractRoot = (Get-Location).Path } finally { Pop-Location }
        $names = @(Get-ChildItem -Path $extractRoot -Recurse -File | ForEach-Object { $_.FullName.Substring($extractRoot.Length + 1) })
        $allText = @(Get-ChildItem -Path $extractRoot -Recurse -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join [Environment]::NewLine

        (@($bundle.included) -contains 'ai-proxy-suite.json') | Should Be $true
        (@($names) -contains 'ai-proxy-suite.json') | Should Be $true
        $allText | Should Not Match 'API_KEY|QWEN_PASSWORD|SERVICE_TOKEN|USER_ID|XIAOMI_CHATBOT_PH|sk-'
    }

    It 'does not mark a proxy configured when files exist but API is not listening' {
        $catalog = $script:RealAiProxyCatalogForTests
        $entry = ConvertTo-BootstrapHashtable -InputObject $catalog['kimiproxy']
        $entry['Port'] = 65534
        $entry['BaseUrl'] = 'http://127.0.0.1:65534/v1'
        $script:AiProxyCatalogOverride = [ordered]@{ kimiproxy = $entry }
        try {
            Mock Get-BootstrapAiProxyCatalog { return $script:AiProxyCatalogOverride }
            $sourceRoot = Get-BootstrapAiProxySourceRoot -ToolName 'kimiproxy' -InstallRoot $script:AiProxySuiteRoot
            New-Item -Path (Join-Path $sourceRoot '.git') -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path $sourceRoot 'node_modules') -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceRoot '.env') -Value @('PORT=65534','API_KEY=redacted-test') -Encoding UTF8

            $report = Get-BootstrapAiProxyToolDoctorReport -ToolName 'kimiproxy' -InstallRoot $script:AiProxySuiteRoot

            [bool]$report.filesConfigured | Should Be $true
            [bool]$report.runtimeReady | Should Be $true
            [bool]$report.listening | Should Be $false
            [string]$report.modelsStatus | Should Be 'unreachable'
            [string]$report.status | Should Be 'start-required'
            [bool]$report.configured | Should Be $false
        } finally {
            $script:AiProxyCatalogOverride = $script:RealAiProxyCatalogForTests
        }
    }

    It 'does not mark suite ready when providers are installed but stopped' {
        $catalog = $script:RealAiProxyCatalogForTests
        $entry = ConvertTo-BootstrapHashtable -InputObject $catalog['kimiproxy']
        $entry['Port'] = 65534
        $entry['BaseUrl'] = 'http://127.0.0.1:65534/v1'
        $script:AiProxyCatalogOverride = [ordered]@{ kimiproxy = $entry }
        try {
            Mock Get-BootstrapAiProxyCatalog { return $script:AiProxyCatalogOverride }
            $sourceRoot = Get-BootstrapAiProxySourceRoot -ToolName 'kimiproxy' -InstallRoot $script:AiProxySuiteRoot
            New-Item -Path (Join-Path $sourceRoot '.git') -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path $sourceRoot 'node_modules') -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceRoot '.env') -Value @('PORT=65534','API_KEY=redacted-test') -Encoding UTF8

            $suite = New-BootstrapAiProxySuiteDoctorReport -InstallRoot $script:AiProxySuiteRoot

            [string]$suite.status | Should Be 'start-required'
            [int]$suite.configuredProviders | Should Be 0
            [int]$suite.runtimeReadyProviders | Should Be 1
            [int]$suite.startRequiredProviders | Should Be 1
        } finally {
            $script:AiProxyCatalogOverride = $script:RealAiProxyCatalogForTests
        }
    }

    It 'marks a listening proxy with unhealthy /v1/models as unhealthy instead of start-required' {
        $sourceRoot = Get-BootstrapAiProxySourceRoot -ToolName 'antigravity-openai-adapter' -InstallRoot $script:AiProxySuiteRoot
        New-Item -Path (Join-Path $sourceRoot '.git'),(Join-Path $sourceRoot 'node_modules') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceRoot '.env') -Value @('PORT=8081','API_KEY=redacted-test') -Encoding UTF8
        Mock Get-BootstrapAiProxyRuntimeProbe {
            return [ordered]@{
                listening = $true
                pid = @(1234)
                processName = @('node')
                healthStatus = 'ok'
                healthStatusCode = 200
                modelsStatus = 'error'
                modelsStatusCode = 500
                healthUrl = 'http://127.0.0.1:8081/health'
                modelsUrl = 'http://127.0.0.1:8081/v1/models'
                runtimeAvailable = $false
                durationMs = 40
            }
        }

        $report = Get-BootstrapAiProxyToolDoctorReport -ToolName 'antigravity-openai-adapter' -InstallRoot $script:AiProxySuiteRoot

        [string]$report.status | Should Be 'unhealthy'
        [bool]$report.listening | Should Be $true
        [string]$report.modelsStatus | Should Be 'error'
        [bool]$report.configured | Should Be $false
    }

    It 'uses cached web validation in Doctor instead of running chat validation probes' {
        $sourceRoot = Get-BootstrapAiProxySourceRoot -ToolName 'kimiproxy' -InstallRoot $script:AiProxySuiteRoot
        New-Item -Path (Join-Path $sourceRoot '.git'),(Join-Path $sourceRoot 'node_modules') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceRoot '.env') -Value @('PORT=3010','API_KEY=redacted-test') -Encoding UTF8
        Write-BootstrapJsonFile -Path (Get-BootstrapAiProxyRuntimeStatePath -ToolName 'kimiproxy' -InstallRoot $script:AiProxySuiteRoot) -Value ([ordered]@{
            tool = 'kimiproxy'
            status = 'started'
            webValidationStatus = 'validated'
        })
        Mock Get-BootstrapAiProxyRuntimeProbe {
            return [ordered]@{
                listening = $true
                pid = @(1234)
                processName = @('node')
                healthStatus = 'ok'
                healthStatusCode = 200
                modelsStatus = 'ok'
                modelsStatusCode = 200
                healthUrl = 'http://127.0.0.1:3010/health'
                modelsUrl = 'http://127.0.0.1:3010/v1/models'
                runtimeAvailable = $true
                durationMs = 30
            }
        }
        Mock Invoke-BootstrapAiProxyChatValidation { throw 'Doctor must not run chat validation' }

        $report = Get-BootstrapAiProxyToolDoctorReport -ToolName 'kimiproxy' -InstallRoot $script:AiProxySuiteRoot

        [string]$report.status | Should Be 'configured'
        [string]$report.webValidation.status | Should Be 'validated'
        Assert-MockCalled Invoke-BootstrapAiProxyChatValidation -Times 0 -Exactly -Scope It
    }

    It 'marks suite degraded when one HTTP proxy is unhealthy even if a desktop tool is configured' {
        $catalog = $script:RealAiProxyCatalogForTests
        $script:AiProxyCatalogOverride = [ordered]@{
            kimiproxy = $catalog['kimiproxy']
            'antigravity-openai-adapter' = $catalog['antigravity-openai-adapter']
            dockernativemanager = $catalog['dockernativemanager']
        }
        try {
            Mock Get-BootstrapAiProxyCatalog { return $script:AiProxyCatalogOverride }
            Mock Get-BootstrapAiProxyToolDoctorReport {
                if ($ToolName -eq 'antigravity-openai-adapter') {
                    return [ordered]@{ id = 'antigravity-openai-adapter'; status = 'unhealthy'; configured = $false; runtimeReady = $true; port = 8081 }
                }
                if ($ToolName -eq 'dockernativemanager') {
                    return [ordered]@{ id = 'dockernativemanager'; status = 'configured'; configured = $true; runtimeReady = $true; port = 0 }
                }
                return [ordered]@{ id = 'kimiproxy'; status = 'configured'; configured = $true; runtimeReady = $true; port = 3010 }
            }

            $suite = New-BootstrapAiProxySuiteDoctorReport -InstallRoot $script:AiProxySuiteRoot

            [string]$suite.status | Should Be 'degraded'
            [int]$suite.configuredProviders | Should Be 1
            [int]$suite.unhealthyProviders | Should Be 1
        } finally {
            $script:AiProxyCatalogOverride = $script:RealAiProxyCatalogForTests
        }
    }

    It 'plans a start action for ai-proxy-suite without starting processes in dry-run' {
        $result = Invoke-BootstrapAiToolAction -ToolName 'ai-proxy-suite' -Action 'start' -InstallRoot $script:AiProxySuiteRoot -ProjectRoot $repoRoot -DryRun -Yes

        [string]$result.status | Should Be 'planned'
        [string]$result.action | Should Be 'start'
        @($result.startResults).Count | Should BeGreaterThan 0
        [string]$result.message | Should Match 'Start'
    }

    It 'keeps suite start usable when the default provider is running and optional providers are degraded' {
        $classification = Get-BootstrapAiProxySuiteStartClassification -Items @(
            [ordered]@{ tool = 'kimiproxy'; status = 'running' },
            [ordered]@{ tool = 'qwenproxy'; status = 'error' },
            [ordered]@{ tool = 'deepsproxy'; status = 'started' },
            [ordered]@{ tool = 'mimo-ai-proxy'; status = 'error' },
            [ordered]@{ tool = 'antigravity-openai-adapter'; status = 'error' }
        )

        [string]$classification.status | Should Be 'degraded'
        [int]$classification.okCount | Should Be 2
        [int]$classification.degradedCount | Should Be 3
        [string]$classification.defaultProviderStatus | Should Be 'running'
    }

    It 'retries Playwright install when the cache lock is transiently compromised' {
        $catalog = Get-BootstrapAiProxyCatalog
        $sourceRoot = Get-BootstrapAiProxySourceRoot -ToolName 'kimiproxy' -InstallRoot $script:AiProxySuiteRoot
        New-Item -Path $sourceRoot -ItemType Directory -Force | Out-Null
        $script:PlaywrightInstallAttempts = 0

        Mock Get-BootstrapNpmCommandForAiTools { return 'C:\Tools\npm.cmd' }
        Mock Get-BootstrapNpxCommandForAiTools { return 'C:\Tools\npx.cmd' }
        Mock Clear-BootstrapPlaywrightStaleLock { }
        Mock Start-Sleep { }
        Mock Invoke-BootstrapAiProxyInstallCommand {
            $script:PlaywrightInstallAttempts++
            if ($script:PlaywrightInstallAttempts -eq 1) {
                throw "playwright install chromium falhou (exit=1). Error: ENOENT: no such file or directory, stat 'C:\Users\misae\AppData\Local\ms-playwright\__dirlock'"
            }
            return [ordered]@{ exitCode = 0 }
        }

        $result = Ensure-BootstrapAiProxyPlaywrightRuntime -CatalogEntry $catalog['kimiproxy'] -SourceRoot $sourceRoot

        [string]$result.status | Should Be 'ready'
        [int]$script:PlaywrightInstallAttempts | Should Be 2
        Assert-MockCalled Invoke-BootstrapAiProxyInstallCommand -Times 2 -Exactly -Scope It
    }

    It 'repairs Playwright browsers before starting browser-session node proxies' {
        $sourceRoot = Get-BootstrapAiProxySourceRoot -ToolName 'kimiproxy' -InstallRoot $script:AiProxySuiteRoot
        New-Item -Path (Join-Path $sourceRoot '.git'),(Join-Path $sourceRoot 'node_modules') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceRoot '.env') -Value @('PORT=3010','API_KEY=redacted-test') -Encoding UTF8

        Mock Get-BootstrapAiProxyToolDoctorReport {
            return [ordered]@{
                installed = $true
                filesConfigured = $true
                runtimeReady = $true
                runtimeAvailable = $false
                listening = $false
                pid = @()
                healthStatus = 'unreachable'
                healthStatusCode = 0
                modelsStatus = 'unreachable'
                modelsStatusCode = 0
                modelsUrl = 'http://127.0.0.1:3010/v1/models'
            }
        }
        Mock Ensure-BootstrapAiProxyPlaywrightRuntime {
            return [ordered]@{ status = 'ready'; changed = $true }
        }
        Mock Start-Process { return [pscustomobject]@{ Id = 6363 } }
        Mock Wait-BootstrapAiProxyRuntime {
            return [ordered]@{
                listening = $true
                pid = @(6363)
                healthStatus = 'ok'
                healthStatusCode = 200
                modelsStatus = 'ok'
                modelsStatusCode = 200
                modelsUrl = 'http://127.0.0.1:3010/v1/models'
                runtimeAvailable = $true
                waitDurationMs = 25
            }
        }
        Mock Invoke-BootstrapAiProxyWebValidation {
            return [ordered]@{ required = $true; kind = 'browser-session'; status = 'validated'; command = 'npm run login'; missing = @(); durationMs = 5; recommendedAction = '' }
        }

        $result = Start-BootstrapAiProxyTool -ToolName 'kimiproxy' -InstallRoot $script:AiProxySuiteRoot -TimeoutMs 1000

        [string]$result.status | Should Be 'started'
        [int]$result.pid | Should Be 6363
        Assert-MockCalled Ensure-BootstrapAiProxyPlaywrightRuntime -Times 1 -Exactly -Scope It
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It
    }

    It 'starts a Go proxy executable without requiring an ArgumentList' {
        $sourceRoot = Get-BootstrapAiProxySourceRoot -ToolName 'mimo-ai-proxy' -InstallRoot $script:AiProxySuiteRoot
        $binDir = Join-Path $sourceRoot 'bin'
        New-Item -Path (Join-Path $sourceRoot '.git'),$binDir -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceRoot '.env') -Value @('PORT=3013','API_KEY=redacted-test') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $binDir 'mimo-ai-proxy.exe') -Value 'test-binary-placeholder' -Encoding ASCII

        Mock Get-BootstrapAiProxyToolDoctorReport {
            return [ordered]@{
                installed = $true
                filesConfigured = $true
                runtimeReady = $true
                runtimeAvailable = $false
                listening = $false
                pid = @()
                healthStatus = 'unreachable'
                healthStatusCode = 0
                modelsStatus = 'unreachable'
                modelsStatusCode = 0
                modelsUrl = 'http://127.0.0.1:3013/v1/models'
            }
        }
        Mock Start-Process { return [pscustomobject]@{ Id = 4242 } }
        Mock Wait-BootstrapAiProxyRuntime {
            return [ordered]@{
                listening = $true
                pid = @(4242)
                healthStatus = 'ok'
                healthStatusCode = 200
                modelsStatus = 'ok'
                modelsStatusCode = 200
                modelsUrl = 'http://127.0.0.1:3013/v1/models'
                runtimeAvailable = $true
                waitDurationMs = 25
            }
        }
        Mock Invoke-BootstrapAiProxyWebValidation {
            return [ordered]@{ required = $true; kind = 'env-session'; status = 'validated'; command = 'configure Mimo/Xiaomi session environment'; missing = @(); durationMs = 5; recommendedAction = '' }
        }

        $result = Start-BootstrapAiProxyTool -ToolName 'mimo-ai-proxy' -InstallRoot $script:AiProxySuiteRoot -TimeoutMs 1000

        [string]$result.status | Should Be 'started'
        [int]$result.pid | Should Be 4242
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It
        Assert-MockCalled Wait-BootstrapAiProxyRuntime -Times 1 -Exactly -Scope It
    }

    It 'falls back to go run when the compiled Go proxy exe is blocked by policy' {
        $sourceRoot = Get-BootstrapAiProxySourceRoot -ToolName 'mimo-ai-proxy' -InstallRoot $script:AiProxySuiteRoot
        $binDir = Join-Path $sourceRoot 'bin'
        New-Item -Path (Join-Path $sourceRoot '.git'),$binDir -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceRoot '.env') -Value @('PORT=3013','API_KEY=redacted-test') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $binDir 'mimo-ai-proxy.exe') -Value 'test-binary-placeholder' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $sourceRoot 'main.go') -Value 'package main' -Encoding ASCII

        Mock Get-BootstrapAiProxyToolDoctorReport {
            return [ordered]@{
                installed = $true
                filesConfigured = $true
                runtimeReady = $true
                runtimeAvailable = $false
                listening = $false
                pid = @()
                healthStatus = 'unreachable'
                healthStatusCode = 0
                modelsStatus = 'unreachable'
                modelsStatusCode = 0
                modelsUrl = 'http://127.0.0.1:3013/v1/models'
            }
        }
        Mock Resolve-CommandPath { return 'C:\Tools\go.exe' } -ParameterFilter { $Name -eq 'go' }
        Mock Start-Process {
            if ([string]$FilePath -match 'mimo-ai-proxy\.exe$') { throw 'App Control blocked exe' }
            return [pscustomobject]@{ Id = 5252 }
        }
        Mock Wait-BootstrapAiProxyRuntime {
            return [ordered]@{
                listening = $true
                pid = @(5252)
                healthStatus = 'ok'
                healthStatusCode = 200
                modelsStatus = 'ok'
                modelsStatusCode = 200
                modelsUrl = 'http://127.0.0.1:3013/v1/models'
                runtimeAvailable = $true
                waitDurationMs = 25
            }
        }
        Mock Invoke-BootstrapAiProxyWebValidation {
            return [ordered]@{ required = $true; kind = 'env-session'; status = 'validated'; command = 'configure Mimo/Xiaomi session environment'; missing = @(); durationMs = 5; recommendedAction = '' }
        }

        $result = Start-BootstrapAiProxyTool -ToolName 'mimo-ai-proxy' -InstallRoot $script:AiProxySuiteRoot -TimeoutMs 1000

        [string]$result.status | Should Be 'started'
        [int]$result.pid | Should Be 5252
        Assert-MockCalled Start-Process -Times 2 -Exactly -Scope It
        Assert-MockCalled Resolve-CommandPath -ParameterFilter { $Name -eq 'go' } -Times 1 -Scope It
    }

    It 'does not start a duplicate process when a proxy is listening but /v1/models is unhealthy' {
        Mock Get-BootstrapAiProxyToolDoctorReport {
            return [ordered]@{
                installed = $true
                filesConfigured = $true
                runtimeReady = $true
                runtimeAvailable = $false
                listening = $true
                pid = @(1234)
                healthStatus = 'ok'
                healthStatusCode = 200
                modelsStatus = 'error'
                modelsStatusCode = 500
                modelsUrl = 'http://127.0.0.1:8081/v1/models'
            }
        }
        Mock Start-Process { throw 'should not start duplicate listener' }

        $result = Start-BootstrapAiProxyTool -ToolName 'antigravity-openai-adapter' -InstallRoot $script:AiProxySuiteRoot -TimeoutMs 1000

        [string]$result.status | Should Be 'error'
        [string]$result.message | Should Match 'ouvindo'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }

    It 'keeps an already running proxy successful when chat validation times out' {
        Mock Get-BootstrapAiProxyToolDoctorReport {
            return [ordered]@{
                installed = $true
                filesConfigured = $true
                runtimeReady = $true
                runtimeAvailable = $true
                listening = $true
                pid = @(16276)
                processName = @('node')
                healthStatus = 'ok'
                healthStatusCode = 200
                modelsStatus = 'ok'
                modelsStatusCode = 200
                healthUrl = 'http://127.0.0.1:3011/health'
                modelsUrl = 'http://127.0.0.1:3011/v1/models'
                runtimeProbeDurationMs = 20
            }
        }
        Mock Invoke-BootstrapAiProxyWebValidation {
            return [ordered]@{ required = $true; kind = 'browser-session'; status = 'timeout'; command = 'npm run login'; missing = @(); durationMs = 10000; recommendedAction = 'login manual' }
        }
        Mock Start-Process { throw 'should not start duplicate listener' }

        $result = Start-BootstrapAiProxyTool -ToolName 'qwenproxy' -InstallRoot $script:AiProxySuiteRoot -TimeoutMs 1000

        [string]$result.status | Should Be 'running'
        [string]$result.message | Should Match 'validacao web esta timeout'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }

    It 'treats a listening browser-session proxy with healthy /health and slow /v1/models as running' {
        Mock Get-BootstrapAiProxyToolDoctorReport {
            return [ordered]@{
                installed = $true
                filesConfigured = $true
                runtimeReady = $true
                runtimeAvailable = $false
                listening = $true
                pid = @(16276)
                processName = @('node')
                healthStatus = 'ok'
                healthStatusCode = 200
                modelsStatus = 'timeout'
                modelsStatusCode = 0
                modelsUrl = 'http://127.0.0.1:3011/v1/models'
                webValidation = [ordered]@{
                    required = $true
                    kind = 'browser-session'
                    status = 'failed'
                    command = 'npm run login'
                    missing = @()
                }
            }
        }
        Mock Start-Process { throw 'should not start duplicate listener' }

        $result = Start-BootstrapAiProxyTool -ToolName 'qwenproxy' -InstallRoot $script:AiProxySuiteRoot -TimeoutMs 1000

        [string]$result.status | Should Be 'running'
        [string]$result.message | Should Match '/health esta ok'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
}
