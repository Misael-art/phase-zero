# PhaseZero Linux — Imersão UX e plano de melhorias

Base: branch `fix/deck-controller-session-binding` @ `a2c3d20`, `version.json` 1.20.9.
Worktree sujo (não tocado): `linux/windows-vm/provision.sh`, `tests/test_provision.sh` modificados; `.mimosa/`, `uber-defesa-privada/` não rastreados.
Recorte: todo o Linux (Central nativa PySide6, CLI `pz`, fallbacks TUI/web, seletor de boot). Windows (`bootstrap-*.ps1`) fora.
Método: somente análise estática + `pz --help` + script Python lendo `build_catalog()` (sem I/O no host). A UI não foi aberta, os testes não foram executados e nada foi alterado.

IDs usam o prefixo **LUX-** para não colidir com UX-001..011 de `rev-remediation-v1.md`.

---

## 1. Resumo executivo

A Central já recebeu muito trabalho de honestidade: CCS-000..042 estão `verified` e UX-001..004 foram corrigidos em 70d959f. Esse trabalho foi focado em cada página. Os riscos que sobram estão na camada comum, que toda página usa (runner, preview, severidade, diálogos, tema). Por isso, cada defeito ali se repete nas 574 ações do catálogo.

Principais riscos:
1. **O preview não mostra o que vai mudar.** Das 395 ações mutáveis, 159 usam `status`/`detect` como prévia. Mesmo assim o diálogo afirma "Preview concluído" e oferece "Confirmar e aplicar". Isso inclui ações de alto risco que reiniciam o host.
2. **Esc mata a operação em andamento sem confirmação.** Vale para a janela principal e para o diálogo de progresso: o processo recebe SIGTERM e, 2 s depois, KILL, inclusive no meio de uma instalação de pacotes.
3. **A severidade pode mostrar falha como "concluída com avisos".**

Três prioridades: **F0** (preview honesto, cancelamento seguro, severidade) → **F1** (contraste do tema claro, Visão geral coerente, diálogos que cabem no Deck, UI sem congelar) → **F2** (escala, tema/movimento, consistência entre CLI, TUI e UI).

---

## 2. Escopo e método

| Examinado a fundo | Examinado superficialmente | Não examinado |
|---|---|---|
| `main_window.py`, `command_runner.py`, `result_parser.py`, `widgets.py` (Preview/Progress/Result/StatefulDialog), `pages/dashboard.py`, `pages/overview.py`, `pages/profiles.py`, `health_models.py`, `operation_ledger.py`, `tokens.py`, `theme.qss`, `a11y.py`, `app.py`, `preferences.py`, `boot_selector.py`, `linux/ui/tui.sh`, `linux/pz` (help), catálogo inteiro via `build_catalog` | `provision_player.py`, `linux/ui/server.py`, `pages/tuning.py`, `test_accessibility_gate.py`, lista de testes | Conteúdo das páginas windows_vm, homelab, steamdeck, emulation, ai_*, themes e linux_hub. Essas áreas já têm roadmaps próprios. Scripts shell de backend (`linux/server`, `steamdeck`, `windows-vm`) |

Roadmaps lidos: `control-center-surfaces-v1.md`, `rev-remediation-v1.md`, `themes-accessibility-v1.md` (cabeçalho). Os commits CCS/REV/UX citados (174a233, 70d959f, aa5a5bd, f7746de) foram conferidos como ancestrais de HEAD.

---

## 3. Mapa da aplicação

- **Entradas:** `pz ui` / `pz ui native` → `linux/ui_native/app.py` (PySide6/Qt6, Fusion + QSS com tokens). `pz ui tui` (whiptail), `pz ui web|server` (fallback gerado de `actions.json`, ADR CCS-034). `app.py --boot-selector` abre o seletor pré-reboot.
- **Catálogo:** `catalog.py::build_catalog` tem 574 ações (395 mutáveis). São 25 `primary`, 381 `standard` e 168 `advanced`, em 17 categorias.
- **Navegação:** a sidebar tem 6 grupos e 19 destinos (`catalog.py:37-44`), mais busca global (Ctrl+F) e Ctrl+1..9.
- **Pipeline de ação:** `request_action` → (ParameterDialog) → `runner.start(preview=mutable)` → `PreviewDialog` → `runner.start(preview=False)` → `ProgressDialog` → `ResultDialog` + toast → `page.reload()`. O ledger (`operation_ledger.py`) registra tudo, e os resultados ficam em `state_dir/results`.
- **Testes relevantes:** `test_accessibility_gate.py` (contraste, nomes, overflow a 150/200% por página), `test_native_dialogs.py`, `test_native_navigation.py`, `test_start_by_goal.py`, `test_operation_ledger.py`, mais os testes por página.

