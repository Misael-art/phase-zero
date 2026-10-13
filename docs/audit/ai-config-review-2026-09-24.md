# Auditoria AICR — Revisão de configurações de IA (2026-09-24)

Executa `docs/roadmaps/ai-config-review-v1.md`. Revisão leitura + prova: nenhum
código de produto alterado. Correções propostas em
`docs/roadmaps/ai-stack-remediation-v1.md`.

## Resumo executivo

- **Funciona?** Parcialmente. Suítes 100% verdes (13 shell + 1066 pytest), mas a
  validação viva mostra **1 de 4 proxies respondendo chat** (DeepSeek). Qwen está
  em crash-loop (81 reinícios) por ABI Node trocado por outro gerenciador; Kimi
  e MiMo precisam de login. Status e UI dizem "rodando" para o Qwen morto.
- **Ficou obsoleto?** Sim: pin do Codex CLI (0.66.0 vs 0.156.1) faria
  *downgrade* do que está instalado; 9Router 0.5.55 vs 0.5.86; RTK 0.43 vs 0.49.
- **Acrescentar?** Backup não cobre providers/combos do 9Router nem estado de
  roteamento; `pz updates` não inventaria CLIs IA; `rules` sem workspace escreve
  em `/`.
- **UX?** `pz ai status` levou 30,8 s (baseline 4,6 s); hero do pilar espera por
  ele. `pz ai --help` dá erro. Estados "rodando"/"sessão presente" desonestos.

Os testes passam porque cobrem fixtures; nenhum cobre shim de runtime
compartilhado, crash-loop sob `is-active`, nem workspace vazio em `rules`.

## Achados

