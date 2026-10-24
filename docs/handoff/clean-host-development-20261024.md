# Continuidade PhaseZero em host limpo — 2026-10-24

## Ponto de partida e limite da prova

`main` auditada em `ddadd6de4fc5a0b8933c2d312e2f8a6dd7f1aff3`; release beta `v1.22.11` aponta ao mesmo SHA. [Auditoria versionada](../audits/status-20261024/README.md) contém evidências, capturas, lacunas e critérios de aceite. GitHub contém código e releases; **não contém** contas, tokens, VM guest, dados de Homelab nem os 18 WIPs preservados somente no cartão de continuidade. Clone de `main` basta para começar desenvolvimento da base publicada. Para continuar qualquer WIP do cartão, transportar e verificar o cartão antes de apagar o host de origem.

Este wrapper/handoff está na branch `codex/clean-host-dev-bootstrap` até o PR ser mergeado. Em host novo, após clone de `main`, execute `git fetch origin codex/clean-host-dev-bootstrap` e `git switch --track origin/codex/clean-host-dev-bootstrap` antes de usar os comandos abaixo. Se usar ZIP sem Git, baixe o ZIP **dessa branch**. Após merge, `main` passa a incluir o wrapper.

Não interpretar CI/fixture verde como homologação física de conta, proxy, VM ou segundo host. Nenhum instalador do produto, VM, container ou serviço deve iniciar no bootstrap de desenvolvimento.

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

`plan` e `doctor` somente leem. `install --yes` instala pacotes mínimos com `phasezero-admin`, `bigsudo` ou `pkexec`; se nenhum existir, falha com instrução para preparar a bridge (`linux/pz ai setup admin`) ou polkit. Evita `pacman -Sy` isolado, recusa upgrades pendentes, root direto, pouca RAM/disco e prefixo temporário. Instala pip **somente em venv de usuário** sob `${XDG_DATA_HOME:-~/.local/share}/phasezero-dev/`; `core` é menor, `ui` adiciona PySide6/Xvfb/qemu-img para testes UI/VM em fixture. Não instala Docker, serviço, modelo, guest ou workload. O instalador mostra caminho do venv anterior para rollback; não apaga automaticamente versões antigas. Para reverter, remover apenas o link `venv-core` ou `venv-ui` e apontá-lo ao venv anterior, após verificar o destino. Pacotes do sistema instalados pelo pacman exigem revisão individual antes de remover.

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
| P0 | Preservação | Conferir WIP Bonsai/WinVM no cartão; revisar segredos; publicar só commits pertinentes em PRs próprios. Criar segunda cópia verificada do cartão em mídia independente antes de formatar. | `checks/verify_continuity.py`, SHA256SUMS, HEAD/diff/untracked e restore de amostra em outra mídia. GitHub-only não cobre WIP até publicar. |
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
- PowerShell Windows não foi executado neste host Linux; Parser/Pester do job Windows são o gate de CI, e teste físico em Windows limpo permanece aberto. Prévia e guarda de consentimento têm teste Pester.
- Diff textual revisado por padrões de segredo; `gitleaks` local indisponível. O job remoto `security-secret-scan` precisa passar antes de merge. Captura de Contas revisada visualmente: estado vazio, sem identidade ou token.
- Um primeiro pytest local falhou porque o diretório de `PYTEST_DEBUG_TEMPROOT` definido manualmente ainda não existia; após `mkdir -p` conforme o exemplo acima, 29/29 passaram. Não tratar esse erro de preparação do teste como bug do produto.

## Handoff obrigatório ao encerrar próxima frente

Usar formato do roadmap Homelab: objetivo, IDs, branch/worktree, HEAD inicial/final, arquivos, commits, testes/resultados, CI/PR, estado do host antes/depois, segredos verificados, limitações/riscos, bloqueios reais e próximo passo **exato**. Dizer `fixture`, `CI` ou `host físico` em cada evidência. Nunca marcar gate físico como concluído por captura ou mock.
