# Roadmap canônico — Linux UX v1 (LUX)

> Fonte operacional única para implementar os achados da imersão UX Linux de
> 2026-09-22 (`docs/audit/linux-ux-immersion-2026-09-22.md`).
>
> Este documento coordena implementação. Não prova conclusão. Commits, testes,
> CI e validação no host são as provas.

## Metadados

| Campo | Valor |
|---|---|
| Status | **F0–F3 implementadas** em `codex/linux-ux-v1` (ver matriz); validação física pendente do operador |
| Criado | 2026-09-22, America/Sao_Paulo |
| Base observada | `fix/deck-controller-session-binding` em `a2c3d20` (`version.json` 1.20.9) |
| Escopo | Linux: Central nativa (`linux/ui_native`), CLI `linux/pz`, fallbacks `linux/ui/{tui.sh,server.py}`, seletor de boot |
| Fora de escopo | Windows (`bootstrap-*.ps1`); conteúdo de páginas com roadmap próprio (WinVM, Homelab, Temas) salvo onde indicado |
| IDs | `LUX-xxx`. Nunca reutilizar. Não confundir com `UX-0xx` de `rev-remediation-v1.md` |

Dados acima são snapshot. Todo agente revalida antes de começar.

## Missão

Nenhuma ação aplica sem a pessoa saber o que muda; nenhuma operação é
abortada sem querer; nenhum resultado mente sobre sucesso. Depois: jornadas
principais legíveis no Deck a 150%/200%, tema claro e teclado.

## Ordem das fontes de verdade

1. Estado vivo do repositório, CI e host.
2. Este roadmap.
3. `control-center-surfaces-v1.md` (invariantes CCS continuam valendo).
4. `rev-remediation-v1.md` (UX-006/011, REV-014/015 relacionados).
5. Código e schemas.
6. Relatório de imersão (contexto; linhas citadas podem ter deslocado).

## Regras permanentes (agente deve obedecer)

1. **Worktree dedicado**: `git worktree add ../pz-linux-ux -b codex/linux-ux-v1 origin/main`. Nunca trabalhar no checkout principal (tem mudanças do operador não commitadas).
2. **Um ID por commit**, mensagem `fix(ui): LUX-00N <resumo>`. Sem `git add -A`; adicionar arquivos nominalmente.
3. **Sem mutar host**: nada de `pz install`, `boot`, `homelab up`, reboot, GRUB, pacman real. Testes rodam `QT_QPA_PLATFORM=offscreen`, com HOME/XDG em tmp (fixture `conftest.py`) e `PZ_USE_SUDO=0`.
4. **Antes de editar**, reler o trecho citado; se a linha mudou, localizar por símbolo (`grep -n`), não por número.
5. **Teste primeiro**: escrever o teste que falha pelo defeito, ver falhar, corrigir, ver passar. Registrar ambos no ledger.
6. **Não criar categoria de sidebar** (anti-escopo CCS). Renomear/descrever é permitido.
7. **`actions.json` é gerado**: após mudar `catalog.py`/`models.py`, rodar `python linux/ui/generate_actions.py` e commitar junto; o drift test (CCS-034) deve passar.
8. **Copy de usuário em PT-BR**; identificadores em inglês.
9. Estados: `pending` → `in_progress` → `verified` (só com teste comportamental verde + SHA) ou `deferred` (com razão).
10. Gate de cada fase = suíte completa verde (comando abaixo), não só o teste novo.

### Comandos de verificação

```bash
export QT_QPA_PLATFORM=offscreen
python -m pytest tests -q -x                      # suíte Python
bash tests/runner.sh                              # suítes shell (se existir runner p/ as tocadas)
bash tests/linux-ui.sh && bash tests/linux-menus.sh
python linux/ui/generate_actions.py && git diff --exit-code linux/ui/actions.json
```

Falha pré-existente conhecida: `test_status_contract.py::test_status_command_always_reports[emulation.dualscreen.status]` (ver rev-remediation). Registrar, não usar como aceite, não "consertar" por acidente.

## Decisões fixadas (defaults até o operador mudar)

