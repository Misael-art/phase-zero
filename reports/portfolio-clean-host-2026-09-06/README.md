# Auditoria PhaseZero — portfólio pronto para uso em host limpo

Data: 2026-09-06. Base auditada: `origin/main` em `2180c94fbfdf67c46050c1bbab9798adf66f3a91`, release `v1.19.0`.

## Parecer

**PhaseZero ainda não cumpre a expectativa de selecionar uma solução e recebê-la pronta para uso em Arch ou Windows sem dependências prévias.** Há fundações úteis e testes verdes, mas instalação, configuração, inicialização, autenticação e validação estão distribuídas entre fluxos diferentes. Vários caminhos terminam antes de entregar resultado utilizável; alguns reportam sucesso apesar de falhas.

O incidente relatado é compatível com uma causa concreta: **“Preparar Homelab” não instala Docker/Compose**. O fluxo que instala pacotes fica em perfis separados; mesmo nele, scripts de aplicações executam antes da habilitação dos serviços. Sem detalhes do outro host, isso explica uma classe de falhas, não identifica definitivamente a causa de cada ocorrência relatada.

Prioridade imediata: corrigir integridade do restore e eliminar sucesso falso. Em seguida, fechar bootstrap em host limpo e tornar todas as superfícies consumidoras do mesmo plano de solução. Expandir catálogo antes disso aumenta a quantidade de caminhos incompletos.

**Entregáveis:** [backlog detalhado](BACKLOG.md), [backlog estruturado para agentes](backlog.json), [plano de execução](PLANO.md), [evidências](evidence/), [reprodutor Linux](reproduce.py) e [contratos PowerShell](reproduce-windows-contract.ps1). São 31 itens; correções permanecem `pending`. Evidência de defeito não significa correção verificada.

## Base, método e limites

- Checkout original: `/mnt/sdcard/Projects/PhaseZero`, branch `release/v1.19.0`, HEAD `9ef6107`; `linux/pz` modificado e quatro caminhos untracked preexistentes, preservados. Nenhum desses WIPs integra os achados da release.
- Worktree de auditoria: `/mnt/sdcard/Projects/pz-portfolio-clean-host-audit`, branch `codex/portfolio-clean-host-audit`, criada da `origin/main` revalidada. Árvore versionada de `9ef6107` e `2180c94` sem diferença de conteúdo.
- Host de análise: `misael-jupiter`, BigLinux baseado em Manjaro, `ID_LIKE=arch`. **Não é Arch oficial limpo.** Ambiente Windows nativo não disponível nesta sessão.
- Revisão cobre entrypoints, 15 perfis JSON, 79 capabilities, catálogo Homelab de 10 apps públicos/3 componentes de infraestrutura, seis perfis appliance, onze IDs Linux de proxies, UI/SSH/agente/web, IA, empacotamento e CI. Nenhum script de perfil referenciado está ausente; isso comprova existência, não funcionamento.
- Testes em fixtures temporárias, HOME/XDG separados, comandos de serviço bloqueados ou substituídos por stubs. Compose validado somente no cliente, sem daemon. Pacote oficial baixado e inspecionado sem instalação.
- Nenhum workload real implantado; nenhuma mudança em serviços reais, firewall, boot, VM, discos ou configurações de IA do usuário. Serviços externos autenticados não receberam prompts de teste nem custos de inferência.
- Não houve validação física de VM/Deck/GPU, primeiro boot de Arch/Windows, Docker Desktop/WSL, login real em provedores, ingestão real em todos os apps ou teste de carga. Essas lacunas são parte explícita do plano de aceite.
- RTK e ponte administrativa disponíveis; memória consultada, sem histórico Homelab útil retornado. Roadmaps canônicos lidos e tratados como histórico de intenção/evidência, confrontados com código atual.

## Evidências executadas