| ID | Sev | Dimensão | Superfície | Evidência | Recomendação |
|---|---|---|---|---|---|
| AICR-001 | P1 | functional | `linux/ai/9router-manager.sh:104-106` × `linux/ai/proxy-suite.sh:151-152,575` | 9Router reaponta shim compartilhado `.runtime/node24/bin/node -> /usr/sbin/node` (v26.8.1). Launchers dos proxies põem esse `bin` no PATH; `npx tsx` roda em Node 26. Journal qwenproxy: `better_sqlite3.node ... NODE_MODULE_VERSION 137. This version of Node.js requires NODE_MODULE_VERSION 147`, `ERR_DLOPEN_FAILED`, `restart counter is at 81`, ~700 MB + `vite build` por ciclo | Runtimes separados por consumidor (9Router não toca `node24/bin`); launcher dos proxies chama `tsx` pelo node isolado; teste de regressão |
| AICR-002 | P1 | functional/ux | `proxy-suite.sh:1850` (detailed-status), `proxy_models.py:49-56` | `service` = só `systemctl is-active`. Qwen: detailed-status `"service":"active"`, `proxies test` → `"service":"down","modelsEndpoint":"unreachable"`. UI rotula "rodando" | Combinar `is-active` + porta + `NRestarts` crescente → `crash-loop`/`failed`; UI com severidade de erro. Regressão de classe do item P0 da auditoria 2026-08-24 ("sucesso aparente após falha") em superfície de status |
| AICR-003 | P1 | freshness | `linux/ai/setup-codex.sh:13,18,23` | Pin `@openai/codex@0.66.0`; upstream `npm view` 0.156.1 (2026-09-24); host já em 0.156.1 via instalador standalone (`~/.codex/packages/standalone/...`). `pz ai setup codex`/`all` instala 0.66.0 e `ln -sfn` sobrescreve `~/.local/bin/codex` → downgrade de ~90 versões | Não pinar versão antiga: detectar instalação existente e sair; pin mínimo, não exato; `status`/`--dry-run` |
| AICR-004 | P1 | functional (segurança) | `linux/ai/setup-agent-compat.sh:907-908,326` | `rules` chama `apply_rules` com `WORKSPACE_ROOT` vazio → alvos `/AGENTS.md`, `/CLAUDE.md`, `/.github/...`. `tests/linux-admin-bridge.sh` log: `mv: não foi possível criar arquivo comum '/AGENTS.md': Permissão negada` / `WARN: agent rule sync failed` — só salvo por permissão. `init` já recusa `/` (`:819`), `rules` não | Mesmo guarda de `init` em `rules`; sem workspace → `needs-project` exit 2; teste afirmando zero escrita fora do sandbox |
| AICR-005 | P2 | functional | `proxy-suite.sh:1623-1668` | `proxies test` sai `rc=0` com chat `unreachable`/`needs-login` (ledger abaixo). Qualquer não-200 (inclui timeout `000`, 5xx) vira `needs-login`. Array cru, sem `summary`/`next` (contrato `ai-tools.md` exit 0/2/3) | Classificar `unreachable/needs-login/upstream-error`; exit 2 degradado; envelope |
| AICR-006 | P2 | ux | `proxy-suite.sh:1377` | Kimi `webValidation.status:"session-present"` (só artefato existe) mas chat real `needs-login` | Rotular "sessão salva (não verificada)" até um chat ok; data do último teste |
| AICR-007 | P2 | functional | launcher `~/.local/bin/phasezero-9router-server` gerado de `9router-manager.sh:37` | `exec /usr/sbin/node /mnt/sdcard/Projects/PhaseZero/linux/ai/9router-server-runner.js`; journal no boot: `Cannot find module '/mnt/sdcard/.../9router-server-runner.js'` (SD ainda não montado). Também muda de comportamento a cada `git checkout` do operador | Copiar runner para `INSTALL_ROOT` na instalação, ou `RequiresMountsFor=` |
| AICR-008 | P2 | functional (redação) | `pz ai 9router provider status` | `"name":"<e-mail da conta>"` para providers codex/xai (regra 8 do roadmap: nome de conta não deve sair) | Mascarar `name` quando parece e-mail |
| AICR-009 | P2 | ux | `pz ai 9router status` | `"healthy":true,"providers":{"total":16,"active":16}` enquanto provider status tem 7 `unavailable`, 2 `unknown`, 1 disponível | Expor `available` separado de `active`; UI mostra "1 de 10 disponível" |
| AICR-010 | P2 | ux (latência) | `linux/ai/status.sh:13` e ~40 `command_record` sequenciais | `pz ai status` 30,8 s; `auth status` 30,8 s; `hermes status` 44,2 s. Trace: `headroom --version` bate timeout 5 s; cada `--version` ~0,7 s em série. Confundidor: crash-loop AICR-001 consumindo CPU durante a medição | Paralelizar/cachear versões por mtime do binário; timeout 1 s; hero não bloquear no agregado |
| AICR-011 | P2 | gap | `linux/ai/backup-manager.sh:44-46` | Cobre `ai-proxies/`, `hermes.env`, auth opencode/codex, ai-memory. Não cobre `~/.config/phasezero/9router/settings.json` nem `~/.local/share/phasezero/ai-routing` (1,5 MB) | Incluir, com mesma cifragem |
| AICR-012 | P2 | gap | `linux/updates/app-updates.sh:40-50` | Inventaria 9router, odysseus, desktop apps. Ausentes: codex CLI, opencode, hermes, codexbar, omniroute, rtk, ai-memory, snapshots dos proxies | Coletor só-leitura por ferramenta |
| AICR-013 | P2 | freshness | 9Router / RTK | 9Router instalado 0.5.55, npm 0.5.86. RTK host 0.43.0, release 0.49.0 (2026-09-11). Sem aviso em `updates check` para RTK | Via AICR-012 |
| AICR-014 | P2 | ux | `linux/pz:766` | `pz ai --help` / `pz ai help` → `ERROR: unknown ai subcommand` rc=1; `pz ai` sem args rc=1. Help só em `pz --help` | `help`/`--help`/vazio imprimem bloco `pz ai` |
| AICR-015 | P3 | functional | `pz ai proxies detailed-status` | MiMo `apiKeyConfigured:true` e `missing:["api-key"]` no mesmo registro | Renomear para `localApiKeyConfigured` ou explicar |
| AICR-016 | P3 | ux | `catalog.py` `ai.setup.tool` | Preview é `ai status`, não prévia do setup escolhido; `all` roda 15 instaladores sem agregar falha | Preview por ferramenta; resumo final |
| AICR-017 | P3 | freshness | shellcheck `-S warning` | 15 avisos (12×SC2034, 5×SC2155) em `hermes-router.sh`, `9router-hermes-provider.sh`, `omniroute-manager.sh`, `setup-codexbar.sh`, `mcp-manager.sh` | Limpar |
| AICR-018 | P3 | ux | `pages/ai_dev.py:168`, `main_window.py:169` | Nome "IA & Dev" único hoje; LUX-016 propõe "Desenvolvimento" — decidir lá (sobreposição, não duplicar) | Seguir LUX-016 |

`unverified`: cobertura de `secrets/schema.json` para BYOK minimax/nex/zhipu —
leitura bloqueada por regra deny do ambiente do agente.

## Vereditos F0 (frescor)

