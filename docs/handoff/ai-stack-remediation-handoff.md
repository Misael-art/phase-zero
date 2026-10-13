# Handoff — remediação do stack de IA (AICR/AISR)

> Documento autocontido: um agente sem contexto da sessão original deve
> conseguir **implantar** o que já foi feito e **corrigir** o que falta.
> Criado 2026-09-24. Fontes: `docs/audit/ai-config-review-2026-09-24.md`,
> `docs/audit/ai-services-sweep-2026-09-24.md`,
> `docs/roadmaps/ai-stack-remediation-v1.md`.

## 1. Estado

| Item | Valor |
|---|---|
| PR | https://github.com/Misael-art/PhaseZero/pull/102 (`fix/ai-stack-remediation` → `main`) |
| Base original do PR | `origin/main` `720b7d5` (v1.21.1); merge atual `7606772` |
| Checkout do operador | `/mnt/sdcard/Projects/PhaseZero` (cartão SD; limpo em `codex/ai-host-deploy-102`, SHA de `origin/main`) |
| Worktree usado | `/mnt/sdcard/Projects/pz-ai-review` |
| Host | `misael-jupiter`, Manjaro, btrfs, systemd user units |

### Atualização operacional — 2026-09-24, após merge

- PR #102 mergeado em `main` como `7606772`; CI do SHA `683e457` verde.
- Checkout canônico `/mnt/sdcard/Projects/PhaseZero` agora está limpo na
  branch local `codex/ai-host-deploy-102`, exatamente no SHA de `origin/main`.
  `main` já estava associado a outro worktree, por isso não foi selecionada.
- WIP anterior preservado na branch original
  `fix/deck-controller-session-binding`, agora no worktree
  `/mnt/sdcard/Projects/pz-deck-wip-preserved-20260924`. Os 5.620 itens,
  seus hashes e o `git status` foram conferidos com a cópia em
  `/mnt/sdcard/Projects/pz-wip-preserved-20260924-pr102`.
- Passos 2.1 a 2.3 e 2.5 executados. `drift status` retorna `in-sync`/rc 0
  para `hermes-router` e `9router-hermes-provider`; ambas as cópias fixam
  `PZ_ROOT=/mnt/sdcard/Projects/PhaseZero`. Timer ativo; execução manual do
  auto-heal terminou `Result=success`, `ExecMainStatus=0`.
- Backup Hermes `.pz-bak.keep`: 3263 bytes, modo 0600. Config ativa restaurada,
  não vazia. Cópias de runtime, unit, timer e config pré-sync salvas em
  `~/.local/state/phasezero/backups/ai-pr102-runtime-20260924/` (diretório
  0700). O mesmo diretório guarda `.mcp.json.pre-cleanup`: só a entrada
  Bonsai-Rx foi removida, mantendo o outro servidor.
- Qwen reparado pelo `proxies restart qwenproxy`: shim aponta ao Node 24
  isolado; serviço ativo, `NRestarts=0` após observação. Chat real e login
  não foram testados. `hermes status`: config/auth/MCP/gateway positivos,
  `ready=false` porque `hermes doctor` encontra 2 vulnerabilidades npm em
  `agent-browser` e 6 no workspace web. Não aplicar `doctor --fix` às cegas.
- `routing status` reporta disponibilidade degradada (1 pronto, 13
  indisponíveis, 16 totais). `claude status` mantém
  `bonsai.updateCheck="forged"` até AISR-010. Nenhuma unit PhaseZero falha.
- `.mcp.json` mora em volume `fuseblk` e apresenta modo 777 mesmo após
  `chmod`; a inspeção por nomes de campos não encontrou segredos. O backup
  desse arquivo está no HOME, em diretório 0700 e modo 0600.

As instruções da seção 2 documentam a implantação realizada e seu rollback;
não repeti-las sem novo drift. Trabalho pendente segue na seção 3.

### Feito neste PR (com teste que falha no código anterior)

