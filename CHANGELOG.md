# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).
As versões seguem a data de build em `version.json`.

## [1.22.2] - 2026-10-10

### Corrigido
- **Teclado virtual do KDE no Steam Deck apontava para o Maliit e lia uma propriedade D-Bus que não existe.** A configuração legada gerida pelo PhaseZero (`InputMethod` simples no desktop do Maliit, sem `InputMethod[$e]`) passa a migrar para o Plasma Keyboard quando esse desktop está instalado. Uma escolha explícita válida fica como está. O status separa configuração, disponibilidade no D-Bus e abertura efetiva. Onboard ou wvkbd vivo no Wayland não conta como teclado aberto.
- **Reescrever o `kwinrc` não recarregava o método de entrada do KWin 6.7.** O compositor só observa o sinal `org.kde.kconfig.notify` / `ConfigChanged` no caminho `/kwinrc`, e o KConfig só emite esse sinal quando a chave muda. `kwriteconfig6 --notify` com o mesmo valor é silencioso. O reparo apaga a chave e grava de novo, os dois com `--notify`, e devolve `InputMethod[$e]` em texto, sem novo sinal. Medido nesta sessão: o KWin (PID estável) passou a ter o `plasma-keyboard` como filho e `available=true`.

### Adicionado
- **Diagnóstico somente leitura do cursor na volta do Game Mode.** `pz steamdeck cursor` registra nós do SCController, o serviço do mapa e se o KWin enxerga o mouse virtual. Não captura o dispositivo, não reinicia o mapa e não reinicia o KWin. Sem amostra de movimento a conclusão fica `not-proven`.

### Limitações
- Digitar num campo real e a volta Game Mode → Switch Desktop não foram executados: o primeiro precisa de toque, o segundo encerra a sessão. Canal beta. O procedimento está em `docs/roadmaps/steamdeck-kde-input-v1.md`.

## [1.21.1] - 2026-09-23

### Adicionado
- **Mapa do controle compatível com o Ashyterm.** O terminal da BigCommunity troca de aba com `Ctrl+PageUp/PageDown` e entrega `Ctrl+Tab` ao shell, então L1/R1 do mapa desktop não faziam nada visível nele. Um perfil derivado (`PhaseZero-Ashyterm`) troca só as abas, lendo os atalhos efetivos do Ashyterm — padrões mais o `~/.config/ashyterm/settings.json` do usuário, sem escrever nele —, e um serviço de usuário preso ao do mapa (`phasezero-controller-apps.service`) segue a janela em foco via `kdotool` e alterna o perfil pelo `scc set-profile`, sem reiniciar o daemon. Atalho desativado no Ashyterm mantém o botão do mapa desktop e avisa. A tabela de aplicativos (`linux/steamdeck/controller_apps.py`) aceita outros programas com atalhos próprios.

### Corrigido
- **Instalação Windows abandonada podia permanecer `running` para sempre.** O supervisor registra identidade de processo resistente a reutilização de PID, separa o worker, libera descritor de lock nos processos filhos e reconcilia operação órfã como interrompida, preservando arquivos para retomar ou remover.
- **Inventário ocultava staging parcial e remoção não recuperava operações presas.** Instalações interrompidas, falhas e cancelamentos passam a aparecer com espaço ocupado, retomada, lixeira e liberação permanente confirmada; QEMU vivo bloqueia mutação.
- **Seletor de edição usava índice global e não inspecionava a mídia escolhida.** O diálogo lê índices da ISO de forma assíncrona e associa conclusões ao SHA-256 da mídia; reinstalar a mesma edição fica permitido.
- ISO válida com WIM/ESD que não pôde ser interpretado não sugere índice 1 nem opções fictícias: pede o índice manual exato. ISO inválida bloqueia o início.
- **O mapa do controle sumia quando a sessão gráfica piscava.** A unit declarava `PartOf=graphical-session.target` mas `WantedBy=default.target`: o pareamento era de mão única, então uma sessão que reinicia por segundos — o Plasma se reiniciando basta — derrubava o mapa e nunca o trazia de volta. Medido num Deck real: `graphical-session.target` inativo às 09:46:42, ativo de novo às 09:47:00, e o mapa morto por onze horas sem erro em lugar nenhum. As duas diretivas passam a nomear o mesmo alvo, e um teste recusa que divirjam. O `Restart` também virou `always`: o daemon já saiu 0 sozinho depois de perder o controle, e `on-failure` trata isso como fim normal e deixa o Deck sem ponteiro. `StartLimitBurst` evita trocar um silêncio por um laço.
- **O `stop` prometia o retorno do lizard mode, que não volta.** Assumir o controle o desprende do `hid-steam`, e devolvê-lo deixa a emulação de mouse e teclado do firmware desligada — o Deck medido ficou só com o nó de gamepad, sem handler de mouse algum. A mensagem passa a dizer o que acontece de fato e como recuperar o ponteiro.
- **`confirm` deixava para trás o link de enable da unit anterior.** `systemctl enable` só cria o link do alvo que a unit nomeia hoje; quem atualizava ficava com os dois e o serviço subia também fora da sessão gráfica. O `confirm` passa a remover os antigos antes de habilitar.
- **O teste do temporizador de reversão era sensível à carga da máquina.** Esperava um tempo fixo enquanto a limpeza ainda parava o serviço e disparava o aviso de OSD; falhava 1 em 5 execuções com uma VM ocupando sete vCPUs. Passa a aguardar o estado, com prazo.

### Testes
- Suíte hermética de recuperação no CI; `test_provision.sh`, suíte de remoção e testes Qt.
- A validação de instalação, desligamento, remoção, reinstalação e aceleração no Steam Deck exige execução física e medição no Windows; continua pendente.

## [1.21.0] - 2026-09-23

### Corrigido
- **A prévia de 159 ações que alteram o sistema era só uma leitura de estado, mas o diálogo dizia "Preview concluído".** A prévia de estado passa a se identificar ("isto não simula a mudança") e mostra o que aplicar vai fazer antes do campo CONFIRMAR. Ações de alto risco sem simulação real exigem texto de impacto — o catálogo recusa a ausência (LUX-001).
- **Esc cancelava a operação em andamento sem perguntar**, na janela principal e no diálogo de progresso, matando o processo no meio de uma instalação. Esc agora só limpa a busca, fechar o progresso só o esconde, e cancelar pede uma segunda decisão (LUX-002).
- **Falha aparecia como "concluída com avisos"** quando o envelope trazia `state: failed` junto de um próximo passo; e `requiresRestart` aparecia como falha. Agora falha é erro e reinício pendente é "Reinício necessário" (LUX-003).
- **Tema claro: o item ativo da barra lateral era branco sobre lilás claro (1,2:1).** Novos pares de cor, medidos pelo gate de acessibilidade (LUX-010).
- **A Visão geral dizia "com avisos" num host saudável** porque contava itens informativos como aviso (LUX-011).
- **Diálogos maiores que a tela do Steam Deck a 150%/200%** empurravam o botão de confirmar para fora da tela; agora cabem, com corpo rolável e rodapé fixo (LUX-012).
- **A janela congelava** ao medir gráficos antes de instalar o Windows (até 20 s) e no seletor de boot (até 120 s, esperando a senha); ambos são assíncronos, e o seletor explica a falha pela sessão escolhida (LUX-015).
- **Início no primeiro uso com 18 botões e ações repetidas**, e o card "Jogos, Android e VM" que só rodava o perfil de jogos (LUX-013). **"Retomar" mostrava leituras de status como a última tarefa**; falhas oferecem "Ver o que falhou" e "Tentar de novo" (LUX-014).
- **Ctrl+1..9 não seguiam a barra lateral** (LUX-016); **a ajuda do `pz` citava Ctrl+Alt+F1..F6** em vez de Meta+Shift+F1..F8 (LUX-018).
- **A interface de terminal (`pz ui tui`) rodava instalações privilegiadas sem confirmação e escondia falhas.** Passa a ser só leitura, aponta para `pz ui` e sempre mostra o código de saída (LUX-017).
- Progresso só de marcadores explícitos (antes "disco 95% usado" movia a barra), leituras expiram em 10 min, falhas do provisionamento do Windows em português (LUX-022); prévia bloqueada explica o motivo (LUX-023); perfis com o recomendado primeiro (LUX-024); Tab do campo CONFIRMAR vai ao botão que ele libera (LUX-025); nomes acessíveis em português e título sem emoji (LUX-030..032).

### Alterado
- **Barra lateral vira trilho de ícones entre 850 e 1100 px** (Steam Deck a 150%) em vez de sumir atrás do menu; o texto acompanha a fonte do sistema; o tema escolhido é lembrado e o movimento reduzido do desktop desliga a animação de carregamento (LUX-020, LUX-021).

## [1.20.9] - 2026-09-15

### Adicionado
- **Mapa de controle para o desktop KDE** (`pz steamdeck controller`). O driver `hid-steam` já entrega o lizard mode, que move o cursor pelo trackpad e pouco mais: ABXY, os paddles traseiros e os acordes de ombro não emitem nada, então um mapa de desktop precisa de um mapeador em espaço de usuário. O perfil versionado em `linux/steamdeck/profiles/` cobre trackpad como cursor e rolagem, R2/L2 como cliques, ABXY como Enter/Esc/Backspace/Espaço, L1/R1 para navegar abas, L4/R4 para campos, L5 no menu iniciar e R5 na visão geral das atividades. O `start` se recusa a rodar com Steam ou gamescope ativos — dois mapeadores no mesmo controle produzem entrada dobrada, não um mapa combinado.
- **Atalho para a visão geral das atividades**, no controle (R5) e no teclado (`Meta+Shift+F9`), alternando o efeito `overview` do KWin por D-Bus em vez de sintetizar a tecla, para que o botão e o atalho façam a mesma coisa mesmo se o usuário remapear `Meta+W`.

