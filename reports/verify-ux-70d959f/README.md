# Verificação independente — 70d959f

Data de fechamento: 2026-09-08. Escopo: UX-001..004, correções c784373 e documentação8c7a3d3/70d959f. Nenhuma alteração de produto nesta revisão.

## Parecer

**Aceite local de UX-001..004: 117 testes passaram** (Player49, Windows VM30, agente/web38). Correções de código e QA dark confirmadas localmente. Resultado final dos testes em [validation.json](validation.json) e [pytest-final.txt](pytest-final.txt). Não equivale a release, instalação limpa ou teste físico.

| Item | Prova independente |
|---|---|
| UX-001 | Só uma definição de _refresh_onboard_label. Na etapa review, confirmação hidden:false, enabled:true, visibleRegion não vazio. Teste público agora exige visibilidade e habilitação, retângulo inteiro e QApplication.widgetAt antes de enviar clique. |
| UX-002 | Planos com16000→15999MiB, mesmos apps e ambos pass, disparam execução simulada. Suite cobre mudança material e verdict fail. |
| UX-003 | MainWindow + tema dark, alternância800→1280→800: máximos horizontais zero. Conteúdo rolável, controles do header/onboarding legíveis. |
| UX-004 | Mesma alternância: máximos horizontais zero. Em800, botão Iniciar termina emx708 contra limite737; totalmente dentro do viewport. |

[Probes/medidas](probes.json) · [Homelab800](Homelab-800.png) · [Windows800](Windows-VM-800.png) · [Homelab1280](Homelab-1280.png) · [Windows1280](Windows-VM-1280.png).

`review_button.confirmed:false` no probe é intencional: esse cenário verifica que Avançar sozinho não confirma revisão; clique de confirmação é coberto pelo teste público da suíte. Não representa regressão.

Reprodução visual: `python reports/verify-ux-70d959f/verify.py`. Wrapper cria ambiente allowlist e HOME/XDG temporários, intercepta status, bloqueia serviços. Capturas demonstram layout, não prontidão real de servidor/VM. Primeira tentativa de harness foi interrompida durante renderização lenta; log misto de tentativas foi descartado como prova. Rodada final de pytest usa arquivo e basetemp exclusivos.

## Rodada seguinte — UX-009 replicado pelo catálogo real (510eeed)

A jornada de referência só tinha sido provada com um app sintético. Agora ela é
exercida uma vez por app real do catálogo.

| Mudança | Prova |
|---|---|
| `firstUse.stepsPtBr` para os 10 apps user-facing (+ node-exporter); `steps` continua sendo a cópia inglesa do CLI | teste parametrizado percorre não instalado → preparando → configurar acesso → pronto para usar, por app, conferindo `openUrl` e cada passo no card |
| `journey.first_use_steps` prefere `stepsPtBr`, com fallback para `steps` | app sem tradução não fica sem texto; teste de cobertura exige tradução para todo user-facing |
| Abrir a solução deixou de marcar primeiro acesso sozinho | operador confirma os passos da própria solução; "Ainda não" mantém o card em Configurar acesso — abrir página não é conta criada |
| Contrato pt-BR no CLI | `tests/linux-homelab.sh` exige `stepsPtBr` do mesmo tamanho e diferente de `steps`; `apps list --json` real devolve a cópia pt-BR |

## Falha de suíte investigada — canal de instalação (60104a5)

A execução completa de pytest acusou `test_installation_manager.py::test_status_reports_channel_and_root_conflicts`.
Não era teste frágil nem efeito do diff de UX: `manager.status()` derivava o canal
`user` de `XDG_DATA_HOME` sempre que a variável existisse, enquanto o home vinha de
`_target_account()`. Sob sudo/pkexec — como o admin bridge chama `pz` — as duas
fontes discordam, e uma instalação de usuário presente era reportada como ausente,
com `activeChannels` e conflitos errados. `XDG_DATA_HOME` passa a valer só quando
pertence ao home da conta alvo. Dois testes novos cobrem o caso elevado e o comum.

Resultados destas duas rodadas: **pytest 866 passaram, 0 falhas** (antes 863/1, e a
falha só aparecia com `XDG_DATA_HOME` exportado) e **`tests/linux-homelab.sh` exit 0**,
reexecutada após os dois commits. A suíte shell é hermética: `HOME`/`XDG_*`/estado em
`mktemp -d`, `PZ_HOMELAB_APPS_NO_DOCKER=1`, WinVM stubbado por arquivo. Segue sendo
aceite local: nenhum app foi instalado de verdade, nenhuma conta criada em servidor
real, nenhuma medição com participantes.

