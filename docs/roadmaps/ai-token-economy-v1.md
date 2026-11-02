# Eficiência dos agentes: proposta, contrato e implementação v1

Owner: domínio existente `ai`, catálogo/runner/UI nativos. Continuidade na única
raiz registrada, mesma branch `codex/clean-host-dev-bootstrap`, PR #129.
Base: `faec0240`. Regras atuais de raiz única substituem referências históricas
a worktrees em roadmaps antigos. Não há instalação paralela de produto.

## Propósito e decisões

Reduzir contexto desnecessário sem reduzir qualidade, quebrar continuidade ou
trocar conta/modelo/permissões. ai-memory permanece responsável por memória
compartilhada em todos os perfis. Economia é tática por agente e projeto.
"Padrão" significa preservar práticas essenciais existentes, incluindo RTK
para comandos suportados e leitura direcionada. Não significa remover regras
Caveman ou outras preferências escritas pelo operador.

"Econômico" acrescenta instruções para busca por símbolos/arquivos alterados,
leituras menores, saída concisa e handoffs compactos. Pode ampliar contexto
quando faltar evidência. Nenhum perfil reduz testes, reasoning ou modelo,
esconde falhas, desliga MCPs em massa ou remove dados da memória.

O ganho comprovado do RTK é redução de saídas em comandos observados. Não há
prova local de redução da fatura ou equivalência de qualidade de sessões IA
inteiras. O produto não converte publicidade upstream em garantia de economia.
`rtk proxy` não filtra saída. Não empilhar wrappers nem usar truncamento para
validar contratos JSON, patches exatos ou gates de segurança.

## Requisitos e aceite

| ID | Entrega | Aceite |
|---|---|---|
| ECO-001 | Perfil `basic` padrão, `economy` opcional por agente/projeto | Alterar um cliente não altera perfil de outro nem projeto homônimo |
| ECO-002 | ai-memory permanece vinculada | Instrução em ambos os perfis, serviço e wiring observados separadamente; indisponível aparece degradado |
| ECO-003 | Regras nativas aditivas e reversíveis | Conteúdo externo/BOM/CRLF preservado; bloco alterado externamente impede sobrescrita; rollback se registro falhar |
| ECO-004 | Uma autoridade por CLI/UI/plataforma | `linux/ai/token_economy.py`; Windows delega ao mesmo Python |
| ECO-005 | Controles elegantes e estados honestos | Perfil, pasta, agente, aplicar, padrão, medição, importação e revisão; bloqueio em busy/unknown/drift |
| ECO-006 | Medição sem inferência paga | Três comandos Git fixos, raw vs RTK, bytes e tokens estimados; negativos/zero preservados |
| ECO-007 | Comparação A/B de uso | Metadados estritos, runtime/modelo/revisão/tarefa iguais, aceite/retries/latência/cache visíveis; nada de promoção automática |
| ECO-008 | Revisão de componentes | Fonte, decisão e data em manifesto único; revisão vence em 30 dias; observação de versão não certifica execução |
| ECO-009 | Headroom experimental | Nova instalação fixada; versões existentes preservadas; não entra no setup base nem perfil Windows ai; wrappers sem contrato não ficam ativos |
| ECO-010 | Escopo de skills/MCPs | Design separado de economia; catálogo MCP opt-in preservado; nenhuma remoção de configuração alheia |

## Responsabilidades e fontes de verdade

- `assets/agent-skills/token-economy.json`: agentes, arquivos nativos, perfis,
  versão Headroom testada e revisão de componentes. Assets já fazem parte das
  receitas de pacote; não há cópia concorrente de pins em adapters.
- `linux/ai/token_economy.py`: resolução do projeto, plano/aplicação, registro,
  medição e importação/pareamento A/B. Não inicia agente, proxy ou serviço.
- `linux/ai/memory_manager.py`: instalação, reparo, saúde e portabilidade da
  memória; manifesto nativo `memory-integrations.json` informa wiring.
- `setup-agent-compat.sh`: instalação das ferramentas e compatibilidade legada.
  Binário presente agora é `installed`; não prova `configured` nem uso real.
- Catálogo/runner Qt e WPF: apresentação, seleção e confirmação. Nenhuma escrita
  de regras ou validação de schema fica na UI.
- `pz_hostbackup`: backup central e ledger existentes, fora do projeto.

Estado privado: `$XDG_STATE_HOME/phasezero/ai/token-economy`, ou equivalente sob
HOME. `profiles.json` guarda perfil e hash por caminho de projeto e cliente;
não contém credenciais. `usage/<project-id>` guarda apenas metadados de uso.
Objetos novos usam permissões privadas. Não sincronizar perfis por cópia de HOME:
identidade/path de um host não identifica automaticamente projeto em outro.

## Agentes e instruções nativas

Mapa declarativo cobre Codex, Claude Code, OpenCode, Gemini CLI, Cursor,
Windsurf, Copilot, Cline, Kimi Code, Grok Build, ZCode, Hermes e DeepSeek Harness.
Usa AGENTS.md, CLAUDE.md, GEMINI.md ou arquivo de regras específico do cliente.
Arquivos compartilhados recebem blocos delimitados por cliente, com instrução
explícita para os demais manterem seu perfil. Cursor/Windsurf recebem frontmatter
nativo somente quando o arquivo dedicado ainda não existe.

