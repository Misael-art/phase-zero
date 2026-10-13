# Backlog auditável — host limpo e portfólio PhaseZero

Base: `2180c94` / v1.19.0, 2026-09-06. Fonte estruturada: [backlog.json](backlog.json). Todos os itens permanecem `pending`; nenhuma correção foi implementada nesta auditoria.

`reproduced` = sintoma confirmado em fixture. `confirmed-source` = caminho confirmado no código, sem E2E integral. `validation-gap` = falta de prova, sem afirmar falha universal. `product-gap` = diferença entre experiência esperada e entregue. P0 bloqueia aceitação de integridade de dados; P1 impede experiência confiável; P2 melhora cobertura/coerência.

| ID | Prioridade | Área | Achado | Evidência | Estado |
|---|---|---|---|---|---|
| [PZ-AUD-001](#pz-aud-001) | P1 | foundation | Pacote Arch não publica CLI usada pelo acesso remoto | confirmed-artifact | pending |
| [PZ-AUD-002](#pz-aud-002) | P1 | foundation | Preparar Homelab não prepara dependências | reproduced | pending |
| [PZ-AUD-003](#pz-aud-003) | P1 | foundation | Perfis executam aplicações antes de habilitar serviços e absorvem falhas | reproduced | pending |
| [PZ-AUD-004](#pz-aud-004) | P1 | foundation | Perfil homelab declara Compose sem executá-lo | confirmed-source | pending |
| [PZ-AUD-005](#pz-aud-005) | P1 | lifecycle | Habilitar, desabilitar e atualizar podem indicar sucesso incompleto | reproduced | pending |
| [PZ-AUD-006](#pz-aud-006) | P1 | lifecycle | Status saudável com container incompleto e sem healthcheck | reproduced | pending |
| [PZ-AUD-007](#pz-aud-007) | P1 | apps | Paperless sem broker necessário | confirmed-source-upstream | pending |
| [PZ-AUD-008](#pz-aud-008) | P2 | apps | Receitas de aplicações terminam antes da experiência utilizável | confirmed-source | pending |
| [PZ-AUD-009](#pz-aud-009) | P1 | data | Backup pode ser vazio, inconsistente ou inacessível | reproduced | pending |
| [PZ-AUD-010](#pz-aud-010) | P0 | data | Restore aplica arquivos não verificados e não restaura estado exato | reproduced | pending |
| [PZ-AUD-011](#pz-aud-011) | P1 | data | Identidade de containers/volumes não fica restrita ao projeto | confirmed-source | pending |
| [PZ-AUD-012](#pz-aud-012) | P1 | lifecycle | Apps selecionados e stack completa não convergem pelo mesmo estado | confirmed-source | pending |
| [PZ-AUD-013](#pz-aud-013) | P1 | ux | Onboarding não executa descoberta/pareamento/preparação completos | confirmed-source | pending |
| [PZ-AUD-014](#pz-aud-014) | P1 | ux | Pareamento SSH exige acesso prévio e ignora porta customizada | confirmed-source | pending |
| [PZ-AUD-015](#pz-aud-015) | P1 | lifecycle | Instalar agente/habilitar dashboard não inicia serviços | confirmed-source | pending |
| [PZ-AUD-016](#pz-aud-016) | P1 | ai | Proxies e 9Router dependem de runtime já existente | reproduced | pending |
| [PZ-AUD-017](#pz-aud-017) | P1 | ai | Build de proxy pode falhar e instalador continuar | reproduced | pending |
| [PZ-AUD-018](#pz-aud-018) | P2 | ai | all tem conjuntos diferentes e instalação agregada bloqueia | confirmed-source | pending |
| [PZ-AUD-019](#pz-aud-019) | P1 | ai | Windows e Linux divergem em autenticação, fontes e defaults de proxies | confirmed-source-contract | pending |
| [PZ-AUD-020](#pz-aud-020) | P1 | ai | MiMo pode aparecer pronto somente pela presença de configuração | confirmed-source | pending |
| [PZ-AUD-021](#pz-aud-021) | P1 | ai | Hermes não é solução automática aprovada no fluxo padrão | confirmed-source | pending |
| [PZ-AUD-022](#pz-aud-022) | P1 | ai | Seis perfis appliance descrevem serviços sem orquestração completa | confirmed-source | pending |
| [PZ-AUD-023](#pz-aud-023) | P1 | ai | Policy Broker limita instalação, não execução das ações de agentes | confirmed-source | pending |
| [PZ-AUD-024](#pz-aud-024) | P1 | ai | Servidor LLM anuncia pronto antes de inferência e modelo disponível | confirmed-source | pending |
| [PZ-AUD-025](#pz-aud-025) | P1 | lifecycle | Boot Hermes chama função shell como executável de timeout | confirmed-source-language | pending |
| [PZ-AUD-026](#pz-aud-026) | P2 | foundation | Dependências opcionais não substituem grafo de requisitos | confirmed-source | pending |
| [PZ-AUD-027](#pz-aud-027) | P1 | foundation | Compatibilidade Arch limpo ainda depende de manifests não validados nessa base | validation-gap | pending |
| [PZ-AUD-028](#pz-aud-028) | P1 | quality | CI verde não cobre promessa de host limpo e todos os apps | confirmed-ci-scope | pending |
| [PZ-AUD-029](#pz-aud-029) | P2 | ux | Portfólio expõe várias taxonomias técnicas para mesmo objetivo | product-gap | pending |
| [PZ-AUD-030](#pz-aud-030) | P1 | apps | Pins e isolamento de Compose não cumprem contrato de distribuição | confirmed-source | pending |
| [PZ-AUD-031](#pz-aud-031) | P1 | lifecycle | Governor mede RAM total e diverge entre app e perfil | confirmed-source | pending |

## PZ-AUD-001

**P1 — Pacote Arch não publica CLI usada pelo acesso remoto**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-artifact`.

**Sintoma e causa:** Pacote oficial contém usr/lib/phasezero/linux/pz, mas usr/bin contém apenas phasezero-control-center. Bridge remota executa pz --version/pz server homelab. README usa phasezero-admin antes de explicar seu bootstrap.

**Fonte primária:** [packaging/linux/aur/PKGBUILD:14](../../packaging/linux/aur/PKGBUILD#L14). **Prova da sessão:** [evidence/arch-package.json](evidence/arch-package.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Instalar entrypoints públicos pz e bootstrap administrativo compatível com host limpo; separar pacote appliance sem UI se necessário.

**Aceite comportamental:** Instalar asset em Arch mínimo; shell SSH não interativo resolve pz --version; usuário abre preparação sem configurar PATH manualmente.

**Dependências:** nenhuma na fila proposta.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-002

**P1 — Preparar Homelab não prepara dependências**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `reproduced`.

**Sintoma e causa:** repair gera secrets/configuração e ignora erro do reparo interno; Docker/Compose/Tailscale são pré-requisitos externos. Na fixture sem Docker retorna zero e after.ready=false.

**Fonte primária:** [linux/server/homelab-status.sh:331](../../linux/server/homelab-status.sh#L331). **Prova da sessão:** [evidence/reproductions.json](evidence/reproductions.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Criar operação prepare da solução com dependências, serviços, permissões, configuração e prova funcional; reutilizar providers existentes.

**Aceite comportamental:** Arch com somente dependências do pacote: selecionar Vaultwarden instala requisitos, inicia engine, configura acesso do usuário e valida aplicação; repetição idempotente.

**Dependências:** PZ-AUD-001.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-003

**P1 — Perfis executam aplicações antes de habilitar serviços e absorvem falhas**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `reproduced`.

**Sintoma e causa:** pz_run_profile executa scripts antes de systemd.enable. apply-common converte falhas de Homelab/LLM/Hermes em WARN e termina com server profile applied. Fixture com filho exit 42 termina exit 0.

**Fonte primária:** [linux/lib/common.sh:1188](../../linux/lib/common.sh#L1188). **Prova da sessão:** [evidence/reproductions.json](evidence/reproductions.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Ordenar pacote→serviço→readiness→configuração→workload; propagar falhas essenciais e persistir etapa recuperável.

**Aceite comportamental:** Docker instalado porém parado não é usado antes da prontidão; filho exit 42 torna resultado failed e impede fase seguinte.

**Dependências:** PZ-AUD-002.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-004

**P1 — Perfil homelab declara Compose sem executá-lo**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** Campo docker_compose aponta core/extras, mas runner legado não o lê; scripts do perfil incluem somente dev-tweaks. Perfil homelab, server-homelab e perfis appliance têm contratos distintos.

**Fonte primária:** [profiles/homelab.json:49](../../profiles/homelab.json#L49). **Prova da sessão:** [evidence/inventory.json](evidence/inventory.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Normalizar perfis como seleção de soluções; migrar campo sem consumidor para receita executável ou eliminar promessa de implantação.

**Aceite comportamental:** Selecionar homelab na UI produz plano com apps/dependências reais e convergência observável; nenhum campo de manifesto sem consumidor.

**Dependências:** PZ-AUD-002, PZ-AUD-003.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-005

**P1 — Habilitar, desabilitar e atualizar podem indicar sucesso incompleto**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `reproduced`.

**Sintoma e causa:** enable sem Docker grava enabled=true, ok=true, started=false. disable com rm falhando retorna ok=true. update força ok=true após pull mesmo quando up falha. Registro é alterado antes da operação.

**Fonte primária:** [linux/server/homelab-apps.sh:471](../../linux/server/homelab-apps.sh#L471). **Prova da sessão:** [evidence/reproductions.json](evidence/reproductions.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Separar desiredState de observedState; falha ou deferred explícitos; bloquear conclusão sem readiness e recuperar alteração parcial.

**Aceite comportamental:** Fixtures Docker ausente, rm exit 42 e pull ok/up failed jamais resultam em ready/completed=true; reconciliador retoma estado desejado.

**Dependências:** nenhuma na fila proposta.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-006

**P1 — Status saudável com container incompleto e sem healthcheck**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `reproduced`.

**Sintoma e causa:** Health none/unknown não entra nas falhas; qualquer container phasezero-* basta para active. build_status não exige igualdade com conjunto esperado nem incorpora todos blockers da stack. Fixture retorna ready=true sem Docker e com um container fictício sem healthcheck.

**Fonte primária:** [linux/server/homelab-status.sh:76](../../linux/server/homelab-status.sh#L76). **Prova da sessão:** [evidence/reproductions.json](evidence/reproductions.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Calcular prontidão por projeto e conjunto desejado; sondas funcionais obrigatórias; missing/unknown/starting bloqueiam ready.

**Aceite comportamental:** Um container isolado, sem check, serviço obrigatório faltando e engine indisponível mantêm ready=false; app real completa jornada antes de ficar pronto.

**Dependências:** PZ-AUD-005.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-007

**P1 — Paperless sem broker necessário**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source-upstream`.

**Sintoma e causa:** Compose modular e extras fornecem apenas Paperless; faltam Redis/Valkey e PAPERLESS_REDIS. Exemplo oficial da versão 2.16.3 inclui broker e URL. Faltam também fluxos consume/export.

**Fonte primária:** [assets/home-server/apps/compose/paperless.yml:2](../../assets/home-server/apps/compose/paperless.yml#L2). **Prova da sessão:** [evidence/compose.json](evidence/compose.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Adicionar broker compatível e dependência com readiness, volumes, configuração de importação/exportação e usuário inicial.

**Aceite comportamental:** Fixture descartável importa PDF, OCR termina, documento é buscável e sobrevive backup/restore e reboot.

**Dependências:** PZ-AUD-002, PZ-AUD-006.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-008

**P2 — Receitas de aplicações terminam antes da experiência utilizável**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** Nextcloud sem cron/Redis/provisionamento de conta; n8n sem PostgreSQL e controles previstos no roadmap; Grafana sem datasource/dashboard; Prometheus sem configuração de targets; Node Exporter sem visibilidade explícita do host; Jellyfin sem seleção guiada de mídia; Vaultwarden com cadastro fechado sem jornada inicial integrada. Não são todos requisitos de boot; são lacunas de produto/roadmap.

**Fonte primária:** [assets/home-server/docker-compose.extras.yml:9](../../assets/home-server/docker-compose.extras.yml#L9). **Prova da sessão:** [evidence/compose.json](evidence/compose.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Completar receitas por app e distinguir essencial de opcional; gerar contas/configuração inicial, dados exemplo e ação Abrir após verificação.

**Aceite comportamental:** Cada um dos dez apps executa caso de uso útil documentado; mídia/usuários/datasources/workflows e execução agendada verificados quando aplicáveis.

**Dependências:** PZ-AUD-002, PZ-AUD-006, PZ-AUD-030.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-009

**P1 — Backup pode ser vazio, inconsistente ou inacessível**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `reproduced`.

**Sintoma e causa:** Volumes ausentes são ignorados; todos ausentes geram ok=true, volumes=[] e verify=true. Backup usa tar direto de Mountpoint sem quiesce/dump nativo. Com usuário comum, permissões dos volumes podem impedir acesso. Cobertura depende core/extras, não registro de apps ativos.

**Fonte primária:** [linux/server/homelab-stack.sh:681](../../linux/server/homelab-stack.sh#L681). **Prova da sessão:** [evidence/reproductions.json](evidence/reproductions.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Inventário autoritativo, falha em volume requerido ausente, dumps consistentes ou quiesce, acesso mínimo explícito e restauração de dados/segredos/configuração como unidade.

**Aceite comportamental:** Carga gravando SQLite/PostgreSQL/MariaDB durante backup; restore preserva consistência. Zero volumes esperados só aceita backup vazio com estado explícito; dados exigidos nunca são silenciosamente omitidos.

**Dependências:** PZ-AUD-011, PZ-AUD-012.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-010

**P0 — Restore aplica arquivos não verificados e não restaura estado exato**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `reproduced`.

**Sintoma e causa:** Verifica entradas do manifesto, mas extrai todos *.tgz da pasta. Fixture comprovou extração de archive não listado e retenção de arquivo ausente no backup. Stop falho é ignorado; rollback apenas sobrepõe volumes concluídos, não limpa extras nem necessariamente reverte volume parcialmente falho.

**Fonte primária:** [linux/server/homelab-stack.sh:867](../../linux/server/homelab-stack.sh#L867). **Prova da sessão:** [evidence/reproductions.json](evidence/reproductions.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Restaurar exclusivamente manifesto validado; validar caminhos/links e identidade; staging por volume, parada obrigatória, troca transacional, rollback integral incluindo volume parcial; testar TOCTOU e backup prévio.

**Aceite comportamental:** Arquivo adicional não listado nunca é aplicado; falha no meio da extração devolve exatamente hashes/árvore anteriores; stop falho impede mutação; restaurar backup elimina arquivos posteriores conforme plano confirmado.

**Dependências:** PZ-AUD-009, PZ-AUD-011.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-011

**P1 — Identidade de containers/volumes não fica restrita ao projeto**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** Descoberta filtra name=phasezero- globalmente; volume_actual_name aceita qualquer sufixo _<logical> ou volume global. Compose usa container_name fixo, inclusive suíte disposable com nome global.

**Fonte primária:** [linux/server/homelab-stack.sh:647](../../linux/server/homelab-stack.sh#L647). **Prova da sessão:** [evidence/compose.json](evidence/compose.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Usar labels com host/instalação/projeto e resolução exata de volumes; remover nomes globais e validar propriedade antes de backup/restore/rm.

**Aceite comportamental:** Dois projetos com mesmo app e volume lógico nunca compartilham status nem dados; operação em A deixa B byte a byte intacto.

**Dependências:** nenhuma na fila proposta.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-012

**P1 — Apps selecionados e stack completa não convergem pelo mesmo estado**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** apps.enabled.json pertence ao fluxo modular; up/down/restart/boot usam core ou core+extras. Habilitar/desabilitar individualmente não define o conjunto usado pelo próximo boot ou operação geral; backup também usa camadas.

**Fonte primária:** [linux/server/homelab-stack.sh:141](../../linux/server/homelab-stack.sh#L141). **Prova da sessão:** [evidence/inventory.json](evidence/inventory.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Um reconciliador para enabled apps, perfil, boot, restart, update e backup; migração dos registros existentes.

**Aceite comportamental:** Desligar app e reiniciar host mantém app desligado; extras escolhidos reiniciam; backup cobre exatamente volumes em uso.

**Dependências:** PZ-AUD-005, PZ-AUD-011.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-013

**P1 — Onboarding não executa descoberta/pareamento/preparação completos**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** Avanço registra descoberta placeholder, trata alias selecionado como pareamento e profile=True sem implantação. Apply chama repair. Botões de app disparam mutação com Prévia separada, sem vincular confirmação ao plano.

**Fonte primária:** [linux/ui_native/pages/homelab.py:336](../../linux/ui_native/pages/homelab.py#L336). **Prova da sessão:** [evidence/pytest.log](evidence/pytest.log). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Wizard conectado a operações reais: papel→host→descoberta/autenticação→solução→dependências→plano→aplicar→verificar→abrir; aprovação única do plano completo.

**Aceite comportamental:** Usuário sem terminal prepara segundo host a partir de sessão limpa; não pode avançar pareamento falho; plano alterado exige nova revisão.

**Dependências:** PZ-AUD-001, PZ-AUD-002, PZ-AUD-014, PZ-AUD-015.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-014

**P1 — Pareamento SSH exige acesso prévio e ignora porta customizada**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** Player exige chave pública existente ou manda executar ssh-keygen; ssh-copy-id usa BatchMode=yes, impedindo primeiro login por senha, e não inclui porta do registro. Não instala runtime remoto. Registro/bridge têm port, mas ação de parear não usa.

**Fonte primária:** [linux/ui_native/pages/homelab.py:454](../../linux/ui_native/pages/homelab.py#L454). **Prova da sessão:** [evidence/pytest.log](evidence/pytest.log). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Criar/importar chave por fluxo seguro, autenticação inicial interativa protegida ou token já provisionado, respeitar porta/host key e bootstrap remoto explícito.

**Aceite comportamental:** Host novo sem authorized_keys e SSH em porta não padrão pareia; chave alterada falha com orientação; nenhuma senha em argv/log.

**Dependências:** PZ-AUD-001.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-015

**P1 — Instalar agente/habilitar dashboard não inicia serviços**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** agent install e web enable escrevem unidades e retornam systemdStarted=false. Não encadeiam daemon-reload/start, sessão persistente, primeira conta e prova HTTPS acessível.

**Fonte primária:** [linux/server/homelab_agent.py:209](../../linux/server/homelab_agent.py#L209). **Prova da sessão:** [evidence/pytest.log](evidence/pytest.log). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Adicionar provisionamento appliance de unidades, lifecycle persistente, conta inicial, confiança TLS e bind coerente; preservar gate que protege host dev.

**Aceite comportamental:** Após instalação e reboot sem login gráfico, agente/dashboard ficam acessíveis no host selecionado; conta criada em canal protegido; unit instalada mas inativa nunca aparece pronta.

**Dependências:** PZ-AUD-002, PZ-AUD-014.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-016

**P1 — Proxies e 9Router dependem de runtime já existente**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `reproduced`.

**Sintoma e causa:** ensure_node_runtime exige npm; 9router exige socat em caminho absoluto e npm. install_selected prepara Node, mas ensure_one chama install_one diretamente; instalação gera launcher apontando runtime isolado mesmo se ausente. Playwright instala browser sem orquestrar libs nativas de Arch; caminho legado MiMo exige Go.

**Fonte primária:** [linux/ai/proxy-suite.sh:55](../../linux/ai/proxy-suite.sh#L55). **Prova da sessão:** [evidence/reproductions.json](evidence/reproductions.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Resolver requisitos por tipo e versão; chamar bootstrap compartilhado de qualquer entrada; testar Git/npm/Node/socat/browser/libs/build tools ausentes individualmente.

**Aceite comportamental:** Arch mínimo instala e valida runtime/binários antes de clone/build; nenhum launcher aponta binário ausente; fluxo não depende de dev-ai previamente executado.

**Dependências:** PZ-AUD-001, PZ-AUD-002.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-017

**P1 — Build de proxy pode falhar e instalador continuar**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `reproduced`.

**Sintoma e causa:** ensure_one chama install_one em if; comandos intermediários run_npm/build não verificam retorno. Errexit do Bash fica suprimido nesse contexto. Fixture npm exit 42 produz AI proxy installed e retorno aceito.

**Fonte primária:** [linux/ai/proxy-suite.sh:391](../../linux/ai/proxy-suite.sh#L391). **Prova da sessão:** [evidence/reproductions.json](evidence/reproductions.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Checar explicitamente cada etapa, staging transacional, validar artefatos/runtime antes de registrar instalação e escrever serviço.

**Aceite comportamental:** Injetar falha em clone, npm ci, build, browser install e Go build; todas propagam failed, não escrevem registro pronto e permitem retry limpo.

**Dependências:** PZ-AUD-016.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-018

**P2 — all tem conjuntos diferentes e instalação agregada bloqueia**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** Catálogo lista onze IDs; install all exige snapshot de todos exceto 9router, mas só quatro possuem fonte aprovada, bloqueando lote. ensure all usa quatro; start all usa quatro. Seis IDs sem snapshot aparecem no mesmo universo.

**Fonte primária:** [linux/ai/proxy-suite.sh:481](../../linux/ai/proxy-suite.sh#L481). **Prova da sessão:** [evidence/linux-ai-proxies.log](evidence/linux-ai-proxies.log). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Definir conjuntos explícitos supported/default/experimental/external; manter all sem ambiguidade e apresentar indisponíveis com motivo.

**Aceite comportamental:** Todas ações all operam mesmo conjunto aplicável declarado; uma integração experimental não impede preparar as disponíveis.

**Dependências:** PZ-AUD-016, PZ-AUD-017.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-019

**P1 — Windows e Linux divergem em autenticação, fontes e defaults de proxies**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source-contract`.

**Sintoma e causa:** Linux MiMo usa API oficial; Windows usa proxy Go/env-session. Windows Sync-BootstrapAiProxyRepository clona branch rasa/faz pull sem consumir manifest de snapshots Linux. Defaults e catálogo diferem entre superfícies.

**Fonte primária:** [bootstrap-tools.ps1:17714](../../bootstrap-tools.ps1#L17714). **Prova da sessão:** [evidence/windows-contract.json](evidence/windows-contract.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Manifest comum de fontes, pins, runtimes, modelos, autenticação e maturidade; adapters por OS. Migrar MiMo Windows para contrato oficial aprovado e testar preservação dos clientes.

**Aceite comportamental:** Mesma solução em Arch/Windows tem mesmo tipo de autenticação e origem imutável; reparo não atualiza branch sem aprovação/versionamento; modelos padrão consistentes.

**Dependências:** PZ-AUD-016, PZ-AUD-018.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-020

**P1 — MiMo pode aparecer pronto somente pela presença de configuração**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** ensure_one marca ready=true/completed=true com chave presente e ignora falha de configure_mimo_official_clients. Não valida inferência nesse ramo. Credencial inválida/revogada pode parecer pronta.

**Fonte primária:** [linux/ai/proxy-suite.sh:1253](../../linux/ai/proxy-suite.sh#L1253). **Prova da sessão:** [evidence/linux-ai-proxies.log](evidence/linux-ai-proxies.log). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Separar configured de authenticated/ready; teste explícito e limitado de modelo com timeout, quota/custo informado e erro redigido.

**Aceite comportamental:** Chave inválida, quota esgotada, offline e erro de configuração IDE jamais ficam ready; resposta real autorizada fecha prontidão.

**Dependências:** PZ-AUD-019.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-021

**P1 — Hermes não é solução automática aprovada no fluxo padrão**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** Gate exige PZ_HOMELAB_ALLOW_HOST_WORKLOADS=1; manifesto Hermes tem approvedForInstall=false, semanticAudit=false e transitiveArtifactsPinned=false. Instalação ainda exige uv gerenciado e credencial 9Router. dev-ai chama setup-hermes no meio de instalação ampla.

**Fonte primária:** [linux/ai/setup-hermes.sh:107](../../linux/ai/setup-hermes.sh#L107). **Prova da sessão:** [evidence/inventory.json](evidence/inventory.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Manter bloqueio honesto; separar proteção de host dev de maturidade de produto, completar distribuição auditada e dependências. Não remover gate como atalho.

**Aceite comportamental:** Perfil padrão não aborta silenciosamente por Hermes bloqueado; UI explica maturidade. Versão aprovada instala em fixture limpa e conversa via 9Router com segredo referenciado.

**Dependências:** PZ-AUD-016, PZ-AUD-019.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-022

**P1 — Seis perfis appliance descrevem serviços sem orquestração completa**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** assistant-private/multichannel, automation, ai-studio, developer e edge contêm serviços ausentes de Compose gerenciado. Código possui cobertura que bloqueia aplicação explícita; selecionar perfil pode mudar apenas orçamento.

**Fonte primária:** [assets/home-server/homelab-profiles.json:37](../../assets/home-server/homelab-profiles.json#L37). **Prova da sessão:** [evidence/inventory.json](evidence/inventory.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Converter perfis em grafo executável de adapters ou apresentar como planos preview indisponíveis para implantação; declarar um gateway e dependências reais.

**Aceite comportamental:** Cada perfil anunciado instalável atinge cobertura 100%, memória e autenticação verificadas; demais ficam preview/blocked sem botão que promete instalação.

**Dependências:** PZ-AUD-002, PZ-AUD-006, PZ-AUD-021.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-023

**P1 — Policy Broker limita instalação, não execução das ações de agentes**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** Implementação checa cinco classes de instalação/pull; não implementa todo runtime de identidade, quotas, aprovações, filesystem/egress e idempotência descrito no roadmap. security.policyActive não prova esse enforcement.

**Fonte primária:** [linux/server/ai-policy-broker.sh:14](../../linux/server/ai-policy-broker.sh#L14). **Prova da sessão:** [evidence/linux-agent-workspaces.log](evidence/linux-agent-workspaces.log). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Delimitar rótulo atual como política de instalação; implementar broker de execução via ADR e adapters, com isolamento efetivo e prova de negação.

**Aceite comportamental:** Ação externa não confiável tentando shell/segredo/arquivo fora do workspace é bloqueada no runtime, auditada e não executa efeito; ausência de broker não vira política ativa presumida.

**Dependências:** PZ-AUD-022.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-024

**P1 — Servidor LLM anuncia pronto antes de inferência e modelo disponível**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** Setup base falho vira WARN; modelo é baixado via nohup em background; mensagem ready sai antes de download/inferência. Pull direto nessa rota não passa pelo broker de modelo.

**Fonte primária:** [linux/server/llm-server.sh:22](../../linux/server/llm-server.sh#L22). **Prova da sessão:** [evidence/inventory.json](evidence/inventory.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Unificar setup-ollama/llm-server; operação persistente de modelo com política, progresso, disco, retry e prova de inferência antes de ready.

**Aceite comportamental:** Offline, disco cheio e pull interrompido ficam degradados/retomáveis; política conservative é respeitada em qualquer entrada; requisição real bem-sucedida fecha operação.

**Dependências:** PZ-AUD-002, PZ-AUD-006.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-025

**P1 — Boot Hermes chama função shell como executável de timeout**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source-language`.

**Sintoma e causa:** as_user é função Bash, mas timeout tenta executar programa chamado as_user. Sem executável externo, etapa Hermes falha antes de executar hermes-remote.

**Fonte primária:** [linux/server/homelab-boot-prepare.sh:132](../../linux/server/homelab-boot-prepare.sh#L132). **Prova da sessão:** [evidence/linux-homelab.log](evidence/linux-homelab.log). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Aplicar timeout ao comando executável dentro da função de identidade, preservando HOME/XDG/UID e exit code.

**Aceite comportamental:** Fixture boot Hermes captura identidade correta e início; timeout mata somente processo da operação; cenário passa sem executável artificial chamado as_user.

**Dependências:** PZ-AUD-003, PZ-AUD-015, PZ-AUD-021.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-026

**P2 — Dependências opcionais não substituem grafo de requisitos**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** Catálogo deps cobre cinco entradas opcionais. wallpaper-engine-kde aponta pacote -git do ecossistema AUR, enquanto engine instala tudo via pacman -S e declara installable por mapa, sem checar provider/repos. swtpm é descrito opcional apesar de ser requisito para cenário Win11.

**Fonte primária:** [linux/deps/catalog.py:31](../../linux/deps/catalog.py#L31). **Prova da sessão:** [evidence/pytest.log](evidence/pytest.log). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Manter deps como diagnóstico opcional ou consolidá-lo no modelo de capabilities; distinguir provider/repositório/requisito por solução e evitar installable sem disponibilidade.

**Aceite comportamental:** Sem AUR/helper e em Arch oficial, item indisponível não oferece reparo impossível; requisito essencial aparece antes do uso; testes não presumem repositórios do host dev.

**Dependências:** PZ-AUD-027.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-027

**P1 — Compatibilidade Arch limpo ainda depende de manifests não validados nessa base**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `validation-gap`.

**Sintoma e causa:** Perfis legados usam listas grandes pacman e abortam preflight quando qualquer pacote não resolve; há nomes como codecs, cockpit-docker e acme.sh que precisam validação nos repositórios alvo. Host auditado é BigLinux/Manjaro, não Arch limpo; disponibilidade oficial não foi confirmada nesta sessão. Provider Flatpak exige Flatpak/Flathub já existentes.

**Fonte primária:** [profiles/safe-base.json:8](../../profiles/safe-base.json#L8). **Prova da sessão:** [evidence/inventory.json](evidence/inventory.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Validar todos pacotes por OS/repositório em CI; separar base indispensável, opcionais e receitas específicas de derivadas; bootstrap Flatpak/remote quando requerido.

**Aceite comportamental:** Todos os quinze perfis geram plano válido em Arch oficial recém-instalado ou incompatibilidade explícita por item; ausência opcional não aborta objetivo inteiro.

**Dependências:** PZ-AUD-002.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-028

**P1 — CI verde não cobre promessa de host limpo e todos os apps**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-ci-scope`.

**Sintoma e causa:** E2E de apps cobre Vaultwarden; backup E2E usa arquivos sintéticos, não bancos sob carga; shell/Qt usam stubs; package-smoke copia árvore, não instala asset em Arch limpo. CI Windows possui Pester, mas não prova jornada WSL/Docker/reboot. Roadmaps registram verified com escopo mais amplo que provas atuais.

**Fonte primária:** [tests/linux-homelab-apps-disposable.sh:2](../../tests/linux-homelab-apps-disposable.sh#L2). **Prova da sessão:** [evidence/pytest.log](evidence/pytest.log). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Matriz produto×OS×canal×estado inicial; instalar assets reais em VMs descartáveis; usar cenários de falha, reboot, multi-host e inferência supervisionada. Reconciliar evidência histórica sem apagar ledger.

**Aceite comportamental:** Cada solução stable liga a job/artefato e caso de uso; sem evidência mantém preview. CI inclui os defeitos reproduzidos e impede regressão.

**Dependências:** PZ-AUD-001, PZ-AUD-006, PZ-AUD-007, PZ-AUD-010, PZ-AUD-019.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-029

**P2 — Portfólio expõe várias taxonomias técnicas para mesmo objetivo**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `product-gap`.

**Sintoma e causa:** Dezenove categorias e superfícies parcialmente sobrepostas: Perfis, Recursos, Linux, Servidor, Homelab, IA & Dev, Proxies e Roteamento. Usuário precisa saber qual fluxo instala dependências e qual somente configura.

**Fonte primária:** [linux/ui_native/catalog.py:11](../../linux/ui_native/catalog.py#L11). **Prova da sessão:** [evidence/inventory.json](evidence/inventory.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Página inicial por objetivo: computador pessoal, administrar servidor, hospedar serviços, IA/desenvolvimento, jogos/Android/VM. Cards com requisito, custo, maturidade e operação única Preparar e usar; detalhes avançados progressivos.

**Aceite comportamental:** Usuário novo completa cinco jornadas principais sem terminal nem escolher entre APIs técnicas equivalentes; teste de usabilidade registra tempo, erros e recuperação.

**Dependências:** PZ-AUD-002, PZ-AUD-013, PZ-AUD-028.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-030

**P1 — Pins e isolamento de Compose não cumprem contrato de distribuição**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** Lock usa tags; update registra RepoDigest, mas Compose continua referindo tags/defaults PZ_IMAGE e não consome digest salvo como fonte de execução. Serviços sem healthchecks, sem redes internas declaradas e sem rotação de logs; mídia Jellyfin montada rw. Variáveis de secrets são expandidas por compose config.

**Fonte primária:** [linux/server/homelab-apps.sh:310](../../linux/server/homelab-apps.sh#L310). **Prova da sessão:** [evidence/compose.json](evidence/compose.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Render único por manifesto: digest efetivamente executado, rede/egress mínimos, mídia ro por padrão, limites/log rotation e segredos por referência quando suportado; nunca registrar compose expandido.

**Aceite comportamental:** Digest executado igual ao plano após update/reboot; scan de logs/planos não contém segredo; sem acesso de app comum ao socket-proxy; mídia read-only e rotação verificadas.

**Dependências:** PZ-AUD-006, PZ-AUD-011.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.

## PZ-AUD-031

**P1 — Governor mede RAM total e diverge entre app e perfil**

Estado: `pending`. Responsável: a atribuir. Tipo de evidência: `confirmed-source`.

**Sintoma e causa:** availableMB vem de MemTotal. App governor soma catálogo e headroom, sem considerar MemAvailable, carga externa ou reserva WinVM usada pelo outro governor. Não há preflight completo de disco/VRAM para toda solução.

**Fonte primária:** [linux/server/homelab-apps.sh:258](../../linux/server/homelab-apps.sh#L258). **Prova da sessão:** [evidence/inventory.json](evidence/inventory.json). A prova pode cobrir somente parte do item; os demais subcasos estão identificados por inspeção no texto.

**Trabalho proposto:** Unificar orçamento por host e operação, separar capacidade total de memória disponível, usar incremento requerido, disco temporário/persistente e VRAM quando aplicável.

**Aceite comportamental:** Host com RAM total alta mas MemAvailable baixo recusa incremento perigoso; seleção por app/perfil dá mesmo veredito; carga de VM e dois apps concorrentes não passa orçamento duplicado.

**Dependências:** PZ-AUD-012, PZ-AUD-022.

**Matriz de fechamento:** implementação pendente; teste comportamental da correção pendente; prova CI pendente. Atualizar os três campos antes de `verified`.
