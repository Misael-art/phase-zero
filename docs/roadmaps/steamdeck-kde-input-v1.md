# Steam Deck KDE input v1

## Desktop resilience — 2026-10-29

Frente atual: branch registrada `codex/clean-host-dev-bootstrap`, base `c3a384e3`, mesmo
checkout canônico. Escopo solicitado: boot direto KDE, Steam → desktop,
RetroFE/emuladores → desktop, teclado USB/mouse, teclado virtual, trackpads,
touchscreen, áudio e microfone. Restrições da sessão histórica abaixo continuam
históricas; esta intervenção não executa reboot, logout, restart de KWin/SDDM,
GRUB ou VM. Não há release nem merge autorizados por estes testes.

### Diagnóstico e hipóteses

| Caminho | Evidência neste host | Resultado |
| --- | --- | --- |
| Touchscreen FTS3528 / I²C | Boot de 29/10 16:28 registra `AMDI0010:01: controller timed out`; dispositivo I²C existe sem driver, sem nó FTS em `/proc/bus/input/devices`; power control `auto`, runtime `suspended` | Falha anterior ao KDE. Causa elétrica/firmware do timeout ainda não demonstrada. Retry restrito preparado; não aplicado sem entrada física utilizável para autenticação. |
| USB físico / dock | `usbhid` e xHCI carregados; sem blacklist ou regra local desabilitando teclado/mouse; nenhum teclado/mouse USB externo enumerado na coleta. Hub e storage aparecem/desconectam no journal | Não há prova de grab nem de defeito USB resolvido. Cabo, alimentação, hub, enumeração e estágio login/desktop precisam de teste com periféricos conectados. |
| Mapper do desktop | Unit antiga executava daemon diretamente, contornando checks de conflito no login. Arquivo de sessão do RetroFE era tratado como dono vivo sem identidade | Unit passa pelo supervisor; entrega controle ao Steam/jogo e retoma após saída. Boot ID + start ticks evitam PID reutilizado; filhos de emulador mantêm lease. |
| Microfone | Perfil Pro Audio expõe PCM, mas `Int Mic` e `DMIC Enable` estavam off. UCM `HiFi (Mic, Speaker)` disponível após reboot | Preferir perfil UCM observado; fallback Pro Audio habilita apenas controles ALSA observados. Não confundir fonte enumerada com voz inteligível. |
| Áudio | JamesDSP padrão estava mudo e em 0%; preferência não coberta pelo guardião anterior | Saídas local e JamesDSP desmutadas; volume zero elevado para 35%. Snapshot anterior preservado no ledger de backups. Preferências saudáveis persistem por nome, não por índice PipeWire. |
| Teclado virtual | Provider Plasma carregado; modo 1, `visible=false`. Ajuste D-Bus para modo 2 produziu `visible=true`, sem trocar PID do KWin | Configuração persistida. Digitação e campos de apps sem protocolo text-input continuam gates físicos; terminal recebe watcher sem grab, tolerante a hotplug. |
| Recuperação Steam | Falha/API indisponível impedia recuperação do snapshot local de teclado | Recuperar KDE/áudio independentemente; manter backup Steam e repetir sua restauração separadamente. |
| Atalhos desktop | Nove entradas PhaseZero confirmadas em KGlobalAccel neste boot | Preservados. Sem instalar novo esquema nem reiniciar KGlobalAccel. Atalho não comprova evento físico. |
| Proveniência | `pz` não está instalado no PATH; entradas existentes apontam ao checkout. Units de controller/terminal não existiam antes da intervenção | Serviço de recuperação e watcher instalados no usuário, apontando à raiz canônica. Nenhum pacote de produto instalado. |

### Contrato e implementação

`linux/steamdeck/desktop_session.py` é backend do comando existente
`pz steamdeck input`, não outro gerenciador de controles. `input install`
registra `~/.config/phasezero/desktop-session.json` e instala
`phasezero-input-restore.service` em `graphical-session.target`. Preferências
ficam em `~/.local/state/phasezero/desktop-session/preferences.json`, com
escrita atômica e recusa de symlink. Guardião restaura no login/saída do último
consumidor, preserva ajustes intencionais de mute/volume no desktop e recusa
substituir baseline saudável por placa interna desaparecida. Dispositivos
desconectados ficam fora da restauração corrente; preferências permanecem.
Em BigLinux, a unit ordena após a reconciliação inicial de microfone da distro
e WirePlumber, evitando disputar preferências durante o início da sessão.