### Corrigido
- **O mapa do controle não sobrevivia a nada.** Nem ao login, porque nada iniciava o daemon — o `sc-controller` não traz autostart e não havia unit; nem ao próprio teste, porque a janela de reversão de 90s derrubava o daemon no meio, sem avisar. De fora não há erro em lugar nenhum: o controle volta ao lizard mode e o resultado é um recurso instalado que não funciona. Agora uma unit de usuário mantém o mapa e `confirm` a habilita no login; a janela subiu para 300s e a reversão anuncia-se por OSD ao disparar.
- **`start` declarava sucesso sobre um serviço em laço de reinício.** A unit passava o perfil ao `scc-daemon` sem o subcomando posicional que ele exige, então o processo saía com erro de argumento e reiniciava a cada 3s — e o systemd reporta `active` durante um laço, de modo que a mensagem "perfil desktop ativo" saía igual. O start passa a checar `NRestarts` antes de afirmar qualquer coisa, e `daemon_running` deixa de olhar só o pidfile, que o modo `--foreground` nunca escreve.
- **A reversão automática do perfil de controle não revertia.** Assumir o controle desliga o lizard mode, e num Deck sem teclado externo um daemon que morre no meio deixa o operador sem ponteiro; por isso todo `start` arma um temporizador. Ele tinha três defeitos, nenhum visível fora de hardware real: `$!` depois de `setsid` registra o wrapper, não o temporizador, e só diverge sob job control (isto é, num terminal), de modo que o arquivo apontava para um processo morto e `confirm` não cancelava nada; o temporizador matava o daemon por padrão de nome, e a própria linha de comando dele contém esse nome, então se matava antes de reverter; e `stop` confiava em `scc-daemon stop`, que devolve sucesso mesmo sem encontrar o daemon. O estado passa a ser lido e escrito por pid registrado, nunca por padrão de processo.
- **A janela do QEMU nascia pequena e decorada dentro do Gamescope.** O `--expose-wayland` deixava o GTK do QEMU falar xdg-shell nativo, e nesse caminho quem aplica escala e tela cheia forçada é o XWM do Gamescope — que não vê um cliente Wayland nativo. O `-full-screen` do QEMU então não produzia tela cheia nenhuma, em Handheld e em Dock. O cliente passa a ser Xwayland (`GDK_BACKEND=x11`) e o `--expose-wayland` sai; um teste recusa o retorno da flag.
- **O resultado do teclado touch era do boot anterior.** Nada reescrevia `touch-input.log` ao começar uma sessão, então um boot curto exibia indefinidamente o `timeout` — ou o sucesso — do boot passado, e não havia como distinguir "ainda esperando" de "falhou". A sessão agora abre o registro em `pending`, encerra em `interrupted` se o boot acaba antes do QGA responder, e grava `lastFailure` para separar socket ausente de guest que não aplica a política. A tentativa também passa a ser limitada pelo tempo restante da janela, não pelo tempo do helper: um helper travado consumia o orçamento inteiro de uma vez.
- **O provisionamento criava a imagem da VM sem `nodatacow`, e o Windows apanhava por isso.** `windows-vm.sh` marca o diretório antes de criar o qcow2 — o comentário ali registra que uma imagem copy-on-write com checksum, aberta pelo QEMU com `cache=none`, falha o próprio checksum na releitura e o btrfs devolve EIO ao guest no meio da escrita, o que já derrubara um Windows antes. `provision.sh` também cria imagens e nunca chamava nada disso: o remédio existia e simplesmente não estava nesta estrada. Numa VM provisionada por esse caminho, sobre `/home` com `compress-force=zstd:3`, o resultado foi `aio failed` no QEMU e `csum failed` no kernel apenas sob carga da VM — com o disco íntegro o tempo todo (`btrfs scrub` sem erros em 654 GiB, `qemu-img check` limpo, SMART com `Media and Data Integrity Errors: 0`). O aviso de falha do `chattr` virou linha de log: antes ele avisava no vazio e um `chattr` malsucedido era indistinguível de um bem-sucedido.
- **A suíte do Windows VM lia `/proc/cmdline` do host**, e `resolve_display_target` deixa um token de boot vencer o ambiente — correto em produção, veneno em teste. O resultado da suíte passava a depender de qual entrada do GRUB a máquina usara no boot: num host entrado pela entrada `(Dock)`, o `phasezero.windowsvm-display=external` real sobrepunha o override interno que os casos definiam, e a mesma revisão passava na CI e falhava na bancada.

## [1.20.8] - 2026-09-14

### Corrigido
- **O controle do Deck chegava ao Windows como gamepad genérico.** O boot direto já mapeava os três nós evdev do controle por `virtio-input-host-pci`, e eles carregam tudo (paddles traseiros em `BTN_TRIGGER_HAPPY`, o botão STEAM em `BTN_MODE`, os trackpads como hats) — mas o driver virtio apresenta isso ao guest como um HID comum. O Steam Deck Tools e o Steam Input falam com o HID nativo da Valve, então não enxergavam dispositivo algum: nenhum atalho `STEAM + …`, nenhum perfil Desktop, nenhum botão traseiro. No boot direto pelo GRUB o `28de:1205` passa a ser entregue cru via `usb-host`. O host perde o controle enquanto a VM roda, o que só é aceitável aí — o Windows é a sessão inteira, não há UI do host para onde voltar. Fora do boot direto nada muda: `virtio-input` como antes. `PZ_WINDOWS_VM_STEAMDECK_CONTROLLER=raw|virtio|off` sobrepõe; sem o controle presente o launch degrada para `virtio-input` em vez de falhar.
- `--usb-mode peripherals` combinado com o boot direto anexava o mesmo controle duas vezes, e o QEMU recusa iniciar com dois `usb-host` para o mesmo `hostbus/hostaddr`.

## [1.20.7] - 2026-09-13

### Corrigido
- **A janela de espera da política de teclado touch era menor que o boot do guest.** O helper aguardava até 180s pelo agente do convidado, mas um Windows arrancando do zero em hardware handheld costuma responder depois disso — e a política era descartada como `timeout` antes de o guest sequer ter chance. Inspeção offline da imagem descartou todas as causas do lado do convidado (`qemu-ga.exe` presente, os sete drivers virtio incluindo `vioser.inf`, serviço com `Start=2`, `DelayedAutoStart=0` e `--retry-path`), o que deixa a janela como a explicação restante. O padrão passa a 420s, configurável até 900s por `PZ_WINDOWS_VM_TOUCH_INPUT_TIMEOUT_SECONDS`.

### Adicionado
- O registro de `timeout` da política de teclado touch passa a gravar `waitedSeconds` e `attempts`. Sem isso, uma falha futura não distingue "a janela foi curta demais" de "o agente nunca responde" — e a hipótese acima só se confirma ou cai com esse dado.

## [1.20.6] - 2026-09-12

Reportado de hardware real: no boot handheld o Windows ficava preso numa janela pequena do QEMU, sem preencher os 1280x800 do painel, e sem teclado touch.

### Corrigido
- **O boot direto nunca conseguiu usar o perfil de vídeo acelerado.** A sessão sonda o host, o `graphics plan` responde elegível sem blockers, a sessão pede `--graphics virtio-gl` — e o launcher recusa, porque a forma explícita exige `--experimental`, flag que a sessão nunca passava. O mesmo perfil lido do arquivo de config era aceito sem a flag: o único chamador que verificava elegibilidade antes de pedir era o único que jamais usava o resultado. Sem `virtio-gl` o guest ignora `xres/yres` e cai em 1024x768 encaixotado, exatamente como o comentário no código já descrevia.
- **A política de teclado touch falhava em silêncio.** O Windows esconde o teclado touch enquanto houver teclado USB conectado, e o QEMU sempre conecta um — sem essa política não há como digitar num guest handheld. O helper gravava o resultado num log que nada lia; num host real registrou `{"success":false,"state":"timeout"}` e a falha só apareceu quando alguém tentou usar o Windows. `boot status` passa a reportar `touch_input` (`applied`/`timeout`/`unknown`), em texto e JSON.

## [1.20.5] - 2026-09-12

Investigação disparada por um `P:` vazio no guest Windows: a pasta estava correta, mas três defeitos separados impediam o compartilhamento de fazer o que promete.

### Alterado
- **A política de compartilhamento passa a ser `full` por padrão**, com `home`, `/mnt/sdcard`, mídia removível e `/mnt` expostos **somente leitura** e o `exchange` como única porta gravável. O guest lê tudo do lado Linux e a escrita continua passando por um caminho controlado. `PZ_WINDOWS_VM_SHARE_POLICY=minimal` volta ao conjunto antigo; `PZ_WINDOWS_VM_SHARE_WRITABLE=1` continua sendo uma decisão explícita, porque o `smb.conf` gerado usa `guest ok` e `force user` — qualquer coisa rodando no Windows escreveria na home inteira com a identidade do operador.

### Adicionado
- **Entrada de GRUB `(Handheld)`**, hotkey `h`, que fixa o painel interno via `phasezero.windowsvm-display=internal`. A sessão já entendia essa cmdline, mas nenhum `menuentry` a emitia: bootando acoplado não havia como voltar para a tela do Deck pelo menu. A entrada `(Dock)` existente passa a vir habilitada por padrão — com as duas desligadas não havia como sobrepor a autodetecção pelo boot menu. Nenhuma das duas carrega geometria: gravar resolução num `menuentry` a congelaria no monitor que estivesse ligado no `boot install`. Elas carregam intenção; a resolução continua resolvida no início da sessão, que é onde o monitor realmente é lido.

