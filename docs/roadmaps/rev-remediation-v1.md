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
| Status | R0+R1 implementados e provados localmente; R2..R5 pendentes |
| Criado | 2026-09-07, America/Sao_Paulo |
| Repositório | `/mnt/sdcard/Projects/PhaseZero` |
| Base | `codex/aud-fase5` em `9d6be9d` (fases de auditoria 0–4 preservadas; branches do agente não reescritas) |
| Branch | `codex/rev-remediation` |
| Worktree | `/mnt/sdcard/Projects/pz-rev-remediation` (dedicado) |
| Revisão fonte | ACHADOS.md REV-001..018; cinco reproduções em `reproduce.py` (asserts provam o DEFEITO, não o aceite) |
| Estado do host | nenhum workload, boot, pacote, VM ou serviço alterado nesta frente |

## Ordem de trabalho (fases R)

- **R0 — regressão hermética + estado**: REV-018, 004, 005, 006, 007. Feito
  nesta branch (`52da4d3`, `8686279`, `87c31a1`).
- **R1 — dados P0**: REV-001, 003, 002. Feito nesta branch (`765e791`).
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

`verified` exige aceite correspondente ao tier: `implemented` <
`local-regression` < `ci` < `e2e-platform` < `physical` < `released`. Fechamento
narrativo não muda estado.

## Matriz de evidência obrigatória

| ID | Requisito (resumo) | Implementação | Teste comportamental | Tier atual | Estado |
|---|---|---|---|---|---|
| REV-001 | Restore não perde volume parcialmente copiado | volume registrado antes da 1ª mutação; rollback inclui o falho; rollback incompleto ⇒ `recoveryRequired:true` + nextAction | suíte: swap falho (cp exit 42) em qualquer posição restaura bytes pré-restore; rollback falho reporta recovery-required | local-regression | in_progress |
| REV-002 | Backup SQLite consistente | `.backup` na origem viva (busy timeout); WAL/SHM obsoletos descartados; TSDB/servidores `consistent:false` + reason | suíte: escritor concorrente + WAL + restore + integrity_check + seeds preservados | local-regression | in_progress |
| REV-003 | Snapshot pré-restore após parar stack | `cmd_down` antes do tar pré-restore; `stackWasRunning`/`stackRestarted` reportados | suíte: ordem fonte `down < snapshot`; restore de sucesso reporta estado | local-regression | in_progress |
| REV-004 | Player lê JSON real da CLI | `_parse_json_payload`: documento inteiro (pretty/compact), ruído tolerado, envelope `--host` desembrulhado | pytest: multiline, compact, ruído, envelope; 6 regressões novas | local-regression | in_progress |
| REV-005 | pair=false não avança | gate exige `pair is True` do host selecionado | pytest: false/outra-host bloqueiam; sucesso do mesmo host libera | local-regression | in_progress |
| REV-006 | Plano amarrado ao host | `_on_host_changed` invalida pair/revisão/plano e rebobina; callback usa host capturado; host divergente derruba plano | pytest: troca de host invalida; callback de outro host é descartado; backend inclui `host` | local-regression | in_progress |
| REV-007 | Perfil revisado dirige o prepare | onboarding envia `prepare --profile`; sucesso persiste `profile.active`; plano ecoa host+perfil | pytest: argv do plano e da execução carregam o perfil; backend falha fechado em perfil desconhecido | local-regression | in_progress |
| REV-008 | Primeiro SSH sem terminal externo | pendente (terminal embutido, pty, timeout/cancel) | gate: admin sem chave + appliance novo + porta customizada | implemented | pending |
| REV-009 | Sessão e launcher coerentes em gráficos | pendente (contrato único backend/consentimento/flag) | gate: launcher real + QEMU stub por backend/flag/consentimento/fallback | implemented | pending |
| REV-010 | Fonte única de maturidade gráfica | pendente (`graphics-profiles.json` canônico; UI sem toggle por presença de QEMU) | gate: contrato idêntico UI/CLI/provision/session | implemented | pending |
| REV-011 | Runtime de boot = pacote | sync transacional com preview/elevação; hash antes da próxima sessão | upgrade real em VM descartável; LCD+monitor no runtime entregue | implemented | blocked (operador) |
| REV-012 | Resiliência física sem aceite | escalada repairFailed>=2; trava pós-guest-start no fallback | boot frio; QGA indisponível; crash tardio; 2 falhas escaladas | implemented | blocked (operador) |
| REV-013 | Dev Windows certificado | perfil Dev separado; WSL2 condicional a nested no guest | guest limpo: toolchain→clone→build→test→debug→reboot→retomar | implemented | blocked (hardware) |
| REV-014 | Homelab sem clipping | página rolável/responsiva; simples vs avançado | screenshots+geometria 1280×800, 800×600, 150/200%; teclado/touch | implemented | pending |
| REV-015 | Objetivos honestos no Início | cards abrem assistente específico; nada promete solução ausente | usuário sem terminal conclui cada objetivo | implemented | pending |
| REV-016 | Paridade IA sem migração pendente | adapters migrados antes de anunciar; matriz por plataforma | Windows/Arch limpos: instalar→autenticar→chat→expirar→recuperar | implemented | blocked (credenciais/operador) |
| REV-017 | Certificação por evidência | PR/CI por SHA; Arch limpo prepare+app+reboot | asset instalado em Arch/Windows limpos; estados refletem tier | implemented | pending |
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

## Contrarrevisão independente — 2026-09-07

Base `a82e2cc`: 78 pytest e suíte Homelab verdes; cinco lacunas adicionais reproduzidas, incluindo P0 de propagação de falha na parada do restore. R0/R1 têm aceite parcial. Ver `reports/review-r0-r1-2026-09-07/README.md` e backlog R01-001..005. Revisão documental, sem correção de produto ou mutação do host.
