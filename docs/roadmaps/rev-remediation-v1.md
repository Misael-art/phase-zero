# Roadmap canônico — Remediation REV v1 (revisão 2026-09-07)

> Fonte operacional única para a frente que corrige e certifica os achados da
> revisão independente de 2026-09-07 (`reports/review-remediation-winvm-ux-2026-09-07/`
> na branch `codex/review-remediation-winvm-ux`, incl. ACHADOS.md, backlog.json,
> reproductions.json).
>
> Regras permanentes anti-poluição, limites de host, ordem das fontes de
> verdade e formato de handoff herdam de
> `docs/roadmaps/homelab-v1.15.1-remediation.md` e aplicam-se integralmente.

## Metadados

| Campo | Valor |
|---|---|
| Status | R0+R1 + contrarrevisão R01 + UX-001..004 implementados e provados localmente; UX-005..011 e R2..R5 pendentes |
| Criado | 2026-09-07, America/Sao_Paulo |
| Repositório | `/mnt/sdcard/Projects/PhaseZero` |
| Base | `codex/aud-fase5` em `9d6be9d` (fases de auditoria 0–4 preservadas; branches do agente não reescritas) |
| Branch | `codex/rev-remediation` |
| Worktree | `/mnt/sdcard/Projects/pz-rev-remediation` (dedicado) |
| Revisão fonte | ACHADOS.md REV-001..018; cinco reproduções em `reproduce.py` (asserts provam o DEFEITO, não o aceite); contrarrevisões `codex/review-r0-r1` (R01-001..005) e `codex/review-r01-ux` (UX-001..011, commit 44cc200) |
| Estado do host | nenhum workload, boot, pacote, VM ou serviço alterado nesta frente |

## Ordem de trabalho (fases R)

- **R0 — regressão hermética + estado**: REV-018, 004, 005, 006, 007. Feito
  nesta branch (`52da4d3`, `8686279`, `87c31a1`); contrarrevisão R01-002/003
  aplicada (`b447312`, `6d8cf39`).
- **R1 — dados P0**: REV-001, 003, 002. Feito nesta branch (`765e791`);
  contrarrevisão R01-001/004/005 aplicada (`174a233`) — o P0 do caminho de
  parada (`compose down` engolido) foi o último fechamento do restore.
- **R2 — primeiro acesso**: REV-008 (terminal embutido na UI com pty,
  timeout/cancel, senha fora de argv/log; chave sem senha só com decisão
  informada).
- **R3 — contrato gráfico WinVM hermético**: REV-009, 010 (sessão chama
  launcher real com QEMU stub por backend/flag/consentimento/fallback tardio;
  `graphics-profiles.json` vira a ÚNICA fonte de maturidade; UI só liga
  aceleração com capacidade comprovada, não presença de QEMU).
- **R4 — UX**: REV-014, 015 (Homelab rolável/responsiva em 1280×800, 800×600,
  150/200%; modo simples vs avançado opt-in; cards honestos).
- **R5 — integração e certificação**: PRs por fase; CI no SHA final; Arch
  limpo em VM descartável (prepare+app+reboot, não só install/status/dry-run);
  matriz por solução/hardware/plataforma; release só depois.
- **Físico/operador (registrado como bloqueio, nunca implementado às cegas)**:
  REV-011 (sync transacional de runtime), REV-012 (encerramento do incidente
  de armazenamento com o operador; boot frio LCD/monitor), REV-013 (matriz
  dev/WSL2 com nested confirmado no guest), REV-016 (migração MiMo + paridade
  IA por plataforma).

## Estados

`verified` exige aceite correspondente ao tier: `planned` < `implemented` <
`local-regression` < `ci` < `e2e-platform` < `physical` < `released`. Fechamento
narrativo não muda estado. Um requisito pode ter estado composto: a parte
implementável em fixture avança por tiers próprios; a certificação física fica
`blocked (operador/hardware)` sem impedir a primeira.

## Contrarrevisão R01 (2026-09-07)

Contrarrevisão do retorno R0+R1 (`codex/review-r0-r1`, worktree
`pz-review-r0-r1`, base `a82e2cc`) devolveu cinco achados; todos tratados em
`codex/rev-remediation` (`174a233`, `b447312`, `6d8cf39`):

