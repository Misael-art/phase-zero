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

The PhaseZero IA & Dev card uses the same manager and canonical product record.
It offers Install, Connect / choose workspace, Open, Stop, Verify, and Refresh.
Advanced mode adds install plan, pinned update, and uninstall. Account and API
entries in Contas e conexões navigate back to this card. Start collects the
route, existing workspace, and loopback port; its `start-plan` preview displays
those exact choices without writing state or launching the runtime. Unknown
status disables mutations, and callbacks preserve the active operation lock.

Package recipes for Arch, Debian, RPM, AppImage, Flatpak, and per-user install
include this metadata closure at `packaging/deepseek-harness` in the installed
runtime. That fixes the missing pin/lock files outside the Arch package; it
does not certify runtime execution on every distribution or inside Flatpak.
Doctor distinguishes passed local checks from unverified account, model, and
sandbox gates. A missing Node/npm/entrypoint is degraded, never installed/healthy.

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

## Installation budget and operating parameters

Linux x64 archive metadata rechecked on 2026-11-01: Node SHA-256 and DSH npm
integrity still match `pins.json`. The locked Linux x64 npm closure contains
563 distinct archives, totaling 139,655,863 bytes; Node adds 32,015,600 bytes.
Total compressed input: **171,671,463 bytes** (~164 MiB). Native build hooks may
require additional downloads. Keep the existing 512 MiB free-disk / 2 GiB
available-memory checks; this budget does not replace either check. The installer
uses an isolated npm cache, so unrelated user-cache contents are not a saving.

| Parameter | Managed value / operator choice |
|---|---|
| Runtime | `@deepseek-ai/dsh@0.2.1-rc.2`, private Node `24.22.0` |
| Default root | `${XDG_DATA_HOME:-~/.local/share}/phasezero/deepseek-harness`; `PZ_DSH_ROOT` is an explicit override |
| Lifecycle | Install prepares files; start/open/stop are explicit; autostart disabled |
| Address | `127.0.0.1`, default port `3080`; operator may choose `1024–65535` |
| Authentication | Explicit `account` or `api`; separate `homes` under managed root, no automatic fallback |
| Workspace | Existing operator-selected folder; confirm again in upstream workspace picker |
| Telemetry | `DSH_TELEMETRY_DISABLED=1` |
| Memory bound | `NODE_OPTIONS=--max-old-space-size=2048`; native allocations and children not capped |
| Requested policy | `workspace-write + ask`; enforcement remains unknown |
| Extensions | Plugins/MCP opt-in; ai-memory connection requires client-specific verification |
| Efficiency | Basic default, economy optional per project/client; configuration does not prove session consumption |
| Credentials | Enter through upstream UI; never place in command arguments, documentation or logs |
| Recovery | Atomic runtime activation; stop/uninstall preserve account/API homes and workspace |

The Node archive is
`https://nodejs.org/dist/v24.22.0/node-v24.22.0-linux-x64.tar.xz`, SHA-256
`cc2f601cee82d9a5a233302fe307abc600727035fd7d2c3a3571755989e95008`.
DSH comes from
`https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-0.2.1-rc.2.tgz`;
its SHA-512 integrity and every transitive URL/integrity are recorded in
`pins.json` and `package-lock.json`. The official installer verifies these inputs
and activates only a completed runtime. Do not unpack files into the runtime by
hand or bypass the memory/disk preflight.

This workspace requires an operator to initiate downloads above 70,000,000 bytes,
including the combined parts of one package. Use the Install button or run
`pz ai deepseek-harness install --json` manually; then inspect `status --json`
and `doctor --json`. Retain those receipts to distinguish installation from runtime readiness.
The operator completed a real Linux x64 install at `2026-11-02T02:41:24Z`; local
Node/package/lock checks passed. Workspace, route, account/model and sandbox
enforcement remain unverified; see the
[host handoff](../../docs/roadmaps/deepseek-harness-implementation-handoff.md).
A successful doctor can establish local runtime health while still reporting
account, model and sandbox checks as unverified.

Memory and efficiency share their existing owners:
[portable memory](../../docs/roadmaps/ai-memory-portability-v1.md) and
[project/client profiles](../../docs/roadmaps/ai-token-economy-v1.md). Do not copy
another client's credentials, hooks or MCP configuration into Harness to make
its status appear connected.