### Corrigido
- `boot status` deixa de afirmar estado errado sem privilégio: a leitura de `menuentry` num `/etc/grub.d` ilegível reporta `unknown-permission` em vez de `missing`.
- `ROOT_ENV_FILE` virou sobreponível (`PZ_WINDOWS_VM_ROOT_ENV_FILE`) para a suíte verificar os defaults distribuídos em vez do que o `/etc` da máquina de quem roda o teste tiver persistido.
- **Pendrive nunca chegava ao guest**: os compartilhamentos usavam `mount --bind`, que expõe o diretório mas não os sistemas de arquivos montados dentro dele. Cada mídia montada pelo udisks é um mount próprio sob `/run/media/$USER`, então a pasta aparecia vazia mesmo com a política ampla. Agora o bind é `--rbind` com `--make-rslave`: carrega os mounts existentes, deixa os futuros propagarem (que é o que hotplug exige) e impede que um umount do lado do guest volte a propagar para a mídia real do operador.
- **A raiz de mídia removível não era criada**: o `udisks` só cria `/run/media/$USER` ao montar o primeiro dispositivo, e um alvo inexistente era pulado em silêncio — de modo que nada inserido depois do boot podia aparecer. A raiz passa a ser criada antecipadamente, com um guard que só permite isso nos caminhos de mídia.
- **O guest recusava cópias grandes alegando disco cheio**: a raiz do compartilhamento ficava no tmpfs de `RUNTIME_DIR`, e o Windows reporta o espaço livre do volume da raiz, não do bind onde o arquivo realmente cai. Com ~1,4 GB anunciados, uma cópia maior era barrada mesmo havendo centenas de GB no destino. A raiz passa a ser persistente e em disco, com degradação anunciada para o tmpfs quando não há como criá-la.
- `umount -R` na poda de binds obsoletos: um umount simples desanexava o topo e deixava submounts (um pendrive sob `removable/`) ainda visíveis ao guest sob uma política que já não os permitia.

## [1.20.4] - 2026-09-11

Defeito encontrado clicando na página Temas de um host real, mais dois follow-ups de release que a própria varredura expôs.

### Corrigido
- **Os interruptores não respondiam ao clique**: o controle é desenhado por inteiro — rótulo à esquerda, trilho colado na borda direita —, mas o Qt só aceita clique dentro da área do indicador nativo, que fica à esquerda e nunca é pintada. Num interruptor de 126px a região sensível ia até 40px, então todo clique no trilho ou no botão visível era descartado sem nada acontecer. Atingia Temas, Serviços, Windows VM e o "Modo avançado" do cabeçalho.
- **Upgrade não deixava mais o runtime de boot do Windows VM para trás**: `windows-vm` ressincroniza sozinho em vez de exigir um `boot install` manual depois de cada atualização de pacote.
- **`.SRCINFO` parou de se corromper a cada release**: o campo `source` vinha acumulando a URL de todas as versões desde a 1.8.0 numa única linha inutilizável, porque a expressão de bump só reescrevia o dígito maior e deixava o resto da linha antiga. Agora a linha é reescrita inteira e bate com o que o PKGBUILD declara.
- `shell-lint` voltou ao verde: estava vermelho em main desde a 1.20.3 por um SC2016 que é falso positivo — as aspas simples ali existem para a chave de API não aparecer na linha de comando de cada job paralelo.

## [1.20.3] - 2026-09-10

Trabalho desenvolvido e host-verificado na branch `release/v1.19.0` (não publicada no main como release) e mesclado aqui: bateria de testes reais no host (Plasma 6/Wayland) que expôs defeitos invisíveis às suítes herméticas — daemon vivo, multi-containment, semântica de ferramenta oficial.

### Adicionado
- **Roteamento Hermes pelo 9Router**: `pz ai hermes route|provider|models` (apply/status/doctor/models/heal) com timer de auto-curativo de 5 minutos. O `config.yaml` vivo agora é reescrito com backup e escrita staged atômica — o heal nunca mais trunca a configuração do agente.

### Corrigido (motor de temas)
- Preview de wallpaper vencido reverte em qualquer comando `pz themes`; apply confirmado nunca é revertido pela expiração do preview anterior.
- `--param` conta na detecção de no-op: trocar o modo do tema (sistema→escuro) aplica de verdade em vez de no-op silencioso.
- Escrita de configuração KDE via `kwriteconfig` quando disponível — a escrita byte a byte disputava o cache do daemon KConfig e duplicava chaves no `kdeglobals` vivo.
- `reduce-motion off` restaura o `AnimationDurationFactor` anterior do usuário (registro de override permanente) em vez do padrão fixo `1`.
- Rollback de wallpaper endereça cada desktop pelo índice real; telas `-1` colapsavam na primeira e sobrescreviam o wallpaper errado.
- `pz themes verify` respeita a direção da operação e falha de wallpaper não é mais reportada como aplicada; `verify`/`rescue-wallpaper` com `ok:false` saem com exit 1.
- Preview de tela de bloqueio reverte em host stock; restore atômico preservando permissões, `SlidePaths` de slideshow e reconfigure do KWin.
- Snapshot cobre todo o raio do apply (`theme.phasezero`, `theme.accent`, `power.*`); plano bloqueado não consome snapshot; snapshot órfão não derruba a CLI.
- Efeito colorblind ausente reporta `indisponivel` e bloqueia o plano com motivo (antes gravava `Enabled=true` e jurava "ligado"); zoom/colorblind marcados `key_verified=False`; alto contraste aplica só o esquema de cores.
- `rescue-wallpaper` sem colisão de telas `-1`; Orca já em execução não falha o plano; disputa de lock responde JSON em vez de traceback.

### Corrigido (interface nativa)
- Interruptores da página Temas voltam a disparar operações (nenhum toggle funcionava; controle preso em "Aplicando…").
- "Tentar novamente" de timeout funciona; `ok:false` com exit 0 mostra falha; contagem de wallpapers respeita checksum; hero mostra o wallpaper real; poll de provisionamento mata o filho em timeout.

### Corrigido (shell)
- `pz ai omniroute install/update`: backup + escrita staged do EnvironmentFile do systemd, preservação de `OMNIROUTE_API_KEY` e correção do jq (`$port` sem `--arg port` matava toda escrita de runtime).
- `pz emulation dualscreen apply azahar` funciona (faltava o `source` de `pz_ini_set`); status lê o formato `chave = valor`.
- `pz ai secrets rotate` lê o prompt do TTY; `pz ai 9router rollback` filtra diretórios `failed-*`; `pz ai hermes setup` reescreve `config.yaml` com backup atômico; Cancelar/Esc no whiptail volta ao menu; `pz tune apply` repetido registra o backup do conteúdo original.

### Testes
- +14 testes de regressão herméticos; suíte completa: 809 passed + shell suite.

## [1.20.2] - 2026-09-09

Correção encontrada ao iniciar o Windows num host real, depois de rodar `boot install` com privilégio.

### Corrigido
- **VM não iniciava depois de um comando elevado**: o `windows-vm` já resolvia a base do runtime para `/run/user/<uid do usuário>` quando rodava como root, mas criava o diretório sem devolver o dono. Ele nascia `root:root` dentro do runtime dir do próprio usuário, e a partir daí todo `windows-vm start` sem privilégio parava em `install: não foi possível mudar permissões de "/run/user/1000/phasezero-windows-vm"`. Bastava um `pz windows-vm boot install` pela ponte admin para deixar a VM do usuário travada até alguém corrigir o dono à mão. Os três pontos que criam o diretório passam por um helper que o devolve ao usuário alvo.

### Interface
- **Ajustes de host pulados viram um resumo com ação**: iniciar a VM sem privilégio imprimia treze avisos `requires root; skipped` seguidos — a maioria um por núcleo de CPU —, sem dizer o que fazer com aquilo. Agora sai uma linha com o que ficou de fora e outra com o comando que aplica (`phasezero-admin pz windows-vm optimize`). A VM inicia com ou sem esses ajustes; eles são otimização, não requisito.

## [1.20.1] - 2026-09-09

Correções encontradas ao instalar a 1.20.0 num host real e rodar o diagnóstico.

### Corrigido
- **`pz doctor` terminava sem terminar**: o comando morria com SIGPIPE no meio do relatório, quando o diretório de operações era grande o bastante para o `ls` ainda estar escrevendo enquanto o `head` já tinha saído. No host de teste o relatório parava no check 44 de 136 — toda a parte de gráficos do Windows VM, TPM e swtpm era pulada em silêncio, e a saída ainda parecia completa.
- **`pz doctor --json` ignorava a flag** e imprimia o relatório humano; qualquer flag desconhecida era aceita sem aviso. Agora emite o mesmo envelope objeto dos demais comandos de status (`schemaVersion`, `summary`, `ok`, `checks[]`), sai 0 como relatório deve sair, e recusa o que não conhece.
- O caso 9 de `tests/audit-doctor.sh` exigia `WARN` para subsistema opcional sem configuração, regra que o produto abandonou de propósito em favor de `INFO: not opted in`. O arquivo nunca era executado pelo runner — o nome não casava com os padrões varridos —, então a contradição sobreviveu sem ser vista. Renomeado para `tests/linux-audit-doctor.sh` e alinhado à regra atual.

### Adicionado
- Check `STATE01`: conta os registros locais de operação e aponta `pz installation prune` quando passam de 500. A poda já existia; faltava alguém dizer que era hora. O host de teste tinha 5126 registros acumulados.

## [1.20.0] - 2026-09-08