| ID | Achado | Correção | Prova |
|---|---|---|---|
| R01-001 (P0) | `if ! cmd_down` suprime errexit; `compose down` 42 era engolido pelo `pz_info` e restore seguia sobre escritor vivo | `cmd_down` propaga falha explicitamente; restore recusa mutação | suíte: `cmd_down` real + stub docker (`compose down` exit 42) → rc 1, "could not stop stack", snapshot não criado, mount intocado |
| R01-002 (P1) | Callback tardio de pair lia a seleção mutável e marcava o host errado | alias capturado no spawn; hostAlias da resposta conferido; resultado de outro host é descartado (sem ingest/avanço/ping); troca de host mata `_pair_advance`/`_pair_host` | pytest: par A em voo + seleção B + sucesso A → B não pareado, etapa não avança, zero follow-up |
| R01-003 (P1) | `--profile` ecoado/persistido, mas serviços não resolvidos; planos idênticos | plano declara `profileInstallable/profileNote/profileServices/budget/appsSource`; UI renderiza aviso ORÇAMENTO; `profile.active` documentado como seleção de orçamento | suíte: edge vs assistant-private planos distintos com services do registry; pytest: aviso presente/ausente |
| R01-004 (P2) | `STAGE_REASON` perdida na subshell `$(...)` | registro único TAB-separated method/consistent/reason | suíte: fixture PG_VERSION com reason não vazio no resultado e no manifest |
| R01-005 (P1) | TSDB real (wal/ + chunks_head/ + blocos com index/chunks) classificada consistente | heurística reconhece layout real e falha conservadoramente com reason | suíte: fixture do layout real → `consistent:false` + reason TSDB |

Cobertura REV-001 ampliada: matriz de mutação falha por posição (primeiro e
último volume; cp e wipe via shims com arm de uso único) + rollback falho.
A afirmação "qualquer posição" vale para a matriz implementada; staging falho
permanece coberto pelo fail-closed de backup, não pelo rollback.

## UX backlog — revisão r01-ux (2026-09-07)

Fonte: `codex/review-r01-ux`, worktree `pz-review-r01-ux`, commit `44cc200`
(relatório + capturas 1280×800/800×600 + probes `check.py`). Prioridade
sugerida pela revisão: UX-001/002 → UX-003/004 → UX-005/007/009 → UX-008 →
UX-006/010; UX-011 acompanha todas as entregas. Experiência-alvo do modo
simples: **objetivo → destino → recursos → resumo → progresso → configurar
acesso → abrir solução**; detalhe técnico apenas no avançado opt-in.

