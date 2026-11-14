Describe 'Memory portability integration contracts' {
    BeforeEach {
        $script:MemoryRepo = Split-Path -Parent $PSScriptRoot
        . (Join-Path $script:MemoryRepo 'bootstrap-tools.ps1') -BootstrapUiLibraryMode
    }

    It 'uses one verified pin for Windows and Linux metadata' {
        $pins = Get-Content (Join-Path $script:MemoryRepo 'packaging/ai-memory/pins.json') -Raw | ConvertFrom-Json
        $catalog = Get-BootstrapAiToolCatalog
        if ($catalog['ai-memory'].ReleaseTag -ne ('v' + $pins.version)) { throw 'Version pin differs' }
        if ($catalog['ai-memory'].ReleaseAssets.windows.Sha256 -ne $pins.assets.'windows-x86_64'.sha256) { throw 'Asset pin differs' }
    }

    It 'never mirrors raw databases or enrolls arbitrary drive letters' {
        $text = (Get-Command Sync-BootstrapAiMemoryWithSdCard).ScriptBlock.ToString()
        if ($text -match 'robocopy|/MIR|F:|DriveType') { throw 'Unsafe mirroring returned' }
        if ($text -notmatch 'Invoke-BootstrapAiMemoryPortability') { throw 'Canonical owner missing' }
        if ((Sync-BootstrapAiMemoryWithSdCard -DryRun).synced) { throw 'Dry run claimed sync' }
    }

    It 'routes native UI and CLI to the same memory owner' {
        $ui = Get-Content (Join-Path $script:MemoryRepo 'windows/ai/memory-ui.ps1') -Raw
        $cli = Get-Content (Join-Path $script:MemoryRepo 'windows/pz.ps1') -Raw
        if ($ui -notmatch 'memory_manager.py') { throw 'Missing contract: memory_manager.py' }
        if ($cli -notmatch 'memory_manager.py') { throw 'Missing contract: memory_manager.py' }
        if ($ui -notmatch 'BeginInvoke') { throw 'Missing contract: BeginInvoke' }
        if ($ui -notmatch 'PasswordBox') { throw 'Missing contract: PasswordBox' }
        if ($ui -notmatch 'expected-sha256') { throw 'Missing contract: expected-sha256' }
    }

    It 'wires the desktop when no separate Codex CLI is installed' {
        Mock Resolve-BootstrapAiToolCommandPath { return '' }
        Mock Resolve-CommandPath { return '' }
        Mock Get-BootstrapCodexDesktopPackageInfo { return @{ installed = $true } }
        $agents = @(Get-BootstrapAiMemoryDetectedAgents)
        if ($agents.Count -ne 1 -or $agents[0] -ne 'codex') { throw 'Desktop MCP was omitted or duplicated' }
    }

    It 'rejects a damaged offline release before extraction or downloading' {
        $package = Join-Path $TestDrive 'damaged.zip'
        [IO.File]::WriteAllText($package, 'not a release')
        $before = $env:AI_MEMORY_RELEASE_ARCHIVE
        try {
            $env:AI_MEMORY_RELEASE_ARCHIVE = $package
            Mock Invoke-WebRequest { throw 'Unexpected network access' }
            Mock Expand-Archive { throw 'Unexpected extraction' }
            $rejected = $false
            try { Install-BootstrapAiMemoryViaRelease -CatalogEntry (Get-BootstrapAiToolCatalog)['ai-memory'] -InstallRoot (Join-Path $TestDrive 'tools') | Out-Null }
            catch { $rejected = $_.Exception.Message -match 'Checksum ai-memory invalido' }
            if (-not $rejected) { throw 'Unverified archive was accepted' }
        } finally { $env:AI_MEMORY_RELEASE_ARCHIVE = $before }
    }
}