### Adicionado
- **Jornada por solução no Homelab**: cada aplicativo do catálogo percorre não instalado → preparando → configurar acesso → pronto para usar, com os passos de primeiro uso em português no próprio cartão. "Rodando" deixou de significar "pronto": sem sonda funcional respondendo, o cartão continua em preparação.
- **Primeiro pareamento remoto sem terminal** (`hosts pair --password-stdin [--timeout S]`): a senha é lida de stdin e entregue ao ssh por um helper askpass em arquivo 0600 dentro de diretório 0700, destruídos em toda saída — nunca em argumento, variável de ambiente, JSON ou log. Espera limitada, cancelamento seguro, e desfechos distintos (`paired`, `auth-failed`, `timeout`, `unreachable`, `empty-password`) com o que fazer a seguir.
- **Início por objetivo**: os cartões abrem a jornada que nomeiam — hospedar leva ao Homelab, cuidar de outro computador leva à etapa de pareamento, e o novo objetivo de Windows leva ao controle de instalação. Tarefa interrompida volta com um cartão para retomar de onde parou.
- **Gate de acessibilidade na suíte**: contraste WCAG AA nos temas escuro e claro, nome acessível e alcance por teclado em todas as páginas, e ausência de overflow horizontal em 150% e 200%.

### Corrigido
- **Perfil de orçamento parou de fingir instalação**: um perfil sem receita reservava memória e seguia instalando os aplicativos padrão, como se atendesse o objetivo escolhido. Agora a interface nomeia os serviços que aquele perfil não instala e exige decisão explícita entre simular recursos e instalar a base do servidor.
- **Windows não promete mais 3D que não pode provar**: `virtio-gl` era anunciado como estável e "aceleração OpenGL" enquanto o próprio backend o classifica como experimental. O modo simples passa a oferecer só o que esta máquina mede como estável, com o display recomendado e o motivo; sem medição, fica no perfil compatível.
- **Canal de instalação sob elevação**: `pz` executado via sudo/pkexec lia `XDG_DATA_HOME` de quem invocou, e reportava como ausente uma instalação de usuário que existia.
- **`emulation dualscreen detect` não trava mais**: `kscreen-doctor` bloqueia indefinidamente sem sessão KDE e era chamado sem limite, deixando o diagnóstico pendurado sob serviço ou runner de teste.
- Contraste abaixo do mínimo WCAG AA em dois pares de estado (erro no tema escuro, aviso no claro) e anel de foco imperceptível sobre superfícies escuras, agora com token próprio.
- Windows VM saía do viewport em escala de 200%: o limiar de reflow era fixo em pixels e a página permitia rolagem horizontal.

### Interface
- Abrir uma solução deixou de marcar o primeiro acesso sozinho: quem confirma que a conta foi criada é o operador, com os passos daquela solução à vista.
- Plano de instalação resumido em linguagem de produto — servidor, aplicativos, acesso, memória e etapas —, com o JSON preservado na visão avançada.
- Falha de comando explica a causa e oferece retomar por um controle visível, sem exigir leitura de log.

## [1.19.0] - 2026-08-27

### Adicionado
- **Página Linux no Control Center**: uma vitrine categorizada com os apps, serviços e otimizações do projeto. Cada cartão traz ícone real do app, o que ele faz, como é desfeito, se é recomendado ou opcional, e um interruptor que reflete o estado do host — instalar/remover para recursos, aplicar/reverter para otimizações.
- **Tuning reversível**: `pz tune <área> apply|revert|status` nas três áreas (gaming, navegador, desenvolvimento). Cada mutação é registrada com backup, hash do conteúdo e valor anterior das preferências de ferramenta, então `revert` devolve o que era do usuário em vez de apagar.
- **Remoção de recursos por id**: `pz capabilities remove-plan|remove|verify-removal`, espelhando o ciclo de instalação. A remoção é recusada quando o histórico não mostra que o PhaseZero instalou o item, ou quando outro recurso instalado ainda depende dele.
- Metadados honestos no catálogo de recursos: `mode` (recomendado/opcional/avançado), `rollback` (mecanismos que o motor realmente executa) e `hasStatus`, que distingue "não instalado" de "não sondamos o host".

### Corrigido
- `pz ai status` deixava de responder quando o Hermes estava instalado sem nenhum bloco MCP gerenciado: `grep -c` imprime a contagem **e** sai com 1 quando ela é zero, o ramo `|| echo 0` imprimia um segundo zero, e o `--argjson` recebia JSON inválido. A página de IA ficava sem nada para renderizar.
- `pz tune dev` não escreve mais com `sudo tee` direto; passa pelo arquivo gerenciado e pela ponte administrativa como o resto do projeto.
- Selo de reversibilidade deixa de pintar de verde o que ninguém desfaz sozinho: `manual` e `sem reversão` não contam como reversível.

### Interface
- Estado nunca otimista: o interruptor vai para "aplicando…" e só assume o novo valor quando o host reconfirma; prévia recusada devolve o interruptor ao lugar; leitura que falha desabilita o controle com o motivo, em vez de exibir um "desligado" em que o usuário poderia agir.
- Ícone original do app resolvido a partir do `.desktop` instalado, sem baixar nada da rede.

## [1.18.0] - 2026-08-27

Versão marcada em `810d9b9` cujo workflow de release foi cancelado; nunca chegou a publicar
artefatos. O conteúdo abaixo está incluído na 1.19.0 e fica registrado aqui para o histórico
não pular de 1.17.4 para 1.19.0.

### Adicionado (Homelab paridade umbrelOS v1)
- **Catálogo um clique por app**: `pz server homelab apps list/enable/disable/update --json`, com isolamento por app validado em CI descartável.
- **Ponte multi-host**: `--host` por SSH para administrar um Homelab remoto a partir do painel.
- **Contratos do dashboard web**: HTTPS, unidade de usuário via template, allowlist de token e TLS do agente, com ADR de modelo de ameaças.
- Fatos honestos do host e primeiro uso orientado no Player.

### Corrigido (AppTuning)
- Itens fantasma passam a existir de fato; `status` deixa de relatar sucesso falso.
- `ConvertTo-BootstrapHashtable` não perde mais dado na conversão.
- Tuning de captura, templates e sondas de known folder implementados.

## [1.17.4] - 2026-08-25

### Adicionado (CCS-040/041/042)
- **Homelab Player v2**: padrões visuais da Central, rótulos em português, bloqueio honesto durante operações e **restauração assistida** — prévia legível, confirmação digitada (`RESTAURAR <backup>`) e aplicação sem `--yes` na UI (CLI ganha `--confirm-file`).
- **Primeiro uso orientado**: Início detecta host novo e oferece "Comece por aqui" com três passos reais (Diagnosticar → Agentes de IA → Backup).
- **Confiança global**: timeout com botão Tentar novamente, aviso central quando já há operação em andamento, toggles liberados quando a leitura falha, nota clara sobre onde segredos ficam.

### Corrigido
- Glossário único para o leigo: Prévia/Aplicar; dry-run → "simulação"; conectores MCP, fontes Flatpak e assistente de dock descritos por benefício.
- Acessibilidade fina: botão default e foco nos diálogos, rótulos acessíveis em todos os campos, tooltips com linguagem humana.

## [1.17.3] - 2026-08-25

### Corrigido
- **Jornadas sem beco sem saída**: relatório de diagnóstico válido nunca sai como erro — status de leitura com estado pendente (não configurado, VM desligada, QGA ausente, LaunchBox/9Router/headroom ausentes, drift de emulação) responde rc0 com envelope `state/summary/nextAction`; falha real da ferramenta continua honesta.
- Preview mutável com pendência vira aviso explicativo (botão Confirmar permanece disponível); ResultDialog/PreviewDialog renderizam "Próximo passo" unificado (`nextAction`/`next`/`reasons`).
- Temas não fica mais presa em "Verificando…" quando a leitura falha; Servidor exibe motivos e próximo passo do Homelab; saúde contextual, boot direto, IA & Dev, Roteamento, Resultados, Ajustes e Assistente Windows com orientação acionável.

### Adicionado
- Guarda transversal `tests/test_status_contract.py`: 60 ações de status do catálogo vigiadas (rc0 + envelope quando `--json`) — a classe "diagnóstico indisponível" não renasce.

## [1.17.2] - 2026-08-25

### Corrigido
- **Diagnóstico Homelab deixa de ser erro**: `server homelab status` com stack não pronto (inclusive nunca configurado) sai `exit 0` com relatório honesto `state` (`needs-config|stopped|degraded|unhealthy|ready`), `summary` em pt-BR e `nextAction` acionável; falha real da ferramenta emite envelope `unavailable` em vez de texto cru.
- **Homelab Player**: estados traduzidos ("Ainda não configurado", "Desligado · dados preservados"…), motivos listados e próximo passo exibido; fim do "status indisponível (exit N)" sem orientação.

## [1.17.1] - 2026-08-25

> Recuperação de UX da integração IA: fim do `ok:true` enganoso, MiMo por API oficial, backup portátil criptografado e `ai-memory` nativo 1.31.1.

### Corrigido
- **Contrato honesto de jornada**: `needs-login`/`needs-credentials` saem com `ok:false`, campos `ready/completed/resumable` e `nextAction`; o runner da UI trata JSON `ok:false` como falha mesmo com exit 0 — a fila nunca mais registra pendência como conclusão.
- **Compat audit no workspace certo**: diagnóstico passa a apontar o projeto registrado (`workspaceSource=registered|explicit|needs-project`) em vez de `/usr/lib/phasezero`.
- **Asserções de teste**: verificações de ausência com `!` sob `set -e` não falhavam silenciosamente (SC2251); guardas SC2015 reescritos.

### Adicionado
- **MiMo via API oficial Xiaomi**: portal oficial + chave única validada contra `/models`, host na allowlist; chave em arquivo `0600`; OpenCode por referência `{file:…}`; registro ZCode sem embutir segredo; fim das instruções de DevTools/cookies.
- **Backup portátil (ADR 0002)**: `pz ai backup plan|create|verify|restore` com GPG AES-256, allowlist de credenciais, manifesto sem segredos, pré-backup e rollback na restauração.
- **ai-memory nativo 1.31.1**: binário verificado por SHA-256 pinado (conferido com o release upstream), wrapper Docker removido, status honesto (`ready/status/integrations`) e adapter correto `open-code`.
- **Integrações declaradas**: Grok Build e Kimi Code detectados como clientes (regras via AGENTS.md), providers separados de clientes; ZCode consome MCP canônico sem prometer hooks inexistentes.