| ID | Requisito (resumo) | Trabalho | Aceite | Tier atual | Estado |
|---|---|---|---|---|---|
| UX-001 | Revisão confirmável pelo fluxo visível | botão "Confirmar revisão" ligado a `onboard_confirm_review`; duplicata de `_refresh_onboard_label` que anulava a lógica REMOVIDA (causa raiz do retorno 2) | E2E por cliques exige visível E habilitado, retângulo inteiro no viewport e clique via `widgetAt` (hit-test real); scan de métodos duplicados nas páginas | local-regression | in_progress |
| UX-002 | Plano estável apesar de telemetria | hash cobre a INTENÇÃO (host/apps/perfil/acesso) e exclui `budget`; verdict fail bloqueia execução com motivo | drift de 1 MiB não invalida aceite; cruzar limite bloqueia; mudança material exige nova revisão | local-regression | in_progress |
| UX-003 | Homelab com controles inteiros | scroll vertical global + reflow de header/perfil/ações via `resizeEvent` (causa do overflow de 70px: linhas únicas que ditavam mínimo) | aceite com MainWindow + tema real: `hmax==0` e retângulo INTEIRO de cada controle no viewport na alternância 800→1280→800 | local-regression | in_progress |
| UX-004 | Windows VM adapta colunas e ações | hero inteiro num grid (wide linha/narrow pilha), card de manutenção reflow (causa do 57px: 5 botões lado a lado = mínimo 785px), captions com wrap | mesmo aceite temático com alternância; CTA com mínimo preservado | local-regression | in_progress |
| UX-005 | Instalar distinto de simular orçamento | combo de perfis lista só `installable`; perfis de orçamento sob "Simular recursos (avançado)", rotulados "— simulação", aviso em `_profile_note` (widget, não log); execução de plano com perfil sem receita NÃO roda `prepare --profile` — pergunta explícita entre reservar recursos e instalar a base | perfil sem receita não é ofertado no simples; escolha indisponível não instala os apps padrão como se atendesse o objetivo (cancelar não executa nada; simular só roda `profile set`; base é opt-in sem perfil) | local-regression | in_progress |
| UX-006 | Início por objetivo real | cards abrem jornada/destino específicos; retomar tarefa recente | escolher Windows chega à instalação Windows; servidor remoto chega ao pareamento; IA não exigida | planned | pending |
| UX-007 | Modo simples com linguagem de produto | copy do onboarding por "Passo N de 5" sem argv/bind/dry-run; banner de falha (`journey.failure_cause`) com causa + próxima ação e "Tentar de novo"; plano revisado resumido em `journey.plan_summary` (servidor, apps, acesso, memória, etapas) num widget, com o JSON só na Saída | espaço/daemon/auth/download mapeados para causa em português com ação; recuperação por controle visível; saber o que o plano faz não exige ler JSON nem argv | local-regression | in_progress |
| UX-008 | Primeiro acesso remoto na jornada | = REV-008 (R2): pareamento guiado, credencial protegida, timeout/cancel | máquina sem chave + host novo: completo sem terminal externo, senha fora de argv/log | planned | pending |
| UX-009 | Instalação termina abrindo a solução | card de app com estado da jornada (`journey.app_journey`) e uma ação primária: Instalar → Preparando → Configurar acesso → Abrir solução; readiness usa `functionalProbes` do status; primeiro acesso persistido em `first-access.json` | "rodando" sem probe aprovado permanece em Preparando; passos de primeiro uso no card; jornada provada por cliques em cada app user-facing do catálogo real (10), com cópia pt-BR (`firstUse.stepsPtBr`) e primeiro acesso confirmado pelo operador, não presumido ao abrir | local-regression | in_progress |
| UX-010 | Windows explica gráficos sem prometer 3D | = REV-010 (R3): simples mostra display recomendado e motivo; experimental só no avançado | guest sem 3D nunca aparece acelerado; flags sessão/launcher coerentes; física separada | planned | pending |
| UX-011 | Gate de acessibilidade/usabilidade | smoke por input público; nomes acessíveis/foco/contraste; sessão com leigos | completar local/remoto/VM com teclado e touch; escalas 150/200%; erros/retomada registrados | planned | pending |

Nota de prova: `test_status_contract.py::test_status_command_always_reports
[emulation.dualscreen.status]` falha de forma idêntica em `a82e2cc` (base da
contrarrevisão) e no HEAD atual — falha pré-existente de ambiente, não
regressão desta frente; não usada como aceite.

## Matriz de evidência obrigatória

