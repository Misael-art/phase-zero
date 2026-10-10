# Steam Deck KDE input v1

Correção do teclado virtual touch e diagnóstico do cursor no KDE Plasma
Wayland. Não é trabalho de Homelab nem da VM Windows. Não autoriza reboot,
logout, reinício de KWin/Plasma/SDDM, Switch Desktop, alteração de GRUB ou
restart de `phasezero-controller-desktop`.

## IDs

| ID | Assunto | Estado |
| --- | --- | --- |
| SDK-001 | Seleção, migração e recarga do teclado virtual | Corrigido e medido no host até `available=true`. Painel visível e caractere digitado pendentes. |
| SDK-002 | Cursor depois de Game Mode → KDE | Não comprovado. Instrumento apenas. Sem correção de causa. |

## Causa comprovada (SDK-001)

No host `misael-jupiter` (Steam Deck LCD/Jupiter, BigLinux, KDE Plasma
Wayland, KWin 6.7.4):

- A configuração legada do PhaseZero gravava `InputMethod` simples no desktop
  do Maliit e removia `InputMethod[$e]`. O marcador
  `~/.config/big_enabled_plasma_keyboard` impede o BigLinux de repor o Plasma
  Keyboard.
- O objeto `org.kde.KWin /VirtualKeyboard` não tem a propriedade `enabled`.
  Consultá-la falha. O status antigo tratava a configuração como "Ligado".
- KWin só recarrega `InputMethod` quando outro cliente emite
  `org.kde.kconfig.notify` / `ConfigChanged` no caminho de barramento
  `/kwinrc`, e só se a chave estiver suja. Reescrita em texto e
  `kwriteconfig6 --notify` com o mesmo valor não emitem o sinal.
  `org.kde.KWin.reconfigure` não é esse caminho.
- A sequência que carregou o teclado, sem trocar o PID do KWin: `kwriteconfig6
  --notify --file kwinrc --group Wayland --key InputMethod --delete` e em
  seguida a escrita do desktop do Plasma Keyboard com `--notify`. O
  `dbus-monitor` viu dois `ConfigChanged` para `InputMethod`. `available`
  ficou `true` e `/usr/sbin/plasma-keyboard` nasceu como filho do KWin.
- Devolver `InputMethod[$e]` só em texto, sem `--notify`, manteve
  `available=true` e o mesmo processo do teclado. KWin 6.7.4 lê a chave
  `InputMethod`; o `[$e]` é o formato do BigLinux.

Modo `VirtualKeyboardMode` não foi alterado. `NonMouseInput` (1) só pede
teclado automático quando o último dispositivo foi toque ou caneta. Teclado
do SCController não suprime o painel por si.

## Cursor (SDK-002)

Não houve transição Game Mode nesta inicialização. Não há causa demonstrada
e o mapa não foi alterado nem reiniciado.

O que a sonda passou a ler de verdade:

- `SCController Mouse` é `event17`; `SCController Keyboard` é `event16`.
- A propriedade do KWin é `org.freedesktop.DBus.Properties.Get` em
  `org.kde.KWin.InputDevice`. A forma de método
  `org.kde.KWin.InputDevice.enabled` devolve `UnknownInterface`.
- Depois da correção da leitura: `enabled=true`, `pointer=true` em
  `event17`. Isso não explica um cursor que suma depois do Game Mode.
- O touchscreen `FTS3528` (`i2c-FTS3528:00`, `mouse1`) não é ponteiro externo.
  Nesta medição não havia mouse Logitech em `/proc/bus/input/devices`.
- Conclusão da sonda: `not-proven`. `grabbed=false`, `serviceRestarted=false`.

## Matriz de evidência

Host: sessão `XDG_SESSION_ID=3`, líder `25869`, `sddm`, Wayland, VT 2, KDE.
PIDs que permaneceram os desta sessão: `sddm` 2033, `sddm-helper` 25869,
`startplasma-wayland` 25893, `kwin_wayland` 26018 (início 2026-10-09 14:56:00),
`plasmashell` 26147, `phasezero-controller-desktop` MainPID 26394,
`NRestarts=0`. Onboard 557082 não foi encerrado. Pacote instalado no início:
`phasezero-control-center` 1.22.1-1.