Aplicação prepara instruções consumíveis pelo cliente. Não comprova que uma
sessão já aberta releu essas instruções. A UI informa abrir nova sessão e mantém
`sessionUse=unverified`. Cliente/modelo que ignore instruções requer avaliação
própria; isto não é enforcement de rede, permissões nem comportamento do LLM.

Projeto pode ser passado explicitamente; leitura também resolve raiz Git atual
ou última seleção persistida. Caminhos symlink e HOME/raiz do filesystem são
recusados. UI mostra pasta e vincula plano/aplicação à mesma seleção. Não usar
diretório do runtime instalado como projeto por inferência.

Registro e arquivo são atualizados sob lock de worker. Escrita é atômica com
fsync; arquivo anterior vai para backup central. Erro ao gravar registro restaura
arquivo anterior. Alteração externa dentro do bloco ou bloco não registrado de
conteúdo desconhecido falha com orientação de revisão. Outro host pode adotar
bloco idêntico ao renderer canônico atual, após aplicação explícita; conteúdo
fora do bloco permanece intacto.
`reset` reaplica `basic` somente ao cliente selecionado; não apaga preferências.

## Memória permanente com contexto seletivo

Vínculo é obrigatório como política dos dois perfis. Estado conectado exige
serviço acessível e receipt de MCP daquele cliente; hooks aparecem separadamente.
Serviço/wiring presentes não provam captura/recall de uma sessão específica.
Ausência de contrato de hooks é parcial, não sucesso inventado.

Consulta deve recuperar poucos resultados relevantes, expandindo páginas quando
necessário; não despejar o banco/histórico em cada prompt. Lifecycle captura
rotina. Aprendizados duráveis ficam em páginas semânticas com origem/tempo.
Se MCP resolver outro projeto, usar CLI nativa a partir da pasta atual e reportar
divergência. Reparar memória usa jornada existente; perfil não cria outro store.

Headroom `--memory` não é ai-memory. Não o ativar como consequência de escolher
perfil econômico. Mesmo cuidado vale para memória opcional de Serena.

## Revisão crítica dos componentes

| Componente | Direção |
|---|---|
| ai-memory | Continuidade; permanece em ambos os perfis. Portabilidade tem roadmap próprio |
| RTK | Base para compressão de saídas compatíveis; medir e preservar escape para raw |
| Skills e discovery nativos | Preferir carregamento sob demanda e descrições de escopo claras |
| Headroom | Experimental; versão instalada observada; nova instalação fixa 0.32.1; sem downgrade silencioso |
| Caveman | Estilo opcional em evolução; preferências existentes preservadas, sem impor novo estilo ao trocar perfil |
| Serena | Candidato para navegação semântica em bases grandes; não instalado automaticamente |
| Ponytail | Apenas arquitetura de workspace detectado; não economia global |
| Graphify | Placeholder, sem integração/ganho declarado |

Helper Gemini falhava porque wrapper não existe na versão testada: agora
retorna unsupported. Wrappers gerenciados Claude/Codex/OpenCode permanecem
bloqueados enquanto rota, autenticação e memória não forem homologadas. Não
contornar gates de grant por requisição já existentes. Regras do perfil não
liberam inferência. Proxy/MCP manuais legados não são promovidos a suporte.

Skill de design `huashu-design` deixa de ser instalada junto com Caveman no
catálogo Windows. Instalações existentes não são removidas. MCPs opcionais
Context7/Firecrawl/Apify/Sentry mantêm seleção explícita. Atualização automática
de todos os terceiros não faz parte deste contrato.

`review` observa versões locais e catálogo gerenciado, sem instalar ou conectar
serviços externos. Mudança upstream exige revisão humana do adaptador, testes e
nova data no manifesto. Data vencida aparece na UI; não cria tarefa periódica.

## Interface

Jornada em IA & Dev, no estilo/cartão/runner existentes. Atalhos "Memória e
eficiência" nos agentes e fichas de produto convergem à mesma jornada.
Selecionar agente não executa nada; selecionar perfil também não aplica mudança.
Pasta explícita, aplicar com plano, restaurar padrão, atualizar, medir saída
local, importar A/B e revisar componentes. Busy bloqueia mudanças e seleção;
status ausente ou pasta alterada invalida prontidão. Drift exige revisão.

Não mostrar porcentagem estimada como dinheiro poupado. A UI diferencia
redução de bytes/tokens estimados, custo API desconhecido, receipt de memória e
uso em sessão não verificado. WPF usa worker assíncrono e diálogo nativo de pasta.
Não há token/senha no formulário de economia. Login/memória usam fluxos próprios.

## Operação e dados A/B

```bash
pz ai token-economy status --project <pasta> --json
pz ai token-economy plan --project <pasta> --agent codex --profile economy
pz ai token-economy apply --project <pasta> --agent codex --profile economy
pz ai token-economy reset --project <pasta> --agent codex
pz ai token-economy measure --project <pasta> --agent codex
pz ai token-economy review --project <pasta>
pz ai token-economy record --project <pasta> --path <metadados.json>
```