| Família | Local | Upstream (2026-09-24) | Veredito |
|---|---|---|---|
| Codex CLI | pin 0.66.0 | 0.156.1 | **stale** (AICR-003) |
| 9Router | 0.5.55 | 0.5.86 | stale |
| OmniRoute | não instalado | 3.8.50 | N/A (not-installed) |
| OpenCode | host 1.18.23 (lockstep) | 1.18.32 | current (patch) |
| OMO | exige OpenCode ≥ 1.4 | oh-my-opencode 4.19.4 | current (gate ok) |
| Claude Code | 2.1.281 | 2.1.281 | current |
| Hermes | v0.21.0 (2026.8.31) | v2026.9.21 | stale (gate `hermes-distribution-audit.json` bloqueia update — intencional) |
| OpenClaw | ausente no host | 2026.9.6 | unknown |
| RTK | 0.43.0 | v0.49.0 | stale (AICR-013) |
| ai-memory | 1.31.1 (pin) | sem release pública consultável | unknown |
| CodexBar | — | v0.65.0 (2026-09-23) | unknown (versão local não reportada) |
| Node runtime proxies | 24.19.0 isolado | — | current, mas shim quebrado (AICR-001) |
| mcp-remote | `@latest` | 0.14.3 | current (flutuante) |
| Proxies (4) | snapshots pinados | — | current por design; SBOM pendente (auditoria 08-24) |

Docs drift: 81 comandos `pz ai …` citados nas três docs de contrato; todos os
subcomandos existem no dispatch. Subcomandos não listados no help são aliases
(`router9`, `omni-route`, `op-ledger`…) — aceitável.

## Validação viva do stack de API (F1)

| Alvo | serviço | sessão/cred | `/v1/models` | chat real | latência | veredito |
|---|---|---|---|---|---|---|
| kimiproxy :3010 | active | session-present | ok | falha (não-200) | 26,4 s | **blocked-needs-login** |
| qwenproxy :3011 | active*(crash-loop)* | session-present | unreachable | unreachable | 44,4 s | **broken** (AICR-001/002) |
| deepsproxy :3012 | active | authenticated | ok | ok (200) | 5,9 s | **ok** |
| mimo-ai-proxy :3013 | inactive → start → stop | missing-credentials | ok | falha (não-200) | 3,3 s | **blocked-needs-login** |
| 9Router :20128 | active, loopback | dashboard-ready | health ok | não testado (fora da allowlist) | 1,8 s | ok gateway; 1/10 providers disponível |
| OmniRoute :20129 | — | — | — | — | 0,3 s | **not-installed** |

Nenhum conteúdo de prompt/resposta registrado.

## Suítes (F1)

| Suíte | Resultado |
|---|---|
| 13 suítes shell do roadmap | todas rc=0 (admin-bridge com WARN de AICR-004) |
| `pytest tests` | 1066 passed, 9 subtests, 19m57s — inclui `dualscreen.status` (falha pré-existente não reproduziu) |
| `generate_actions.py` | sem drift em `actions.json` — **correção 2026-09-24**: o comando do roadmap omitia o argumento `destination` e falhou em silêncio; refeito com `generate_actions.py <destino>` em `origin/main`: sem drift |
| shellcheck `-S warning` | 15 avisos (AICR-017) |
| Pester | não executado (revisão estática de paridade) |

Paridade Windows↔Linux: portas 3010–3013/20128 coerentes com
`assets/ai/proxy-manifest.json`; OmniRoute sem contraparte Windows (gap
conhecido, P3).

## Regressões da auditoria 2026-08-24

| Item | Estado |
|---|---|
| Sucesso aparente após falha de serviço (P0) | corrigido no install/start; **reaparece na camada de status** (AICR-002) |
| Mimo sem credencial (P0) | ok — status honesto `missing-credentials` |
| Política única de roteamento (P1) | ok — `routing status` 0,57 s, suíte verde |
| Falha de IDE degrada estado (P1) | ok — suíte `linux-ai-proxies` verde |
| `pz ai status` 4,6 s (P2) | **piorou**: 30,8 s (AICR-010) |

## Ledger de execução

- Host `misael-jupiter`, Manjaro 6.18.49; worktree `../pz-ai-review`,
  branch `codex/ai-config-review-v1` em `720b7d5` (v1.21.1). Checkout do
  operador intocado.
- `ai-memory search` feito antes; rtk e ai-memory presentes (modo ready).
- Probes vivos (todos na allowlist F1):
  - 2026-09-23T23:15:43-03 `systemctl --user start phasezero-mimo-ai-proxy.service`
  - 23:16:12 `proxies test kimiproxy`; 23:16:56 `qwenproxy`; 23:17:02 `deepsproxy`; 23:17:06 `mimo-ai-proxy` (4 chamadas de chat)
  - 23:18:06 `systemctl --user stop phasezero-mimo-ai-proxy.service` (restaurar estado anterior)
  - Efeito colateral do próprio `proxies test`: grava status de login em
    `~/.local/state/phasezero/ai-proxies/` (não em `~/.config`).
- Leituras: status/detailed-status, 9router status/provider status, omniroute
  status, journal user units, `npm view`/GitHub API (sem instalar).
- Nenhum install/ensure/login/sync/apply executado.
