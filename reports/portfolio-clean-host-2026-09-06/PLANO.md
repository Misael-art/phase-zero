# Plano executável — PhaseZero em host limpo

Base: auditoria de 2026-09-06, `2180c94`. Este plano complementa os roadmaps Homelab e WBR; não substitui limites operacionais nem marca trabalho anterior como concluído. Itens em [backlog.json](backlog.json) são a fila proposta; cada um contém causa, evidência, dependências e aceite. Não há prazo contratado nem implantação autorizada por este documento.

## Resultado esperado

Um usuário seleciona **o objetivo e o host**, revisa dependências/recursos/custos/acesso e confirma um plano completo. PhaseZero instala o necessário, configura, inicia, aguarda prontidão, pede somente credenciais/decisões inevitáveis e abre a solução funcional. Se falhar, registra causa, preserva dados e oferece retomar/reparar. O administrador não precisa instalar Docker local para operar outro servidor.

Fluxo de produto:

```mermaid
flowchart LR
    A["Escolher objetivo e host"] --> B["Detectar requisitos"]
    B --> C["Revisar plano completo"]
    C --> D["Instalar dependências"]
    D --> E["Configurar e iniciar"]
    E --> F["Validar função real"]
    F --> G["Pronto: abrir solução"]
    D --> H["Pausa recuperável com causa"]
    E --> H
    F --> H
    H --> D
```

## Arquitetura proposta

### Um manifesto de solução, adapters por plataforma

Evoluir `linux/capabilities` e o grafo de componentes Windows; preservar compatibilidade dos comandos públicos. Manifesto comum define:

| Campo | Contrato |
|---|---|
| `id`, versão e migração | Identidade estável da solução e do estado persistido |
| Plataformas/papéis | Arch/Windows; appliance/admin/local; hardware necessário |
| Maturidade | stable/preview/experimental/blocked apoiado em evidência |
| Dependências | DAG transitivo, provider, versão/pin, origem, recursos e reboot |
| Configuração | Schema, valores padrão, decisões do usuário, referências de segredo |
| Lifecycle | install/configure/start/stop/update/remove/repair/backup/restore |
| Probes | installed/configured/active/healthy/authenticated/ready; nunca conflar estados |
| Dados | Volumes/pastas, propriedade, preservação, migração e restore |
| Orçamento | Memória incremental disponível, CPU/GPU/VRAM, disco e download |
| Acesso | Endpoint, bind, TLS, autenticação e host de execução |
| Provas | Caso de uso E2E, matriz suportada e links de CI/artefatos |

Provider resolve pacote/runtime; receita configura solução; reconciliador aplica estado desejado; UI/CLI/web/SSH apenas submetem payloads tipados ao mesmo motor. Não duplicar instalação em handlers da UI. Ferramentas opcionais não viram dependências globais de todas as soluções.

### Operação persistente

`planId`, hash do plano, hostId, operationId, versão do runtime, etapas, resultados, tempo-limite e checkpoint. Cada etapa mutável registra intenção antes do efeito e resultado após verificação. Reexecutar não reinstala dados nem gira segredos. Lock cobre a operação e o recurso, não somente escrita de JSON.

Estados mínimos: `planned`, `installing`, `configuring`, `starting`, `needs-auth`, `needs-restart`, `verifying`, `ready`, `degraded`, `failed`, `cancelled`. `enabled` é desejo; `installed` é presença; `ready` é prova funcional. Erro de `rm`, `up`, build ou restore não pode resultar em completed=true.

### Contrato de host limpo

“Sem dependências” significa sistema operacional instalado, armazenamento/rede utilizáveis e acesso administrativo quando necessário. O bootstrap precisa incluir ou provisionar o próprio runtime antes de depender dele. Contas externas, aceite de termos, decisões de privilégio, reinício e ativos privados continuam decisões do usuário, conduzidas pelo produto.

Arch: não presumir pacotes/repositórios BigLinux/Manjaro, helper AUR, Qt/Node/npm, Docker, grupo docker, daemon ativo ou sessão systemd de usuário persistente. Windows: não presumir winget operacional, PATH atualizado, WSL2, recursos de virtualização, distro pronta, Docker Desktop inicializado ou ausência de reboot pendente.

## Fila por fases e gates

### Fase 0 — Proteger confiança em dados e resultados

Itens: **PZ-AUD-005, 006, 009, 010, 011, 012**.

