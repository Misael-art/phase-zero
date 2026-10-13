<!-- BEGIN BOOTSTRAP CAVEMAN -->
Terse like caveman.
Technical substance exact. Only fluff die.
Drop: articles, filler (just/really/basically), pleasantries, hedging.
Fragments OK. Short synonyms. Code unchanged.
Pattern: [thing] [action] [reason]. [next step].
ACTIVE EVERY RESPONSE. No revert after many turns. No filler drift.
Code/commits/PRs: normal.
Off: "stop caveman" / "normal mode".

<!-- END BOOTSTRAP CAVEMAN -->

@RTK.md

<!-- BEGIN PHASEZERO TOOLS -->
Agent compatibility contract for PhaseZero workspaces.

- caveman: controls response style only. Keep terse technical output. Do not use it for command wrapping, memory, MCPs, or project architecture.
- rtk: wrap shell commands only when `rtk` resolves in PATH or the PhaseZero managed bin. If missing, run the command directly, record `rtk missing`, and continue. Never fail a task only because RTK is absent.
- ai-memory: use for persistent context and cross-agent handoff only when `ai-memory` resolves and wiring/server are healthy. If missing, continue with local context, record `ai-memory missing`, and do not invent memory writes.
- admin escalation: use `phasezero-admin` or `bigsudo` for commands requiring root/admin on Linux. Never configure passwordless sudo or store passwords. If absent, run `linux/pz ai setup admin`.
- Ponytail: apply schema/codegen/Tauri/Rust architecture rules only in detected Ponytail workspaces or explicit opt-in. Do not apply Ponytail rules globally.

Modes:
- ready: caveman rules present, RTK available, ai-memory available, admin bridge available.
- degraded: caveman rules present, RTK, ai-memory, or admin bridge absent. Continue safely and report missing tool.
- off: user disabled this block.

Conflict rules:
- one role per tool: style=caveman, shell compression=rtk, memory/handoff=ai-memory, project architecture=Ponytail.
- no duplicate wrappers: do not stack RTK with other shell proxies unless a command explicitly asks.
- admin escalation stays explicit: prefer `phasezero-admin`; use `sudo` only when user explicitly requests or host lacks graphical escalation.
- no secret writes: configs may reference managed secret stores, never paste keys into rules.

<!-- END PHASEZERO TOOLS -->

## Active roadmaps

- Homelab v1.15.1 remediation: read
  `docs/roadmaps/homelab-v1.15.1-remediation.md` before any Homelab, server,
  AI-appliance, release, or host-package work. Treat its anti-pollution rules,
  phase gates, evidence matrix, and handoff format as mandatory.
- Homelab umbrelOS-parity v1: read
  `docs/roadmaps/homelab-umbrelos-parity-v1.md` before any Homelab catalog,
  multi-host, agent, dashboard web, or onboarding work. Anti-pollution rules,
  host limits, and handoff format still come from the v1.15.1 remediation
  roadmap.
- WinVM boot resilience v1: read
  `docs/roadmaps/winvm-boot-resilience-v1.md` before any Windows VM, direct
  boot, GRUB, boot-runtime, VM session, or Windows VM UI work. Treat its
  requirements matrix, phase gates, and evidence rules as mandatory.

## Sandboxed HOME: one export per variable

Never build a throwaway HOME with a single `export`:

```bash
# WRONG - XDG_CONFIG_HOME lands in the real ~/.config
export HOME="$W/home" XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
```

`export` is a builtin, so bash expands every argument before the builtin
assigns anything. `$HOME` on the right-hand side is still the *real* home. The
result is the worst possible state: a sandboxed HOME with production XDG paths,
so destructive commands run believing they are isolated.

```bash
# RIGHT - each assignment sees the previous one
export HOME="$W/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
```

