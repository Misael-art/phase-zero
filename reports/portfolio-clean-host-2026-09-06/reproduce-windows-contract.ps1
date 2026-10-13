# These are isolated contract probes under PowerShell on Linux, not Windows E2E.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$AuditRepo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$AuditFixture = Join-Path ([IO.Path]::GetTempPath()) ('pz-windows-contract-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($AuditFixture)
Write-Output "Fixture path: $AuditFixture"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $AuditRepo 'bootstrap-tools.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'PowerShell source parse failed' }
$wanted = @('Get-BootstrapHomelabComposePath', 'New-BootstrapHomelabSecret', 'Ensure-BootstrapHomelabStack', 'Get-BootstrapAiProxyCatalog')
$nodes = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true))
if ($nodes.Count -ne $wanted.Count) { throw 'Required functions not found' }
foreach ($node in $nodes) {
    # Only path injection; function bodies retain their product control flow.
    . ([scriptblock]::Create($node.Extent.Text.Replace('$PSScriptRoot', '$AuditRepo')))
}
function Get-BootstrapAiInstallRoot { param($InstallRoot) return $AuditFixture }
function Register-BootstrapFileChange { param($State, $Target, $Operation, $Component) }
$script:AuditLogs = [Collections.Generic.List[string]]::new()
function Write-Log { param($Message, $Level) $script:AuditLogs.Add([string]$Message) }
function Test-DockerReady { return $false }
$state = @{ DryRun = $false }
Ensure-BootstrapHomelabStack -State $state
if (-not ($script:AuditLogs -match 'Docker indisponivel')) { throw 'Missing Docker path not exercised' }
$missingDocker = @{ returnedWithoutError = $true; logs = @($script:AuditLogs.ToArray()) }

function Test-DockerReady { return $true }
function Resolve-CommandPath { param($Name) return 'fixture-docker-never-executed' }
function Invoke-BootstrapCommandCapture { param($Exe, $Args) return @{ ExitCode = 42; Output = 'fixture failure' } }
$script:AuditLogs.Clear()
Ensure-BootstrapHomelabStack -State $state
if (-not ($script:AuditLogs -match 'exit=42')) { throw 'Failed Docker path not exercised' }
$failedDocker = @{ returnedWithoutError = $true; logs = @($script:AuditLogs.ToArray()) }
$catalog = Get-BootstrapAiProxyCatalog
$result = [ordered]@{
    schemaVersion = 1
    runtime = 'PowerShell on Linux; AST-extracted product functions; fixture dependencies'
    parseErrors = $errors.Count
    missingDocker = $missingDocker
    composeFailure = $failedDocker
    windowsMimo = @{ runtime = $catalog['mimo-ai-proxy']['Runtime']; authentication = $catalog['mimo-ai-proxy']['WebValidationKind'] }
    proxies = @($catalog.Keys)
}
$json = ($result | ConvertTo-Json -Depth 8).Replace($AuditFixture, '<fixture>')
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'evidence/windows-contract.json'), $json + "`n")
Write-Output 'Two Windows function failure paths returned without error; MiMo uses Go/env-session.'