## [1.17.0] - 2026-08-24

> Atual estável publicada: **1.16.x** (`version.json`).
> Entradas abaixo cobrem WinVM, IA, Homelab e Central desde 1.13.0.

### Adicionado
- Central IA reorganizada por jornada: catálogo separa base essencial de
  opcionais, páginas dedicadas para IA & Dev, Proxies e Roteamento, próxima ação
  pedagógica, progresso persistente e repetição segura após interrupção.
- Registro central de autenticação redigido (`pz ai auth`) para clientes,
  providers 9Router, proxies e workspaces; nenhuma identidade ou credencial
  aparece no contrato público.
- Ledger privado de operações da Central com estados running/completed/failed/
  interrupted, recuperação após encerramento da UI e retry sempre submetido a
  nova prévia e confirmação.
- Hermes Agent `v0.20.5` integrado ponta a ponta ao 9Router: distribuição e
  instalador fixados, aceite de risco preso ao commit, launchers protegidos,
  MCP ai-memory, Playwright, desktop entry e gateway user persistente por
  drop-in systemd.
- Procedência fail-closed para Kimi, Qwen, DeepSeek e Mimo: repo, commit, árvore,
  licença e lockfiles versionados; instalação atômica em staging; divergência
  bloqueia execução sem impedir parada segura.
- Diagnóstico e plano agregados para Hermes, Odysseus, 9Router, Ollama,
  ai-memory, Podman, Tailscale, portas, política e orçamento do host.
- Odysseus ganhou manifests de release, imagens por digest OCI e base Python
  por digest, mantendo instalação bloqueada enquanto auditoria semântica e
  dependências Python não forem aprovadas.
- Entrada GRUB dedicada "PhaseZero Windows VM (Dock)": `boot install
  --dock-entry` cria uma segunda entrada (hotkey `d`, mesma classe de ícone
  do Windows) que inicia a sessão sempre no monitor da dock via
  `phasezero.windowsvm-display=external` no cmdline — o cmdline vence o
  default `auto` e o override de ambiente. A preferência persiste no env
  root (`PZ_WINDOWS_VM_BOOT_DOCK_ENTRY=1`), sobrevive a reinstalações, e a
  Central de Controle ganhou o botão "GRUB: Windows (Dock)" para
  adicionar/remover com fluxo elevado de prévia.
- Boot direto reconhece o monitor: o default da sessão GRUB deixa de forçar o
  painel do Deck (`internal` → `auto`) — com monitor conectado, o boot usa o
  modo físico do monitor (preferência do KWin por EDID, senão nativo, senão
  1080p) e o refresh real; no handheld mantém 1280×800 com rotação. Quem
  quiser o Deck na dock: `PZ_WINDOWS_VM_PRIMARY_DISPLAY=internal`.
- Boot direto em tela cheia de verdade: a sessão sonda `graphics plan` e
  quando o host suporta passa `--graphics virtio-gl` (único perfil que honra
  a resolução da saída via `xres/yres`, com driver `viogpudo` já instalado
  pelo provisionador), mantendo o fallback `compat` em falha rápida. Sem
  isso, VMs `compat`/QXL sem driver rodavam 1024×768 em janela minúscula.
  Override manual: `PZ_WINDOWS_VM_SESSION_GRAPHICS=compat|virtio-gl`.
- Atualização do pacote com boot direto instalado deixa um marcador
  legível sem privilégios (`windows-vm-runtime-sync.pending`): o
  `status --json` expõe `boot.bootRuntimePendingSync` e a página Windows VM
  aciona o botão "reparar boot" também por ele, mesmo se o aviso do terminal
  passar despercebido. `boot install` consome o marcador e grava
  `provenance.json` (fonte, versão, data) no runtime instalado, impedindo que
  um runtime vindo de worktree se disfarce de atual sem rastro.
- Inventário de VMs concluídas criadas pelo provisionador, com espaço real por
  operação e remoção explícita por instalação. A interface separa a VM atual
  das instalações legadas e oferece lixeira recuperável ou liberação imediata.
- Gerenciador de imagens Windows na Central de Controle (`Windows VM` →
  "Gerenciar imagens"): lista as ISOs registradas, mostra características
  básicas (tamanho, arquitetura, UEFI, SHA-256, validade), lista as edições
  por índice WIM marcando as já instaladas e reúne numa única tela reproduzir
  no player, habilitar no boot, restaurar o GRUB e remover.
- Registro versionado de imagens (`linux/ui_native/image_registry.py`,
  `images.json` sob o diretório de estado): `schemaVersion 1`, escrita atômica
  com modo 0600, idempotência por `sha256`, arquivo ausente ou corrompido
  degrada para lista vazia e versão futura falha fechada.
- `pz windows-vm media scan [--json]`: descoberta de ISOs do Windows nas bases
  canônicas (`~/Downloads`, `/mnt/sdcard/Steam`, `$HOME`, `/mnt/sdcard`), com
  deduplicação por caminho. O contrato de `media inspect` permanece inalterado.
- Modo simplificado padrão na Central de Controle: comandos, JSON e logs ficam
  recolhidos; a chave global "Modo avançado" revela detalhes técnicos sob
  demanda.
- Páginas visuais dedicadas para Windows VM, Waydroid e Servidor, com status,
  ações de ligar/desligar, sliders seguros, toggles explicativos e zona de
  perigo separada.
- Painel "Saúde do sistema" agrupa diagnóstico por categoria e converte
  `PASS`/`WARN`/`FAIL` em indicadores e ações compreensíveis.
- Resultados estruturados usam cards e fatos legíveis; sucessos mutáveis usam
  toast e falhas abrem diálogo orientado à correção.
- Comando `pz waydroid stop` idempotente para suportar o controle visual.
- Configurador de roteamento IA por tarefa (`linux/ai/routing_manager.py`,
  `pz ai routing`): inventário de conexões do 9Router com quota real
  (known/unknown/unavailable + confiança), recomendações por tarefa
  (code/analysis/plan) e política (quality/balanced/save-quota/privacy),
  plano transacional `phasezero-*` com manifesto, apply idempotente,
  rollback byte a byte (recusa drift sem `--force`), `run` com env de
  criança e `verify` (health, planMatches, userCombosPreserved,
  bonsaiIsolated). Redação obrigatória de segredos.
- Página dedicada "Roteamento IA" na UI nativa: cards por tarefa com
  recomendação/cadeia/quota, seletor de política, editor de ordem de
  fallbacks, aplicar/reverter e isolamento Bonsai.
- Suíte de testes `tests/test_routing_manager.py` com 9Router fake
  (machine-id + CLI secret + API key), falhas injetadas, rollback
  transacional e e2e via `pz ai routing`.
- Smoke `pz ai routing` em `tests/linux-ai.sh` (degrada sem 9Router).

### Corrigido
- Proxies deixam de declarar sucesso após falha de serviço: início, readiness,
  porta e chat real agora determinam resultado terminal e próxima ação.
- Fluxo Mimo não inicia sem credencial; salvar valores válidos continua
  automaticamente por iniciar, verificar e abrir. Falhas de IDE são degradadas,
  nunca descartadas.
- Roteamento IA usa uma política global coerente para code/analysis/plan;
  recomendações, preview e aplicação transacional compartilham o mesmo estado.
- Status IA executa sondas independentes em paralelo e reduz espera da Central.
- Hermes gateway preserva integração 9Router após reboot mesmo quando upstream
  autorregenera sua unit systemd.
- A sessão de boot direto não mata mais o Windows em execução ao ser
  encerrada. Todo fim de sessão (logout do SDDM, sinal, arquivo
  `shutdown.requested`) pede primeiro o desligamento do convidado via QGA
  (`guest-login shutdown`), espera até 120 s e só então escala TERM→KILL;
  fim forçado é registrado como desligamento sujo.
- Cada sessão grava `session-state.json` versionado (graceful, motivo,
  duração, display usado) e o `status --json` passa a expor `session` com os
  findings `guest-unclean-shutdown` (desligamento sujo — orientação de
  reparo) e `session-shutdown-hint` (saída não verificada — dica de
  encerramento correto), alimentando a UI com próximo passo claro.
- `fallback_desktop` ganha kill-switch `PZ_WINDOWS_VM_SESSION_DESKTOP_FALLBACK=0`
  para suítes de contrato rodarem dentro de uma sessão logada sem risco de
  subir um desktop aninhado.
- Fechar a janela do QEMU não encerra mais a máquina (`window-close=off` nos
  perfis GTK, validado contra o QEMU instalado): fechar com o Windows ligado
  derrubava o convidado na hora e sujava o disco. O desligamento passa a ser
  pelo menu Iniciar do Windows ou pelo botão Desligar do PhaseZero.
- Descartar uma instalação interrompida antes de qualquer disco existir
  (checkpoints `validate`/`assets`) deixa de reportar
  `staging removal failed; preserved:` com caminho vazio. A operação nunca
  registrou diretório de staging, então não há nada a preservar e o descarte é
  concluído. O player ficava preso em "Descarte falhou" e impedia iniciar uma
  nova instalação.
- Remover a VM configurada deixa de ser impossível para toda VM criada pelo
  PhaseZero. `provision finalize` adota o próprio disco que acabou de construir,
  o que marcava a VM como `adopted-existing` e caía no bloqueio "somente VMs
  criadas pelo PhaseZero podem ser removidas aqui". `adopt` passa a registrar a
  procedência (`--source provisioned|adopted-existing`) e `remove` decide pela
  localização: discos dentro de `~/VirtualMachines/PhaseZero*` são removíveis,
  com aviso explícito quando a VM foi adotada em vez de criada. Procedência
  desconhecida vira bloqueio.
