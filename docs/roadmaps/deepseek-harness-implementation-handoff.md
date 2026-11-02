# DeepSeek Harness implementation handoff

## Canonical checkout integration — 2026-11-01

Owner: PhaseZero AI adapters and native UI. Current root
`/home/misael/Projects/PhaseZero`, branch `codex/clean-host-dev-bootstrap`, PR #129,
initial HEAD `53d62e2d14f7edafe5cefea77f46fb0a7dca5cc0`. Source implementation
`336abb7d8eb175dcd70d64e8f1182a29ee7a3be4` from PR #127 was reviewed and ported
selectively; no branch merge, new checkout, release, or live Harness install.
The original 2026-10-21 evidence below remains historical.

- Six quota/desktop/help defects from the previous review passed independent
  baseline validation: 149 tests and `tests/linux-ai-desktop.sh`.
- Harness uses the existing catalog, action runner, typed preview, inventory,
  installation authority and theme. All nine supported operations have controls;
  advanced mode contains plan/update/remove. Account/API channel links focus the
  same card. Start preview binds the selected workspace, route and port.
- Missing Node/npm/entrypoint is degraded. Doctor reports partial local readiness
  separately from unverified account/model/sandbox. Invalid port retains JSON
  diagnostics. Route/port changes require stopping the existing runtime.
- Linux supervisor handles termination and cleans its own process group, including
  child tools. Failed activation removes the unreferenced candidate while retaining
  the previous pointer. Windows keeps its existing Job Object lifecycle boundary.
- All Linux package recipes now include pins/lock/SBOM; only Arch did so in the
  source PR. Installed-root smoke executes the real CLI against copied metadata
  without creating a Harness runtime. Quota UI timeout now accommodates its two
  bounded HTTP adapters, matching the tray collector budget.
- npm integrity and both Node SHA-256 values rechecked against the official
  registry and SHASUMS on 2026-11-01; upstream tag still points to the recorded
  commit. Pins remain unchanged; no package or Node archive downloaded locally.

Local evidence: 257 affected tests passed; after final UI/authority refinements,
134 focused UI/account/catalog/loader tests and 45 manager/inventory tests passed.
`packaging/install-root-smoke.sh` and desktop shell regressions passed. PowerShell
parser (three files) and PSScriptAnalyzer (Windows adapters) passed on Linux;
Windows runtime was not exercised locally. Bash/ShellCheck and generated contract
checks passed. The first generation attempt selected the native manifest instead
of the fallback web format; drift test caught it. Final snapshot uses the official
`python -m linux.ui.generate_actions` generator and passes coherence checks.

Xvfb public UI checks passed dark/light at 100/150/200%, 800×600 and 1280×800,
including keyboard, overflow, and actual pointer hit target. Visual review restored
the shared primary-button styling and placed the single available primary action
at the left. Screenshots are local fixture evidence under
`~/.cache/phasezero-dev/evidence/deepseek-harness-20261101.BENSJwrK/`.

No real account, paid inference, login, compositor tray, Windows host, reboot,
Homelab appliance, or sandbox enforcement was certified. Keep Experimental and
retain blocked 9Router grants. PR #126/#127 and main are untouched. Final commit,
remote CI, package evidence and next action belong to the clean-host handoff.

## Original implementation evidence — 2026-10-21