RetroFE continua dono dos leases e guardiões Steam/KDE existentes. Seu módulo
`desktop_environment.py` registra a preferência imediatamente antes da troca
e usa o mesmo backend ao restaurar. Sem registro PhaseZero, mantém recuperação
standalone existente. Registro inválido ou restauração incompleta preserva o
snapshot e produz erro. Receita reproduzível das alterações externas:
`linux/emulation/retrofe-desktop-recovery.patch`; aplicar somente após backup,
checagem de contexto e com frontend fechado. Não inclui ROM, conta ou mídia.

Recuperação I²C: `bash linux/repairs/reparo-entrada.sh --status` é leitura.
`--persist` requer admin, valida Jupiter, tenta apenas `i2c-FTS3528:00` e só
instala regra/unidade de boot após o nó reaparecer. Unidade usa comandos fixos
do sistema, sem executar checkout gravável pelo usuário como root no boot.
Não desabilita USB nem reassocia controle Valve. Não foi aplicada neste host:
operador informou indisponibilidade de teclado para senha. `bigsudo --help`
abriu um diálogo por comportamento do wrapper; não repetir esse diagnóstico.

### Matriz de aceite

| ID | Implementação / evidência | Estado |
| --- | --- | --- |
| SDK-003 | Backend, baseline persistente, retomada no login e pós-jogo; fixtures de transição e falha; serviço ativo no host | in_progress: cold boot físico pendente |
| SDK-004 | Nenhum grab/reset USB; reabilitação KWin de teclado/ponteiro/touch; teste com USB simulado desabilitado | in_progress: USB físico/login/retirada do dock pendentes |
| SDK-005 | Diagnóstico I²C, retry FTS restrito e persistência preparada; ShellCheck, udev e unit parsing | in_progress: elevação, reparo e toque físico pendentes |
| SDK-006 | UCM Mic preferido, controles fallback, snapshot de áudio, preservação de mute intencional e falha de PipeWire | in_progress: audição/voz e reboot pendentes |
| SDK-007 | Supervisor scc cede ao Steam/jogo; fixture de entrada/saída e encerramento do filho próprio | in_progress: transição física com frontend/jogo pendente |
| SDK-008 | Keyboard modo 2 persistido, provider visível no KWin; watcher presente, tolera touchscreen tardio | in_progress: caractere real em app, terminal e diálogo admin pendente |

### Handoff desta intervenção

- Host físico: BigLinux/Manjaro, Jupiter, PipeWire 1.6.8; kernel cmdline ainda
  contém `steamzero.gamemode=1` embora KDE esteja ativo. Não usar esse flag
  como prova de que Gaming Mode está em execução. SteamZero não foi alterado.
- Antes/depois: teclado provider já carregado → modo 2/visível; áudio mute/0%
  → desmutado/35% onde estava zero; microfone UCM ativo; FTS continua ausente.
  `phasezero-input-restore` e `phasezero-terminal-keyboard` ativos, habilitados
  no login; guardião RetroFE existente preservado. Sem root/reboot/logout.
- Validação: 77 pytest, 14 casos de auditoria isolada RetroFE e cinco suites
  shell (controller, teclado, terminal, serviços desktop e cursor) passaram.
  Receita RetroFE reproduziu quatro fontes alterados byte a byte.
  Auditoria RetroFE tinha erro preexistente de chamada de teste com assinatura
  antiga; chamada corrigida, sem afrouxar a asserção de PID de outro boot.
  Suite shell de controller também dependia do Steam/systemd reais apesar de
  HOME isolado; agora usa comandos fake e confirma timers sem tocar unidades
  reais. Recusa antiga por Steam ativo não conta como gate aprovado.
- Continuidade: código PhaseZero + receita RetroFE em Git; preimagens, hashes,
  testes e limites RetroFE em `Manifests/desktop-session-resilience-20261029.json`
  e histórico `romtool record-artifacts` da raiz emulation.
- Próximo passo físico: confirmar teclado virtual entregando caractere;
  executar reparo FTS `--persist` com bridge oficial; conectar teclado/mouse
  USB; testar login direto KDE, Steam → KDE e última saída de frontend/jogo.
  Só então agendar cold boot com periféricos conectados. Não reiniciar para
  testar enquanto operador não tiver entrada de recuperação confirmada.

Rollback: desabilitar apenas os dois novos serviços de usuário; registro e
baseline PhaseZero podem ser preservados para diagnóstico. Preferências de
áudio anteriores e kwinrc estão no ledger `pz_backup_file`. Reverter arquivos
RetroFE somente se hashes atuais coincidirem com o manifesto, usando preimagens
ou receita reversa. Se futuramente instalados, regra/unidade FTS gerenciadas
podem ser desabilitadas/removidas pelo administrador após checar marcadores;
nunca reiniciar o barramento USB para reverter este reparo.