- A prévia de remoção da VM deixava de ficar pronta em qualquer host cujo
  `active.lock` já tivesse sido liberado: `provision_lock_clear` trunca o lock
  no lugar e nunca o apaga, então lock vazio é o estado normal de "nenhuma
  operação ativa", mas o leitor tratava o vazio como inconsistente e devolvia
  "estado do provisionamento é inconsistente; repare ou descarte a operação".
  Lock vazio volta a significar ociosidade; conteúdo inválido continua
  bloqueando.
- Remover uma imagem do Windows não é mais confundido com apagar a VM criada.
  Remoção legada valida o identificador, recusa VM em execução, revalida o alvo
  sob trava compartilhada com a finalização e libera o índice somente após
  remoção confirmada.
- Gerenciador de imagens: ISO válida cujas edições não são legíveis a partir
  do arquivo (caso comum em mídia de varejo, em que `media inspect` devolve
  `imageCount: 0`) passa a oferecer as edições 1 a 10, como a instalação já
  fazia, em vez de deixar a lista vazia e o botão de reproduzir desabilitado.
- Gerenciador de imagens: falha ao mover a ISO para a lixeira é reportada como
  falha (a sobrecarga estática do Qt devolve uma tupla, sempre verdadeira).
- Gerenciador de imagens: uma ISO ilegível não interrompe mais a análise das
  demais imagens selecionadas na busca.
- `verify` considera isolamento Bonsai por combos, não por conexão.
- Redação preserva booleanos em chaves como `secretsRedacted`.
- Atribuição de modelo a provider por prefixo (`cc/`, `cx/`, ...).
- Página dedicada "Proxies IA" na UI nativa: gateways 9Router/Odysseus, cards
  por proxy com iniciar/parar, autenticação OAuth por navegador, integração com
  IDEs e polling passivo de status.
- `pz ai proxies detailed-status` (JSON consolidado de instalação, serviços,
  autenticação e IDEs), `restart` e `login all` sequencial para proxies com
  sessão de navegador.
- 9Router com pacote verificado, atualização atômica, perfil de clientes e
  watchdog passivo.
- Odysseus fixado em commit oficial, provisionado com Podman rootless,
  autenticação obrigatória e rollback.
- Inventário unificado e timer check-only para updates PhaseZero, apps e host.
- Qwen Code Desktop oficial `desktop-latest`, instalado por usuário com digest
  SHA-256, launcher Wayland e diretório de configuração privado.
- WinBoat e WinPodX oficiais com Podman rootless, recursos adequados aos 14 GiB
  do Steam Deck, FreeRDP, multitouch e política de um guest Windows por vez.
- Compartilhamento `PZExchange`, canal SPICE WebDAV e diagnóstico da rede/NIC
  libvirt.

### Homelab v1.15.1 (remediação, merge PR #37)

### Adicionado
- Port do Homelab v1.15.1: stack, status, boot-prepare, compose core/extras e
  operations com lock de exclusão, crash/resume/cancel e rollback; estado nunca
  em `/root` (HOME/XDG explícitos via runuser).
- Resource governor com 6 perfis públicos (`homelab-profiles.json`):
  assistant-private, assistant-multichannel, automation, ai-studio (blocked),
  developer e edge (default), com classe, maturidade e pesos por imagem;
  `pz server homelab profile set` com gate de RAM e fail-closed.
- AI policy broker (modos, allowlist de ações, redação de segredos).
- CLI `pz server homelab` (status/plan/verify/repair/backup/restore/logs,
  `profiles --json`) e Player nativo async QProcess com UI de controle.
- Portainer alcança o Docker somente via `socket-proxy` read-only
  (tecnativa/docker-socket-proxy:0.2.0, allowlist CONTAINERS/TASKS); nenhum
  container monta `/var/run/docker.sock`.
- Suíte hermética `tests/linux-homelab.sh`, smoke `packaging/install-root-smoke.sh`
  e jobs dedicados de CI (`homelab-shell-test`, `homelab-python-test`,
  `compose-validate`, `package-smoke`, `security-secret-scan` com gitleaks).
- Testes do contrato WinVM no governor (stub de status, fail-closed, plano de
  impacto, execução graciosa, resume) e de rollback do restore (falha parcial
  com volume envenenado) na suíte hermética.
- Documentação de operação (docs/linux-homelab.md): arquitetura e perfis,
  matriz de suporte, threat model (socket-proxy, no-new-privileges, limits),
  segredos/rede/acesso, backup/restore/DR com snapshot prévio e rollback,
  contrato WinVM, operação sem UI/troubleshooting e limitações honestas.

### Corrigido
- Restore recusa aplicar sem `--yes` explícito; verify-then-apply e manifest
  schemaVersion 2 com tamper fail-closed.
- Restore cria snapshot prévio `<source>.pre-restore` (verificável, mesmo
  schema) e em falha parcial devolve cada volume tocado ao estado prévio
  (`rollbackApplied`); `status` ignora diretórios `*.pre-restore`.
- Governor desconta WinVM ativa do orçamento (`winvmMB`) e expõe contrato
  `winvm-status`/`winvm-suspend [--dry-run]`/`winvm-resume` com suspensão
  somente graciosa via QGA (`killUsed:"never"`, nenhum arquivo da VM tocado).
- CI: job `homelab-integration-disposable` prova em Docker real
  backup → destruição → restore → igualdade byte a byte em volumes
  descartáveis.
- Contrato CLI/Player alinhado (`pz server homelab profiles --json`); scripts
  novos marcados executáveis (core.filemode=false); suíte pinada ao checkout
  via `PZ_ROOT`; ShellCheck 0.9.0 e 0.11.x verdes com os mesmos excludes do CI.
- Auditoria deduplica aliases `/usr/lib` e `/usr/lib64` do mesmo inode.
- Shares Windows validam listagem real e criam diretório de intercâmbio como o
  usuário alvo.
- Runtime gráfico Steam Deck LCD documenta e aplica Gamescope 1280×800 com
  orientação `right`, evitando guest vertical no modo handheld.

## [1.13.0] - 2026-07-30

> Nota (CCS-033): as releases 1.14.x–1.16.x foram publicadas sem entrada
> individual neste arquivo; a fonte de verdade de versão é `version.json`
> e as tags/releases do GitHub.

### Adicionado
- Janela dedicada Provision Player (`windows.provision.player` na UI nativa):
  plano, confirmação, provisão com checkpoint e progresso, validação pós-boot,
  cancelamento, retomada, descarte, reparo, shutdown e reboot.
- `provision status --json` expõe vmDir, snapshotPath, snapshotExists, qemuPid,
  qemuRunning, libvirtRunning.
- `provision shutdown` via QGA guest-shutdown + PID waiting + libvirt fallback.
- `windows-vm.sh --json` emite bootReady e oneShotReady como booleanos estritos.
- `common.sh::checkpoint_progress_start`/`end`: sequência de progresso por
  checkpoint com pesos somando 100.
- ProvisionWorker com sleep interruptível (100ms) para fechamento rápido.
- AsyncProc: timeout dispara uma vez, FailedToStart aborta imediatamente,
  finished sinal com tupla (data, exit_code).
- Testes comportamentais (295 Python, 12 específicos do player).

### Corrigido
- Player não bloqueia o event loop Qt (sem waitForFinished/QThread.wait).
- `_finish_once` centraliza conclusão de AsyncProc (sem emissão dupla).
- Janela não destrói worker thread durante close (aborta primeiro).
- `_resume_state` não sobrescreve ISO/parâmetros explícitos em `open()`.
- Discard limpa disco sem salvar estado via `_discarding` flag.

## [1.8.4] - 2026-07-13

### Corrigido
- Backend ISO preserva modo executável nos pacotes e aparece disponível no
  status geral mesmo quando invocado explicitamente por `bash`.

## [1.8.3] - 2026-07-13

### Corrigido
- CI nativo instala `python-pip`, necessário para empacotar PySide6 no AppImage.
- Flatpak obtém wheels PySide6 por URLs fixas e valida SHA-256, sem depender de
  arquivos locais ausentes no checkout.

## [1.8.2] - 2026-07-13

### Corrigido
- Builders invocam `export-source.sh` via `bash`, funcionando em checkout CI
  onde scripts auxiliares preservados como modo `100644` não são executáveis.

## [1.8.1] - 2026-07-12

### Corrigido
- Release sincroniza `version.json` com metadados DEB, RPM, AUR, Flatpak e
  AppStream antes do commit/tag.
- Job de pacotes instala PySide6 antes do gate de coesão; job Flatpak usa imagem
  oficial existente `gnome-48` conforme documentação upstream.

## [1.8.0] - 2026-07-12

Foco: boot dinâmico seguro de ISOs e mídias removíveis pelo GRUB do host.

### Adicionado
- **ISO loopback tipada**: `pz boot iso` detecta e valida ArchISO,
  SystemRescue, Ubuntu Casper, Debian Live e Grml; registra UUID, caminho GRUB,
  kernel/initrd, metadados e SHA-256 antes de gerar entradas one-shot.
- **Chainload removível por UUID**: `pz boot usb` descobre USB/SD, valida
  `/EFI/BOOT/BOOTX64.EFI` em montagem somente leitura e evita ordinais
  `(hdN,gptN)` e recursão no fallback EFI do host.
- **GRUB2 File Manager opt-in**: `pz boot grubfm` aceita somente EFI x86_64
  local com SHA-256 explícito, bloqueia Secure Boot não confirmado/desativado e
  sinaliza upstream arquivado; nenhum payload é baixado automaticamente.
- **Integração completa**: seletor Qt carrega ISOs/mídias disponíveis, catálogo
  possui previews elevados, doctor/repair-plan auditam geradores e documentação
  cobre instalação, one-shot e rollback.

