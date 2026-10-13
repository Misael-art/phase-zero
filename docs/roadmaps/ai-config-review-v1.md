# Roadmap canônico — Revisão de configurações de IA v1 (AICR)

> Direcionamento operacional único para um agente revisar **todas as funções
> relativas às configurações de IA** do PhaseZero: frescor (nada ultrapassado),
> funcionalidade completa (tudo funciona), lacunas (o que acrescentar/melhorar)
> e experiência do usuário no pilar **IA & Dev**.
>
> Este documento coordena a revisão. Não prova conclusão. Comandos, saídas,
> testes e o documento de auditoria produzido são as provas.

## Metadados

| Campo | Valor |
|---|---|
| Status | **done** 2026-09-24 — ver `docs/audit/ai-config-review-2026-09-24.md` e `docs/roadmaps/ai-stack-remediation-v1.md` |
| Criado | 2026-09-23, America/Sao_Paulo |
| Base observada | `fix/deck-controller-session-binding` em `a2c3d20` (`version.json` 1.20.9) |
| Escopo | Linux: CLI `linux/pz ai *` e `pz server llm/hermes`, backends `linux/ai/*` e `linux/server/ai-policy-broker.sh`, UI nativa (`pages/ai_dev.py`, `ai_proxies.py`, `ai_routing.py`), catálogo `ai.*`, templates `linux/ai/templates/*`, manifestos `assets/ai/*`, segredos `secrets/schema.json`, testes, docs de contrato |
| Escopo secundário | Paridade de contrato com Windows (`Setup-AITools.ps1`, `bootstrap-tools.ps1`, Pester `ai-*.tests.ps1`): só contratos (portas, `webValidation`, manifesto de proxies), não revisão completa do lado Windows |
| Fora de escopo | Perfis Homelab e LLM-server (roadmap próprio); WinVM; itens com dono no roadmap `linux-ux-v1.md` (LUX-*) — registrar sobreposição citando o ID, não duplicar; implementação de correções (esta é uma revisão; correções viram roadmap próprio) |
| IDs | `AICR-xxx`. Nunca reutilizar. Não confundir com `LUX-*`, `UX-0xx`, `REV-*`, `CCS-*`, `PZ-AUD-*` |

Dados acima são snapshot. Todo agente revalida antes de começar.

## Missão

Responder, com evidência por superfície:

1. **Frescor**: alguma função/config ficou ultrapassada? Versões pinadas,
   manifestos, docs e help deslocados do comportamento real, upstream
   descontinuado, código morto.
2. **Funcionalidade**: tudo está completamente funcional? Suítes verdes,
   contratos respeitados (exit 0/2/3, envelope JSON, redação de segredos),
   catálogo coerente com o CLI.
3. **Lacunas**: o que acrescentar ou melhorar? Cobertura ausente, paridade
   Windows↔Linux, inconsistência entre gerenciadores.
4. **UX IA & Dev**: como a experiência do usuário no pilar pode melhorar?
   Jornadas, estados honestos, mensagens acionáveis, acessibilidade.

## Ordem das fontes de verdade

1. Estado vivo do repositório, CI e host (comandos abaixo).
2. Este roadmap.
3. Contratos documentados: `docs/ai-tools.md`, `docs/linux-ai-proxies.md`,
   `docs/ai-routing-workspace.md` (o comportamento que viola contrato é defeito;
   contrato deslocado da realidade também é achado — dimensão Frescor).
4. Auditoria prévia `docs/audit/2026-08-24-ai-ux-backend-diagnosis.md`
   (contexto; não re-relatar como novo o que lá foi corrigido — verificar
   regressão desses itens).
5. Código e schemas.

Antes de iniciar (obrigatório, AGENTS.md): buscar em `ai-memory` por soluções
prévias (`ai-memory search` com palavras-chave do problema). Ao concluir,
registrar aprendizados duráveis via `ai-memory write-page` com frontmatter
`tier: semantic`. Se `ai-memory`/`rtk` estiverem ausentes: registrar
"`ai-memory missing`"/"`rtk missing`" e continuar (modo degradado).