| Pergunta | Default adotado |
|---|---|
| Fundir Servidor/Homelab, Recursos/Ajustes? | **Não fundir** nesta v1. Só descrições e tooltips que delimitam. |
| TUI escreve no host? | **Só leitura** (LUX-017 opção B). Ações mutáveis saem da TUI com mensagem "use `pz ui`". |
| Idioma do `pz --help`? | **Não traduzir** nesta v1; corrigir só conteúdo errado (LUX-018). |
| `requiresrestart` | Novo estado "Reinício necessário" (cor aviso), não erro. |

## Matriz de evidência

### Fase F0 — Não aplicar sem saber, não abortar sem querer (P0)

Ordem obrigatória: LUX-003 → LUX-002 → LUX-001.

| ID | Requisito | Implementação | Teste (novo/ampliado) | Estado |
|---|---|---|---|---|
| LUX-003 | Severidade nunca pinta falha como aviso | `result_parser.py`: `is_pending_report` aceita só `state`/`status` numa allowlist explícita (`needs-*`, `needs*`, `degraded`, `warn*`, `gui-required`, `pending`, `ready`, `running`, `installing`) ou `resumable is True`; `nextAction` sozinho não basta com exit≠0. `failed|error|blocked` ⇒ `error` sempre. `requiresrestart` ⇒ novo severity `restart` (render como warning, título "Reinício necessário"). Atualizar `status_map`/`verb_map` em `main_window.py::operation_completed` e `ResultDialog.title_map` | `tests/test_result_severity.py` paramétrico: (exit1,state=failed,mut)→error; (exit1,state=needs-login)→warning; (exit1,{nextAction},mut)→error; (exit0,status=requiresrestart)→restart; (exit0,ok=false,mut)→error. Rodar `test_homelab_player.py`, `test_ai_session_ui.py`, `test_native_dialogs.py` | verified `797a882` |
| LUX-002 | Esc/fechar não cancela; cancelar pede confirmação | `main_window.py::cancel_or_clear`: só limpa busca. `ProgressDialog.reject()`: `hide()` (não emite cancel); status bar mantém operação visível + botão "Mostrar progresso". Botões "Cancelar operação" (dialog e barra) chamam `MainWindow.confirm_cancel()` → `QMessageBox` padrão "Continuar", texto "Parar agora pode deixar “{título}” incompleto."; ações `elevated` acrescentam "Pode exigir reparo." | `tests/test_cancel_safety.py`: runner com processo `sleep 30` stub; Esc na janela e no dialog ⇒ `runner.running` True; cancelar + resposta "Continuar" ⇒ vivo; resposta "Parar" ⇒ terminado. `closeEvent` inalterado | verified `459212c` |
| LUX-001 | Prévia honesta | `models.py`: `preview_kind: str = ""` e `impact: str = ""`. `catalog.py::_a`: inferir `preview_kind="plan"` se prévia contém `dry-run`, `plan`, `preview`, `--plan`; senão `"state"`. `PreviewDialog`: se `state`, título "Revisar antes de aplicar", headline "Estado atual — isto não simula a mudança.", bloco "O que vai acontecer:" com `action.impact or action.description`. Se `plan`, texto atual. Preencher `impact` para TODAS as ações `risk=="high"` (lista abaixo) | `tests/test_catalog_visibility.py`: toda ação `high` tem `preview_kind=="plan"` ou `impact` não vazio; `tests/test_native_dialogs.py`: ação `state` não contém "Preview concluído" e mostra impacto; ação `plan` inalterada. Regenerar `actions.json` | verified `bb58ed4` |

Ações `high` com prévia de estado (revalidar com script abaixo): `system.deps.install`, `windows.provision.cancel`, `windows.provision.discard`, `windows.guest-login.auto`, `windows.guest-login.password`, `waydroid.boot.next-reboot` ("Agenda o Waydroid e REINICIA o computador imediatamente; trabalho não salvo é perdido."), `boot.efi`, `ai.omo.uninstall`, `ai.secrets.rotate`, `ai.codexbar.plasmoid-remove`.

Script de revalidação (somente leitura):

