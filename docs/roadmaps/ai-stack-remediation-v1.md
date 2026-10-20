# Roadmap canônico — Remediação do stack de IA v1 (AISR)

> Corrige os achados P1 da auditoria `docs/audit/ai-config-review-2026-09-24.md`
> (AICR). P2/P3 ficam no backlog ao fim.

## Metadados

| Campo | Valor |
|---|---|
| Status | AISR-001..006, 011..014 e AICR-033 implementados no PR #102; implantação e itens restantes em `docs/handoff/ai-stack-remediation-handoff.md` |
| Criado | 2026-09-24, America/Sao_Paulo |
| Base observada | `origin/main` `720b7d5` (v1.21.1) |
| Origem | AICR-001..004 |
| IDs | `AISR-xxx`. Não confundir com `AICR-*`, `LUX-*`, `REV-*`, `CCS-*` |

## Regras

1. Worktree dedicado; nunca no checkout do operador.
2. Testes com HOME/XDG em tmp, **um `export` por variável**; `PZ_USE_SUDO=0`.
3. Cada item: teste que falha antes e passa depois, citado no PR.
4. Copy PT-BR; identificadores em inglês.
5. Não reinstalar proxies no host do operador para provar; prova viva só com
   aceite (mesma allowlist do AICR F1).

## Itens

| ID | Origem | Entrega | Prova |
|---|---|---|---|
| AISR-001 | AICR-001 | `9router-manager.sh` para de escrever `$PROXY_ROOT/.runtime/node24/bin/node`; usa runtime próprio. Launchers de proxies executam `tsx` pelo `NODE_BIN` isolado, não pelo PATH. `proxy-suite.sh` repara shim apontado para node ≠ 24 | Teste: rodar `ensure_runtime` do 9Router com node de sistema v26 fake; assert shim dos proxies continua v24. No host (com aceite): `phasezero-qwenproxy` `NRestarts` estável e `proxies test qwenproxy` com `/v1/models` ok |
| AISR-002 | AICR-002 | `detailed-status`/`status` derivam `service` de `is-active` + porta + `NRestarts` entre duas leituras → `running`/`starting`/`crash-loop`/`failed`. `proxy_models.py` mapeia `crash-loop` para severidade erro com próxima ação | Teste com systemctl stub `active` + porta fechada + restarts crescendo → `crash-loop`; teste Qt offscreen do rótulo |
| AISR-003 | AICR-003 | `setup-codex.sh`: se `codex` existente ≥ mínimo suportado, não reinstala nem troca symlink; pin vira mínimo (`PZ_CODEX_MIN_VERSION`); adiciona `status` e `--dry-run` | Teste: codex fake 0.156.1 no PATH → nenhuma chamada `npm install`, symlink intacto |
| AISR-004 | AICR-004 | `setup-agent-compat.sh rules` sem workspace → recusa com `needs-project` exit 2 (mesmo guarda de `init`: vazio, `/`, `$HOME`) | Teste: `rules` sem `PZ_WORKSPACE_ROOT` e sem registro → exit 2, zero arquivo criado; `linux-admin-bridge.sh` sem WARN |

### Bonsai (pedido do operador, 2026-09-24)

Diagnóstico:

- `@bonsai-ai/cli` retorna **404** no registry npm (`npm view` e
  `registry.npmjs.org/@bonsai-ai%2fcli`): instalação nova impossível pelo
  caminho atual de `_ensure_bonsai`; instalação existente segue funcionando.
- No host do operador, `~/.local/bin/bonsai` aponta para
  `~/.local/share/cc-installer/tools/bonsai-runner/bonsai-managed` (criado
  manualmente em 2026-08-21, **fora do repositório**), que fixa
  `PZ_BONSAI_INSTALLED_VERSION=0.4.19` e, via `latest-fail-open.cjs`, forja a
  resposta `/@bonsai-ai/cli/latest` com a versão instalada quando o registry
  falha. Com o registry em 404, a CLI se acha sempre atualizada: preso em 0.4.19.
- Erro conceitual 1: Bonsai só existe como *launcher* de Claude Code. OpenCode
  recusa (`opencode_9router_manager.py`, `BONSAI_ROUTE=direct is unsupported`)
  e 9Router trata Bonsai como erro (`routing_manager.py`, `bonsai-in-router`).
  Upstream é um endpoint Anthropic Messages (`https://go.trybons.ai`, Bearer),
  consumível por qualquer harness.
- Erro conceitual 2: o MCP `bonsai` apontava para `mcp.bonsai-rx.org` —
  Bonsai-Rx, produto sem relação (programação reativa visual). Host nem
  resolve DNS; foi o MCP que falhou ao conectar nesta sessão. Windows repete a
  confusão no manifesto de segredos (`bootstrap-tools.ps1`: provider `bonsai`
  com `signupUrl`/`docsUrl` em bonsai-rx.org e baseUrl MCP bonsai-rx).