## Regras permanentes (agente deve obedecer)

1. **Revisão é leitura + prova, não mutação**. No checkout do operador só rodam
   comandos de leitura e suítes de teste com fixtures. `pz ai doctor`,
   `doctor`/`repair` de qualquer família, `install`, `ensure`, `login`,
   `sync`, `apply`, `setup`, `update` **mutam o host e ficam proibidos** nesta
   revisão, exceto `--dry-run`/`plan`.
2. **Probes vivos**: o operador pré-autorizou em 2026-09-23 a **validação viva
   do stack de API** (allowlist fechada na fase F1: `pz ai proxies test`,
   start de serviço já instalado, health do 9Router/OmniRoute). Fora da
   allowlist — `verify --live` de clientes, chat via 9Router, `ensure`,
   `login` de navegador — continua exigindo aceite explícito, um por um.
   Cada probe vivo entra no ledger com data, alvo e motivo.
3. **Sem mutar host nos testes**: `QT_QPA_PLATFORM=offscreen`, HOME/XDG em tmp
   (fixture `conftest.py`), `PZ_USE_SUDO=0`. Sandbox HOME: **um `export` por
   variável** (regra AGENTS.md — incidente 2026-08-24 com `9router.env`).
   Antes de comando destrutivo em sandbox, ecoar os caminhos que ele toca.
4. **Não trabalhar no checkout principal** para qualquer edição de código ou
   docs de produto: `git worktree add ../pz-ai-review -b codex/ai-config-review-v1 origin/main`.
   O checkout do operador tem mudanças não commitadas.
5. **Antes de editar**, reler o trecho citado; se a linha mudou, localizar por
   símbolo (`grep -n`), nunca por número.
6. **Achado = linha na matriz** com `arquivo:linha`, comando executado e saída
   (trecho). Sem evidência, não é achado; é hipótese (marcar `unverified`).
7. **Classificação dupla obrigatória**: dimensão
   (`freshness|functional|gap|ux`) × severidade (`P0` bloqueia uso/segurança,
   `P1` quebra jornada, `P2` degrada, `P3` polimento).
8. **Redação**: nenhuma saída com chave, token, cookie ou nome de conta entra
   em documento commitado; usar forma redigida já produzida pelos backends.
9. **Copy de usuário em PT-BR**; identificadores em inglês.
10. **Não misturar**: revisão não corrige código de produto. Correções (inclusive
    docs de contrato deslocados) viram proposta de roadmap ao final (formato em
    "Saída"). Exceção: correção de teste quebrado pela própria revisão.
11. Falha pré-existente conhecida:
    `test_status_contract.py::test_status_command_always_reports[emulation.dualscreen.status]`
    (ver rev-remediation). Registrar, não usar como aceite, não "consertar" por
    acidente.

### Comandos de verificação

```bash
export QT_QPA_PLATFORM=offscreen
python -m pytest tests -q -x                      # suíte Python
python -m pytest tests/test_claude_code_manager.py tests/test_opencode_9router_manager.py \
  tests/test_routing_manager.py tests/test_ai_session_ui.py -q
bash tests/linux-ai.sh
bash tests/linux-ai-proxies.sh
bash tests/linux-9router.sh
bash tests/linux-ai-claude.sh
bash tests/linux-ai-init.sh
bash tests/linux-ai-backup.sh
bash tests/linux-ai-codexbar.sh
bash tests/linux-ai-desktop.sh
bash tests/linux-ai-status-hermes.sh
bash tests/linux-opencode-align.sh
bash tests/linux-agent-workspaces.sh
bash tests/linux-admin-bridge.sh
bash tests/linux-qwen-desktop.sh
python linux/ui/generate_actions.py linux/ui/actions.json && git diff --exit-code linux/ui/actions.json
shellcheck linux/pz linux/ai/*.sh linux/server/ai-policy-broker.sh
```

