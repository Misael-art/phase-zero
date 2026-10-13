# Handoff — sessão de 2026-10-12/13

Escrito para o próximo agente depois de um reboot do host. Host: `misael-jupiter`
(Steam Deck LCD, BigLinux/Manjaro, KDE Wayland, 14 GiB de RAM). Repositório:
`/mnt/sdcard/Projects/PhaseZero`, remoto `Misael-art/phase-zero`.

Regra do operador nesta sessão: não reiniciar o host nem encerrar a sessão sem
ele pedir. Ele responde de forma assíncrona; não dependa de ele apertar algo
na hora.

## Estado ao encerrar

- `main` = `fa91c09`, CI verde, versão `v1.22.5` (beta).
- Checkout local: branch `docs/handoff-20261013` (este arquivo). Árvore limpa.
- Worktrees: só o principal e `/mnt/sdcard/Projects/pz-deck-wip-preserved-20260924`.

### PRs abertos

| PR | Branch | Estado | O que falta |
|---|---|---|---|
| #114 | `fix/winvm-memory-and-hermetic` | 4 commits, último `503dbc9`. A primeira rodada de CI falhou em `python-test` e `shell-lint`; o `503dbc9` corrige as duas (verificado local). CI novo não conferido. | Conferir CI, mergear. |
| #113 | `feat/dock-input-recorder` | CI verde (34 checks). | Mergear. |
| #105 | dependabot `setup-python-7` | Rebaseado, verde, `CLEAN`. | `gh pr merge 105 --merge` (merge foi barrado para o agente pelo classificador de permissões). |
| #63 | `feat/opencode-auto-permissions` | `python-test` falhando. | **Não mergear** — decisão do operador. Conflita com a direção do PXA-008 (main bloqueou `opencode install/run`). Falta decidir se fecha. |

Mergeados nesta sessão: #110, #111, #112. Fechado: #96 (superado pelo #100).

## Windows VM — o que foi validado e o que mudou no host

### Mudanças reais no host (não estão no git)

1. **A instalação do Windows de 2026-09-23 foi ativada.** `finalize` rodou sobre
   `op-20260923-225352-18359`. Isso aconteceu porque um teste novo vazou para o
   estado real, não por decisão deliberada. Resultado:
   - disco novo: `~/VirtualMachines/PhaseZero-Windows-20260923-225352-18359/phasezero-windows.qcow2` (38,7 GB, `qemu-img check` limpo);
   - `~/.config/phasezero/windows-vm.conf` aponta para ele; não houve backup do conf anterior (apontava para um disco vazio);
   - o disco vazio antigo em `~/VirtualMachines/PhaseZero-Windows/` continua lá;
   - `tpm/` copiado à mão do staging para o diretório novo (o `finalize` antigo não levava).
2. Staging da instalação continua em
   `~/.local/state/phasezero/windows-vm/vms/op-20260923-225352-18359/` (39 GB,
   removível pelo inventário). Não remover antes de o operador confirmar que a
   VM abre pela interface.
3. Perfil de energia: uma tentativa de `launch` o deixou em `performance`; foi
   devolvido para `balanced`. O valor original é desconhecido.
4. `~/.local/state/phasezero/windows-vm/provision/plans/` tem ~968 planos
   deixados por execuções antigas da suíte. Lixo; não foi limpo.

### Verificado neste Deck

- Plano contra a ISO real (`~/ISOs/Win11_25H2_BrazilianPortuguese_x64_v2.iso`): 4096 MiB, aviso de memória presente.
- `launch` com os 12288 MiB configurados: recusado em menos de 1 s, sem diálogo de senha.
- Boot real do disco ativado: QEMU sem janela sobre camada descartável, com cópias de `OVMF_VARS.fd` e `tpm/`, 4096 MiB. O agente convidado respondeu em 18 s (Windows 11, build 26200, host `PHASEZE-7SVSMPQ`) e `guest-shutdown` desligou limpo em 12 s. A camada foi apagada; o disco real não foi escrito.
- `provision inventory` e `windows-vm remove --dry-run`: prontos.