- Date: 2026-10-21
- State: Experimental; implementation checks passed. No release or host install/start.
- Branch: `codex/deepseek-harness-integration`
- PR: draft [#127](https://github.com/Misael-art/phase-zero/pull/127)
- Implementation SHA validated by CI: `50e555063d5eabe5d51f32350611cf06ce5ceb96`
- Base: `ddadd6de4fc5a0b8933c2d312e2f8a6dd7f1aff3` + plan commit `eda2ca9fefcfde1b03508b1c9e6d366dd3884ede`

CI passed on the implementation SHA in push run
[`39557528866`](https://github.com/Misael-art/phase-zero/actions/runs/39557528866)
and PR run
[`39557534033`](https://github.com/Misael-art/phase-zero/actions/runs/39557534033).
Secret scans passed in
[`39557528878`](https://github.com/Misael-art/phase-zero/actions/runs/39557528878)
and
[`39557534111`](https://github.com/Misael-art/phase-zero/actions/runs/39557534111).
Pester: 801 passed, 0 failed, 2 skipped; focused AI Pester: 35 passed. Python/UI,
PowerShell analysis, shell lint, clean Arch, and clean Windows jobs passed.
`origin/main` still points to `ddadd6de4fc5a0b8933c2d312e2f8a6dd7f1aff3`; its
baseline CI and secret scan passed in runs `39401851679` and `39401851673`.

The `0.2.1-rc.2` value remains the exact pin first observed on 2026-10-20, not
a moving recommendation. Recheck on 2026-10-21 still matched npm integrity
`sha512-tvY+yhfKRifthbqPe/OK0AYxM5ZkvqfYq/jMYgJcEUxiRRL1Vwra3Ti5TB6AXgSWQdiPHYh/Vp6SJa9yHwMNuw==`,
upstream tag commit `687f282e8625c6b8d11ff58211a90524be2e4317`, and the pinned
Node 24.22.0 Linux/Windows SHA-256 values in
`packaging/deepseek-harness/pins.json`. Never replace these pins with `latest`.

## DSH-001..010 state

| ID | State | Evidence and open gate |
|---|---|---|
| DSH-001 | Implemented | Exact npm/Node pins, lockfile, CycloneDX SBOM, MIT license audit, ADR. npm registry, upstream tag, Node SHASUMS rechecked 2026-10-21. |
| DSH-002 | Implemented; clean-runner CI passed | Arch x64 and Windows x64 provision pinned Node 24.22.0 with runner Node/npm hidden, locked npm install, private staging, atomic activation, rollback. No host Node/npm changes. |
| DSH-003 | Implemented; clean-runner CI passed | Explicit `DSH_HOME`, loopback port, lock, owned process supervision, health, duplicate-start prevention, crash recovery/restart, safe stop/uninstall. Host or OS reboot was not tested; runtime has no autostart. |
| DSH-004 | Partial; external account gate open | Account and API routes use separate homes; fixture verifies separation and credential presence remains “validity unknown.” No real account login, API validation, balance, quota, or inference. **PXA-006 remains an external real supported-account/session/quota gate.** |
| DSH-005 | Partial; sandbox proof open | User-selected workspace, requested `workspace-write + ask`, plugins/MCPs opt-in. Enforcement remains `unknown`; file policy does not limit network/processes, and same-user processes share trust boundary. No isolation claim. |
| DSH-006 | Implemented; UI CI passed | Canonical `app.deepseek-harness` card is separate from Proxy/model. Public controls cover guided journey; UI tests cover 800×600/1280×800, themes, 100/150/200% scale, keyboard, accessible names, and overflow. Advanced unsupported routes remain disabled. |
| DSH-007 | Partial; fixture and no-credential smoke passed | Fixture verifies one-time authenticated launch handoff and token redaction. Clean Windows smoke started/stopped upstream Web UI without credentials or inference. Real browser login/reopen not tested. |
| DSH-008 | Implemented; fixture and clean-runner CI passed | Truncated download cleanup, unavailable registry rollback, preservation of active runtime, occupied port, crash/restart, duplicate start, uninstall, and preservation of both DSH homes/workspace covered. Windows uninstall completed safely. |
| DSH-009 | Partial | Telemetry disabled, ambient credentials/config stripped, V8 old-space capped at 2 GiB, disk/memory checks and no boot start. Native allocations, subprocesses, CPU, and external tools have no hard cap. |
| DSH-010 | Implementation checks passed; release gates open | Fixture matrix, clean Arch/Windows jobs, CI and secret scans passed on implementation SHA above. PR remains draft/Experimental; real account, sandbox enforcement, usability, and cost gates are external. |

## Evidence and limitations

- Clean Arch CI installed with Node/npm/compiler absent, started and stopped actual
  upstream Web UI without credentials or inference, then uninstalled.
- Clean Windows CI hid runner Node/npm, installed the pinned runtime, started and
  stopped upstream Web UI without credentials, and passed fixture checks for
  occupied port, duplicate start, unknown credential validity/quota, sandbox
  unknown, token-redacted authenticated handoff, crash/restart, and uninstall.
  Log marker: `deepseek-harness Windows clean-runtime smoke: passed; no inference sent`.
- Python/UI CI verified public controls at 800×600 and 1280×800, themes, scale,
  keyboard and hit testing. Pester and secret scanning passed as listed above.
- A real account/session, API credential, quota, balance, paid inference, upstream
  sandbox enforcement, and usability study were not tested. Invalid credential
  coverage is a fixture that preserves validity as unknown; no live 401 or model
  request was sent. OS reboot was not tested. No occupied Windows VM was used and
  the supplied ISO was not mounted.
- CI uses disposable runners. No Harness package/runtime was installed or started
  on the Manjaro host. At the 2026-10-21 recheck, KDE graphical target was active,
  available RAM was 2.3 GiB and swap use was 12 GiB; no Harness/VM process was
  observed. No package manager, session, host config, AI service, or credential
  store was changed.
- Original checkout `/mnt/sdcard/Projects/PhaseZero` and other worktrees retain
  unrelated WIP. Implementation stayed in the dedicated worktree.

## Host impact and rollback

No host rollback is needed. If this integration is explicitly installed later:

```sh
pz ai deepseek-harness stop --json
pz ai deepseek-harness uninstall --json
```

Uninstall removes PhaseZero runtime/state only; it preserves `DSH_HOME` account/API
data and selected workspace. Back up or revoke credentials inside Harness before
deleting those homes manually. To revert code after merge, revert implementation
commits in reverse order; do not delete DSH homes as part of code rollback.

## Host installation and publication preparation — 2026-11-01

Objective: install the pinned Harness on the authorized host, document existing
memory/efficiency settings, update README/changelog and prepare the requested
publication. Owner: Harness lifecycle and release tooling. Canonical checkout:
`/home/misael/Projects/PhaseZero`, branch `codex/clean-host-dev-bootstrap`, draft
[PR #129](https://github.com/Misael-art/phase-zero/pull/129). Initial HEAD:
`08ca96ef118a1678bb0d4963381a593c83b7c3fa`; implementation/documentation fix:
`e92f1bd85cd81790f3d72d5d01fc46e671e4119f`. Handoff commit: `git log -1 --format=%H -- docs/roadmaps/deepseek-harness-implementation-handoff.md`.

### Delivered and verified

- README and changelog cover pinned Harness, portable memory and project/client
  efficiency profiles. Detailed installation parameters remain owned by
  `packaging/deepseek-harness/README.md`, with links to the two existing roadmaps.
- Exact-SHA CI on the initial HEAD exposed stale contracts: fallback web catalog,
  deferred AI page probes, Windows Health routes and hardcoded ai-memory version.
  Fixed these contracts without disabling gates or changing runtime safeguards.
- **Fixture on Linux:** 41 Python tests passed (`test_accounts_page`,
  `test_installation_cohesion`, `test_linux_ui_server`); complete hermetic
  `tests/linux-homelab.sh` passed; Bash parser and ShellCheck with official CI
  options passed. Four changed Health assertion blocks passed with Pester 6
  assertion syntax in a private portable fixture; PowerShell parser passed.
  Pester 3.4 cannot import its Windows WMI dependency on this Linux host; this
  portable check does not replace the complete Windows CI suite.
- Source input metadata rechecked: Node SHA-256 and npm DSH integrity match pins.
  Linux x64: 563 npm archives, 139,655,863 bytes, plus Node 32,015,600 bytes;
  **171,671,463 bytes** total, excluding possible native-hook transfers.
  Metadata obtained using bounded header/range requests; runtime not downloaded.
- Private receipts, budget, logs and portable assertions:
  `~/.cache/phasezero-dev/harness-release/` (directory mode 0700).
  Budget receipt SHA-256: `96f987cc75bc5012a4422a6431894a56b7154188560257aeac7be4e858ec9da0`.
- Durable learning saved in this project's ai-memory:
  `gotchas/ai-release-ui-contracts-and-harness-budget-20261101.md`. Host provenance
  and exact fixes included; no secret or private backup destination published.

### Actual host state, limits and next action

Host `misael-jupiter`, BigLinux/Manjaro x86_64: official installed `pz` reports
Harness `not-installed`, reason `absent`. Installation remains pending because
Projects/AGENTS.md §9 requires operator initiation above 70,000,000 bytes, counting
the full package. Operator action: **IA & Dev → DeepSeek Harness → Instalar** or
`pz ai deepseek-harness install --json`; then retain `status --json` and
`doctor --json` receipts. Do not bypass preflight, substitute global Node or copy
files into the runtime manually. No Harness process, credentials, autostart,
paid inference, host service or workload was changed in this preparation.

Publication request names Bitbucket, while only GitHub origin is configured and
no Bitbucket connection/destination was found. Destination clarification is
pending; do not substitute GitHub or create a remote by guess. README/changelog
remain `Unreleased`, version stays 1.22.12 beta, no new tag/release or artifact
publication. Exact-SHA CI must pass before release; no red-CI override. Existing
release helper also refuses tracked dirty work: unrelated handoff edits and
untracked touch-repair script were preserved, excluded from this increment.
Do not stash, revert or commit them to satisfy that gate.

Next: complete the operator-started install, verify actual runtime via its owner,
record remaining account/sandbox/memory-client gates honestly; resolve publication
destination; inspect new exact-SHA CI; only then prepare the next eligible beta
with immutable metadata/tag, build artifacts and checksums through the official
release workflow. Cryptographic signing has not been performed or claimed.

## Operator-completed host installation — 2026-11-02 UTC

This supersedes the pending-install state in the previous preparation entry.
Operator ran the official `pz ai deepseek-harness install --json`; active receipt
records `2026-11-02T02:41:24Z` (2026-11-01 local time). Runtime was installed on
`misael-jupiter`, BigLinux/Manjaro x86_64, without bypassing resource or download
rules. Source baseline remains `3bafdd558d592e7728bd641cf754d0dd9a12ed25` on the
same canonical branch/PR #129. Only installation documentation changed here;
unrelated handoff edits and touch-repair script remain excluded.

**Actual host checks:** official installed CLI reports `installed=true`, version
`0.2.1-rc.2`, runtime `stopped`, configuration `needed`. Doctor returns `ok=true`,
`localChecksPassed=true`, state `partial`: pins/lock/SBOM and Node/package checks
pass; approximately 5 GiB RAM available versus the unchanged 2 GiB minimum.
Private Node executes `--version` as `v24.22.0`; installed npm package declares
`0.2.1-rc.2`. Installed lockfile equals the repository bytes, SHA-256
`4bac0867926ac65836ff1d9a1236546ecda2f593703ba15286e1bddbeaf67049`.
Managed root and active runtime permissions are both `0700`.

**Installed UI state probe:** offscreen Qt loaded the installed PhaseZero source
and the actual CLI status receipt. Connect/choose folder and Verify are enabled;
Install/Open are hidden and Stop disabled. Visible text correctly identifies the
installed, stopped runtime and asks for route/folder; it does not claim login.
Other host queries were stubbed and no action dispatched. This checks rendering
and available controls, not the live compositor, pointer, login or inference.
Private receipts: `host-status-installed.json`, `host-doctor-installed.json`,
`installed-integrity.json`, `installed-ui-state.json` in the existing protected
`~/.cache/phasezero-dev/harness-release/` evidence directory.

No route or workspace has been chosen. No Harness process was started; account,
API validity, quota, model execution, memory-client wiring and sandbox enforcement
remain unverified. Telemetry remains disabled and autostart off. Next operator
step: **IA & Dev → DeepSeek Harness → Conectar / escolher pasta**, select account
or API and the intended existing folder; enter credentials only in upstream UI.
The pending route/workspace question must be resolved before starting on behalf
of the operator. Stop/uninstall recovery commands above remain available.

CI snapshot on baseline `3bafdd55`: 27 successful checks, 10 in progress, 2 skipped,
no observed failure. This is not a completed gate and does not certify subsequent
commits. Version remains 1.22.12 beta / changelog Unreleased; requested Bitbucket
destination still unresolved, no tag or release created. Next publication step:
resolve destination, verify required exact-SHA CI, then use the eligible official
release path. No cryptographic signature was produced or claimed.

## Guided access, wallet and AI dashboard — 2026-11-02

Objective: remove the blank-workspace dead end, offer official DeepSeek browser
sign-in and reusable API wallet selection, and summarize IA & Dev observations.
Canonical checkout/branch and draft PR #129 remain unchanged. Base:
`6df58403e5025a085aa622f528bfe4ba078e55d9`; feature:
`26d817aef8c4b1f7cfcafcde2473287c079ecce0`; installed product source:
`e0ea0127747af23d5ca10cca7e063b62d1dbacc0`. Qt fixture cleanup: `d2a87bd1`.
Handoff commit identifiable with `git log -1 --format=%H --` this document.

### Implementation and ownership

- Native Linux connection dialog suggests saved/context/detected project (this
  host: `/home/misael/Projects/PhaseZero`), permits changing it, offers friendly
  account/API choices and keeps the default loopback port under Advanced.
- Official Account controller owns OAuth/PKCE, state, callback and exchange.
  `deepseek_harness_auth.py` implements only Account state/sign-in RPC with
  authenticated local cookies and named-object arguments. Authorization URL,
  cookie and launch token stay in supervisor memory. Project UI exposes only
  presence/attempt phase; valid session, model, quota and balance are not inferred.
- `CredentialVault` owns the shared registry path and selected-provider lookup.
  Guided API selection uses an existing active DeepSeek ID or saves a new masked
  stdin key to the OS vault after preflight. Explicit consent covers this consumer
  and API charges. No key enters argv, preview, JSON or logs. New-key save followed
  by later startup failure leaves the saved wallet entry available for retry.
- Each wallet ID has a distinct API home. Upstream file credentials take priority
  over environment, so a native saved `DEEPSEEK_API_KEY` blocks wallet use. The
  owned supervisor checks selection/overrides every two seconds and stops that
  runtime on removal/invalidation; it never substitutes another key/provider.
  This is process-lifetime binding, not request-level proxy enforcement. Existing
  gateway/grant gates remain blocked. Legacy manual API homes remain separate.
- New dashboard projects the existing status callbacks: CLI/IDE installation,
  active services, memory reachability, configured MCP targets, router health,
  efficiency profiles and Harness. Individual components expand on demand;
  quotas remain immediately below. Failed readings clear their observations.
  MCP inventory alone no longer claims a verified connection in either view.
- Standing user policy is in `AGENTS.md`; no second key store, memory owner,
  polling daemon, dependency or credential-import flow was added.

### Evidence and actual host change

- **Fixture on Linux:** final combined relevant suite **220 passed in 117.12 s**.
  Final MCP label/OAuth capability follow-up **10 passed**. Coverage includes selected provider,
  missing/removed keys, no secret in argv/output, native override refusal,
  no key lookup/write during preview, stdin save, owned-child injection and
  stop on revocation. Bash parser, official ShellCheck options, compile checks,
  generated web/native catalog coherence and local documentation links passed.
- **UI Xvfb:** dark/light, 100/150/200%, 800×600 and 1280×800; OAuth/new-key forms,
  running/stopped Harness with OAuth retry visible, keyboard, screen bounds and
  no horizontal overflow. Screenshots were inspected.
  These fixtures do not certify physical touch, accessibility compliance or login.
- **Pinned upstream runtime:** actual DSH `0.2.1-rc.2` / private Node `24.22.0`
  started in a separate temporary HOME using the installed runtime read-only,
  returned `signed-out` through the Account adapter and stopped. No sign-in or
  inference request was sent. Initial argument-array prototype failed against
  upstream; named-object payload fixed it, protected by an HTTP contract test.
- **Native OS wallet:** owned dummy entry store/selected lookup/removal passed;
  plaintext metadata contained no key and the OS entry was removed. No operator
  credential was read, copied or used for a provider call.
- **Packaging:** isolated per-user install and `install-root-smoke.sh` passed,
  including metadata, imports and deployed-tree checksum. Then official user
  installer deployed immutable `e0ea0127` source on the actual host. Seven core
  installed files matched source bytes. Backup of prior PhaseZero runtime:
  `~/.local/share/phasezero/backups/1.22.12.20261102004456.2208578/`.
- **Installed UI/CLI:** source under `~/.local/share/phasezero/current` presents
  six dashboard tiles, prefilled project, two auth choices and wallet selection.
  Offscreen probe used real installed Harness status; other probes were stubbed,
  no action dispatched and no key read. Host doctor passes local checks with
  `state=partial`; operator Harness remains installed/stopped, awaiting connection.
  Existing open Central windows need reopening. Old live supervisors advertise no
  new connection feature; explicit stop/reconnect loads the new protocol.
- Private evidence: `~/.cache/phasezero-dev/harness-connect/` (0700), including
  `final-combined.log`, UI matrices/screenshots, `real-runtime-receipt.json`,
  `os-wallet-receipt.json`, installation provenance and installed UI/CLI receipts.
  Durable learning: `gotchas/deepseek-guided-wallet-and-dashboard-20261102.md`.

### Gates, rollback and next action

Baseline CI on `6df58403` had 36 successful checks, 2 skipped and one Python
failure: timed out restoring global Qt style after the reflow fixture. Cleanup
now destroys its own window before global repolish and avoids resetting an
unchanged style; all original viewport/control assertions and timeout remain.
Local combined suite passed; new exact-SHA CI still needs observation.
No Homelab workload, VM, boot, host service, account or inference was exercised.

Native dialog/dashboard/wallet binding are Linux Qt features. Windows retains
existing PowerShell lifecycle and upstream Web account/API flow; native Windows
wallet-selector parity is not certified. Actual browser authorization, provider
validity, account/model execution, quota, request grants, native memory-client
wiring and sandbox enforcement remain open. DSH stays Experimental. No new
release/tag; version remains 1.22.12 beta, requested Bitbucket destination pending.

Next operator path: reopen Central → IA & Dev → DeepSeek Harness → Conectar /
escolher pasta. Keep suggested project or choose another; select browser account
or consented wallet API, finish official authorization, then confirm project/model
in upstream Web UI. No key should be pasted into chat or shell arguments.
Rollback: stop the owned Harness first; use the preserved PhaseZero runtime backup
through the user installer/recovery path. Runtime uninstall preserves all homes
and workspace. Unrelated clean-host handoff edits and touch-repair script remain
untouched and excluded from commits. No cryptographic signing claimed.
