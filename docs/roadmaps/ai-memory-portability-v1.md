# ai-memory: portabilidade, recuperação e interface

Owner: adaptadores IA, catálogo e UI existentes. Contrato de criptografia:
[ADR 0002](../adr/0002-ai-portability-backup.md). Pins únicos:
`packaging/ai-memory/pins.json`. Baseline de implementação: `69a471cd`;
branch de continuidade `codex/clean-host-dev-bootstrap`, PR #129.

## Escopo e contratos

- MEM-001: remover espelhamento destrutivo Windows. Não copiar SQLite ativo,
  escolher unidade por letra/pasta ou exportar antes de preservar exclusivos.
- MEM-002: instalação nativa verificada 3.3.1, snapshot anterior à migração,
  recuperação após falha e companion oficial compilado de fonte fixada.
- MEM-003: snapshots OpenPGP por host, inventário/hash, extração sem links ou
  traversal, pré-backup e ciclo coordenado do serviço na restauração.
- MEM-004: conhecimento por projeto via `ai-memory-wikisync`, baselines locais
  por peer e escritas condicionais. Exclusões não propagam. Conflitos mantêm
  versão recebida criptografada; resolução seleciona um conflito por vez.
- MEM-005: dispositivos cadastrados por volume/manifesto e publicações
  imutáveis. Detector observa conexão a cada 10 segundos; timer recupera
  tentativas perdidas. Caminho manual usa exatamente o mesmo worker.
- MEM-006: GitHub privado, identidade revalidada, conhecimento pequeno em Git
  e snapshots completos em assets de releases do repositório dedicado.
- MEM-007: opções nativas para instalar, reparar, cadastrar projetos/destinos,
  autenticar GitHub, sincronizar, automatizar, recuperar chave e restaurar.

Não é replicação multiwriter de SQLite. Conhecimento pode circular entre
hosts; snapshots completos preservam histórico por host. Para consultar todo
histórico numa única instância, escolher servidor autoritativo ai-memory em
frente própria, sem inventar fusão de backups. Backup nativo contém estado
interno do ai-memory, inclusive possíveis dados de autenticação do próprio
servidor. Arquivos de credenciais de provedores/navegador ficam fora da
automação. Todo conteúdo remoto sai criptografado.

## Operação

```bash
pz ai memory install
pz ai memory status --json
pz ai memory scope-add --workspace default --project <nome-existente> \
  --repo-path <checkout> --families concepts,decisions,gotchas,notes
# Host novo: --create-project cria escopo por API, com registro de inscrição.
pz ai memory github --repository <usuario/repositorio-privado>
# Novo destino dedicado: acrescente --create. Nunca usar repositório de código.
pz ai memory device-add --path <raiz-do-volume-montado>
pz ai memory sync
pz ai memory settings --interval 15 --backup-hours 24 --keep 7
pz ai memory automatic --enabled yes
```

Automação exige runtime instalado; não aponta serviço de produção ao checkout.
No Linux, instalação de usuário usa `packaging/linux/install-user.sh`, incluindo
CLI `pz`, UI e pins. Timer/worker são units de usuário; não instalam serviço de
sistema, Docker, gateway ou banco novo. Pausar usa `automatic --enabled no`.
Windows usa o mesmo owner Python e tasks de usuário; bootstrap legado delega
à mesma entrada. Diretório de instalação Windows customizado exige migração
explícita; não é adotado silenciosamente.

Projetos devem ser selecionados na memória existente; nomes de pasta não
identificam projeto. Vínculo compartilhado deriva do remoto Git normalizado.
Somente GitHub tem equivalência conhecida entre SSH/HTTPS e capitalização;
outros servidores preservam protocolo e case do caminho. Sem remoto, gera-se
ID próprio: copie o `scopeId` retornado e informe `--identity <scopeId>` no outro
host. Campo equivalente existe na UI. Nunca inferir equivalência por basename.
Snapshot completo inclui metadados dos vínculos, sem referências de cofre;
restauração guarda esses dados na pasta de recuperação para revisão e novo
cadastro. Não copiar automaticamente caminhos locais ou identidade do host antigo.
Novo host importa chave, cadastra checkout/projeto e conecta mesmo destino.
Login GitHub reutiliza `gh`; não concede chave de descriptografia nem escolhe
automaticamente todos os projetos.

