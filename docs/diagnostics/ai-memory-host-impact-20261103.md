# ai-memory: impacto no host e plano de otimização (03/11/2026)

Este é um diagnóstico de recursos do ai-memory no host Linux (Manjaro/KDE). Ele
foi levantado pelo Fôlego e separa o que cabe à **instalação** (PhaseZero), ao
**upstream** (ai-memory) e ao **Fôlego** (observação, manutenção e destrave).
Nenhuma configuração foi alterada durante o levantamento, exceto um ponto,
registrado em §3.4: a finalização assistida de uma ponte MCP duplicada,
confirmada pelo usuário.

## 1. Arquitetura observada

- **Servidor único:** `ai-memory.service` (usuário) roda
  `ai-memory serve --transport http --bind 127.0.0.1:49374 --enable-api`.
  O binário nativo é a versão 3.3.1, fixada em `packaging/ai-memory/pins.json`.
  Os dados ficam em `~/.local/share/ai-memory` e ocupam 1,5 GB.
- **Instalação e ligação dos clientes:** `linux/ai/setup-memory.sh` →
  `wire_agents()` roda, para cada agente detectado, `ai-memory install-mcp
  --client … --apply` e `ai-memory install-hooks --agent … --apply`.
- **Serviços auxiliares do PhaseZero**, gerados por `linux/ai/memory_manager.py`:
  - `phasezero-ai-memory-watch.service`: Python, ~15 MB.
  - `phasezero-ai-memory-sync.timer` e `.service`: sincronização criptografada
    a cada 15 min.

| Cliente | Ferramentas MCP | Hooks (registro automático) | Arquivo |
|---|---|---|---|
| Claude Code | HTTP direto | 10 eventos, incluindo `pre-tool-use` e `post-tool-use` (×2) | `~/.claude.json`, `~/.claude/settings.json` |
| Codex | HTTP direto | ~7 eventos, também a cada ferramenta | `~/.codex/config.toml`, `~/.codex/hooks.json` |
| OpenCode | HTTP `type: "remote"` | não encontrados | `~/.config/opencode/opencode.json` |
| Grok | HTTP direto | não verificados | `~/.grok/config.toml` |
| Hermes | HTTP direto, conexão persistente | — | `~/.hermes/config.yaml` |
| Claude Desktop | **ponte `npx -y mcp-remote@latest`** | — | `~/.config/Claude/claude_desktop_config.json` |
| Qwen / GLM | **sem configuração própria no host** | — | provavelmente usados como modelos no OpenCode; confirmar |

## 2. Medições (janela curta, com agentes ativos)

- **Servidor:** 42 MB de RAM agora; chegou a 166 MB depois do boot. Média de
  ~3,7% de um núcleo desde o boot, e **~13% de um núcleo com um agente usando
  ferramentas**. A carga acompanha os hooks, porque cada ferramenta gera
  `pre` + `post` e cada um grava no servidor.
- **Hook:** processo nativo com início de ~6 ms. É barato por unidade; o custo
  total escala com ferramentas × agentes × eventos.
- **Ponte do Claude Desktop:** ~110 MB por instância (npm + node). Havia
  **duas** para o mesmo cliente (08:22 e 08:28); a mais antiga foi finalizada.
  Com `@latest`, o `npx` resolve a versão a cada início do Desktop.
- **Sincronização:** falha a cada 15 min com
  `state: memory-key-unavailable-unlock-system-vault`. A chave fica num cofre do
  sistema que está trancado. A sincronização não acontece e o journal acumula
  erros.

## 3. Problemas e onde cada um se corrige

### 3.1 Hooks a cada ferramenta (maior custo de CPU com agentes ativos)
- **Instalação (PhaseZero):** `wire_agents()` registra todos os eventos que o
  upstream oferece. Proposta: um perfil de hooks **enxuto** como padrão, com
  `session-start`, `user-prompt-submit`, `pre-compact`, `stop`, `session-end` e,
  se for preciso, só `post-tool-use`. O perfil **completo** fica como opção.
  Isso vale para Claude Code, Codex e qualquer harness com hooks (Grok,
  OpenCode), com o mesmo perfil para todos.
- **Upstream (ai-memory):** confirmar se `hook-spool` grava em lote. Se gravar
  um evento por vez, abrir uma issue propondo agrupar por N eventos ou T
  segundos. Não aplicar patch local no binário fixado.