Suítes Windows (Pester `ai-tools.tests.ps1`, `ai-proxy-suite.tests.ps1`,
`bootstrap-ai-config.tests.ps1`, `bootstrap-mcp-repair.tests.ps1`,
`bootstrap-agent-skills.tests.ps1`, `bootstrap-mimocode.tests.ps1`): rodar só
se `pwsh`/Pester disponível; caso contrário, revisão estática de paridade.

Probes de leitura permitidos no host do operador (capturar saída como evidência,
com segredos já redigidos pelos próprios backends):

```bash
linux/pz ai status
linux/pz ai auth status
linux/pz ai 9router status
linux/pz ai 9router provider status
linux/pz ai omniroute status
linux/pz ai opencode status
linux/pz ai opencode version-status
linux/pz ai claude status
linux/pz ai hermes status
linux/pz ai routing status
linux/pz ai proxies status
linux/pz ai proxies detailed-status
linux/pz ai workspaces doctor
linux/pz ai compat status
linux/pz ai token-economy status
linux/pz ai codexbar status
linux/pz ai menu --help
```

## Superfície sob revisão (mapa de partida)

Revalidar por símbolo; linhas deslocam. Toda família abaixo precisa de
veredito nas quatro dimensões ou `N/A` justificado.

### CLI e dispatch

- Entrada: `linux/pz` — `cmd_ai` (~L557), dispatch `ai)` (~L1029), help
  (~L154–236); `cmd_server` (~L520–556) para `server llm`/`server hermes`/
  `homelab policy`; dispatch `ai setup <tool>` (~L700–743).

### Roteadores e proxies

- `linux/ai/9router-manager.sh` (986 l) + `9router-server-runner.js`: install,
  health, dashboard, repair, provider, combo, usage, watchdog; units
  `phasezero-9router*.service`; env `~/.config/phasezero/ai-proxies/9router.env`.
- `linux/ai/proxy-suite.sh` (2264 l): catálogo (4 suportados: kimi/qwen/deeps/
  mimo; 6 legados bloqueados), loopback patch, procedência fail-closed, login
  por navegador, `ensure`, IDEs (OpenCode/Continue/ZCode).
- `linux/ai/omniroute-manager.sh` (838 l): roteador paralelo, porta dinâmica
  20128+.
- Manifestos: `assets/ai/proxy-manifest.json`,
  `assets/ai/proxy-suite-trusted-sources.json`.

### Clientes e workspaces

- Claude Code + Bonsai: `linux/ai/claude_code_manager.py` (1834 l) +
  wrapper `setup-claude-code.sh`; launchers por processo, rollback byte a byte.
- OpenCode: `linux/ai/setup-opencode.sh` (674 l) +
  `opencode_9router_manager.py` (576 l); lockstep CLI↔desktop, hook pacman.
- Codex CLI: `linux/ai/setup-codex.sh` (pin `@openai/codex@0.66.0`).
- Hermes: `setup-hermes.sh` (680 l, gate `assets/ai/hermes-distribution-audit.json`),
  `hermes-router.sh` (456 l), `9router-hermes-provider.sh` (480 l).
- Odysseus: `odysseus-manager.sh` (803 l, podman, allowlist).
- OMO: `setup-omo.sh`. OpenClaw: `setup-openclaw.sh`. Desktop apps:
  `desktop-apps.sh` (857 l). Ollama: `setup-ollama.sh`; Open WebUI:
  `setup-open-webui.sh`.
- Roteamento por tarefa: `routing_manager.py` (1549 l) — combos
  `phasezero-code/analysis/plan`, plan/apply/rollback/verify.

### Runtime de agente e Dev

