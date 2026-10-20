# DeepSeek Harness implementation handoff

Date: 2026-10-20
State: Experimental; no release, no host install/start.
Branch: `codex/deepseek-harness-integration`
Base: `ddadd6de4fc5a0b8933c2d312e2f8a6dd7f1aff3` + plan commit `eda2ca9fefcfde1b03508b1c9e6d366dd3884ede`.

Main CI and secret scan were green on baseline `ddadd6d` (CI run
`39401851679`; gitleaks run `39401851673`). The more recent main run for
`f030b14` was cancelled; it is not evidence for this implementation.

The `0.2.1-rc.2` pin is an observation from 2026-10-20, not a permanent
recommendation. Revalidation matched npm integrity
`sha512-tvY+yhfKRifthbqPe/OK0AYxM5ZkvqfYq/jMYgJcEUxiRRL1Vwra3Ti5TB6AXgSWQdiPHYh/Vp6SJa9yHwMNuw==`,
upstream tag commit `687f282e8625c6b8d11ff58211a90524be2e4317`, and official
Node 24.22.0 Linux/Windows SHA-256 values in `packaging/deepseek-harness/pins.json`.
Never replace these with `latest`.

## DSH-001..010 state

| ID | State | Evidence and open gate |
|---|---|---|
| DSH-001 | Implemented | Exact npm/Node pins, lockfile, CycloneDX SBOM, MIT license audit, ADR. npm registry, upstream tag, and Node SHASUMS rechecked 2026-10-20. |
| DSH-002 | Implemented; clean-runner CI pending | Arch x64 and Windows x64 bootstrap managers provision private Node 24.22.0; pinned hashes, locked npm install, private staging, atomic activation, rollback. No host Node/npm changes. |
| DSH-003 | Fixture evidence; clean-runner smoke pending | Explicit `DSH_HOME`, route-specific launch directories, loopback port, lock, process ownership, health, crash detection/restart, duplicate start, retained custom port. Clean Arch/Windows CI will start and stop upstream Web UI without credentials or inference. No autostart. |
| DSH-004 | Implemented; external account gate open | Account and API use separate homes; credentials entered only in Harness UI. No key copied, no fallback, no inference/probe. Account/session, API validity, balance, quota remain `unknown`. **PXA-006 remains an external real-account/session/quota gate.** |
| DSH-005 | Partial; sandbox proof open | User path is requested and must be confirmed in Harness picker; requested file policy is `workspace-write + ask`; plugins/MCPs stay off. Enforcement stays `unknown`; same-user processes share trust boundary; file policy does not limit network/processes. No isolation claim. |
| DSH-006 | Local UI tests; CI pending | Canonical `app.deepseek-harness` card is separate from Proxy/model. Public controls implement the guided journey; tests cover 800×600/1280×800, themes, scale, keyboard, accessible names, and overflow. Advanced unsupported routes remain visibly disabled. |
| DSH-007 | Fixture evidence; clean-runner smoke pending | Supervisor captures launch URL in memory, validates loopback host/port, hands it to browser once, and redacts token-like values from logs/output. Real upstream login/reopen not exercised; clean-runner smoke checks actual loopback health without launching a browser. |
| DSH-008 | Fixture evidence | Interrupted download cleanup, registry failure rollback, prior runtime preservation, port conflict, crash/restart, safe uninstall, preservation of both DSH homes and selected workspace. Actual Windows lifecycle is pending clean-runner CI. |
| DSH-009 | Partial | Telemetry disabled; ambient credentials/config stripped; V8 old-space capped at 2 GiB; install checks disk and memory; start blocks below 2 GiB measured available memory; no boot start. Native allocations, subprocesses, CPU, and external tools have no hard cap. |
| DSH-010 | Pending final CI | Fixture matrix and clean Arch/Windows workflows added. Final CI, secret scanner, and PR checks must pass on final pushed SHA before calling implementation checks complete. |

## Evidence and limitations

- The first 225-test run found one status exit-code mismatch and one stale static action snapshot; both were fixed. Latest affected suite: 64 passed (manager, action cohesion/status, and UI); earlier account/product/UI-server tests passed in the broader run. PowerShell AST parse, Python compile, workflow YAML parse, 628-component SBOM/license check, and read-only Linux/Windows CLI probes passed.
- Clean Arch workflow installs only Python in disposable `archlinux:base`, then executes pinned install/status/doctor, starts/stops actual upstream Web UI without credentials or inference, and uninstalls. Windows workflow hides runner Node/npm/compiler, installs on a disposable clean runner, performs the same no-cost upstream Web UI start/stop, then replaces only the disposable entry point with a local fixture for fault injection. Both workflows remain pending until CI runs.
- CI secret scanner is the authoritative scanner when the branch is pushed; local `gitleaks` binary was absent. Do not report scanner green until CI result is green.
- No real account/session, quota, paid inference, upstream sandbox probe, or user task was tested. No Windows VM was used. No Harness package/runtime was installed or started on the Arch host.
- The original checkout and other worktrees contain unrelated WIP; implementation work stays in the dedicated worktree.

## Host impact and rollback

Host at recheck: Manjaro/Arch x86_64, KDE graphical target active, about 4.1 GiB available RAM and 7.7 GiB swap used. No Harness runtime/service or Windows VM was started. Local probes and tests used read-only checks or disposable fixture processes. No package manager, KDE session, host config, existing AI service, or credential store was changed.

Stop and remove an explicitly installed integration with:

```sh
pz ai deepseek-harness stop --json
pz ai deepseek-harness uninstall --json
```

Uninstall removes PhaseZero runtime/state only; it preserves `DSH_HOME` account/API data and selected workspace. Back up or revoke credentials inside Harness before deleting those homes manually. To revert code after merge, revert implementation commits in reverse order; do not delete DSH homes as part of code rollback.

No host rollback is required for this implementation review because no host install or runtime start occurred.