```bash
python - <<'EOF'
import sys; sys.path.insert(0,'.')
from pathlib import Path
from linux.ui_native.catalog import build_catalog
for a in build_catalog(Path('.')):
    p=' '.join(a.preview_args or ())
    if a.mutable and a.risk=='high' and not any(k in p for k in ('dry-run','plan','preview')):
        print(a.id,'|',p)
EOF
```

Gate F0: três IDs `verified`; suíte verde; `actions.json` sem drift.

### Fase F1 — Jornadas principais (P1)

Ordem: 010 → 011 → 012 → 015 → 013 → 014 → 016 → 018 → 017.

| ID | Requisito | Implementação | Teste | Estado |
|---|---|---|---|---|
| LUX-010 | Sidebar legível nos dois temas | `tokens.py`: tokens `sidebar_active_text`, `sidebar_hover_text` (DARK=`on_accent`, LIGHT=`text_strong`), `section_label` (DARK e LIGHT ≥4.5 sobre `surface_inset`). `theme.qss` `#sidebarButton:hover/:checked`, `#sectionLabel`, `:disabled` usam os tokens. `a11y.py::CONTRAST_PAIRS` inclui esses pares (texto 4.5) | `test_accessibility_gate.py` falha antes (light 1.21) e passa depois | verified `b8b1ccd` |
| LUX-011 | Visão geral coerente | `pages/overview.py`: `warnings` conta só `WARN`; métrica nova "Informativos" (INFO); ícone inicial "…"; em falha, remover segundo botão de repetir e adicionar "Abrir Resultados" (`request_category("Resultados")`) | pytest: checks PASS+INFO ⇒ título "Tudo certo"; loading sem "✓"; falha com um só botão "Tentar novamente"/"Verificar novamente" | verified `b7dd35a` |
| LUX-012 | Diálogos cabem a 150/200% | `widgets.py::StatefulDialog`: remover `setMinimumSize(760,540)`; mínimo = `min(760, avail.w-32) × min(540, avail.h-32)` do `screen().availableGeometry()`; corpo dentro de `QScrollArea`, rodapé fora. Mesmo padrão em `ImageManagerDialog`, `ProvisionPlayerWindow`, `WindowsInstallDialog`, `BootSelectorWindow`, `ResultDialog` (remove 660×380 fixo) | `tests/test_dialog_fit.py`: para cada diálogo, tela virtual 853×533 e 640×400 (patch de `availableGeometry`) ⇒ botão primário com retângulo inteiro dentro da janela e janela ≤ tela | verified `c159c63` |
| LUX-015 | UI nunca congela; boot selector robusto | `main_window.py::_graphics_status` → `QProcess` assíncrono; mostrar diálogo "Medindo gráficos…" com cancel; timeout ⇒ `{}` (fallback compatível já existente). `boot_selector.py::run_choice` → `QProcess` + estado "Aguardando autorização…"; tratar timeout/erro; texto de falha por escolha (`choice.title`), só citar "Windows VM → Reparo" se `choice.key=="windows"` | pytest com stub `pz` que dorme 3s: `QApplication.processEvents` responde durante; timeout ⇒ mensagem tratada; escolha waydroid não menciona Windows | verified `3b25654 + f20f198` |
| LUX-013 | Início sem ruído | `pages/dashboard.py`: em `first_use`, não renderizar "Ações rápidas" nem "Ferramentas"; remover de `JOURNEYS` a duplicata que repete ação de `ONBOARDING_STEPS` (`profile.safe-base`); card `play` → título "Jogos e emulação"; corrigir comentário "três passos" | `tests/test_start_by_goal.py`: no first_use nenhum `action.id` repetido e ≤ 8 botões primários; card `play` não promete Android/VM | verified `e602cb7` |
| LUX-014 | Retomar = última tarefa real | `pages/dashboard.py`: buscar `records(limit=50)` e escolher o primeiro com `mutable and not preview`. Falhou/interrompido ⇒ botões "Ver o que falhou" (abre `ResultDialog` a partir de `resultPath`, se existir) e "Tentar de novo" (`request_action(by_id[actionId])`) | `tests/test_operation_ledger.py`/dashboard: ledger [status ok, install failed] ⇒ card do install com "Ver o que falhou" | verified `f2a00ee` |
| LUX-016 | Atalhos seguem a sidebar | `main_window.py::_install_shortcuts`: iterar a ordem visual de `SIDEBAR_GROUPS` (Início=Ctrl+1 … até 9); tooltip do botão inclui "(Ctrl+N)". Renomear grupo "IA & Dev" → "Desenvolvimento". Descrições: Servidor = "Serviços deste computador: LLM local, Hermes"; Homelab = "Stack home-server e outros computadores" | `tests/test_native_navigation.py`: Ctrl+N abre N-ésimo botão visível | verified `81cc0b9` |
| LUX-018 | Help do `pz` correto | `linux/pz` linha de `steamdeck hotkeys`: "Install Meta+Shift+F1..F8 shortcuts" | `tests/test_help_no_host_touch.py` (ou novo): help contém `Meta+Shift+F1..F8` e não `Ctrl+Alt+F1` | verified `55417c5` |
| LUX-017 | TUI não muta sem confirmação | Opção B (default): `linux/ui/tui.sh` mantém só itens de leitura (status, doctor, repair-plan, planos); itens mutáveis removidos e menu mostra "Para aplicar mudanças use: pz ui". `pz_tui_show_output` anexa "✔ concluído" / "✖ falhou (código N)". Dica de dependência: `sudo pacman -S libnewt` | `tests/linux-menus.sh` ou `linux-ui.sh`: grep de tui.sh sem `install`/`next-reboot`/`privileged` executáveis; saída de falha mostra código | verified `54a79b1` |

