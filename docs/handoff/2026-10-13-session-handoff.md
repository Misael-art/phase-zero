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

## Pacote instalado no host (2026-10-13 06:53)

`phasezero-control-center 1.22.5-1` foi instalado com `phasezero-admin pacman -U`
a pedido do operador, para ele validar o trabalho desta sessão. **Não é a
release publicada v1.22.5**: foi gerado da branch local
`integration/validate-20261013` (`e02a9b4`) = `main` (`fa91c09`) + #113 + #114
(até `6a99db8`) + #115. O pacote está em
`~/.cache/pz-validate-20261013/`. Antes era `1.22.4-1`.

- O hook pós-transação ressincronizou o runtime de boot do Windows VM; `pz windows-vm status` passou a `ok`, `readyToLaunch: true`.
- Com o pacote instalado, o gravador de dock pode ser rearmado sem depender do merge do #113:
  `systemd-run --user --unit=phasezero-dock-record pz steamdeck dock-record watch`
- O #114 recebeu mais um commit (`6a99db8`, três guardas reescritas para o shellcheck 0.9). CI dessa rodada não conferido.
- A branch `integration/validate-20261013` é só local e descartável; não abrir PR dela.

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

## Atualização — 2026-10-14

Sessão de vigília + implementação das duas lacunas de RAM. Host `misael-jupiter`
sem reboot e com a sessão KDE intacta do começo ao fim (mandato do operador).

### PRs

| PR | Estado ao fechar | Como seguir |
|---|---|---|
| #114 `fix/winvm-memory-and-hermetic` | head `6a99db8`, **CI verde** (confirmado nesta sessão), `MERGEABLE` | Merge é do operador; classificador barra `gh pr merge` para o agente. |
| #116 `fix/winvm-ram-rebase` | **aberto nesta sessão**, base = #114, head `870ff42`. No fechamento: `windows-vm-shell-test`, `lint`, `arch-clean-host`, `compose-validate`, `homelab-python-test`, `hosted-qemu-kvm-probe`, `security-secret-scan`, `scan` verdes; `shell-lint` (0.9.0/0.11.0), `python-test`, `pester` ainda rodando | Mergear **depois** do #114. Reconferir o rollup terminal do SHA `870ff42` antes de merger. |
| #113, #105, #63 | inalterados desde o registro de 2026-10-13 | #113 e #105 prontos para o operador; #63 continua **não mergear**. |

### O que o #116 muda

1. `launch-check`/`status` respondem com memória: `memory:{requestedMb,fit,availableMb,swapFreeMb}` e, quando o veredito é `exceed`, entram como blocker. Antes o JSON dizia `success: true` com a memória ausente (`null`).
2. `PZ_WINDOWS_VM_RAM_MB` pinado num valor que o host não entrega é **re-baseado** para o valor calculado pela regra de `linux/windows-vm/memory.sh`, com aviso que nomeia o número novo. `--ram` explícito e o modo kiosk nunca são re-baseados.
3. `tests/test_provision.sh`: o caso do sentinela do preflight roda com `env -u PZ_TEST_MODE`. Sem isso a suíte dependia do ambiente de quem a chamou (era eu quem estava vazando o sentinela ao rodar `PZ_TEST_MODE=1 bash tests/test_provision.sh`).