- `setup-agent-compat.sh` (924 l): RTK, Caveman, Headroom, ai-memory,
  frugality, `init` em projetos arbitrários; `headroom-agent.sh`.
- `setup-admin-bridge.sh` (phasezero-admin/bigsudo). `setup-ides.sh`.
- `mcp-manager.sh` (824 l): 8 clientes MCP. `setup-memory.sh` (ai-memory
  loopback :49374). `setup-usagebar.sh`. `setup-codexbar.sh` (849 l, CLI +
  plasmoid). `linux/ui_native/operation_ledger.py` (`ai operations`).
- `rotate-secrets.sh` + `secrets/schema.json`; `auth-registry.sh`;
  `backup-manager.sh`; `server/ai-policy-broker.sh` (`pz ai policy`).

### UI nativa (pilar IA & Dev)

- `linux/ui_native/pages/ai_dev.py` ("IA & Dev": cards de agentes e ferramentas),
  `ai_proxies.py` (gateways, ciclo de vida, MiMo token, polling), 
  `ai_routing.py` (tarefas, políticas, editor de fallbacks, rollback).
- `linux/ui_native/proxy_models.py`; ~60 ações `ai.*` em `catalog.py`
  (grupos ~L574–599, 930–993); dispatch em `main_window.py` (~L630–633,
  809–813); TUI `linux/ai/menu.sh`.

### Docs de contrato

- `docs/ai-tools.md`, `docs/linux-ai-proxies.md`, `docs/ai-routing-workspace.md`,
  `docs/adr/0002-ai-portability-backup.md`, `docs/codexbar-pendencies.md`,
  `docs/superpowers/plans/2026-05-11-ai-tools-cli-ui-hardening.md`.

## Matriz de evidência

Cada fase termina com veredito por superfície na tabela de saída. Gates são
cumulativos.

### Fase F0 — Frescor (o que envelheceu)

| Checagem | Como |
|---|---|
| Versões pinadas vs upstream | `setup-codex.sh` (codex 0.66.0), `hermes-distribution-audit.json`, runtime Node 24 isolado, `qwen2.5-coder:1.5b` (llm-server), snapshots dos proxies, release RTK, ai-memory (1.31.1), CodexBar/KodexBar, OMO (exige OpenCode ≥ 1.4). Consultar metadata upstream via web (`npm view`, GitHub releases API, docs oficiais). **Nunca instalar**. Marcar `current` / `stale` / `unknown` |
| Upstream descontinuado | Exemplo conhecido: OAuth gratuito Qwen encerrado 2026-04-15 (nota em `docs/ai-tools.md`). Procurar notas de deprecação equivalentes nas outras ferramentas e nos links de "Fontes oficiais" |
| Docs drift | Cada comando documentado em `ai-tools.md` / `linux-ai-proxies.md` / `ai-routing-workspace.md` existe e aceita as flags documentadas (`--help`, dry-run); cada subcomando implementado aparece na doc e no help do `pz ai`. Ambas direções |
| Código morto/legado | 6 proxies legados sem snapshot (só catálogo), funções duplicadas entre `cmd_ai` inline e backends, subcomandos sem caller no catálogo/`menu.sh` |
| Janelas temporais | Datas citadas em docs/comments (ex.: "descontinuado em", "revisado em") já passaram ou viraram incorretas |

Gate F0: toda família do mapa com veredito `current/stale/unknown` + evidência
(fonte upstream + arquivo local). Stale P1+ listado na proposta de roadmap.

### Fase F1 — Funcionalidade (tudo funciona)