Chave automática aleatória fica somente no Secret Service/WinCred existente.
Na UI, **Guardar recuperação** gera arquivo OpenPGP protegido por senha que
entra por stdin. Guardar arquivo e senha independentemente do host; senha
nunca deve ser enviada no chat. **Importar recuperação** precede cadastro de
destinos/projetos no novo host e não copia UUID do host anterior.

```bash
pz ai memory verify --path <snapshot.gpg>
pz ai memory restore-plan --path <snapshot.gpg>
pz ai memory restore --path <snapshot.gpg> --confirm RESTORE \
  --expected-sha256 <hash-retornado-pelo-plano>
```

Restauração preserva configuração local; configuração externa do backup fica
no diretório de recuperação para revisão. Histórico bruto complementar recebe
troca coordenada e cópia anterior identificada. Não há restauração automática
quando uma mídia é conectada. Conteúdo/origem/datas do registro permanecem na
página original; manifesto registra transporte e sidecar preserva origem de
versões compartilhadas. `firstObservedAt` não inventa data histórica ausente.

Limites iniciais: pacote de conhecimento até 8 MiB; arquivo GitHub de snapshot
até 2 GB pelo orçamento do adaptador. Cadastro, verificação e falta de espaço
falham sem substituir último objeto válido. Retenção remove apenas snapshots
do próprio host após substituto verificado. Git guarda histórico de blobs;
reduzir retenção de snapshots não apaga histórico Git.
Falhas de rede/autenticação GitHub usam retentativa crescente com jitter,
limitada a seis horas. Sincronização manual ignora espera. Backups continuam
independentes de conflitos de conhecimento. Arquivos de conhecimento sem mudança
não geram novos objetos nem expulsam versões úteis na mídia.

## Práticas aprovadas entre hosts

Cada host consulta a cópia local de `default/phasezero-development-practices`,
no caminho `_rules/development-practices.md`. O catálogo usa o mesmo domínio de
criptografia e os mesmos destinos da sincronização. A chave de assinatura do
curador é independente da chave de recuperação. O curador assina o Markdown
com sua chave OpenPGP privada. Cada host confia explicitamente na impressão
digital completa da chave pública primária. Verifique essa impressão fora do
destino usado para transportar a memória.

**Preparação em cada máquina.** Use runtime PhaseZero com suporte ao catálogo.
Instale ou repare o ai-memory pelo fluxo existente. No host novo, importe a
chave de recuperação antes de vincular destinos e escopos. Conecte o mesmo
repositório GitHub privado ou cadastre a mesma mídia. Cadastre o projeto comum
separadamente, para que possa enviar e receber aprendizados. Importe só a chave
pública do curador nos hosts leitores.

```bash
gpg --import curador-publico.asc
pz ai memory practices-configure --fingerprint <impressao-digital-primaria>
# Apenas no host do curador, após revisão do Markdown:
pz ai memory practices-publish --revision 1 --path <catalogo-revisado.md>
# Em cada host:
pz ai memory sync
pz ai memory practices
```

O catálogo começa com um título Markdown e declara o escopo de cada prática.
`practices` retorna `practices-verified`, revisão e corpo verificado. Funciona
com o ai-memory local ativo mesmo sem o destino conectado. Práticas são
padrões subordinados ao pedido atual e às regras do repositório. A regra de
consulta vai no bloco gerenciado de `pz ai init`. Agentes que só usam MCP
podem recuperar contexto histórico normalmente, mas precisam de um ponto de
entrada que execute a verificação para consumir o catálogo aprovado.

Para corrigir ou revogar uma prática, publique o catálogo completo com revisão
maior. A última revisão aceita fica registrada localmente. Depois que o host
aceita uma atualização, cópias anteriores não fazem a prática revogada voltar.
Quem estiver offline continua com a revisão já recebida. Erro de verificação
é explícito e remete às regras do repositório. Notas, handoffs e outras
páginas não entram no catálogo. A rejeição de um catálogo não impede a troca
de aprendizados nem o backup completo. Proteja a chave privada do curador e guarde o
material de recuperação separadamente da mídia.

