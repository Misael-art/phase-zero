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

## 5. Contas Codex por perfil — 2026-10-29

**Objetivo/IDs:** PXA-006/010, gestão no painel de múltiplos perfis Codex
Desktop/CLI e suas sessões ChatGPT Web, sem substituir contas existentes.
Owner: `linux/ai/codex_profiles.py`, no domínio de Contas e conexões; bridge
existente continua proprietário do setup/rota/túnel Web.

**Continuidade:** raiz única `/home/misael/Projects/PhaseZero`, branch
`codex/clean-host-dev-bootstrap`, PR draft
[#129](https://github.com/Misael-art/phase-zero/pull/129). HEAD inicial
`83c50a60b8c0a7ab7c95941b1b06be482d4b8d0d`; implementação `47e4012`
(`feat(ai): add isolated Codex account profiles to accounts panel`). Commit
deste handoff segue a implementação. Sem merge/release.

**Arquivos:** backend `linux/ai/codex_profiles.py`; roteador `linux/pz`;
instanciação/ownership em `linux/ai/chatgpt_web_bridge.py`;
`linux/ui_native/codex_profiles_panel.py` integrado a `pages/accounts.py`;
testes `test_codex_profiles`, `test_codex_profiles_panel` e ajuste do fake do
bridge. Jornada, contrato e limites detalhados no
[roadmap](../roadmaps/apps-dev-ai-accounts-v1.md#contas-codex-no-painel--incremento-de-2026-10-29)
e superfície de escrita em `docs/host-surface.md`.

**Resultado:** nome/cor/ID persistentes, Desktop/CLI por conta, Web e navegador
com armazenamento próprio, atalhos por modo, arquivar/restaurar sem apagar
sessões, e recuperação do daemon Web ao abrir novamente. Cadastro envia
metadados por stdin e retorna resumo redigido ao runner. Não há troca
automática por cota. IDs locais não certificam identidade no provedor.

Dois defeitos estruturais tratados: parada Web antes percorria todos os
`app-codex-web-gpt-launcher-*.scope`; agora filtra somente owners do perfil.
Caminhos muito longos causavam `listen EINVAL` no socket `ipc/ipc.sock`, com
Desktop preso no carregamento. Execução passa a usar raiz curta
`$XDG_DATA_HOME/phasezero/codex/<id>`; metadados continuam em
`phasezero/ai-accounts/codex-profiles`. Abertura recusa socket acima de 107
bytes. Nenhum symlink de credenciais é necessário.

**Testes:**

- Fixture: 139 testes focados passaram em `test_codex_profiles.py`,
  `test_codex_profiles_panel.py`, `test_chatgpt_web_bridge.py`,
  `test_accounts_page.py`, `test_account_contract.py` e
  `test_product_inventory.py`. Incluem processos CLI simultâneos, persistência,
  ambiente/rotas limpos, isolamento de scopes/unidades, perfil desconhecido,
  metadados inválidos, redirecionamento por symlink, socket UTF-8, ausência de
  download automático e privacidade. Após ajuste final de foco/refresh,
  22 testes das páginas de contas/perfis passaram novamente.
- Host de desenvolvimento: `tools/dev-bootstrap.sh doctor --profile ui`
  pronto; Bash syntax, ShellCheck de `linux/pz` com exclusões oficiais do CI,
  compilação Python e `git diff --check` passaram. Hooks de stage/commit
  aprovaram arquivos explícitos. Gitleaks local indisponível; varredura do CI
  ainda necessária.
- Aplicativo real: launcher `linux/ui/native.sh --smoke-test --category
  'Contas e conexões'` abriu com Python/PySide do sistema e produziu captura,
  sem erro. Quatro atalhos de perfil em fixture e atalho real do painel
  passaram `desktop-file-validate`.
- Codex Desktop instalado, CLI 0.166.0: duas instâncias em Xvfb atingiram
  **Entrar no ChatGPT**, com portas 22104/22108 e diretórios Electron próprios.
  Capturas individuais revisadas. Primeiro ensaio com `--disable-gpu` falhou;
  ensaio seguinte revelou limite IPC. Verificação final usou raiz curta e
  ANGLE/SwiftShader, sem mudar flags da instalação do operador. Receber HTML
  no servidor local não foi tratado como prova de tela pronta.

**Estado do host:** BigLinux/Manjaro, `misael-jupiter`. Atalho **PhaseZero —
Contas Codex** criado no menu e na área de trabalho do usuário, apontando ao
launcher da raiz canônica. Pacote instalado continua 1.22.11; o novo painel é
acessível por esse atalho de desenvolvimento. Instalações nativa e Web
anteriores foram referenciadas, sem leitura/cópia dos tokens, logout ou mudança
de rota. Nenhuma nova conta real cadastrada automaticamente, daemon de produto
instalado, reinício de sessão ou operação de boot executados.

Evidência local regenerável:
`~/.cache/phasezero-dev/evidence/codex-profiles-20261029/` (capturas, script e
receipt). Fixtures do Codex não receberam autenticação real. Processos de
teste encerrados; ausência de `auth.json` e de processos usando as duas raízes
anônimas foi conferida antes de removê-las. Logs/receipts/capturas preservados. Diretórios pytest compartilhados não foram varridos.

**CI/limites:** SHA anterior tinha `shell-lint` falho no PR; checks do novo SHA
devem ser consultados após push. Fixture/Xvfb não homologam login A/B, identidade
igual entre Desktop e Web, cota, túnel por conta, retenção de sessão após reboot,
integração com IDE ou Windows. Apelido/cor identificam painel e atalhos; classe
e título das janelas continuam pertencendo ao launcher instalado. Registros
agregados de Contas permanecem redigidos; CLI administrativa privada não deve
ser publicada com identificação local.

**Próximo passo exato:** abrir **PhaseZero — Contas Codex**, identificar conta
existente e adicionar outra. Entrar pelo Desktop em cada conta; conferir
identidade exibida pelo Codex; preparar/login Web do ID correspondente e
conferir identidade no ChatGPT. Provar uso simultâneo e reabertura após logout
da sessão/reboot sem mistura de conta. Esse passo exige ação de autenticação
do operador. Para comandos deste checkout, usar `linux/pz ai codex-profiles`;
`pz` do pacote antigo pode não conhecer a nova família.

## 6. Escrita/consentimento Desktop do perfil — 2026-10-30

Relato: onboarding não conseguia conceder acesso à Área de Trabalho.
Base `e3aa4592`, mesma raiz/branch e PR #129. Causa reproduzida: ambiente
isolado sem `user-dirs.dirs`; GLib e `xdg-user-dir DESKTOP` retornavam
`/home/misael/Desktop` inexistente, embora a pasta real fosse
`/home/misael/Área de trabalho`. Handler `requestDesktopRoot()` no bundle
instalado chama `app.getPath("desktop")` e abre o diretório com `opendir()`.
Falha ocorria na validação da pasta, antes de concluir a concessão de acesso.

Correção em `sync_desktop_user_dirs()` no bridge, reutilizada por
`CodexProfiles.prepare_desktop_dirs()`: espelha somente oito caminhos XDG
padrão em native/web, com strings literais, idempotência, backup e preservação
de mapas próprios. Preparo de perfil e abertura Web standalone convergem para
o mesmo helper. Credenciais, preferências gerais, sandbox e permissões Unix não
são copiados/ampliados.

Host: dois mapas criados no perfil existente. GLib/xdg passaram a resolver a
pasta localizada. Dois processos com os ambientes nativo/Web criaram, leram e
apagaram arquivo de prova nessa pasta; diretórios temporários próprios foram
removidos. Codex sandbox real negou escrita fora do workspace sem concessão
(exit 1) e aceitou a pasta de prova explicitamente autorizada (exit 0), sem
prompt de inferência. CLI 0.166 usa `codex sandbox -P NOME ...`; não utiliza
mais o subcomando `linux` nesse comando. Probes usaram configuração temporária,
sem alterar a política dos perfis do operador.

103 testes focados passaram (perfis, painel, bridge e Accounts), incluindo
regressão de diretórios localizados, atualização com backup, ausência de
importação de configurações e tratamento literal de caracteres de shell.
Teste de lançamento passou a simular também porta livre, pois o perfil real
aberto ocupava a porta de teste; fixture não consulta o socket do operador.
Compilação Python e `git diff --check` passaram. Evidência local:
`~/.cache/phasezero-dev/evidence/codex-desktop-write-20261030/{before,after,sandbox-write}.json`.

Janela autenticada do operador foi preservada. **Próximo passo:** fechar apenas
a janela do perfil afetado, abrir novamente pelo painel e repetir **Permitir
acesso**. Cache de caminhos do processo anterior exige reabertura. Repetição do
onboarding autenticado não foi automatizada; teste de filesystem/sandbox não
equivale a essa jornada GUI. Login e dados existentes permanecem nos mesmos
stores. Não houve reboot, chmod amplo ou desativação de sandbox.

## 7. Abrir perfil ativo retornava falha — 2026-10-30

PXA-006/010, base `af0a5669`, mesma branch/PR. Ledger do painel registrou erro
“Janela deste perfil já aberta ou porta ocupada”. Perfil continuava ativo com
Electron e webview; o guard de porta impedia o operador de recuperar sua janela.

`desktop_instance()` e `focus_desktop_instance()` no bridge validam namespace
de dados, PID/UID/executável/start ticks e socket/peer Linux. `CodexProfiles.launch`
e `Bridge.desktop` reaproveitam o warm-start do pacote para foco da instância
correta. Comando `argv: []`, confirmação `ok\n`; nenhuma chamada de inferência,
novo processo ou sinal de encerramento é necessário. Processo Linux reescreve
argv como uma única string; validação reconhece essa representação com caminho
completo e limites de argumento, sem execução de shell ou match por prefixo.

109 testes focados passaram (perfis, bridge, painel e Accounts), incluindo IPC
Unix real, peer errado sem envio de payload, mudança de start ticks, diretório
de outro perfil, argv agregado, PID stale e porta estrangeira sem spawn/kill.
Host: `launch(ID, "desktop")` respondeu `focused=true`, `started=false`; PID e
start ticks permaneceram iguais. Evidência:
`~/.cache/phasezero-dev/evidence/codex-profile-reopen-20261030/live-handoff.json`.

Janela autenticada recuperada sem encerrar trabalho em execução. Warm-start
preserva cache do processo: para reaplicar o mapa de pastas da seção anterior,
operador deve usar **Sair** somente naquela instância e depois abrir de novo.
Não houve reinício forçado, parada de outro Codex ou mudança de credenciais.


## 8. Limpeza de perfis personalizados — 2026-10-30

Pedido autoriza implementar e executar exclusão individual/em lote, preservando
Codex padrão e Web padrão. Base `550d8540`, mesma raiz/branch/PR #129. Novo
`remove --id ID` / `remove --all-custom`, ambos com `--dry-run`, integrado ao
runner e painel. Proteção de `current` obrigatória no backend; arquivados entram
no lote. Apps ativos bloqueiam a limpeza; sem kill, reset ou elevação.

Operação retira dados/atalhos do ambiente ativo para recuperação privada com
manifesto e rollback de falha do registro; runtime/socket inativo removido
separadamente. Não apaga pacote compartilhado, sessão primária nem Web padrão;
não revoga recursos remotos. Detalhes e recuperação no roadmap Apps/IA/contas.

193 testes focados passaram (perfis/painel/bridge/Accounts, ledger/help,
contratos de contas e inventário).
GUI real com PySide6 do host executou exclusão individual e geral, com prévia e
QProcess/CommandRunner oficiais, em HOME/XDG próprios; capturas antes/depois e
receipt preservados. Teste com processo vivo comprova bloqueio sem sinais;
socket Unix stale real comprova limpeza sem cópia entre filesystems.

Host real: comando fonte `linux/pz ai codex-profiles remove --all-custom`
removeu 1 perfil autorizado; registro agora contém somente instalação padrão,
raiz runtime personalizada vazia, sem atalhos personalizados ou processos
residuais. Sete caminhos do padrão permaneceram idênticos por existência,
inode e SHA-256. Backup privado identificado em `host-after.json`; não publicar
conteúdo. Evidência local: `~/.cache/phasezero-dev/evidence/codex-profile-cleanup-20261030/`.

Próximo passo: abrir **PhaseZero — Contas Codex** novamente para carregar os
botões. Operador pode repetir criação, autenticação A/B e testes GUI de escrita.
Esses aceites de login/identidade/cota continuam pendentes; limpeza não certifica
túnel ou onboarding autenticado. CI anterior: shell-lint 0.9.0 falhou; 0.11.0 e
lint/gitleaks passaram. Não houve merge/release nem alteração do pacote 1.22.11.


## 9. Ícones, principal primeiro e menu Codex — 2026-10-30

Base `bdbfed30`, mesma raiz/branch/PR #129. Pedido autoriza implementar e aplicar
no host ícone indicado, variações por cor exclusiva e nomes Codex [nome] /
Codex Web [nome]. Padrão agora primeiro; paleta suporta 64 adicionais sem RGB
repetido, inclusive arquivados. SVG compartilhado preserva forma indicada e
remove fundo quadriculado do raster. Sem download/runtime gráfico extra.

Menu passa a duas entradas visíveis por conta; CLI/site ocultos do menu e
acessíveis no painel/contexto. Override nativo preserva Exec/protocolos/ações
da instalação padrão. `organize --dry-run` e botão organizador convergem para
mesmo backend, migram cores legadas e ocultam somente AppImage Codex conhecido
e entrada Web Tools extra. Bridge reconhece ownership do painel e snapshot
estável atualizado evita recriar entradas antigas. Opt-out Web segue coberto,
sem apagar atalho nativo ou contornar gates de tools/opt-in.

Host tinha duas contas no momento da aplicação: novo perfil surgiu após limpeza
da seção 8 e foi preservado. Colisão azul corrigida; quatro entradas visíveis,
três duplicações antigas ocultadas/removidas do desktop. Sete caminhos de
credenciais/configs idênticos; estado do bridge preservado exceto owner.
Protocolo codex/codex-browser-sidebar já apontava ao ID primário, sem mudança.
Cache KDE/MIME refeito, sem root, término de apps ou reinício de sessão.

204 testes focados passaram (perfis/painel/bridge/Accounts, ledger/help,
contratos de contas e inventário), incluindo limite de 64 cores adicionais,
recusa de colisões/cores reservadas, migração legada, protocolo preservado,
owner do guardião e opt-out Web sem afetar nativo. Gate de cancelamento de
desenvolvimento e renderização sem QtSvg também passaram. AST/diff passaram.
CI Arch do primeiro SHA revelou libQt6Svg.so.6 ausente em PySide6 mínimo;
import direto foi removido. QtGui renderiza os mesmos contornos/gradiente sem
dependência adicional. Log do job 124208244093 preservado na evidência local.

GUI PySide6 real, em HOME/XDG próprios, executou criação e organização com
prévia/CommandRunner/QProcess; três contas mostraram ícones coloridos, padrão
primeiro e seis entradas visíveis. Desktop files validados. Evidência privada:
`~/.cache/phasezero-dev/evidence/codex-icons-20261030/` (receipts, capturas e
imagem original; não publicar estado privado).

Próximo passo: reabrir **PhaseZero — Contas Codex** para recarregar classe Qt
atualizada; menu do host já foi corrigido. Homologação de login A/B/Web,
identidade real, cotas e onboarding permanece do operador. Não houve instalação
ou atualização do pacote de produto 1.22.11, merge ou release.


## 10. Aparência acompanha a cor da conta — 2026-10-31

Base lógica `eaca07b5`; raiz/branch/PR #129 preservados, incluindo commits
concorrentes de entrada Steam Deck. User autorizou tema de Aparência pela cor
do perfil e confirmou prosseguimento. `current` e Web padrão ficam intocados.

Configurações nativas `desktop.appearanceLightChromeTheme.accent` e
`desktop.appearanceDarkChromeTheme.accent` passam a acompanhar cor registrada,
nos perfis nativo/Web. Helper único no bridge faz patch TOML validado, backup,
idempotência e preservação semântica; atualizações de cor/atalhos/preparo e
organizador integram política. Metadata de cor do Web sustenta reentrada;
snapshots existentes são atualizados com backup. Detalhes/limites no roadmap.

208 testes focados passaram, cobrindo tema nativo/Web, principal intocado,
fontes/fundo/mode preservados, formato nested/inline emitido pelo app, TOML
inválido/ambíguo recusado, idempotência e cor persistida de Web sem env herdado.
Probe real app-server/config/read confirmou duas chaves com destaque verde em
HOME anônimo; nenhum login, prompt de modelo ou inferência foi realizado.

Host: duas contas adicionais existentes receberam dois config.toml nativos;
seus Webs ainda não preparados receberão tema no seed. Configs do padrão/auth
permaneceram byte a byte iguais e demais configurações equivalentes por hash
semântico. Sem encerrar app, mudar sandbox/rota ou reiniciar sessão. Evidência
privada: `~/.cache/phasezero-dev/evidence/codex-appearance-20261031/`.

Próximo passo: reabrir janelas dos perfis personalizados para reler Aparência.
Padrão mantém cores/preferências atuais. Login real, cota e Web autenticado
continuam gates distintos; alteração de tema não os homologa.


### Aplicação e execução no host — 2026-10-31

Pedido posterior exige host já operante, commit e PR. Código de Aparência já
publicado em `4924380e`, PR #129. Estado inicial desta verificação: cores
persistidas, duas instâncias adicionais fechadas e painel Qt fechado. Chamadas
`CodexProfiles.launch(ID, "desktop")` abriram ambas em namespaces separados;
atalho canônico **PhaseZero — Contas Codex** abriu o painel atualizado.

Host Wayland/KDE: PID/executável/home de cada Electron validados, dois webviews
HTTP responderam com título Codex. Consulta temporária, somente leitura, ao
KWin confirmou ambas as janelas mapeadas, não minimizadas, com dimensão não
nula, além do painel PhaseZero. Instâncias primária/Web anteriores permaneceram
abertas. Nenhum app foi encerrado nem preferência de cor do padrão alterada.
Sondas KWin próprias descarregadas; aplicações solicitadas continuam abertas.

Uma conta adicional possui credencial local; outra não tem login salvo e sua
janela está aberta para autenticação oficial do operador. Presença local não
valida sessão/cota. Não houve inferência nem preenchimento de credenciais.
Cores claro/escuro dos dois arquivos nativos correspondem ao registro. Webs
adicionais continuam não preparados. Evidência privada:
`~/.cache/phasezero-dev/evidence/codex-appearance-20261031/{host-running,host-windows,host-deployment}.json`.

CI Arch limpo passou em `4924380e` (dois jobs), assim como scans de segredo;
demais checks ainda executavam durante a coleta. Este complemento só registra
execução real e não muda código. Árvore de código permaneceu limpa antes da
edição documental. Próximo passo: autenticar a conta sem login pelo fluxo do
aplicativo; PR #129 continua draft, sem merge/release.


### Fundo da conta verde — correção após relato do operador

Base `236e389e`, mesma branch/PR #129. Ajuste anterior só mudava destaque e
não cumpria identificação visual da janela. Helper de Aparência agora altera
`accent` e `surface`, mantendo demais preferências e instalação principal.
Fundos são distintos em 65 cores; contraste do texto default ≥ 4,5:1 nos dois
modos. Verde escuro `#174227`, claro `#dcece2`.

45 testes de perfis e 93 de bridge/UI passaram. Screenshot real do aplicativo
instalado, em HOME/XDG anônimos e Xvfb próprios, confirmou tela de login verde.
Sonda CDP não enumerou página principal; captura nativa do display foi usada,
sem fingir sucesso de automação CDP. Evidência privada no lote
`codex-green-window-20261031`, incluindo visual-proof e host-theme-proof JSON.

Host recebeu dois configs customizados atualizados e snapshots do bridge.
Principal/config e todos os auth.json presentes ficaram byte a byte iguais.
HMAIL executava outra tarefa: processo preservado; janela aberta continua
pendente de recarga após tarefa terminar. Próximo passo: reabrir somente essa
conta e conferir tema autenticado. Não certificar recarga ao vivo, login/cota
ou Web autenticado por essa prova anônima. Sem merge/release.

### Codex Web: atualização retomável e aplicação no host — 2026-11-02

Branch/PR: `codex/clean-host-dev-bootstrap`, #129 (draft). Base de entrada
`b39654af540d4cc8f3a7061dca09d112eeaad130`; correção do bridge
`a8334412dcef9c4f6a0d09d50abaeecf1eb34c91`; fonte instalada inclui retenção
segura do instalador em `8629e1ea`.

Pedido: erro `route-enable-failed` após **Atualizar app**, launcher 6.1.14 →
6.1.17. Owner: `linux/ai/chatgpt_web_bridge.py`, cartão privado IA & Dev e
instalador oficial por usuário. Runtime e hook permaneciam na versão anterior;
reativação guardada recusava essa mistura. Migração transacional de journals v10
acontece antes do launcher novo e mantém configuração, login e modo Full.
Atualização incompleta retoma com pacote local, sem novo download; divergência
de baseline continua bloqueada. Detalhes no roadmap Apps/Dev/IA, seção PXA-010
de 2026-11-02.

Dependência descoberta no host: identidade antiga do túnel referia PID
reutilizado por processo do desktop. `tunnel-client 0.0.16` recusava inspeção
desse executável. Recuperação compara marcas de início do kernel sob lock
upstream, preserva backup e altera só registro do perfil comprovadamente antigo;
nenhum sinal ao processo atual. Conta, chave e túnel remoto permanecem intactos.

Validação:

- 143 testes de bridge, cartão e perfis/painel Codex; 13 de coesão da instalação.
  `shellcheck -S warning`, `bash -n` do instalador e `git diff --check` passaram.
  Ambiente do wrapper `tools/dev-bootstrap.sh doctor --profile ui`: pronto.
- CLI 6.1.17 real, em perfil descartável sem sessão, conectou/desconectou/
  reconectou com journals coerentes e restauração exata. Manifesto verificou
  4.899 arquivos do runtime. Sem inferência/mensagem de teste.
- Host retomou **Atualizar**: `update=recovered`, `ready=true`,
  `stage=tools-experimental`; launcher ativo, runtime 6.1.17, rota ativa e
  daemon em `127.0.0.1:17841`. Modo Full e login local presentes. SHA-256 do
  config principal igual; modelo, sandbox, aprovação, Desktop, projetos,
  plugins e MCPs preservados. PID reutilizado ficou intacto.
- Instalador `packaging/linux/install-user.sh` aplicado de export Git imutável
  `8629e1ea`, sem incluir WIP local. Runtime de usuário 1.22.12 atualizado e
  snapshot estável dos atalhos conferido por SHA-256. Backup anterior:
  `~/.local/share/phasezero/backups/1.22.12.20261102072658.3721797/`.
- Antes de instalar, retenção foi corrigida para filtrar somente nomes de
  release/backup próprios. Diretório de recuperação RetroFE existente teve
  mesmo digest antes/depois; outros owners não entram nessa retenção.

Evidência privada em `~/.cache/phasezero-dev/codex-web-update/`:
`final-tests.log`, `packaging-tests.log`, `native-migration/receipt.json`,
`host-repair-receipt.json`, `installed-health.json`,
`installed-pz-route-verify.json`, `install-source.json`, `install-user.log`.
Backups da integração e metadado de PID ficam no journal privado já existente.
Export temporário de fonte é regenerável com `git archive 8629e1ea`; não é
outro checkout nem destino de continuidade. Fontes oficiais ficam nesta única
raiz e branch remota.

Limites e próximo passo: teste pago e prova nova de escrita/MCP/cota não foram
executados; sessão local não comprova validade remota. Reabrir painel PhaseZero
carrega também texto atualizado da UI. SHA de entrada tinha 35 checks positivos,
2 falhas (smoke DeepSeek Windows e temporização de skeleton da Overview) e
2 skips; logs da entrada foram preservados. São falhas observadas antes deste
incremento, sem reprodução em `main` nesta sessão. PR continua draft, sem
merge/release; aguardar checks do incremento e tratar gates pendentes na frente
correta antes de publicação.

### Codex Web por plano e cor própria — 2026-11-02

Incremento `e53cd0cd`, mesma branch e PR #129. Owner: domínio existente de
perfis Codex; bridge continua dono da conexão, permissões e cofre. Pedido
implementado em UI/CLI: automático habilita Pro/Pro Lite, demais planos ou plano
desconhecido/vencido ficam desabilitados. Override por conta é reversível;
cancelar diálogo não mostra preferência ainda não salva. Desligar preferência
preserva sessões existentes; não implica autostart nem concede ferramenta.

Novas contas recebem `webColor` exclusivo ao criar; paleta Web não coincide com
65 cores nativas. Organizador migra metadados antigos e ícones. Web principal
também ganha fundo/destaque próprios; nativo principal permanece intocado.
Modo Web de perfis exige `tools_enable` idempotente e abre `desktop("tools")`,
sem fallback silencioso. UI oferece Verificar conexão e Conectar ferramentas;
saída separa `connectionReady` de `executionVerified`, sem expor identidade/chave.

Host aplicado pelo organizador oficial: uma Pro Lite habilitada e duas Plus
desabilitadas em automático. Web principal usa destaque `#eb15da`, distinto
das três cores nativas atuais. Configuração principal, todas as configurações
nativas e auth.json presentes mantiveram hashes; opções Web fora de Aparência
preservadas. Rota ativa, política válida e daemon em loopback. Nenhum app do
operador foi fechado. Janelas já abertas precisam recarregar para mostrar tema.

Instalador oficial por usuário aplicado de export Git imutável `e53cd0cd`;
runtime permanece 1.22.12. Quatro módulos instalados comparados por SHA-256;
snapshot estável do bridge atualizado. Backup anterior:
`~/.local/share/phasezero/backups/1.22.12.20261102080250.3928001/`.
Recuperação RetroFE preservada pelo digest. CLI instalado confirmou
`connectionReady=true`, `executionVerified=false`. Render da UI instalada,
com identidade ocultada, confirmou exatamente um preparo Web habilitado e dois
desabilitados. UI antiga precisa ser reaberta para carregar código novo.

Validação local: 159 regressões passaram; 13 testes de UI reexecutados após
ajuste do diálogo de preferência passaram. Layout claro/escuro em 100/150/200%
e larguras 560/1280 sem overflow horizontal e com controles alcançáveis. Texto
das 130 superfícies nativa/Web tem contraste ≥ 4,5:1. Wrapper dev-ui pronto;
diff revisado sem segredos ou WIP alheio.
Fixtures do cartão usam HOME/XDG próprios, sem depender das preferências de
conta reais do operador; cinco testes desse cartão passaram após isolamento.

**Limite real de ferramentas:** infraestrutura passou em 12 gates. Leitura de
canary foi tentada por Codex Web. Controle inicial `read-only` foi recusado por
ausência de rede no contexto confiável. Segundo teste herdou permissões já
escolhidas pelo operador (`inherit`, `danger-full-access`, `on-request`), sem
alterar configuração, mas automação 6.1.17 falhou localizando seletor de
raciocínio na página ChatGPT (`locator.click` timeout). Não retornou canary;
arquivo ficou igual, sem fallback para API. Sessão local e conector ativo não
homologam execução de ferramenta. Última release consultada ainda é 6.1.17.
Não editar bundle verificado, forjar contexto ou ampliar permissões para
transformar essa falha em sucesso.

Próximo passo indispensável: resolver compatibilidade de seleção de modelo/
raciocínio no upstream por versão auditada e repetir uma leitura real antes de
declarar acesso funcional às ferramentas. Mudança de idioma/layout da página
não foi aplicada à conta como tentativa de contorno. Este incremento entrega
padrões/cores/conexão, mas não encerra homologação de execução do host.

Evidência privada: `~/.cache/phasezero-dev/codex-web-policy/`, especialmente
`final-tests.log`, `final-ui-tests.log`, `ui-proof.json`, `host-tools-before.json`,
`host-tool-proof/{receipt,profile-receipt}.json`, `host-applied.json`,
`installed-source.json`, `installed-tools-status.json`, `installed-ui.json`.
Fonte exportada é regenerável com `git archive e53cd0cd`, sem segundo checkout.
Aprendizado durável registra limites da prova; nenhum transcript privado vai ao Git.

CI de entrada `bb0afd7e` teve `shell-test` falhando em hot-backup SQLite do
Homelab (REV-002), observado antes deste incremento; logs preservados. Não foi
reproduzido em main nesta sessão nem alterado fora da frente. PR permanece
draft; merge/release dependem dos gates pendentes e da prova de ferramentas.

### Codex Web principal: início discreto e recuperação automática — 2026-11-07

Código revisável `5d6948136ad56357fce46deb77aeaad212ad675d`, branch
`codex/codex-web-background`, sobre `396347cffa4013fd2b1feafe933906e9b15e0989`
(`codex/accounts-key-manager`, PR #134). Equivalente local da correção nova:
`027bb086`, na branch compartilhada `codex/agent-launchers`. O incremento
inclui o adaptador de composer que já existia localmente, necessário à página
atual; não publica alterações alheias de estabilidade, memória, AGENTS ou touch.

Pessoa/tarefa/aceite: conta principal acessa **Codex Web Principal** pelo menu
ou área de trabalho; login da sessão prepara o backend sem abrir janela nem
notificação de sucesso. Primeiro onboarding e falhas continuam visíveis pelo
fluxo upstream. Não há troca automática de conta/modelo nem fallback pago.

Owner continua `linux/ai/chatgpt_web_bridge.py`. Launcher usa `--hidden`,
`Restart=on-failure`, espera de 5 s e limite de cinco partidas em 300 s. O próprio
unit executa preparo antes de cada partida e restaura o helper de composer após
iniciar. Helper usa snapshot estável, ordem sem bloqueio e reaproveita unit em
encerramento. `systemctl is-active` retorna código 3 durante `activating`;
esse estado agora permite agendar o helper pelo `ExecStartPost`.

Falha real descoberta na injeção: Chromium deixava o túnel no scope anterior;
`/proc/PID/exe` podia negar leitura ao próprio usuário. Runtime recusava nova
partida e restaurava a rota nativa do perfil dedicado. Identificação agora
confere UID, executável ou argv com binário e diretório de perfil exatos,
cgroup e marcas de início estáveis. Preparo encerra somente scopes órfãos
desse perfil. Não sinaliza apps de outras contas nem enfraquece sandbox.
Três tentativas intermediárias falharam; recibos preservados. Após correção,
SIGKILL apenas do launcher próprio recuperou serviço, túnel, composer e rota
automaticamente em **11,13 s**, com zero túneis órfãos.

Diagnóstico de conector ignora abas vazias/com origem nula e tenta outra aba
do próprio ChatGPT dentro do prazo global. Ausência temporária não vira logout.
Agrupador `linux/ui/menu.py` preserva owner `codex-profiles`/`chatgpt-web`;
antes trocava por `true`, tornando o atalho principal inconsistente. Metadado
do menu reparado após comparar Exec/nome/ícone com cópia da área de trabalho,
com backup pelo owner existente.

Host BigLinux/Manjaro KDE Wayland, launcher **6.1.17**, Codex **0.167.0**:

- Conta da página autenticada comparada à principal por identidade derivada;
  igualdade confirmada, sem exportar identidade ou credenciais. Configuração e
  auth da instalação nativa, e auth do Codex Web, mantiveram hashes.
- Aprovação automática encontrada ligada e desligada pela API nativa do app.
  Sandbox e aprovações do perfil continuam herdados da escolha existente.
- Turno real `chatgpt-web/light` respondeu PONG. Primeiro canary de ferramentas
  recebeu 429; após recuperação, `chatgpt-web/medium` leu arquivo próprio e
  gravou cópia idêntica em sandbox `workspace-write` com rede, sem API paga.
  Prova é existência/conteúdo do arquivo, não apenas texto do modelo.
- 163 regressões de bridge/perfis/cartão, 31 de menus e 13 de coesão de
  instalação passaram. Painel Codex também passou na rodada anterior.
  Temporários por usuário em disco; wrapper `doctor --profile ui` pronto.
- Instalador oficial por usuário aplicado de export Git imutável do SHA de
  código acima. Versão nominal **1.22.17**, sem tag/release nova. Dois módulos
  instalados conferidos byte a byte; snapshot estável e opt-in de início no
  login atualizados pelo gerenciador instalado. Wrapper real de login retornou
  `ready=true`, sem janela do launcher no KWin. Atalho real da área de trabalho
  abriu Codex Desktop visível no perfil dedicado; comando do menu é idêntico.

Evidências privadas: `~/.cache/phasezero-dev/codex-web-resilience/` e
`~/.local/share/phasezero/chatgpt-web/smoke/tools-proof-20261107/`.
Fontes exportadas temporariamente removidas após instalar; pacote upstream não
foi modificado nem baixado novamente. Estado de teste e recibos ficam privados.

Publicação: incremento separado da base de contas, sem merge/release. CI deve
ser consultado no SHA publicado. Próximo login físico, reboot, Windows e
durabilidade de sessão perante revogação/limites externos não foram homologados.
Catálogo de práticas retornou `practices-not-configured`; memória do projeto e
memorial local usados. Fetch foi destravado preservando em recuperação privada
uma referência automática de checkpoint Codex comprovadamente vazia; branches,
commits e demais referências intactos. Caminho de recuperação:
`~/.local/share/project-recovery/PhaseZero/git-empty-checkpoint-20261107/`.

### Codex Web: reconexões no modelo selecionado e monitor do perfil — 2026-11-07

Código instalado/revisável `949cfc24bf427eac1d9a925d733606c66a804fa5`, mesma
branch `codex/codex-web-background` e [PR #135](https://github.com/Misael-art/phase-zero/pull/135).
Equivalentes locais `d362401f` e `2466b054` em `codex/agent-launchers`.
AGENTS, handoff de host limpo, touch e commits das outras frentes preservados.
Sem merge, tag ou release; versão nominal continua 1.22.17.

**Causa reproduzida:** o modelo realmente selecionado pela janela era
`chatgpt-web/gpt-6-sol`, esforço High. O verificador do launcher 6.1.17 não
reconhecia os rótulos portugueses `6 Alta` e `6 Alta, 3 de 5.`. Retornava
`model_version_unavailable` antes de enviar a mensagem; Codex repetia a conexão
cinco vezes. Os smokes anteriores com aliases light/medium não cobriam essa
seleção e não homologavam o caminho da janela. Agora o smoke testa o modelo
selecionado, recusando modelo nativo nesse perfil em vez de substituí-lo.

Owner continua o adaptador DOM existente em `linux/ai/chatgpt_web_bridge.py`.
Compatibilidade traduz somente rótulos conhecidos do controle real, preserva
família, rádio/slider selecionados e idioma da conta. Sem editar AppImage,
runtime verificado, conta, modelo, idioma global, sandbox ou aprovações.
Remover essa tradução quando o verificador upstream suportar esses rótulos e
o modelo exato passar sem ela. A tela roxa é o tema da conta, não uma falha.

**Cota distinta:** `account/rateLimits/read` do app-server oficial confirmou
limite atingido no Codex nativo. O aviso nativo é real;
não mede a cota do ChatGPT Web. Enquanto o aviso continuava visível, o mesmo
modelo Web respondeu e usou ferramentas. Não houve reset de limites, troca de
conta nem fallback pago. Contrato oficial:
[app-server](https://learn.chatgpt.com/docs/app-server).

`linux/ai/chatgpt_web_health.py` integra diagnóstico e recuperação ao bridge,
CLI `pz repair codex-web` e cartão privado IA & Dev. Uma trava por perfil
serializa manutenção manual e monitor. Opt-in explícito instalado no host:
`pz-chatgpt-web-launcher-health.timer`, a cada 60 s com dispersão; serviço
oneshot com prazo 90 s, prioridade reduzida e memória limitada a 256 MiB.
Estado privado no diretório já existente do perfil; nenhuma carteira nova.
Limite de três ações em dez minutos, orçamento persistido antes da mutação e
espera crescente. Desligar produto, rota, início no login ou launcher
manualmente revoga o monitor; pausa do monitor preserva sessão e janela.

| Situação | Política integrada | Evidência |
| --- | --- | --- |
| Composer ausente ou seletor localizado | Reaplicar helper; mesma falha de modelo só uma vez até novo turno | Modelo exato antes falhou/depois respondeu; helper parado recuperado pelo serviço real |
| Launcher cai; túnel fica em scope antigo | systemd reinicia; preparo limpa somente órfão comprovado do perfil | SIGKILL próprio após instalar: recuperado em 18,72 s, GUI preservada, zero órfãos |
| Metadado de PID reutilizado | Preparo confere alias/binário/perfil/UID/start ticks sob trava upstream; nunca sinaliza PID reutilizado | Regressões para PID igual, reutilizado, ambíguo, lock ocupado, GUI ociosa, ExecStartPre/MainPID zero e launcher vivo |
| Daemon parado ou túnel local quebrado | Reiniciar backend comprovadamente próprio e ocioso; verificar retorno | Falha de backend real; fixture cobre porta/túnel, dono desconhecido e timeout |
| Rota dedicada perdida | Restaurar pelo owner e conferir; manter configuração nativa | Injeção real recuperada pelo timer, hashes nativos iguais |
| Atalho/entrada de login gerenciados ausentes | Restaurar só cópia com origem comprovada; respeitar remoção intencional | Regressões de atalho, owner legado, symlink e arquivo alheio |
| Tarefa ativa, manutenção concorrente, pressão de recursos | Aguardar; não reiniciar backend | Matriz de regressões e trava real compartilhada |
| 429, cota, rede ou indisponibilidade externa | Registrar estado e aguardar; não repetir mensagem; falha local posterior continua reparável | 429 real anterior; política atual em fixtures, sem derrubar rede do host |
| Login, conector ou chave vencidos | Ação oficial do operador; aviso limitado por estado | Diagnóstico real de sessão/conector; expiração/revogação simuladas, sem revogar conta real |
| Integridade/política/isolamento conflitantes; falhas repetidas | Preservar configuração, bloquear mutação ou abrir disjuntor; diagnóstico acessível | Fixtures de pacote alterado, dono incerto, budget/timeout/cooldown; sem download automático |

Validação no host BigLinux/KDE Wayland, Codex 0.167.0 e launcher 6.1.17:

- Modelo exato High respondeu PONG, turno do app-server completou sem erros e
  resposta foi renderizada na janela roxa real. Teste de ferramentas leu canary
  e gravou cópia byte a byte. Entrada enviada pelo app-server oficial; digitação
  física não foi automatizada: ferramenta de entrada rejeitou ydotool local.
- Queda controlada do backend próprio recuperou launcher, composer, túnel e
  rota; GUI continuou aberta, auth/config nativos iguais e nenhum novo turno
  gerado. Timer saudável entre ciclos; ciclo normal observou cerca de 31 MiB.
  Smoke instalado após a recuperação respondeu PONG no modelo selecionado;
  diagnóstico profundo final: ready, integridade/túnel/conector verificados,
  timer active/waiting e último serviço success.
- 244 regressões do artefato revisado passaram: 242 sem metadados Git + dois
  contratos Git consultados separadamente com índice da revisão. Na primeira
  exportação, dois testes exigiam Git ausente; tentativa de dar contexto Git à
  suite inteira interferiu nas fixtures de `git init`. A referência temporária
  `core.worktree` foi removida após conferir valor exato; árvore, índice normal
  e HEAD preservados. Não aplicar GIT_DIR/GIT_WORK_TREE à suite inteira.
- O teste novo do comando `repair codex-web --help` protege dependências do
  artefato: exportação inicial omitira `import sys` da variante revisável do
  manager. Corrigido antes da publicação; instalador oficial final retornou 0.
- Cartão Qt renderizado a 510 e 1000 px; ações de diagnóstico/ativação/pausa e
  distinção de cotas visíveis. Nome do teste encurtado após encontrar corte.
- Instalador por usuário aplicado de export Git imutável. Quatro módulos
  instalados coincidem com SHA acima; snapshot atualizado pelo comando
  instalado. Backup anterior em
  `~/.local/share/phasezero/backups/1.22.17.20261107192329.198048`.

Evidências privadas: `~/.cache/phasezero-dev/codex-web-autorepair/`, incluindo
`saved-model/`, `saved-model-fixed/`, `gui-rpc/`, `gui-response.png`,
`high-tools/receipt.json`, `monitor-helper-proof.json`, `monitor-route-proof.json`
e `current-backend-crash-proof.json`. Sem chats ou credenciais no Git.

CI da base `92a295ff`: uma execução python-test passou; outra falhou somente
em `test_supervisor_sigterm_closes_its_runtime_port` do DeepSeek Harness
(1 falhou/1806 passaram), demais checks executados passaram. Não alterar esse
teste externo para liberar o lote. Conferir CI do novo SHA ao publicar.
Windows, novo login/reboot físico, leitor de tela/toque e durabilidade perante
revogação/cotas futuras seguem gates próprios. Catálogo de práticas sem revisão
assinada; memória escopada e memorial local usados. Não prometer recuperação de
limites impostos pelo provedor nem reparo de configurações de dono desconhecido.

### Créditos API da assinatura OpenAI e padrão OpenCode — 2026-11-07

Código revisável `3a5a9c21501035540e109d9b833a4fdee46beae4`, branch
`codex/openai-api-credits`, sobre `664718e9` de `codex/codex-web-background`
(PR #135, dependente de #134). Equivalente local `bc49c710` na raiz canônica.
Não confundir implementação com ativação do benefício ou consumo homologado.

Fonte consultada: [créditos API para assinantes](https://developers.openai.com/api/docs/guides/chatgpt-api-credits).
Benefício exige Pro/Business elegível, ativação e organização vinculada;
Plus não está incluído. Concessão inicial pode ser proporcional e vence no
ciclo. Crédito pertence à organização, não à chave. OpenAI usa promocionais
antes dos comprados; esse benefício não amplia cota do Codex autenticado e não
cobre Codex via chave API. Não presumir saldo a partir do preço do plano.

Owner financeiro continua `CredentialVault`: metadados API por organização,
chaves vinculadas à mesma observação, moeda, origem, ativação, total/saldo e
vencimento. Registro v1 permanece legível; primeira cota grava schema v2 com
backup central antes da migração. Segredos continuam no cofre nativo;
metadados Windows mantêm envelope DPAPI. Não há nova carteira ou banco.
UI da carteira oferece Registrar cota da API e, para OpenAI, Configurar uso no
app. Informações manuais ficam marcadas `user_reported`; não viram consulta
oficial, contador automático ou saldo atual. Renovação exige nova observação.
Valor desconhecido é distinto de zero e de crédito vencido.

`linux/ai/opencode_api.py` implementa seleção explícita da chave, organização,
projeto e modelo, com consentimento de consumo API. Antes de alterar padrão,
confere runtime, lê carteira e consulta `/v1/models` com chave selecionada e
headers da organização/projeto. Consulta autenticação/modelos, não saldo.
Modelo Codex é recusado nesse fluxo. Configuração usa provedor próprio
`phasezero-openai-api`, modelo padrão e política que limita caminho normal de
provedores; credencial persistida é somente placeholder sem acesso.

Plugin local `linux/ai/assets/opencode-openai-api/` intercepta cada requisição
HTTP desse provedor. Resolve chave por pipe interno do helper Python isolado,
reconfere registro/grant/cota e fixa Authorization/organização/projeto. Aceita
apenas endpoints HTTPS autorizados e modelo selecionado; rejeita redirects e
WebSocket. Nenhuma chave em argv, configuração OpenCode ou log do adaptador.
Revogação/remoção bloqueia próxima requisição; requisição já autorizada pode
estar em andamento. Revogar mantém provedor bloqueado, sem escolher outra
conta. `disable-openai` restaura backup somente com hashes correspondentes;
edições posteriores do usuário são preservadas. Guards 9Router permanecem.

Contrato de extensão é experimental e ainda precisa de prova no OpenCode real.
Referências: [plugins server](https://opencode.ai/docs/build/plugins/server),
[políticas](https://opencode.ai/docs/policies/) e
[configuração](https://opencode.ai/docs/config/). Mínimo 2.2.6 é guarda adotada
pelo adaptador, não homologação de qualquer versão superior. CLI/desktop devem
estar alinhados. Políticas gerenciadas e código de outros plugins permanecem
fora da prova das fixtures; não afirmar fechamento geral de PXA-008.

**Bloqueios reais reobservados após reinício:** carteira sem chave OpenAI;
chave existente no armazenamento nativo do OpenCode recusada com HTTP 401 /
`invalid_api_key`; CLI instalada 2.0.12. Concessão, organização beneficiada e
saldo não observados. Tentativa controlada de configurar foi recusada e
configuração do OpenCode permaneceu byte a byte igual. Nenhuma inferência API,
compra, recarga, upgrade de plano ou ativação de benefício foi executada.
Navegador Chrome autenticado não estava acessível pelo conector. Foi solicitado
ao operador ativar benefício oficial e cadastrar chave da organização no cofre;
não pedir segredo no chat nem reaproveitar cookies de outra aplicação.

Retomada após crash/reboot informado pelo operador: causa não estabelecida.
Consulta limitada ao kernel anterior não encontrou OOM/pânico; pstore exigiu
permissão e não foi lido. Não usar ausência desses registros como diagnóstico.
Testes retomados em scopes próprios e sequenciais, CPUQuota 75% de um núcleo,
MemoryMax 512 MiB, MemorySwapMax zero, Nice 10 e IOWeight 10. Amostragem a cada
dois segundos interrompe somente scope próprio se MemAvailable <4 GiB,
PSI full memória >=2%, full I/O >=8%, CPU some >=35% ou prazo >180 s.
Não houve encerramento de processos alheios, reset de rede ou teste de carga.

Validação do artefato Git: **113 passaram, seis jornadas antigas de escala
deselecionadas**; mínimo disponível do lote 6043 MiB, sem gatilho de pressão.
Lotes anteriores separados: 82 core e 30 UI; uma regressão adicional cobre
formulários com texto dobrado. Render Qt dos dois formulários em 100/200% de
fonte: rolagem vertical, ações acessíveis, sem rolagem horizontal após correção.
Não equivale a escala física, leitor de tela, conta/consumo ou SDK OpenCode real.
Gitleaks do commit passou; `bash -n linux/pz` e diff sem whitespace inválido.
Práticas assinadas indisponíveis (`practices-not-configured`); memorial local e
memória escopada usados. AGENTS, handoff de host limpo e reparo de touch alheios
permanecem fora do incremento.

Evidência privada em `~/.cache/phasezero-dev/openai-api-credits/`: recibos dos
scopes, render dos formulários e `live-readonly-receipt.json`. Driver de
limitação é temporário dessa validação, não outro monitor residente do host.
Próximos gates: runtime CLI/desktop compatível, SDK carregado no cliente real,
concessão e chave válidas da organização, configuração pelo fluxo guiado e
turno API controlado com observação do faturamento. Não declarar padrão API
ativo neste host antes dessas provas; não comprar créditos para contornar gate.
