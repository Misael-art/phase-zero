# Canonical CLI and WPF contract; no native Windows claim from Linux parsing.
Describe 'Token economy portability contract' {
    BeforeEach { $script:EconomyRepo = Split-Path -Parent $PSScriptRoot }
    It 'keeps one owner and a pinned experimental component' {
        $policy = Get-Content (Join-Path $script:EconomyRepo 'assets/agent-skills/token-economy.json') -Raw | ConvertFrom-Json
        if ($policy.defaultProfile -ne 'basic' -or $policy.headroomVersion -ne '0.32.1') { throw 'policy mismatch' }
        $cli = Get-Content (Join-Path $script:EconomyRepo 'windows/pz.ps1') -Raw
        $view = Get-Content (Join-Path $script:EconomyRepo 'windows/ai/token-economy-ui.ps1') -Raw
        if ($cli -notmatch 'linux/ai/token_economy.py' -or $view -notmatch 'linux/ai/token_economy.py') { throw 'duplicate owner' }
        if ($view -notmatch 'BeginInvoke' -or $view -notmatch 'DispatcherTimer') { throw 'UI blocks event loop' }
    }
    It 'does not add headroom memory or an unsupported wrapper to generated helpers' {
        $source = Get-Content (Join-Path $script:EconomyRepo 'bootstrap-tools.ps1') -Raw
        if ($source -match "'wrap','(?:claude|codex)','--memory'") { throw 'second memory store' }
        if ($source -match "'wrap','gemini'") { throw 'unsupported wrapper' }
        if ($source -match "'skills', 'add', 'alchaincyf/huashu-design'") { throw 'design skill mixed into economy' }
        if ($source -notmatch 'experimental-route-auth-and-memory-homologation-required') { throw 'missing usage gate' }
    }
}