Evidência (arquivos estáveis, todos fora do repositório, em
`~/.local/state/phasezero/homologation/winvm-20261013/`):
`baseline-test_provision-6a99db8-clean.log` (295/0 — suíte completa no head do
#114, rodando com `env -u PZ_TEST_MODE`, sem as assertivas novas),
`red-test_provision.log` (299 PASS / 16 FAIL com as assertivas novas antes do
código), `green-test_provision.log` e `final-test_provision.log` (315/0),
`green-linux-windows-vm.log`, `green-session.log`, `green-graphics.log`,
`green-ui.log`. O arquivo `baseline-test_provision-6a99db8.log` é uma tentativa
anterior abortada (292 PASS antes de parar no primeiro caso novo, por
`set -euo pipefail`, e 1 FAIL que era o meu próprio ambiente vazando
`PZ_TEST_MODE`); **não** serve de baseline — use o `-clean`.

Prova no host real com o conf pinado em 12288 MiB: instalado `1.22.5-1` →
`.memory = null`, `success: true`; árvore nova →
`memory:{requestedMb:4096,fit:"fits",availableMb:6402,swapFreeMb:3861}` sem
blocker de memória, com o aviso "a configuração pede 12288 MiB ... a VM vai
iniciar com 4096 MiB".

### A janela de instalação nunca abriu

Regra derivada do próprio código, não inventada: piso do Windows 11 (4096 MiB) +
reserva do perfil desktop (3072 MiB) ⇒ `MemAvailable ≥ 7168` MiB, e ainda PSI
`some avg10 < 10`, nenhum QEMU real rodando e `corruption_errs` estável.

Monitor: unit transiente `pz-winvm-resource-monitor` (user unit), amostra a cada
30 s em `resource-samples.log`, colunas `ts gate need_mb avail_mb total_mb
swap_free_mb psi_some_avg10 load1 io_in_mb io_out_mb qemu top btrfs_corr
reason`. De 2026-10-13 23:13 local (`2026-10-14T02:13:31Z`) até
2026-10-14T09:56Z: **926 amostras `gate=FAIL`, 0 `gate=PASS`**, 1 linha
`gate=INFO`, máx `avail_mb` 6509, mín 2908, PSI sempre < 2, `btrfs_corr`
constante em **603** (nenhuma corrupção nova), nenhum QEMU real. Ler assim:

```
LOG=~/.local/state/phasezero/homologation/winvm-20261013/resource-samples.log
grep -c 'gate=PASS' "$LOG"; grep -o 'avail_mb=[0-9]*' "$LOG" | cut -d= -f2 | sort -n | tail -1
```

Dois registros saíram com `reason=qemu-running` por stubs de teste
(`/tmp/tmp.*/bin/qemu-system-x86_64` do `linux-windows-vm.sh`); o filtro agora
exige `/proc/<pid>/exe` realmente qemu. A unidade foi rearmada às
2026-10-14T09:40:43Z e a lacuna de ~2 min está marcada no log como `gate=INFO`.

Quem segura a RAM que falta: o processo do próprio agente (`qoder` 1,1–1,6 GiB)
e `electron` (~0,9 GiB). Faltaram ~1,7 GiB no melhor momento; só o operador
libera.

### Inventário de lacunas (nada disso está resolvido)

- **`PZ_WINDOWS_VM_ISO` está errado.** O conf aponta
  `/home/misael/Downloads/Win11_25H2_BrazilianPortuguese_x64_v2.iso` (não
  existe). As mídias boas: `/home/misael/ISOs/Win11_25H2_BrazilianPortuguese_x64_v2.iso`
  e `/home/misael/Downloads/Win11_25H2_BrazilianPortuguese_x64_v2 (1).iso`, ambas
  com `sha256 50fe4703cf0df0072e093d1f5d58ed450e4c49d8ca960433bbe6278d5ef10107`
  e 8 172 068 864 bytes — verificado nesta sessão, mesmo hash do plano tirado da
  ISO real. Ou seja: a instalação falha por caminho, não por mídia. Corrigir o
  conf **com backup antes**, ou passar `--iso` no `plan`.
- `preflight.sh:208` `resource_check()` ainda deriva `RAM_MB` de **MemTotal**
  (o plan JSON mostra `preflight.resources.ramMb: 14820` ao lado de
  `resources.memory.availableMb: 6291`). Não corrigi — mudança de comportamento
  pede aprovação por unidade.
- Perfil de energia do host está em `performance`; origem não verificável
  (`journalctl` do `power-profiles-daemon` sem entradas a partir de
  2026-10-13T20:00). O #114 restaura o perfil na saída do `launch`, mas um
  `launch` morto no meio deixa o valor para trás.
- Staging `op-20260923-225352-18359` = **40 GB** em
  `~/.local/state/phasezero/windows-vm/vms/`. **Não remover** antes de o
  operador abrir a VM instalada pela interface.
- 969 arquivos órfãos de plano em
  `~/.local/state/phasezero/windows-vm/provision/plans/`. Lixo de suítes
  antigas; não limpo.
- `/home` com 161 GB livres (83% usado).
- Continua **não validado**: instalação nova a partir da ISO; `launch` real no
  desktop (diálogo de senha do `phasezero-admin`); boot direto pelo GRUB
  (WBR-005/006); ciclo remover → reinstalar (WBR-003); cópia de `tpm/` no
  `finalize` sem teste hermético; `status` ainda marca `boot-runtime-stale`.
- Teste `tests/test_windows_vm_ui.py::test_windows_vm_page_reflows_without_cut_cta`
  falha neste host. **Atribuído, não consertado**: reproduzi num checkout limpo
  de `6a99db8` em worktree descartável, então é pré-existente e dependente de
  host, com CI verde.
- LUX-033: o gravador de dock era unit transiente e o reboot de 2026-10-13 o
  matou. Rearmar após mergear o #113
  (`systemd-run --user --unit=phasezero-dock-record python3 linux/steamdeck/dock_input_record.py watch`);
  ainda não existe nenhum registro de undock.

### Como retomar a instalação

> **Esta seção foi executada em 2026-10-15 e o item 1 está invalidado.** Ler
> "Atualização — 2026-10-15 (instalação completa rodou)", mais abaixo, antes de
> repetir qualquer passo.

1. Com `avail ≥ 7168` confirmado no log (ou fechando aplicativos até isso):
   ```
   pz windows-vm provision plan --iso /home/misael/ISOs/Win11_25H2_BrazilianPortuguese_x64_v2.iso --json
   pz windows-vm provision start --plan-id <id> --confirm <confirmToken>
   ```
2. Em paralelo, num terminal: `pz windows-vm provision watch` e
   `~/.local/state/phasezero/homologation/winvm-20261013/install-watch.sh <op>`.
3. Antes de qualquer `finalize`: backup de `~/.config/phasezero/windows-vm.conf`
   (a sessão de 2026-10-13 não teve backup e o `finalize` antigo não levava
   `tpm/`).
4. Registrar a linha no ledger de `docs/roadmaps/winvm-boot-resilience-v1.md`.

## Atualização — 2026-10-15 (instalação completa rodou)

Sessão Qoder (`claude-session a4227094`), continuando o #116. O host reiniciou às
2026-10-15 19:51 local sem pedido meu antes desta faixa (a vigília anterior
parou junto com a unidade transiente); nada foi reiniciado nem fechado depois
disso, e a sessão KDE (`seat0`, `startplasma-wayland` pid 5907) permaneceu
intacta durante a instalação inteira.

### Resultado

A instalação nova do Windows **concluiu de ponta a ponta**, sem root, a partir da
árvore do #116 (`/mnt/sdcard/Projects/pz-winvm-ram-rebase`, head `d761000`), com
ISO íntegra em `/home/misael/ISOs/Win11_25H2_BrazilianPortuguese_x64_v2.iso`
(sha256 `50fe4703cf0df0072e093d1f5d58ed450e4c49d8ca960433bbe6278d5ef10107`).

| passo | evidência |
|---|---|
| plano | `plan-20261015-224202-27493`, `ramMb:4096` explícito, `memory.fit:"fits"`, `blockers:[]` — `~/.local/state/phasezero/homologation/winvm-20261013/plan-20261016.json` |
| start | `op-20261015-224232-10324` em `start-20261016.json`, worker `setsid nohup`, `state=running` |
| fim | `01:42:32Z` → `02:20:27Z` (38 min), `state=completed checkpoint=relaunch progress=100`, os 10 checkpoints em `done` |
| payload | disco realocado 19 G, `allocatedBytes:20987645952`, snapshot `golden-clean.qcow2`, QGA no relaunch reportando SO e rede OK, drivers virtio exit 0 |

Para reler o estado terminal de qualquer shell:

```
jq -r '"\(.state) \(.checkpoint) \(.progress) \(.checkpoints)"' \
  ~/.local/state/phasezero/operations/op-20261015-224232-10324/operation.json
```

### O gate de 7168 MiB estava errado por excesso

Eu defini `MemAvailable ≥ 7168` (piso 4096 + reserva 3072) como janela mínima
para instalar e vigiei 2 800+ amostras contra ele. A corrida prova que o limiar
é conservador demais: a instalação inteira rodou com `MemAvailable` mínimo de
**1166 MiB**, sem nenhum OOM-kill, sem PSI alto (máx 15,12) e sem erro de disco.
O que segurou foi o que o próprio código já calcula — `fits` = RAM da VM ≤
`MemAvailable` — mais o zram, que o host expandiu sozinho três vezes durante a
corrida (`dmesg`: `Adding … swap on /dev/zram0`, `zram1`, `zram3`).

Consequência prática: o gate de vigília deve ser re-derivado do
`windows_vm_memory_fit` em `linux/windows-vm/memory.sh`, não da soma
piso+reserva. **Não mudei o gate nem o código de sizing** — é mudança de
comportamento e precisa de aprovação por unidade.

Contagens reconciliadas (três samplers independentes sobre a mesma janela):

```
L=~/.local/state/phasezero/homologation/winvm-20261013
awk '$1>="2026-10-16T01:42:00Z" && $1<="2026-10-16T02:21:00Z"' $L/resource-samples.log | wc -l   # 78, todos gate=FAIL
grep -c '^2026' $L/guard-op-20261015-224232-10324.log                                             # 111
grep -c 'op=op-20261015' $L/install-watch-op-20261015-224232-10324.log                             # 69
awk '$1>="2026-10-16T01:42:00Z" && $1<="2026-10-16T02:21:00Z"' $L/resource-samples.log | \
  grep -o 'avail_mb=[0-9]*' | cut -d= -f2 | sort -n | sed -n '1p;$p'                               # 1166 / 5911
grep -o 'btrfs_corr=[0-9]*' $L/guard-op-20261015-224232-10324.log | sort -u                         # só 603
```

### Nada pré-existente foi tocado

- conf: md5 `f90148ad19668141fd2b01b65a962012`, igual ao backup
  `windows-vm.conf.bak-20261015T200748` tomado antes de começar.
- discos ativados: `~/VirtualMachines/PhaseZero-Windows-20260923-225352-18359/phasezero-windows.qcow2`
  continua com mtime `2026-10-13T01:10`; `adoptedDiskExists:false` na operação nova.
- `finalize` **não foi rodado**. Ele achata 19,5 GB e chama `windows-vm.sh adopt`,
  que reescreve conf e disco — fica com o operador presente.
  `provision pending-finalize` já lista a operação.

### Lacunas abertas por esta corrida

1. `preflight cache SHA mismatch (expected=e14cf2b9… cached=4fcae9c9…)` obriga
   re-download de 753 MB de virtio em cada instalação (43 s + banda). O hash
   pinado e a cache do host divergem permanentemente.
2. QGA reporta `Windows 10 Home` para uma ISO Windows 11 25H2. É o nome de
   produto que o agente devolve, não uma verificação de SKU; `guestLoginVerified`
   continua em aberto e nada nesta corrida fecha isso.
3. A resolução do fim da fase `setup` é o poll de 30 s de `run_setup`: o heartbeat
   de 1800 s e o `QEMU exited` caíram no mesmo sample, então o término real do
   convidado está em (1770 s, 1800 s].
4. `install-watch.sh` mede `qcow_bytes` pelo glob
   `~/VirtualMachines/PhaseZero-Windows*/phasezero-windows.qcow2`, ou seja, o
   disco **ativado**. Durante uma instalação ele mostra o disco velho congelado
   (38,6 GB constantes) enquanto o staging crescia. O número real desta corrida
   veio de `qemu-img info`/`du` direto em `$vm_dir`. O sampler precisa apontar
   para o staging da operação. **Corrigido no sampler** (2026-10-16, mesmo
   diretório): `qcow_bytes()` agora prefere
   `qemu-img info --output=json …/vms/$OP/disk.qcow2` e só cai no glob ativado
   quando não há staging. Verificado fora do loop: função nova devolve
   `19904008192` (o mesmo `actual-size` que o rollup do awaiter registrou), a
   antiga devolve `38679740416` (o disco de setembro).
5. Espaço: staging novo 19,5 GB somado ao `op-20260923-225352-18359` de 42,7 GB.
   `/home` foi de 147 GB para 128 GB livres. Nenhum dos dois removíveis antes de
   o operador confirmar que abre a VM pela interface.

### Estado no fechamento

A VM relançada está de pé com janela GTK (`qemuPid 988752`, RSS ~4,1 GiB,
`-display gtk`, graphics `compat`/QXL) para o operador abrir. Unidades de
usuário: `pz-winvm-resource-monitor.service` ativa; `pz-winvm-install-guard` e
`pz-winvm-install-watch` encerraram sozinhas ao estado terminal, como projetado.
Artefatos novos em `~/.local/state/phasezero/homologation/winvm-20261013/`:
`plan-20261016.json`/`.err`, `start-20261016.json`/`.err`,
`guard-op-20261015-224232-10324.log`, `install-watch-op-20261015-224232-10324.log`,
`await-op-20261015-224232-10324.log`, `install-guard.sh`, `await-install.sh`,
`dmesg-baseline-op-20261015-224232-10324.txt`.

### O que a tela mostra

`winvm-after-install.png` (e `-2.png`, dois instantes a ~1 min) foi capturado com
`spectacle -n -b`, sem qualquer automação de ponteiro. Nela a janela GTK da QEMU
mostra o **desktop do Windows já renderizado**: papel de parede do 25H2, ícones
de Área de Reciclagem e Microsoft Edge, sem tela de login — ou seja, o
`guestLogin: auto` do plano entregou sessão aberta. Continua sendo evidência de
imagem, não de interação: nada nesta sessão clicou na VM.

Um diálogo "Fatal Error — Unrecognized switch --help" aparece no canto da
captura e **não é da VM**: o host roda Wine (`wineserver` pid 10318,
`winedevice.exe`, e a ponte MT5 `mt5_bridge_server.py`), e o MetaEditor 5 está na
área de trabalho. Registrado para o próximo agente não atribuir isso ao
provisionamento.

### Como continuar daqui

1. Conferir na janela GTK já aberta o que só o operador valida: resolução, teclado
   pt-BR, áudio e se a sessão está realmente logada (a captura mostra desktop sem login).
2. Decidir o `finalize` com backup do conf já existente; depois verificar que o
   `tpm/` e o `OVMF_VARS.fd` foram carregados (o teste `6fd7c69` cobre a cópia, a
   UI ainda não cobre o resultado).
3. Mergear #114 e depois #116 (head `d761000`) com o rollup terminal do CI no SHA
   pinado.
4. Rearmar o gravador LUX-033 depois do #113 e decidir o caminho de `PZ_WINDOWS_VM_ISO`.

## Atualização — 2026-10-16 (os dois P0 da ativação, e um commit que carregava um stub)

Os dois P0 da revisão do operador estão implementados no PR #116, head
`c86df85ca417a19f50c59300ddf61f90f47bba5c`. Nada do host foi mutado nesta rodada:
nenhum `finalize`, nenhum shutdown, nenhum reboot, sessão KDE ativa, QEMU da
instalação nova ainda de pé (`pid 988752`), e os dois staging intactos
(`op-20260923-225352-18359` 40 G, `op-20261015-224232-10324` 42 G).

### P0 — a instalação pendente parou de ficar invisível

`status --json` emitia `install-awaiting-activation` **só** quando a VM configurada
estava quebrada. Com uma VM funcionando, a instalação concluída desaparecia da
tela e a única ação oferecida era iniciar a antiga. Agora o finding sai
independentemente da saúde da VM configurada, com a frase "Duas máquinas virtuais
existem: a que está configurada segue em uso, e a instalação concluída
`<op>` aguarda ativação", e o registro pendente carrega a prévia dentro de
`.provision.pendingFinalize`. Na página, a instalação vira uma **segunda
instância** com rótulo próprio e botão "Ativar instalação", visível apenas quando
a operação não está rodando; o caminho antigo (uma única instalação pendente,
nada configurado) continua igual.

Prova no host real, somente leitura (`status-after-p0.json`,
`preview-after-p0.txt`): `readyToLaunch:true` **junto** do finding, com
`pendingFinalize{operationId:op-20261015-224232-10324, running:true,
requiredBytes:23790485504, freeBytes:109038714880, fits:true}`, e
`provision finalize --preview` imprimindo origem/destino/substitui/espaço
("101 GiB livres para 22 GiB") e recusando porque a QEMU da instalação ainda está
ligada — exatamente o aceite pedido.

### P0 — ativação agora tem prévia e volta

`adopt` (dono da troca) grava `windows-vm.conf.bak-<UTC>-<pid>` antes de reescrever
o conf e restaura esse backup se a instalação do launcher falhar; `write_config`
troca o arquivo por um único `mv` em vez de escrever em place. `finalize`
(dono do achatamento) ganha `--preview`, calcula bytes necessários/livres no
destino, nomeia o disco substituído, e limpa o disco órfão de uma meia-troca. O
caminho do conf agora tem um único dono: `windows-vm.sh config-path`, consultado
por `provision.sh` em vez de re-derivar.

Teste com erro injetado: `install -d` do launcher derrubado por um arquivo onde a
pasta deveria existir → conf restaurado byte a byte, `adoptedDisk` vazio no
registro da operação, retry depois da correção ativa o disco novo. Ao escrever o
teste apareceram dois defeitos reais de produção, corrigidos: `install_user_files`
devolvia o status do `pz_info` final (uma adoção incompleta seria reportada como
instalação completa — sem atalho na área de trabalho e sem unidade systemd), e o
`2>&1` misturava INFO no envelope JSON (a asserção passou a ler o registro
durável `operation.json`).

### O CI vermelho não era teste — era o índice

`bd5de03` commitou `linux/windows-vm/windows-vm.sh` como um **stub de duas
linhas** (`#!/usr/bin/env bash` + `echo "{}"`), 4095 linhas a menos. O disco tinha
o script inteiro, então `test_provision.sh` dava 359/0 localmente enquanto
`windows-vm-shell-test` morria em 31 segundos e `python-test`/`shell-test`
falhavam junto. Comparação `4a9e30c` (verde) → `cd6cde7` (vermelho) sem nenhum
assertion quebrado no host apontou o índice, não o código. Corrigido em
`80e93f1`.

**Regra nova para os próximos agentes**: verificar o **blob commitado**, não só o
arquivo em disco, e rodar as suítes contra a árvore exportada antes de fazer
push. Controle feito nesta rodada: `git show HEAD:linux/windows-vm/windows-vm.sh |
wc -l` = 4135, `bash -n` limpo, `config-path` e `config_backup` presentes no blob,
e `git archive HEAD` extraído para um diretório vazio rodando com `env -i`
(HOME vazio, `LANG=C.UTF-8`) → `test_provision.sh` **359/0** e
`linux-windows-vm.sh` **exit 0** (`green-headexport-test_provision.log`,
`green-headexport-linux-windows-vm.log`).

### Shell-lint do aceite: verde

O item "P0 para merge" (SC2031 em `tests/test_provision.sh`, 0.9.0 e 0.11.0) está
resolvido: o `# shellcheck source=` dentro do subshell foi removido em `4a9e30c`,
`shell-lint (0.9.0)` e `shell-lint (0.11.0)` completaram sem falha, e o
ShellCheck local com as exclusões do CI dá 0 findings (SC2031 = 0).

### Lacuna nova, no caminho de boot: `rescue.sh` precisava de `USER`

`vm_rescue_scan_isos`/`vm_rescue_scan_disks` montavam as bases de mídia removível
com `$USER`. A sessão de boot chama essas funções sob `set -u`, e um serviço
systemd não exporta `USER` — o wizard abortava antes de listar ISO ou disco,
justamente o caso para o qual existe. Reproduzido com o nome fora do ambiente
(`red-rescue-user.log`: `rescue.sh: linha 59: USER: variável não associada`),
corrigido com fallback `USER → LOGNAME → id -un` e preso por um teste que faz
`unset USER` dentro da varredura (`green-rescue-user.log`, suite inteira exit 0).
Nenhum outro uso de `$USER` no caminho do Windows VM: `windows-vm.sh:21` já usa
`PZ_TARGET_USER → SUDO_USER → USER → misael`.

### Números desta rodada

`test_provision.sh` 359/0 (antes 355/5, depois 358/1); `test_windows_vm_ui.py` 34
passed; `test_linux_native_ui.py + test_windows_vm_ui.py` 62 passed;
`linux-windows-vm.sh`, `linux-windows-vm-graphics.sh`,
`test_windows_vm_remove.sh`, `test_windows_vm_session.sh`,
`test_provision_recovery.sh`, `test_boot_runtime_notice.sh`,
`linux-autounattend.sh`, `linux-guest-recovery.sh` exit 0;
`linux-audit-doctor.sh` 9/0; ShellCheck com as exclusões do CI 0 findings.

### O que ainda não está provado

A **ativação real** nunca rodou: achatar os 19,5 GB e trocar o disco em
`~/VirtualMachines` é decisão do operador com ele presente. A prévia, o backup e o
rollback são provados hermeticamente e a recusa está provada no host — isso não é
evidência de que a troca completa funciona numa máquina real. Continuem em aberto
os quatro P1 (fonte única de versão/URL/hash do virtio; `PZ_WINDOWS_VM_ISO`
apontando para `~/Downloads` inexistente; política de memória por perfil com
margem e pressão observada, porque `fits` sozinho não é limite seguro; teste físico
de interação/SKU com captura e interação separadas) e o P2 (instrumentação
versionada no repositório, mais fina que o poll de 30 s). A matriz física de boot
direto (WBR-005/006, teclado, desligamento gracioso pelo GRUB) também segue
aberta — a instalação pela janela GTK não fecha esses gates. WBR-009 foi
**adicionado** à matriz (IDs nunca se reutilizam) como `in_progress`.

### Como continuar daqui (2026-10-16)

1. Confirmar o rollup terminal do CI em `c86df85…` no log
   `~/.local/state/phasezero/homologation/winvm-20261013/ci-rollup-c86df85.log`
   antes de qualquer merge — inclusive `arch-clean-host`.
2. Validar interação na janela que já está de pé (teclado, áudio, resolução,
   login persistente, edição do Windows), mantendo captura e interação como
   evidências separadas.
3. Desligar a nova VM de modo limpo, rodar `provision finalize --preview` e, com o
   operador presente, a ativação; conferir o `windows-vm.conf.bak-*` criado.
4. Mergear #114 e depois #116 (head `c86df85`).
5. Depois: fonte única do virtio, caminho da ISO no conf, política de memória,
   instrumentação do staging.

## Atualização — 2026-10-16 (reboot do operador, o vermelho restante, e uma reprodução local que não valia)

### Estado do host depois do reboot

O operador reiniciou o host por outros motivos e pediu para prosseguir. A QEMU da
instalação nova terminou por SIGTERM do systemd (shutdown orderly, não queda de
energia); `qemu-img check` no `golden-clean.qcow2` de 23,8 GB não reporta erros
(`postreboot-imgcheck-golden-clean.log`). Staging intactos:
`op-20260923-225352-18359` (40 G) e `op-20261015-224232-10324` (42 G). O conf ainda
aponta o disco antigo, sem `windows-vm.conf.bak-*` novo, sem `finalize`, sem
ativação. MemAvailable 6 118 MiB, PSI `some avg10=0.12`, nenhuma QEMU.

Consequência honesta para o aceite do P0-1: **"desligamento limpo da nova VM" não
foi cumprido pelo reboot** — o convidado foi morto pelo systemd, não desligado
dentro do Windows. A ativação continua sendo decisão do operador, com ele presente.

Refinamento do achado P1 da ISO: o caminho exato do conf
(`~/Downloads/Win11_25H2_BrazilianPortuguese_x64_v2.iso`) não existe, mas
`~/Downloads/Win11_25H2_BrazilianPortuguese_x64_v2 (1).iso` existe com o mesmo
tamanho (8 172 068 864) da cópia em `~/ISOs`. A validação da prévia não pode ser
só "existe?": precisa conferir SHA-256 e nomear a candidata vizinha.

### O que restava vermelho, e não era o SC2031 do aceite

Em `c86df85` fecharam 3 jobs distintos: `shell-lint (0.9.0)`, `shell-lint (0.11.0)`
e `windows-vm-shell-test`. O lint não era SC2031 — era **SC2015 meu**, criado na
rodada anterior ao escrever `A && B || C` no teste do `USER`
(`tests/linux-windows-vm.sh:1348`); o job fica vermelho para qualquer finding,
inclusive de informação. No `windows-vm-shell-test`, as 5 assertions da seção de
rollback falhavam com o conf intacto e nenhuma linha de "configuração restaurada"
— assinatura de uma falha **anterior** ao backup, não da falha injetada.

### Uma reprodução local que não provava nada (registrada para não repetir)

A rodada anterior afirmou ter reproduzido o vermelho mascarando a firmware com
`unshare -rm` + tmpfs sobre `/usr/share/edk2`. **Essa reprodução é inválida**, por
dois motivos verificados agora:

1. `/usr/share/OVMF` continuava visível, e é o 2º/3º caminho que
   `ovmf_vars_template` sonda — a máscara não removia a dependência.
2. Dentro de `unshare -r` o processo é root do namespace, então `cmd_adopt` cai no
   ramo `runuser -u misael` / `setfacl -m u:misael:rw`; esses uid estão mapeados lá
   fora e desmapeados lá dentro, e o `setfacl` morre com `Argumento inválido`. As
   mesmas 5 falhas, por um motivo que não existe no runner.

Mascarar a firmware continuando uid 1000 (`unshare -m --user --map-users=...`) não
pegou neste host (`newgidmap: gid range [1000-1001) not allowed`), então o proxy
local foi abandonado em favor de um teste direto do mecanismo.

### O mecanismo, provado sem namespace

`probe-ensure-vm-storage.sh` extrai `ensure_vm_storage` do script real e
sobrescreve `ovmf_vars_template` para devolver vazio — que é o que um runner sem
edk2 é — rodando como usuário normal:

- sem `OVMF_VARS.fd` no destino → `ERROR: OVMF_VARS template missing`, rc=1,
  **antes** de qualquer backup do conf;
- com o arquivo presente → rc=0.

Bate na assinatura do CI, e é consistente com `provision.sh:1422`, que cria
`$vm_dir/OVMF_VARS.fd` em toda instalação real: o staging de verdade sempre traz o
arquivo; o fixture não. **Comportamento de produção inalterado** — recusar
ativação num host sem firmware é correto; quem mentia sobre o staging era o teste.

### Correções (head novo: `c7ed0bc`)

O fixture passa a carregar `OVMF_VARS.fd` e `tpm/tpm2-00.permall` no staging e a
fixar `PZ_WINDOWS_VM_OVMF_CODE` nas duas chamadas de `finalize` (precedente já
existia na linha 788). `tests/linux-windows-vm.sh` fica sem SC2015.

### Controles na árvore commitada (`git archive HEAD`)

- `test_provision.sh` 359/0; `linux-windows-vm.sh` exit 0 com "rescue scans survive
  USER being unset"; suítes irmãs `test_windows_vm_remove.sh`,
  `test_windows_vm_session.sh`, `test_provision_recovery.sh`,
  `test_boot_runtime_notice.sh` exit 0.
- Loop de lint do CI sobre os **253 scripts** da árvore exportada: 0 falhas.
- No working tree, sem máscara: `test_provision.sh` 359/0 (`green-firmware-test_provision.log`).
- Artefatos: `mechanism-ensure-vm-storage.log`, `blob-green-*.log`,
  `blob-test_windows_vm_*.log`, `ci-rollup-c7ed0bc.log`,
  `ci-terminal-c7ed0bc.log`.

### Rollup terminal do CI em `c7ed0bc`: verde

`ci-terminal-c7ed0bc.log`: **35 checks, 35 completed, 33 success, 2 skipped,
0 failure**. Os três jobs que fecharam vermelhos em `c86df85` estão verdes —
`shell-lint (0.9.0)`, `shell-lint (0.11.0)`, `windows-vm-shell-test` — e com eles
`arch-clean-host` e `pester`, que a rodada anterior ainda precisava confirmar. O
waiter (`ci-rollup-c7ed0bc.log`) estourou o teto de 30 passadas com 2 checks
pendentes às 13:48Z; a leitura terminal acima é posterior e independente dele. Os
dois `skipped` são condicionais por design (`Sourcery review`;
`hosted-qemu-kvm-probe`, que neste mesmo SHA também aparece com `success` em outra
run, porque o nome se repete entre re-runs). **O aceite "CI integralmente verde no
SHA final antes da sequência de merges" está cumprido em `c7ed0bc`.**

### O que ainda não está provado

A ativação em si (achatar e trocar o disco de 19,5 GB) e a validação física de
interação/SKU. O reboot também **não** conta como desligamento limpo. Seguem
abertos os quatro P1 e o P2, e a matriz física de boot direto (WBR-005/006,
teclado, GRUB).

### Como continuar daqui (a partir de `c7ed0bc`)

1. Merge liberado pelo CI: rollup terminal verde em `c7ed0bc`
   (`ci-terminal-c7ed0bc.log`), incluindo `arch-clean-host` e `pester`. Isto
   substitui o passo 1 da seção anterior, que apontava para `c86df85`.
2. Desligar a nova VM **por dentro do Windows** para satisfazer o pré-requisito de
   desligamento limpo; a janela que existia acabou com o reboot. **Superado pela
   seção 4 desta atualização:** a origem do finalize é o `golden-clean.qcow2`, que
   passou no `qemu-img check` hoje e é mais novo que a última escrita do
   convidado, e o código só exige que nenhum `qemu-pid` esteja vivo. Ligue o
   convidado de novo apenas se a decisão for validar interação primeiro.
3. `provision finalize --preview` e ativação com o operador presente; conferir o
   `windows-vm.conf.bak-*` criado.
4. Mergear #114 e depois #116 (head `c7ed0bc`), #113, #105. **Fazer isso antes do
   passo 3, não depois:** `git grep -c "windows-vm.conf.bak-" origin/main` não dá
   hit, ou seja, o backup automático e o rollback da troca existem só no `c7ed0bc`
   e não no que está releaseado. Ativar antes do merge é rodar a troca pelo caminho
   antigo, sem `windows-vm.conf.bak-*` — exatamente o P0 que a revisão apontou.
   Não localizei a cópia instalada do script (`pz` resolve para o wrapper
   `/usr/bin/pz`; nada de `windows-vm.sh` sob os caminhos de share habituais), então
   confirmar qual código a ativação executa é passo prévio obrigatório.
5. Depois: fonte única do virtio, caminho/SHA da ISO no conf, política de memória
   por perfil, instrumentação do staging no repositório.

## Atualização — 2026-10-16 (estado real da ativação e o gate de memória derivado do código)

Duas correções materialmente relevantes para quem for mergear ou rodar o finalize.

### 1. A instalação pendente não é mais a que este handoff descrevia

`windows-vm.sh status --json` lido agora (somente-leitura) responde:

- `pendingFinalize.operationId` = **`op-20261015-224232-10324`**, `completedAt`
  `2026-10-16T02:20:27Z`, `running:false`.
- origem: `~/.local/state/phasezero/windows-vm/vms/op-20261015-224232-10324/golden-clean.qcow2`
- destino: `~/VirtualMachines/PhaseZero-Windows-20261015-224232-10324/phasezero-windows.qcow2`
- **substitui** o disco `~/VirtualMachines/PhaseZero-Windows-20260923-225352-18359/phasezero-windows.qcow2`
- `requiredBytes` 23 809 490 944, `freeBytes` 108 271 542 272, `allocatedBytes`
  44 505 047 040, `fits:true`.

Ou seja, o "disco de 19,5 GB" citado acima está superado: a operação hoje
pendente é a de 15/10, e a VM **configurada** é a de 23/09 — 256 GiB virtual,
36 GiB alocados, `corrupt:false`, sem backing file (`qemu-img info -U`, leitura
sem writer). O `windows-vm.conf` não é escrito desde `2026-10-13T01:10:30-03:00`,
anterior a qualquer ação desta sessão, e os únicos backups continuam sendo
`bak-20260811223635` e `bak-20260912144514` (mais o `.pre-25h2`) — a troca com
backup automático ainda não aconteceu porque o código que faz isso está no
`c7ed0bc`, não mergeado.

O aceite do P0-1 já está no produto deste PR: o mesmo `status --json` emite o
finding `install-awaiting-activation` ("Duas máquinas virtuais existem: a que
está configurada segue em uso, e a instalação concluída op-20261015-224232-10324
aguarda ativação", `action: windows.provision.finalize`) junto de
`readyToLaunch:true`. Falta conferir a superfície da UI (`windows_vm.py:624`),
não a do script.

### 2. O gate de vigília agora é a aritmética do próprio `memory.sh`

`memory.sh` dimensiona o convidado subtraindo a reserva do perfil
(`PZ_WINDOWS_VM_HOST_RESERVE_MB`: 3072 desktop, 2048 kiosk), mas julga o start
por outra regra: `fits` se `ram <= MemAvailable`, `tight` se coberto por
`SwapFree`, `exceed` só acima disso; e no kiosk devolve `fits` incondicional.
A reserva entra no tamanho e nunca no veredito. Ensaios com
`PZ_WINDOWS_VM_MEMINFO_FILE` (arquivo íntegro em
`vigil-gate-derived.log`, gerado por `derive-vigil-gate.sh` sobre `c7ed0bc`):

- piso observado do instalador (avail 1166, swap 5120, PSI 15,12): `fit(4096)` =
  **`tight`**, headroom **−2930 MiB**. `windows_vm_memory_guard` retorna 0, isto
  é, `tight` **aprova** o start.
- instante do `launch-check` de hoje (avail 4304): `fit(4096)` = **`fits`**,
  headroom **208 MiB**, e o `launch-check --json` respondeu `success:true`.
- fronteira nua: avail 4096 com ram 4096 = `fits` (0 MiB para a sessão);
  avail 4095 = `tight`; avail 4095 **sem swap** = `exceed`. A mesma demanda de
  RAM muda de veredito conforme o backing de swap, não conforme a memória.
- kiosk com avail 1166 e `SwapFree` 0: `fit(14000)` = **`fits`**. No GRUB o
  veredito não verifica nada.

Isso é a prova do aceite "uma corrida bem-sucedida não prova que `fits` sozinho
seja limite seguro": ele é correto como *aritmética de instante* e incorreto
como *limite*, porque não reserva, não olha pressão e, no kiosk, não olha nada.

O `resource-monitor.sh` fora do repositório foi re-derivo no lugar de ajustar
número: ele faz `source` do `memory.sh` do worktree, tira `GUEST_MB` do
`default_ram_mb` e a reserva do perfil, e grava na mesma amostra o veredito do
produto ao lado do gate. Amostra real após a mudança
(`resource-samples.log`, formato novo a partir das linhas antigas):

```
2026-10-16T15:33:59Z gate=FAIL need_mb=7168 guest_mb=4096 reserve_mb=3072 mode=desktop avail_mb=5432 total_mb=14820 swap_free_mb=3624 product_fit=fits psi_some_avg10=0.00 ... reason=mem<7168,product-says-fits
```

`reason=product-says-fits` é a divergência sinalizada: o host não sustenta o
convidado **mais** a reserva, e o produto ainda diz que cabe. As notas do próprio
produto vão para `product-notices.log`. `shellcheck` com as exclusões do CI:
rc=0 (corrigi também um SC2046 pré-existente no `set -- $(pgpg)`).

### Consequência para a política por perfil (P1)

A forma derivada, que já é a do produto sem inventar constante: aprovar start
somente com `MemAvailable - ram >= reserva(perfil)`, tratar `tight` como
reprovado sem margem, e exigir o PSI como segundo eixo — nada disso está no
`memory.sh`, e por isso o gate de vigília hoje é mais estrito que o produto.
Ficar só no monitor inverte quem protege quem: a correção tem que descer para
`memory.sh` com teste próprio, na fila que o operador já definiu (depois do
finalize, junto de virtio e ISO).

Nada foi mutado no host nesta rodada: nenhum `finalize`, nenhuma ativação,
nenhum shutdown, nenhuma VM em execução (`qemu=none` nas amostras), os dois
staging intactos.

### 3. A ISO do conf: o problema é nome, não conteúdo

`PZ_WINDOWS_VM_ISO` aponta para `~/Downloads/Win11_25H2_BrazilianPortuguese_x64_v2.iso`,
e esse arquivo **não existe**. Existem dois outros, e os dois têm o **mesmo
SHA-256** (`iso-candidate-hashes.log`):

- `50fe4703cf0df0072e093d1f5d58ed450e4c49d8ca960433bbe6278d5ef10107`
  `~/Downloads/Win11_25H2_BrazilianPortuguese_x64_v2 (1).iso` (8 172 068 864)
- `50fe4703cf0df0072e093d1f5d58ed450e4c49d8ca960433bbe6278d5ef10107`
  `~/ISOs/Win11_25H2_BrazilianPortuguese_x64_v2.iso` (8 172 068 864)

Então o P1 se estreita: não falta ISO, falta o caminho apontar para uma, e o
plano iniciado pela UI falharia por nome. Isso também muda o aceite da prévia —
checar só existência é fraco aqui, porque há dois arquivos de conteúdo idêntico
e o conf não corresponde a nenhum dos dois nomes; a prévia precisa resolver o
caminho, conferir o SHA e nomear o candidato vizinho de mesmo hash. Não há
motivo para re-download.

### 4. A prévia do finalize está verde e a origem é íntegra

`provision.sh finalize --preview --latest` (lido o despacho: o ramo `--preview`
retorna antes do `provision_lock_acquire`, portanto não escreve; saída em
`finalize-preview-20261016.json`):

```
origem:    ~/.local/state/phasezero/windows-vm/vms/op-20261015-224232-10324/golden-clean.qcow2
destino:   ~/VirtualMachines/PhaseZero-Windows-20261015-224232-10324/phasezero-windows.qcow2
substitui: ~/VirtualMachines/PhaseZero-Windows-20260923-225352-18359/phasezero-windows.qcow2
espaço:    99 GiB livres para 22 GiB
status:    pronta para ativar   (running:false, fits:true)
```

Sobre o pré-requisito de desligamento limpo, com os números na mão:

- a origem que o finalize achata é o snapshot, não o disco do convidado.
  `qemu-img check -U golden-clean.qcow2` → "No errors were found on the image",
  rc=0, 23 809 490 944 bytes, 8,66% alocado — exatamente o `requiredBytes` da
  prévia.
- o `golden-clean.qcow2` tem mtime **2026-10-16 08:19 local** e o
  `disk.qcow2` da instalação tem mtime **2026-10-15 23:19 local**: o snapshot é
  **posterior** à última escrita do convidado, então ativar a partir dele não
  descarta trabalho feito depois.
- o código do finalize não exige histórico de desligamento gracioso: ele exige
  que o `qemu-pid` do staging não esteja vivo (`kill -0`), e o `pid 988752` está
  morto. O `session.lastGraceful:true` no `status --json` é do registro anterior
  (2026-09-15), não prova nada sobre esta operação.

Leitura honesta: o reboot do operador não deu desligamento limpo ao convidado,
mas o que ele protege — imagem suja e escritor concorrente — não se aplica à
origem desta ativação, que é um snapshot verificado hoje e mais novo que o disco
vivo. Decidir com esse critério é do operador; a prévia está pronta e eu não
ativei nada.

## Atualização — 2026-10-16 (a linha da ISO fechada, e um `fits` que não provava nada)

Dois commits no head do PR #116, cada um com seu teste primeiro.

### 5. ISO do conf: `3a4e633`

Aceite do P1 era "Atualizar caminho com backup e validar existência/hash na
prévia". O que está no código (`linux/windows-vm/windows-vm.sh`):

- `effective_config` só confia no `PZ_WINDOWS_VM_ISO` do conf enquanto o
  arquivo existir. Não existindo, emite
  `WARN: configured Windows ISO does not exist, ignoring it: <caminho>` — ou
  seja, nomeia o caminho morto que foi descartado — e cai para a detecção. Um
  `--iso` explícito continua acima de tudo.
- `write_config` virou fail-closed com backup automático: `cp -p` da versão
  atual para `<conf>.bak-<UTC>-<pid>` **antes** do rename, e recusa sobrescrever
  se o backup falhar (`could not back up <conf>; refusing to overwrite it`).
  Isso cobre toda reescrita de configuração, não só o finalize.
- `plan --verify-iso` calcula o SHA-256 do caminho escolhido e nomeia o
  candidato de mesmo hash (`verify_iso_preview`, que reutiliza o
  `media-inspect.sh scan --json` em vez de varrer o disco de novo). O hash é
  opt-in de caso pensado: 8 172 068 864 bytes custam ~30 s neste host, e o
  `plan --json` é o envelope que a UI pergunta em poll — por isso `--verify-iso`
  junto de `--json` emite
  `WARN: --verify-iso applies to the text plan only; the JSON envelope does not hash the ISO`
  em vez de virar um nada silencioso.

Evidência no host, caminho durável
(`~/.local/state/phasezero/homologation/winvm-20261013/plan-verify-iso-20261016.log`):

```
WARN:  configured Windows ISO does not exist, ignoring it: /home/misael/Downloads/Win11_25H2_BrazilianPortuguese_x64_v2.iso
  iso: /home/misael/Downloads/Win11_25H2_BrazilianPortuguese_x64_v2 (1).iso (present)
  iso_sha256: 50fe4703cf0df0072e093d1f5d58ed450e4c49d8ca960433bbe6278d5ef10107
  iso_same_hash: /home/misael/ISOs/Win11_25H2_BrazilianPortuguese_x64_v2.iso
plan rc=0
```

Os três pedidos da seção 3 — resolver o caminho, conferir o SHA, nomear o vizinho
de mesmo hash — estão respondidos, e não houve re-download.

Estreitamento honesto do aceite: a prévia **padrão** valida existência; o hash
só vem com pedido explícito. Foi decisão registrada, não omissão — a razão é o
custo de 30 s no caminho que a UI consulta.

Consequência que precisa ser dita: um `adopt` sobre conf existente passa a
deixar **dois** `<conf>.bak-*` — o do `cmd_adopt`, que já salvava e restaurava
quando `install_user_files` falhava, e o do `write_config`. Mantive os dois:
o do `adopt` protege a troca inteira e o do `write_config` protege o próprio
rename. A leitura de `cmd_adopt` (windows-vm.sh:2990-3049, somente-leitura nesta
sessão) é o que confirma a promessa que o finalize fazia por palavra sobre o
adopt.

Testes: `tests/linux-windows-vm.sh` casos 80–97 (caminho morto não é confiado,
`--iso` explícito preservado, prévia diz `present`/`missing`, backup do
`write_config`, hash só com pedido, vizinho nomeado, e o aviso no `--json`).
O RED real foi `exit 97` — `--verify-iso ignorada no --json sem aviso`. Antes
disso eu mesmo quebrei o teste duas vezes: `jq -e '.iso'` (o envelope não tem
`iso` no topo, é `vm.iso`/`vm.isoExists`) e `.vm.isoExists == "yes"` quando o
valor é booleano; isso era erro meu de teste, não lacuna do produto, e ficou
registrado como tal.

### 6. Prévia do finalize: `bcb5173`

Achado na fila do P1 de memória ("`fits` sozinho não prova limite seguro"), mas
em outro caminho de código. O `provision_finalize_preview` comparava
`requiredBytes` contra o espaço livre do destino. Só que a origem mora em
`$XDG_STATE_HOME/phasezero/windows-vm/vms/<op>/golden-clean.qcow2` e o destino
em `$HOME/VirtualMachines/` — nada liga os dois, então o snapshot registrado
pode simplesmente não existir mais na hora da decisão. Nesse estado o
`requiredBytes` saía 0, o `fits` comparava 0 contra o espaço livre e a prévia
respondia "há espaço" e "pronta para ativar" sobre uma cópia que o próprio
`finalize` recusa ("verified snapshot missing").

Agora `originExists` é campo do envelope e porta o `fits`; o texto diz
`(AUSENTE)` na origem, "espaço: indeterminado sem a origem" e
"status: a origem verificada não existe; finalize recusaria — nada foi
copiado". O `rm -f` é no fixture, não no host: `tests/test_provision.sh` estende
o bloco `FP_*` e afirma os dois estados (origem presente → `originExists:true`,
`fits:true`; origem sumida → `originExists:false`, `fits:false`, texto com
`AUSENTE`).

Relido no host com o código corrigido, após a prévia (somente-leitura; o ramo
`--preview` retorna antes do `provision_lock_acquire`, então não escreve), em
`finalize-preview-origin-20261016.txt` e `.json` no mesmo diretório de
evidências:

```
origem:   .../op-20261015-224232-10324/golden-clean.qcow2
destino:  ~/VirtualMachines/PhaseZero-Windows-20261015-224232-10324/phasezero-windows.qcow2
substitui: ~/VirtualMachines/PhaseZero-Windows-20260923-225352-18359/phasezero-windows.qcow2
espaço:   95 GiB livres para 22 GiB
status:   pronta para ativar
```

`originExists:true`, `requiredBytes:23809490944`, `freeBytes:102267215872`,
`fits:true`, `running:false`. O `--latest` hoje resolve **esta** operação
(`op-20261015-224232-10324`, `completed`, `adoptedDisk:null`). O `freeBytes`
diverge da captura da seção 1 (108 271 542 272 → 102 267 215 872) porque o host
gravou entre as duas; a diferença é de espaço livre, não da origem.

### Dois erros meus, registrados para não se repetirem

- `pgrep -c -f qemu-system-x86_64` devolveu 1 e eu disse que havia uma VM: o
  `grep` casava com a própria linha de comando do wrapper. `ps -C
  qemu-system-x86_64` não mostra nada — não havia.
- Procurei o `golden-clean.qcow2` com `find ~/VirtualMachines`, não achei, e
  chamei a origem da ativação de "sumida". Ela está em
  `~/.local/state/phasezero/windows-vm/vms/<op>/`. Foi erro meu de escopo, não
  defeito do host; a origem existe nas duas operações (set/23: 23 334 420 480
  B; 15/10: 23 809 490 944 B).

### Verificação desta rodada

`tests/linux-windows-vm.sh` rc=0; `tests/test_provision.sh` PASS 371 FAIL 0;
`shellcheck` 0.11.0 rc=0 com as exclusões do CI; 7 suítes adjacentes
(`linux-windows-vm-graphics`, `linux-windows-vm-host-access`,
`linux-windows-container-frontends`, `test_provision_recovery`,
`test_windows_vm_remove`, `test_windows_vm_session`) rc=0, log em
`adjacent-test_provision-20261016.log` e
`adjacent-linux-windows-vm-graphics-20261016.log`.

### Estado do host ao fechar

`qemu_running=0`, MemAvailable 5 238 MiB, sessão KDE ativa, os dois staging
intactos e o snapshot da operação pendente íntegro. Nenhum `finalize`,
nenhum shutdown, nenhum reboot, nenhuma alteração no host, nenhuma
senha/persistente de sudo criada. Os `windows-vm.conf.bak-20260811223635` e
`bak-20260912144514` pré-existentes não são meus — minhas corridas não criaram
backup no diretório real de configuração.

### O que continua aberto

1. Merge na ordem já avisada: **#116 antes de qualquer ativação**, senão a
   troca roda sem o backup que este PR conserta. Head atual `bcb5173`.
2. UI: confirmar `windows_vm.py:624` na superfície (o script já emite o
   `install-awaiting-activation` junto de `readyToLaunch:true`).
3. Finalize com o operador presente — tarefa #7. Evidência de desligamento
   limpo continua sendo power-cycle, não algo que eu possa fabricar.
4. P1 de memória: a política por perfil descida ao `memory.sh` (margem derivada
   da reserva, `tight` reprovado, PSI como segundo eixo) com teste próprio.
5. P1 de interação/SKU: `guestLoginVerified` segue `false`; QGA responde
   "Windows 10 Home".
6. Virtio: a fonte única está commitada (`5c8dc9f`, `382d43e`), mas
   `guest/Install-VirtioFS.ps1:47` e `guest/vendor/vendor.json:12-13` ainda
   buscam o `stable-virtio/virtio-win-gt-x64.msi` flutuante; e o cache do host
   (`4fca…`) ≠ confiado (`e14c…`), então um `--auto-fix` real agora recusa o
   cache e re-baixa o ISO pinado (~240 MB).
7. P2: instrumentação do staging versionada no repositório.

---

## Atualização — 2026-10-16 (tarde): o `fits` que não provava nada, fechado no `memory.sh`

Fecho o item 4 da lista acima. Aceite pedido: *"Política por perfil com margem e
pressão observada; ensaios repetidos, incluindo host sem expansão automática de
zram."* A política está no repositório e testada; **os ensaios repetidos com
zram fixo continuam abertos** — ver o fim da seção, porque isso é alteração de
host e depende do operador.

### O que estava errado, lido no código

Três defeitos distintos, todos no mesmo eixo:

1. `windows_vm_memory_fit` respondia `fits` **sem verificar nada** no boot por
   GRUB (`kiosk`). Não havia leitura de `MemTotal`, não havia reserva: qualquer
   número virava `fits`.
2. A reserva do perfil existia só na **derivada** (`default_ram_mb`: 3072 no
   desktop, 2048 no kiosk). O veredito nunca a consultava. Um convidado de 4096
   com `MemAvailable` 5300 era `fits`, embora sobrassem 1204 MiB para um host
   que prometeu 3072 à sessão.
3. PSI não era lido em lugar nenhum. `MemAvailable` é um instante; no Deck de
   2026-10-16 ele chegou a 1166 MiB com `some avg10` em 15,12 enquanto o
   veredito se mantinha `fits`.

### A política agora em `linux/windows-vm/memory.sh`

Dois eixos, um veredito, vocabulário preservado (`fits|tight|exceed`) para que
nenhum consumidor precisasse mudar:

- `windows_vm_profile_reserve_mb` (novo) — a reserva passa a ter **uma**
  definição, usada pela derivada e pelo veredito. `default_ram_mb` perdeu os
  dois literais.
- `windows_vm_memory_margin_mb` (novo) — a base é por perfil: desktop mede
  contra `MemAvailable`, GRUB/kiosk contra `MemTotal`. O que sobra depois do
  convidado é a margem.
- `windows_vm_psi_some_avg10` + `windows_vm_memory_pressure_high` (novo) — eixo
  de pressão, limite `10.0`, ajustável por `PZ_WINDOWS_VM_PSI_SOME_MAX`.
- `windows_vm_memory_fit` reescrito: `exceed` continua sendo o teto físico
  (`MemAvailable + SwapFree`, ou `MemTotal` no kiosk); `tight` agora também
  significa *margem abaixo da reserva do perfil* **ou** *pressão acima do
  limite*. O `fits` só existe quando os dois eixos estão quietos.
- `windows_vm_memory_notice` nomeia **qual** eixo falhou: mantém a frase de
  swap, e acrescenta `"a folga depois do convidado é N MiB e a reserva do
  perfil X é M MiB; o convidado cabe, o resto do host não"` e
  `"pressão de memória no host: some avg10=… acima do limite …; adiar a
  inicialização é o que protege a sessão"`.

**Hermeticidade** (`windows_vm_pressure_file`, novo): `PZ_WINDOWS_VM_PRESSURE_FILE`
descreve a pressão do host simulado; quando só o `meminfo` é fixture, a
resolução cai em `/dev/null` — linha nenhuma lida, que lê como *"pressão não
medida"*. Sem isso, a carga do runner do CI poderia mudar um veredito, o que é
exatamente o tipo de teste que passa localmente e falha aleatoriamente.

**Semântica do gate não mudou** — decisão consciente:
`windows_vm_memory_guard` continua recusando apenas `exceed`. Em `tight` avisa
com as duas contas. Endurecer para recusar `tight` mudaria o comportamento de
inicializações que hoje funcionam, com o operador ausente; isso é decisão dele,
com os números dele embaixo.

### Onde a conta aparece

`marginMb` e `reserveMb` viajam com o veredito em vez de serem rederivados em
três lugares:

- `linux/windows-vm/provision.sh` — `.memory` do plano em JSON.
- `linux/windows-vm/windows-vm.sh:2735-2741` — `.memory` do `launch-check`.
- Vocabulário antigo (`fit`, `availableMb`, `swapFreeMb`) intacto.

Lacuna honesta descoberta ao ligar isso à UI: **`linux/ui_native/` não tem
nenhum consumidor de `.memory`** (`grep` por `memoryFit|availableMb|marginMb|tight|exceed`
não acha nada além de comentários sem relação). O veredito nunca apareceu no
GTK, e continua não aparecendo. Não é regressão deste batch; é a mesma família
do P0 de visibilidade (`windows_vm.py:624`).

### Testes, incluindo os dois erros meus

Seção nova `=== memória: margem por perfil e pressão observada, não só o
instante ===` em `tests/test_provision.sh`, 20 asserções, TDD com 12 RED antes
de qualquer mudança de produção. Cobre: margem cobrindo reserva → `fits`; o
instante real de 2026-10-16 (total 14820 / avail 5432 / swap 3624, convidado
4096) → `tight` **e** o texto de "reserva" no stderr; PSI 15,12 com margem boa →
`tight` **e** o texto de "pressão"; PSI 0,40 → `fits`; reserva menor (`1024`) →
`fits`; kiosk 12288 → `fits`, 14000 → `tight`, 15000 → `exceed`; hermeticidade
do arquivo de pressão; plano com `fit=tight`, `reserveMb=3072`, `marginMb=1336`;
`launch-check` carrying os mesmos números; e a asserção de que um `tight` **não
gera blocker** — o guard mantém o significado.

**Um pin virou de propósito.** `re-based to the floor: ... fits` virou
`re-based to the floor: still inside the reserve, so tight`, com a aritmética no
comentário (5300 − 4096 = 1204 < 3072). A asserção antiga era verdade sob a
política velha e mentira sob a nova; mantê-la verde teria escondido exatamente o
defeito que este batch fecha.

**Dois erros meus no teste, ambos revelados por ferramenta, não por sorte:**

1. `assert_eq ... "$(bash -c '... p="$(windows_vm_pressure_file)" ...')" )` —
   as aspas duplas internas fechavam o contexto do `bash -c` aninhado:
   `encontrado EOF inesperado enquanto procurava por '"'`. Corpo agora montado
   por `printf` numa variável e passado como `bash -c "$MP_PF_BODY"`. A asserção
   também parou de ser vacua: compara o caminho resolvido (`/dev/null`), não a
   string "não é o /proc".
2. A forma `VAR= bash -c` acendeu **SC1007** no shellcheck 0.11, e o
   `tests/test_provision.sh` ficou vermelho no lint outra vez — o mesmo arquivo
   do P0-para-merge. Corrigido com `env VAR= ...`, que tira a atribuição da
   posição que o shellcheck interpreta.

Verificação desta rodada: `tests/test_provision.sh` **PASS 390 FAIL 0** rc=0
(`test_provision-memory-policy-20261016.log`), `tests/linux-windows-vm.sh` rc=0
(`linux-windows-vm-memory-policy-20261016.log`), `bash -n` ok nos quatro
arquivos, shellcheck 0.11.0 com os excludes do CI (`SC1090,SC1091,SC2034,SC2154,SC2155,SC2312`)
limpo nos quatro. Suítes adjacentes que consomem `memory.sh`, todas rc=0 no log
`adjacent-20261016-memory-policy.log`: `linux-audit-doctor`,
`linux-autounattend`, `linux-guest-recovery`, `linux-windows-vm-graphics`,
`linux-windows-vm`, `test_boot_runtime_notice`, `test_provision_recovery`,
`test_windows_vm_session`.

Commit do batch: `ff00a98` em `fix/winvm-ram-rebase` (head do PR #116),
empurrado. O rollup terminal do CI para esse SHA ainda não foi confirmado — é
item de checklist antes do merge, não algo que eu deva declarar verde antes da
hora.

### O que a política nova diz no host real, agora

Somente leitura, `memory-policy-host-20261016.log`, 2026-10-16T15:15-03:00:

```
MemTotal 15176264 kB · MemAvailable 6097612 kB · SwapFree 3815904 kB
psi_memory some avg10=0.01 · configured PZ_WINDOWS_VM_RAM_MB=12288
boot_mode=desktop · reserve_mb=3072 · default_ram_mb=4096
fit(default)=tight
```

Ou seja: a configuração instalada (12288, herdada de um boot GRUB) não cabe no
desktop que está de pé; `windows_vm_configured_ram_mb` re-baseia para 4096 —
e o 4096, que ontem era `fits`, agora é `tight` porque a folga (5954 − 4096 =
1858) está abaixo da reserva prometida (3072). Continua **permitido**: o
`tight` é aviso. **A decisão de recusar `tight` para de inicializar é do
operador**, e este é o cenário exato em que ela aparece — ele consegue abrir a
VM, e o aviso diria que a sessão paga por isso. Nota do mesmo log: ~5,9 GiB de
swap já em uso com `qemu_procs=0`, ou seja, a pressão não é do convidado.

### Continua aberto neste eixo

- **Ensaios repetidos, incluindo host sem expansão automática de zram** — não
  feito. `zram` dobrou de tamanho durante a instalação de 2026-10-15/16 e foi
  exatamente isso que sustentou o `fits` errado. Repetir a corrida com
  `zram-tools`/`zramswap` sem expansão automática é mexer no host, e o operador
  pediu para isso acontecer com ele presente.
- Recusar `tight`, se ele quiser o gate endurecido. Um `PZ_WINDOWS_VM_*` novo
  seria a forma; sem ele, o comportamento fica como está.
- A margem/reserva na superfície da UI, junto do P0 de visibilidade.

### Risco de processo descoberto (vale para quem rodar suítes em paralelo)

`tests/linux-audit-doctor.sh` **reescreve arquivos vivos do repositório**:
`stub_repo_file` faz `cp $f $f.bak` e depois sobrescreve `$f` com um mock
(`tests/linux-audit-doctor.sh:26-32`), restaurando no `trap EXIT`
(`:15-24`). Durante a corrida, `git status` mostra ~20 arquivos modificados com
milhares de deleções e `linux/*/..*.bak` soltos, e um `git add -A` feito nesse
instante **comitaria os mocks**. Consequência prática: commit só depois da
suíte terminar, sempre por caminho explícito. Foi assim que este batch foi
commitado; a asserção que fiz no meio da corrida (`windows-vm.sh` = 4203 linhas
com `memoryMarginMb` em 2735) provou que o round-trip é lossless.
