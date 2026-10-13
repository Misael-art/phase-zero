# Diagnóstico IA, proxies e workspaces — 2026-08-24

## Escopo

Auditoria da UI nativa, catálogo de ações, roteamento, proxies, autenticação,
Hermes, 9Router e Odysseus. Validação sem instalar pacotes, subir containers,
alterar serviços do host ou aplicar perfis Homelab.

## Resumo executivo

Estado encontrado: recursos fortes, porém jornadas desconectadas. A UI confundia
base essencial com extras, oferecia ações sem continuidade, ocultava falhas de
serviço e apresentava três escolhas de política para um backend com uma política
global. Hermes não aparecia como workspace gerenciável. Odysseus oferecia
instalação sem prova de procedência. Autenticação existia por ferramenta, sem
catálogo comum.

Estado após correção: UI separa essenciais e opcionais, agrega agentes e gateways,
mostra autenticação e próxima ação, encadeia credencial Mimo até abertura do
serviço, aplica roteamento como transação única e bloqueia operações perigosas sem
prova. Backends agora retornam falha verificável em vez de sucesso aparente.

Continuação AI-UX-002: autenticação ganhou registro central redigido; operações da
Central ganharam ledger persistente, recuperação de interrupção e repetição com
nova confirmação. Sondas independentes de `pz ai status` passaram a executar em
paralelo, reduzindo a leitura observada neste host de cerca de 6,7 s para 4,6 s.

Continuação AI-UX-003: Kimi, Qwen, DeepSeek e Mimo ganharam manifesto de snapshot
fixo e verificação fail-closed antes de instalar ou executar. Origem, commit,
árvore, licença, lockfiles e patch local gerenciado são verificados. A UI informa
o limite: integridade do snapshot não equivale a auditoria semântica.

Continuação AI-UX-004: dependências Odysseus deixaram de usar `latest` e resolução
por pull durante deploy. Chroma, SearXNG e ntfy agora vêm de manifesto versionado
com tags explícitas e digests de manifest list. Instalação valida esse manifesto
antes da primeira escrita; start/restart validam lock exato antes do systemd.

Continuação AI-UX-005: releases candidatas Hermes e Odysseus foram auditadas sem
implantação. Hermes ganhou manifesto com release, commit, árvore, instalador e
hashes; checksum arbitrário por variável deixou de promover script remoto.
Odysseus ganhou relatório executável de riscos. A imagem-base Python agora é
reescrita para digest OCI aprovado antes do build. Dependências Python destravadas,
superfície de shell e auditoria semântica incompleta mantêm ambos bloqueados.

Continuação AI-UX-006: após autorização explícita do operador, Hermes
`v2026.8.19`/`v0.20.5` foi instalado no commit e árvore catalogados. O aceite de
risco fica vinculado ao commit exato, não a um checksum arbitrário. Hermes usa
9Router em loopback com referência à credencial canônica, gateway systemd de
usuário persistente, launcher isolado, MCP ai-memory, Skills Hub e Chromium.
Chat real e navegador headless passaram. A instalação não transforma a release
não assinada nem a cadeia transitiva incompleta em distribuição aprovada.

## Lacunas encontradas e tratamento

| Severidade | Lacuna | Causa | Tratamento |
|---|---|---|---|
| P0 | Proxy podia declarar sucesso após falha do serviço | `systemctl` e readiness não determinavam resultado | início, porta e chat validados; erro estruturado propagado |
| P0 | Proxy podia atualizar e executar ponta mutável de branch | clone/fetch sem snapshot aprovado | manifesto fixa quatro snapshots; instalação em staging e runtime bloqueiam divergência |
| P0 | Mimo podia iniciar antes da credencial | ordem imperativa incorreta | início adiado; salvar credencial inicia, valida e abre automaticamente |
| P0 | Odysseus podia ser instalado de origem mutável | ausência de allowlist e gate de release | commit e árvore precisam estar autorizados; mutações bloqueadas por padrão |
| P0 | Checksum manual podia promover qualquer instalador Hermes | confiança vinha de variável do processo, não de revisão versionada | somente manifesto versionado pode autorizar; release atual permanece bloqueada |
| P0 | Plano Odysseus encerrava sem JSON quando allowlist faltava | pipeline `jq` em arquivo ausente sob shell estrito | lookup tolera ausência e retorna blockers estruturados |
| P0 | Perfil Homelab podia parecer aplicável sem cobertura completa | perfil público não provava serviços declarativos | cobertura e orçamento viraram gates antes de `compose up` |
| P1 | Roteamento mostrava três políticas independentes | UI divergente do contrato global do backend | uma política para três rotas; preview e aplicação usam mesmo valor |
| P1 | Prévia dinâmica ficava presa em “Verificando” | falha assíncrona não encerrava estado | erro acionável, pending limpo, aplicação desabilitada |
| P1 | Editor de fallback permanecia vazio | preenchimento ligado a ação estática inalcançável | cadeia atual preenchida após recomendação dinâmica |
| P1 | Hermes ausente e Odysseus sem jornada segura | catálogo focado só em proxies HTTP | seção “Agentes e gateways”, status, diagnóstico e plano seguro |
| P1 | Estado essencial aparecia quebrado por extras ausentes | cálculo misturava dependências obrigatórias e opcionais | `setupCatalog` separa essenciais e opcionais |
| P1 | Integração IDE falhava silenciosamente | retorno descartado | falha vira estado degradado e log acionável |
| P2 | Motivos técnicos vazavam no modo simples | justificativa interna renderizada diretamente | explicações pedagógicas por política; detalhe bruto só no modo avançado |