### Não validado

- Instalação nova a partir da ISO: sem RAM livre com o desktop em uso (2–4 GiB disponíveis, zram quase cheia).
- `launch` pelo script real (janela, pastas compartilhadas, SPICE): no desktop ele chama `phasezero-admin` para os bind mounts e abre diálogo de senha. Precisa do operador presente.
- Boot direto pelo GRUB; remover → reinstalar de verdade.
- A cópia do TPM no `finalize` não tem teste hermético.
- `status` ainda mostra `boot-runtime-stale` (o boot direto usa o pacote instalado, não o repositório).

### O que o PR #114 corrige

1. Plano de instalação dimensionava RAM por `MemTotal` (cópia antiga em `provision.sh`). Agora `linux/windows-vm/memory.sh` é a única definição, usada por `provision.sh` e `windows-vm.sh`.
2. `provision start` e `launch` recusam VM que excede MemAvailable + swap livre. No `launch` a checagem vem antes das otimizações e do pedido de senha. Override: `PZ_WINDOWS_VM_ALLOW_MEMORY_OVERCOMMIT=1`. Boot dedicado pelo GRUB não é barrado.
3. Instalação concluída sem ativação: `provision pending-finalize`, `finalize --latest`, bloco `provision.pendingFinalize` e finding `install-awaiting-activation` no `status`, botão "Ativar instalação" na página (ação `windows.provision.finalize`).
4. `finalize` leva `tpm/` junto com `OVMF_VARS.fd`.
5. `launch` restaura o perfil de energia ao sair.
6. `test_provision.sh` exporta `XDG_STATE_HOME` descartável (`PZ_STATE=` no ambiente é ignorado por `common.sh`); `linux-windows-vm-graphics.sh` isola o barramento USB.

Armadilha para quem escrever testes: **`PZ_STATE` passado no ambiente não
isola nada.** `linux/lib/common.sh` deriva de `XDG_STATE_HOME`. Use
`XDG_STATE_HOME` (e `HOME`) temporários.

## LUX-033 — touch/ponteiro some ao tirar do dock (P0)

- Instrumento no PR #113: `pz steamdeck dock-record (once|watch|report)`. Só lê.
- Estava armado como unit transitória `phasezero-dock-record`; **o reboot a mata**.
- Rearmar depois do merge do #113:
  ```
  systemd-run --user --unit=phasezero-dock-record python3 /mnt/sdcard/Projects/PhaseZero/linux/steamdeck/dock_input_record.py watch
  ```
  Antes do merge o arquivo só existe na branch `feat/dock-input-recorder`.
- Registros: `~/.local/state/phasezero/dock-input/records.jsonl`. Até agora só o registro inicial (dockado); nenhum undock gravado.
- Leitura dockado em 2026-10-13: tela no `event9` (`INPUT_PROP_DIRECT`), `SCController Mouse` no `event19`, ambos `enabled=true` e `outputName` vazio no KWin; `DP-1` e `eDP-1` conectados. Os números de `eventN` mudam a cada boot.
- Próximo passo: operador tira do dock e toca na tela nos 45 s seguintes; depois `pz steamdeck dock-record report`. Causa-raiz desconhecida.

## Limpeza de branches — pendente

- 81 branches remotas já contidas na `main` ou com PR mergeado no mesmo commit. Lista em `docs/handoff/2026-10-13-remote-branches-to-delete.txt` (gerada em 2026-10-12; reconferir antes de usar). A exclusão foi barrada para o agente; o operador roda:
  ```
  xargs -a docs/handoff/2026-10-13-remote-branches-to-delete.txt git push origin --delete
  ```