1. Registrar PZ-AUD-010 como bloqueio de aceitação do restore atual. Qualquer contenção temporária deve ser explícita, sem apresentar a função como segura por teste de checksum.
2. Fixar identidade de projeto/volumes (011); definir desired/observed e propagar falhas (005).
3. Unificar conjunto de apps por operação/boot (012); tornar backup consistente/completo (009).
4. Implementar restore por manifesto com staging e rollback exato (010).
5. Concluir prontidão por conjunto esperado e prova funcional (006).

Gate: fixtures atuais deixam de reproduzir o defeito; testes de regressão passam com comportamento corrigido. Dois projetos permanecem isolados; restore com arquivo extra, stop falho, falha parcial, checksum inválido e destino incompatível não altera dados indevidos. Bancos sob escrita sobrevivem backup→restore com consistência.

### Fase 1 — Bootstrap e motor comum de preparação

Itens: **001, 002, 003, 004, 026, 027**.

Entregar entrypoints públicos no pacote, preparação administrativa inicial, manifesto de dependências por solução, providers Arch/Windows e ordenação de serviços. Migrar o caminho “Preparar Homelab” para instalação efetiva. Tratar pacotes desconhecidos/indisponíveis por solução e bootstrap Flatpak/Flathub quando necessário.

Gate Arch: VM oficial mínima, instalação do asset de release sem checkout, usuário não root, nenhum Node/npm/Docker preexistente. Abrir PhaseZero→preparar Vaultwarden→cofre funcional. Segunda execução idempotente. Sem alterar arquivos de outros usuários/projetos.

Gate Windows: VM limpa, PowerShell 5.1 e variante sem winget pronto; instalar requisitos, retomar após reinício quando exigido, atualizar PATH do processo, aguardar engine e executar app. UI nunca encerra como concluída quando falta reboot ou Docker pronto.

### Fase 2 — Completar aplicações e runtime appliance

Itens: **007, 008, 015, 025, 030, 031**; consome contratos das fases anteriores.

Começar com Paperless, que tem dependência necessária ausente, e um conjunto pequeno de apps de referência. Fechar receitas dos dez apps, governança de recursos, pins efetivos, contas/configuração útil e lifecycle do agente/dashboard. Manter lista stable pequena até gate por app.

Gate: cada app realiza caso de uso da matriz do relatório; reboot sem login gráfico preserva estado escolhido; health→degraded→repair comprovado. Node Exporter observa appliance correto; Grafana mostra dados reais; mídia é read-only por padrão; nenhum container de outra instalação é tocado.

### Fase 3 — Coesão IA e proxies

Itens: **016–024**.

1. Contrato comum de fontes/runtimes/auth/modelos e conjunto supported (016, 018, 019).
2. Build transacional e erro obrigatório por etapa (017).
3. MiMo com API oficial e prova autorizada de inferência (020).
4. Gateway/modelos: Ollama e 9Router com progresso, política, orçamento e erro de autenticação acionável (024).
5. Perfis executáveis ou claramente preview; maturar distribuição Hermes e integração ai-memory (021, 022).
6. Broker de execução com ADR, identidade, política e isolamento real (023). Não chamar política de instalação de sandbox de execução.

Gate: Arch e Windows limpos completam instalação e autenticação guiada de cada integração suportada. Testes de contrato não substituem inferência autenticada supervisionada. Offline, sessão expirada, key inválida, quota/rate limit, modelo indisponível, streaming interrompido, tool call malformada e restart são estados testados. Nenhum segredo em logs/argv/diagnóstico.

### Fase 4 — Jornada amigável entre dois hosts

Itens: **013, 014, 029**.

Escolha inicial de papel; descoberta real ou entrada manual; criação/importação de chave/pareamento protegido; bootstrap remoto; plano vinculado à confirmação; endpoints acessíveis do administrador; primeira conta e confiança TLS guiadas. Usuário vê o que será instalado no host selecionado e consegue retomar após queda de rede.

Gate: admin sem Docker + appliance limpo. Usuário sem terminal pareia inclusive SSH em porta customizada, instala app, abre serviço, reinicia appliance e volta a operar. Troca de host não reutiliza plano/secret/operationId do host anterior. Teste de usabilidade registra erros e passos não assistidos.

### Fase 5 — Certificação contínua e documentação viva

Item **028**, iniciado como infraestrutura de teste desde fase 0; fecha a aceitação do conjunto.