---

Correção do teclado virtual touch e diagnóstico do cursor no KDE Plasma
Wayland. Não é trabalho de Homelab nem da VM Windows. Não autoriza reboot,
logout, reinício de KWin/Plasma/SDDM, Switch Desktop, alteração de GRUB ou
restart de `phasezero-controller-desktop`.

## IDs

| ID | Assunto | Estado |
| --- | --- | --- |
| SDK-001 | Seleção, migração e recarga do teclado virtual | Corrigido no host. Abertura do painel confirmada pelo usuário em 2026-10-10. Caractere digitado pendente. |
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
`phasezero-control-center` 1.22.1-1. A confirmação de abertura abaixo ocorreu
com `phasezero-control-center` 1.22.4-1 (`version.json` 1.22.4, canal beta,
`builtAt` 2026-10-10T14:21:28Z) já instalado. A sessão 3 e os PIDs do KWin
26018, do `plasma-keyboard` 3821305, do plasmashell 26147 e do controlador
26394 continuavam os mesmos.

| Checagem | Resultado | Não é |
| --- | --- | --- |
| `kwinrc` depois da migração e do flip | `InputMethod[$e]=/usr/share/applications/org.kde.plasma.keyboard.desktop`, `VirtualKeyboardEnabled=true` | Prova de digitação |
| D-Bus `available` / `visible` depois do flip e da restauração `[$e]` | `true` / `false` | Painel aberto |
| Filho do KWin | `plasma-keyboard` (PID 3821305 após o segundo flip) | Teclado utilizável |
| `input-actions.sh status` | provider `plasma-keyboard`, origin `explicit`, action `keep`, open `kwin-available-closed`, fallback onboard `alive-unusable-on-wayland`. `kwinrc` não mudou | Sucesso de toque |
| `forceActivate` sem campo e sobre `kdialog` | `active=true`, `visible=false`. Painel não apareceu. KWin e o processo do teclado permaneceram | Caractere entregue |
| Abertura física, relato do usuário em 2026-10-10 | O painel abriu. Leitura D-Bus seguinte: `available=true`, `visible=false`, `active=false`, `activeClientSupportsTextInput=true`, `mode=1`, `willShowOnActive=false` | Caractere no campo. Captura de `visible=true`. Game Mode. Boot direto |
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

A abertura do painel está confirmada. O restante não marcar como verificado.

1. Abertura: confirmada pelo usuário em 2026-10-10, na sessão 3, com o pacote
   1.22.4-1. O relato foi que o teste funcionou abrindo o teclado. A leitura
   D-Bus feita depois do relato já encontrou o painel fechado (`visible=false`,
   `active=false`) e um cliente com text-input
   (`activeClientSupportsTextInput=true`). Não houve captura de `visible=true`
   nesse instante.
   Caractere: pendente. Falta o usuário confirmar que um caractere entrou num
   campo real, sem encerrar o KDE. Fechar pelo toggle, não por `keyboard close`,
   se o onboard antigo ainda for necessário.
2. Game Mode → Switch Desktop, numa sessão em que encerrar o desktop seja
   aceitável. Anotar o ID da sessão nova. Mover o touchpad direito e gravar
   `pz steamdeck cursor sample 5`. A conclusão só deixa `not-proven` se a
   amostra vir `REL_X`/`REL_Y` e o KWin reportar o mouse habilitado — e mesmo
   assim isso não é a causa de um cursor oculto.
3. Boot direto da VM Windows continua no roteiro `winvm-boot-resilience-v1`.
   Não faz parte deste teste e não foi executado.

## Release

A linha foi cortada no canal beta. `v1.22.2` e `v1.22.3` ficaram sem
release publicada. A confirmação de abertura em 2026-10-10 não promove o
canal para estável: caractere digitado e Game Mode → Switch Desktop
continuam pendentes. A release publicada desta linha, e a que estava
instalada no teste, é a beta `v1.22.4`. Não mover as tags `v1.22.1`,
`v1.22.2`, `v1.22.3` nem `v1.22.4`.

O repositório passou a se chamar `Misael-art/phase-zero`. O CI do Arch
comparava `GITHUB_REPOSITORY` só com `Misael-art/PhaseZero` e falhava antes
de exercitar o pacote. O guarda aceita os dois nomes. `dbus.available` não
identifica qual comando o KWin carregou; o objeto não expõe o caminho.
