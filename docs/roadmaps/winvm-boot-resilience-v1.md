# Roadmap canônico — WinVM Boot Resilience v1

> Fonte operacional única para a frente de robustez do boot direto Windows.
> Este documento coordena implementação. Não prova conclusão. Commits, testes,
> CI e validação física são as provas.

## Metadados

| Campo | Valor |
|---|---|
| Status | Planejado |
| Criado | 2026-08-19, America/Sao_Paulo |
| Repositório | `/mnt/sdcard/Projects/PhaseZero` |
| Base | `main` em `1ccaf61` (pacote host `1.16.6-1`) |
| Incidente originador | Primeiro boot GRUB da VM atual (2026-08-19): NTFS sujo, Reparo Automático interrompido, janela QEMU pequena/baixa resolução, usuário leigo sem próximo passo |

## Missão

Um usuário leigo que iniciar o Windows pelo GRUB, pela UI ou pelo dock nunca
fica preso: toda falha tem causa removida automaticamente quando possível e um
próximo passo de um clique quando não. O encerramento de sessão nunca corrompe
o estado do guest. A imagem aparece sempre em tela cheia: 1280×800 no LCD do
Deck, resolução do monitor quando houver monitor.

## Análise do incidente (2026-08-19)

Evidência coletada em diagnóstico read-only do host:

1. **Windows não estava corrompido.** `qemu-img check` 0 erros; boot sector
   NTFS válido; `winload.efi`/`bootmgfw.efi`/BCD presentes; GPT padrão Win11.
2. **Volume NTFS sujo** (`ntfsinfo`: "Volume is scheduled for check"). Causa:
   as duas únicas sessões GRUB da VM (193 s e 36 s) terminaram com o QEMU
   encerrado com o guest vivo — log mostra `terminating on signal 1` e
   `tpm-emulator: Could not cleanly shutdown the TPM`. Fechar a janela do QEMU
   GTK encerra o processo (rc 0) sem shutdown do guest.
3. **Reparo Automático interrompido.** `SrtTrail.txt` inexistente: o reparo
   nunca concluiu porque a sessão acabou antes (36 s é pouco até para o
   diagnóstico). Cada relançamento sobre NTFS suja perpetua o loop.