### Prova reproduzível

Com ai-memory e ai-memory-wikisync já instalados, rode do checkout oficial.

```bash
proof_tmp="${XDG_CACHE_HOME:-$HOME/.cache}/phasezero-dev/memory-proof"
mkdir -p "$proof_tmp/tmp" "$proof_tmp/pytest"
export TMPDIR="$proof_tmp/tmp"
export PYTEST_DEBUG_TEMPROOT="$proof_tmp/pytest"
export PZ_MEMORY_TEST_NATIVE="$(command -v ai-memory)"
export PZ_MEMORY_TEST_WIKISYNC="$(command -v ai-memory-wikisync)"
python3 -m pytest -q tests/test_memory_native_integration.py -k approved_practices
```

O ensaio usa dois serviços nativos em loopback, chaves e dados sintéticos, e
um diretório temporário como volume compartilhado por padrão. O cofre é uma
fixture. Exercita captura por hooks com entradas sintéticas,
cadastro, exportação e importação de chave, troca criptografada, consulta
offline, aprendizado de volta, atualização e rejeição de adulteração e revisão
antiga.

Para testar armazenamento físico, aponte `PZ_MEMORY_TEST_DEVICE` para o ponto
de montagem de um volume de dados gravável e execute o mesmo pytest. O
ensaio exige um volume separado e recusa qualquer diretório `PhaseZero`
existente na raiz. Ele usa a descoberta real por UUID e limpa o namespace
temporário após conferir a identidade do domínio de teste. As instâncias
ainda rodam na mesma máquina. Mantenha a mídia conectada durante o ensaio.

Para testar o **GitHub real**, execute a mesma prova com
`PZ_MEMORY_TEST_GITHUB=OWNER/phasezero-memory-proof-IDENTIFICADOR` e a
autenticação `gh` já ativa. Aponte `GH_CONFIG_DIR` para a configuração
existente do GitHub CLI antes de iniciar os ambientes isolados. Use um nome
novo e escolha um transporte por execução. A prova cria um repositório
privado dedicado com dados sintéticos. Publica duas revisões, recebe o
aprendizado de volta, verifica a rejeição da assinatura inválida e volta a
publicar o catálogo válido. Também baixa o snapshot de A, confere o SHA-256
e restaura o SQLite em um ambiente descartável.

Para continuar o mesmo ensaio em outro computador, use uma instalação
limpa ou isolada. Transfira `curator-public.asc`, `recovery.gpg` e
`github-proof.json` gerados no diretório temporário do caso. Importe a
recuperação sintética antes de cadastrar o repositório e a impressão
digital indicada no recibo. Cadastre o escopo `default/shared` com
`_rules,notes` e a identidade fixa do ensaio, 64 caracteres `b`.
Após sincronizar, o agente deve informar a revisão 2, aplicar a prática
e registrar uma nota própria nesse escopo. O recibo e o arquivo de
recuperação pertencem ao ensaio. A senha sintética está definida em
`recover` no teste de integração.

**Aceite em duas máquinas físicas.** Em A, publique uma prática de ensaio e
sincronize pelo destino escolhido. Em B, instale a mesma versão, cadastre a
chave pública e sincronize. Em uma sessão no projeto, peça ao agente para
informar a revisão, aplicar a prática numa tarefa de teste e registrar um
aprendizado identificado. Confira a captura com `ai-memory doctor` e o
aprendizado em A após sincronizar B e A. Publique uma revisão em A que
substitua a prática e confira sua aplicação em B. Repita a leitura em B com
o destino desconectado e registre versão, agente, destino e revisões
observadas. Para clientes com integração parcial, declare qual parte ficou
pendente. Use o destino privado já autorizado ou uma mídia de ensaio.

## Evidência em 2026-11-01

