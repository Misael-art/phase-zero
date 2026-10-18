# Bonsai login: histórico não comprova indisponibilidade atual

## Problema e causa

Operador executou `bonsai login` no pacote `phasezero-control-center 1.22.6-1`
e recebeu `upstream-auth-disabled; aguarde recuperação do Bonsai`.
Wrapper correto foi resolvido: `~/.local/bin/bonsai`, que chama gerenciador
instalado `/usr/lib/phasezero/linux/ai/claude_code_manager.py`.

Observação de provedor tem `checkedAt=2026-10-17T21:43:34-03:00`,
`fresh=false` e `currentAvailability=unknown`. CLI/UI ignoravam validade ao
formular mensagem. Além disso, `bonsai_auth_probe()` é deliberadamente passivo
e sempre retorna `available=false`: exigir esse campo para login bloqueava
permanentemente novas tentativas, mesmo após recuperação upstream.

## Correção

- Histórico mantém classe, data e origem; mensagem não o converte em estado atual.
- Falha recente `upstream-auth-disabled` bloqueia antes de qualquer processo.
- Observação ausente/vencida permite somente tentativa explícita pelo CLI oficial,
  após consulta npm válida e verificação de runner sem versão latest forjada.
- Status continua local/passivo. `bonsai-probe` consulta somente metadados npm;
  não verifica disponibilidade de autenticação nem cria autorização de dispositivo.
- `loginAvailable` significa prontidão para tentar pelo CLI, não autenticação.
  `loginRequiresPrivateTerminal=true`: UI mantém botão desabilitado e indica
  comando no terminal privado. Nenhum código passa pelo ledger da UI.
- Erro de login restaura credencial anterior. Login/status não chamam `start`.
- Sessão utilizável, inferência e proxy continuam bloqueados por seus gates.

Documentação oficial descreve `bonsai login` separado de `bonsai start`:
https://docs.trybons.ai/bonsai-cli. Não foi comprovado contrato oficial passivo
de disponibilidade nem contrato para proxy genérico. Nenhum endpoint privado
ou projeto de engenharia reversa foi adotado.

## Provas e limites

Host `misael-jupiter`, BigLinux/Manjaro, KDE Wayland. Runtime instalado comparado
ao gerenciador versionado em `main` base `241f84b`: arquivos idênticos antes da
correção. Checkout principal e demais worktrees preservados.

- Baseline: `python3 -m pytest -q tests/test_claude_code_manager.py`:
  28 passed, 17 subtests passed.
- Regressão final manager/UI: 66 passed, 19 subtests passed, incluindo
  timeout/JSON inválido/TTY. Manager isolado: 30 passed, 19 subtests passed.
- UI real XCB/KDE, temas claro/escuro, 800×600 lógicos: helper
  `tests/helpers/bonsai_ui_probe.py`; controles públicos acionados, login
  bloqueado, diagnóstico despachado, detalhe avançado acessível, scroll horizontal
  zero. Capturas locais em `~/.local/state/phasezero/bonsai-followup-20261018/`.
- Consulta real em 2026-10-18 06:06 -03:
  `python3 /usr/lib/phasezero/linux/ai/claude_code_manager.py bonsai-probe`
  confirmou `registry-http-error`, HTTP 404, CLI instalado 0.4.19 e credencial
  `expired-refresh-required`. Nenhuma versão substituta inventada.
- `python3 linux/ai/claude_code_manager.py login bonsai` no worktree, com estado
  real do host, retornou exit 1 com disponibilidade atual desconhecida, histórico
  datado e HTTP 404. Comparação privada antes/depois confirmou bytes da credencial
  intactos. Nenhum código, token ou hash de credencial publicado.
- Sucesso após recuperação upstream é teste simulado de dispatch exclusivo
  `[bonsai, login]` em TTY privado; **não comprova login real**.

## Handoff e próximo gate

Worktree `/mnt/sdcard/Projects/pz-bonsai-observation-age`, branch
`codex/bonsai-observation-age`, base `origin/main=241f84b`. Commit/PR: consultar
Git desta branch. Fase: correção do diagnóstico e desbloqueio futuro de tentativa
explícita. Gates locais acima; CI integral deve ser conferida no PR.

Pacote instalado permanece 1.22.6-1; runtime privilegiado não recebeu cópia manual.
Correção ainda precisa merge/release/pacote para chegar ao comando instalado.
Hoje login segue bloqueado por npm 404; disponibilidade atual do provedor não
foi comprovada. Próximo gate externo: Bonsai restaurar metadata oficial e permitir
login pelo CLI. Só então testar autenticação real em terminal privado, sem
inferência. Reversão: reverter commit; nenhum segredo/cache de provedor foi
reescrito. Apenas cache de metadata npm foi atualizado pela sondagem explícita.
