# DeepSeek Harness runtime pins

This directory owns only the official `@deepseek-ai/dsh` runtime closure. It is
separate from the `deepsproxy` service and DeepSeek model-provider definitions.

Pins were revalidated on 2026-10-20. `pins.json` records the immutable upstream
Git commit, npm tarball integrity, exact Node archive hashes, sources, and
observed license. `package-lock.json` locks the complete npm dependency graph;
`sbom.cdx.json` records its transitive components and declared licenses.
Installers must use this lock and these hashes. They must not use `npx`, a
floating tag, or `@latest`.

Node 24.22.0 is the supported LTS release observed on the review date and is
installed in the integration's private runtime directory. The host's Node,
npm, and PATH stay untouched. Linux support is limited to Arch x86_64; Windows
support is limited to x64. Other architectures fail with an explicit reason.

The upstream is a developer preview without a security audit. Its file policy
does not confine network or process access, and its Windows ACL backend can
report partial enforcement. PhaseZero keeps the application opt-in and
experimental; a successful install does not mean account, sandbox, model, or
task readiness.

Runtime starts only after an explicit user action. It binds to `127.0.0.1`,
uses a route-specific `DSH_HOME`, disables telemetry, and requests
`workspace-write` plus `ask`. Sandbox enforcement remains `unknown` until
measured. The one-time launch token stays in supervisor memory and never enters
state or logs. The account and API routes use different homes; a missing API
key or account session never causes fallback to another route.
Enter an API key only in Harness's **Settings → Models** while using the API
route; Harness stores it in that route's home. PhaseZero never reads or copies
the key and never probes it with paid inference.

The supervisor starts from an empty route-private directory. Upstream loads
`.env` from its invoking directory and has no Web CLI flag to preselect a
workspace. PhaseZero asks for the intended folder, then tells the user to
confirm that folder in Harness's workspace picker. Project `.env` values
cannot silently replace the chosen API/account route. The upstream picker is
the source of truth for the active workspace.

Install plan requires 512 MiB free disk and at least 2 GiB available memory;
`start` repeats the memory check and blocks when it cannot measure enough
headroom. The Node process receives a 2 GiB V8 old-space limit. This does not
cap native allocations, child processes, CPU, or external tools; do not treat it
as a complete resource sandbox. Autostart stays disabled.

`npm ci` runs with lifecycle scripts disabled. Installer then runs only the
upstream-reviewed `node-pty`, `koffi`, and `@deepseek-ai/dsh-subprocess-local`
build hooks, matching the pinned upstream `allowBuilds` list. This pins build
code through the lockfile and prevents unreviewed dependency hooks from
running during preparation. It also ignores ambient `NODE_OPTIONS`, `NODE_PATH`,
and `NPM_CONFIG_*`, uses temporary empty npm user/global config files, and
keeps the npm cache inside staging so another project or personal registry
credentials cannot change this installation.

## CLI

On Arch/Linux, use `pz ai deepseek-harness plan|status|install|update|start|open|stop|doctor|uninstall --json`.
On Windows, the PowerShell adapter accepts the same action and options:
`pwsh .\windows\pz.ps1 ai deepseek-harness status --json`.
`start` requires an existing `--workspace` and exactly one
`--auth-route account|api`; optional `--port` accepts loopback ports 1024–65535
and is retained in local state. `plan`, `status`, and `doctor` do not create
the runtime root or start Harness. `install` prepares only; `start` is a
separate, explicit action. `open` hands the one-time launch URL to the local
browser, while token values stay out of PhaseZero output and logs.

Examples:

```sh
pz ai deepseek-harness plan --json
pz ai deepseek-harness install --json
pz ai deepseek-harness start --workspace "$PWD" --auth-route account --json
pz ai deepseek-harness open --json
pz ai deepseek-harness stop --json
```

```powershell
pwsh .\windows\pz.ps1 ai deepseek-harness plan --json
pwsh .\windows\pz.ps1 ai deepseek-harness install --json
pwsh .\windows\pz.ps1 ai deepseek-harness start --workspace $PWD --auth-route account --json
pwsh .\windows\pz.ps1 ai deepseek-harness open --json
pwsh .\windows\pz.ps1 ai deepseek-harness stop --json
```