Host: BigLinux/Manjaro, `misael-jupiter`. Instalação real 1.31.1 → 3.3.1,
serviço ativo em loopback com API e MCP/hooks dos agentes detectados aplicados.
Release Linux de 22.535.953 bytes e fonte do companion verificadas pelos pins.
Snapshot anterior à migração preservado em estado privado do usuário; instalação
também mantém rollback próprio, fora do Git.

Rehearsal em cópia isolada: 3.478 páginas, 1.835 sessões, 842.919 observações e
177 handoffs. Contagens e todos os campos originais compartilhados entre
schemas permaneceram idênticos, por comparação de hashes linha a linha. Store
real continua recebendo eventos; contagem posterior naturalmente difere.

Teste nativo opt-in: duas instâncias descartáveis com binário/companion reais,
troca nos dois sentidos, origem/data preservadas, edição concorrente recusada,
snapshot online criptografado e restauração nativa com SQLite íntegro. Restore
usa namespace PID próprio; nenhum serviço de produção é parado pelo teste.

GitHub real: repositório dedicado privado validado; 133 arquivos de conhecimento
retornaram pela API e passaram descriptografia/inventário/hash. Snapshot completo
foi enviado; tamanho e digest confirmados pelo GitHub. Cópia completa remota não
foi baixada para este teste: excede limite local de download manual de 70 MB.
Recuperação de snapshot completo foi provada com fixture nativa local; não
confundir isso com recuperação integral daquele asset remoto.

Fixtures Python cobrem chave fora de config, senha errada, archive traversal/
links, exclusividade de worker, disco/dispositivo, identidade/privacidade GitHub,
conflitos, preservação de backup apesar de conflito de conhecimento, origem de
projeto e rollback de migração/restauração. Probes Qt usam Xvfb, temas claro/
escuro, 800×600/1280×800 e escalas 100/150/200%; teclado e ponteiro são medidos.
Fixtures e capturas não homologam toque físico, leitor de tela ou Windows.

## Gates e continuidade

Handoff final deve registrar commit, testes/checks e instalação do runtime/
agendamento realmente observados. Não publicar dados, chaves, dumps ou URL de
backup privado no Git do produto. Evidências locais ficam em diretório privado
de cache `phasezero-dev/ai-memory-implementation`, com snapshots de rollback no
estado privado `phasezero/ai-portability` e `phasezero/ai/memory-upgrades`.

Pendentes de alvo: Windows nativo/WPF e tasks, dois equipamentos físicos,
remoção abrupta de USB/SD, recuperação após perda real do cofre, acessibilidade
física. Chave de recuperação exige exportação local pelo operador. Sem merge,
release de produto, inferência paga ou homologação genérica de todos os hosts.


## Fechamento no host

Implementação: `37448e62556b3257776f7c7450b0c5f7c25718c9`. Runtime de usuário
instalado do arquivo imutável desse commit pelo instalador oficial, após ensaio
em HOME isolado. CLI/UI/desktop entry/pins presentes; launcher oficial renderizou
no desktop. Probe da ficha instalada, sem respostas simuladas, exibiu memória
ativa, automação ligada, GitHub em dia e botão Sincronizar habilitado. Timer e watcher habilitados e ativos; units usam caminho estável
`~/.local/share/phasezero/current`. Execução real do worker terminou com status 0,
`Result=success`; GitHub em dia, sem duplicar backup completo ainda dentro de 24 h.

Checks locais: rodada ampla 156 pytest; rodada final 75 pytest, com sobreposição.
Installed-root smoke, três suites Bash afetadas, ShellCheck, parser/analyzer
PowerShell e três contratos Pester passaram. Matriz Qt: 24 combinações de tema,
escala, dimensão e modo avançado, com teclado/ponteiro e sem overflow. Suite
legada ai-tools limitada por Pester Linux; não declarada aprovada. PR #129 recebe
incremento sem merge/release; checks remotos devem corresponder ao SHA final.

Automação está operacional com chave no cofre; recuperação após perda do cofre
permanece dependente da exportação pelo operador. Nenhuma mídia física cadastrada
neste host. Backups/dados/chaves/URL do destino privado não foram publicados no
repositório de código. Trabalho alheio mantido fora dos commits.
