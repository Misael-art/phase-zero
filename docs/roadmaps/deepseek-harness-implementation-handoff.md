# DeepSeek Harness implementation handoff

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