Decisões do operador: credencial para a API vem do login da CLI (`bonsai
login`), sem chave extra; exposição é **opt-in explícito**, fora de combos
`phasezero-*` e de fallback automático (Bonsai registra prompts para benchmark).

| ID | Entrega | Prova | Estado |
|---|---|---|---|
| AISR-005 | Remover MCP `bonsai` (bonsai-rx) do catálogo Linux e do `.mcp.example.json`; `_ensure_bonsai` com erro acionável quando o npm dá 404 | `test_bonsai_unpublished_from_npm_gives_actionable_error` | **done** |
| AISR-006 | Status Bonsai honesto: `updateCheck` (`valid`/`forged` quando o runner injeta `latest-fail-open`), próxima ação. Não mexer no runner do host sem aceite | `test_bonsai_status_flags_runner_that_fakes_latest`; host real: `updateCheck:"forged"` | **done** (registry publicado/despublicado fica para `pz updates`, AICR-012) |
| AISR-007 | Gateway loopback `bonsai-gateway` (127.0.0.1:3014, unit user): Anthropic Messages → `go.trybons.ai`, Bearer lido do store da CLI a cada requisição (relogin vale na hora; chave nunca copiada para outro arquivo), token local 0600 para clientes, `/health` sem segredo | teste com store fixture cifrado no mesmo formato | **pausado** 2026-09-24: upstream com sinais de desativação (npm 404, `docs.trybons.ai` sem DNS, login WorkOS "authentication is disabled for this application"); além disso o classificador do agente exige regra de permissão para ler a credencial da CLI |
| AISR-008 | `pz ai bonsai api enable|disable|status|test`: provider `bonsai` no OpenCode (`@ai-sdk/anthropic`, baseURL do gateway) com backup/rollback; `bonsai start` intocado; 9Router continua sem Bonsai em combos automáticos | teste de merge/rollback do `opencode.json` | pausado com AISR-007 |
| AISR-010 | Host roda cópia divergente de `claude_code_manager.py` em `~/.local/share/cc-installer/tools/phasezero-claude-manager/` (2305 linhas, 2026-08-22, ausente de qualquer commit; repo tem 1878): origem do preflight de login `upstream-auth-disabled` e do runner que fixa 0.4.19. Portar seletivamente preflight de auth com testes; preservar cópia instalada até paridade e backup. Substituir runner forjado só com origem oficial verificável | `diff` entre as duas cópias; `git log --all -S upstream-auth-disabled` vazio; teste de paridade pendente | decidido, implementação pending; registry npm 404 bloqueia troca do runner |
| AISR-009 | Windows: separar provider Bonsai (trybons.ai) de Bonsai-Rx no manifesto de segredos e no catálogo MCP | Pester `bootstrap-mcp-repair`, `resilience` | pending |

## Execução

| ID | Commit | Teste |
|---|---|---|
| AISR-001 | `848b504` | `tests/linux-ai-runtime-shim.sh` (falha no código anterior) |
| AISR-002 | `dcc9c3f` | `tests/linux-ai-proxy-crash-loop.sh`, `test_crash_looping_proxy_is_not_shown_as_running` |
| AISR-003 | `1f506b7` | `tests/linux-ai-codex.sh` (falha no código anterior) |
| AISR-004 | `5962461` | `tests/linux-ai-rules-workspace.sh` (falha no código anterior) |

Nota: nenhuma suíte shell de IA roda no CI (`.github/workflows/ci.yml` só faz
`bash -n`). Item de backlog: incluir `tests/linux-ai*.sh` no job Linux.

## Gates

- G1: AISR-001..004 com testes verdes; suíte completa no mesmo estado ou melhor.
- G2 (aceite do operador): validação viva repetida — Qwen deixa de estar
  `broken`; status/UI não mostram "rodando" para serviço em crash-loop.

## Próxima onda (varredura `docs/audit/ai-services-sweep-2026-09-24.md`)

| ID | Origem | Entrega |
|---|---|---|
| AISR-011 ✅ | AICR-021 | Helper de escrita durável (tmp + `fsync` + `os.replace` + `fsync` do diretório) usado por todos os writers de config do Hermes/OpenCode/9Router |
| AISR-012 ✅ | AICR-020/022 | Cópias gerenciadas carregam hash da fonte; `status` expõe `runtimeDrift`; `pz ai doctor --drift` lista divergências e o comando de atualização |
| AISR-013 ✅ | AICR-019 | Auto-heal do Hermes restaura `config.yaml` vazio a partir do `.pz-bak` válido (validação YAML) e registra a restauração |
| AISR-014 ✅ | AICR-023 | `routing status`: `health` reflete providers disponíveis; alerta de combo sem membro disponível |