| Checagem | Como |
|---|---|
| Suítes | Comandos de verificação acima. Falha pré-existente = registrada, não corrigida |
| Contrato de resultado | Exit `0/2/3` documentado (`ai-tools.md` §Resultados estruturados) respeitado por um comando mutável de cada família em `--dry-run`/`plan`; envelope `summary`/`next` presente |
| Redação | Saídas JSON dos probes permitidos não vazam chave/token/conta (inspecionar `status`, `detailed-status`, `auth status`, `9router status`) |
| Catálogo ↔ CLI | Toda ação `ai.*` em `catalog.py` despacha para comando existente com flags existentes; todo subcomando mutável relevante tem ação ou é intencionalmente só-CLI (documentar) |
| `actions.json` | Regenerar sem drift |
| Shellcheck | Limpo em `linux/pz` + `linux/ai/*.sh` + policy broker |
| Consistência transacional | Famílias que prometem rollback (claude, opencode, routing, 9router, odysseus) têm manifesto + recusa de drift; apontar quem falta |
| Regressões da auditoria 2026-08-24 | Reexecutar os cenários-chave corrigidos lá (sucesso aparente após falha de serviço; Mimo sem credencial; políticas de roteamento únicas; falha de IDE degradando estado) |

#### Validação viva do stack de API (pré-autorizada pelo operador)

O operador já usa os proxies; a revisão precisa provar que **respondem de
verdade**, não só que estão instalados. Escada por proxy suportado
(`kimiproxy`, `qwenproxy`, `deepsproxy`, `mimo-ai-proxy`) + gateways:

1. `linux/pz ai proxies status` / `detailed-status` — leitura, sempre.
2. Serviço instalado mas inativo ⇒ **permitido subir** o que já existe:
   `systemctl --user start phasezero-<id>.service` (reversível, sem rede além
   do próprio proxy). Se nem instalado está: registrar `not-installed` e
   parar — instalação segue proibida.
3. `linux/pz ai proxies test <id>` — probe real e restrito ao alvo
   (`/v1/models` + chat). Pré-autorizado para os 4 suportados. Custo: uma
   chamada de chat por proxy.
4. Gateways: `linux/pz ai 9router status` / `provider status` /
   `linux/pz ai omniroute status` — leitura. Teste real de provider via
   9Router ("somente sob demanda" por contrato) **não** faz parte da
   pré-autorização; se o operador quiser, autoriza na hora.
5. Autenticação: julgar só pelo `auth` redigido. Proxy sem sessão/credencial
   ⇒ veredito `blocked-needs-login`; o agente **nunca** abre fluxo de login,
   nunca pede e nunca manipula chaves/cookies — o próprio operador faz login
   se quiser destravar.

Proibido mesmo nesta validação: `install`, `ensure`, `login`, `restart` com
reinstalação, atualização de snapshot, `apply`/`sync` de combo, escrita em
`~/.config/phasezero/ai-proxies/*`.

Saída obrigatória: tabela de veredito por proxy + gateway na auditoria:

| Alvo | serviço | sessão/cred | `/v1/models` | chat real | latência | veredito |
|---|---|---|---|---|---|---|

`chat real` registra apenas `ok/falha + código`, nunca conteúdo do prompt ou
resposta. Latência = duração do probe.

Gate F1: suítes verdes (ou falhas pré-existentes registradas por nome);
contratos e redação verificados por amostragem de cada família; **tabela de
validação viva completa (4 proxies + 9Router + OmniRoute)**; zero regressão
dos itens da auditoria prévia.

### Fase F2 — Lacunas (o que acrescentar/melhorar)

Prompts de investigação (cada resposta vira linha `gap` com severidade):

- Paridade Windows↔Linux: catálogo de ferramentas dos dois lados
  (`bootstrap-tools.ps1` vs `pz ai setup`), portas, `webValidation`,
  manifesto de proxies — o que existe só de um lado e deveria existir dos dois?
- Cobertura de ciclo: toda ferramenta instalável tem `status` +
  verificação + rollback/remoção? (ex.: usagebar, ollama, open-webui, omo)
- Backup: `ai backup` cobre ai-memory e credenciais; cobre
  `~/.config/phasezero/9router/settings.json`, envs dos proxies, state de
  routing?