### Segurança
- Escrita transacional em `/etc/grub.d/46`–`48`, backup prévio, instalação
  atômica, recompilação obrigatória e restauração automática quando validação
  falha. `/boot/grub/grub.cfg` nunca é editado diretamente.
- Atualização GRUB diferencia erro fatal de aviso conhecido do `os-prober` para
  mídia ISO híbrida sem drive GRUB; demais mensagens `error:` continuam fatais.
- EFI ativo com prefixo ordinal foi reparado no host por bootstrap UUID antes
  da instalação. USB BigLinux `3339-E139` foi registrado e entrada passou
  `grub-script-check`; boot padrão permaneceu intacto.

### Validação
- `linux-iso-boot`, `linux-boot-recovery`, `linux-doctor`, `linux-menus` e
  `linux-ui` aprovados.
- 58 testes Python nativos aprovados; smoke Qt/UI adicional aprovou 23 testes.
- Fixture ArchISO local confirmou detecção automática de label, kernel e initrd.

## [1.6.0] - 2026-07-11

Foco: biblioteca de jogos orientada por tarefas, instalação Vita3K resiliente e
menu do desktop consolidado.

### Adicionado
- **Biblioteca unificada**: workflow nativo em cinco etapas — origem, análise,
  plano, execução e validação — aceita biblioteca completa, pasta ou múltiplos
  arquivos, com filtros, detalhes contextuais, cancelamento e rollback.
- **Adapter PlayStation Vita**: identifica ZIP/VPK NoNpDrm pelo conteúdo e SFO,
  bloqueia dumps incompatíveis, instala atomicamente em Vita3K, preserva origem
  e verifica hashes. `PCSE01224.zip` foi instalado e validado no host real.
- **Menu PhaseZero único**: consolida jogos/emuladores, web apps e sessões sob
  uma raiz KDE; deduplica por comando, oculta jogos individuais não favoritos e
  mantém ledger privado reversível.
- **Diagnóstico gráfico Windows VM**: perfis compat/virtio-gl e planos seguros
  para Venus, rutabaga e VFIO/Looking Glass, sem alterar GRUB ou bind VFIO.

### Corrigido
- **UI em 1280×800**: inspetor de contexto fica oculto até uma seleção; quatro
  jornadas substituem a pilha de 71 ações da página principal de Emulação.
- **ROM Vita em ZIP**: `rom-optimize` deixa de falhar como arquivo não suportado
  e encaminha pacote instalável ao planner da biblioteca.
- **Menu iniciar duplicado**: raízes legadas Jogos/Web Apps são removidas com
  backup e launchers gerenciados deixam categorias globais.

### Validação
- 133 testes Python, suítes nativas/emulação/menu/Windows VM e smoke offscreen.
- Instalação real Vita3K: 392 arquivos verificados, fonte SHA-256 preservada.
- Menu KDE: 76 entradas únicas, 103 jogos/auxiliares ocultos e aplicação idempotente.

## [1.5.1] - 2026-07-11

### Corrigido
- **Atalho do menu iniciar**: o wrapper instalado no usuário agora resolve a própria
  release antes de `/usr/lib/phasezero`, evitando abrir UI antiga quando o pacote
  do sistema ainda está em versão anterior.

## [1.5.0] - 2026-07-11

Foco: reorganização completa da Central de Controle nativa para reduzir ruído,
agrupar jornadas e tornar impacto/risco explícitos antes da execução.

### Adicionado
- **Workspace contextual**: módulos operacionais usam navegação secundária por
  intenção (visão geral, sessão, biblioteca, frontends, controles, manutenção e
  avançado), preservando acesso às 250 ações do catálogo.
- **Inspetor de contexto**: seleção de uma ação mostra descrição, risco, resultado
  esperado e comando seguro. Apenas o inspetor oferece o CTA Executar/Pré-visualizar.
- **Componentes consistentes**: linhas semânticas, métricas reais do catálogo,
  radio buttons para modos exclusivos do Steam Deck e disclosure para ações raras.
- **Busca reorganizada**: resultados textuais agora usam lista selecionável e o
  mesmo inspetor, em vez de grids extensos de cards e botões.

### Corrigido
- **Hierarquia visual**: remove pilhas de botões com mesma ênfase, barras de status
  duplicadas, ícones genéricos repetidos e agrupamentos pouco claros.
- **Acessibilidade**: alvos mínimos de 48 px, foco visível, labels persistentes,
  descrições acessíveis e navegação completa por teclado.
- **Portabilidade visual**: componentes usam Qt/PySide6, tokens semânticos e ícones
  do tema/sistema com fallbacks, sem dependência de primitivas gráficas Linux.

### Validação
- Design QA comparado ao mock selecionado em 1586×992 e 1280×800.
- 97 testes Python e todas as suites `tests/linux*.sh` aprovados.

## [1.4.1] - 2026-07-10

Foco: correções de emulação e experiência SteamOS — Steam ROM Manager, centralização
de keys/firmware, pastas duplicadas, mídia órfã e robustez de sessão Game Mode.

### Corrigido
- **Decky no SteamOS**: preparação e validação transacional dos bundles impede
  carregar plugins incompletos (`frontend_bundle not OK`/imports dinâmicos);
  pacotes inválidos são preservados ou isolados sem substituir instalação válida.
- **Fundação visual**: temas claro/escuro usam tokens semânticos validados, sem
  hex residual no QSS, com contraste AA nos pares essenciais e shimmer sem vazamento.
- **Execução resiliente**: status assíncrono sanitiza stderr, expira, cancela e
  limpa processos deterministicamente; resultados ficam privados e argumentos
  continuam sem shell.
- **Portabilidade preparada**: estado, permissões, elevação, abertura de caminhos
  e encerramento de processos foram isolados; plataforma Windows simulada não
  expõe ações Linux nem seletor de boot.
- **Steam ROM Manager — parsers faltantes**: `normalize_srm_parsers` só cobria
  Switch/PSX/PS2/PS3/PS4/Xbox360. Adicionados parsers PhaseZero-managed para
  GameCube, Wii, Wii U, N64, SNES, NES, GBA, GB e PSP apontando para os launchers
  corretos (Dolphin, Cemu, RetroArch cores, PPSSPP). Essas ROMs agora viram
  shortcuts Steam e aparecem no Big Picture.
- **Keys/firmware centralizados quebrados no Game Mode**: `import_switch_keys`
  short-circuitava quando o Ryujinx já tinha keys, deixando o store central
  (`~/Emulation/firmware/switch/keys`) vazio; Eden/Citron linkavam ao Ryujinx em
  vez do central. Agora o store central é sempre populado e Eden/Citron/Ryujinx
  linkam a ele (prioridade central > Ryujinx > cópia). Corrige o prompt
  reincidente de keys/firmware ao abrir emuladores no SteamOS Game Mode.
- **Pastas Emulation duplicadas**: layout canônico não declarava `keys`,
  `hdpacks`, `texturepacks`. `pz_emulation_consolidate_aliases` agora cria
  symlinks de compatibilidade (`keys → firmware/switch/keys`,
  `texturepacks/hdpacks → texture_packs`) para dirs vazios, sem clobber de
  conteúdo real do usuário.
- **Mídia órfã não limpa**: o índice de mídia mapeava rom→mídia mas nunca
  computava o inverso. `media-index.py` agora emite `orphanedMedia` (mídia sem
  rom correspondente) e `media.sh clean [--apply]` move esses arquivos para
  `~/Emulation/.phasezero/backups/orphaned-media-<data>/` (backup, não delete).
- **Eden EmuDeck SRM glob recursivo**: o template opcional em
  `~/.config/EmuDeck/.../nintendo_switch_eden.json` usava glob `**/` recursivo,
  que descia em `Nintendo Switch (DLC)/(Update)`, `Mods`, `Firmware`, `_backup`,
  `Torrent`. Agora usa glob não-recursivo `${title}@`, alinhado ao SRM ativo.
- **SteamOS session robustez**: `steamos-session.sh` agora valida `steam` além
  de `gamescope-session-plus` e registra instruções de instalação quando algum
  falta, antes de cair para desktop (antes do fallback silencioso para Plasma).