## Recursos implementados

### Jornada de proxies

- Preparação verifica instalação, sessão, serviço, porta e chamada de chat.
- Sessão salva inválida volta ao login assistido.
- Mimo não inicia sem credencial.
- Credencial Mimo salva aciona sequência automática: iniciar, verificar, abrir.
- Falha de integração com OpenCode aparece como degradação, não como sucesso.
- Abrir proxy recusa serviço sem readiness.
- Instalar, iniciar, reiniciar, autenticar, salvar Mimo e abrir IDE revalidam a
  procedência; parar serviço continua sempre disponível.
- Seis proxies legados sem revisão ficam bloqueados, não implicitamente confiáveis.
- UI mostra fonte aprovada, instalação íntegra e aviso de ausência de auditoria
  semântica.

### Catálogo e autenticação

- Catálogo IA expõe base essencial: OpenCode, 9Router, ai-memory e MCPs.
- Claude/Bonsai, Hermes, OpenClaw, Ollama e Odysseus aparecem como opcionais,
  cada um com maturidade e próxima ação.
- Hermes mostra instalação, readiness e autenticação sem expor segredo.
- 9Router mostra atividade e acesso ao gateway.
- Odysseus mostra diagnóstico e plano; instalação indisponível enquanto gates
  de procedência e host não forem satisfeitos.
- `pz ai auth status|doctor` agrupa clientes, providers 9Router, proxies e
  workspaces. Nomes, e-mails, IDs de conta e credenciais são descartados antes
  da saída.
- UI resume prontidão por grupo e mostra somente labels públicas, contagens e
  próximos passos.

### Continuidade de operações

- Cada ação iniciada pela Central recebe `operationId` e manifesto privado.
- Ledger registra estado, progresso, término, cancelamento e resultado associado.
- Operação viva deixada por processo encerrado vira `interrupted`, nunca sucesso.
- Retry disponível somente para mutação, sem preview interrompido, e sempre volta
  pela prévia e confirmação central.
- Resultados finais ligados ao ledger não aparecem duplicados no histórico.
- Ledger não registra comando, parâmetros, stdout ou credenciais.

### Workspaces e Homelab

- `pz ai hermes status|doctor` produz estado estruturado e redigido.
- `pz ai workspaces doctor|plan` agrega Hermes, Odysseus, 9Router, Ollama,
  ai-memory, Podman, Tailscale, portas, política e orçamento.
- Hermes e Odysseus exigem autorização explícita para workloads no host.
- Hermes exige distribuição versionada aprovada; URL raw fixa, commit e checksum
  são lidos do manifesto, nunca de variável fornecida pelo operador.
- Odysseus exige commit e tree confiáveis e gate de release antes de mutar.
- Odysseus exige três imagens aprovadas por digest; lock divergente bloqueia
  start/restart. Nenhum pull ocorre para descobrir confiança durante deploy.
- Build Odysseus substitui as duas ocorrências de `python:3.14-slim` por índice
  OCI fixo. Mudança no layout do Dockerfile falha fechado.
- Doctor/plan expõem assinatura, licença, locks, auditoria semântica, superfície
  de shell e achados sem traduzir integridade de hash como segurança semântica.
- Perfil Homelab incompleto falha antes de qualquer aplicação.

### Roteamento

- Política global única: equilibrado, qualidade, economia ou privacidade.
- Três recomendações atualizadas juntas.
- Aplicação única, bloqueada até todas as recomendações estarem válidas.
- Preview e aplicação carregam a mesma política.
- Cotas e motivos usam linguagem de usuário.

## Lacunas restantes

