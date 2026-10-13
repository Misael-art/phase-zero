# WinVM 1.20.8 — janela pequena, teclado e controles

## Evidência de 2026-09-15

Host: `misael-jupiter`, BigLinux/Manjaro, Steam Deck LCD. Diagnóstico de
logs e metadados; nenhuma VM iniciada e nenhum reparo de disco executado.

| Item | Evidência | Conclusão |
|---|---|---|
| Runtime | `/usr/local/lib/phasezero/windows-vm-runtime/provenance.json`: versão `1.20.8`, origem `/usr/lib/phasezero`, instalado `2026-09-14T11:00:46-03:00` | Runtime foi atualizado; aviso de repo configurado não prova runtime antigo |
| Handheld | `session.log`, 14/09 15:32:53: Gamescope, `1280x800`, QEMU `launch --fullscreen --graphics virtio-gl --experimental`, `NO CURSOR IMPL XDG` | Fullscreen solicitado, mas cliente GTK usa caminho Wayland nativo; foto mostra janela decorada |
| Dock | `session.log`, 15/09 12:10:17: DP-1, `2560x1080`, mesmo caminho gráfico e erro XDG | Mesmo defeito de apresentação; resolução efetiva do Windows ainda não medida |
| Teclado | `touch-input.log` datado de 12/09, JSON antigo com `state:timeout` sem duração | Não representa resultado dos boots recentes; sessões de 151s e 63s terminam antes do prazo de 420s |
| Controle | Logs recentes: `raw usb-host passthrough` | Host selecionou USB Valve; isso não comprova enumeração no Windows nem execução de `SteamController.exe` |
| Disco | Kernel 15/09 12:10:50–53: `csum failed root 257 ino 12372912`; QEMU: `aio failed: Erro de entrada/saída` | Erros reais de leitura, independentes da janela pequena |

`stat` confirma inode **12372912** no arquivo:

```text
/home/misael/VirtualMachines/PhaseZero-Windows-20260820-050749-32490/phasezero-windows.qcow2
```

`findmnt` confirma `/home`, `/dev/nvme0n1p2[/@home]`, subvolume 257,
`btrfs`, `compress-force=zstd:3`. Contador Btrfs `corrupt 603` é cumulativo;
não significa 603 arquivos corrompidos. Causa física (RAM, SSD ou caminho de
I/O) ainda não determinada. Integridade estrutural qcow2 não garante leitura
correta dos blocos do Windows.

## Correção preparada

- Sessão Gamescope remove `--expose-wayland` e inicia filho com
  `env GDK_BACKEND=x11`. Assim QEMU GTK usa Xwayland, caminho gerenciado pelo
  XWM para escala e fullscreen. Configuração limitada ao filho do Gamescope.
- Política touch escreve `pending` no início, substituindo resultado antigo;
  registra `interrupted` quando sessão termina antes da conclusão.
- Helper QGA recebe tempo restante como timeout. Resultado de timeout distingue
  socket ausente de tentativa de política sem sucesso. Prazo padrão segue 420s.

Essas alterações corrigem configuração de apresentação e observabilidade.
Não consertam blocos ilegíveis, não instalam drivers no Windows e não provam
funcionamento físico do teclado ou Steam Deck Controller.

Fontes técnicas: [seleção do backend GTK](https://docs.gtk.org/gtk3/running.html),
[Gamescope/Xwayland](https://github.com/ValveSoftware/gamescope/wiki),
[atalhos Steam Controller](https://github.com/ayufan/steam-deck-tools/blob/main/docs/shortcuts.md).

## Ordem de recuperação e validação

1. Preservar dados importantes em armazenamento independente. Cópia/reflink no
   mesmo Btrfs não resolve blocos compartilhados ilegíveis.
2. Diagnosticar armazenamento e RAM conforme bloqueio WBR já registrado em
   `winvm-boot-resilience-v1.md`: scrub de diagnóstico somente leitura, SMART
   atualizado e memtest fora da sessão. Planejar janela operacional para I/O
   pesado/reboot. Não usar `btrfs check --repair` ou recriar VM como tentativa.
3. Recuperar imagem a partir de cópia íntegra caso os blocos sejam
   irrecuperáveis. Alterar cache ou desativar compressão não restaura dados.
4. Depois do gate de armazenamento, integrar correção no pacote e sincronizar
   runtime pelo fluxo canônico `pz windows-vm boot install`; não sobrepor
   arquivos instalados manualmente com um checkout.
5. Boot Handheld: conferir 1280×800 **dentro do Windows**, tela toda ocupada,
   ausência de decoração GTK e novo `touch-input.log` com sucesso.
6. Dentro do Windows, confirmar dispositivo Valve `VID_28DE&PID_1205`,
   `SteamController.exe` em execução e dispositivo reconhecido no Steam Deck
   Tools. Só então validar STEAM+X. USB selecionado no host não fecha esse gate.
7. Repetir Dock; comparar resolução/refresh do Windows com monitor selecionado.

Para acesso manual ao teclado, Windows permite ativar ícone em
Configurações → Personalização → Barra de tarefas → Teclado virtual → Sempre.
Isso oferece acionamento por clique, sem depender do atalho do controle.
[Instruções Microsoft](https://support.microsoft.com/en-us/windows/get-to-know-the-touch-keyboard-004f3d67-855b-27f0-6f7c-d5145f691181).

## Handoff

- Fase/IDs: WBR-005/006, correção e diagnóstico; nenhum item marcado verified.
- Branch: `codex/winvm-handheld-1208`.
- Worktree: `/mnt/sdcard/Projects/pz-winvm-handheld-1208`, base `d4a8bec`.
- Estado host antes/depois: runtime 1.20.8 preservado; VM parada; disco,
  GRUB e pacote não modificados. Bloqueio Btrfs permanece aberto.
- Testes aprovados: `bash tests/linux-windows-vm.sh`,
  `bash tests/test_windows_vm_session.sh`, `bash -n`, `git diff --check` e
  ShellCheck dos três scripts alterados com exclusões da CI
  (`SC1090,SC1091,SC2034,SC2154,SC2155,SC2312`). A suíte principal inclui
  helper travado com orçamento de 10s e interrupção antes do socket QGA.
- Ajuste hermético adicional: suíte principal agora usa arquivo cmdline vazio;
  antes herdava `phasezero.windowsvm-display=external` do boot real deste host
  e invalidava teste de seleção interna. Precedência de produção preservada.
- CI/remoto: não executados; sem commit, push, release ou instalação.
- Risco restante: correção gráfica exige validação física; teclado/QGA e
  atalhos não podem ser confirmados com disco produzindo erros de leitura.