Gate F1: todos `verified`; `test_accessibility_gate.py` verde com pares novos; suíte completa verde.

### Fase F2 — Escala, acessibilidade, consistência (P2)

| ID | Requisito | Implementação | Teste | Estado |
|---|---|---|---|---|
| LUX-025 | Gate a11y cobre diálogos | Estender `test_accessibility_gate.py`: nomes acessíveis, foco inicial e ordem de Tab em Preview/Progress/Result/WindowsInstall/BootSelector | o próprio teste | verified `ab17dd2` |
| LUX-020 | Escala e sidebar compacta | Sidebar em modo ícones (48px, tooltips/nomes) entre 700–1100px lógicos em vez de sumir; hambúrguer só <700. Tipografia: `render_qss` recebe `scale = QApplication.font().pointSizeF()/10` e multiplica `text_*` (mínimo `text_xs`≥11) | pytest: janela 853×533 ⇒ sidebar visível em modo ícone; tamanhos escalam com fonte do sistema 12pt; gates de geometria Homelab/WinVM continuam verdes | verified `464fedd` |
| LUX-021 | Tema persiste; movimento reduzido | `preferences.py`: `interface/theme` ∈ system/dark/light (default system via `QStyleHints.colorScheme()`); `app.py` aplica; `toggle_theme` persiste. `start_shimmer` no-op se `PZ_REDUCE_MOTION=1` ou KDE `AnimationDurationFactor==0` (ler `kdeglobals` só leitura) | pytest: preferência persiste entre instâncias (QSettings em tmp); shimmer não cria animação com reduce-motion | verified `aab4e22` |
| LUX-022 | Progresso e timeout honestos | `command_runner.py`: progresso só de linhas `PZ_PROGRESS=NN` (manter `%` apenas se ação declara `progress="percent"`); `timeout_ms` por ação (`ActionSpec.timeout_s`, default 1800, status 120); mensagem de timeout em PT com ação sugerida. `provision_player.py`: mensagens de falha em PT via `journey.failure_cause` | pytest: stdout "disco 95% usado" não move barra; timeout de status em 120s (stub com clock patch) | verified `cbb22ea` |
| LUX-023 | Prévia bloqueada explica | `PreviewDialog`: com erro/blockers, título "Não é seguro aplicar agora", lista `blockers`, texto sob o botão desabilitado | pytest dialog | verified `edbc2c1` |
| LUX-024 | Perfis comparáveis | `pages/profiles.py`: remover `setMinimumWidth(400)`; ordenar por recomendado (`profile.safe-base` primeiro); mostrar descrição + botão "Ver o que instala" (preview existente `install <p> --dry-run`) | pytest: combo sem mínimo fixo; primeira opção = safe-base | verified `7b86c36` |

