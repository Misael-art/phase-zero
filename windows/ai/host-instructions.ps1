#Requires -Version 5.1
function Set-PhaseZeroHostInstructions {
    $body = [IO.File]::ReadAllText((Join-Path $repoRoot 'assets/ai/host-resource-policy.md'))
    $codexHome = Get-BootstrapCodexHome
    $claudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path (Get-BootstrapUserProfileRoot) '.claude' }
    $targets = @((Join-Path $codexHome 'AGENTS.md'), (Join-Path $claudeHome 'CLAUDE.md'))
    foreach ($target in $targets) {
        Write-BootstrapMarkedRuleFile -Path $target -Body $body -Label 'HOST RESOURCE CHECK' | Out-Null
        if (-not ([IO.File]::ReadAllText($target).Contains($body))) { throw 'Instrucoes globais incompletas.' }
    }
    if (Test-Path -LiteralPath (Join-Path $codexHome 'AGENTS.override.md')) {
        Write-Warning 'AGENTS.override.md existente tem precedencia. Confira a descoberta das instrucoes ao abrir o Codex.'
    }
    return $targets
}
