# Continuidade PhaseZero em host limpo — 2026-10-24

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
privado já registrado `~/.local/share/project-recovery/PhaseZero/`, com bundle
incremental e manifesto. Próximo gate de publicação: reconciliar este incremento
com a continuidade registrada sem carregar mudanças alheias. Prompts entregues
separam instrumentação Gamescope (SteamZero) de telemetria passiva (Fôlego);
nenhum agente dessas frentes foi iniciado nesta tarefa.