### Fase F3 — Refinos (P3)

| ID | Requisito | Implementação | Teste | Estado |
|---|---|---|---|---|
| LUX-030 | Nome acessível do estado em PT | `widgets.py::StatefulDialog` map success/warning/error/running → Concluído/Aviso/Erro/Em andamento | pytest | verified `a274743` |
| LUX-031 | Rótulo de cópia honesto | "Copiar saída" → "Copiar detalhes técnicos" | pytest | verified `bbb3006` |
| LUX-032 | Emoji fora do nome acessível | título sem emoji; emoji em QLabel decorativo com `setAccessibleName("")` | pytest a11y | verified `b54ecf7` |

## Físico / operador (não implementar às cegas)

- Deck LCD/OLED a 150%/200%: capturas de Início, Visão geral, Preview, Progress (confirma LUX-012/020).
- Orca sobre a Central; navegação só teclado e só toque.
- Sessão com leigos continua em UX-011 (rev-remediation).

## Anti-escopo

- Nova categoria na sidebar; reescrita de páginas; tema novo.
- Criar subcomandos `plan` no backend (backlog futuro; LUX-001 resolve pela UI).
- Tocar WinVM boot/QGA, Homelab compose, Temas engine.
- Traduzir o help do `pz` inteiro.

## Ledger de execução

| Data | Agente | Branch/worktree | IDs | Resultado |
|---|---|---|---|---|
| 2026-09-22 | Claude (imersão) | leitura em `a2c3d20` | — | Diagnóstico e roadmap. Zero implementação, host não mutado |
| 2026-09-22 | Claude (implementação) | `codex/linux-ux-v1`, worktree `/mnt/sdcard/Projects/pz-linux-ux`, base `origin/main` `5eedd21` | LUX-001..003, 010..018, 020..025, 030..032 | Todos `verified` por teste comportamental (cada teste novo provado falhando sem a correção). Gate F0 em `bb58ed4`: 994 passed. Gate F1 em `cbb22ea`: 1030 passed, 1 falha de timing (ver nota). Host não mutado: nenhum reboot, GRUB, pacote ou serviço; só testes offscreen com HOME/XDG em tmp e um `--smoke-test` da Central |

### Desvios do roadmap registrados

- LUX-003: allowlist virou **denylist** de estados de falha (`failed`, `timeout`, `blocked`, `unhealthy`...). Motivo: o backend emite estados em PT (`ligado`, `degradado`) e o contrato `is_pending_report({"nextAction": ...}) is True` já estava coberto por teste. `requiresrestart` sai como severidade `warning` com título "Reinício necessário" (não uma quarta severidade), para não tocar os consumidores de `severity_for`.
- LUX-001: `preview_kind` é propriedade inferida + `preview_kind_override`; impactos vivem em `HIGH_RISK_IMPACT` (catalog.py). `host.wipe` é `plan` por override. `actions.json` não mudou (o gerador não exporta os campos novos).
- LUX-014: "Ver o que falhou" abre **Resultados** (não um ResultDialog direto). Tarefa interrompida mantém "Retomar".
- LUX-017: opção B (somente leitura) aplicada; `support-bundle` continua na TUI (gera arquivo de diagnóstico, não muda o sistema).
- LUX-020: trilho de ícones 700–1100 px; o teste `test_main_window_supports_documented_narrow_viewport` foi atualizado para o novo contrato (trilho ≥700, menu <700).
- LUX-032: emoji removido do título (sem rótulo decorativo separado).
- LUX-015 teve uma correção posterior (`f20f198`): matar a medição de gráficos ao fechar a janela.

## Handoff (formato obrigatório)

```text
Objetivo da sessão:
Branch e worktree:
HEAD inicial / final:
IDs tocados e estado final:
Arquivos:
Testes (antes falhando / depois passando) e suíte completa:
Host mutado? (deve ser NÃO):
Próximo ID exatamente:
```

## Definição de concluído

LUX-001..003 e LUX-010..018 `verified`; F2/F3 `verified` ou `deferred` com
razão; suíte completa verde no SHA final; `actions.json` sem drift; itens
físicos registrados com o operador.