## Rodada UX-005/007 — escolha indisponível deixa de fingir instalação (7099ef4)

Diagnóstico antes de mexer, contra o CLI real: **todo perfil do catálogo tem
`installable=false`** (`assistant-private`, `developer`, `automation`, `ai-studio`,
`edge`, `assistant-multichannel`). `prepare --dry-run --profile edge` reserva
1664 MiB e devolve `apps: [jellyfin, syncthing, vaultwarden, uptime-kuma]`, enquanto
`profileServices: [zeroclaw, 9router]` — o que o perfil promete — não é instalado.
O aviso de orçamento já existia; a execução seguia mesmo assim. Era exatamente o
que o aceite de UX-005 proíbe, e não um caso de borda: é o comportamento de todo
perfil hoje.

| Mudança | Prova |
|---|---|
| Plano revisado com perfil sem receita não executa sozinho; a página nomeia os serviços que ele não instala e exige decisão explícita | cancelar não roda comando nenhum; "só reservar recursos" roda apenas `profile set`; "instalar base do servidor" roda `prepare` sem perfil; perfil instalável executa o plano revisado sem perguntar |
| `journey.plan_simulation_refusal` nomeia serviços e nota | recusa cita `zeroclaw`, `9router` e `zeroclaw worker not implemented` |
| UX-007: plano resumido em `journey.plan_summary` num widget — servidor, apps, acesso, memória, etapas | resumo confere as cinco linhas e não contém argv nem flags (`--json`, `--dry-run`, `--profile`, `dryRun`, `appsSource`); JSON permanece na Saída para a visão avançada |

Dois testes R01-003 fixavam a redação antiga do aviso no log; foram reescritos contra
a invariante (verdade do perfil orçamento afirmada na interface), agora conferida no
widget e no log. Resultado desta rodada: **pytest 872 passaram, 0 falhas** e
**`tests/linux-homelab.sh` exit 0**.

Sem captura visual nesta rodada — o aceite é por controle e por comando executado,
não por layout. Limites anteriores continuam valendo.

## Rodada UX-006 — o card do objetivo chega à jornada que promete (a4ad262)