`measure`: `git status`, `git log -5`, `git diff --stat`, comparados com RTK.
Saídas ficam somente em memória durante medição; persistem totais, comando fixo,
revisão, perfil e horário. Nenhuma sessão/conta/provedor é chamada. Estimativa
tokens = ceil(bytes/4). Resultado negativo é válido; qualidade não é avaliada.
Não atribuir esse experimento a uma sessão real do agente selecionado.

Schema de uma observação A/B, com valores fictícios:

```json
{"agent":"codex","profile":"basic","taskId":"case-1","acceptanceId":"suite-v1","model":"same-model",
 "runtimeVersion":"same-runtime","revision":"same-revision",
 "inputTokens":100,"outputTokens":50,"cachedInputTokens":10,
 "latencyMs":1000,"retries":0,"passed":true,"source":"provider-export"}
```

Aceita somente essas chaves; números inteiros não negativos, cache ≤ entrada,
`passed` booleano, identificadores simples e origem `provider-export`/`manual`.
Não importar prompts, respostas, logs, tokens de autenticação ou campos extras.
`outputTokens` inclui reasoning quando assim reportado pelo provedor: não somar
reasoning novamente. Modelo deve incluir variante/revisão necessária ao experimento.

Pareamento exige mesmo agente, taskId, acceptanceId, modelo, runtimeVersion e revisão.
Só compara quando há exatamente um registro por perfil; tentativas ambíguas não
escolhem o melhor resultado. Cache, latência, falha de aceite e regressão de
retries permanecem visíveis. Exportação importada é `reported-not-attested`;
não é autenticada pelo PhaseZero. Fatura depende de tarifas/cache e não é inferida.
Não há promoção automática de perfil por uma amostra. Homologação de ganho total
exige tarefas representativas repetidas, mesmo aceite e inspeção das falhas.

## Validação e limites

Testes: preservação de conteúdo e outros perfis, idempotência, locks, rollback,
drift, symlinks, leitura sem escrita, estimativa negativa, schema e pares A/B.
CLI/Qt/WPF delegam ao mesmo owner. Gates de pacote, inventário, Bash/ShellCheck,
parser/analyzer PowerShell e testes afetados continuam obrigatórios.

Prova visual: dark/light, 800×600/1280×800, escalas 100/150/200%, teclado e
ponteiro. Mock/Xvfb não homologam Windows/WPF, leitor de tela, toque ou interpretação
dos prompts por cada modelo. Nenhuma inferência paga implícita para produzir ganho.
Handoff deve registrar SHA, resultados observados, implantação, limites e CI.

Fontes oficiais consultadas em 2026-11-02:
[RTK](https://github.com/rtk-ai/rtk),
[Headroom](https://github.com/headroomlabs-ai/headroom),
[Skills Codex](https://learn.chatgpt.com/docs/build-skills),
[MCP Claude](https://code.claude.com/docs/en/mcp),
[OpenCode](https://opencode.ai/docs/mcp-servers/),
[Serena](https://github.com/oraios/serena).


## Evidência inicial no host

BigLinux/Manjaro, mesma raiz canônica. RTK 0.43.0, Headroom 0.32.1 e
ai-memory 3.3.1 observados. Padrão aplicado explicitamente a Codex, Claude Code
e OpenCode; arquivo/registro confirmam configuração, serviço e receipt de MCP/
hooks presentes. Nenhuma sessão LLM foi executada para simular homologação.

Medição local em 2026-11-02T01:36:59Z, HEAD anterior `faec0240` com alterações
locais identificadas por fingerprint: 4.325 → 2.978 bytes, redução de 31,14%.
Estimativa bytes/4: 1.082 → 745 tokens. `git status`: 1.535 → 1.000 bytes;
`git log -5`: 1.452 → 641; `git diff --stat`: 1.338 → 1.337. Isso mede apenas
esses comandos nesse estado, não fatura, sessão inteira ou qualidade equivalente.

Rodada ampla: 150 pytest passaram. Refinamentos finais: 46 testes focados,
com sobreposição. Suites Bash IA/compatibilidade/grants, ShellCheck, parser/
analyzer PowerShell e dois contratos Pester 6 passaram. Installed-root smoke
passou, incluindo importação de catálogo/UI e checksum do runtime. Matriz Xvfb
com HOME isolado e backend xcb: claro/escuro, 800×600/1280×800, 100/150/200%,
12 combinações com teclado/ponteiro, sem overflow. Ensaios que herdaram Wayland
foram descartados; não sustentam evidência de dimensões/escalas.

Validação física Windows/WPF, interpretação dos perfis pelos modelos e economia
de custo API continuam abertas. Não há promoção automática de Headroom/Serena.
A namespace `ai token-economy` agora possui operações próprias; setup legado
continua em `ai compat`, sem duplicar implementação de memória ou roteamento.
Evidências privadas e regeneráveis: cache `phasezero-dev/token-economy`.
Handoff existente registra SHA instalado, publicação e limites finais.