- Remotas a decidir (têm commits fora da main): `codex/apps-dev-ai-accounts-plan`, `codex/winvm-display-contract`, `codex/homelab-appliance`, `codex/winvm-display-refresh`, `codex/hermes-odysseus-diagnostic`, `restore/v1191-fixes`, `claude/sad-cray-b851e9`, `verify/pr{1,2,3,6}-base`. `fix/deck-controller-session-binding` pode sair (superada).
- Manter: `wip/bonsai-resilience-20260821`, as quatro `codex/review-*` (relatórios de 2026-09-07 que não estão na main).
- Locais mantidas por não estarem inteiras no remoto: `codex/homelab-appliance`, `codex/verify-pr1`, `codex/winvm-provision-recovery`.
- Stashes antigos foram salvos como patch em `~/pz-stash-backup-20261012/` e limpos.

### Pastas em `/mnt/sdcard/Projects` aguardando o operador

- `pz-deck-wip-preserved-20260924` (worktree): o código já está superado, mas contém `uber-defesa-privada/` (84 MB) e `.mimosa/` (50 MB) sem rastreio — parece outro projeto. Não remover até ele tirar.
- `pz-wip-preserved-20260924-pr102`: backup manual, não inspecionado.
- `release-87d75d90`, `release-bundles`: artefatos do **SteamZero 2.0.0rc1**, não do PhaseZero.

## WIP bonsai — só triagem

Branch `wip/bonsai-resilience-20260821` (commit `a86af26`): 66 arquivos nunca
revisados, base 561 commits atrás. Aplicar na main dá 6 conflitos. Três
trabalhos misturados:

1. **Lançadores KDE + ícones `phasezero-*`** (`linux/ui/kde-launchers.sh`, `kde-launch.sh`, `tests/linux-kde-launchers.sh`, ~45 SVG, `scripts/generate_icons.py`, `packaging/linux/install-user.sh`): não existem na main; a main já tem `pz_desktop_write_entry` em `linux/lib/desktop.sh`. É a parte aproveitável. Operador aprovou portar só isso num PR próprio.
2. `linux/ai/claude_code_manager.py` (+548 linhas): conflita com o trabalho AISR. Pode ser a origem da cópia divergente do AISR-010; não confirmado.
3. Hotkeys e ditado (`input-actions.sh`, `install-hotkeys.sh`, `voice-typing.sh`): conflitam.

## Desenvolvimento em aberto

- **PXA** (`docs/roadmaps/apps-dev-ai-accounts-v1.md`): 001/002/003/007 `verified`; 004, 005, 006, 008, 009, 010, 011, 013, 014 `in_progress`; 012 `planned`. 008 depende do 9Router #2703. 004/005 (planner e página Desenvolvimento) avançam só com código e testes; não iniciados nesta sessão.
- **Steam Deck input** (`docs/roadmaps/steamdeck-kde-input-v1.md`): SDK-001 falta provar caractere digitado; SDK-002 cursor pós Game Mode `not-proven`. Gates físicos; bloqueiam o canal estável.
- **AI stack**: AISR-009 pendente; AICR-005 e AICR-029 abertos.
- `tests/linux-ai.sh` sai com exit 1 neste host por `rm` do diretório temporário falhar na limpeza, também na main. No CI passa.
- `CLAUDE.md` descreve só a parte PowerShell; o projeto hoje é majoritariamente `linux/` e UI PySide6.

## Ordem sugerida ao retomar

1. Conferir CI do #114 e mergear #114, #113, #105.
2. Rearmar o gravador de dock.
3. Com o operador presente e aplicativos fechados: abrir a VM pela página ou `pz windows-vm launch --ram 6144`; se abrir, liberar o staging de 39 GB.
4. Portar lançadores KDE + ícones do WIP bonsai.
5. PXA-004/005.

## Limites de permissão observados

O classificador de permissões barrou, mesmo com pedido do operador em alguns
casos: `gh pr merge 105`, `git push origin --delete` em lote, remoção em massa
de worktrees. Nesses casos o agente deixa o comando para o operador rodar com
`! <comando>`.