---

## 4. Achados

Legenda de evidência: **E** = estática (código e linha), **C** = cálculo reproduzível, **R** = reprodução executada.

### P0

**LUX-001 · O preview de 159 ações mutáveis é um status, mas o diálogo diz "preview"** · Área: todas as ações mutáveis · Jornada: confirmar uma mudança
- Evidência (C+E): o script sobre `build_catalog` encontrou 236 ações com plano, 135 com status como prévia e 24 com "outro" (por exemplo `steamdeck detect`, `windows-vm discover`). Casos de alto risco: `waydroid.boot.next-reboot` ("REINICIA o host", prévia `waydroid boot status`, `catalog.py:377`), `boot.efi` (`boot status`, `:546`), `ai.secrets.rotate` (`ai status`, `:943`), `system.deps.install` (`deps status --json`, `:165-168`), `windows.guest-login.password`, `windows.provision.discard`, `ai.omo.uninstall`, `ai.codexbar.plasmoid-remove`. Em `PreviewDialog`, o texto padrão é "Preview concluído. Nenhuma mutação foi executada." (`widgets.py:1438`) e o botão é "Confirmar e aplicar" (`:1511`).
- Problema: a pessoa confirma sem ver o que vai mudar. A tela sugere que houve um plano.
- Causa (fato): `ActionSpec.preview_args` não diz de que tipo é a prévia.
- Recomendação: criar `preview_kind: "plan" | "state"` no `ActionSpec`, inferido quando a prévia contém `dry-run|plan|preview` e declarado nos demais casos. Para `state`, o diálogo mostra "Estado atual (isto não é um plano)" e um bloco fixo "O que vai acontecer", vindo de um novo campo `impact` (texto do catálogo). Para `risk == "high"`, exigir `preview_kind == "plan"` ou `impact` preenchido, com lint no teste.
- Aceite: nenhuma ação com prévia `state` mostra a palavra "Preview concluído". Todas as ações `high` exibem o impacto antes do campo CONFIRMAR. Um teste de catálogo falha se uma ação `high` não tiver `plan` nem `impact`.
- Dependências/riscos: é preciso escrever o texto de impacto de cerca de 11 ações `high` e 148 outras. O ideal é criar subcomandos `plan` no backend aos poucos. Confiança: alta.

**LUX-002 · Esc e fechar o diálogo de progresso cancelam a operação sem confirmação** · Área: operações longas
- Evidência (E): Esc chama `cancel_or_clear`, que chama `runner.cancel()` (`main_window.py:389-391, 880-883`). `ProgressDialog.reject()` (Esc ou X) emite `cancel_requested` (`widgets.py:1604-1609`). `cancel()` faz SIGTERM no grupo de processos e KILL após 2 s (`command_runner.py:151-164`). Nenhum teste cobre Esc (grep por `Key_Escape`/`cancel_or_clear` em `tests/` não retorna nada).
- Problema: quem aperta Esc para limpar a busca, ou fecha a janela de progresso para "ver a Central", aborta pacman, provisionamento ou escrita em disco pela metade.
- Recomendação: Esc no diálogo de progresso passa a minimizar (`hide()`), e o toast global continua visível. Esc na janela principal só limpa a busca. Os botões Cancelar pedem confirmação ("Parar agora pode deixar <título> incompleto. Parar mesmo assim?", com o padrão em "Continuar"). Adicionar ao catálogo o campo `cancel_safe` (padrão falso quando `elevated`).
- Aceite: um teste pytest com Esc durante um runner falso deixa o processo vivo. Um clique em Cancelar exige uma segunda confirmação. O fechamento da janela principal mantém o diálogo que já existe (`main_window.py:915-925`).
- Confiança: alta.