| Prioridade | Lacuna | Risco/impacto | Próxima implementação |
|---|---|---|---|
| P0 | Odysseus tem commit candidato assinado, mas não release aprovada | deploy permanece corretamente bloqueado | fixar dependências Python, revisar superfícies de shell e concluir auditoria semântica antes de criar allowlist |
| P1 | Snapshots dos proxies não possuem SBOM nem auditoria semântica | dependências/código podem conter risco mesmo com hash íntegro | gerar SBOM, revisar diff por atualização e registrar rollback antes de mudar pins |
| P1 | Imagens Odysseus têm digest íntegro, sem SBOM/assinatura verificada | digest não prova conteúdo seguro nem autoria | anexar SBOM, assinatura/cosign e política de atualização/rollback |
| P1 | Hermes instalado por aceite explícito ainda tem cadeia transitiva incompleta, fallback do lock upstream e release sem assinatura | atualização automática ou reprodução perfeita não podem ser alegadas | fixar downloads/lockfiles transitivos; concluir revisão semântica ou usar pacote hermético assinado |
| P1 | Registro central ainda não conhece expiração/revogação de todos os upstreams | vários providers não oferecem metadado uniforme | adapters por provider; preencher expiração somente quando comprovada; botão de revogação no sistema oficial |
| P1 | Login Mimo depende de segredo copiado do DevTools | jornada frágil e técnica | preferir fluxo oficial OAuth/device-code; fallback guiado com secret store |
| P1 | “Preparar todos” pode abrir várias janelas de login | carga cognitiva e retomada ruim | wizard serial persistente com progresso, pausa e retomada |
| P1 | “Nova Router” não existe no código ou catálogo | nome/integração ambíguos | decidir se significa 9Router, OmniRoute ou novo adaptador; não criar integração por suposição |
| P2 | `pz ai status` leva cerca de 4,6 s neste host | melhorou 31%, mas ainda não é instantâneo | status rápido por domínio e atualização incremental dos cartões |
| P2 | Ledger permite retry, não checkpoint interno de scripts arbitrários | operações monolíticas recomeçam do início após interrupção | adotar etapas idempotentes/checkpoints nos instaladores IA longos |
| P2 | 9Router não oferece wizard nativo completo para providers | autenticação ainda salta ao dashboard web | catálogo de providers, teste de credencial e rota padrão na UI |

## Arquitetura recomendada

1. `AuthRegistry`: inventário redigido, sem armazenar segredo na UI.
2. `JourneyOrchestrator`: máquina de estados para instalar, autenticar, iniciar,
   verificar, integrar e abrir.
3. `OperationLedger`: persistência de progresso e retomada após fechar a UI.
4. `ProvenanceManifest`: URL, licença, commit, tree, imagem por digest e rollback.
5. `ReadinessContract`: contrato único `installed/configured/ready/blockers/next`.
6. `ProviderBroker`: 9Router como ponto de integração; Hermes/Odysseus consomem
   referência canônica, sem cópia de chave.

Fluxo alvo:

```text
Catálogo -> diagnóstico -> plano/diff -> consentimento -> instalação
         -> autenticação -> readiness -> integração -> abertura
         -> monitoramento -> reparo/retomada
```

Cada transição precisa retornar estado terminal, bloqueador, ação seguinte e log
redigido. Falha parcial não pode ser traduzida como “pronto”.

## Evidências

- Pytest completo: `640 passed, 9 subtests passed`.
- Testes de proxies, workspaces, Homelab, IA e UI nativa: verdes.
- ShellCheck, `bash -n` e `git diff --check`: verdes.
- QA offscreen em 1280×800 e 1280×1080: IA & Dev, Proxies IA,
  autenticação central e Roteamento IA aprovados.
- Na auditoria AI-UX-001–005, nenhum workload, container, pacote, serviço ou
  perfil foi aplicado no host.
- Hermes `v2026.8.19`: quatro hashes raw no commit conferem com manifesto; commit
  e tag não assinados; instalador suporta `--commit`, mas resolve artefatos externos.
- Na continuação autorizada AI-UX-006: Hermes `v0.20.5`, commit
  `fcbd1076a93841fa88855acce810e342a5b78101`, árvore
  `cc9f987a403a1d02b8b17cc527a57b54402e864b`; gateway user ativo/habilitado,
  linger ativo e launcher fixado por drop-in resistente à autorregeneração da
  unit upstream; configuração/estado/ambiente em modo `0600`; somente a chave
  cliente canônica do 9Router entra no processo.
- Provas funcionais AI-UX-006: chat real retornou `HERMES_OK`; Playwright abriu e
  fechou Chromium headless; doctor live validou Browser e MCP ai-memory; auditoria
  OSV examinou 107 componentes e retornou zero achados.
- Odysseus `b4d1293`: commit assinado, árvore e cinco hashes registrados. `npm
  audit --package-lock-only --omit=dev` retornou zero vulnerabilidades no lock
  mínimo; `requirements.txt` não fixa a maior parte do grafo Python.
- Registry v2: digest de `python:3.14-slim` no header igual ao SHA-256 do índice
  OCI (`sha256:ce4076…df5a4`), sem pull de imagem.

## Limites desta sessão

- Sem commit, push, PR ou release do PhaseZero. A instalação Hermes no host foi
  executada somente na continuação AI-UX-006, após autorização explícita.
- Manifesto dos quatro proxies registra snapshots observados e verificáveis;
  declara explicitamente `semanticAudit: false`.
- Manifesto das três imagens Odysseus registra digests observados no Registry v2;
  também declara `semanticAudit: false` e não autoriza o commit Odysseus ausente.
- Manifestos de auditoria Hermes/Odysseus são candidatos explícitos, ambos com
  aprovação falsa. Integridade foi comprovada; segurança semântica não.
- Hermes foi liberado por recibo local de risco preso ao commit exato. O
  `uv sync --locked` upstream falhou e o instalador oficial usou seu fallback
  destravado. Doctor mantém 4 advisories high no workspace web e 3 no ui-tui;
  são ferramentas de build, não runtime, e não foram alteradas fora do snapshot.
- “Nova Router” não foi mapeado sem decisão explícita de produto.