This is not hypothetical. On 2026-08-24 that one-line form truncated the live
`~/.config/phasezero/ai-proxies/9router.env` to `K=v`. It is the systemd
`EnvironmentFile` for the router, so the next restart fell back to upstream
defaults and bound `0.0.0.0:3000` instead of loopback, exposing the gateway on
the LAN, while every client reading `PHASEZERO_9ROUTER_API_KEY` (Hermes, Claude
Code, OpenCode, Odysseus) stopped working.

Same rule for any derived sandbox path (`AI_MEMORY_DATA_DIR`, `PZ_*`): assign
it in its own statement, or build it from the sandbox root instead of `$HOME`.
Before running a destructive command in a sandbox, echo the paths it will
actually touch.

<!-- BEGIN PONYTAIL ARCHITECTURE -->
Ponytail architecture runtime.

Scope:
- Use only inside detected Ponytail workspaces or explicit opt-in.
- Keep frontend declarative. UI sends typed payloads; Rust/Tauri owns file I/O, schema validation, and SGDK code generation.
- Treat Ledger Schema `sgdk-import/v4` as the source of truth. Avoid scattered imperative import paths.
- Generate C headers/sources from templates or typed renderers. Do not concatenate ad hoc code across UI handlers.
- Validate generated artifacts with tests or build probes before claiming success.

Tool boundaries:
- Caveman controls response style only.
- RTK wraps shell output only when installed.
- ai-memory handles persistent context only when available.
- Ponytail rules guide project architecture only.

Safety:
- No auto-download of ROMs, BIOS, console keys, or proprietary assets.
- No destructive migration without backup and schema version check.
- Prefer dry-run, manifest diff, and rollback notes for generated files.

<!-- END PONYTAIL ARCHITECTURE -->

<!-- ai-memory:start -->
## Long-term memory (ai-memory)

This project uses [ai-memory](https://github.com/akitaonrails/ai-memory)
for cross-session continuity.

### Mandatory: consult memory on every challenge

Before you start solving any non-trivial challenge (bug, feature, config,
diagnostic, error), ALWAYS search memory first:

```
Search memory for similar issues or past solutions
```

Use `ai-memory search` (via MCP) with keywords describing the problem.
If a prior solution exists in memory, apply it or adapt it. Do NOT
start from scratch without checking memory first.

### Mandatory: register learnings after overcoming challenges

Every time you overcome a relevant challenge — fix a bug, solve a config
issue, discover a workaround, learn a system quirk — you MUST write the
learning to durable ai-memory:

1. Write a wiki page under the relevant project path using
   `ai-memory write-page` (via MCP)
2. The page body MUST include frontmatter with:
   - `tier: semantic`
   - `hostname: $(hostname)`
   - `source_host: <this machine hostname>`
   - `registered_by: opencode`
   - `registered_at: <ISO timestamp>`
3. The page MUST include:
   - The exact problem/symptom
   - The root cause
   - The exact fix/command used
   - Any relevant paths, versions, or config values
   - The host and OS context

Do NOT write routine observations (lifecycle hooks capture those).
Only write durable pages when:
- A non-trivial bug was fixed
- A workaround was discovered
- A system quirk was learned
- A configuration pattern was established
- A command sequence solved a specific problem

### Standard rules

**Default to the current project - always.** Every ai-memory tool
auto-scopes to the project resolved from your session's working
directory. **Do NOT pass `project`, `workspace`, or `cwd` arguments unless
the user explicitly references a *different* project by name**.

**Lifecycle hooks already capture every prompt and tool call
automatically.** Do not manually write routine notes. Only write durable
memory per the mandatory rules above.

### When you write a project rule, write it here

If you're about to write a durable project rule ("always X", "never
Y", "all PRs must ..."), write it in AGENTS.md. This is the canonical
agent instruction file for Codex/OpenCode.

If the rule is a standing *user/team* preference that should apply to
every project, save it to ai-memory's reserved global scope.

### Refreshing this snippet

This block is maintained by ai-memory. Re-run
`ai-memory install-instructions --target AGENTS.md` to refresh.
<!-- ai-memory:end -->