### 3.2 Ponte `mcp-remote@latest` no Claude Desktop
- **Instalação (PhaseZero):** ao ligar o `claude-desktop`, verificar se a
  versão instalada aceita MCP remoto por URL. Se aceitar, gravar a URL direta
  (`http://127.0.0.1:49374/mcp`) e eliminar a ponte. Se não aceitar, usar
  `mcp-remote` com **versão fixa** e instalado uma vez, nunca `@latest` via
  `npx -y`. Não usar `serve --transport stdio` por cliente, porque isso sobe um
  servidor completo, com watcher e banco, para cada cliente.
- **Fôlego:** já lista as pontes (cliente dono, endpoint, conexão), marca
  duplicada/órfã e finaliza a duplicada sob clique, com reverificação.

### 3.3 Sincronização falhando em laço
- **Instalação (PhaseZero):** com o cofre trancado, o timer deve **pausar com
  estado explícito** (por exemplo, `waiting-unlock`) em vez de falhar a cada
  15 min, e retomar quando o cofre for destrancado. Expor isso no
  status/doctor do PhaseZero.
- **Usuário:** destrancar o cofre do sistema quando quiser sincronizar.

### 3.4 Limites do serviço do servidor
- **Instalação (PhaseZero):** a unit `ai-memory.service` gerada deve incluir
  `Nice=10`, `IOSchedulingClass=best-effort`, `IOSchedulingPriority=7` e
  `MemoryHigh=` em torno de 300 MB (só limitar crescimento, sem matar), para que
  agentes e compositor tenham prioridade. O ajuste deve ser aplicado por
  `setup-memory.sh` de forma idempotente.

### 3.5 Banco e backup antigo
- **Instalação (PhaseZero) / usuário:** rodar `ai-memory compact`, que só
  recupera páginas livres e não apaga dados, e decidir sobre o
  `backup-pre-migrate.tar.gz` antigo. **Nenhuma remoção automática.**

### 3.6 Cobertura e consistência dos clientes
- **Instalação (PhaseZero):** sempre gerar a configuração pelo
  `install-mcp`/`install-hooks` do upstream, sem edição manual, para evitar
  divergências como a ponte `@latest` só no Desktop.
- **Qwen/GLM:** confirmar se rodam dentro do OpenCode. Se forem CLIs próprias,
  cadastrar o mesmo endpoint HTTP (`type: remote`/`url`), nunca ponte ou stdio.
- **`ai-memory doctor`:** usar para provar a cobertura de captura por harness
  depois das mudanças.

## 4. Papéis

| Papel | Responsável | Escopo |
|---|---|---|
| **Instalação e configuração** | PhaseZero (`linux/ai/setup-memory.sh`, `memory_manager.py`, `pins.json`) | Unit do servidor e limites, perfil de hooks, registro MCP por cliente, ponte do Desktop, timer de sincronização, doctor/status |
| **Produto** | Upstream `akitaonrails/ai-memory` | Lote no spool de hooks, modos de transporte. Pedidos por issue; a versão local continua fixada |
| **Manutenção, otimização e destrave** | Fôlego | Observar o servidor, as pontes, a taxa de hooks e as units com falha. Sugerir. Finalizar só a ponte duplicada ou órfã, sob clique, com revalidação e reverificação. **Não edita configuração de agentes nem do ai-memory** |

O Fôlego age apenas quando há comportamento prejudicial ao host: pontes
duplicadas ou órfãs, laços de falha e consumo fora do orçamento. As correções
de causa ficam na instalação.

## 5. Aceite das correções (instalação)

1. Perfil enxuto aplicado a todos os clientes com hooks. `ai-memory doctor` sem
   lacunas de captura. Durante uma sessão ativa, a CPU do servidor deve cair em
   relação aos ~13% medidos, com o mesmo roteiro de uso.
2. Claude Desktop com uma única conexão ao servidor: URL direta ou ponte com
   versão fixa. Nenhum `npx … @latest` em execução.
3. Com o cofre trancado, a sincronização fica em estado de espera explícito, sem
   `Failed to start` no journal. Com o cofre destrancado, sincroniza.
4. `systemctl --user show ai-memory.service` mostra os limites do §3.4.
5. Reexecutar `setup-memory.sh` não muda nada (idempotente) e não remove
   arquivos do usuário.
6. Testes do PhaseZero pertinentes (`tests/test_memory_*.py`) verdes. QA no host
   real registrado no handoff.