Matriz mínima:

| Dimensão | Casos obrigatórios |
|---|---|
| OS | Arch oficial mínimo; derivada declarada; Windows 11 limpo |
| Canal | Asset instalado; upgrade da última release suportada; CLI; UI; admin remoto |
| Dependências | Ausentes; presentes/paradas; incompatíveis; faltando PATH; provider indisponível |
| Rede | Offline; DNS/TLS inválido; download interrompido; porta ocupada; reconexão |
| Identidade | Usuário comum; elevação negada; primeiro pareamento; duas instalações |
| Recursos | Pouca RAM disponível; disco cheio; GPU ausente; VM concorrente |
| Lifecycle | Segunda execução; cancel; processo morto; reboot; resume; remove preservando dados |
| Dados | Banco sob carga; backup incompleto; archive adicional; restore parcial; rollback exato |
| IA | Sem credencial; expirada; resposta real; streaming; ferramenta negada; memória no workspace correto |

Jobs Docker usam runner/VM descartável, projeto/portas/volumes exclusivos e cleanup por identidade. Não executar suite disposable contra daemon do desenvolvedor. Provas físicas WBR/Deck/GPU permanecem gates próprios; não inferir a partir de mocks.

Gate final: cada solução stable tem linha de evidência com implementação, teste comportamental, CI e limitações. Publicação usa pipeline canônico e asset verificado. Novos números de release seguem versão atual; não reutilizar alvo histórico v1.15.1.

## Como agente assume um item

1. Ler AGENTS/RTK e roadmaps aplicáveis; consultar memória por área. Revalidar base e WIP concorrente.
2. Criar worktree dedicado. Escolher IDs, preencher owner e status `in_progress` no backlog da frente; não alterar arquivos de outra responsabilidade.
3. Reproduzir achado no baseline. Reprodutores desta auditoria confirmam defeitos: não copiar assertions de comportamento quebrado para suíte de produto.
4. Escrever teste que exige comportamento correto; implementar mudança mínima sob contrato compartilhado.
5. Executar gates afetados; revisar segredos, identidade e regressões. Atualizar provas/limitações e gerar handoff.
6. Marcar `verified` somente quando aceite do item estiver provado. Prova unitária pode concluir subetapa, mas não valida automaticamente cenário Windows/Arch físico.

Não criar PRs que apenas alteram rótulo para “pronto” ou desabilitam gates. Nenhum item exige reescrever projeto inteiro. Fundação compartilhada precede migração gradual dos adapters.

## Handoff desta auditoria

```text
Objetivo da sessão: auditar portfólio, bootstrap de host limpo, Homelab, IA/proxies e registrar plano.
Fase/IDs assumidos: diagnóstico de PZ-AUD-001..031; nenhuma correção de runtime assumida.
Branch e worktree: codex/portfolio-clean-host-audit; /mnt/sdcard/Projects/pz-portfolio-clean-host-audit.
HEAD inicial: 2180c94fbfdf67c46050c1bbab9798adf66f3a91.
HEAD final da base auditada: 2180c94fbfdf67c46050c1bbab9798adf66f3a91; eventual commit documental identificado pelo Git.
Arquivos alterados: reports/portfolio-clean-host-2026-09-06/ e seções Estado vivo/Ledger dos dois roadmaps Homelab.
Commits criados: consultar git log da branch de auditoria; sem alteração de código de produto.
Testes executados e resultados: evidence/validation-summary.json; pytest direcionado, quatro suites shell, reproduções, contratos PS, Compose cliente e asset Arch.
CI/PR: CI base main 33136161096 success; gitleaks 33136161092 success; sem nova publicação/PR nesta auditoria.
Estado do host antes/depois: nenhuma operação mutável de serviços/workloads/boot; somente arquivos de auditoria/fixtures/download do asset.
Segredos verificados como ausentes: relatório e provas contêm dados de fixture e metadados públicos; valores de env real não lidos nem copiados.
Limitações e riscos restantes: Windows/Arch limpos reais e credenciais de provedores não exercitados; Pester local incompatível; P0 restore aberto.
Bloqueios reais: execução nativa Windows e E2E em VMs descartáveis dependem de infraestrutura de validação; não bloqueiam análise/registro concluídos.
Próximo passo exato: fase 0; assumir PZ-AUD-011/005, reproduzir, implementar isolamento/estado, depois 012→009→010; conter aceitação de restore até fechar 010.
```
