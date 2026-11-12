$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'windows/ai/prepare-host.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-PhaseZeroHostPreparationAction' }, $true)
if (-not $definition) { throw 'Preparation action missing' }
. ([scriptblock]::Create($definition.Extent.Text))
$originalWindows = $env:WINDIR
$env:WINDIR = [IO.Path]::GetTempPath()
$window = [pscustomobject]@{ hidden = $false }
$window | Add-Member -MemberType ScriptMethod -Name Hide -Value { $this.hidden = $true }
$window | Add-Member -MemberType ScriptMethod -Name Show -Value { $this.hidden = $false }
$operationStatus = [pscustomobject]@{ Text = '' }
$hostScript = Join-Path ([IO.Path]::GetTempPath()) 'path with spaces/prepare-host.ps1'
$setupLogRoot = Join-Path ([IO.Path]::GetTempPath()) 'phasezero-host-preparation-fixture'
$receipts = New-Object 'Collections.Generic.List[object]'
$launches = New-Object 'Collections.Generic.List[object]'
$outcome = [pscustomobject]@{ ExitCode = 0; FailLaunch = $false }
$script:writeReceipt = { param($Path, $Value) $receipts.Add(@{ path = $Path; value = $Value }) }.GetNewClosure()
Set-Item Function:Start-Process -Value {
    [CmdletBinding()]
    param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
    if ($outcome.FailLaunch) { throw 'fixture-start-failure' }
    $launches.Add(@{ file = $FilePath; arguments = $ArgumentList; wait = $Wait; passThru = $PassThru })
    return [pscustomobject]@{ ExitCode = $outcome.ExitCode }
}.GetNewClosure()
$run = ${function:Invoke-PhaseZeroHostPreparationAction}
try {
    & $run 'InstallApps'
    if ($launches.Count -ne 1 -or $launches[0].arguments -notmatch '-AllowLargeDownloads') { throw 'Install action did not authorize its downloads' }
    if (-not $launches[0].arguments.Contains('-File "' + $hostScript + '"')) { throw 'Preparation path with spaces changed' }
    if (-not $receipts[0].value.downloadsAuthorized) { throw 'Install authorization missing from receipt' }
    if ($window.hidden) { throw 'Launcher did not reopen' }
    & $run 'InstallMemory'
    if ($launches[1].arguments -match '-AllowLargeDownloads' -or -not $launches[1].wait -or -not $launches[1].passThru) { throw 'Memory action arguments or process verification changed' }
    if ($receipts.Count -ne 2 -or $receipts[1].value.exitCode -ne 0) { throw 'Action result not retained' }
    if ($receipts[1].path -ne (Join-Path $setupLogRoot 'prepare-host-InstallMemory.json')) { throw 'Action receipt destination changed' }
    $outcome.ExitCode = 42
    & $run 'InstallMemory'
    if ($operationStatus.Text -notmatch 'falhou' -or $receipts[2].value.exitCode -ne 42 -or $window.hidden) { throw 'Child failure hidden' }
    $outcome.FailLaunch = $true
    & $run 'Status'
    if ($operationStatus.Text -notmatch 'fixture-start-failure' -or $window.hidden) { throw 'Process launch failure hidden' }
    Write-Output 'PASS: 4 preparation journeys; processes and result writes mocked.'
} finally { $env:WINDIR = $originalWindows }