## Backlog P2/P3

### AISR-015 — Bonsai npm 404 e tentativa de login (2026-10-18)

O `@bonsai-ai/cli` 0.4.19 consulta `/latest` antes de `login` e chama
`semver.gt(undefined, installedVersion)` quando recebe 404. No host, `/-/ping`
responde 200, mas metadados do pacote e `/latest` respondem 404. A CLI local
permanece instalada; o token local exige renovação. Uma observação anterior de
`upstream-auth-disabled` está vencida e **não** prova o estado atual do login.

PhaseZero agora classifica separadamente controle do npm, pacote e `/latest` no
diagnóstico explícito `pz ai claude bonsai-probe`. Quando o CLI local 0.4.19
corresponde ao hash conhecido, uma tentativa **explícita** de login em terminal
privado pode contornar somente a checagem de versão que falha em HTTP 404. O
preload não altera o pacote, não vale para `start` ou `status`, não chama o
serviço em diagnóstico, não afirma que a versão está atualizada e não promove
login, sessão ou proxy a `ready`. CLI diferente falha fechado. O fluxo de
recuperação preserva o armazenamento de credenciais se a tentativa falhar.

Teste real de PTY no host alcançou o fluxo de dispositivo do CLI, com espera
por autenticação; foi interrompido sem concluir login. Antes, `open('/dev/tty',
'r+')` falhava porque PTY não suporta seek; passou a usar `r+b` sem buffer.
Os detalhes da tentativa ficam apenas no terminal privado; nenhum código,
token ou URL de verificação entra em status, logs ou repositório. Estado atual
do provedor: **desconhecido**. API/proxy para outros clientes continua fora de
escopo até contrato oficial e concessão por consumidor verificáveis.

Evidência e rollback: `docs/handoff/bonsai-404-login-20261018.md`.

### AISR-016 — Botão de login Bonsai e erro de autenticação do provedor (2026-10-20)

O operador concluiu o fluxo local de abertura do login, mas o navegador exibiu
`Authentication is disabled for this application`. A observação atual do usuário
é distinta do HTTP 404 do npm: o primeiro bloqueia a autenticação remota;
o segundo impede instalar/atualizar a CLI. A documentação oficial ainda indica
`@bonsai-ai/cli` e `bonsai login`; não há caminho alternativo oficial comprovado.
PhaseZero não controla a configuração da aplicação de autenticação Bonsai.

Entrega local: `Login Bonsai` permanece visível e acionável ao lado de
`Atualizar diagnóstico`, inclusive quando a observação npm está vencida.
O clique mantém o preflight do gerenciador e o terminal privado; não afirma
sessão, API ou proxy prontos. O card distingue tentativa local de autenticação
remota e orienta suporte Bonsai para a mensagem do navegador. Aceite: teste
temático em 800×600 prova geometria, hit-test e despacho pelas ações públicas
com estados disponível, vencido e indisponível; testes do gerenciador preservam
gates da CLI e das credenciais. Uma observação histórica de provedor desativado
não veta nova tentativa solicitada pelo usuário após possível recuperação;
diagnóstico passivo continua sem criar tentativa. Falha ou timeout do login
orienta sobre a mensagem do navegador e restaura as credenciais anteriores.
Homologação no pacote instalado ainda depende
da release. Login remoto, execução e proxy continuam bloqueados até Bonsai
reativar a aplicação e existir contrato oficial para consumo por outros CLI.

- AICR-005 `proxies test`: exit 0/2/3, envelope `summary/next`, classificação `upstream-error`/`unreachable`.
- AICR-006 "sessão salva (não verificada)" até chat ok.
- AICR-007 runner do 9Router copiado para `INSTALL_ROOT` (independe do checkout em SD).
- AICR-008 mascarar e-mail em `9router provider status`.
- AICR-009 `available` vs `active` em providers do 9Router.
- AICR-010 `pz ai status` < 5 s: versões em paralelo/cache, timeout 1 s, hero sem bloqueio.
- AICR-011 backup de `9router/settings.json` e `ai-routing`.
- AICR-012/013 `pz updates check` inventaria codex, opencode, hermes, codexbar, omniroute, rtk, ai-memory, snapshots.
- AICR-014 `pz ai help|--help|<vazio>`.
- CI: rodar `tests/linux-ai*.sh` no job Linux.
- AICR-024..031 (redação no routing, propagação de remoção MCP, ciclo ollama/webui, doc de desinstalação, `pz ai memory`, envelope comum, latência, unit legada).
- AICR-015..018 polimento (campo MiMo, preview de setup, shellcheck, naming via LUX-016).