**LUX-003 · A classificação de severidade pode transformar falha em "concluída com avisos"** · Área: resultado de qualquer ação
- Evidência (E): com `exit != 0`, `severity_for` retorna `warning` quando `is_pending_report` é verdadeiro (`result_parser.py:106-108`). `is_pending_report` aceita **qualquer** `state` textual diferente de `"error"` (por exemplo `"failed"`) ou qualquer `nextAction` (`:62-66`). O inverso também acontece: `status == "requiresrestart"` com `exit 0` vira "Falhou" (`:115`). O `PreviewDialog` habilita "Confirmar" para payload pendente (`widgets.py:1434`).
- Problema: um envelope `{"state":"failed","nextAction":"..."}` com `exit 1` aparece em âmbar como "concluída com avisos". E uma instalação que só precisa de reinício aparece como falha.
- Causa: inferência. A lista de envelopes reais que o backend emite com `state` não foi auditada.
- Recomendação: usar uma lista explícita de estados "pendentes" (`needs-*`, `degraded`, `resumable`). Tratar `failed|error|blocked` como erro sempre. Mapear `requiresrestart` para um estado próprio, "Reinício necessário" (cor de aviso, ação "Reiniciar depois").
- Aceite: tabela de testes com `exit×state×mutable` e, no mínimo, os casos `state=failed exit=1` → error e `requiresrestart exit=0` → warning com o texto "Reinício necessário".
- Confiança: média (defeito lógico confirmado; ocorrência real não medida).

### P1