| Checagem | Resultado | Não é |
| --- | --- | --- |
| `kwinrc` depois da migração e do flip | `InputMethod[$e]=/usr/share/applications/org.kde.plasma.keyboard.desktop`, `VirtualKeyboardEnabled=true` | Prova de digitação |
| D-Bus `available` / `visible` depois do flip e da restauração `[$e]` | `true` / `false` | Painel aberto |
| Filho do KWin | `plasma-keyboard` (PID 3821305 após o segundo flip) | Teclado utilizável |
| `input-actions.sh status` | provider `plasma-keyboard`, origin `explicit`, action `keep`, open `kwin-available-closed`, fallback onboard `alive-unusable-on-wayland`. `kwinrc` não mudou | Sucesso de toque |
| `forceActivate` sem campo e sobre `kdialog` | `active=true`, `visible=false`. Painel não apareceu. KWin e o processo do teclado permaneceram | Caractere entregue |
| Sonda do cursor | `mouseEnabled=true`, `mousePointer=true`, conclusão `not-proven`, sem amostra de movimento | Causa do cursor sumir |
| Boot direto e Game Mode → Switch Desktop | Não executados | Verificado |

Cópias locais desta sessão, fora do git: `/tmp/pz-kbd-host/`.

## Rollback

O backup da migração aponta para o `kwinrc` anterior, com Maliit simples:

`~/.local/state/phasezero/backups/5ce34df1b1af3caea450ebd1535dc0c6b6995b3e2560fb0368de8f20243d24aa/kwinrc.bak.1791626099465633167`

`pz steamdeck keyboard revert` restaura o arquivo inteiro a partir desse
backup. A restauração é texto: não emite `ConfigChanged`. O KWin desta sessão
continua com o comando que já carregou até o próximo login ou um novo
`--notify` sujo. Não reverter no meio desta sessão se o objetivo for manter
o Plasma Keyboard carregado.

Pacote anterior, antes de qualquer upgrade desta linha: `phasezero-control-center`
1.22.1-1. Guardar o pacote em cache antes de instalar o novo e voltar com
`pacman -U` desse arquivo se o upgrade falhar. Não copiar runtime à mão para
`/usr/lib/phasezero`.

## Gates físicos pendentes

Não marcar como verificado.

1. Campo de texto real, noutra interação, sem encerrar o KDE. Focar um campo
   que use text-input do Wayland, tocar a tela, confirmar `visible=true` em
   `pz steamdeck keyboard status` e que um caractere chega. Fechar pelo mesmo
   comando de toggle, não por `keyboard close` se o onboard antigo ainda for
   necessário.
2. Game Mode → Switch Desktop, numa sessão em que encerrar o desktop seja
   aceitável. Anotar o ID da sessão nova. Mover o touchpad direito e gravar
   `pz steamdeck cursor sample 5`. A conclusão só deixa `not-proven` se a
   amostra vir `REL_X`/`REL_Y` e o KWin reportar o mouse habilitado — e mesmo
   assim isso não é a causa de um cursor oculto.
3. Boot direto da VM Windows continua no roteiro `winvm-boot-resilience-v1`.
   Não faz parte deste teste e não foi executado.

## Release

1.22.2 sai no canal beta (pré-release). O canal estável exigiria os gates
físicos acima. Não reutilizar as tags `v1.22.1` e `v1.21.1`.

O repositório passou a se chamar `Misael-art/phase-zero`. O CI do Arch
comparava `GITHUB_REPOSITORY` só com `Misael-art/PhaseZero` e falhava antes
de exercitar o pacote. O guarda aceita os dois nomes. `dbus.available` não
identifica qual comando o KWin carregou; o objeto não expõe o caminho.