| ID | O quê | Arquivos | Teste |
|---|---|---|---|
| AISR-001 | 9Router usa shim de Node próprio; proxies religam o shim Node 24 em start/restart/test | `linux/ai/9router-manager.sh`, `linux/ai/proxy-suite.sh` (`repair_runtime_shim`) | `tests/linux-ai-runtime-shim.sh` |
| AISR-002 | Status de proxy `crash-loop` (restarts ≥ 3 sem listener) | `proxy-suite.sh` (`unit_service_state`), `linux/ui_native/proxy_models.py`, `pages/ai_proxies.py` | `tests/linux-ai-proxy-crash-loop.sh`, `test_crash_looping_proxy_is_not_shown_as_running` |
| AISR-003 | `setup-codex` não rebaixa Codex existente; `status`/`dry-run` | `linux/ai/setup-codex.sh` | `tests/linux-ai-codex.sh` |
| AISR-004 | `agent-compat rules` sem projeto → exit 2 `needs-project` | `linux/ai/setup-agent-compat.sh`, `setup-admin-bridge.sh` | `tests/linux-ai-rules-workspace.sh` |
| AISR-005 | MCP `bonsai` (bonsai-rx, produto errado) removido; erro acionável p/ npm 404 | `assets/mcp/servers/bonsai.json` (removido), `.mcp.example.json`, `linux/ai/claude_code_manager.py` | `test_bonsai_unpublished_from_npm_gives_actionable_error` |
| AISR-006 | Status Bonsai `updateCheck: forged` quando runner fixa versão | `claude_code_manager.py` (`_bonsai_update_check`) | `test_bonsai_status_flags_runner_that_fakes_latest` |
| AISR-011 | Escrita durável (fsync tmp + dir) nos writers de config Hermes | `linux/ai/hermes-router.sh`, `9router-hermes-provider.sh`, `setup-hermes.sh` (bloco `PhaseZero durable config IO`, idêntico nos 3) | `tests/linux-ai-hermes-durable-config.sh` |
| AISR-012 | `pz ai drift status|sync [--dry-run]` compara cópias de runtime × repo | `linux/ai/runtime-drift.sh`, `linux/pz`, `catalog.py` (`ai.drift-status`, `ai.drift-sync`), `linux/ui/actions.json` | `tests/linux-ai-runtime-drift.sh` |
| AISR-013 | Config Hermes vazia é restaurada do `.pz-bak`; backup nunca recebe arquivo vazio | mesmos writers de AISR-011 | idem |
| AICR-033 | `hermes status` não aprova config vazia (`configured`/`configCheckOk` exigem arquivo não vazio) | `linux/ai/setup-hermes.sh` | `tests/linux-ai-hermes-empty-config.sh` |
| AISR-014 | `routing status` ganha `providerAvailability`; UI mostra "Online, N de M"; redação de `lastError`/`errorMessage`/e-mail corrigida | `linux/ai/routing_manager.py`, `pages/ai_routing.py` | `test_status_reports_provider_availability_and_redacts_errors`, `test_routing_status_text_reports_provider_availability` |

## 2. Implantação no host (após merge do PR)

Regras: executar **no checkout do operador**, não num worktree — os
instaladores gravam o caminho do repo (`PZ_ROOT`) dentro das cópias de
runtime; rodar de um worktree apontaria os timers para ele. Cada passo tem
verificação; parar no primeiro que falhar.

### 2.0 Pré-condições

```bash
cd /mnt/sdcard/Projects/PhaseZero
git status --short            # há mudanças não commitadas de outro trabalho?
```
Se houver, **não** usar `git switch`/`stash` sem o operador; pedir a ele.
Com a árvore limpa:
```bash
git fetch origin && git switch main && git pull --ff-only
git log -1 --oneline          # deve conter os commits AISR (ver PR #102)
```

### 2.1 Preservar e restaurar a config do Hermes (P0)

Estado encontrado: `~/.hermes/config.yaml` com 0 bytes; `config.yaml.pz-bak` (3263 B) íntegro.
```bash
cp -a ~/.hermes/config.yaml.pz-bak ~/.hermes/config.yaml.pz-bak.keep
[ -s ~/.hermes/config.yaml ] || cp -a ~/.hermes/config.yaml.pz-bak ~/.hermes/config.yaml
python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); assert isinstance(d,dict) and d; print("ok", len(d), "keys")' ~/.hermes/config.yaml
```
Rollback: `cp -a ~/.hermes/config.yaml.pz-bak.keep ~/.hermes/config.yaml`.

### 2.2 Atualizar cópias de runtime (AISR-012)

```bash
linux/pz ai drift status | jq '{state, copies:[.copies[]|{name,state}]}'   # esperado: drift
linux/pz ai drift sync --dry-run    # lista hermes-router e 9router-hermes-provider
linux/pz ai drift sync
linux/pz ai drift status >/dev/null && echo in-sync   # exit 0 = in-sync
```
`sync` roda `hermes-router.sh install` e `9router-hermes-provider.sh install`
(reinstala as units/timer do Hermes). `unmanagedCopies` (em
`~/.local/share/cc-installer/tools/`) **não** são tocadas — ver AISR-010.

### 2.3 Reativar o auto-heal do Hermes