Diagnóstico antes de mexer: o Início oferecia objetivos, mas cada card disparava
uma ação do catálogo e deixava o resto da jornada para ser achado na barra
lateral. **Não existia card de Windows.** "Cuidar de outro computador" executava
`homelab.hosts` — uma listagem JSON —, não o pareamento. A faixa de primeiro uso
exigia IA duas vezes: `ai.compat` e `ai.backup.export` ("Exportar memória e
acessos", ação da categoria IA & Dev). Não havia retomada de tarefa recente.

| Mudança | Prova |
|---|---|
| `BasePage.category_requested(categoria, foco)` + hook `focus_journey`; `MainWindow.show_journey` abre o destino e pede a etapa de entrada | clique real no card navega: `current_category` e o widget do stack passam a ser a página do destino |
| Objetivos com destino: hospedar → Homelab (fluxo do começo); cuidar de outro computador → Homelab na etapa **pair**; novo objetivo **Instalar e usar Windows** → Windows VM no controle de instalação | teste parametrizado confere `(destino, foco)` por card; pareamento chega em `onboard_step_name() == "pair"` com confirmação de outro host descartada; Windows chega com `focusWidget()` no controle de instalação |
| Primeiro uso sem IA: diagnosticar + preparar este computador | teste cruza os ids usados na faixa com todas as ações das categorias de IA e exige interseção vazia; IA continua ofertada como um objetivo entre outros |
| Retomar tarefa recente, com o estado real, voltando à página dela | ledger com operação `interrupted` produz card "Tarefa interrompida · Preparar Homelab"; clique pede a categoria certa; primeiro uso não mostra o card |

Bug encontrado no caminho: o Início construía `OperationLedger(root)` com a **raiz
do repositório** em vez do diretório de estado, enquanto todo o resto usa
`OperationLedger()`. O ledger procurava `<repo>/*/operation.json`, nunca achava
nada, e por isso todo start parecia primeiro uso — "Bem-vindo de volta" nunca
aparecia e não havia o que retomar. Sem essa correção, a retomada seria um card
que jamais apareceria em uso real.

Dois testes de contrato existentes fixavam o comportamento antigo (cinco cards com
rótulo único; passos de IA no primeiro uso) e foram atualizados à nova regra.
Resultado desta rodada: **pytest 883 passaram, 0 falhas**. Não reexecutei
`tests/linux-homelab.sh` — o diff é só de UI nativa e não toca o backend do
homelab.

Sem captura visual: o aceite aqui é por destino alcançado e por controle em foco,
não por layout. Continua sendo aceite local — nenhuma jornada foi percorrida por
um participante real, e o pareamento remoto de verdade (R2/UX-008) segue pendente.

## Rodada UX-008 — o primeiro pareamento remoto acontece na interface (a549f82)

Diagnóstico antes de mexer: máquina sem chave contra host novo terminava em
`state: needs-first-contact` e num aviso — *"Primeiro acesso sempre pede a senha
no terminal"* — com o comando `ssh-copy-id` para copiar à mão. O fluxo guiado não
conseguia terminar o que começava, que é exatamente o que o aceite proíbe.

| Mudança | Prova |
|---|---|
| `hosts pair --password-stdin [--timeout S]` conclui o primeiro contato; a senha vai por stdin e chega ao ssh por um helper askpass lendo arquivo 0600 dentro de diretório 0700, destruídos em toda saída | stub no lugar do `ssh-copy-id` confirma que a senha chegou **pelo askpass** e que não aparece em argv, no JSON nem em stderr; o diretório do segredo não existe mais depois da execução |
| Espera limitada: host que não responde não trava a interface, e matar o processo é cancelamento seguro | `--timeout 1` contra stub que dorme devolve `state: timeout` com a causa em linguagem de produto |
| Desfechos distintos em vez de uma falha só: `paired`, `auth-failed`, `timeout`, `unreachable`, `empty-password` | cada estado conferido no JSON; entrada vazia não chega à rede (log do stub permanece vazio) |
| A página pede a senha, explica a recusa, oferece nova tentativa e preserva a intenção do onboarding; recusar deixa o host sem pareamento | 8 testes na página real: cancelar não dispara comando algum, `_pair_advance` sobrevive à retomada, e resultado de outro host continua descartado |

O teste legado de pareamento fixava o aviso de terminal (porta 2222 na mensagem);
foi reescrito contra a nova regra — primeiro acesso pedido na interface, sem aviso
de terminal. A senha continua fora de argv por asserção explícita sobre o código
de `start_pair`.

### Falha dualscreen: verificada, reproduzida e corrigida

O relatório anterior registrava que a falha dualscreen alegada pelo agente **não
tinha sido verificada**. A execução completa desta rodada a produziu:
`test_status_contract.py::test_status_command_always_reports[emulation.dualscreen.status]`
estourou os 90s. Reproduzida isolada, e também **em HEAD limpo com `git stash`** —
portanto anterior a este diff. Causa observada em processos vivos: `kscreen-doctor -o`
fica pendurado sem sessão KDE (havia órfãos com mais de 10 minutos na máquina), e
`dualscreen_kwin_indices` chamava sem limite, então `emulation dualscreen detect`
nunca retornava sob runner de teste ou serviço. A chamada passou a ser limitada;
detect responde com os conectores e marca os índices KWin como `unknown`.
`tests/linux-dualscreen.sh` ganhou guarda com `kscreen-doctor` travado de propósito.

Resultado desta rodada: **pytest 891 passaram, 0 falhas**; `tests/linux-homelab.sh`
exit 0; `tests/linux-dualscreen.sh` exit 0.

Limite honesto desta rodada: **nenhum pareamento foi feito contra um servidor SSH
real**. O primeiro contato é provado contra um stub que representa o `ssh-copy-id`,
o que cobre o contrato (senha por askpass, fora de argv, limites e estados) mas não
prova a negociação real com um sshd — inclusive host key desconhecida, teclado
interativo e senha expirada. R2 só fecha de verdade com uma máquina remota nova.

## Rodada UX-010 — a interface para de prometer 3D que não pode provar (e821d6b)

Diagnóstico antes de mexer, comparando os dois lados do contrato: a UI declarava
`virtio-gl` com `"mode": "stable"` e rótulo *"aceleração OpenGL"*, enquanto o
backend classifica o mesmo perfil como **experimental** e escreve, na própria nota
de recomendação, *"VirtIO GL valida caminho host, sem garantir 3D no Windows"*. O
diálogo de instalação listava a opção sem consultar o host: numa máquina sem render
node ou sem `virtio-vga-gl`, o operador escolheria "aceleração" e receberia um guest
sem 3D. É o primeiro item do aceite, violado por construção — e a incoerência ficava
visível até no texto de uso do `graphics.sh`, que já chamava o perfil de experimental.

| Mudança | Prova |
|---|---|
| Contrato alinhado ao backend: `virtio-gl` é experimental, e rótulo/texto dizem que não garante 3D dentro do Windows | teste de coerência roda `graphics status --json` de verdade e exige que todo perfil marcado `stable` no contrato seja `stable` para o host; o que é oferecido sem ser estável precisa dizer "experimental" ou "não garante" |
| Modo simples oferece só o que é estável **nesta** máquina e mostra o display recomendado com o motivo | host que reporta `virtio-gl` experimental ou bloqueado deixa a opção fora da lista simples; o rótulo de recomendação traz perfil e motivo medidos |
| Sem medição do host, fica no perfil compatível | `simple_graphics_options({})` devolve só `compat`, e a recomendação explica que não houve medição — nunca o caminho otimista |
| Avançado mantém experimentais, ditos como tal, com o bloqueio do host junto da opção | opção aparece como "indisponível neste host" e o helper carrega o bloqueio medido (ex.: render node ausente) |

O teste legado do diálogo fixava a promessa antiga (`virtio-gl — aceleração OpenGL`
oferecido no modo simples); foi reescrito para a nova regra — simples sem medição
só oferece `compat`, avançado oferece o experimental com o rótulo honesto.

Resultado desta rodada: **pytest 900 passaram, 0 falhas**;
`tests/linux-windows-vm-graphics.sh` exit 0.

Limites desta rodada, sem suavizar: **nada foi verificado com um Windows convidado
rodando**. O que está provado é a coerência entre contrato, medição do host e
interface — que um guest sem 3D não *apareça* acelerado. Confirmar se o 3D funciona
de fato dentro do convidado exige instalação real. O terceiro item do aceite de
UX-010, "física separada", não foi tocado nesta rodada.

## Próxima etapa

UX-005/006/007/008/009/010 têm aceite local pelas rodadas acima: jornada por app
real, instalação distinta de simulação de orçamento, plano em linguagem de produto,
recuperação por controle visível, objetivos do Início que chegam à jornada que
prometem, primeiro pareamento concluído sem terminal e gráficos que não prometem
3D sem medição.

O que a direção original pedia e ainda **não** foi feito, em uma frase: nada disso
foi exercido contra máquinas de verdade nem por quem não conhece o produto. Não se
instalou um app num servidor real, não se criou a primeira conta, não se pareou um
host remoto novo (UX-008 está provado contra stub, não contra um sshd), não se
iniciou um Windows convidado para conferir 3D (UX-010 prova coerência, não
comportamento do guest), e nenhum objetivo do Início foi percorrido até o fim.

Em aberto no roadmap: UX-011 (acessibilidade e usabilidade) e o item "física
separada" de UX-010. Permanecem pendentes tema light, escala150/200%, leitor de
tela, usabilidade com participantes, CI/PR/release, banco↔anexos e snapshots por
serviço. A falha dualscreen deixou de ser alegação: foi reproduzida em HEAD limpo
e corrigida na rodada UX-008.

## Handoff

```text
Objetivo: verificar retorno de70d959f e fechar contrarrevisão UX-001..004.
Branch/worktree: codex/verify-ux-70d959f; /mnt/sdcard/Projects/pz-verify-ux-70d959f-tree.
HEAD inicial:70d959f; documental 4e318a9; jornada 510eeed; canal de instalação 60104a5; UX-005/007 7099ef4; UX-006 a4ad262; UX-008 + dualscreen a549f82; UX-010 e821d6b.
Arquivos: reports/verify-ux-70d959f; notas Estado vivo/Ledger Homelab e roadmap REV.
Testes: validation.json/pytest-final.txt; QA dark e medidas de viewport.
Depois: pytest completo900 verde; linux-homelab.sh, linux-dualscreen.sh e linux-windows-vm-graphics.sh exit0.
CI/PR: nenhum; host sem alteração de workloads/serviços/VM/boot/pacotes.
Segredos: ambiente allowlist, fixtures sintéticas, diff revisto; gitleaks não executado.
Limitações: aceite local; demais UX e certificação física continuam pendentes.
Próximo passo: UX-005..010 com aceite local; faltam provas contra máquinas reais
(sshd para UX-008, guest Windows para UX-010) e UX-011 segue aberto.
```
