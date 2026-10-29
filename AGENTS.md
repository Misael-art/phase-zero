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

- Contributor on clean host: read `docs/handoff/clean-host-development-20261024.md`
  before preparing a new development machine. Use `tools/dev-bootstrap.sh` on
  Arch family or `tools/dev-bootstrap.ps1` on Windows. The contributor wrapper
  installs tooling only; product services, VMs and host boot remain separate.

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

## Local test temporary storage

Before local pytest or artifact-heavy test runs, ensure `TMPDIR` and
`PYTEST_DEBUG_TEMPROOT` use writable per-user directories on disk, outside
`XDG_RUNTIME_DIR`. Keep each derived shell export in its own statement.
Do not sweep `/run/user`, terminate agents, or reset desktop services to recover
space. Use the on-demand terminal repair: archive only inactive, verified test
fixtures with backup; preserve live locks, ambiguous locks and current fixtures.

## Steam Deck desktop input safety

- Physical USB keyboard/mouse and touchscreen remain available during every
  controller mode. Never grab, disable, unbind or reset them to switch a game
  profile. Touchscreen recovery targets FTS I2C only, never Valve HID or USB.
- Temporary controller ownership requires live PID, start ticks and boot ID;
  retain emulator children until the last consumer exits. File existence alone
  never proves ownership. Desktop mapper yields to Steam/game owners at login
  and while running, not only during manual start.
- `pz steamdeck input` owns PhaseZero desktop preference recovery. RetroFE uses
  the registered backend and its existing Steam/KDE guardians. Do not create a
  second audio policy or discard original preferences after failed recovery.
- Preserve intentional desktop mute/volume changes; restore the pre-game/login
  baseline on transitions. Keep the virtual keyboard available, including input
  through trackpad, and retry late touchscreen enumeration without input grabs.
- Help/status never request elevation. Before opening an admin dialog, ensure
  an input path is usable; do not repeatedly prompt an operator unable to type.
  Mock/CI success does not certify physical USB, touch, speech or cold boot.

## Coleção Projects: continuidade e organização

- Política comum: [../AGENTS.md](../AGENTS.md), especialmente autonomia, testes, GitHub e recursos (§§5–10); raiz/branch em [registro central](../.workspace/projects.json). A orientação atual de raiz única substitui recomendações históricas de criar worktrees/clones por tarefa; os contratos técnicos e gates deste projeto permanecem obrigatórios. Em outro host, preserve este mesmo método em um único checkout registrado, sem recriar caminhos antigos.
- Antes de implementar, leia `docs/handoff/clean-host-development-20261024.md`, a auditoria de status e o roadmap da frente afetada, identifique causa, owner, dependências e aceite. Procure a solução oficial existente e integre nela; não introduza soluções concorrentes, aliases ambíguos ou refatorações fora do pedido. Neste host, a única raiz é `/home/misael/Projects/PhaseZero`.
- Execute o lote até implementar, testar, revisar e preservar a continuidade. Resolva decisões reversíveis pelo contexto; não pare em planos nem peça confirmação para editar/testar o que já está autorizado. Comunique descobertas, bloqueios e entrega, sem narrar cada comando ou pequeno avanço.
- Antes de operações pesadas, confira espaço do destino, RAM e carga; estime saídas e retenção. Reutilize ferramentas/ambientes compatíveis, limite jobs e encerre somente processos temporários próprios. Não mate trabalhos alheios, limpe caches compartilhados ou apague evidência para obter um gate verde.
- Use o wrapper `tools/dev-bootstrap.sh` e o ambiente já provisionado, sem instalar o produto, serviços ou VMs para testar código por conveniência. TMPDIR/pytest ficam em disco persistente próprio, fora de `/run/user`; preserve exportações HOME/XDG separadas. Não crie outro banco, gateway, gerenciador de contas ou fluxo paralelo.
- Faça os checks pertinentes a toda alteração; para documentos, revise diff, referências e coerência. Para código, cubra comportamento/regressão e execute os gates aplicáveis, sem desativá-los. Execute checks e o fluxo afetado no host disponível, isolando efeitos. Fixtures e CI não homologam login, cotas, provedores, Homelab, boot ou Windows VM. Gates físicos continuam sujeitos ao ambiente e escopo autorizados. `.mimosa`, `uber-defesa-privada`, Ai-memory, credenciais e estado compartilhado permanecem protegidos; não publicar nem limpar pelo nome PhaseZero.
- Reutilize a autenticação válida e os helpers existentes. Nunca peça senha/token no chat, copie sessões ou grave credenciais em código/log. Se faltar acesso indispensável, solicite uma única ação pelo fluxo oficial, preserve o estado e avance no trabalho independente; não repita permissões já concedidas.
- Confira remoto, PRs e checks do SHA antes do lote e ao publicar; reutilize o PR da mesma branch/objetivo. Revise arquivos explícitos, segredos e tamanho, faça commit/push do incremento autorizado e confirme o SHA remoto. Sem stage global de resgates, push forçado, merge de pesquisas ou publicação de dados privados. Não faça polling contínuo de CI.
- PR cabe ao incremento revisável; release somente a marco elegível com versão/artefatos/notas e gates completos, dentro da autorização de publicação vigente. Não gerar release por manutenção destas regras. Preserve limites de merge/deploy e falhas preexistentes; acesso autenticado não amplia autorização.
- Fontes e receitas ficam no Git; bancos, ROMs, assets privados, SDKs, builds, caches e pacotes de resgate seguem owner/destino próprios e recuperação verificável. `.gitignore` não é backup. Novo arquivo acima de 10 MiB exige revisão; downloads acima de 70 MB são manuais, inclusive o pacote dividido, com origem/tamanho/hash/destino preparados.
- Ao fechar, mantenha apenas os gerados necessários e atualize o handoff existente com SHA, testes no host, limites de validação, bloqueio e próximo passo. Não declare produto pronto quando faltar evidência do alvo real, nem deixe um único exemplar de trabalho útil sem proteção identificada.