**LUX-010 · Tema claro: o item ativo da sidebar fica ilegível** · Área: navegação
- Evidência (C): `#sidebarButton:checked` e `:hover` usam `on_accent` (#fff) (`theme.qss:79-88`). No LIGHT, a razão é 1,21:1 sobre `surface_selected` e 1,15:1 sobre `surface_alt`. Os rótulos de seção (`text_muted` sobre `surface_inset`, 10 px) ficam em 3,31 (dark) e 2,79 (light). Texto desabilitado (`text_muted`) fica em 2,67 no dark. O gate `CONTRAST_PAIRS` (`a11y.py`) não contém esses pares.
- Recomendação: criar os tokens `sidebar_active_text` (usar `text_strong` no light) e `section_label` ≥ 4,5, e incluir sidebar, seções e desabilitado em `CONTRAST_PAIRS`.
- Aceite: `test_accessibility_gate.py` cobre os novos pares nos dois temas, todos ≥ 4,5 (texto) ou 3,0 (UI).

**LUX-011 · Visão geral conta INFO como aviso e mostra ✓ antes de medir** · Jornada: primeiro diagnóstico
- Evidência (E): `warnings = sum(status in {"WARN","INFO"})` (`overview.py:180`), enquanto `needs_attention` exclui INFO (`health_models.py:64`). Resultado: o topo diz "Sistema funcionando com avisos" e os grupos dizem "Tudo certo". Isso contradiz a intenção de CCS-016 (subsistemas não optados = INFO). O ícone começa como "✓" durante "Verificando…" (`:72`). Na falha aparecem dois botões de repetir (`:86` e `:274`) e o texto "abra o histórico técnico" sem link (`:273`).
- Recomendação: INFO vira uma métrica separada, "Informativos", que não altera o título. O ícone de loading fica neutro ("…"). Na falha, um único botão de repetir, mais "Abrir Resultados".
- Aceite: um pytest com só PASS+INFO resulta no título "Tudo certo". Um estado de carregamento sem "✓".

**LUX-012 · Diálogos maiores que a tela lógica do Steam Deck com escala** · Jornada: confirmar/ver resultado no Deck
- Evidência (C+E): `StatefulDialog.setMinimumSize(760, 540)` (`widgets.py:1388`) vale para Preview e Progress. Outros mínimos: `ImageManagerDialog` 780×540, `ProvisionPlayer` 720×460, `BootSelector` 560×560, `WindowsInstallDialog` 620 px. O Deck (1280×800) a 150% dá 853×533 lógicos, e a 200% dá 640×400. O rodapé com "Confirmar e aplicar" fica abaixo da borda. O gate de overflow (`test_accessibility_gate.py`) mede páginas, não diálogos.
- Causa: inferência visual. Não foi renderizado.
- Recomendação: tamanho mínimo derivado de `screen().availableGeometry()`, corpo em `QScrollArea` e rodapé de ações sempre fora do scroll.
- Aceite: um teste offscreen com `QT_SCALE_FACTOR=1.5/2` e tela virtual de 1280×800 mostra, para cada diálogo, o retângulo inteiro do botão primário dentro da tela.

**LUX-013 · O Início no primeiro uso tem 18 CTAs, com duplicatas e uma promessa falsa** · Jornada: primeiro acesso
- Evidência (E): `dashboard.py` exibe "Comece por aqui" (2 passos, embora o comentário e o roadmap CCS-041 falem em 3), 6 objetivos, 4 ações rápidas e 6 ferramentas. "Preparar este computador" (`profile.safe-base`) aparece no passo 2 e no objetivo 1. O doctor aparece no passo 1 e nas ações rápidas. O card "Jogos, Android e VM" executa apenas `profile.gaming` (`:60-64`).
- Recomendação: no primeiro uso, esconder "Ações rápidas/Ferramentas" (mostrar depois do primeiro sucesso), remover a duplicata do objetivo 1 e renomear o card para "Jogos e emulação" (Android e VM já têm objetivos ou páginas próprias). Continua dentro de UX-006/REV-015, que estão pendentes em `rev-remediation-v1.md`.
- Aceite: um pytest confirma que nenhum `action.id` aparece duas vezes no Início, com no máximo 8 CTAs no primeiro uso.

**LUX-014 · "Retomar" mostra previews e leituras como a "última tarefa"** · Jornada: voltar ao app
- Evidência (E): `OperationLedger.begin` grava toda execução, com `preview` e `mutable` (`operation_ledger.py:53-80`). `DashboardPage` pega `records(limit=1)` sem filtro (`dashboard.py:~91`). Um `status` de 1 segundo passa a ser "Última tarefa concluída". "Retomar" só navega para a categoria. Uma tarefa que falhou mostra "Retomar", não "Ver erro"/"Tentar de novo".
- Recomendação: filtrar `mutable and not preview`. Para uma tarefa que falhou, mostrar "Ver o que falhou" (abre o ResultDialog pelo `resultPath`) e "Tentar de novo".
- Aceite: um ledger com [status ok, install failed] exibe o card de falha do install.

**LUX-015 · A UI congela em chamadas síncronas, e o seletor de boot quebra no timeout** · Jornada: instalar Windows, escolher o próximo boot
- Evidência (E): `_graphics_status` faz `subprocess.run(... timeout=20)` na thread da UI ao clicar em instalar Windows (`main_window.py:454-471`). `BootSelector.run_choice` faz `subprocess.run(timeout=120)` com pkexec na thread da UI, sem capturar `TimeoutExpired`/`OSError` (`boot_selector.py:160-168`). A mensagem de falha sempre menciona "entrada do Windows" (`:178-181`), mesmo para SteamOS ou Waydroid.
- Recomendação: usar `QProcess` assíncrono com um estado "Medindo gráficos…"/"Aguardando autorização…", capturar as exceções e escrever mensagens por escolha.
- Aceite: um pytest com stub lento mantém o event loop respondendo. O timeout mostra uma falha tratada. A mensagem cita a escolha feita.

**LUX-016 · Atalhos e nomes da navegação não batem** · Área: sidebar
- Evidência (E): Ctrl+1..9 usam `CATEGORIES[:9]` (`main_window.py:392-396`), então Ctrl+1 abre Visão geral, o Início fica sem atalho, a ordem difere da sidebar e nenhum tooltip mostra o atalho. O grupo "IA & Dev" contém a categoria "IA & Dev". "Servidor" ("LLM local, homelab e Hermes") e "Homelab" se sobrepõem, assim como "Linux"/"Recursos"/"Ajustes"/"Aplicativos".
- Recomendação (sem criar categoria nova, anti-escopo do CCS): atalhos na ordem visual, com Início = Ctrl+1 e o atalho nos tooltips; renomear o grupo para "Desenvolvimento"; reescrever as descrições para marcar a fronteira (Servidor = serviços deste PC; Homelab = gerenciar a stack e outros hosts). A fusão fica como pergunta aberta.
- Aceite: um pytest confirma que o atalho N abre o N-ésimo botão visível da sidebar.

**LUX-017 · A TUI executa ações privilegiadas sem confirmar e esconde falhas** · Superfície: `pz ui tui`
- Evidência (E): `tui.sh:123-137` roda `plugins.sh install-decky-privileged`, `apply-*` etc. direto, sem prévia. `pz_tui_show_output` faz `"$@" ... || true` e mostra a saída sem o código de saída (`:65`). A TUI não passa pelo catálogo nem pelo ledger. A dica `sudo pacman -S whiptail` está errada: no Arch o pacote é `libnewt` (`:266`).
- Recomendação: gerar os menus a partir de `actions.json`, como a web faz (ADR CCS-034): prévia primeiro, `--yesno` com o impacto, linha final "✔ concluído / ✖ falhou (código N)". Alternativa: marcar a TUI como legada e deixar só leitura.
- Aceite: um teste de drift entre TUI e `actions.json`, e nenhuma ação `elevated` sem `--yesno`.

**LUX-018 · A ajuda do `pz` contradiz o produto** · Superfície: CLI
- Evidência (R: `pz --help`): "Install Ctrl+Alt+F1..F6 shortcuts" (`linux/pz:24`), enquanto o real é Meta+Shift+F1–F8 (`install-hotkeys.sh:40-64`, `catalog.py:246`). A ajuda mistura EN e PT (`themes` em PT, o resto em EN).
- Aceite: um teste grep contra a ajuda. Decidir o idioma da ajuda (sugestão: PT-BR, como o README).

### P2

**LUX-020 · Escala e tipografia fixas** · A sidebar some abaixo de 1100 px lógicos (`main_window.py:533`), então o Deck a ≥ 117% vive no menu hambúrguer. O QSS usa px fixos (`text_xs=10`, `text_sm=11`, `tokens.py:160-161`), o que ignora a fonte do sistema e o recurso de texto maior da página Temas (inferência; verificar `access.*` em `themes/catalog.py`). Recomendação: derivar a escala tipográfica de `QApplication.font().pointSizeF()` e reduzir o limiar da sidebar ou usar trilho só com ícones. Aceite: a 150% num Deck, a sidebar aparece em modo ícone e o texto base fica ≥ 12 px efetivos.

**LUX-021 · O tema não persiste e o movimento não é reduzido** · `app.py:41` sempre abre no escuro. `toggle_theme` não grava nada (`preferences.py` só guarda o modo avançado) e ignora o esquema de cor do Plasma. O shimmer (`widgets.py:1063`) ignora `access.reduce-motion`. Aceite: preferência `interface/theme` = system|dark|light; shimmer desligado quando o movimento reduzido está ativo.

**LUX-022 · Progresso falso e erros crus** · Qualquer "NN%" no stdout vira progresso (`command_runner.py:200-207`; "disco 95% usado" vira 95%). O timeout é global, de 30 min, igual para status e instalação (`:59`). Mensagens em inglês chegam ao usuário ("operation timed out after", `:229`; "provision start timed out", "status poll failed Nx", `provision_player.py:247+`). Recomendação: progresso só a partir de uma linha estruturada (`PZ_PROGRESS=NN`), timeout por ação no catálogo e mensagens em PT com causa e ação (reusar `journey.failure_cause`).

**LUX-023 · O PreviewDialog não explica bloqueio** · Em erro ou com `blockers`, o texto ainda diz "Preview concluído…" (`widgets.py:1439`) e o Confirmar aparece desabilitado sem motivo visível (`:1515`). Aceite: estado de erro com título "Não é seguro aplicar agora" e a lista de `blockers`.

**LUX-024 · Perfis sem comparação** · O combo tem mínimo de 400 px (`profiles.py:45`, overflow em telas estreitas), a ordem é alfabética e não há "o que instala / espaço / tempo". Recomendação: cards de perfil com um recomendado destacado, reusando o plano `pz install <p> --dry-run`.

**LUX-025 · O gate de a11y não cobre diálogos, estados nem atalhos** · Lacuna de teste transversal (ver LUX-010/012/016). Estender `test_accessibility_gate.py` para `PreviewDialog`, `ResultDialog`, `ProgressDialog`, `WindowsInstallDialog`, `BootSelectorWindow`, com foco inicial e ordem de Tab.

### P3

- **LUX-030** O nome acessível do ícone de estado usa o id em inglês ("Estado: success", `widgets.py:1393`). Traduzir.
- **LUX-031** A ação "Copiar saída" do PreviewDialog copia um conteúdo escondido no modo simples. Renomear para "Copiar detalhes técnicos".
- **LUX-032** Os emojis nos títulos ("👋", `dashboard.py:108-110`) são lidos por leitores de tela. Mover para um `QLabel` decorativo sem nome acessível.

---

## 5. Jornadas

**Confirmar uma mudança (todas as páginas).** Hoje: clique → prévia (às vezes só status) → "Preview concluído" → Confirmar → progresso (Esc mata) → resultado (a severidade pode mentir). Proposta: clique → **O que vai mudar** (plano ou impacto declarado, bloqueios em destaque) → Confirmar (CONFIRMAR digitado se `high`) → progresso (Esc minimiza; Cancelar pede confirmação e avisa o risco) → resultado com um estado canônico (Concluído / Reinício necessário / Pendente de você / Falhou) e uma ação seguinte.

**Primeiro acesso.** Hoje: 4 blocos e 18 CTAs; o doctor diz "com avisos" num host limpo. Proposta: título → 2 passos (Diagnosticar → Preparar) → objetivos (sem duplicata) → o resto só depois do primeiro sucesso. Na Visão geral, INFO não assusta.

**Voltar ao app.** Proposta: o card mostra a última tarefa *mutável* com ação coerente com o estado (ver erro / tentar de novo / abrir destino).

**Deck a 150%.** Proposta: sidebar só com ícones, diálogos rolam e rodapé de ações sempre visível.

---

## 6. Plano faseado

### F0 — Nunca aplicar sem saber, nunca abortar sem querer (P0)
Resolve LUX-003, LUX-002 e LUX-001, nesta ordem, cada um num PR próprio.

| Passo | Escopo | Arquivos | Aceite / testes | Est. |
|---|---|---|---|---|
| F0.1 LUX-003 | Tabela de estados canônica e "Reinício necessário" | `result_parser.py`, `widgets.py` (ResultDialog/PreviewDialog), `main_window.py` (toast) | Ampliar `test_native_dialogs.py` com tabela paramétrica exit×state×mutable | S |
| F0.2 LUX-002 | Esc minimiza; cancelar com confirmação; `cancel_safe` | `main_window.py:383-396,880`, `widgets.py:1533-1610`, `models.py`, `catalog.py` | Novo `test_cancel_safety.py` com runner falso (processo vivo após Esc; 2 cliques para cancelar) | S |
| F0.3 LUX-001 | `preview_kind` + `impact`; texto do diálogo por tipo; lint `high` | `models.py`, `catalog.py`, `widgets.py:1424-1531`, `linux/ui/generate_actions.py` + `actions.json` (regenerar, drift test CCS-034) | `test_catalog_visibility.py`: `high` ⇒ plan ou impact; pytest do diálogo `state` sem "Preview concluído" | M (texto de impacto de ~11 ações `high` + padrão por categoria para as 148 restantes) |

Fora de escopo: criar `plan` real no backend para cada ação. Isso vira backlog incremental, começando por `waydroid.boot.next-reboot`, `boot.efi` e `ai.secrets.rotate`.
Risco: a mudança de severidade altera a cor de resultados existentes. Revisar `is_pending_report` junto com `homelab`/`ai proxies` (cujos envelopes usam `state`) e rodar `test_homelab_player.py` e `test_ai_session_ui.py`.

### F1 — Jornadas principais legíveis e sem travar (P1)
Ordem: LUX-010 → LUX-011 → LUX-012 → LUX-015 → LUX-013/014 → LUX-016 → LUX-018 → LUX-017.

| Item | Arquivos | Aceite | Est. |
|---|---|---|---|
| LUX-010 | `tokens.py`, `theme.qss`, `a11y.py` | novos pares ≥ piso nos dois temas | XS |
| LUX-011 | `pages/overview.py` | PASS+INFO ⇒ "Tudo certo"; loading neutro | XS |
| LUX-012 | `widgets.py::StatefulDialog`, dialogs listados | teste offscreen 150/200% com o botão primário inteiro visível | M |
| LUX-015 | `main_window.py:454`, `boot_selector.py:150-185` | event loop vivo com stub lento; timeout tratado; texto por escolha | S |
| LUX-013/014 | `pages/dashboard.py`, `operation_ledger.py` (filtro) | sem id duplicado; ≤ 8 CTAs; card de falha correto | S |
| LUX-016 | `main_window.py:392`, `catalog.py` (descrições/grupo) | atalho N = N-ésimo botão | XS |
| LUX-018 | `linux/pz` help | grep de hotkeys; idioma decidido | XS |
| LUX-017 | `linux/ui/tui.sh` (gerar de `actions.json`) ou marcar legado | teste de drift; `yesno` em `elevated` | M |

Dependências: LUX-012 e o teste de diálogos de LUX-025 andam juntos. LUX-013 conversa com UX-006/REV-015 (pendentes); registrar neste roadmap, sem duplicar ID.

### F2 — Escala, acessibilidade e consistência (P2)
LUX-020, 021, 022, 023, 024, 025. Arquivos: `tokens.py`, `theme.qss`, `app.py`, `preferences.py`, `main_window.py:531`, `command_runner.py`, `provision_player.py`, `pages/profiles.py`, `test_accessibility_gate.py`.
Aceite: gate de a11y cobrindo diálogos e sidebar em modo ícone a 150%; tema persistido; progresso só estruturado; mensagens de timeout em PT com ação. Est.: M no total (LUX-020 é o maior; os demais são XS/S).
Risco: mexer na escala tipográfica pode reabrir overflow (UX-003/004). Rodar os testes de geometria de Homelab e Windows VM.

### F3 — Refinos (P3)
LUX-030..032. XS cada.

---

## 7. Lacunas e perguntas abertas

- **Não verificado ao vivo:** nada foi renderizado. LUX-012 e LUX-020 são inferências geométricas. Verificação segura sugerida: `python -m linux.ui_native.app --smoke-test --screenshot out.png` com `QT_QPA_PLATFORM=offscreen QT_SCALE_FACTOR=1.5`, mais capturas dos diálogos (exige um harness de teste, já que os diálogos não abrem no smoke).
- **Testes não executados:** `conftest.py` só isola o HOME para quem usa a fixture, e a UI grava em `state_dir`. A regra do mandato era não alterar o host. Rodar em container ou VM descartável.
- **Físico:** Deck OLED/LCD a 150/200%, toque na sidebar e nos diálogos, leitor de tela (Orca) sobre a Central e teclado Steam. Continua UX-011 (sessões com leigos) do roadmap REV.
- **Perguntas:**
  1. Fundir "Servidor" e "Homelab", e "Recursos" e "Ajustes"? O CCS proíbe nova categoria, mas não fusão.
  2. A TUI deve continuar sendo uma superfície de escrita ou virar só leitura?
  3. Idioma oficial da ajuda do `pz`?
  4. Quais envelopes reais emitem `state` com `exit != 0`? (Confirma o alcance de LUX-003.)
- **Não coberto nesta rodada:** conteúdo das páginas Windows VM, Homelab, Steam Deck, Emulação, IA e Temas (já têm roadmaps próprios); `linux/ui/server.py` a fundo; mudanças não commitadas em `provision.sh`.

---

## 8. Apêndice — consultados

Código: `linux/ui_native/{main_window,command_runner,result_parser,widgets,catalog,models,operation_ledger,health_models,tokens,a11y,app,preferences,boot_selector,provision_player}.py`, `theme.qss`, `pages/{dashboard,overview,profiles,tuning}.py`, `linux/ui/{tui.sh,server.py}`, `linux/pz`, `linux/steamdeck/install-hotkeys.sh`.
Testes: `tests/test_accessibility_gate.py`, `tests/conftest.py`, inventário de `tests/*.py`/`*.sh`.
Docs: `docs/roadmaps/control-center-surfaces-v1.md`, `rev-remediation-v1.md`, `themes-accessibility-v1.md`, `CLAUDE.md`.
Comandos (somente leitura): `git log/status`, `pz --help`, script Python de classificação do catálogo, cálculo de contraste com `a11y.contrast_ratio`.
