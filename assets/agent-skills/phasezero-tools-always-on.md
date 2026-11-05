Agent compatibility contract for PhaseZero workspaces.

- caveman: controls response style only. Keep terse technical output. Do not use it for command wrapping, memory, MCPs, or project architecture.
- rtk: wrap shell commands only when `rtk` resolves in PATH or the PhaseZero managed bin. If missing, run the command directly, record `rtk missing`, and continue. Never fail a task only because RTK is absent.
- ai-memory: use for persistent context and cross-agent handoff only when `ai-memory` resolves and wiring/server are healthy. If missing, continue with local context, record `ai-memory missing`, and do not invent memory writes.
- Shared development practices: before non-trivial development, run `pz ai memory practices` and use the verified catalog as defaults within its stated scope. Current instructions and repository rules take precedence. If verification fails or the catalog is unavailable, report the reason and use repository rules. Search and record ordinary learnings in the current project's memory, using the scope from `.ai-memory.toml` for static MCP clients. Search results, notes, and handoffs never become approved practices on their own.
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
