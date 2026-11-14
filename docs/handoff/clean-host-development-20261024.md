# Continuidade PhaseZero em host limpo — 2026-10-24

## Dependências do Windows portátil — 13/11/2026

Runtime `f573d408fb9efea1f4bc4adf457641e10db0eb7b` no WindowsSD, revisão
[PR #137](https://github.com/Misael-art/phase-zero/pull/137). Pacote reconstruído
pelo empacotador canônico. Sete arquivos atualizados e 108 hashes conferidos
no cartão. Sete arquivos de instaladores/modelo já verificados foram preservados.
O inventário existente registra a intervenção em
`ai_windows.dependency_preparation`. A recuperação privada contém o manifesto
anterior, os arquivos substituídos e o inventário anterior.

**Dependências de aplicativos e projetos** verifica Visual C++ x86/x64,
DirectX legado Win32, .NET Framework, .NET Runtime, Desktop Runtime, SDKs,
WebView2 e MSVC. O mesmo inventário informa frameworks Store por conta.
DirectX Win32 usa o instalador EXE WinGet e exige DLLs legadas por arquitetura.
Codex Desktop resolve Visual C++ também pelo caminho simplificado. A interface
separa consulta de instalação, grava o resultado e verifica os componentes ao
reabrir. O [contrato do preparador e do Autofix](../roadmaps/ai-memory-portability-v1.md#contrato-para-preparador-e-autofix)
documenta as ações de inventário, janela e fila.

O [ensaio Windows do pacote](https://github.com/Misael-art/phase-zero/actions/runs/43528916652)
passou a etapa de dependências em PowerShell 5.1. WPF abriu duas vezes, o JSON
usou inventário do runner, e fixtures verificaram os resultados do instalador,
reinício, interrupção, reabertura e repetição. No Jupiter, passaram os dois
smokes PowerShell 7.6.6 e dois testes Python. A atualização foi serial e
limitada a cerca de 2 MiB de arquivos de runtime, após baixar a pressão de
memória. A amostra anterior à cópia mostrou cerca de 6,1 GiB disponíveis, sem
swap-in/out nas amostras de um segundo, 61 °C e trip passivo de 100 °C.

Próximo aceite: boot físico do cartão, execução dos instaladores selecionados,
teste dos aplicativos e nova consulta após reinício. O Autofix tem contrato
disponível para consumir. A gravação ai-memory continua pendente porque a
unidade está mascarada/inativa e a conexão local foi recusada. O registro
privado da auditoria preserva o corpo original e o complemento de implementação.

## Preparação de memória no Windows — 12/11/2026

Código `c6d9ab6922fbf54b53025c0cbe225e46b6ecd6ce`. Runtime de memória
empacotado pelo checkout canônico e preparado no cartão, em
`Program Files\PhaseZero`, com entrada no menu Steam Deck. Não é outro
checkout nem outro banco. `INICIAR.cmd` abre o preparador nativo; o owner
continua sendo `linux/ai/memory_manager.py`, chamado pelo adaptador Windows.

Release ai-memory 3.3.1 verificada, companion oficial compilado em CI com um
job e cache semântico local conferido pelos hashes do upstream. O servidor
recebe `RAYON_NUM_THREADS=1` e `OMP_NUM_THREADS=1`. A preparação local usou
CPUQuota 50%, MemoryMax 768 MiB e cópia serial limitada a 4 MiB/s. Nenhuma VM
ou compilação Rust foi iniciada no host físico.

Passaram cinco contratos PowerShell e dois testes Python do runtime instalado.
O [ensaio Windows nativo](https://github.com/Misael-art/phase-zero/actions/runs/43185528162)
passou com PowerShell 5.1: janela WPF renderizada, regras nos arquivos globais,
MCP/hooks para Codex e Claude Code, task de servidor, backup online,
restauração com configuração preservada e rejeição de companion alterado.

O pacote prepara a instalação; ainda é necessário executar o preparador dentro
do Windows, entrar nas contas e recuperar o histórico privado com a chave
existente. Não foram transportados tokens, cookies, banco SQLite ativo,
hostId ou referências do cofre Linux. O destino privado existente consta
somente do inventário de preparação; não é publicado nas instruções.

Próximo gate: boot físico, instalar pelos fluxos oficiais, importar recuperação,
verificar/restaurar o backup, escolher as pastas reais deste Windows e validar
uma consulta MCP em cada aplicativo e a sincronização autenticada. Downloads
grandes permanecem manuais sem autorização explícita. Não tratar o ensaio
de CI como aceite do hardware, das contas ou da transferência do histórico.

## Correção do autologin e central Vibe Code — 10/11/2026

O boot físico selecionado confirmou `phasezero.vibe=1` e o alvo dedicado.
O journal mostrou `runuser` abrindo PAM durante a preparação. A unidade
atingiu o timeout antes de gravar o drop-in transitório. O SDDM apresentou o
greeter e o operador entrou manualmente. Fôlego iniciou pelo autostart
próprio nessa sessão.

Correção `6dcf9e14`: validar o launcher com `setpriv` no UID e grupos
do operador, sem abrir PAM. Bigsudo ensaiou o helper real com o cmdline
do boot selecionado e diretório descartável. Gerou `Session=plasma.desktop`
e `Relogin=false`, validou o vínculo do SDDM e substituiu o helper de forma
atômica. Backup
`/var/lib/phasezero/vibe-code/session-before-pam-fix.J5UJE0`.
Entrada BigLinux do GRUB continua disponível. Novo boot físico pendente.

Runtime de usuário `1.22.17+vibe.ff03b8d9` ativo. Janela em duas abas e
layout adaptável com OpenCode Desktop, Codex Desktop e Claude Desktop em
destaque. Busca reúne atalhos XDG e detalhes canônicos da Central.
Atalho Claude Code Desktop chama a ação `NewCode` publicada pelo
aplicativo. Atalhos CLI usam a pasta do projeto. GIO permanece responsável
pelo lançamento, inclusive quando `Exec` contém caminho entre aspas.

Wayland real: abertura pelo menu, largura lógica aproximada de 850 px,
capturas ampla e compacta. OpenCode e Claude abriram janelas novas. Codex
aceitou o lançamento e manteve uma única janela. Codex CLI, Claude Code e
OpenCode CLI responderam à consulta de versão. Fôlego, OpenClaw, Grok Build
e DeepSeek Harness foram encontrados no menu. Atalho disponível não atesta
conta autenticada ou inferência. Passaram 69 testes focados e os smokes de
recuperação de boot e do gerenciador de desktops IA. Recibos e capturas privados em
`~/.cache/phasezero-dev/tmp/vibe-correction.luC9wP/`.

`pz boot vibe-code apps --yes` preparou o inventário. Qwen Code Desktop
permanece pendente porque o AppImage oficial excede 70 MB. O comando informa
origem, destino e SHA-256 para depósito manual verificado. OpenClaw local
aparece via seu AppImage; serviço gerenciado continua sujeito aos grants.

## Instalador e boot Vibe Code — 10/11/2026

Código `627ba19a`. `pz boot vibe-code` no checkout e no runtime de usuário
`1.22.17+vibe.627ba19a`. O plano neste BigLinux detecta somente `pnpm`
ausente. A resolução pacman previa só `pnpm 12.9.1-1`; o instalador recusa
atualizações implícitas de dependências existentes. Receita e recuperação em
[Vibe Code no Linux](../roadmaps/apps-dev-ai-accounts-v1.md#vibe-code-no-linux).

GRUB deriva kernel, initramfs e argumentos de `10_linux`. A transação faz
backup, valida a sintaxe e acrescenta somente o próprio bloco à configuração
ativa. O alvo systemd dedicado pede SDDM, que recebe configuração transitória
de login automático apenas quando o boot contém `phasezero.vibe=1`.
O helper confere launcher e sessão Plasma e usa `Relogin=false`.

Validação local: 67 pytest focados, smoke `linux-boot-recovery.sh` e ShellCheck.
Bigsudo confirmou leitura das entradas existentes e ausência de autologin
local conflitante. Instalação privilegiada concluída em 10/11 às 16:02 (-03).
Pacman instalou somente `pnpm 12.9.1-1`; o executável informou `11.28.4`.
`grub.cfg` ativo passou no validador e na comparação do conteúdo fora
do bloco Vibe Code. Backup em `/var/lib/phasezero/vibe-code/backup.L8qLXt`.
Alvo dedicado carregado; SDDM ativo com a preparação ordenada antes dele.
O operador pode reiniciar e selecionar **PhaseZero Vibe Code (Plasma)**.
**BigLinux** continua como entrada de recuperação. Base do boot normal
capturada com `systemd-analyze` em
29,932 s até a inicialização do sistema. O número não mede prontidão do
launcher. Próximo gate é medir no boot selecionado, verificar logout e retorno
ao SDDM e confirmar abertura das ferramentas. Recibo privado do lote em
`~/.cache/phasezero-dev/tmp/vibe-boot.WPeFnp/`.

## Vibe Code no Linux — 10/11/2026

Branch `codex/vibe-code-profile`, código validado `77e1a8d7`. Início,
Desenvolvimento e menu PhaseZero abrem o mesmo launcher. Pasta e editor ficam
em estado privado. IDE, Konsole, Dolphin, Kate e navegador padrão abrem sob
demanda. Receitas e contas usam as superfícies existentes. Plano e gates em
[Vibe Code no Linux](../roadmaps/apps-dev-ai-accounts-v1.md#vibe-code-no-linux).

Host BigLinux/Plasma Wayland: runtime de usuário
`1.22.17+vibe.77e1a8d7` ativado pelo link `current`, mantendo a base
`1.22.17` recuperável. Deploy composto de seis arquivos de runtime da frente
Vibe Code sobre a instalação existente, conferidos por conteúdo. Entrada
gerenciada de menu instalada. Autostart do Plasma ativado, com serviço
gerado e condição KDE conferidos em diretório descartável. A opção do
launcher remove seu próprio autostart.

Validação: 63 testes focados, ShellCheck e diff check. Menu abriu janela no
KWin real. Na jornada de QA Wayland, IDE e terminal abriram na mesma pasta
com espaços; Konsole confirmou cwd físico e `PWD`; `node --test` passou;
Brave abriu o preview loopback com perfil e handler de QA; reabertura e
pasta renomeada passaram. Recibos privados em
`~/.cache/phasezero-dev/tmp/vibe-code-host.8S3zHQ/`.

Gates: nova entrada no Plasma para observar o autostart. Overlay Hyprland
0.56 foi aceito por `--verify-config` junto da base do host; sessão e
bloqueio físicos seguem pendentes. Autologin SDDM, recuperação pelo greeter
e TTY e comparação de desempenho aguardam teste físico. Catálogo assinado
`practices-not-configured`; memorial local usado, achados registrados em
`decisions/vibe-code-plasma-terminal-browser-20261110.md` no ai-memory.
Push recusado pelo guard local porque a branch Vibe Code está fora da
continuidade registrada. Incremento preservado na branch local.

## Contas e conexões: carteira e gestão de chaves — 07/11/2026

Incremento de código `a6e5e06fcd0f16b6f1bbe072ffeed6b8a4c50357`, branch de revisão
`codex/accounts-key-manager`, sobre `b7c223b643dd41a70a67d584c3ba6973c41de154`
(PR #133). O commit local equivalente é `0495c9c703638c49cecb779d2dc31b0a8fb8667b`.
Essa base preserva os launchers Grok/DeepSeek já instalados, sem publicar os
commits de outras frentes da branch local. AGENTS, alterações anteriores deste
handoff e reparo de touch permaneceram fora do incremento.

Contas agora separa sessões observadas, registros/perfis locais, plataformas e
chaves. Perfis não comprovam identidades distintas. Cotas preservam unidade,
fonte e horário; renovação aparece quando informada. Ver todas as contas mantém
Codex e os consentimentos existentes. Gerenciar chaves abre busca, filtros,
ordenação e detalhe por chave com cadastro/idade, origem e vínculos gerenciados.
A carteira continua CredentialVault/cofre nativo, sem novo banco ou segredo na
listagem. Criação no provedor, validade, expiração, saldo e última requisição
permanecem desconhecidos quando faltam dados. Revisão de cadastro após 90 dias
é lembrete local, não prova de comprometimento. Lista usa acesso da sessão local;
autorização/desbloqueio do cofre continua nas operações nativas, sem falso gate.

Cobertura de uso: DeepSeek Harness selecionado por referência exata, com estado,
pasta sugerida, supervisor e horário da observação. Uso externo segue desconhecido.
Revogar uso encerra e desfaz somente esse vínculo. Remoção segura serializa
encerramento e exclusão local com a trava do próprio manager; falha ao parar
preserva a chave. Substituição cadastra outra chave e exige seleção/consentimento
no consumidor. Nenhuma revogação no provedor ou grant de proxy é presumida.

Validação: 203 pytest focados passaram em 59,27 s; jornadas claro/escuro em
100/150/200%, 800×600 e 1280×800, teclado, privacidade, filtros e reabertura.
Qt/Xvfb exercitado no host. Secret Service real com chave inválida própria e
Harness real 0.2.1-rc.2/Node privado existente passaram: cadastro pela UI,
observação, revogação, reinício explicitamente selecionado e parada antes da
remoção. Recibo privado: `~/.cache/phasezero-dev/accounts-host.PdF0J4/receipt.json`.
Sem login de operador ou inferência. Venv de testes não contém PyGObject; o teste
nativo usou Python do launcher, sem trocar backend por arquivo.

Smoke do pacote instalado em raiz descartável passou. Instalador oficial de
usuário aplicou fonte imutável do SHA de código acima; versão nominal continua
1.22.16, sem tag/release nova. Backup anterior:
`~/.local/share/phasezero/backups/1.22.16.20261107085718.600230`.
Os sete arquivos Linux alterados coincidiram byte a byte com esse SHA. Launcher
instalado abriu Contas e conexões em Xvfb e encerrou pelo smoke normal; evidência
privada em `~/.cache/phasezero-dev/accounts-installed.WHyvxm/accounts.png`.

Próximo gate: CI do SHA de revisão e integração do PR #133 antes deste incremento.
Na consulta da base, python-test estava vermelho; demais checks executados
passaram. Windows, conta/cota reais, uso externo, leitor de tela e toque físico
não foram homologados. Não houve merge/release. Catálogo assinado de práticas
retornou practices-not-configured; memória local e memorial do checkout usados.

## Preferência de microfone após deriva de perfil — 06/11/2026

Código `154225b3e4b7dcf4a21331e297eefe893a08b588` na branch de
continuidade. O watcher PhaseZero capturava o áudio a cada três segundos; um
`pro-audio` com `Int Mic`/`DMIC Enable` desligado podia substituir o snapshot
`HiFi (Mic, Speaker)` antes de o Fôlego reparar. Agora, quando a entrada padrão
continua `mic-biglinux`, essa captura falha e preserva a referência interna;
o próximo ciclo reconcilia. Headset indisponível também não substitui a
referência. Microfone externo padrão e Pro Audio com ambos os controles ligados
continuam ajustes capturáveis. Contrato em
[steamdeck-kde-input-v1.md](../roadmaps/steamdeck-kde-input-v1.md).

Validação: 27 casos de `tests/test_desktop_session.py` passaram em HOME/XDG e
temporários privados em disco com Python 3.14.7/pytest já provisionados pelo
Fôlego. O wrapper PhaseZero `doctor --profile core` recusou o venv ausente;
nenhuma instalação privilegiada foi feita. No host, serviço próprio reiniciado
uma vez, `active/running` PID 307531; sem jogo/lease, perfil salvo interno,
fonte padrão `mic-biglinux`, nenhuma fonte de headset salva. O Fôlego mantém
as duas referências saudáveis, zero tentativas e disjuntor vazio. Não houve
troca artificial do perfil ou teste do efeito no hardware falho. Alterações
preexistentes de `AGENTS.md`, deste handoff e o script de touch não integram
este incremento. Commits de código e handoff estão na branch registrada,
SHA remoto `09c99430f63d2fc676b5b4340cf8e3ef2178bc03`. PR #132 draft:
o diff inclui commits anteriores dessa branch ainda fora da `main`. Uma
branch isolada foi preparada sem novo checkout, mas a guarda de push recusou
publicá-la fora da continuidade registrada; o bloqueio não foi contornado.
CI do PR estava em andamento na última consulta; não há merge/release.

## Integração manual de entrada — 30/10/2026

Correção posterior após teste do operador sem dock: pedir senha sem teclado
utilizável bloqueava o reparo. `recover-touch`/`persist-touch` agora só pedem
privilégio após confirmar o painel nativo visível. Mantêm modo 2 temporário
durante a autenticação, reabrem o painel ao mudar o foco para outro cliente de
texto e restauram o modo anterior (0 retorna a 1). Não recebem nem registram
senha. `keyboard-mode.lock` serializa essa janela explícita com a política
normal; o watcher cede enquanto a trava está ocupada. Não há mudança permanente
para abertura automática por mouse/trackpad. Timeout continua incerto.
`tests/test_desktop_session.py`: **22 passed em 7,57 s**, ambiente compatível
isolado, incluindo ausência de teclado sem root, troca de foco, cancelamento e
timeout com restauração. Não certifica digitação na autenticação física sem dock.
O serviço residente precisa carregar essa revisão para respeitar a trava.
Espera de até um segundo pelo painel evita confundir ativação assíncrona com
ausência; repetição final do mesmo foco: **22 passed em 6,37 s**. Serviço próprio
recarregado para a coordenação; autenticação física sem dock segue pendente.

Base `bdbfed30bf5bef0a523d8246ff5057e2b24829be`, mesma branch/PR #129.
O incidente do Fôlego exigiu separar solicitação manual de entrada da
reconciliação geral: `desktop_session.py reconcile-input` executa somente
`protect_input`, retorna schema 1/escopo `input` e erros explícitos. Não chama
restauração/captura de áudio, modo do teclado ou Steam. Watcher inalterado.
Fôlego verifica lease/jogo/pendências, identidade e hash antes da chamada e
confere o resultado no compositor. API não concede exclusividade global.

Validação local: `tests/test_desktop_session.py`, **19 passed em 7,11 s**,
incluindo dois casos de separação de escopo/erro. Python 3.14.7 + pytest
emprestados do ambiente gerenciado já existente do Fôlego, HOME/XDG/TMPDIR
privados em disco; nenhum efeito no host como fixture. O `doctor --profile core`
do wrapper PhaseZero recusou o venv core ausente/incompleto; não houve instalação
global nem promoção desse teste focal a gate completo do PhaseZero. Evidência
privada no lote `run-accessibility-incident-20261030/phasezero-qa` do Fôlego.
CI da base já apresentava falha `shell-lint (0.9.0)` e Pester em andamento;
essa falha não foi contornada por alteração de regras. Login físico, teclado,
toque e áudio continuam exigindo aceite próprio; sem merge/release.

## Ponto de partida e limite da prova

`main` auditada em `ddadd6de4fc5a0b8933c2d312e2f8a6dd7f1aff3`; release beta `v1.22.11` aponta ao mesmo SHA. [Auditoria versionada](../audits/status-20261024/README.md) contém evidências, capturas, lacunas e critérios de aceite. Clone de `main` basta para começar desenvolvimento da base publicada. Para continuar WIP sem acesso ao cartão, usar o resgate privado verificado abaixo. GitHub **não contém** contas, tokens, VM guest, dados de Homelab nem configuração do host.

Este wrapper/handoff está na branch `codex/clean-host-dev-bootstrap`, [PR #129](https://github.com/Misael-art/phase-zero/pull/129), até merge. Em host novo, após clone de `main`, execute `git fetch origin codex/clean-host-dev-bootstrap` e `git switch --track origin/codex/clean-host-dev-bootstrap` antes de usar os comandos abaixo. Se usar ZIP sem Git, baixe o ZIP **dessa branch**. Após merge, `main` passa a incluir o wrapper.

Não interpretar CI/fixture verde como homologação física de conta, proxy, VM ou segundo host. Nenhum instalador do produto, VM, container ou serviço deve iniciar no bootstrap de desenvolvimento.

## Resgate remoto do trabalho local, sem cartão

Em 2026-10-24, WIP de código dos 18 worktrees foi copiado para o repositório GitHub **privado** [`Misael-art/phase-zero-continuity-20261024`](https://github.com/Misael-art/phase-zero-continuity-20261024), release [`rescue-20261024`](https://github.com/Misael-art/phase-zero-continuity-20261024/releases/tag/rescue-20261024). Requer login na conta GitHub autorizada. Inclui bundle/gitdir, quatro patches, dois arquivos de untracked selecionados, manifestos e instruções de restauração. O tar de 107642880 bytes tem SHA-256 `6b24e25ad4b7824aa81adfea305087db699c0a8f5b74189b3355de1b32200a80`; upload e download remoto foram conferidos por hash. O resgate foi varrido com Gitleaks 8.18.4 sem achados, prova limitada ao conteúdo varrido.

Asset adicional `phasezero-additional-wip-20261024.tar.gz` (SHA-256 `e0a353d41fb42b0e56b1d8fcddd66dc174c333b8593598417c5d6c3dd96ecd73`) guarda quatro patches de stash antigos e código avulso do snapshot `pz-wip-preserved-20260924-pr102`. Exclui expressamente `.mimosa/` e `uber-defesa-privada/`. Gitleaks 8.18.4 no conteúdo extraído: zero achados. Restaurar somente após inspeção; não pressupor que o material antigo ainda se aplica ao HEAD atual.

No host novo, instalar `gh` pelo gerenciador de pacotes oficial ou baixar os dois assets pelo navegador já autenticado. Com `gh`, executar em diretório separado do clone:

```bash
gh auth login
gh release download rescue-20261024 -R Misael-art/phase-zero-continuity-20261024 -D phasezero-rescue
cd phasezero-rescue
sha256sum -c phasezero-code-rescue-20261024.SHA256SUMS
sha256sum -c phasezero-additional-wip-20261024.SHA256SUMS
mkdir extracted
tar -xf phasezero-code-rescue-20261024.tar -C extracted
mkdir additional
tar -xzf phasezero-additional-wip-20261024.tar.gz -C additional
```

No Windows, conferir SHA-256 via `Get-FileHash` ou Git Bash. Ler README do repositório privado e manifestos extraídos antes de restaurar. Inspecionar bundle e patches antes de aplicar no checkout canônico registrado; não recriar worktrees nem aplicar WIP sem revisão. O resgate **não** inclui `.mimosa/`, `uber-defesa-privada/`, VMs/ISOs, credenciais, sessões, ai-memory ou estado de serviços. Essas partes não podem ser reconstruídas só com GitHub. Windows VM local foi declarada descartável pelo operador.

## Primeiro uso, Arch / Manjaro / BigLinux

Necessário: rede e Bash/pacman do sistema base. Se Git ausente, obter o código pelo ZIP do GitHub via navegador ou instalar apenas Git pelo gerenciador da distro; `git clone` não pode preceder a instalação de Git. Após checkout:

```bash
git clone https://github.com/Misael-art/phase-zero.git PhaseZero
cd PhaseZero
git fetch origin codex/clean-host-dev-bootstrap
git switch --track origin/codex/clean-host-dev-bootstrap
bash tools/dev-bootstrap.sh plan --profile ui
bash tools/dev-bootstrap.sh install --profile ui --yes
bash tools/dev-bootstrap.sh doctor --profile ui
```

`plan` e `doctor` somente leem. `install --yes` instala pacotes mínimos com `phasezero-admin`, `bigsudo` real ou `pkexec`; num Arch mínimo sem esses três, usa `su` interativo com a lista fixa de pacotes. Root bloqueado ou ausência de TTY impede esse primeiro passo; habilitar polkit/bridge pelo administrador e repetir. Evita `pacman -Sy` isolado, recusa upgrades pendentes, root direto, pouca RAM/disco e prefixo temporário. Instala pip **somente em venv de usuário** sob `${XDG_DATA_HOME:-~/.local/share}/phasezero-dev/`; `core` é menor, `ui` adiciona PySide6/Xvfb/qemu-img para testes UI/VM em fixture. Não instala Docker, serviço, modelo, guest ou workload. O instalador mostra caminho do venv anterior para rollback; não apaga automaticamente versões antigas. Para reverter, remover apenas o link `venv-core` ou `venv-ui` e apontá-lo ao venv anterior, após verificar o destino. Pacotes do sistema instalados pelo pacman exigem revisão individual antes de remover.

Antes de testes longos, reservar temporários persistentes do usuário, **uma variável por export**:

```bash
export TMPDIR="${XDG_CACHE_HOME:-$HOME/.cache}/phasezero-dev/tmp"
mkdir -p "$TMPDIR"
export PYTEST_DEBUG_TEMPROOT="$TMPDIR/pytest"
mkdir -p "$PYTEST_DEBUG_TEMPROOT"
"${XDG_DATA_HOME:-$HOME/.local/share}/phasezero-dev/venv-ui/bin/python" -m pytest tests/test_product_inventory.py tests/test_accounts_page.py -q
```

Se o checkout veio de ZIP, rode `git init/remote/fetch` ou clone após o wrapper instalar Git; use o checkout Git para commits. Nunca executar `pip install` global nem misturar HOME isolado com XDG de produção. Para automações, cada atribuição `export HOME`, `export XDG_CONFIG_HOME`, `export XDG_DATA_HOME`, `export XDG_STATE_HOME` fica em linha separada.

## Primeiro uso, Windows

PowerShell 5.1 do sistema base. Se Git ausente, baixar o ZIP do repositório pelo navegador/PowerShell e expandir com `Expand-Archive`; o wrapper instala Git e Python para o clone definitivo. Em PowerShell no diretório extraído:

```powershell
.\tools\dev-bootstrap.ps1 -Action Plan -Profile Ui
.\tools\dev-bootstrap.ps1 -Action Install -Profile Ui -Yes
.\tools\dev-bootstrap.ps1 -Action Doctor -Profile Ui
.\tools\dev-bootstrap.ps1 -Action PythonPath -Profile Ui
```

Instala Git/Python pelo winget; caso winget falte, tenta o App Installer oficial da Microsoft e falha com motivo se a plataforma não permitir. Perfil `Ui` adiciona Pester/PSScriptAnalyzer ao **usuário atual**. Venv fica em `%LOCALAPPDATA%\PhaseZero\dev`; dois slots fixos limitam uso de disco, e o arquivo ponteiro seleciona apenas o slot validado. O outro slot preserva a versão anterior para rollback. Abrir terminal novo se PATH ainda não refletir Git/Python. `Install -Yes` pode solicitar elevação do instalador Git/winget; nunca cria sudo sem senha ou serviço PhaseZero.

## Fluxo de desenvolvimento limpo

1. Verificar `git status`, `git fetch origin`, SHA/tag, PRs e CI. Reutilizar checkout canônico e branch/PR de continuidade registrados. Preservar alterações locais alheias; não criar clones/worktrees. Não trabalhar em `/tmp`/`XDG_RUNTIME_DIR`.
2. Ler `AGENTS.md`, roadmap da área e esta auditoria. Reproduzir defeito e rodar baseline de testes afetados antes de editar. Separar mudanças por contrato e adicionar teste de regressão que observe efeito real, sem espelhar implementação.
3. Rodar validações locais com HOME/XDG sandboxados, temporários fora de `/run/user`, recursos monitorados. Sem VM física/boot, Docker real, login, pacote de produto ou alteração de serviço no host de desenvolvimento. Para gates físicos, usar host descartável/operação agendada, evidência antes/depois e rollback.
4. `git diff --check`, ShellCheck/Bash syntax ou Parser/Pester, pytest focal e CI. Revisar segredos e destinos de escrita. Commit pequeno, push, PR com SHA/base, prova, limites e próximo passo. Não promover release por suíte parcial.

## Fila de trabalho, ordem e aceite

| Prioridade | Frente | Ação concreta | Aceite necessário |
|---|---|---|---|
| P0 | Preservação | Recuperar resgate privado, conferir WIP Bonsai/WinVM, revisar segredos e publicar commits pertinentes em PRs próprios. | Hash remoto do tar, manifestos, bundle/patches revisados no checkout canônico e testes específicos antes de cada PR. Estado privado do host permanece fora do resgate. |
| P0 | IA/Contas | PXA-006/008/009: provar sessão/cota reais; grant vinculado a consumidor **e requisição**; fallback pago bloqueado. | G3 no provedor real, logs sem segredo e teste negativo de consumidor sem grant. Gateway saudável ≠ cada provider pronto. |
| P0 | WinVM | Integrar #114 antes de #116; revisar WIP de integridade esparsa. Não reusar guest apagado. | G2 Windows descartável: first boot, OVMF/TPM, QGA/rede, boot direto, tela/resolução, GPU fallback; ledger de RAM/disco e rollback. |
| P1 | ChatGPT Web | Integrar #117 antes de #122, com escopo/grants e recuperação após reboot. | Prova real read/write somente dentro da autorização, revogação e ausência de fallback indevido. Full ainda não certificado. |
| P1 | DeepSeek | #126 antes de #127. Manter experimental até conta real. | Login, inferência, cota/custo, cancelamento e rollback com conta própria; sem uso pago implícito. |
| P1 | Homelab | PZ-AUD-009/010/013: consistência DB↔anexos, restore, SSH onboarding em segundo host. | Backup/restore real em host descartável e primeiro acesso guiado; testes Docker locais não bastam. |
| P1 | UX | Jornada objetivo → app/perfil → conta/permissão → executar/abrir; ação principal única, próximo passo e estado funcional. | 800×600/1280×800, escala 100/150/200%, teclado/touch/leitor de tela e G4 com cinco participantes. |
| P1 | Entrega | Resolver #115 conflitante, #63 CI vermelho; alinhar README stable/beta e `pz ai help`. | CI exigida verde, canal de release explícito e help útil; release só após gates aplicáveis. |

Roadmaps de referência: [apps/IA/contas](../roadmaps/apps-dev-ai-accounts-v1.md), [remediação](../roadmaps/rev-remediation-v1.md), [WinVM](../roadmaps/winvm-boot-resilience-v1.md), [Homelab](../roadmaps/homelab-v1.15.1-remediation.md). Revalidar estados dos PRs ao iniciar; tabela é snapshot de 2026-10-24.

## Verificação desta entrega

- Arch atual: `plan` sem escrita; `install` exige `--yes`; `doctor` falha com venv ausente. Instalação real do perfil `core` em prefixo isolado, seguida por `doctor`, `pip check` e 29 testes (`test_product_inventory`, `test_profile_packages`) passou. Prefixo de fixture removido após teste. Nenhum pacman/serviço/VM/boot tocado.
- Bash syntax, ShellCheck, YAML parse e `git diff --check` verdes. CI inclui contrato hermético de prévia e criação real de venv em container Arch descartável; execução remota deve ser conferida no PR.
- Parser PowerShell 7.6 e Pester 6 local passaram (2/2: prévia sem mutação, instalação exige consentimento). Windows não foi executado neste host Linux; Parser/Pester 3.4 do job Windows são o gate de CI, e teste físico em Windows limpo permanece aberto.
- Diff textual revisado por padrões de segredo; `gitleaks` local indisponível. O job remoto `security-secret-scan` precisa passar antes de merge. Captura de Contas revisada visualmente: estado vazio, sem identidade ou token.
- Cartão de continuidade: `checks/verify_continuity.py` passou novamente em 2026-10-24, validando 18 worktrees, bundle, patches, untracked, gitdir e pacote; `sha256sum -c checks/SHA256SUMS` também passou para todas as 41 entradas. Isso prova integridade da cópia atual, **não** redundância física. O novo PR está no GitHub, fora do bundle anterior; buscar branch remota para obtê-lo.
- Um primeiro pytest local falhou porque o diretório de `PYTEST_DEBUG_TEMPROOT` definido manualmente ainda não existia; após `mkdir -p` conforme o exemplo acima, 29/29 passaram. Não tratar esse erro de preparação do teste como bug do produto.

## Handoff obrigatório ao encerrar próxima frente

Usar formato do roadmap Homelab: objetivo, IDs, branch/worktree, HEAD inicial/final, arquivos, commits, testes/resultados, CI/PR, estado do host antes/depois, segredos verificados, limitações/riscos, bloqueios reais e próximo passo **exato**. Dizer `fixture`, `CI` ou `host físico` em cada evidência. Nunca marcar gate físico como concluído por captura ou mock.

## Recuperação organizada — 2026-10-26

Raiz única neste host: `/home/misael/Projects/PhaseZero`, base `808108a9e4b9de528f5056b1715cf8cb21ed42dc`. Perfil UI preparado pelo wrapper e doctor aprovado; 42 testes de inventário/Contas passaram em Qt offscreen. Os dois resgates privados foram baixados e conferidos pelos hashes publicados. Histórico de 18 pontas preservado em refs locais de recuperação, sem recriar worktrees; patches conservados para revisão, três não aplicam diretamente à continuidade. Nenhum WIP foi mesclado nem serviço/VM/conta foi homologado. Próximo passo: revisar WIP por contrato e respeitar dependências dos PRs, usando o mesmo checkout.

## Correções de quota, atualizações e controles IA — 2026-11-01

Objetivo/IDs: corrigir seis defeitos confirmados e inconsistências de observação,
PXA-006/009. Owner: adaptadores IA e UI nativa. Raiz única
`/home/misael/Projects/PhaseZero`, branch `codex/clean-host-dev-bootstrap`, PR #129.
HEAD inicial `a2fb4ab49bf237ab0194d2a134d1de35539118f9`; commit de implementação
`72c81569b0469d38fa077b0c4c2fb7b53e6e61a3`; commit deste handoff identificável
por `git log -1 -- docs/handoff/clean-host-development-20261024.md`.

Arquivos: `linux/ai/quota_meter.py`, novo `quota_tray.py`, `desktop-apps.sh`,
`linux/pz`, `linux/ui_native/pages/ai_dev.py`; regressões em `test_quota_meter.py`,
novo `test_quota_tray.py`, `test_ai_quota_card.py`, `linux-ai-desktop.sh`.
README separa stable/beta; roadmap Apps/IA registra maturidade, dependências e aceite.
Instruções antigas deste handoff passam a usar checkout único.

Corrigido: cache Claude antes era compartilhado por TTL, reset passado inventava 100%,
callbacks liberavam controles, coleta HTTP bloqueava Qt, disable-updates descartava erro,
e aliases de ajuda IA não existiam. Cache agora considera credencial/conta/organização,
expiração e logout; dados vencidos/falhas ficam desconhecidos. Coleta tem processo único,
prazo global e encerramento; respostas de outra conta são descartadas. UI mantém trava
recebida e não transforma instalação/versão desconhecida em ausência/sucesso. Atualizações
exigem estado confirmado; ajuda reutiliza tabela CLI sem serviços.

**Fixture no host `misael-jupiter`, BigLinux/Manjaro:** doctor UI aprovado no ambiente
provisionado `/home/misael/.local/share/phasezero-dev/venv-ui`. Rodada final com fontes
congeladas, HOME/XDG privados, TMPDIR/PYTEST_DEBUG_TEMPROOT persistentes e Qt offscreen:
**149 passed em 124,43 s**:

```bash
QT_QPA_PLATFORM=offscreen /home/misael/.local/share/phasezero-dev/venv-ui/bin/python -m pytest \
  tests/test_quota_meter.py tests/test_quota_tray.py tests/test_ai_quota_card.py \
  tests/test_product_inventory.py tests/test_status_contract.py \
  tests/test_product_status_loader.py tests/test_catalog_visibility.py \
  tests/test_chatgpt_web_card.py -q
```

`bash tests/linux-ai-desktop.sh`: passou, incluindo systemctl stub com falha, ausência,
desabilitado, ainda ativo e repetição. Bash syntax, ShellCheck dos scripts alterados,
compilação Python e `git diff --check`: passaram. Caminho oficial `linux/pz ai quota status
--json` executado com rollout privado no host: observação vencida→desconhecido;
nova observação→5% restante, sem rede/conta/serviço. Primeiro preparo dessa fixture usou
CODEX_HOME fora do HOME canônico e não encontrou conta; corrigido para HOME/.codex,
respeitando o adaptador de perfis existente, sem mudar o produto.

Duas rodadas anteriores não são baseline válido: comandos Bash liam `linux/pz` enquanto
arquivo era regravado, produzindo erro transitório de sintaxe após JSON (130 e 142 testes
passaram, respectivamente). A rodada final congelada acima passou integralmente.
Sem gates desativados. Suites sequenciais, sem instalação, elevação, serviço, VM ou boot.
`linux/repairs/reparo-touch-auto.sh` alheio continua untracked e preservado.

**CI/PR:** checks da base observados verdes (jobs opcionais skipped). PR #129 reutilizado;
checks do novo SHA devem ser consultados após push e antes de merge. Sem merge/release/deploy.
Revisão local de diff, tamanhos (<10 MiB cada) e padrões de segredo sem achados;
Gitleaks local ausente, portanto scan remoto continua necessário. Nenhuma credencial real
usada nos testes adicionados. Memória histórica solicitada retornou 404 e busca exata vazia;
memória relacionada consultada via CLI disponível (MCP não exposto), aprendizado registrado
em `notes/phasezero-quota-cache-tray-fixes-20261101.md`.

**Alvo real/pêndencias:** nenhum aceite G2/G3/G4 novo. Bandeja do compositor real, duas contas
reais, Windows limpo, boot/display, Homelab remoto e usabilidade continuam pendentes;
fixtures Qt/CLI não os homologam. Grants 9Router continuam bloqueados até upstream vincular
conta/consumidor/requisição, com teste negativo e sem fallback pago. ADR 0005 preservada.
Próximo passo exato: conferir CI no SHA remoto; depois, com operador/ambiente descartável
autorizados, executar matriz conta A→B→logout→expiração→offline, comparar quota/plano com
origem oficial e verificar interação/fechamento da bandeja sob coleta lenta simulada.

## Release beta solicitada — 2026-11-01

Operador autorizou release e push após correções. `packaging/release.sh 1.22.12
--channel beta` preparou commit `5731c5cc5fcff3ae072fb82d4da6b765db3c78d8` e tag anotada
local `v1.22.12`, atualizando metadados oficiais de versão/pacotes. Branch de continuidade
foi enviada e SHA remoto confirmado. Três testes de canal passaram; diff do bump e
`git diff --check` aprovados. Código funcional conserva validação anterior de 149 testes.

**Bloqueio real:** push da tag recusado pelo hook central
`/home/misael/Projects/.workspace/hooks/pre-push` → `workspace.py:208`:
“criação, exclusão ou destino de branch fora da continuidade registrada”. O guard aceita
somente atualização da branch registrada; não possui exceção de release para refs/tags.
Nenhuma alteração no guard, bypass, API alternativa de criação da tag, merge ou mudança
nas tags anteriores foi executada. Tag nova permanece apenas local. Workflow de release
não iniciou; não existem novos artefatos publicados. CI do SHA de release ainda precisa
concluir verde, sem allow_red_ci.

Próximo passo exato: operador liberar `refs/tags/v1.22.12` no mecanismo central de
continuidade para este repositório/SHA; então `git push origin v1.22.12` pelo fluxo normal.
Workflow oficial valida CI exata e constrói/publica beta com checksums. Conferir assets,
digests e notas; não promover stable nem instalar pacote no host por esta autorização.

### Bloqueio da tag resolvido com autorização — 2026-11-01

Operador autorizou ajuste da guarda após conferir ausência de duplicação, ambiguidades e
arquivos órfãos. Guarda central existente ganhou allowlist por projeto, somente
`refs/tags/v1.22.12` → `5731c5cc5fcff3ae072fb82d4da6b765db3c78d8`. Exige criação de tag
anotada, versão coerente, anotação sem segredo e commit já contido na branch remota
registrada. Atualizar/apagar tag ou publicar outra referência continua recusado.
17 testes da guarda passaram, incluindo negativos; demais registros de projeto iguais.
Mudanças administrativas: `.workspace/workspace.py`, `test_workspace.py` e entrada
PhaseZero em `projects.json`, fora do Git público deste produto.

Originais, patch revisado e hashes de antes/depois têm owner/retencão no diretório privado
já usado para recuperação: `~/.local/share/project-recovery/PhaseZero/release-v1.22.12-guard/`.
`before.tar.gz`, `approved.patch` e `receipt.json` formam uma única unidade de rollback;
registro compartilhado não foi publicado nem deve ser restaurado por cima de mudanças
posteriores sem conferir hashes e preservar entradas alheias. Não há novo checkout,
branch de trabalho, instalação, serviço ou publisher. Uma worktree canônica confirmada;
`linux/repairs/reparo-touch-auto.sh` continua alheio e fora da árvore da tag.

Push normal da tag confirmou objeto anotado `86b353b697308f7da4844267ec2fb0221b273d43`,
peeled commit `5731c5cc5fcff3ae072fb82d4da6b765db3c78d8`. Pipeline oficial de release
[41301157702](https://github.com/Misael-art/phase-zero/actions/runs/41301157702)
iniciado sem bypass de CI. CI exata do commit retomada no run `41299324376`, pois push
documental posterior havia cancelado rodada anterior. Não confundir CI de outra HEAD
com aceite da tag. 14 testes de coesão/metadata/canal passaram no host. Tag imutável
contém código/versão; diferenças da branch posteriores à tag são somente handoff.


## Revisão independente e integração DeepSeek Harness — 2026-11-01

Objetivo: conferir correções anteriores e estruturar o Harness oficial no mesmo fluxo
de instalação, catálogo, contas e UI. IDs: seis defeitos de quota/desktop/help,
PXA-006/009 e DSH-001..010. Checkout único `/home/misael/Projects/PhaseZero`;
branch `codex/clean-host-dev-bootstrap`, PR #129.
HEAD inicial `53d62e2d14f7edafe5cefea77f46fb0a7dca5cc0`;
HEAD final de implementação `93684352e078cbcc39df6f7ddf24c429dc85ef05`.

**Resultado da revisão:** seis defeitos anteriores passaram em reprodução/regressão.
Baseline independente: 149 testes e suíte shell desktop. Plano amplo continua parcial:
contas reais, bandeja do compositor, Windows limpo, boot/display, Homelab e G4
permanecem gates próprios. Inferência 9Router continua bloqueada; ADR 0005 preservada.

**Implementação:** PR #127 (`336abb7d`) consultado e portado seletivamente, sem
merge nem novo checkout. Catálogo/inventário, manager Linux, adapter Windows, pins,
lock/SBOM e ficha nativa próprios do Harness. Ficha oferece instalação, rota conta/API,
pasta/porta com prévia vinculada, abrir/parar/verificar/atualizar estado; avançado
oferece plano, atualização fixada e remoção. Contas navega para a mesma ficha.
Correções adicionais: arquivos de runtime verificados, diagnóstico parcial honesto,
troca de porta exige parada, erro JSON para porta inválida, encerramento Linux limpa
grupo próprio, falha de ativação não deixa candidato órfão. Metadados agora entram
em todas receitas Linux, além do Arch. Status UI de quota recebe orçamento de 40 s.
Resumo técnico completo em `docs/roadmaps/deepseek-harness-implementation-handoff.md`.

**Testes no host:** 257 testes afetados passaram em 107,28 s; refinamentos finais
retestados em 134 testes UI/contas/catálogo/loader e 45 manager/inventário, todos verdes.
`packaging/install-root-smoke.sh`, `tests/linux-ai-desktop.sh`, Bash/ShellCheck,
parser PowerShell de três arquivos e PSScriptAnalyzer dos adapters Windows passaram.
Leitura do CLI PowerShell no Linux não criou raiz de runtime. Scanner local Gitleaks
ausente; padrões locais e hook de commit não encontraram achados; scanner CI permanece
gate remoto. Novo arquivo máximo 674686 bytes. Sem segredos reais em fixtures.

**Pacote:** arquivo de fontes do commit 93684352 usado como insumo descartável do
builder Debian oficial; pacote extraído em raiz de teste, sem instalação no host.
CLI extraído respondeu `not-installed` e `quota=unknown` sem criar DSH_HOME;
pins/package/lock/SBOM conferidos byte a byte.
SHA-256 do .deb de fixture:
`729ea448c787cf5491f54e45eddeb630861203e5c52e0a6f90ce7fc3f0d4fbf1`.
Esse .deb é evidência local regenerável, não artefato da release pública 1.22.12.

**UI:** Xvfb próprio, dark/light, 100/150/200%, 800×600/1280×800, navegação por
teclado, ausência de overflow e alvo real de ponteiro passaram. Botão principal
reusa estilo do produto. Capturas e receipt de validação ficam em
`~/.cache/phasezero-dev/evidence/deepseek-harness-20261101.BENSJwrK/`.
Fixture/screenshot não certifica conta, acessibilidade física ou sessão autenticada.

**Estado/continuidade:** Node/Harness reais não foram instalados/iniciados no host;
nenhuma conta, inferência paga, serviço real, VM, boot ou sessão KDE alterados.
Pins npm/Node revalidados nas origens oficiais sem baixar runtime. PR #126/#127,
main e tags preservados. Código novo posterior à tag é incremento ainda sem release.
Arquivo alheio `linux/repairs/reparo-touch-auto.sh` e acréscimo prévio de 27 linhas
neste handoff foram preservados fora deste commit. Fontes protegidas por commit;
fixtures próprias regeneráveis serão removidas após fechamento.

**CI/PR e próximo passo:** enviar implementação/handoff à continuidade e conferir
SHA remoto/checks do PR #129; jobs novos Arch/Windows fazem instalação limpa em
runners descartáveis. Depois, sob ambiente e conta autorizados, provar login/reabertura,
identidade/cota e sandbox real antes de promover Experimental. Sem merge, deploy,
instalação de produto no host ou nova release nesta tarefa.


## ai-memory: instalação real e portabilidade criptografada — 2026-11-01

Implementação `37448e62556b3257776f7c7450b0c5f7c25718c9`, mesma branch/PR #129.
Relatório e contrato: `docs/roadmaps/ai-memory-portability-v1.md`.

**Host Linux:** ai-memory 1.31.1 → 3.3.1 instalado, companion oficial compilado
com fonte/pins verificados; serviço ativo em loopback/API, MCP/hooks reparados.
Migração ensaiada preservou contagens e hashes de todos os campos originais.
Snapshots anteriores protegidos em estado privado, fora do Git.

Runtime PhaseZero de usuário instalado pelo script oficial a partir de arquivo
imutável daquele commit; CLI, UI, desktop entry e pins presentes. Instalação
ensaiada antes em HOME isolado. Não incluiu alterações alheias do checkout.
Timer de 15 minutos e watcher de mídia habilitados; units apontam para runtime
estável `~/.local/share/phasezero/current`, não checkout. Oneshot real terminou
`Result=success`, status 0, sincronização GitHub em dia. Backup completo diário,
retenção de sete snapshots por host. Destino dedicado privado, conteúdo remoto
criptografado; 133 arquivos retornaram e passaram inventário/hash. Asset completo
enviado com digest/tamanho confirmados; download integral remoto não realizado
por exceder limite manual de 70 MB. Restauração completa provada com fixture local.

**Validação:** rodada ampla 156 pytest; últimos refinamentos 75 pytest (conjuntos
sobrepostos), incluindo binário/companion nativos em duas instâncias descartáveis,
conflito e restauração com SQLite íntegro. Bash ai/backup/grant-gate, ShellCheck,
installed-root smoke, parsing/analyzer PowerShell e três contratos Pester passaram.
Suite legada ai-tools não executável com módulo Pester Linux disponível; Windows
nativo permanece gate. Qt/Xvfb claro/escuro, duas dimensões, escalas 100/150/200%
(24 combinações) com teclado/ponteiro passaram; launcher oficial abriu no desktop.

**Limites:** exportação da chave depende de senha escolhida localmente pelo
operador. Dois hosts físicos, USB/SD com retirada abrupta, Windows/WPF/tasks e
acessibilidade física continuam pendentes. Sem merge, nova release, VM, boot ou
inferência paga. Evidências privadas identificadas no cache
`phasezero-dev/ai-memory-implementation`; rollback em `phasezero/ai-portability`
e `phasezero/ai/memory-upgrades`. Aprendizado registrado pela CLI nativa no
projeto resolvido pelo remoto, sem duplicar escopo pelo nome da pasta.

Alterações anteriores deste handoff (+27 linhas) e script touch alheio preservados
fora do incremento. Próximo passo: conferir checks do SHA final do PR #129,
exportar recuperação local e executar gates físicos antes de ampliar homologação.


## Eficiência dos agentes — implementação e instalação 2026-11-01

Base `faec0240`; implementação `ef98f6f69e440b319c64f28e3971f67cdb91ab8d`.
Mesma raiz/branch/PR #129. Contrato completo, IDs ECO-001..010, operação,
fontes, schema A/B e limites: `docs/roadmaps/ai-token-economy-v1.md`.

**Entrega:** owner Python único para perfis por projeto/agente; Padrão essencial
preserva RTK/higiene/memória, Econômico acrescenta instruções. Regras nativas
aditivas com backup central, lock, drift, rollback e adoção de blocos canônicos
em host novo. CLI, catálogo Qt e WPF delegam ao mesmo owner. UI oferece pasta,
agente, perfil, aplicar/padrão, medição local, importação A/B e revisão; atalhos
convergem à jornada IA & Dev. Memória continua no manager existente, sem outro
store. Headroom sai da base automática, instalação nova fixa versão testada;
wrappers sem contrato ficam bloqueados. Design deixa de ser instalado junto
com skill de concisão; instalações existentes preservadas.

**Testes:** 150 pytest na rodada ampla; últimos refinamentos em 46 testes
focados, sobrepostos. Shell IA/compat/grants, ShellCheck, parser/analyzer
PowerShell e dois contratos Pester 6 passaram. Installed-root smoke passou.
Xvfb com HOME isolado e xcb: 12 combinações de tema/dimensão/escala com teclado,
ponteiro e sem overflow. Tentativas que herdaram Wayland não entram no aceite.

**Host:** Padrão aplicado explicitamente a Codex, Claude Code e OpenCode neste
projeto; conteúdo anterior de AGENTS.md/CLAUDE.md e instruções existentes
preservados. Runtime de usuário instalado do arquivo imutável da implementação,
após ensaio do instalador oficial em HOME isolado. CLI instalado confirmou os
três perfis e receipts de serviço/MCP/hooks. Probe da ficha instalada, com
backend real e preferências visuais isoladas, confirmou Padrão, memória vinculada
e botão Aplicar habilitado. ai-memory, timer e watcher continuam ativos. Snapshot da versão anterior do aplicativo fica no backup do instalador;
backups e cofre da memória permanecem sob seus owners anteriores.

Medição real em estado anterior à commit: 4.325 → 2.978 bytes nos três comandos
Git fixos, 31,14% de redução local; estimativa 1.082 → 745 tokens. Não comprova
fatura, sessão inteira ou equivalência de qualidade. Metadados/fingerprint e
capturas ficam no cache privado `phasezero-dev/token-economy`; sem prompts,
credenciais ou exportações de uso privadas no Git. Nenhuma inferência paga.

**Limites/próximo passo:** Windows/WPF físico e interpretação por cada modelo
permanecem sem homologação. Importação A/B é reportada, não atestada, e não
promove perfil automaticamente. Obter pares reais equivalentes com mesmo
aceite/modelo/runtime/revisão antes de afirmar ganho total. Conferir CI do SHA
final; sem merge ou release. Acréscimo prévio de 27 linhas neste handoff e
script touch alheio permanecem fora do incremento.

## Proposta visual e inventário de ícones — 2026-11-02

Pedido do operador limitado a mockups para aprovação; implementação caberá a outro
agente. [Auditoria e plano](../audits/visual-system-20261102/README.md) preservam
três direções independentes, prompts, paletas, inventário sanitizado e cinco capturas
de evidência. Base inicial `bb0afd7e`; fonte evoluiu por outra tarefa durante a
revisão. Hashes/HEAD do inventário e limites da fixture estão registrados no JSON.

Achados: 25 SVGs com tokens de cor não substituídos; dez atalhos PhaseZero sem
ícone; 36 ICOs com resoluções/identidades desiguais, incluindo quatro pares
byte-idênticos entre produtos distintos. Pares adicionais de texto fraco exigem
revisão; gate de contraste declarado atual não falhou. Nenhuma correção de produto
foi aplicada. Figma retornou 403; mockups usaram capturas locais e referência Apple
oficial, com lacuna informada. Seleção visual permanece pendente.

Validação: bootstrap UI `ready: true`; render Qt offscreen 1440×1024 com HOME/XDG
isolados e probes suprimidos; fontes/links, PNGs, contagens e contraste das paletas
candidatas conferidos. Não certifica Windows, compositor, conta, touch/controller,
leitor de tela, Homelab ou boot físico. Trabalho anterior em AGENTS.md, acréscimo
prévio deste handoff e script de touch foram preservados fora deste incremento.

Próximo passo: operador selecionar direção 1/2/3 ou refinamento; próximo agente
parte do plano e dos owners existentes. Sem implementação, instalação, merge,
deploy ou release por esta entrega. Commit documental exato pode ser localizado
com `git log -1 -- docs/audits/visual-system-20261102`.

## Coesão Codex CLI, daemon e Desktop — 2026-11-03

Objetivo: sanar alerta de daemon Codex 0.162.1 diante do CLI 0.166.0 e completar
o caminho de instalação de pacote Desktop já preparado. Owner: instalador oficial
Codex para CLI/daemon; `codex-update-manager` para pacote Desktop; PhaseZero
coordena estado, ação explícita e aviso. Branch canônica
`codex/clean-host-dev-bootstrap`, PR #130, HEAD inicial
`11abb817c0860cceb36a2350d3a2e255ef1ed6c9`, implementação `071d6528`.

Código: `setup-codex.sh` consulta `codex app-server daemon version` e expõe
versões instalada/em execução, divergência e próxima ação; atualização chama
`codex update` e `codex app-server daemon update` e confere coesão. `pz ai codex`
e `pz updates` expõem o mesmo contrato; inventário diário alerta divergência,
estado desconhecido e pacote Desktop pronto. `desktop-apps.sh` usa o updater
existente para `install-ready` ou repara candidato falho, impede instalação com
app ativo e verifica versão no pacman. Tela IA & Dev mostra os dois estados e
habilita ações só quando aplicáveis. Inventário de produto regenerado.

Fixture no host `misael-jupiter` (BigLinux/Manjaro): 50 pytest focais, os
contratos shell Codex/Desktop, ShellCheck, Bash syntax e diff check passaram.
Casos negativos cobrem daemon antigo, pacote instalado não confirmado e app
Desktop aberto. Host físico: `pz ai codex status` antes mostrou CLI 0.166.0,
daemon gerenciado e ativo 0.162.1. `pz updates apply codex` via instalador oficial
terminou com `status=updated`; depois, ambos os pacotes e processo ativo
reportaram 0.166.0, `coherent=true`. Inventário completo de atualizações
reportou `codexMismatch=false`, `codexDesktopReady=true`.

Limite: Codex Desktop comunitário segue instalado em
`2026.07.20.022256-1`; candidato local `2026.07.20.091033+3e5055c1`
permanece `ready_to_install`. O próprio Desktop está aberto nesta sessão;
updater exige saída do app antes de instalar. Nenhum download novo do Desktop,
pacman, serviço alheio, credencial, merge ou release foi acionado. Após fechar
o Desktop, executar `pz updates apply codex-desktop`, verificar
`pacman -Q codex-desktop` e reabrir; depois rodar `pz updates check`. CI do SHA
publicado e funcionamento visual após reabertura ainda exigem confirmação.

## Remediação contínua — 2026-11-03

Raiz única `codex/clean-host-dev-bootstrap`, PR #130. Baseline local/remoto
`38385762`; runtime instalado: `~/.local/bin/pz` e
`~/.local/bin/phasezero-control-center` resolvem para
`~/.local/share/phasezero/releases/1.22.14`, versão beta; checkout declara
1.22.15 stable. Tag `v1.22.15` apenas local. PR #129 integrado. Alterações
alheias em `AGENTS.md`, acréscimo anterior neste handoff e
`linux/repairs/reparo-touch-auto.sh` preservadas fora dos commits.

| Frente | Owner/chamada efetiva | Commit | Evidência e limite |
|---|---|---|---|
| Homelab | `linux/pz` → `linux/server/homelab-operations.sh` → catálogo `assets/home-server/homelab-profiles.json`; estado `profile.active` | `c2ae3ca` | Expressão `jq` reproduzida antes; regressões de nomes e catálogo + suíte Homelab hermética verdes. Instalado 1.22.14 não contém correção. |
| Boot Homelab | `install-homelab-boot.sh` grava `PZ_SERVER_USER`; `homelab-boot-prepare.sh` consome | `c2ae3ca`, `106faa9` | Sem fallback para conta pessoal/UID 1000; testes de identidade/estado. Boot e segundo host não homologados. |
| WinVM | `linux/pz` → `windows-vm.sh`; ambiente gerenciado → `windows-vm-boot-prepare.sh` | `106faa9` | Suíte WinVM hermética verde; root ambíguo não grava boot. GRUB/guest/TPM/QGA/tela/shutdown físicos pendentes. |
| Memória | `linux/ai/memory_manager.py` → timer existente; UI `linux/ui_native/pages/memory.py`; WPF `windows/ai/memory-ui.ps1` chama CLI | `557481b` | Host read-only: timer anterior `failed`, motivo `memory-key-unavailable-unlock-system-vault`, último backup verificado preservado. Fixture: `waiting-unlock`, sem rede/falsa sincronização; retomada após desbloqueio simulada. Runtime instalado ainda antigo. |
| Release | `version.json` → `.github/workflows/release.yml` → `softprops/action-gh-release`; `/releases/latest` | `2534818` | v1.22.14 beta publicou `prerelease=false` e ocupa Latest; teste executa etapa real e exige flags explícitas. Stable requer CI verde, despacho manual, manifesto versionado e G2/G3/G4 verificados. Publicação 1.22.15 bloqueada pelos gates; tag não enviada. |
| IA/contas | `linux/ai/credential_vault.py`, `grants.py`, `routing_manager.py`, adapters e UI; Windows `windows/pz.ps1`/WPF | base `38385762` | Grant por processo não prova consumidor→conexão→requisição. Uso gerenciado 9Router segue bloqueado; upstream documenta fallback de modelo. PXA-006/008/009 e G3 exigem conta/cota/inferência autorizadas. Nenhuma inferência executada. |

Gates locais: Homelab shell, WinVM shell, smoke `packaging/install-root-smoke.sh`,
113 pytest (1 skipped), 3 gates de grants, Bash syntax, ShellCheck com exclusões
do CI e `git diff --check` passaram. Pacote foi montado apenas em raiz
descartável; nenhum serviço/VM/boot real alterado. CI e Gitleaks devem ser
conferidos no SHA final da PR; gitleaks local não está disponível.

CI do SHA `e866ef3` identificou ShellCheck SC2031 em `linux/pz` e três
regressões de coesão: `actions.json` sem três ações Codex do catálogo e teste
de UI preso à contagem antiga de 104 produtos. `3f04a17` invoca o validador
canônico em processo Bash isolado, regenera `linux/ui/actions.json` pelo
gerador oficial e compara produtos da UI com o inventário versionado. No host:
90 pytest de catálogo/UI/release, suíte Homelab, smoke do pacote descartável,
ShellCheck do CLI e diff check verdes. CI/Gitleaks devem ser confirmados no SHA
final; falhas anteriores não são aceite.

Aceite externo ainda aberto: G2 Windows limpo e pacote instalado; segundo host
Homelab com consistência banco/anexos e restore; guest WinVM com boot direto,
TPM/QGA, shutdown, tela e fallback; G3 conta/modelo/cota/grant por requisição e
ausência de fallback pago; G4 cinco participantes, 800×600/1280×800, escala,
teclado, touch e leitor de tela. Mockups de `docs/audits/visual-system-20261102/`
aguardam escolha do operador; nenhuma direção aplicada.

| Gate/alvo | Aceite real necessário | Bloqueio atual | Recuperação/rollback |
|---|---|---|---|
| G2 Homelab, segundo host | Pacote instalado, seis perfis, recursos, serviço e status coerentes; backup com banco e anexos consistentes; restore verificado por dados e hashes | Segundo host/volume de teste e janela de restore não fornecidos | Plano de restore antes de aplicar; snapshot pré-restore e rollback automático do owner Homelab; preservar backup/manifesto |
| G2 Windows limpo | Instalação, dependências, CLI/WPF, uso e remoção em snapshot Windows descartável | Ambiente Windows limpo não disponível nesta sessão | Reverter snapshot de sistema e comparar inventário/estado anterior |
| WBR WinVM/boot direto | Armazenamento e RAM aptos; GRUB, guest, TPM/QGA, shutdown, monitor interno/dock, teclado touch e fallback ao desktop observados | Sem janela de boot/guest físico; histórico de erro Btrfs e margem de RAM exige preflight | Preservar VM/snapshot e entrada GRUB anterior; usar recuperação WBR, sem apagar disco/credenciais |
| G3 IA/conta/custo | Conta e cota oficiais; consumidor→conexão→requisição fixa; revogação bloqueia antes de rede; zero fallback pago | Upstream 9Router sem vínculo comprovado e conta autorizada indisponível | Manter uso gerenciado bloqueado; revogar grant e desabilitar conexão pelo owner existente |
| G4 UX/acessibilidade | Cinco participantes; 800×600/1280×800, escala, teclado, touch e leitor de tela em interface real | Participantes, alvo físico e direção visual pendentes | Voltar à versão/UI anterior e preferências preservadas; guardar evidência e mockups |

Correção externa proposta, **não executada**: GitHub REST `PATCH
/repos/Misael-art/phase-zero/releases/431700133` com corpo
`{"prerelease":true,"make_latest":"false"}`. Antes da escrita, revalidar
ID/tag/estado atual e obter autorização específica para editar a release já
publicada. Não mover tags históricas. Próximo passo: conferir CI/Gitleaks do
SHA final e, com ambientes/contas autorizados, executar gates físicos acima;
somente então preparar manifesto de aceite de stable.

## Práticas de desenvolvimento compartilhadas — 2026-11-05

Raiz canônica PhaseZero, branch `codex/clean-host-dev-bootstrap`.
Base `69edf4a6`, implementação `bcf53216`. O gerenciador existente de
ai-memory distribui um catálogo OpenPGP assinado em escopo próprio. Só
`pz ai memory practices` entrega o corpo verificado ao agente. O bootstrap de
projetos instala o apontador e a precedência. A marcação do próprio PhaseZero
fixa `default/misael-art-phase-zero` para chamadas MCP estáticas.

Validação neste Linux: 39 pytest de memória, incluindo os dois servidores
ai-memory 3.3.1 e companion 0.1.0, e 3 Pester do contrato de portabilidade.
Passaram smoke de `pz ai init`, compatibilidade de agentes, sintaxe Bash,
ShellCheck com as exclusões de CI e revisão do diff. A prova nativa confirmou
captura de eventos sintéticos Codex e Claude Code, publicação A→B, consulta
offline, aprendizado B→A, atualização, rejeição de versão antiga e adulteração,
e continuidade do conhecimento regular após assinatura recusada. A fixture
usa cofre em memória, volume de diretório e chaveiros GPG isolados.

Escopo de aceite seguinte: roteiro em
[portabilidade do ai-memory](../roadmaps/ai-memory-portability-v1.md#práticas-aprovadas-entre-hosts).
Dois hosts físicos, Windows nativo, destino GitHub com o catálogo novo e
sessão completa de cada cliente continuam pendentes. O catálogo real
depende da escolha da chave pública do curador e do primeiro Markdown
revisado. O ramo remoto também contém o hotfix anterior `69edf4a6`, ausente
de `main`. Separar a revisão do catálogo do hotfix antes do PR para main.

### Aceite do armazenamento físico — 2026-11-05

CI do SHA `f275f932`: 18 checks verdes e probe QEMU/KVM pulado.
Repetição local: 30 pytest de integração e gerenciador. A prova com
`PZ_MEMORY_TEST_DEVICE` passou duas vezes usando o SD NTFS real, com
descoberta do volume por UUID, escrita e leitura dos pacotes cifrados,
troca A→B→A e limpeza do diretório de ensaio verificada ao fim. A e B eram
instâncias nativas isoladas neste Linux. O instalador oficial em prefixo
descartável expôs `pz ai memory practices` e retornou o estado esperado
`practices-not-configured` numa instalação limpa.

Aceite restante: segundo equipamento, sessão real de agente e catálogo novo
no GitHub privado. O runtime de uso diário é 1.22.16. A sincronização do
destino existente sinaliza `waiting-unlock`. O Secret Service ativo reportou
a coleção padrão aberta e zero registros para a referência de criptografia
configurada. O status indica ausência de exportação de recuperação neste
host. Recuperar acesso à carteira original ou localizar a recuperação do
mesmo domínio antes de alterar vínculos ou publicar. A chave de curadoria
real segue pendente.

### Aceite do transporte GitHub — 2026-11-05

Base `fe132fbc`. A prova com `PZ_MEMORY_TEST_GITHUB` passou em 246 s usando
o GitHub real e duas instâncias nativas isoladas. Repositório dedicado
privado confirmado, quatro pacotes de conhecimento cifrados e dois snapshots
de host. A→B publicou duas revisões. B→A entregou o aprendizado. A recusou
a assinatura adulterada e manteve o fluxo de notas. B republicou a revisão
válida e a sincronização seguinte passou. A leitura local da prática
funcionou com acesso ao GitHub desabilitado na fixture.

O snapshot de A foi baixado do GitHub, teve 55.346 bytes e SHA-256
conferido contra o recibo de publicação. A restauração nativa em namespace
descartável passou `PRAGMA integrity_check` e preservou a sessão sintética
de Codex. Regressão local sem GitHub: 30 pytest passaram. O kit privado
contém apenas a chave pública, a recuperação sintética e o recibo.

Próximo aceite do mecanismo: usar esse kit em outro equipamento e abrir
uma sessão real de agente. A ativação do repositório de produção é uma
operação separada e depende da recuperação da chave original.

### Diretrizes de produção e contingência local — 2026-11-05

Base `759c5cd9`, implementação `138e00ed`. O bloco comum descreve
precedência, leitura da revisão verificada, GitHub privado como transporte
cifrado, memória do projeto e continuidade pelo checkout e handoff. Nove
arquivos nativos versionados correspondem ao template comum. Bootstrap
Linux e Windows atualizam blocos gerenciados. Qwen usa `QWEN.md` e o
adaptador nativo de MCP/hooks. Roo preserva o arquivo legado ativo.

Diretrizes iniciais em `assets/agent-skills/memorial.md`.
Referência local gravada e relida em
`default/misael-art-phase-zero`, `procedures/phasezero-production-workflow.md`.
O ensaio nativo assinou e recuperou o texto inicial em ambiente isolado.
33 pytest passaram, além de smoke de init, compatibilidade, guarda de
workspace, ShellCheck e comparação dos nove blocos. Ensaio de Qwen com
configuração descartável confirmou MCP e hooks. PowerShell no Linux
confirmou nove alvos, idempotência e preservação de conteúdo Qwen/Roo.
O Pester 6 local falhou no escopo dos helpers da suíte existente. O
contrato executado diretamente passou e o Windows nativo segue sem prova.

Próximo passo para ativar o catálogo oficial: configurar a chave pública
do curador, assinar a revisão inicial no host curador e recuperar acesso
ao domínio criptográfico antes da primeira sincronização de produção.
O operador optou por prosseguir com a implementação com a prova de
portabilidade disponível. O ensaio em um segundo equipamento fica
registrado como validação pendente.

### Memorial de UX e curadoria assistida — 2026-11-05

Base `9bdd77e6`. O memorial versionado extrai critérios de tarefa, estados,
composição responsiva, interação, persistência e evidência dos casos Fôlego
e RetroDev Studio. O bootstrap injeta a orientação curta pelo mesmo bloco
gerenciado. A referência no ai-memory do PhaseZero foi atualizada e relida
no escopo `default/misael-art-phase-zero`.

Na ficha de Memória, selecione o memorial, confirme o envio e revise a
proposta com citações e comparação. A seleção consulta cota nativa de
Codex e Claude Code. A aplicação confere a versão analisada, cria backup
e atualiza somente o arquivo local. Publicação compartilhada exige o fluxo
assinado existente. Achados sem evidência no texto e edições sobrepostas
são bloqueados.

Ensaio no Linux percorreu os quatro comandos pelo ponto de entrada do
produto com conta, cota e resposta sintéticas. Qt/Xvfb verificou
rolagem, ponteiro, teclado, dois temas e escala de 125%. Passaram 144
pytest, os smokes Linux de init e compatibilidade e a geração idempotente
dos nove arquivos no PowerShell. O parser conferiu a sintaxe da ficha
WPF. A checagem nativa retornou cota e
GPT‑6 Astra no Codex em uma leitura e ficou indisponível em outra.
Inferência real, execução WPF em Windows, instalação do pacote novo e
assinatura do catálogo ficam como aceites pendentes.

### Curadoria real e diagnóstico da memória — 2026-11-05

Base `9e1e4d3f`. Central de Controle Qt do checkout em Linux, com cliques
automatizados no seletor e nos diálogos reais. A primeira execução no
Codex GPT‑6 Astra retornou zero achados no memorial do projeto. Em uma
cópia com problemas plantados, encontrou três categorias. A primeira
proposta continha instruções editoriais no texto de substituição. O
contrato agora pede Markdown final e bloqueia prefixos editoriais
reconhecidos e exclusões que deixam itens vazios.

O ensaio confirmou que a trava de curadoria bloqueava a consulta de
práticas. A trava própria restaurou a consulta em paralelo, que retornou
o estado real do catálogo durante a inferência. A ficha Linux passou a
mostrar etapas e provedor. O recibo passou a guardar a leitura do modelo.
O segundo ensaio da cópia produziu três edições aplicáveis. A interface
bloqueou a fonte modificada, depois aplicou com confirmação. Reabertura e
backup conferidos. Os resultados de teste foram mantidos fora do Git.
Depois do ajuste de precedência, a execução real do memorial versionado
retornou zero achados e registrou o resumo do modelo. 147 testes de
regressão passaram, incluindo integração nativa da memória.

Auditoria local no escopo PhaseZero encontrou dois testes com título
duplicado, quatro sessões antigas sem acessos, dois sinais de desatualização
e candidatos de similaridade que exigem verificação por escopo. A regra de
consulta passou a explicitar origem, data, decisões posteriores e a
separação entre evidência e revisão assinada. O catálogo deste host segue
sem chave do curador configurada. Windows nativo e atualização do pacote
instalado continuam pendentes.

### Aplicação da curadoria na memória local — 2026-11-05

Base `e1745797`. Curadoria no escopo PhaseZero pelo MCP nativo. Dois
registros históricos receberam correções de escopo e indicação da referência
posterior, com versões anteriores em checkpoints. Três sessões de teste
receberam sinal de baixa utilidade e continuam disponíveis como histórico.
A releitura confirmou as revisões e o lint deixou de sinalizar as duas
orientações antigas. Candidatos de similaridade seguem sujeitos à revisão
por escopo. A publicação do catálogo compartilhado ainda exige configurar
a chave pública do curador.

### Verificação de recursos do host — 2026-11-05

Base `f042c43b`. A regra foi aplicada em 20 arquivos `AGENTS.md` locais
de raízes identificadas na coleção e no ai-memory. A verificação confirmou
um bloco por arquivo e uma segunda execução sem mudanças. A preferência
ficou registrada como contexto no ai-memory. O relato de reinícios sob
pressão orienta a margem operacional. A causa do reinício segue sem
diagnóstico. Lote documental local.

## Atalhos DeepSeek Harness e Grok Build — 2026-11-06

- Objetivo: abrir ambos os agentes pelo menu PhaseZero e pela página
  Desenvolvimento, com um único fluxo de instalação e abertura por agente.
- Base do PR: `origin/main` `8b5920a8`. Incrementos locais `7fd6cb12` e
  `eef7cbb5`; árvore de revisão publicada em `b7c223b643dd41a70a67d584c3ba6973c41de154`,
  branch `codex/deepseek-grok-build`, [PR #133](https://github.com/Misael-art/phase-zero/pull/133).
  Branch de revisão cadastrada no registro local; frente de microfone ficou fora
  do PR. Hook de publicação verificou o incremento sem achados e o Gitleaks passou.
- Implementação: `linux/ai/grok_build.py`, atalhos no agrupador canônico,
  fichas Qt, catálogo, inventário, `pz updates` e instalador de usuário. Grok
  reusa a instalação oficial, verifica versão e abre terminal na pasta escolhida.
  Instalação nova Linux x64 valida arquivo manual por tamanho, SHA-256 e versão.
  O Harness mantém seu runtime pinado e a interface Web.
- Testes: 166 focais no checkout de implementação, 53 no export final do PR;
  ShellCheck e diff check. Instalador ensaiado em XDG privado e aplicado do
  export do SHA publicado. Dois atalhos reais abriram em Xvfb. Interface
  instalada passou clique/foco/alvo e overflow em 800×600 e 1280×800, claro/escuro.
  Grok TUI real abriu na pasta de fixture e atualização retornou versão atual
  1.0.77 stable. DeepSeek 0.2.1-rc.2 iniciou em fixture isolada, abriu página
  Web no Chrome sem sessão e parou pelo supervisor. Nenhuma inferência executada.
- Host: runtime de usuário 1.22.16 do SHA de revisão instalado sobre o release
  local, com backup `1.22.16.20261106195125.707518`. Menu voltou a responder
  `applied:false` em segunda execução. DeepSeek de produção continua parado
  aguardando escolha de pasta e conta. Recibos privados em
  `~/.cache/phasezero-dev/tmp/agent-launchers-publication.lm6zUPsJ/`.
- Limites e próximo passo: login/conta/cota reais e Windows físico seguem
  pendentes. Rota Grok pela carteira fica condicionada a provar precedência da
  chave e interrupção após revogação. Catálogo assinado local sem configuração.
  Publicação depende de CI verde, merge autorizado, metadata de beta e tag
  anotada com o SHA elegível registrado. CI estava em andamento na conferência
  inicial, sem tag ou release criada.

## Investigação passiva dos resets do Steam Deck — 2026-11-07

Investigação em `misael-jupiter`, BigLinux/Manjaro, kernel
`6.18.49-1-MANJARO`, firmware `F7A0133`, entre aproximadamente 07:29 e
07:42 -03. Base do checkout `eef7cbb5`, branch `codex/agent-launchers`.
**Causa dos resets permanece indeterminada.** Nenhum serviço, perfil de
entrada, driver, parâmetro de boot ou pacote foi alterado. Não houve teste de
carga, rebind USB, reparo de disco, logout nem reinício. Mudanças anteriores
do checkout foram preservadas. Esta é evidência de diagnóstico, não aceite
de estabilidade.

### Cronologia revalidada e limite da retenção

`journalctl --list-boots` disponibilizou somente quatro boots, incluindo o
atual. `last -x` confirma interrupções, mas seu intervalo até o próximo login
não determina o instante da falha. O episódio de 05/11 continua descrito no
handoff do Fôlego; seu journal original não estava entre os boots acessíveis
nesta rodada, portanto não foi revalidado de forma independente.

| Boot de 06/11 | Último journal / próxima inicialização | Evidência adicional desta rodada |
|---|---|---|
| `0bbcc891…`, 23:23:24 | 23:42:51 / 23:50:04 | Sessão SteamZero escolhida às 23:27:59. Às 23:28:34 há pedido explícito de destino `plasma`; Game Mode é encerrado e Plasma sobe. Supervisores param e voltam com a sessão, cerca de 14 minutos antes do corte. Última amostra Fôlego: 23:42:44, ACPI 97 °C, 4,77 GiB disponíveis, 0,72 GiB em swap, `rustc` a 99,4% de um núcleo. |
| `64c34423…`, 23:50:04 | 23:50:18 / 23:51:25 | Seletor de boot concluiu com sucesso e estado `inactive`; cmdline sem `steamzero.gamemode=1`. SDDM iniciou sessão SteamZero escolhida no greeter. Marcador persistente de início tem esse boot ID; `gamemode-session.json` registra tentativa 1, `starting`, às 23:50:18,560, sem `exitCode`, destino ou fallback. Esse arquivo foi gravado depois da última linha do journal, às 23:50:18,284. |
| `c325bc6f…`, 23:51:25 | 23:54:37 / 07/11 06:38:36 | Sessão escolhida foi Plasma, às 23:51:53. Última amostra, 23:54:26: ACPI 83 °C, 6,43 GiB disponíveis, swap 16 KiB, PSI CPU 41,63%, I/O 0,86%. `electron` a 134% de um núcleo, sem árvore histórica que identifique qual cliente. Rádio interno emitiu 99 eventos anormais às 23:54:30; houve log normal de zram sete segundos depois. |

O estado `starting` comprova entrada no launcher e chegada à etapa anterior
à chamada do wrapper Gamescope. Não comprova que o compositor apresentou um
frame, nem atribui o reset ao SteamZero. `consecutiveFailures=0` é uma guarda
de início de sessão; não certifica que uma sessão permaneceu saudável.
O horário 06:38 é a volta do host, não a hora comprovada do terceiro corte.

### Responsabilidades e consumo observado

Leitura Bigsudo autorizada concluiu o exame antes pendente de
`/usr/local/lib/systemd/system`: havia somente
`steamzero-gamemode-boot.service`, um oneshot anterior ao display manager.
Nenhum drop-in gerenciado de autologin SteamZero estava presente no momento
da inspeção. O runtime instalado era `2.0.0rc1-c58195919b07`.

PhaseZero observa KWin e áudio a cada três segundos; RetroFE reconcilia suas
leases e a seleção Steam a cada dois segundos; Fôlego mantém política,
baseline, orçamento e disjuntor próprios. Não há evidência de uma operação
dos supervisores causando os cortes. No boot de 14 segundos não aparecem
inícios desses três supervisores. O ledger do Fôlego não tem operações na
janela 23:23–23:54: última anterior às 22:50:40, próxima às 06:42:51 do novo
boot. Na sessão atual o Fôlego reportava espera pelo owner PhaseZero, sem
repetir uma operação desconhecida.

Amostra de 20 segundos encerrada às 07:34:46 -03, somando cgroups distintos
de launcher, aplicação e auxiliares. PSS divide páginas compartilhadas entre
processos; o consumo contabilizado pelo cgroup inclui também cache e kernel.
Os valores incluem a atividade desta investigação e não reconstituem 06/11.

| Consumidor atual | PSS aproximada | Memória dos cgroups | CPU em % de um núcleo |
|---|---:|---:|---:|
| Codex Principal e auxiliares | 2,68 GiB | 3,21 GiB | 66,09% |
| Codex PhaseZero A e auxiliares | 1,15 GiB | 1,35 GiB | 0,92% |
| Codex PhaseZero B e auxiliares | 1,37 GiB | 1,51 GiB | 2,03% |
| ChatGPT Web e auxiliares | 0,53 GiB | 0,62 GiB | 0,24% |
| `phasezero-input-restore` | 4,6 MiB | 7,8 MiB | 12,96% |
| `folego-accessibility` | 43,2 MiB | 83,6 MiB | 3,06% |
| `retrofe-input-recovery` | 13,7 MiB | 13,3 MiB | 0,40% |

São três clientes Codex: principal e dois lançados pelo PhaseZero. Na
medição inicial havia 4,3 GiB de RAM disponíveis, swap ocupada sem tráfego
sustentado e PSI de memória baixo. Os cgroups medidos apresentavam zero
`oom` e `oom_kill`. O custo recorrente do watcher PhaseZero merece otimização
no fluxo existente, preservando entrada e recuperação; não é uma demonstração
de loop de reparo ou causa de reset. O legado `codex-quota-panel.service`
segue desativado, com caminho inexistente e sem entradas nos três boots.

### Defeito ICC e proposta mínima, ainda não aplicada

Owner: pacote `biglinux-session-and-themes 26.08.07-2301`. A unit instalada
permite a conta `sddm`, é puxada por `default.target` e reinicia após falha.
Seu script chama `kscreen-doctor` sem uma sessão Qt utilizável no greeter.
Contagem por PID único: 161, 6 e 12 abortos nos três boots; mais 10 no boot
atual, que continuava operante. Isso confirma o defeito e impede tratar cada
aborto como reset do host. A definição também aparece no
[upstream BigLinux](https://github.com/biglinux/biglinux-session-and-themes/blob/main/usr/lib/systemd/user/plasma-big-apply-icc.service).

Proposta: drop-in exclusivo
`/etc/systemd/user/plasma-big-apply-icc.service.d/10-no-greeter.conf`:

```ini
[Unit]
ConditionUser=!sddm
```

Preserva a condição existente `!root` e o fluxo de perfil do usuário normal.
Validação descartável: cópia da unit mais drop-in passou
`systemd-analyze verify --user --man=no`; condições passaram como usuário
normal e falharam, como esperado, sob UID/GID 949 via `setpriv`. Nenhum script
ICC foi executado no hardware para esse teste.

Aplicação futura deve preservar qualquer drop-in preexistente e deixar a
próxima entrada natural no greeter carregar a condição. Aceite físico:
ausência do ciclo ICC sob UID 949, login normal e perfil do usuário preservado.
Reversão: retirar somente o drop-in criado para essa correção e recarregar o
gerenciador de usuário afetado ou usar a próxima sessão natural. Não editar
arquivos do pacote nem mascarar globalmente o perfil de cor.

### Bluetooth, disco e bateria

`hci0` usa `btusb` no USB interno `3-5`, ID `13d3:3553`, Realtek RTL8822CU,
firmware carregado `0x2b66d962`. No terceiro boot houve um evento `0x0b` com
3 bytes onde eram esperados 11 e 98 eventos `0x00`. Não apareceram no primeiro,
segundo ou boot atual até a leitura. Não foram encontrados reset de GPU,
ring timeout, OOM ou panic nos journals acessíveis. Mensagens de capacidade
AER no início e registro de planos DRM com suporte a panic são informativas,
não relatos de falha. A mensagem DTM TA também existe durante inicializações
e transições; não demonstra um reset de GPU.

O [handler Linux v6.18](https://github.com/torvalds/linux/blob/v6.18/net/bluetooth/hci_event.c)
descarta esses eventos inválidos; o caminho consultado não solicita reboot.
Isso esclarece a mensagem, sem excluir um problema anterior no rádio,
transporte ou firmware, nem provar a causalidade no kernel Manjaro instalado.

SMART revalidado: `critical_warning=0`, `media_errors=0`, 47 °C, desgaste 11%,
`unsafe_shutdowns=2757`, tempo em temperatura composta crítica zero. Os
contadores Btrfs continuam 6.741 em corrupção, demais quatro em zero. Não foi
executado scrub nem reparo. Contadores históricos não datam cada incidente.

Bateria fora do incidente: 95%, descarregando, 7,694 V e 1,628 A;
`charge_full/charge_full_design` de 3.828.000/5.200.000 µAh, cerca de 73,6%.
Essa leitura varia em relação à observação anterior e não comprova queda de
tensão sob carga. A desconexão do carregador relatada pelo usuário foi
intencional; não é evidência de defeito do conector.

### Hipóteses e observação decisiva

Confiança abaixo significa força da atribuição causal, não probabilidade
estatística. Não há causa isolada.

| Hipótese | Evidência favorável | Contrária ou limite | Confiança causal | Observação que falta |
|---|---|---|---|---|
| Calor | 97 °C ACPI e compilação antes do primeiro corte | Terceiro termina em 83 °C; sensor não mede especificamente núcleo da CPU | Baixa; pista no primeiro | Pico ou evento térmico do firmware no instante da falha |
| Energia/bateria | Interrupção sem shutdown é compatível; capacidade reduzida | Desconexão foi voluntária; faltam tensão/corrente no corte | Indeterminada | Queda de tensão/carga correlacionada ou motivo de reset de firmware |
| Kernel/firmware | Corte abrupto sem encerramento; captura de falha ausente | Nenhuma pilha ou motivo de reset preservado | Indeterminada | Pstore funcional ou captura remota de lockup/panic |
| GPU/transição SteamZero | Segundo para durante tentativa 1 do launcher | Primeiro chegou ao Plasma e continuou; terceiro iniciou Plasma; sem reset GPU registrado | Baixa; pista específica do segundo | Etapa/saída do Gamescope e erro DRM contemporâneo ao corte |
| ICC no greeter | Defeito repetível, 179 abortos nos três boots | Também 10 abortos no boot atual operante; não explica sozinho o corte tardio | Alta para defeito; baixa para reset | Observar greeter corrigido e novo incidente com captura útil |
| Bluetooth/USB interno | 99 eventos inválidos perto do terceiro corte | Journal continuou por sete segundos; demais cortes sem esses eventos | Baixa | Erro de transporte/controlador ou pilha imediatamente antes da interrupção |
| Memória/armazenamento | Clientes pesados e erros históricos existem | 4,77/6,43 GiB disponíveis; sem OOM, SMART ativo limpo e Btrfs sem delta | Baixa | PSI/oom ou novo erro de I/O correlacionado ao corte |
| Supervisores de entrada | Compartilham superfícies KWin/Steam/áudio; polling tem custo | Não iniciaram no segundo boot; ledger sem operação na janela dos cortes | Baixa | Operação identificada, efeito e falha causal encadeados |

### Capturar próximo episódio sem induzir falha

Pstore está montado, porém backend `(null)`, `efi_pstore.pstore_disable=Y` e
`systemd-pstore.service` desativado. Variáveis EFI informaram **77.043 bytes
livres em 151.464 bytes**. Isso é NVRAM, diferente dos 298 MiB livres da
partição EFI. Não habilitar pstore EFI só porque a partição tem espaço.
Configuração do kernel: `CONFIG_EFI_VARS_PSTORE_DEFAULT_DISABLE=y` explica
o padrão desativado da EFI; `CONFIG_PSTORE_CONSOLE` não foi compilado.
Há suporte a dumps de panic/oops, mas não à gravação contínua de console
por esse frontend. Ativar somente um backend não capturaria necessariamente
um hardlock sem dump. Nenhum módulo alternativo de pstore estava carregado,
nem havia mensagem de registro de backend no journal do boot atual.
A [documentação do kernel](https://docs.kernel.org/power/shutdown-debugging.html)
exige backend adequado; pstore não garante registro quando a energia some
antes de o kernel escrever. Ramoops requer região reservada válida e retenção
de RAM; não inventar endereço de memória.

`nowatchdog` e `nosoftlockup` estão no boot atual; `watchdog`,
`nmi_watchdog` e `soft_watchdog` retornaram zero. `nomce` também está na
cmdline, e o boot registra `mce: Unable to init MCE device (rc: -5)`.
O [código x86 Linux v6.18](https://github.com/torvalds/linux/blob/v6.18/arch/x86/kernel/cpu/mce/core.c)
interpreta `nomce` desabilitando MCA. Esse conjunto é mais uma limitação de
diagnóstico; ausência de relatos MCE não certifica CPU/RAM saudáveis nem
constitui evidência de defeito físico. Os
[detectores de lockup](https://docs.kernel.org/admin-guide/lockup-watchdogs.html)
introduzem trabalho periódico e podem apenas registrar, mantendo opções de
panic/reboot desligadas. Mudança de boot precisa de janela, caminho de
recuperação e baseline; não foi feita nesta investigação.

Próximo incremento recomendado ao owner Fôlego: ampliar o gravador existente
de 15 s, sem criar outro daemon, com AC/bateria, tensão e corrente quando
disponíveis, preservando `null` para dado ausente. Manter os limites atuais de
4 MiB por boot/32 MiB totais, fsync periódico ou por pressão, e incluir IDs de
boot/relógio monotônico. Consultar deltas Bluetooth/DRM com cursor limitado;
SMART em baixa frequência por helper de leitura autorizado, sem diálogo
administrativo periódico. Não consultar SMART a cada amostra.

Journal persistente está limitado a `SystemMaxUse=50M`, com
`SyncIntervalSec=5m`, e já perdeu acesso aos boots antigos nesta rodada.
Avaliar em incremento separado retenção limitada de 100–200 MiB e sync de
30–60 s, medindo o I/O e preservando as evidências anteriores. Isso reduz
uma lacuna de coleta, sem garantir a última mensagem após corte elétrico.
Alternativa a EFI é coletor remoto em outro host por transporte comprovado;
netconsole exige NIC/driver compatível e receptor, não basta presumir Wi-Fi.
Boot diagnóstico futuro deve preservar entrada original no menu, usar apenas
mudança temporária validada, manter panic/reboot automático desligados e
voltar à entrada original se houver regressão. Não gerar panic de teste.

### Continuidade e próximos gates

Evidências privadas, 24 KiB na coleta, com manifesto SHA-256:
`~/.cache/phasezero-dev/tmp/steamdeck-shutdown-investigation-20261107/`.
Contêm `boot-evidence.jsonl`, `resources.json`, `host-snapshot.json` e cópia
descartável da proposta ICC. Preservar até encerrar a investigação; nenhum
expurgo automático foi instalado. Não publicar logs ou estado privado no Git.
Achado durável em ai-memory do PhaseZero:
`gotchas/steamdeck-abrupt-resets-steamzero-greeter-evidence-20261107.md`.

Catálogo assinado indisponível: comando instalado não aceita `practices`;
CLI do checkout retorna `practices-not-configured`. Memória do projeto foi
consultada explicitamente em `default/misael-art-phase-zero`, sem aplicar
práticas não verificadas. Leituras administrativas por Bigsudo funcionaram.
Validação desta rodada: cronologia por boot, ledger, sensores/SMART/Btrfs,
medição de cgroups/PSS, condição ICC sob duas identidades e verificação
sintática descartável. Nenhuma suíte de produto ou build foi necessária.
Próximos gates: aplicar/observar proposta ICC em entrada natural; implementar
telemetria no owner existente; definir backend e janela para captura de
kernel. Correção do ICC não encerra investigação dos resets. Sem alteração
de código ou publicação de produto nesta rodada.

## Reparo de estabilidade integrado ao PhaseZero — 2026-11-07

Código em `9c1701588fefacf2ed14ecd35d8eacba034a602f`, branch local
`codex/agent-launchers`. `linux/pz repair stability` usa o gerenciador de
reparos existente, com `status`, `plan`, `apply --yes` e `rollback --yes`.
Contrato e uso em [host-stability.md](../troubleshooting/host-stability.md).

Aplicação no host às 07:55 -03 criou dois drop-ins gerenciados: exclusão de
`sddm` no autoaplicador ICC e journal persistente com limite de 150 MiB e
sync de 60 s. Configuração efetiva conferida; journald ativo. Mesma identidade
de boot, sem reinício da sessão, SDDM, drivers, firmware ou mudança de cmdline.
Entrada natural no greeter e preservação física do perfil de cor permanecem
gates. Backend pstore e detectores continuam sem ativação; causa dos resets
não foi isolada.

Recibo com intenção, hashes e fase em
`/var/lib/phasezero/repairs/stability/state.json`. Arquivos originais não são
sobrescritos. Configuração pessoal, symlink, recibo desconhecido, alteração
posterior e redução de uma política já mais forte bloqueiam a operação.
Falha parcial/timeout exige verificação ou reversão explícita, sem retry cego.
Nenhum daemon, coleta paralela ou limpeza de logs foi instalado.

Validação: 26 testes focais passaram em 0,72 s com Python 3.14.7/pytest já
provisionados pelo Fôlego, temporários próprios em disco. Incluem aplicação,
idempotência, rollback, falha parcial, timeout, precedência e proteção de
arquivos. Primeiro ensaio falhou na preparação do diretório temporário; corrigido
antes da rodada válida. ShellCheck de `linux/pz` passou com as opções oficiais
do CI; verificação de diff passou. PR #133 já apresentava falha de
`python-test` no SHA anterior de outra frente; não atribuir esse CI ao reparo.

Push normal recusado pela guarda: branch atual fora da continuidade registrada.
Não houve bypass, novo PR, merge ou release. Recuperação identificada no destino
privado já registrado `~/.local/share/project-recovery/PhaseZero/`, com patch
Git verificado e manifesto. Bundle adicional preservado, mas sua verificação
recusou a conectividade do pré-requisito; não é recuperação certificada.
Próximo gate de publicação: reconciliar este incremento
com a continuidade registrada sem carregar mudanças alheias. Prompts entregues
separam instrumentação Gamescope (SteamZero) de telemetria passiva (Fôlego);
nenhum agente dessas frentes foi iniciado nesta tarefa.


## Preparação Windows no cartão após teste físico — 12/11/2026

O preparador Windows apontou falhas de início de instalador por arquivo/pasta
corrompido, e os eventos do Windows registraram corrupção de estado AppX.
A recuperação do volume pertence ao projeto Windows11_SteamDeck_preparo.
O owner PhaseZero conserva instalação dos agentes, ai-memory e recuperação.

A janela de preparação agora expõe autorização de downloads, aguarda o código
de saída de cada ação e mantém resultado visível ao reabrir. A modalidade de
download manual apresenta instalação pendente. O registro por ação usa o writer
atômico existente em ai-tools/logs. Quatro jornadas de regressão exercitam
instalação manual, autorização, falha do filho e falha ao iniciar o processo,
com processos e gravação substituídos por fixtures. O workflow Windows executa
essas jornadas junto do ensaio WPF e do lifecycle nativo já existente.

Host Linux com limites de CPU e RAM. As quatro jornadas passaram no PowerShell
local. O [ensaio nativo em ef033ba](https://github.com/Misael-art/phase-zero/actions/runs/43247289736)
passou com PowerShell 5.1, renderização WPF, quatro jornadas, companion e
lifecycle de memória com backup/restauração em base descartável. O pacote
desse código foi reconstruído e seus 105 arquivos foram conferidos por hash
no cartão.

O Pester geral nesse SHA registrou 809 testes aprovados, uma falha e dois
ignorados. A falha foi o orçamento do PSScriptAnalyzer, com 926 avisos diante
do limite 921. O incremento de teste trata os quatro avisos da nova fixture
com parâmetros comuns reais, escopo explícito do writer e verificações de
caminho/recibo. O retry de saúde no ensaio nativo conserva o último erro para
diagnóstico. O limite do gate foi preservado.

O fechamento em `263e2d7b87dff0f82256e7cc790269e38de8090d` teve 38 checks
aprovados e um ignorado. Pester registrou 810 aprovados, zero falhas e dois
ignorados. PSScriptAnalyzer voltou a 921 avisos. O
[ensaio Windows do pacote](https://github.com/Misael-art/phase-zero/actions/runs/43265888542)
também passou nesse SHA. Naquele fechamento o runtime conservava `ef033ba`,
com o mesmo código de produto e os 105 hashes conferidos. O delta seguinte trata fixtures
e evidência de validação.

Instalação/login no Deck dependem do Windows nativo. A transferência do
histórico privado depende da chave de recuperação do domínio criptografado.
O comando de práticas do checkout retornou
practices-not-configured. Checkout, roadmap e este handoff sustentam a
continuidade desta rodada.

A ação **Instalar Codex Desktop e Claude Code** autoriza os downloads pelo
próprio botão e executa a instalação. O recibo conserva essa autorização.
As quatro jornadas atuais cobrem instalação dos aplicativos, preparação da
memória, falha do processo filho e falha de abertura, com os efeitos substituídos
por fixtures. A janela informa os downloads na descrição da tarefa.

O CI de `4d67050` passou no ensaio Windows do pacote e encontrou uma corrida
no teste Python de SIGTERM. O supervisor fecha a porta, aguarda o leitor e
publica o estado final. O teste agora aguarda porta fechada e estado stopped
dentro do prazo original de oito segundos, conservando as duas asserções.
O teste focal passou em 1,39 s no ambiente Python gerenciado, com temporários
privados em disco. A raiz temporária ausente da primeira invocação foi criada
antes do ensaio válido. A VM própria ficou pausada durante o teste e foi retomada.

O fechamento de código em `61eb775b1120d5564249000e3af74076d5700548` teve
37 checks aprovados e um ignorado, incluindo os dois jobs Pester e Python.
O runtime foi reconstruído pelo empacotador canônico e atualizado no cartão,
com os 105 arquivos conferidos por SHA-256 e cópia dos arquivos substituídos
no destino de recuperação. O produto usa o fluxo de instalação ensaiado
nativamente em `4d67050`. [CI da branch](https://github.com/Misael-art/phase-zero/actions/runs/43292255819),
[CI do PR](https://github.com/Misael-art/phase-zero/actions/runs/43292265763),
[ensaio Windows](https://github.com/Misael-art/phase-zero/actions/runs/43288210494).

O cofre Linux estava aberto, mas a chave de memória configurada continuou
indisponível. O serviço de origem estava inativo. O histórico aguarda a chave
desse domínio ou o arquivo de recuperação criptografado existente, solicitado
ao operador. Instalação, autenticação, consulta MCP pelos dois clientes e
sincronização permanecem sujeitos ao aceite no Windows físico.


## Clientes Windows pelo cache preparado — 14/11/2026

O preparador do microSD já possui os payloads fixados de Codex CLI, Claude Code
e Claude Desktop. O owner PhaseZero passa a expor InstallCachedApps e
CachedAppStatus em prepare-host.ps1, com cache explícito e sem rede/WinGet.
O novo módulo cached-apps.ps1 preserva o inventário ai-tools, vincula Windows e
SID, confere bytes contra o payload original e conserva o pacote Codex inteiro.
Nenhuma consulta elevada executa os clientes. Abertura, login e memória privada
continuam gates distintos. A janela oferece essa ação quando recebe OfflineCache
e conserva a identidade do usuário na elevação.

No Jupiter Linux, o ambiente gerenciado ui estava pronto. Sob execução serial,
as fixtures passaram: 40 checks do cache, cinco jornadas da janela e dois
testes pytest do empacotador. A conferência inicial do PSScriptAnalyzer foi revista: a rodada completa
identificou dois avisos novos nos construtores de fixture e um aviso existente
na atualização do PATH. Os três agora têm ShouldProcess efetivo; o orçamento
global 921 permanece. A análise final deve ser conferida no SHA publicado.
As fixtures substituem processos, registro, rede e AppX. O workflow Windows
renderiza também a janela com cache; ainda é necessário observar seu resultado
no SHA publicado e ensaiar os clientes reais no Windows descartável. O preparador
Windows fará a ponte para esse contrato, sem copiar sua implementação.

As práticas continuam practices-not-configured, e o servidor ai-memory de origem
está indisponível. O cofre não forneceu a chave configurada; nenhum banco, cofre
ou chave foi recriado. Esta entrada conserva a descoberta até a memória voltar.
A distribuição oficial offline OpenAI foi localizada com MSIX e licença pública
própria; sua aquisição e identidade estão em validação pelo preparador antes de
expandir os três adaptadores atuais. Não há instalação física ou recuperação
de histórico privado nova nesta rodada. O cartão e o overlay antigo permanecem
sob o contrato de recuperação do owner Windows11_SteamDeck_preparo.

A referência PowerShell 5.1 revelou que a fixture ZIP precisava carregar
System.IO.Compression explicitamente antes do enum ZipArchiveMode. O ajuste
`e415e67c7fbc5914b5bf06dc721cd9ada51066b8` passou no
[ensaio Windows completo](https://github.com/Misael-art/phase-zero/actions/runs/43588457553),
incluindo WPF, cinco jornadas, 40 checks do cache e lifecycle de memória.
O incremento seguinte acrescenta o quarto cliente: OpenAI MSIX com licença
pública fixada, provisionamento licenciado e registro da família na mesma conta.
As fixtures locais passaram em 52 checks, sem execução real dos clientes.
Assinatura/identidade/licença de origem foram conferidas pelo preparador em
[referência Windows descartável](https://github.com/Misael-art/Windows11_SteamDeck_preparo/actions/runs/43587914719).
A instalação real desse quarto adaptador e o aceite físico continuam separados.

O código `18ce8d88192fab63525182f89127b38f5d225d23` passou no
[empacotamento/lifecycle Windows](https://github.com/Misael-art/phase-zero/actions/runs/43590184221).
O preparador confirmou instalações reais de Codex CLI, Claude Code e Claude
Desktop em referência Windows, com versões CLI executadas sem saída de rede.
O ensaio OpenAI no executor privado de 8 GiB foi interrompido pela reserva de
recursos durante o provisionamento. Os três recibos anteriores permanecem
válidos para seu escopo; não há recibo de aceite OpenAI daquela tentativa.

O ensaio de provisionamento OpenAI passa ao workflow do próprio owner público,
cujo executor padrão dispõe de 16 GiB. Mantém reserva de 4 GiB/25%, pico
estimado de 1 GiB e 10 GiB além da saída estimada de 8 GiB. Fixtures contêm
somente URLs/hashes públicos fixados; MSIX/licença não entram no Git nem nos
artifacts de recibos. GITHUB_ACTIONS, hosted runner, repositório, identidade,
privilégio e destino temporário são conferidos antes dos efeitos. A instalação
usa a entrada normal, vinculada a Windows/SID, com prazo e supervisão serial.
A reserva não foi reduzida para obter aprovação. Registro/provisionamento
nativos ainda não comprovam abertura/login, isolamento de rede de todo o SO
ou Windows 11 físico.

A primeira referência OpenAI pública encontrou estreitamento numérico no
PowerShell 5.1: Math.Max escolhia Int32 a partir do literal 512MB, mas 25% de
16 GiB excedia Int32. O orçamento usa agora ambos os operandos double,
preservando os mesmos limites. Uma fixture executa a aritmética real com
leituras sintéticas de 16 GiB. Não houve falta de RAM nessa falha nem
provisionamento OpenAI aprovado; a referência deve ser repetida no novo SHA.