4. **Tela pequena/baixa resolução.** Entrada GRUB rodava runtime instalado em
   **2026-07-25** proveniente do worktree `pz-winvm-display`
   (`configured_repo`), anterior a todos os fixes de display. O código em
   `main` (PR #54/#60) já resolve: handheld → 1280×800 eDP-1; docked → modo
   físico do monitor (KWin/EDID hash, refresh real, fallback 1080p).
5. **Detecção existente sem ação efetiva.** `runtime-check`/status já expõem
   `boot-runtime-stale` e a UI já mostra aviso + botão "reparar boot", mas o
   incidente ocorreu no caminho GRUB, fora do app, onde não há aviso algum.
6. **Padrão correto já existe isolado.** `recover.sh::stop_vm` faz
   QGA shutdown → espera 120 s → fallback. Nenhuma sessão de boot ou launch
   comum usa esse padrão.

## Princípios

- Nunca matar o guest vivo: encerramento gracioso é caminho feliz; kill é
  último recurso com registro explícito `unclean`.
- Toda superfície (UI, GRUB, sessão) comunica estado e próximo passo em
  linguagem leiga; nada de beco sem saída.
- Runtime do boot direto nunca diverge do pacote instalado por mais de uma
  interação com o app.
- Comportamento só é `verified` com prova: teste hermético, CI e, para
  display/shutdown, validação no hardware real.

## Requisitos (matriz de evidência obrigatória)

| ID | Requisito | Implementação esperada | Teste comportamental | Prova CI/hardware | Estado |
|---|---|---|---|---|---|
| WBR-001 | Encerramento de sessão gracioso | `windows-vm-session.sh`: launcher em background com monitor; fim de sessão (SIGHUP/TERM/INT, `shutdown.requested`) pede QGA `guest-login shutdown` → espera ≤120 s → TERM → 15 s → KILL; GTK com `window-close=off` nos dois perfis (`e982eee` substituiu o `confirm-quit=on` de `5238f7d`, que o QEMU rejeitava) | `tests/test_windows_vm_session.sh`: stop-file e SIGTERM produzem sequência graciosa (`graceful:stop-file`, `graceful:signal`); `tests/linux-windows-vm-graphics.sh` cobre `confirm-quit=on` | hermética verde + runner 43/43; shutdown físico via GRUB pendente | in_progress |
| WBR-002 | Sem relançamento sobre estado sujo | Crash pós-estável recusa relançamento (pré-existente) e agora classifica `launcher-crash` como `graceful:false`; give-up registra `start-failure` sem tocar o convidado; `fallback_desktop` ganha kill-switch de teste | Suíte de sessão: crash ≥stable → rc propagado + `graceful:false`; start-failure limitado termina em give-up | hermética verde; CI `windows-vm-shell-test` agora roda a suíte (`c73f211`) | in_progress |
| WBR-003 | Reparo leigo de um clique | `status --json` emite finding `guest-unclean-shutdown` (warning) com orientação; página Windows VM mostra card "Windows foi desligado de forma inesperada. Inicie e deixe o reparo automático concluir" e mantém Iniciar habilitado; hint info para saída não verificada | `tests/test_windows_vm_ui.py`: pending-sync + unclean acionam botão/mensagem e estado limpo os oculta | pytest 575 + 9; ciclo real de reparo no host pendente | in_progress |
| WBR-004 | Runtime nunca stale após interação | Hook pós-transação grava `/var/lib/phasezero/windows-vm-runtime-sync.pending` (legível sem privilégio); `status --json` expõe `boot.bootRuntimePendingSync`; `boot install` consome o marker e grava `provenance.json` (fonte/versão/data) | `tests/test_boot_runtime_notice.sh`: stale→aviso+marker, current/ausente→silêncio, nunca falha transação; `linux-windows-vm.sh` asserts pendingSync true/false | hermética verde + E2E real no host: reinstalação 14:08 criou o marker e `status` instalado devolveu `pending:true` | in_progress |
| WBR-005 | Resolução correta em cada tela | Implementado (`fdc0361`): default `auto` no session (docked → modo físico do monitor; handheld → 1280×800; override `internal` preservado) + probe `graphics plan` que adiciona `--graphics virtio-gl` quando elegível (único perfil que honra `xres/yres`; fallback compat preservado). Prova no host dockado: `--validate` do runtime instalado resolve `display_width=2560 display_height=1080 display_connector=DP-1 display_refresh_rate=74.991` e probe `eligible:true` | Suíte session cobre docked-auto e internal-override; suite principal inverteu o contrato do default; cenários de probe eligible/ineligible no lifecycle | validação física: próximo boot GRUB do usuário (LCD + monitor) | in_progress |
| WBR-006 | Tela cheia, controles e teclado virtual no boot GRUB | Entregue no main (PR #60); valida somente com runtime sincronizado (depende de WBR-004 física) | — | boot físico com evidência pendente | pending |
| WBR-007 | Escalada de recuperação guiada | Após 2 reparos sem sucesso, wizard encadeia `pz windows-vm recover` → WinRE guiado | Estado `repairFailed>=2` ainda não existe | hermética; físico opcional | pending |
| WBR-008 | Telemetria de sessão alimenta status | `session-state.json` versionado (graceful, reason, duração, display) gravado em todo fim de launch; `status --json` expõe `session` + findings por severidade | Suíte de sessão cobre os cinco motivos e o schema; status real no host devolve o bloco | hermética verde + host | in_progress |
| WBR-009 | Instalação concluída fica visível e a ativação é reversível | `status --json` emite `install-awaiting-activation` mesmo com a VM configurada íntegra, e carrega a prévia em `.provision.pendingFinalize` (origem, destino, disco substituído, bytes necessários/livres, `fits`, `running`); a página Windows VM mostra a instalação como segunda instância com botão "Ativar instalação" condicionado a `not running`; `adopt` copia o conf para `windows-vm.conf.bak-<UTC>-<pid>` antes da troca e restaura esse backup quando o launcher falha; `write_config` troca o arquivo por um único `mv` | `test_provision.sh`: prévia nomeia origem/destino/substitui/espaço sem mutar nada; status reporta a VM instalada E a segunda instalação concluída; falha injetada no launcher → conf restaurado, disco órfão removido, retry ativa; `test_windows_vm_ui.py`: as duas instâncias na tela e ativação explícita só quando nada está rodando | hermética verde no host + CI no SHA final; ativação real ainda depende do operador presence | in_progress |

Adicionar IDs, nunca reutilizar. Estados: `pending`, `in_progress`, `verified`,
`deferred`.

## Fases e gates

### Fase 0 — Baseline e fixtures

- Worktree dedicado; reproduzir incidente em fixture (launcher fake que "morre
  com guest vivo").
- Fixtures de display já suportam `PZ_DISPLAY_SYSFS_ROOT`.
- Gate: suíte nova executa em <60 s; baseline documentado aqui.

### Fase 1 — Ciclo de vida gracioso (WBR-001, WBR-002, WBR-008)

- Extrair padrão `stop_vm` para função compartilhada; aplicar na sessão GRUB e
  no launch comum.
- `window-close=off` no GTK (substituiu `confirm-quit`, rejeitado pelo QEMU); ação de desligar nos controles.
- Registro de sessão versionado; status/UI consomem.
- Gate: hermética verde; 1 shutdown físico real via GRUB com registro `clean`.

### Fase 2 — Reparo leigo (WBR-003, WBR-007)

- Modo reparo (sem auto-kill, banner, timeout longo).
- Card de um clique na página Windows VM; wizard de escalada após 2 falhas.
- Gate: hermética verde; 1 ciclo real de reparo no host (NTFS suja → clean).

### Fase 3 — Runtime sob controle (WBR-004)

- Marker no hook pós-transação; card de sincronização com preview elevado.
- `boot install` fonte única = pacote; sobreposição de `configured_repo`.
- Gate: package-smoke; instalar pacote em ambiente de teste → card aparece →
  boot install → `runtime-check` `current`.

### Fase 4 — Validação física de display (WBR-005, WBR-006)

- Deck LCD: 1280×800, tela cheia, controles, teclado virtual.
- Monitor: modo do monitor com refresh real; troca a quente re-resolve no
  próximo boot.
- Gate: evidência registrada (log de sessão + foto) nesta seção.

### Fase 5 — Docs, changelog, release

- CHANGELOG, release notes, atualização deste roadmap.
- Gate: CI verde; release com checksums; instalação no host validada.

## Estado vivo

### Incidente físico 1.20.8 — 2026-09-15

Validação do usuário **falhou**: janela QEMU pequena em Handheld e Dock,
atalhos e teclado touch indisponíveis. Diagnóstico e recuperação detalhados em
[winvm-1208-handheld-incident.md](winvm-1208-handheld-incident.md).
Runtime instalado é 1.20.8. Logs mostram cliente GTK Wayland nativo sob
Gamescope, resultado touch antigo e erros Btrfs no inode do disco qcow2 ativo
(root 257, inode 12372912), acompanhados de `qemu: aio failed`.
WBR-005/006 continuam sem verificação física. Corrigir apresentação não fecha
o bloqueio de armazenamento registrado em agosto.

| Item | Estado atual | Verificado por | Data |
|---|---|---|---|
| Incidente originador | diagnosticado; sem mutação; correções ainda não aplicadas | diagnóstico read-only 2026-08-19 | 2026-08-19 |
| Runtime GRUB do host | `stale` (2026-07-25, worktree `pz-winvm-display`); sincronização pendente de autorização | `pz windows-vm boot runtime-check --json` | 2026-08-19 |
| VM atual | NTFS sujo; Reparo Automático não concluiu; disco estruturalmente são | `qemu-img check`, `ntfsinfo`, boot sector | 2026-08-19 |
| Implementação Fases 1–3 | WBR-001..004/008 implementados com testes herméticos (`da373f8`, `5238f7d`, `8a92aab`, `c73f211`, `095d674`); runner 43/43; pytest 575+9; ShellCheck paridade CI | `bash tests/runner.sh`, `pytest tests/` | 2026-08-19 |
| Pacote host | `1.16.6-1` reinstalado às 14:08 do HEAD `095d674`; hook criou `/var/lib/phasezero/windows-vm-runtime-sync.pending`; `status` instalado devolve `pending:true`, `stale:true` e bloco `session` | `pacman -Q`, `cat` marker, `pz windows-vm status --json` | 2026-08-19 |
| CI | runs `32279172680`/`32279456440` (ci) em andamento no push; gitleaks verde; confirmar verde antes de marcar `verified` | `gh run list` | 2026-08-19 |
| Remediação REV-009..013 | defeitos de contrato gráfico/runtime/dev registrados pela revisão de 2026-09-07; plano R3 e matriz da frente em `docs/roadmaps/rev-remediation-v1.md` (REV-009/010 herméticos antes de qualquer gate físico; REV-011/012/013 permanecem bloqueios de operador/hardware) | branch `codex/rev-remediation` sobre `9d6be9d`; ACHADOS.md em `codex/review-remediation-winvm-ux` | 2026-09-07 |

## Ledger de execução

| Data | Agente | Branch/worktree | Fase | Commits | Gates | Resultado |
|---|---|---|---|---|---|---|
| 2026-08-19 | ZCode | `main` (diagnóstico) | — | `1ccaf61` (docs anteriores) | diagnóstico read-only | Incidente documentado; roadmap criado |
| 2026-08-19 | ZCode | `main` (worktree principal) | Fases 1–3 + testes CI | `da373f8` (sessão graciosa + estado), `5238f7d` (confirm-quit), `8a92aab` (marker/provenance/cards UI), `c73f211` (suítes no CI), `095d674` (AGENTS.md LF) | runner 43/43 (inclui suítes novas de sessão/notice/remoção); pytest 575+9; `linux-windows-vm.sh` verde; ShellCheck com excludes do CI; `git diff --check`; gitleaks verde | WBR-001..004 e 008 em `in_progress` (falta física). Acidente de sessão durante o desenvolvimento: `fallback_desktop` sob teste dentro do desktop logado aninhou um Plasma e derrubou a sessão KDE; corrigido com kill-switch de teste e análise de parentagem antes de matar processos. Pacote reinstalado 14:08; marker pending criado E2E. **Próximo**: CI verde; boot install autorizado (consome marker, grava provenance); boot físico p/ WBR-005/006; ciclo real de reparo p/ WBR-003 |
| 2026-08-20 | ZCode | `main` (worktree principal) | Reinstalação completa monitorada + avaria de armazenamento | `4ad7d3e` (provenance), `e982eee` (window-close), `ebb2a96` (sendkey em janela inteira) | provision 258/0; CI `ci` verde (run 32280269422); runtime `current` via bigsudo; reinstalação op-20260820-050749-32490: setup→drivers→tweaks(falhou 1×, resume ok)→verify→snapshot→relaunch→**completed 100%**; finalize com `--source provisioned`; preview de remoção limpo; duplicata órfã de 20 GB + staging limpos | Causas-raiz corrigidas no caminho: QEMU rejeitava `confirm-quit` (VM nem iniciava — agora `window-close=off`, provado no binário instalado); instalador travava para sempre no prompt "Press any key" (rajada de teclas por 21 s via QMP + teste comportamental). **Bloqueio real novo**: sob carga de I/O da VM, o btrfs reporta `csum failed` recorrente (10 eventos neste boot) e o QEMU derruba `aio failed` — corrupção de leitura transitória e recorrente; SMART do NVMe (NV530-1T) saudável, 52–59 °C, spare 100%. Suspeitas: RAM do host (não testada), SSD quente, ou interação `compress-force=zstd` + DirectIO. VM nova estruturalmente íntegra (`qemu-img check` ok) mas não inicia confiavelmente até validar o caminho de dados. **Próximo**: memtest86+; teste com VM em subvolume sem compress e `cache=writeback`; `btrfs scrub`; nova tentativa de boot somente após isso |
| 2026-08-20 | ZCode | `main` (worktree principal) | WBR-005: monitor na dock + fullscreen nativo | `fdc0361` (auto + probe virtio-gl), `bedcb8c` (evidência) | session lifecycle 7 cenários; `linux-windows-vm.sh` verde com contrato invertido (docked-auto primário, internal como override); ShellCheck; pacote rebuild + reinstalado; runtime `current` via bigsudo; resíduo root de `/run` limpo pós-boot-install | Prova no host dockado: `--validate` do runtime instalado resolve 2560×1080@74.991 no DP-1 e o probe responde `eligible:true` (boot usará `--graphics virtio-gl`, driver viogpudo já no convidado). Boot direto documentado como single-screen: monitor na dock, painel no handheld. **Próximo**: usuário valida no próximo boot GRUB (LCD e monitor); evidência visual fecha WBR-005/006 |
| 2026-08-20 | ZCode | `main` (worktree principal) | Entrada GRUB dedicada "Windows (Dock)" | `960364a` (feature), `57835e2` (status unknown-permission) | runner 43/43; suíte windows-vm verde com dry-run dock; session suite pina external/internal via cmdline (fixture `PZ_WINDOWS_VM_CMDLINE_FILE`); UI 24 testes com botão rastreando `dockEntryInstalled`; pacote rebuild + reinstalado; entrada confirmada no `grub.cfg` (menuentry com hotkey `d` e `phasezero.windowsvm-display=external`); env root persiste o toggle; `/run` limpo; `grubenv` intacto | Primeiro `--dock-entry` gravou a entrada no cfg mas o env ficou `0` (o boot install seguinte sem flag a removeria); re-execução com `--dock-entry` ficou pendurada no diálogo do bigsudo sem autorização — usuário deve autorizar o diálogo ou usar o botão "GRUB: Windows (Dock)" da Central para fixar o toggle. Ícone depende do tema GRUB ativo (mesma `--class windows` das duas entradas). **Próximo**: autorizar `--dock-entry`; boot físico pela entrada Dock valida monitor exclusivo |
| 2026-08-23 | ox-alpha (opencode) | `codex/ccs-surfaces-v1` (worktree `pz-ccs-surfaces`) | CCS-000 (ops, via roadmap Control Center Surfaces) | — (nenhum commit; item é do operador) | nenhum gate aplicável — sem código | **CCS-000 marcado `deferred`**: memtest86+, `btrfs scrub` e migração da VM para subvolume nocow/sem zstd exigem reboot ou I/O pesado no host em uso, proibidos no mandato da sessão. Bloqueio de produção de 2026-08-20 (csum failed + aio failed) permanece aberto: disco atual segue CoW+csum; WBR físico continua bloqueado até o operador executar memtest/scrub/nocow e registrar aqui. Nenhuma VM foi bootada nesta sessão. Fonte: `docs/roadmaps/control-center-surfaces-v1.md` |
| 2026-09-23 | Codex | `codex/winvm-provision-recovery` (`/mnt/sdcard/Projects/pz-winvm-recovery`) | Supervisão de provisionamento, inventário, edição e pacote | `24b0bb9`; pacote `1.21.1-2` | `test_provision.sh` 259/0; recovery smoke; remoção smoke; UI Qt 32/32; bash syntax; ShellCheck com exclusões do CI; `install-root-smoke.sh`; pacote extraído/imports/inventário; instalado via `phasezero-admin`; `runtime-check=current`; inventário real pós-remoção count 0 | Corrigidos worker destacado e identidade de processo, reconciliação de `running` órfão, lock/QEMU filhos, inventário de parcial, remoção bloqueada com QEMU vivo, retomada e seleção de edição sem palpite. Operação `op-20260918-153055-5487` movida à lixeira recuperável (14,9 GB; permanece ocupando disco até esvaziar). Qcow2 configurado `/home/misael/VirtualMachines/PhaseZero-Windows/phasezero-windows.qcow2` permaneceu zero/inalterado. Scrub Btrfs completo, somente leitura, percorreu 831,67 GiB em 11m09s e não encontrou erros; contadores acumulados `corruption_errs=603`, contadores read/write/flush/generation em zero. RAM disponível pós-scrub 2,0 GiB, abaixo do mínimo guest de 4 GiB. `virtio-gl` elegível no host em modo experimental e QEMU tem `virtio-vga-gl`/virglrenderer, mas não houve inicialização do guest, driver 3D nem medição Windows. **Próximo**: liberar memória com margem acima de 4 GiB e rodar instalação/shutdown/remoção/reinstalação; depois snapshot + teste dentro do Windows com `virtio-gl`; CI remoto não executado. |
| 2026-10-14 | Qoder (claude-session a4227094) | `fix/winvm-ram-rebase` (worktree `/mnt/sdcard/Projects/pz-winvm-ram-rebase`, empilhada em `fix/winvm-memory-and-hermetic` = `6a99db8`) | Duas lacunas de memória no `launch`/`status` + monitoramento do host até a janela de instalação | `e4b646c` (sentinela do preflight hermética), `870ff42` (pré-checagem emite veredito de memória; valor pinado que o host não entrega é re-baseado); PR #116 (base `fix/winvm-memory-and-hermetic`) | `test_provision.sh` no head do #114: baseline 295/0 → RED 299 PASS/16 FAIL → GREEN 315/0; `linux-windows-vm.sh`, `test_windows_vm_session.sh`, `linux-windows-vm-graphics.sh` exit 0; ShellCheck 0.11 com as exclusões do CI; `git diff --check` limpo. CI do #116 no fechamento: `windows-vm-shell-test`, `lint`, `arch-clean-host`, `compose-validate`, `homelab-python-test`, `hosted-qemu-kvm-probe`, `security-secret-scan`, `scan` verdes; `shell-lint` (0.9.0 e 0.11.0), `python-test` e `pester` ainda em andamento. Prova no host real com o conf pinado em 12288 MiB: pacote instalado `1.22.5-1` responde `.memory = null` e `success: true` (a pré-checagem não falava de memória); árvore nova responde `memory:{requestedMb:4096,fit:"fits",availableMb:6402,swapFreeMb:3861}`, sem blocker de memória, com o aviso "a configuração pede 12288 MiB … a VM vai iniciar com 4096 MiB" | **Instalação nova não rodou — a janela nunca abriu.** A regra é a do próprio código (`linux/windows-vm/memory.sh`): mínimo do Windows 11 (4096) + reserva do perfil desktop (3072) ⇒ `MemAvailable ≥ 7168` MiB, mais PSI `some avg10 < 10`, nenhum QEMU real e `corruption_errs` estável. Amostragem de 30 s desde 2026-10-13 23:13 local (`2026-10-14T02:13:31Z`) até `2026-10-14T09:56Z`, em `~/.local/state/phasezero/homologation/winvm-20261013/resource-samples.log`: **926 amostras `gate=FAIL`, 0 `gate=PASS`**, 1 linha `gate=INFO`; máx `avail_mb` 6509, mín 2908, PSI sempre abaixo de 2, `btrfs_corr` constante em 603 (**sem corrupção nova**), nenhum QEMU real, host **não** reiniciou e a sessão KDE permaneceu intacta. Dois registros saíram com `reason=qemu-running` (09:31Z, 09:39Z) por stubs de teste do `linux-windows-vm.sh` em `/tmp/tmp.*/bin/qemu-system-x86_64`; o filtro do monitor passou a exigir `/proc/<pid>/exe` realmente qemu e a unidade foi rearmada às 09:40:43Z, com a lacuna de ~2 min marcada no log como `gate=INFO`. Maior detentor de RAM durante a vigília: o próprio processo do agente (`qoder` 1,1–1,6 GiB) e `electron` (~0,9 GiB) — falta ~1,7 GiB e só o operador libera. **Lacuna nova encontrada (fora do código)**: `PZ_WINDOWS_VM_ISO` aponta para `/home/misael/Downloads/Win11_25H2_BrazilianPortuguese_x64_v2.iso`, que não existe; a mídia íntegra está em `/home/misael/ISOs/Win11_25H2_BrazilianPortuguese_x64_v2.iso` e há uma cópia em `/home/misael/Downloads/Win11_25H2_BrazilianPortuguese_x64_v2 (1).iso` — as duas conferem `sha256 50fe4703cf0df0072e093d1f5d58ed450e4c49d8ca960433bbe6278d5ef10107` (8 172 068 864 bytes, o mesmo hash do plano verificado nesta ISO), então o que está errado é só o caminho do conf; instalação nenhuma parte do conf atual. **Também aberto**: `preflight.resources.ramMb` continua derivado de `MemTotal` (plan JSON mostra `14820` ao lado de `memory.availableMb: 6291`) — não corrigido, precisa aprovação por unidade; 969 arquivos de plano órfãos em `…/provision/plans/`; staging `op-20260923-225352-18359` com 40 GB não remover antes de o operador abrir a VM pela interface; WBR-003/005/006 seguem dependendo de boot físico. **Próximo**: com `avail ≥ 7168` confirmado no log, `provision plan --iso /home/misael/ISOs/Win11_25H2_BrazilianPortuguese_x64_v2.iso` → `start` → `watch` e, em paralelo, `install-watch.sh <op>`; mergear #114 e depois #116; decidir o caminho da ISO no conf com backup. |
| 2026-10-15 | Qoder (claude-session a4227094) | `fix/winvm-ram-rebase` (worktree `/mnt/sdcard/Projects/pz-winvm-ram-rebase`, head `d761000`) — a instalação rodou a partir dessa árvore; o pacote instalado `1.22.5-1` e o conf do host não foram tocados | Instalação Windows nova completa e instrumentada (plan → start → setup → drivers → tweaks → verify → snapshot → relaunch) + terceiro gap de RAM fechado (`preflight.resources.ramMb`) + guarda de pressão para a janela de instalação | `6fd7c69` (teste hermético do carry de TPM/OVMF no finalize, com prova de mutação das duas guardas), `d761000` (preflight responde com `MemAvailable` e mantém `totalMb` ao lado); PR #116 | Suíte: `test_provision.sh` 329/2 (RED do preflight, `red-preflight-ram.log`) → 331/0 (`green-preflight-ram.log`); carry 320/8 (`red-carry-test_provision.log`) → 328/0 → 329/0 (`green-carry2-test_provision.log`); `linux-windows-vm.sh`, `test_windows_vm_session.sh`, `linux-windows-vm-graphics.sh` exit 0; ShellCheck 0.11 com as exclusões do CI. **Instalação real**: plano `plan-20261015-224202-27493` com `ramMb:4096` explícito, `memory.fit:"fits"`, `blockers:[]`, `preflight.resources:{ramMb:4692,totalMb:14820}` (prova viva do `d761000` — antes respondia 14820); operação `op-20261015-224232-10324` de `01:42:32Z` a `02:20:27Z` (38 min), fechou `state=completed checkpoint=relaunch progress=100` com os 10 checkpoints em `done`; disco realocado 19 G (`allocatedBytes:20987645952`), snapshot `golden-clean.qcow2` criado, relaunch validado por QGA (SO reportado `Windows 10 Home`, rede OK, marcador de conclusão OK), instalação de drivers virtio exit 0 (netkvm, viogpudo, balloon, viorng, vioscsi, vioinput; vioser já presente). **Prova visual**: captura do desktop do host (`~/.local/state/phasezero/homologation/winvm-20261013/winvm-after-install.png`, 2 083 558 bytes, `spectacle -n -b`) mostra a janela GTK da QEMU renderizando o desktop do Windows já sem tela de login — primeiro registro visual desta imagem instalada. **Observação reconciliada em três log independentes**: monitor 78 amostras dentro da janela (`resource-samples.log`), guarda 111 (`guard-op-…log`), watch 69 (`install-watch-op-…log`); `MemAvailable` mínimo 1166 MiB; PSI `some avg10` máximo 15,12; `btrfs corruption_errs` = 603 em todas as amostras dos três logs, delta +0; `dmesg` cresceu 18 linhas e não contém nenhum OOM/oom-kill/erro de I/O; sessão KDE intacta (seat0, `startplasma-wayland` pid 5907) e o host não reiniciou. **Integridade do que já existia**: conf com md5 `f90148ad19668141fd2b01b65a962012`, idêntico ao backup `windows-vm.conf.bak-20261015T200748`; discos ativados com mtime inalterado (`…/PhaseZero-Windows-20260923-225352-18359/phasezero-windows.qcow2` 2026-10-13T01:10) e `adoptedDiskExists:false` na operação nova | **A janela de 7168 MiB que venho usando como gate está errada por excesso, e esta corrida é a prova.** Um convidado de 4096 MiB instalou o Windows inteiro com `MemAvailable` caindo a 1166 MiB — 6× abaixo do limiar que publiquei — sem nenhum OOM, sem PSI alto e sem erro de disco: o host adicionou três dispositivos zram durante a corrida (`dmesg`: `Adding … swap on /dev/zram0/1/3`) e a condição do próprio `linux/windows-vm/memory.sh` (`fits` = RAM da VM ≤ `MemAvailable`) bastou. O gate de vigília deve ser re-derivado do código, não da soma piso+reserva; mudança de comportamento precisa de aprovação por unidade. **Lacunas novas abertas pela corrida**: (a) `preflight cache SHA mismatch (expected=e14cf2b9… cached=4fcae9c9…)` força re-download de 753 MB de virtio a cada instalação (43 s e banda); (b) QGA reporta `Windows 10 Home` para uma ISO 25H2 — é nome de produto, não verificação de SKU, e `guestLoginVerified` continua em aberto; (c) resolução do fim da fase `setup` é o poll de 30 s, então o término real está em (1770 s, 1800 s] e o heartbeat cai no mesmo sample do `QEMU exited`; (d) `install-watch.sh` mede `qcow_bytes` pelo glob do disco **ativado**, ou seja, durante uma instalação mostra o disco velho congelado em 38,6 GB — o número real saiu de `qemu-img`/`du` direto no staging, e o sampler precisa apontar para `$vm_dir`. **Não rodei `finalize`**: achata 19,5 GB e chama `windows-vm.sh adopt`, que reescreve conf e o disco em `~/VirtualMachines` — decisão do operador com ele presente; `pending-finalize` já lista a operação. A VM relançada continua de pé com janela GTK (`qemuPid 988752`, RSS 4,1 GiB) para ele abrir. **Espaço**: staging novo 19,5 GB somado ao `op-20260923-225352-18359` de 42,7 GB; `/home` foi de 147 GB a 128 GB livres e nenhum dos dois é removível antes de o operador confirmar que abre a VM pela interface. **Próximo**: conferir na própria tela a sessão logada (a captura já mostra o desktop, mas quem valida interação é o operador); decidir o `finalize`; mergear #114 e depois #116 (head `d761000`) com o rollup terminal do CI no SHA pinado; rearmar o gravador LUX-033 depois do #113; alinhar o gate de vigília com o `fits` do código. |
| 2026-10-16 | Qoder (claude-session a4227094) | `fix/winvm-ram-rebase` (worktree `/mnt/sdcard/Projects/pz-winvm-ram-rebase`) | Os dois P0 da revisão do operador (visibilidade da instalação pendente + ativação reversível), o gate de merge do shell-lint, e uma regressão própria encontrada no rollup do CI | `4a9e30c` (SC2031 do carry removido de `tests/test_provision.sh`), `bd5de03` (prévia + backup/rollback no `adopt`), `cd6cde7` (segunda instância e ativação explícita na UI), `80e93f1` (restaura o `windows-vm.sh` real que `bd5de03` commitou como stub), `c86df85` (varreduras do rescue sobrevivem a `USER` ausente); PR #116 head `c86df85ca417a19f50c59300ddf61f90f47bba5c` | `test_provision.sh` 359/0 (`green-p0-activation-test_provision.log`; antes 358/1 com o rollback vazio e 355/5 antes de corrigir `install_user_files`); `pytest tests/test_windows_vm_ui.py` 34 passed; `test_linux_native_ui.py + test_windows_vm_ui.py` 62 passed; `linux-windows-vm.sh` e `linux-windows-vm-graphics.sh` exit 0 (`green-p0-linux-windows-vm*.log`, `green-rescue-user.log`); suítes irmãs exit 0 (`test_windows_vm_remove.sh`, `test_windows_vm_session.sh`, `test_provision_recovery.sh`, `test_boot_runtime_notice.sh`, `linux-autounattend.sh`, `linux-guest-recovery.sh`, `linux-audit-doctor.sh` 9/0); ShellCheck com as exclusões do CI: 0 findings, SC2031 = 0 (`ci-like-test_provision.log`); **controle novo**: as duas suítes rodadas contra um `git archive HEAD` limpo (`env -i`, HOME vazio, `LANG=C.UTF-8`) → 359/0 e exit 0 (`green-headexport-*.log`) | **Causa-raiz do CI vermelho em `cd6cde7` não era teste: era o índice.** `bd5de03` commitou `linux/windows-vm/windows-vm.sh` como um stub de 2 linhas (`#!/usr/bin/env bash` + `echo "{}"`), 4095 linhas a menos; o disco tinha o script inteiro, então todas as suítes locais passavam enquanto `windows-vm-shell-test` morria em 31 s e `python-test`/`shell-test` falhavam com ele. verde em `4a9e30c` → vermelho em `cd6cde7` nos três jobs, sem nenhum assertion quebrado no host. Corrigido em `80e93f1` com verificação do **blob commitado** (`git show HEAD:... | wc -l` = 4135, `bash -n` ok, `config-path`/`config_backup` presentes) e suítes rodadas contra a árvore exportada — o controle que faltava, agora obrigatório antes de qualquer push. **Shell-lint do aceite (SC2031 nas duas versões) está verde no SHA anterior**: os jobs `shell-lint (0.9.0)`/`shell-lint (0.11.0)` completaram sem falha em `cd6cde7`. **Lacuna nova fechada no caminho de boot**: `rescue.sh:59` e `:73` liam `$USER` para montar as bases de mídia removível; a sessão de boot roda sob `set -u` e um serviço systemd não exporta `USER`, então o wizard abortava antes de listar ISO ou disco — exatamente o caso para o qual existe. RED reproduzido com o nome fora do ambiente (`red-rescue-user.log`: `USER: variável não associada`), GREEN com fallback `USER→LOGNAME→id -un` e um teste que dá `unset USER` dentro da varredura. **P0-1 (visibilidade)**: `status --json` agora emite `install-awaiting-activation` mesmo com a VM configurada íntegra, com a frase "Duas máquinas virtuais existem…"; a página mostra a instalação como segunda instância e o botão "Ativar instalação" só aparece com a operação parada — provado no host real com as duas instâncias vivas: `.health.readyToLaunch=true` junto do finding e `pendingFinalize{operationId:op-20261015-224232-10324, running:true, requiredBytes:23 790 485 504, freeBytes:109 038 714 880, fits:true}` (`status-after-p0.json`), e `finalize --preview` imprimindo origem/destino/substitui/espaço e recusando por a QEMU da instalação ainda estar ligada (`preview-after-p0.txt`). **P0-2 (reversibilidade)**: `adopt` copia o conf para `windows-vm.conf.bak-<UTC>-<pid>` antes da troca, restaura esse backup se o launcher falhar, e `finalize --preview` expõe origem, destino, disco substituído, bytes necessários/livres e `running`; a troca agora limpa o disco órfão de meia-troca. Falha injetada no `install -d` do launcher → conf restaurado byte a byte, `adoptedDisk` vazio no registro, retry ativa o disco novo. **Matriz**: WBR-009 added (never reuse IDs), `in_progress` até a ativação real acontecer com o operador. **Nada do host foi mutado**: staging `op-20260923-225352-18359` (40 G) e `op-20261015-224232-10324` (42 G) intactos, QEMU `988752` ainda rodando, sem `finalize`, sem shutdown, sem reboot, sessão KDE ativa; memória no momento da verificação 2 876 MiB disponíveis, PSI `some avg10=0.21`. **Limites do que está provado**: a prévia e o rollback são provados hermeticamente e a recusa é provada no host, mas a ativação em si (achatar 19,5 GB e trocar o disco) ainda não rodou — decisão do operador com ele presente; P1 (fonte única virtio, ISO do conf, política de memória por perfil, interação física/SKU) e P2 (instrumentação no repositório) seguem abertos; `arch-clean-host` e o rollup terminal em `c86df85` ainda por confirmar. **Próximo**: confirmar o rollup terminal em `c86df85` (waiter em `ci-rollup-c86df85.log`), validar interação física na janela atual, depois `finalize` com o operador e então cache/ISO/política de memória. |

### Handoff — Fases 1–3 (2026-08-19)

```text
Objetivo da sessão: implementar a robustez de boot direto planejada
  (WBR-001..004, 008) após o incidente de NTFS suja/Reparo Automático.
Fase/IDs assumidos: Fases 1–3; WBR-001/002/003/004/008.
Branch e worktree: `main`, worktree principal.
HEAD inicial: `d54d9fc`.
HEAD final: `095d674` (+ docs deste registro).
Arquivos alterados: `linux/windows-vm/windows-vm-session.sh`,
  `linux/windows-vm/windows-vm.sh`, `linux/windows-vm/boot-runtime-notice.sh`,
  `linux/ui_native/pages/windows_vm.py`, `tests/test_windows_vm_session.sh`
  (novo), `tests/test_boot_runtime_notice.sh` (novo),
  `tests/test_windows_vm_remove.sh`, `tests/test_windows_vm_ui.py`,
  `tests/linux-windows-vm.sh`, `tests/linux-windows-vm-graphics.sh`,
  `tests/runner.sh`, `.github/workflows/ci.yml`, `CHANGELOG.md`, `AGENTS.md`
  (normalizado LF), este roadmap.
Commits criados: `da373f8`, `5238f7d`, `8a92aab`, `c73f211`, `095d674`,
  docs do roadmap.
Testes executados e resultados: runner 43/43 (suítes novas de sessão,
  notice e remoção incluídas); pytest 575 + 9 subtests; suítes individuais
  re-executadas após cada commit; `bash -n`; ShellCheck com os excludes do
  CI; `git diff --check`.
CI/PR: pushes `c73f211` e `095d674`; gitleaks verde; jobs `ci` em andamento
  (runs `32279172680`, `32279456440`) — confirmar verde antes de `verified`.
Estado do host antes/depois: pacote `1.16.6-1` reinstalado às 14:08 do
  HEAD `095d674` via `phasezero-admin pacman -U`; hook criou o marker
  pending; `status` instalado devolve `pending:true`/`stale:true`/bloco
  `session`; runtime GRUB segue de 2026-07-25 (boot install pendente de
  autorização); VM/disco/GRUB não mutados nesta sessão.
Segredos verificados como ausentes: diffs revisados; gitleaks verde.
Limitações e riscos restantes: (1) shutdown gracioso e reparo dependem de
  QGA ativo no convidado — sem agente, escala para TERM após 120 s e marca
  unclean; (2) saída rc=0 sem pedido continua indistinguível entre
  desligamento pelo menu Iniciar e fechamento confirmado — tratada como
  dica, não como dano; (3) validação física (WBR-005/006, ciclo de reparo
  real, shutdown via GRUB) pendente; (4) durante o desenvolvimento, um
  teste rodando a sessão real dentro do desktop logado derrubou a sessão
  KDE do usuário via `fallback_desktop` — kill-switch adicionado e
  guardado por revisão de parentagem antes de qualquer kill.
Bloqueios reais: nenhum técnico; boot install aguarda autorização.
Próximo passo exato: confirmar CI verde; com autorização, `phasezero-admin
  /usr/lib/phasezero/linux/pz windows-vm boot install` (consome o marker,
  grava provenance, sincroniza runtime 1.16.6); bootar VM pela UI, deixar
  o Reparo Automático concluir (WBR-003 física) e registrar
  `session-state.json` real; boot físico GRUB para WBR-005/006.
```

## Definição de concluído

Boot direto resiliente v1 termina quando: WBR-001..008 `verified` ou
`deferred` com razão; shutdown físico e ciclo de reparo provados no host;
runtime `current` após sincronização; evidência de display em LCD e monitor
registrada; CI verde em todas as frentes mergeadas.
