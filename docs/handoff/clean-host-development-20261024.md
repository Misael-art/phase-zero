# Continuidade PhaseZero em host limpo — 2026-10-24

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

No Windows, conferir SHA-256 via `Get-FileHash` ou Git Bash. Ler README do repositório privado e manifestos extraídos antes de restaurar. Inspecionar bundle e patches em worktrees separados; não aplicar WIP diretamente em `main`. O resgate **não** inclui `.mimosa/`, `uber-defesa-privada/`, VMs/ISOs, credenciais, sessões, ai-memory ou estado de serviços. Essas partes não podem ser reconstruídas só com GitHub. Windows VM local foi declarada descartável pelo operador.

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

1. Verificar `git status`, `git fetch origin`, SHA/tag, PRs e CI. Criar branch `codex/<tema>` e worktree próprio a partir de `origin/main` atual. Não trabalhar em checkout sujo nem em `/tmp`/`XDG_RUNTIME_DIR`.
2. Ler `AGENTS.md`, roadmap da área e esta auditoria. Reproduzir defeito e rodar baseline de testes afetados antes de editar. Separar mudanças por contrato e adicionar teste de regressão que observe efeito real, sem espelhar implementação.
3. Rodar validações locais com HOME/XDG sandboxados, temporários fora de `/run/user`, recursos monitorados. Sem VM física/boot, Docker real, login, pacote de produto ou alteração de serviço no host de desenvolvimento. Para gates físicos, usar host descartável/operação agendada, evidência antes/depois e rollback.
4. `git diff --check`, ShellCheck/Bash syntax ou Parser/Pester, pytest focal e CI. Revisar segredos e destinos de escrita. Commit pequeno, push, PR com SHA/base, prova, limites e próximo passo. Não promover release por suíte parcial.

## Fila de trabalho, ordem e aceite

| Prioridade | Frente | Ação concreta | Aceite necessário |
|---|---|---|---|
| P0 | Preservação | Recuperar resgate privado, conferir WIP Bonsai/WinVM, revisar segredos e publicar commits pertinentes em PRs próprios. | Hash remoto do tar, manifestos, bundle/patches em worktrees isolados e testes específicos antes de cada PR. Estado privado do host permanece fora do resgate. |
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
