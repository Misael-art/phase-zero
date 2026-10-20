#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$PzArguments)

$ErrorActionPreference = 'Stop'
$manager = Join-Path $PSScriptRoot 'ai\deepseek-harness.ps1'

function Write-UsageError {
    param([string]$Command, [string]$Reason, [string]$NextAction)
    [Console]::Out.WriteLine((([ordered]@{
        schemaVersion = 1; appId = 'app.deepseek-harness'; command = $Command
        ok = $false; state = 'blocked'; reason = $Reason; nextAction = $NextAction
    }) | ConvertTo-Json -Compress))
    exit 2
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