```bash
systemctl --user reset-failed phasezero-hermes-router.service
systemctl --user start phasezero-hermes-router.service
systemctl --user show phasezero-hermes-router.service -p Result --value   # esperado: success
linux/pz ai hermes status | jq '{configured, configCheckOk, ready}'   # após 2.1: configured e configCheckOk true (com config vazia ambos são false desde AICR-033)
```
Se `Result` ≠ `success`: `journalctl --user -u phasezero-hermes-router.service -n 30`.
Causas conhecidas: 9Router fora do ar (`linux/pz ai 9router status`), cartão SD
não montado (AICR-007).

### 2.4 Recuperar o qwenproxy (AISR-001)

```bash
linux/pz ai proxies restart qwenproxy          # religa o shim para Node 24
readlink -f ~/.local/share/phasezero/ai-proxies/.runtime/node24/bin/node
#   esperado: .../node24/node_modules/node/bin/node (não /usr/sbin/node)
n1=$(systemctl --user show phasezero-qwenproxy.service -p NRestarts --value); sleep 90
n2=$(systemctl --user show phasezero-qwenproxy.service -p NRestarts --value); echo "$n1 -> $n2"  # esperado: igual
linux/pz ai proxies detailed-status | jq '.proxies[]|select(.id=="qwenproxy")|.service'   # "active", não "crash-loop"
```
Prova viva (1 chamada de chat; pedir aceite do operador): `linux/pz ai proxies test qwenproxy`.
Esperado `modelsEndpoint:"ok"`; `chat:"needs-login"` significa sessão Qwen
expirada — login é do operador (`linux/pz ai proxies login qwenproxy`), nunca do agente.

### 2.5 Limpeza manual do MCP errado

`/mnt/sdcard/Projects/PhaseZero/.mcp.json` (gitignored) ainda tem `bonsai` →
`mcp.bonsai-rx.org`. Remover só essa chave (backup antes):
```bash
cp -a .mcp.json .mcp.json.bak && jq 'del(.mcpServers.bonsai)' .mcp.json.bak > .mcp.json
```

### 2.6 Verificação final

```bash
linux/pz ai drift status >/dev/null; echo "drift rc=$?"            # 0
linux/pz ai routing status --json | jq .providerAvailability       # estado real
linux/pz ai claude status | jq '.bonsai.updateCheck'               # "forged" até AISR-010
systemctl --user list-units 'phasezero-*' --state=failed --no-legend  # vazio
```

## 3. Trabalho restante (especificado)

Ordem sugerida por impacto. Para cada item: teste primeiro (deve falhar), depois código.

