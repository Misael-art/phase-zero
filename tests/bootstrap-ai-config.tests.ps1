$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

. $scriptPath
Reset-BootstrapFileCmdlets

function Invoke-AiConfigBootstrapForTest {
    param([string[]]$CommandArgs)

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $CommandArgs
    $quotedArgs = foreach ($arg in $allArgs) {
        if ($arg -match '[\s"]') { '"' + ($arg -replace '"', '\"') + '"' } else { $arg }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellExe
    $startInfo.Arguments = [string]::Join(' ', $quotedArgs)
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Failed to start bootstrap process: $($CommandArgs -join ' ')" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(120000)) {
        try { $process.Kill() } catch { Write-Verbose $_.Exception.Message }
        throw "Bootstrap invocation timed out: $($CommandArgs -join ' ')"
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = @($stdoutTask.Result, $stderrTask.Result) -join [Environment]::NewLine
    }
}

Describe 'PhaseZero AI Config Doctor and Sync' {
    BeforeEach {
        $script:AiConfigTestRoot = Join-Path $env:TEMP ("phasezero_ai_config_{0}" -f ([Guid]::NewGuid().ToString('N')))
        $null = New-Item -Path $script:AiConfigTestRoot -ItemType Directory -Force
    }

    AfterEach {
        Remove-Item -LiteralPath $script:AiConfigTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name AiConfigTestRoot -ErrorAction SilentlyContinue
    }

    It 'exposes aiConfigSync capability in the UI contract' {
        $contract = Get-BootstrapUiContract

        [bool]$contract.capabilities.aiConfigSync | Should Be $true
    }

    It 'normalizes codeclaw as openclaw' {
        [string](Normalize-BootstrapAiToolName -ToolName 'codeclaw') | Should Be 'openclaw'
    }

    It 'declares Hermes native Windows beta metadata and OpenClaw Node 22 requirement' {
        $catalog = Get-BootstrapAiToolCatalog

        [string]$catalog['hermes-agent'].WindowsInstallSupport | Should Be 'native-powershell-beta'
        [string]$catalog['hermes-agent'].WindowsInstallCommand | Should Match 'install.ps1'
        [int]$catalog['openclaw'].MinimumNodeMajor | Should Be 22
        (@($catalog['openclaw'].Aliases) -contains 'codeclaw') | Should Be $true
    }

    It 'builds redacted AI Config Doctor report for providers, targets and MCPs' {
        $env:OPENROUTER_API_KEY = 'sk-or-v1-phasezero-ai-config-secret'
        try {
            $report = New-BootstrapAiConfigDoctorReport
            $json = $report | ConvertTo-Json -Depth 12

            [string]$report.schemaVersion | Should Be '1'
            @($report.providers).Count | Should BeGreaterThan 0
            $openClawTarget = @($report.targets | Where-Object { [string]$_['id'] -eq 'openClaw' })[0]
            @($openClawTarget).Count | Should Be 1
            [string]$openClawTarget.status | Should Be 'blocked'
            [bool]$report.openclaw.ready | Should Be $false
            [bool]$report.openclaw.usageBlocked | Should Be $true
            [string]$report.openclaw.blockedReason | Should Be 'connection-grant-not-enforceable'
            @($report.targets | Where-Object { [string]$_['id'] -eq 'hermes' }).Count | Should Be 1
            [bool]$report.manualRequired | Should Be $true
            $json | Should Not Match 'phasezero-ai-config-secret'
            $json | Should Not Match 'sk-or-v1'
        } finally {
            Remove-Item Env:\OPENROUTER_API_KEY -ErrorAction SilentlyContinue
        }
    }

    It 'plans AI Config Sync dry-run without mutating and without secrets' {
        $env:OPENAI_API_KEY = 'sk-phasezero-ai-config-secret'
        try {
            $report = Invoke-BootstrapAiConfigSync -DryRun
            $json = $report | ConvertTo-Json -Depth 12

            [string]$report.status | Should Be 'planned'
            [bool]$report.dryRun | Should Be $true
            @($report.applied).Count | Should Be 0
            @($report.planned).Count | Should BeGreaterThan 0
            $json | Should Not Match 'phasezero-ai-config-secret'
            $json | Should Not Match 'sk-'
        } finally {
            Remove-Item Env:\OPENAI_API_KEY -ErrorAction SilentlyContinue
        }
    }

    It 'writes result.json for AiConfigDoctor mode' {
        $resultPath = Join-Path $script:AiConfigTestRoot 'doctor.result.json'
        $logPath = Join-Path $script:AiConfigTestRoot 'doctor.log'

        $result = Invoke-AiConfigBootstrapForTest -CommandArgs @('-AiConfigDoctor', '-DryRun', '-NonInteractive', '-ResultPath', $resultPath, '-LogPath', $logPath)
        $json = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json

        [int]$result.ExitCode | Should Be 0
        [string]$json.mode | Should Be 'ai-config-doctor'
        $json.aiConfig | Should Not Be $null
    }

    It 'writes result.json for AiConfigSync dry-run mode' {
        $resultPath = Join-Path $script:AiConfigTestRoot 'sync.result.json'
        $logPath = Join-Path $script:AiConfigTestRoot 'sync.log'

        $result = Invoke-AiConfigBootstrapForTest -CommandArgs @('-AiConfigSync', '-DryRun', '-NonInteractive', '-ResultPath', $resultPath, '-LogPath', $logPath)
        $json = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json

        [int]$result.ExitCode | Should Be 0
        [string]$json.mode | Should Be 'ai-config-sync'
        [bool]$json.aiConfig.dryRun | Should Be $true
    }

    It 'adds AI config redacted artifacts to SupportBundle' {
        $bundlePath = Join-Path $script:AiConfigTestRoot 'support.zip'
        $doctor = [ordered]@{
            aiConfig = New-BootstrapAiConfigDoctorReport
            checks = @()
            auditResults = @()
            auditSummary = [ordered]@{ critical = 0; timedOut = 0 }
        }
        $repair = [ordered]@{ items = @() }
        $payload = [ordered]@{ status = 'success'; mode = 'test' }

        $bundle = New-BootstrapSupportBundle -DoctorReport $doctor -RepairPlan $repair -ResultPayload $payload -DestinationPath $bundlePath
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $entries = [System.IO.Compression.ZipFile]::OpenRead($bundlePath).Entries | ForEach-Object { $_.FullName }

        (@($entries) -contains 'ai-config.json') | Should Be $true
        (@($entries) -contains 'ide-targets.json') | Should Be $true
        (@($entries) -contains 'mcp-health.json') | Should Be $true
        (@($bundle.included) -contains 'ai-config.json') | Should Be $true
    }
}