### Adicionado
- **Ação `emulation media clean`** exposta no `pz`, `catalog.py` (card "Limpar
  mídia órfã") e `actions.json` regenerado. Dry-run por padrão; `--apply` move
  para backup.
- **Central de Controle nativa completa**: catálogo canônico com 250 ações,
  parâmetros tipados, busca global e seção contextual Avançado cobre comandos
  Linux públicos e todos os perfis sem exigir descoberta pelo terminal.
- **UX operacional**: skeleton sem flash para respostas rápidas, saúde assíncrona,
  preview seguro, confirmação explícita para alto risco, progresso cancelável,
  resultado/histórico, breadcrumb, barra de estado persistente e navegação por teclado.
- **Contrato público**: `linux/pz commands --json` expõe o mesmo catálogo usado
  pela UI; gates detectam IDs/comandos duplicados, parâmetros ausentes, ações
  mutáveis sem preview e funções não renderizadas.

### Notas
- **SteamOS pré-requisitos**: a entrada GRUB `PhaseZero SteamOS Console` exige
  `gamescope-session-plus`, `steam` e `sddm` instalados (todos verificados no
  host). Sem eles, a sessão cai em Plasma com log de diagnóstico.

## [1.4.0] - 2026-07-09

Foco: fechamento de lacunas Linux/Windows — autenticação dos proxies de IA,
economia de contexto para Codex/Claude e release de pacotes atualizados.

### Adicionado
- **Proxies de IA Linux — auth/login**: `pz ai proxies auth [id]` retorna
  `webValidation` redigido compatível com o contrato Windows; Kimi/Qwen/DeepSeek
  usam `browser-session` e Mimo usa `env-session`.
- **Login real via UI/CLI**: `pz ai proxies login kimiproxy|qwenproxy|deepsproxy`
  abre Chromium visível, para o serviço user antes do login para evitar lock
  Playwright headless, grava log/estado em `~/.local/state/phasezero/ai-proxies/`
  e reinicia o serviço após o fluxo terminar.
- **Central de Controle**: novos cards "Auth proxies IA" e login dedicado para
  Kimi, Qwen e DeepSeek.
- **Token economy**: `pz ai token-economy status` como alias explícito de
  compatibilidade para validar RTK, ai-memory, Headroom e `ai-context-frugality`
  em Codex/Claude sem auto-wrappers.

### Corrigido
- **Portabilidade Windows→Linux**: o status de autenticação dos proxies agora
  espelha `webValidation.required/kind/status` sem vazar nomes ou valores de
  credenciais; Mimo reporta apenas grupos genéricos faltantes.
- **Bind seguro por padrão**: wrappers Linux definem `PZ_BIND_HOST=127.0.0.1`;
  Kimi/Deep/Mimo recebem patch compat local para não expor listeners em `0.0.0.0`
  quando executados como serviços PhaseZero.
- **Teste Linux de proxies**: `tests/linux-ai-proxies.sh` foi isolado de configs
  reais do usuário e corrigido para a porta Mimo 3013.
- **Documentação Linux/Windows**: README, `docs/ai-tools.md` e
  `docs/linux-ai-proxies.md` documentam login, auth, token economy e paridade
  Windows/Linux.

## [1.3.0] - 2026-07-08

Foco: Homelab CX — o servidor caseiro (Docker Compose) ganha status/plano rico,
geração segura de segredos, modos de acesso explícitos, backup/restore/update e um
gate de compatibilidade CasaOS opt-in. UI nativa e dashboard web legado atualizados.

### Adicionado
- **`pz server homelab`** ganhou `plan`, `open <app>`, `logs <app>`, `backup`,
  `restore --source PATH --yes`, `update` e `repair`, todos com saída JSON estruturada
  (`status`, `blockers`, `nextSteps`, `apps[]` com URL/bind/volumes/estado).
- **Segredos gerados automaticamente**: `pz server homelab repair`/`up` cria um `.env`
  seguro (`chmod 600`, fora do repositório) com tokens/senhas aleatórios para
  Vaultwarden, Nextcloud, Grafana, Paperless e n8n; nunca inline no compose.
- **Modos de acesso explícitos**: `--access local` (padrão, tudo em `127.0.0.1`),
  `--access tailscale` (expõe apps sensíveis apenas no IP Tailscale, bloqueado se
  deslogado) e `--access lan` (opt-in, `0.0.0.0`). Nenhuma porta fica exposta à WAN
  por padrão.
- **Imagens Docker fixadas por tag** (Portainer, Jellyfin, Syncthing, Vaultwarden,
  Uptime Kuma, Nextcloud, Grafana, Prometheus, Paperless, n8n) — sem `:latest` —
  com overrides `PZ_IMAGE_*` para quem quiser trocar a versão.
- **`pz server casaos`** (`status`/`plan`/`install`): gate de compatibilidade para
  CasaOS real. Detecta distro/arquitetura e bloqueia Arch/SteamOS/BigLinux/Manjaro;
  instalação permanece opt-in (`--yes`) mesmo em hosts compatíveis (Debian/Ubuntu/
  Raspberry Pi OS). O caminho padrão do PhaseZero continua sendo a stack Docker
  Compose + Portainer.
- **UI nativa**: 26 novos cards na categoria Servidor (status, planos, subir/parar,
  abrir apps, logs, backup/restaurar/atualizar, Tailscale, CasaOS). **Dashboard web
  legado**: nova página "Servidor" e lista de perfis `server-*` atualizada.
- **Testes**: `tests/linux-homelab.sh` cobre sintaxe, tags fixadas, binds seguros,
  bloqueio por segredo ausente, `.env` sem vazar segredo, `docker compose config`,
  bloqueio por Tailscale deslogado, URLs de `open`, dry-runs de backup/restore e o
  gate de compatibilidade CasaOS (Ubuntu ok, Arch bloqueado).

### Corrigido
- **Empacotamento (.deb/.rpm)**: `packaging/linux/deb/build-deb.sh` e
  `.../rpm/build-rpm.sh` copiavam `control`/`.spec` sem sincronizar o campo
  `Version` com `version.json` — um `.deb`/`.rpm` publicado podia reportar a
  versão anterior. Os scripts agora derivam a versão de `version.json` na cópia
  de build, sem alterar os arquivos versionados.
- **Empacotamento (AppImage)**: `build-appimage.sh` construía o AppDir dentro do
  checkout do repositório; em filesystems FUSE (ex.: NTFS-3g), a compactação
  paralela do `mksquashfs` podia descartar silenciosamente arquivos da stdlib do
  Python (`encodings/` incluído), gerando um AppImage que falhava ao abrir com
  "Failed to import encodings module" sem nenhum erro no build. O script agora
  usa por padrão um diretório temporário (`/tmp`, tmpfs); `PZ_APPIMAGE_WORK`
  continua disponível para quem sabe que seu filesystem é seguro.
- **Empacotamento (Flatpak)**: `build-flatpak.sh` exigia que o `--state-dir` do
  `flatpak-builder` ficasse no mesmo filesystem do diretório de build/repo (ele
  usa hardlinks entre os dois); agora todos os três (`state`, `build`, `repo`)
  vão por padrão para um diretório `/tmp` (tmpfs) recém-criado.
- **Bit de execução perdido no git**: este repositório tem `core.fileMode=false`
  (necessário porque o checkout roda sobre um mount FUSE/NTFS-3g, que não reporta
  mudanças de permissão de forma confiável) — isso fez o modo rastreado pelo git
  de `linux/pz`, `linux/ui/native.sh` e outros scripts de entrada regredir para
  não-executável, embora funcionassem localmente (tudo aqui é chamado via
  `bash script.sh` explícito). O `.deb`/`.rpm`/AppImage não foram afetados (usam
  `cp -a` da árvore de trabalho local), mas o pacote AUR e o Flatpak buscam a
  fonte de um `git clone`/tarball da tag publicada — e um `git clone` limpo do
  GitHub também teria `linux/pz` sem permissão de execução, quebrando o uso
  documentado no README (`linux/pz <comando>`, sem prefixo `bash`). Corrigido o
  modo rastreado pelo git para os scripts que o README/empacotamento invocam
  diretamente; o manifesto do Flatpak ganhou um `chmod +x` defensivo adicional.

**Nota:** a tag `v1.3.0` foi movida (recriada apontando para o commit com esta
correção) pouco depois da publicação inicial, já que o bug do bit de execução
afeta a fonte buscada pelo AUR/Flatpak diretamente pela tag.

## [1.2.0] - 2026-07-07

Foco: trilha Linux — IA/agentes, servidor caseiro, correções de emulação/Steam Deck
e redesign da Central de Controle. Os fluxos Windows não são afetados.

### Adicionado
- **Servidor caseiro**: perfis `server-llm`, `server-homelab`, `server-homelab-hermes`,
  `server-llm-hermes`, `server-llm-homelab`, `server-llm-homelab-hermes` e módulo
  `linux/server/` (`pz server status|llm|homelab|hermes|slim|boot`). Entrada GRUB
  `PhaseZero Homelab (headless)` (`multi-user.target` + `phasezero.homelab=1`, SO enxuto
  reversível) via `sudo pz server boot install`.
- **Proxies de IA nas IDEs**: `pz ai proxies configure-ides` conecta kimi/qwen/deeps/mimo
  ao opencode, opencode-desktop e zcode; `pz ai proxies test` faz probe honesto.
- **Acesso host↔guest**: `pz windows-vm host-access` (guestmount) e `pz waydroid host-access`
  (link ao armazenamento Android); bind opcional do home completo no Waydroid
  (`PZ_WAYDROID_SHARE_FULL_HOME=1`).
- **Perfis de controle Steam Deck**: `pz emulation controllers apply` (Ryujinx/RPCS3).
- **Central de Controle** redesenhada no estilo EmuDeck (dashboard, sidebar agrupada,
  cards com badges de estado, tema escuro roxo, toasts) — expõe todos os recursos acima.

### Corrigido
- **OpenCode "Interrompido"** (CLI/desktop): o padrão era um modelo Ollama local lento
  que estourava o timeout; agora usa um modelo free keyless do OpenCode Zen
  (`deepseek-v4-flash-free`), com Ollama como provider offline. `pz ai opencode free-model`.
- **Steam ROM Manager** não percorria ROMs e "Test/Parse" falhava com "invalid
  configuration": `${racores}` mapeia para `environmentVariables.raCoresDirectory`
  (Settings), que estava vazio; agora aponta para os cores do RetroArch.
- **Emulation Station** ignorava o Switch por um `noload.txt` órfão na raiz do sistema
  (auto-heal em `media.sh`).
- **Mídia** unificada para RetroArch flatpak (e DuckStation/PCSX2 flatpak).
- **BigBox** usa aceleração de hardware (DXVK) em vez de renderização por software.
- **Decky/CSS Loader**: a antigravity-proxy saiu de `:8080` (porta do CEF do Steam) para
  `:8090`; `plugins.sh` detecta conflito real de `:8080`.
- **Windows VM**: `HOME` e `/mnt/sdcard` agora são bind-montados (não symlinks) e expostos
  no SMB embutido do SLIRP (`\\10.0.2.4\qemu` → `home/`, `sdcard/`).
- **Portas dos proxies** movidas para 3010-3013 (evita colisão com open-webui/uptime-kuma).

## [1.1.0] - 2026-07-06
- Integrações do Control Center e proxy suite; sessões Gamescope; boot direto de
  Windows VM/Waydroid; instalação limpa LaunchBox/ES-DE. (Ver histórico git.)