| ID | Sev | Problema | Onde | Correção esperada | Aceite |
|---|---|---|---|---|---|
| AISR-010 | P1 | `bonsai` do host chama `~/.local/share/cc-installer/tools/phasezero-claude-manager/claude_code_manager.py` (2305 linhas, 2026-08-22, ausente do git; repo tem 1878). Tem preflight de login WorkOS (`bonsai_auth_probe`) e o runner `bonsai-runner/bonsai-managed` + `latest-fail-open.cjs` que fixam 0.4.19 | host | **Decisão 2026-09-24: portar seletivamente o preflight de auth para `linux/ai/claude_code_manager.py` com testes; não incorporar as 2305 linhas nem apagar a cópia instalada antes da paridade funcional.** Salvar cópia antes de reinstalar. O runner que forja `latest` só pode ser substituído por origem oficial verificável; npm ainda retorna 404. | Paridade de preflight provada em fixture; cópia versionada instalada só após backup e instalação viável; `updateCheck == "upstream"` condicionado a origem oficial disponível. `unmanagedCopies` pode conter ferramentas manuais alheias ao manager. |
| AICR-007 | P2 | Launchers apontam para o checkout no SD (`/mnt/sdcard/...`): 9Router falha no boot antes do mount; `drift sync` fixa o mesmo caminho | `9router-manager.sh` (`SERVER_RUNNER`), instaladores das cópias de runtime | Copiar runner/scripts para `~/.local/share/phasezero/runtime` na instalação, ou `RequiresMountsFor=/mnt/sdcard` nas units | reboot sem `MODULE_NOT_FOUND` no journal do 9Router |
| AICR-005 | P2 | `proxies test` sempre exit 0; qualquer não-200 vira `needs-login` | `proxy-suite.sh` `test_proxies` | classes `ok/needs-login/unreachable/upstream-error` pelo código HTTP; exit 2 se algum não-ok; envelope `summary/next` | teste com servidor fake devolvendo 200/401/500/timeout |
| AICR-006 | P2 | `session-present` só indica que existe artefato | `proxy-suite.sh` (`web_status=session-present`) | rótulo "sessão salva (não verificada)" + data do último `test` ok | teste do rótulo na UI |
| AICR-008/009 | P2 | `9router provider status` mostra e-mail; `providers.active` conta indisponíveis | `9router-manager.sh` | mesma máscara de e-mail do `routing_manager.EMAIL_RE`; `available` separado | teste com fixture de providers |
| AICR-010 | P2 | `pz ai status` 30 s | `linux/ai/status.sh` | versões em paralelo com cache por mtime, timeout 1 s; hero da página sem bloquear | medir < 5 s |
| AICR-011 | P2 | backup não cobre `~/.config/phasezero/9router/settings.json` nem `~/.local/share/phasezero/ai-routing` | `linux/ai/backup-manager.sh` | incluir com a mesma cifragem | `tests/linux-ai-backup.sh` estendido |
| AICR-012/013 | P2 | `pz updates check` não inventaria codex/opencode/hermes/codexbar/omniroute/rtk/ai-memory/snapshots; npm 404 do Bonsai | `linux/updates/app-updates.sh` | coletor só-leitura por ferramenta, com estado `unpublished` | teste com `npm view` stub |
| AICR-014/028 | P2 | `pz ai help/--help/<vazio>` e `pz ai memory` dão erro | `linux/pz` `cmd_ai` | imprimir bloco de ajuda; `memory (status|doctor)` → `setup-memory.sh status` | exit 0 e texto |
| AICR-025 | P2 | remoção do catálogo MCP não propaga para configs geradas | `linux/ai/mcp-manager.sh` | marcar entradas gerenciadas e remover as que saíram do catálogo em `sync` | teste com config contendo entrada órfã |
| AICR-026/027 | P2 | ollama/open-webui sem status/remove; docs prometem desinstalação inexistente | `setup-ollama.sh`, `setup-open-webui.sh`, `docs/ai-tools.md` | contrato status/dry-run/remove ou corrigir a tabela | — |
| AICR-029 | P2 | status sem envelope comum (hermes, codexbar, odysseus, omo, mcp, desktop), sempre exit 0 | backends | `{schemaVersion,state,summary,nextAction}` + exit 0/2/3 | teste de contrato por família |
| AISR-009 | P2 | Windows confunde provider Bonsai (trybons.ai) com Bonsai-Rx | `bootstrap-tools.ps1` (busque `bonsai-rx`) | separar; Pester `bootstrap-mcp-repair`/`resilience` | Pester 3.4.0 verde |
| AISR-007/008 | — | Bonsai como API p/ OpenCode | — | **pausado**: login upstream desativado; retomar só com login funcionando e regra de permissão para o agente ler a credencial da CLI | — |
| CI | P2 | suítes `tests/linux-ai*.sh` não rodam no CI | `.github/workflows/ci.yml` | job Linux executando-as | CI verde |

## 4. Armadilhas conhecidas

- **Sandbox HOME**: um `export` por variável em scripts de teste. Nunca
  `export HOME=... XDG_CONFIG_HOME="$HOME/..."` numa linha (já destruiu
  `9router.env` uma vez).
- **Status ≠ leitura pura**: `hermes-router.sh enforce|apply|heal`,
  `proxies ensure|login|install`, `drift sync` mutam o host. `proxies test`
  faz 1 chamada de chat real por proxy e grava estado de login em
  `~/.local/state/phasezero/ai-proxies/`.
- **Credenciais**: o classificador de segurança do agente bloqueia leitura de
  stores de credencial (Bonsai CLI, `secrets/`). Não contornar; pedir regra de
  permissão ao operador.
- **Gerador de actions**: `python linux/ui/generate_actions.py <destino>`
  exige o argumento de destino; sem ele falha (e com stderr descartado parece
  sucesso).
- **Falha pré-existente conhecida** (não é regressão): pode aparecer
  `test_status_contract.py::...[emulation.dualscreen.status]`.
- **Comandos de verificação** usados nesta remediação:
  ```bash
  export QT_QPA_PLATFORM=offscreen
  export PZ_USE_SUDO=0
  for t in tests/linux-ai*.sh tests/linux-9router.sh; do bash "$t" >/dev/null 2>&1 || echo "FAIL $t"; done
  python -m pytest tests -q
  shellcheck -S warning linux/pz linux/ai/*.sh linux/server/ai-policy-broker.sh   # base: 15 avisos
  python linux/ui/generate_actions.py /tmp/a.json && diff -q /tmp/a.json linux/ui/actions.json
  ```