| Prova | Resultado | Alcance |
|---|---|---|
| `pytest` deps/capabilities/Homelab/web/agente/roteamento/catálogo | 155 passed | Contratos e fixtures; não instalação real |
| `pytest` UI/VM/temas/emulação/desktop/status | 209 passed; total direcionado 364 | Contratos; sem validação física |
| `tests/linux-homelab.sh` | exit 0 | Fault suite hermética; Docker real bloqueado |
| `tests/linux-ai-proxies.sh` | exit 0 | Configuração, procedência e contratos com stubs |
| `tests/linux-9router.sh` | exit 0 | Attach-only, unidades, PID e redação em fixture |
| `tests/linux-agent-workspaces.sh` | exit 0 | Gates/procedência/configuração em fixture |
| `reproduce.py` | 12 registros de reprodução/observação, assertions satisfeitas | Inclui ausência de dependências, sucesso falso, backup vazio e restore de arquivo não listado |
| `reproduce-windows-contract.ps1` | 2 caminhos de falha retornam sem erro | Funções reais extraídas por AST, dependências simuladas, PowerShell no Linux |
| Compose cliente | 13 arquivos válidos; **zero healthchecks declarados** | Validade sintática; não saúde de aplicações |
| Pacote Arch oficial | SHA-256 conferido; CLI pública ausente | Inspeção real do asset publicado |
| Pester 3.4.0 local | Não executou suítes: dependência `Get-WmiObject` indisponível no Linux/PowerShell atual | Não classificar como regressão Windows; CI Windows existente é evidência histórica separada |

Saídas completas em `evidence/`. Sintaxe validada: 221 scripts shell e 97 PowerShell, zero erros. Resumo completo em [validation-summary.json](evidence/validation-summary.json). Suíte total do repositório não foi executada nesta auditoria.