| ID | Requisito (resumo) | Implementação | Teste comportamental | Tier atual | Estado |
|---|---|---|---|---|---|
| REV-001 | Restore não perde volume parcialmente copiado | volume registrado antes da 1ª mutação; rollback inclui o falho; rollback incompleto ⇒ `recoveryRequired:true` + nextAction | suíte: matriz cp/wipe falho por posição (primeiro/último) restaura bytes pré-restore; rollback falho reporta recovery-required | local-regression | in_progress |
| REV-002 | Backup SQLite consistente | `.backup` na origem viva (busy timeout); WAL/SHM obsoletos descartados; TSDB/servidores `consistent:false` + reason (R01-004/005) | suíte: escritor concorrente + WAL + restore + integrity_check; fixture PG e TSDB real com reason; consistência banco↔anexos ainda NÃO certificada; snapshot por API do serviço tem teste próprio pendente | local-regression | in_progress |
| REV-003 | Snapshot pré-restore após parada efetiva | `cmd_down` ANTES do tar; `cmd_down` propaga falha do compose down (R01-001); `stackWasRunning`/`stackRestarted` | suíte: `compose down` exit 42 → rc 1, zero escrita; ordem fonte down<snapshot | local-regression | in_progress |
| REV-004 | Player lê JSON real da CLI | `_parse_json_payload`: documento inteiro (pretty/compact), ruído tolerado, envelope `--host` desembrulhado | pytest: multiline, compact, ruído, envelope | local-regression | in_progress |
| REV-005 | pair=false não avança | gate exige `pair is True` do host selecionado | pytest: false/outra-host bloqueiam; sucesso do mesmo host libera | local-regression | in_progress |
| REV-006 | Plano amarrado ao host | `_on_host_changed` invalida pair/revisão/plano e rebobina; callback usa host capturado; pareamento tardio também captura alias (R01-002) | pytest: troca de host invalida; callback de plano/pareamento de outro host é descartado | local-regression | in_progress |
| REV-007 | Perfil revisado dirige o prepare | onboarding envia `prepare --profile`; plano declara `profileInstallable/profileNote/profileServices/budget/appsSource`; UI avisa ORÇAMENTO (R01-003); `profile.active` = seleção de orçamento | suíte: planos distintos por perfil com services do registry; pytest: aviso; hoje TODOS os perfis são budget-only — resolução de services por perfil aguarda receita installable | local-regression | in_progress |
| REV-008 | Primeiro SSH sem terminal externo | pendente (terminal embutido, pty, timeout/cancel) | gate: admin sem chave + appliance novo + porta customizada | planned | pending |
| REV-009 | Sessão e launcher coerentes em gráficos | pendente (contrato único backend/consentimento/flag) | gate: launcher real + QEMU stub por backend/flag/consentimento/fallback | planned | pending |
| REV-010 | Fonte única de maturidade gráfica | pendente (`graphics-profiles.json` canônico; UI sem toggle por presença de QEMU) | gate: contrato idêntico UI/CLI/provision/session | planned | pending |
| REV-011 | Runtime de boot = pacote | sync transacional com preview/elevação + hash pré-sessão: implementável em fixture (VM descartável) | LCD+monitor no runtime entregue + rollback testado: exige host/operador | planned | pending (fixture) / blocked (física) |
| REV-012 | Resiliência física sem aceite | escalada repairFailed>=2 e trava pós-guest-start no fallback: implementáveis em fixture | boot frio; QGA indisponível; crash tardio; 2 falhas escaladas: exige host/operador | planned | pending (fixture) / blocked (física) |
| REV-013 | Dev Windows certificado | perfil Dev separado (manifesto, disco/RAM, retomada) e gate nested-guest declarado: implementáveis em fixture | toolchain→clone→build→test→debug→reboot→retomar em guest limpo: exige hardware | planned | pending (fixture) / blocked (hardware) |
| REV-014 | Homelab sem clipping | scroll vertical global + geometria provada (UX-003); modo simples vs avançado e escalas pendentes | screenshots+geometria 1280×800, 800×600 feitas; 150/200% e teclado/touch pendentes | local-regression | in_progress |
| REV-015 | Objetivos honestos no Início | cards abrem assistente específico; nada promete solução ausente | usuário sem terminal conclui cada objetivo | planned | pending |
| REV-016 | Paridade IA sem migração pendente | matriz supported/experimental/blocked consumida pela UI e fixtures por plataforma: implementável em fixture | chat/stream/renovação reais por plataforma: exige credenciais/operador | planned | pending (fixture) / blocked (credenciais) |
| REV-017 | Certificação por evidência | PR/CI por SHA; Arch limpo prepare+app+reboot | asset instalado em Arch/Windows limpos; estados refletem tier | planned | pending |
| REV-018 | Maturidade sem depender do daemon | `cmd_up` decide perfil antes de `require_docker` | suíte inteira exit 0 com daemon presente E com docker indisponível (rc 69 explícito) | local-regression | in_progress |

## Gates de saída

- P0 fechado em fixture + CI; suíte verde sem daemon e com fake; nenhum
  `verified` sem tier correspondente; `origin/main` intocado até PRs (R5);
  host real sem workloads/boot/VM alterados.
- Reprodutor da revisão (`reproduce.py`) tem asserts que provam o DEFEITO:
  após cada correção eles quebram por design. Aceite futuro exige os testes
  de comportamento correto listados na matriz acima.

## Definição de concluído

REV-001..018 `verified` ou `deferred` com razão aceita; R5 com CI verde no
SHA final e asset validado em host limpo; gates físicos registrados com o
operador; handoff no formato obrigatório.

## Verificação independente70d959f — 2026-09-08

QA dark confirma correções UX-001..004 nos cenários revisados, com confirmação apresentada e overflow horizontal zero em800/1280. Resultado final de pytest e limites em `reports/verify-ux-70d959f/README.md`. Aceite local, sem release; próxima UX-005/007/009.