- Updates: `pz updates check` inventaria todas as ferramentas IA que instala?
  (desktop apps, codexbar, omo, openclaw, omniroute)
- Policy broker: novos instaladores/caminhos cobertos, ou bypass possível?
- Segredos: `secrets/schema.json` cobre todos os providers realmente usados
  (BYOK minimax/nex/zhipu-glm manuais)?
- Consistência entre gerenciadores: nomes de estado (`ready/degraded/blocked`),
  manifestos, units systemd seguem o mesmo padrão? Onde divergem?
- Erros: mensagens acionáveis (`nextAction`) em todas as famílias ou só em
  algumas?

Gate F2: lista priorizada P0–P3; P0/P1 justificados com jornada afetada.

### Fase F3 — UX do pilar IA & Dev

Avaliar as três páginas + TUI `menu.sh` + primeira execução, do ponto de vista
de quem quer usar IA hoje:

- **Jornada zero→primeiro chat**: do `first_use` da Central até uma resposta
  real de modelo, quantos passos, cliques e recargas? Onde trava sem orientação?
- **Resposta às 4 perguntas do usuário em 10s**: o que está instalado e
  saudável? o que falta? qual o próximo passo? quanto custa (quota/roteamento)?
- **Estados honestos**: severidade não pinta falha como aviso; operação
  interrompida é recuperável pelo ledger; progresso não congela (regras
  LUX-003/002/001 valem aqui — citar sobreposição, não redefinir).
- **Mensagens**: copy PT-BR acionável; erro técnico cru só em modo avançado;
  link/atalho para o comando CLI equivalente em cada card.
- **Latência de status**: sondas paralelas (já reduzido 6,7s→4,6s em
  2026-08-24); medir de novo e comparar.
- **Acessibilidade**: contraste dos tokens usados nas três páginas em tema
  claro/escuro; navegação por teclado; 150%/200% (regras LUX-012).
- **Coerência de naming**: sidebar "IA & Dev" vs renome para "Desenvolvimento"
  (LUX-016) vs título hero `ai_dev.py` — o pilar precisa de nome único.
- **Modo simples vs avançado**: o essencial (um provedor respondendo) aparece
  sem ruído; o exotismo (omniroute, combos, frugality) fica no avançado?

Gate F3: achados de UX mapeados a jornada + severidade; sobreposições LUX
citadas por ID.

## Saída (formato de handoff)

1. **Auditoria**: `docs/audit/ai-config-review-2026-09-<dia>.md` contendo:
   - tabela de achados: `ID | severidade | dimensão | superfície (arquivo:linha) | evidência (comando + trecho de saída) | recomendação`;
   - tabela de vereditos F0 (família × current/stale/unknown);
   - tabela de validação viva do stack de API (F1: 4 proxies + 9Router +
     OmniRoute, com latência);
   - ledger de execução: comandos rodados, ambiente (host, data, branch/SHA),
     probes vivos aceitos, ferramentas ausentes (`rtk missing` etc.);
   - regressões verificadas da auditoria 2026-08-24.
2. **Proposta de correção**: `docs/roadmaps/ai-<tema>-v1.md` no formato da casa
   (metadados, regras, matriz de evidência, gates), contendo só P0/P1 como
   itens implementáveis; P2/P3 como lista de backlog no fim. Nenhum ID novo
   colide com famílias existentes.
3. **Learnings**: páginas `ai-memory` para cada descoberta durável; regra
   permanente nova vai no `AGENTS.md` (preservar CRLF), não em memória.
4. Revisão não edita código de produto; docs de contrato deslocados entram na
   proposta como itens de correção.

## Gate final

Auditoria commitada com todas as famílias do mapa cobertas (veredito ou `N/A`
justificado), proposta de roadmap para todo P0/P1, suítes no mesmo estado ou
melhor que o encontrado, zero mutação de host não aceita no ledger.
