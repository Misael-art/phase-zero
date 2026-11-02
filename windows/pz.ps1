#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$PzArguments)

$ErrorActionPreference = 'Stop'
if ($PzArguments -and $PzArguments.Count -ge 2 -and $PzArguments[0] -eq 'ai' -and $PzArguments[1] -in @('token-economy','tokens')) {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $python) {
        [Console]::Out.WriteLine('{"ok":false,"state":"blocked","reason":"python-3.11-required"}')
        exit 2
    }
    $economyManager = Join-Path (Split-Path -Parent $PSScriptRoot) 'linux/ai/token_economy.py'
    $economyArguments = if ($PzArguments.Count -gt 2) { @($PzArguments[2..($PzArguments.Count - 1)]) } else { @('status') }
    & $python.Source $economyManager @economyArguments
    exit $LASTEXITCODE
}
if ($PzArguments -and $PzArguments.Count -ge 2 -and $PzArguments[0] -eq 'ai' -and $PzArguments[1] -in @('memory','ai-memory')) {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $python) {
        [Console]::Out.WriteLine('{"ok":false,"state":"blocked","reason":"python-3.11-required"}')
        exit 1
    }
    $memoryManager = Join-Path (Split-Path -Parent $PSScriptRoot) 'linux/ai/memory_manager.py'
    $memoryArguments = if ($PzArguments.Count -gt 2) { @($PzArguments[2..($PzArguments.Count - 1)]) } else { @('status') }
    & $python.Source $memoryManager @memoryArguments
    exit $LASTEXITCODE
}
$manager = Join-Path $PSScriptRoot 'ai\deepseek-harness.ps1'

function Write-UsageError {
    param([string]$Command, [string]$Reason, [string]$NextAction)
    [Console]::Out.WriteLine((([ordered]@{
        schemaVersion = 1; appId = 'app.deepseek-harness'; command = $Command
        ok = $false; state = 'blocked'; reason = $Reason; nextAction = $NextAction
    }) | ConvertTo-Json -Compress))
    exit 2
}

if ($PzArguments -and $PzArguments.Count -ge 2 -and
    $PzArguments[0] -eq 'ai' -and $PzArguments[1] -eq 'deepseek-harness' -and
    ($PzArguments.Count -eq 2 -or $PzArguments[2] -in @('help','--help','-h'))) {
    [Console]::Out.WriteLine('pz ai deepseek-harness <plan|status|start-plan|install|update|start|open|stop|doctor|uninstall> [--json]')
    [Console]::Out.WriteLine('start / start-plan: --workspace <folder> --auth-route account|api [--port 3080]')
    exit 0
}

if (-not $PzArguments -or $PzArguments.Count -lt 3 -or
    $PzArguments[0] -ne 'ai' -or $PzArguments[1] -ne 'deepseek-harness') {
    Write-UsageError -Command 'unknown' -Reason 'unsupported-command' -NextAction 'use ai deepseek-harness <plan|status|install|update|start|open|stop|doctor|uninstall>'
}

$managerArguments = @('-Action', [string]$PzArguments[2])
for ($index = 3; $index -lt $PzArguments.Count; $index++) {
    switch -Exact ($PzArguments[$index]) {
        '--json' { $managerArguments += '-Json'; continue }
        '--workspace' {
            $index++
            if ($index -ge $PzArguments.Count -or -not $PzArguments[$index]) {
                Write-UsageError -Command ([string]$PzArguments[2]) -Reason 'workspace-required' -NextAction 'pass --workspace <existing-folder>'
            }
            $managerArguments += @('-Workspace', [string]$PzArguments[$index]); continue
        }
        '--auth-route' {
            $index++
            if ($index -ge $PzArguments.Count -or $PzArguments[$index] -notin @('account','api')) {
                Write-UsageError -Command ([string]$PzArguments[2]) -Reason 'auth-route-required' -NextAction 'pass --auth-route account or --auth-route api'
            }
            $managerArguments += @('-AuthRoute', [string]$PzArguments[$index]); continue
        }
        '--port' {
            $index++
            $port = 0
            if ($index -ge $PzArguments.Count -or -not [int]::TryParse([string]$PzArguments[$index], [ref]$port) -or $port -lt 1024 -or $port -gt 65535) {
                Write-UsageError -Command ([string]$PzArguments[2]) -Reason 'invalid-port' -NextAction 'pass --port between 1024 and 65535'
            }
            $managerArguments += @('-Port', [string]$port); continue
        }
        default {
            Write-UsageError -Command ([string]$PzArguments[2]) -Reason 'unknown-option' -NextAction 'check command help and retry'
        }
    }
}

$engine = (Get-Process -Id $PID).Path
& $engine -NoLogo -NoProfile -ExecutionPolicy Bypass -File $manager @managerArguments
exit $LASTEXITCODE