CI pública revalidada: [main ci 33136161096](https://github.com/Misael-art/PhaseZero/actions/runs/33136161096) e [gitleaks 33136161092](https://github.com/Misael-art/PhaseZero/actions/runs/33136161092) success em `2180c94`; [release 33136169621](https://github.com/Misael-art/PhaseZero/actions/runs/33136169621) success em `9ef6107`. Isso não invalida os defeitos: os caminhos reproduzidos não são exercitados pelos gates atuais com as mesmas condições.

Asset examinado: `phasezero-control-center-1.19.0-1-any.pkg.tar.zst`, SHA-256 `729aa6f3e529f0ff3ce03a870c4e9866e6a7186317fda90dfc66f358cdd9725d`. Fonte: [release v1.19.0](https://github.com/Misael-art/PhaseZero/releases/tag/v1.19.0). Manifesto do pacote em [arch-package.json](evidence/arch-package.json).

## Falhas que explicam a experiência atual

### Instalação e primeiro uso

O pacote instala Python/PySide6/Bash/jq/Polkit, mas apenas `phasezero-control-center` em `/usr/bin`. O payload inclui `linux/pz`, sem disponibilizar `pz` no PATH. A bridge SSH chama justamente `pz`. O README também começa por `phasezero-admin`, ferramenta que o host limpo pode ainda não ter.

No Homelab, `repair` prepara `.env`; `up` exige Docker já utilizável. `pz install server-homelab` instala pacotes, mas executa o script `up` antes de habilitar Docker. Além disso, não fecha nesse fluxo a decisão de como o usuário acessará a engine. Instalar pacote, iniciar daemon e permitir acesso são etapas distintas. A documentação oficial do Docker confirma que acesso pelo grupo requer nova avaliação da sessão e concede privilégios elevados; essa escolha deve constar do plano, não aparecer como reparo manual posterior. [Docker pós-instalação](https://docs.docker.com/engine/install/linux-postinstall/).

Windows possui grafo de componentes com dependências `wsl-core` e `docker`, um avanço em relação aos caminhos diretos Linux. Porém `Ensure-BootstrapHomelabStack` apenas avisa e retorna quando Docker não está pronto ou Compose falha. Portanto, presença de dependências no grafo não comprova continuação automática após reboot, prontidão da engine ou sucesso da stack.

### Sucesso falso e preservação de dados

- Sem Docker, `apps enable vaultwarden` retorna `ok=true`, `enabled=true`, `started=false`.
- Falha simulada de `compose rm` termina com `ok=true`; update também pode aceitar pull bem-sucedido seguido de up falho.
- Um container sem healthcheck pode tornar Homelab `ready=true`, mesmo com requisitos da stack ausentes.
- `npm` falhando dentro de `install_one` pode resultar em “proxy instalado”. A chamada dentro de `if` suprime `errexit`; cada etapa precisa checar retorno explicitamente.
- Backup sem nenhum volume encontrado retorna sucesso e passa verificação.
- Restore verifica o manifesto, mas extrai todos os `.tgz` da pasta, inclusive os não verificados. Sobrepõe destino sem remover arquivos posteriores; rollback repete sobreposição e não garante retorno exato após falha parcial.

Esses achados foram reproduzidos em fixtures. **PZ-AUD-010 bloqueia confiança em restore de produção** até correção e prova transacional. Não houve restauração de dados reais.

## Matriz de aplicações Homelab

Todos os apps abaixo possuem Compose; nenhum possui healthcheck declarado no snapshot auditado. “Possui Compose” não equivale a “funcional”.

| Solução | Dependências/estado atual | Lacuna de jornada | Prova necessária |
|---|---|---|---|
| Jellyfin | Config/cache e bind de mídia | Mídia rw por padrão; seleção/permissão/GPU não fechadas no fluxo por app | Selecionar biblioteca, indexar e reproduzir mídia própria |
| Syncthing | Volume persistente e portas | Pareamento entre dispositivos e sincronização útil não provisionados pelo card | Parear segundo dispositivo e verificar ida/volta de arquivo |
| Vaultwarden | Token admin e cadastro desabilitado | HTTP 200 não prova primeiro usuário, acesso seguro, criação/consulta do cofre | Onboarding da conta, login e item persistente após restore |
| Uptime Kuma | Volume persistente | Sem provisionamento de monitores de serviços PhaseZero | Monitor saudável→falha→alerta→recuperação |
| Portainer | Socket proxy com allowlist parcial | Sem rede interna explícita e prova de compatibilidade das operações permitidas | Enumerar stack via proxy; operações não autorizadas negadas |
| Nextcloud | MariaDB e volume | Sem cron/Redis/admin/trusted-hosts integrados; depends_on não espera banco saudável | Criar conta, upload/download e tarefa de fundo |
| Prometheus | Volume de dados | Sem configuração PhaseZero de scrape/targets | Coletar métrica do appliance e alertar falha de serviço |
| Grafana | Senha admin e volume | Sem datasource/dashboard provisionados | Abrir dashboard útil com dados do host selecionado |
| Paperless | Container/secret/volumes | Broker Redis/Valkey ausente; consume/export ausentes | Importar PDF e concluir OCR pesquisável |
| n8n | Chave e volume SQLite implícito | PostgreSQL/políticas/workflows do perfil automation não integrados | Executar workflow, retomar execução e preservar credenciais no restore |

Infraestrutura adicional: socket-proxy, nextcloud-db e node-exporter. Node Exporter precisa provar observação do host correto; presença do processo em container não comprova isso.

Paperless: comparação com [Compose oficial 2.16.3](https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/v2.16.3/docker/compose/docker-compose.sqlite.yml) confirma broker e `PAPERLESS_REDIS`. Nextcloud: ausência de Redis não prova que todo boot falhará; indica lacuna de robustez/roadmap. n8n pode usar SQLite; PostgreSQL é requisito do perfil anunciado, não condição universal de startup. Ordem simples de `depends_on` também não prova prontidão do banco. [Compose e ordem de inicialização](https://docs.docker.com/compose/how-tos/startup-order/).

## IA e proxies: parecer por integração

| Integração | O que existe | Estado auditável |
|---|---|---|
| Kimi | Snapshot aprovado, Playwright, login e teste de chat no fluxo | Contratos passam; host limpo/build/auth real não provados; PZ-AUD-016/017 |
| Qwen | Snapshot aprovado, frontend administrativo e browser | Mesmo bloqueio de runtime; necessidade de build e login real |
| DeepSeek | Snapshot aprovado, browser e teste de chat | Mesmo bloqueio; sessão presente não basta, teste real continua necessário |
| MiMo | Linux usa API oficial; Windows mantém proxy Go/env-session | Paridade quebrada; Linux pode marcar ready sem inferência |
| 9Router | Gestor separado, pacote com verificação, unidades/watchdog/env protegido | Teste hermético passa; bootstrap npm/socat incompleto; rotas reais não testadas |
| qwen-worker-proxy | ID do tipo worker | Sem snapshot aprovado nesse catálogo; não é daemon Node equivalente |
| antigravity-proxy | ID listado | Sem snapshot aprovado; funcionalidade real não atestada |
| antigravity-openai-adapter | ID listado; implementação Windows distinta | Sem snapshot Linux aprovado; dependência do upstream precisa prova |
| ollieproxy | ID listado | Sem snapshot aprovado; não atestado |
| airlock | ID do tipo library | Biblioteca, não proxy de serviço pronto; sem snapshot aprovado |
| unlimited-ai-proxy | ID listado | Sem snapshot aprovado; não atestado |

Dos onze IDs Linux, quatro têm snapshot no manifesto; 9Router segue gestor separado; seis não têm aprovação de instalação nesse manifesto. `install all`, `ensure all` e `start all` não significam a mesma seleção. Bloquear fonte não aprovada é comportamento correto; apresentá-la como parte indistinta de uma suíte pronta é lacuna de produto.

Hermes tem gate explícito e manifesto ainda não aprovado. `dev-ai` é lista ampla de pacotes/scripts, não instalação atômica de assistente. ai-memory possui instalação nativa versionada com checksum, ponto positivo, mas coexistem expectativas históricas de container e vários clientes/configuradores. Odysseus possui bloqueios de procedência/imagens e não deve ser chamado de pronto por existir configuração. Os seis perfis appliance representam intenção/orçamento; todos precisam prova de cobertura dos serviços antes de anúncio como instaláveis.

Policy Broker atual é política de instalação/pull. Não comprova controle integral das ações de agentes em runtime. Recomenda-se distinguir claramente:

1. identidade/autenticação e credenciais;
2. roteamento de inferência via 9Router;
3. execução autorizada/isolada de ferramentas;
4. memória canônica por workspace;
5. operações persistentes, limites e observabilidade.

Uma requisição de chat respondida pelo gateway é prova distinta de uma ferramenta executada com política correta e distinta de memória escrita no projeto correto. Todos esses elos precisam testes próprios e um cenário integrado.

## Cobertura do restante do portfólio

| Área | Base útil | Limite desta auditoria / próximo gate |
|---|---|---|
| Apps Linux/capabilities | 79 entradas, grafo `requires`, plano/confirm, reprobe e rollback | Bootstrap de providers e disponibilidade em Arch oficial limpo |
| Dependências opcionais | Diagnóstico explícito de cinco recursos | Provider AUR e distinção requisito essencial/opcional por solução |
| Windows pós-formatação | Componentes, perfis, WSL/Docker, auditoria e estados de restart | Windows nativo limpo, PATH pós-install, reboot/resume e engine real |
| Temas/tuning | Código e contratos de aplicar/reverter | Desktop alvo real, Qt/Plasma/portais/providers ausentes |
| Emulação | Perfis, catálogo e otimização de arquivos | Binários/firmware legais fornecidos pelo usuário, launch real e preservação de mídia |
| Steam Deck | Contratos e rotas específicas de hardware | Deck real/SteamOS; não extrapolar resultado BigLinux |
| Waydroid | Perfil e scripts de setup/diagnóstico | Kernel, sessão gráfica, rede e primeiro boot em fixture apropriada |
| Windows VM/boot | Roadmap de resiliência, testes e evidência histórica | Shutdown/display/boot físicos permanecem fora desta sessão; respeitar gates WBR |

Não foi demonstrado que essas áreas estejam quebradas por completo. Também não há base para afirmar que todas funcionem em host limpo. Inventário identifica a superfície que a futura matriz de aceite precisa cobrir.

## O que preservar

- Separação entre appliance e administrador; limite que impede poluir host de desenvolvimento.
- Manifestos, plans, operação identificável, escrita protegida e testes de regressão já existentes.
- Providers/capabilities e resolução de dependências Windows como bases para convergência; evitar criar mais um instalador paralelo.
- Verificação de procedência e bloqueios explícitos de integrações não aprovadas.
- UI assíncrona, testes Qt, APIs com allowlist, TLS/CSRF/sessões e segurança de credenciais já exercitados em contratos.

Nenhum gate de segurança deve ser removido para “fazer funcionar”. O plano fecha dependências, explica escolhas inevitáveis — credenciais, autorização administrativa, reinício, hardware — e automatiza o restante.

## Definição proposta de pronto

Solução fica `ready` somente quando pacote/runtime corretos estão instalados, dependências e serviços estão disponíveis, configuração válida foi aplicada, autenticação exigida foi validada, teste funcional da solução passou e operação persistida permite recuperação. Reboot deve preservar o estado desejado. Backup/restore precisa preservar dados e segredos necessários ao caso de uso.

“Automatizado” admite decisões humanas inevitáveis em UI protegida. Não admite mandar usuário descobrir dependência, interpretar log técnico ou executar sequência manual que o produto já pode planejar. Plano completo pode receber uma única aprovação; etapas previsíveis subsequentes continuam automaticamente, com status claro e retomada segura.
