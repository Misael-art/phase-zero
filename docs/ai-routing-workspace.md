# 9Router e Odysseus

PhaseZero integra dois componentes distintos:

- **9Router**: gateway OpenAI-compatible local. Consolida providers autorizados, combos e fallback.
- **Odysseus**: workspace web agnóstico de IA. Consome endpoints locais/remotos; não é distribuição Linux.

Na UI nativa, a página **Proxies IA** reúne ambos os gateways, os cards de ciclo de vida dos proxies OpenAI-compatible (`kimi`, `qwen`, `deeps`, `mimo`), a autenticação por navegador e a sincronização com IDEs, com polling passivo de `pz ai proxies detailed-status`.

## 9Router

```bash
linux/pz ai 9router install
linux/pz ai 9router status
linux/pz ai 9router dashboard
linux/pz ai 9router provider status
linux/pz ai 9router combo sync
linux/pz ai 9router client status
linux/pz ai 9router check-update
linux/pz ai 9router update
```

Controles PhaseZero:

- pacote npm exato; `dist.integrity` comparado antes da instalação;
- staging, troca atômica, health check e rollback;
- bind exclusivo em `127.0.0.1:20128`;
- ponte privada Unix para workloads Podman; sem bind adicional em LAN;
- senha, JWT e API key aleatórios; arquivos `0600`; dados `0700`;
- `REQUIRE_API_KEY=true`; request logs desativados;
- watchdog passivo a cada dez minutos. Testes reais de provider somente sob demanda;
- telemetria do status resumida. IDs de conta, prompts e chaves não saem no inventário.

Executar cliente com perfil temporário:

```bash
claude-9router
linux/pz ai opencode run --route=9router -- run
```

Wrapper injeta endpoint e chave apenas no processo filho. Configurações globais de cada agente não são sobrescritas. Uso de OAuth, assinaturas e modelos deve respeitar termos e cotas do provider. Fallback não significa evasão de limites.

Claude Code oficial permanece na assinatura por padrão. `claude-subscription` remove qualquer rota herdada; `claude-9router` usa somente `ANTHROPIC_AUTH_TOKEN` e o endpoint loopback. Bonsai coexiste como `claude-bonsai`: não ocupa porta local e injeta suas variáveis somente no processo filho. O launcher preserva o consentimento de snapshot/upload e bloqueia diretórios ou arquivos sensíveis conhecidos.

Use `linux/pz ai claude preflight bonsai --cwd /projeto/revisado` e depois `linux/pz ai claude run bonsai --cwd /projeto/revisado`. O diretório explícito evita iniciar snapshot no HOME por engano; preflight procura nomes conhecidos de dotenv, credenciais e chaves sem ler conteúdo. Também valida DNS A/AAAA e TLS do router Bonsai usando Node. `ENOTIMP` é classificado como falha DNS/transporte transitória; PhaseZero não altera DNS nem aumenta retries automaticamente.

`bonsai` é shim PhaseZero para todos subcomandos. `start` executa preflight e usa `BONSAI_ROUTE=direct|9router`; `login` sonda WorkOS/AuthKit antes de abrir navegador e restaura credential store byte a byte em falha ou cancelamento. Demais comandos passam pelo runner Node 24. Rota `9router` é fallback explícito, não inicia Bonsai e não cria snapshot/upload. Token Bonsai nunca é importado no 9Router. Na rota direta, Claude.ai connectors ficam desativados porque Bonsai usa endpoint e bearer próprios. Use `claude-subscription` quando precisar dos connectors Claude.ai.

Instalador copia o gerenciador PhaseZero para `~/.local/share/cc-installer/tools/phasezero-claude-manager/`. Shims `bonsai` e `claude-bonsai` usam somente essa cópia transacional. Nenhum subcomando depende de branch, worktree ou checkout ativo; `login`, `start`, preflight e fallback nunca podem executar versões divergentes.

Instalação cria `PhaseZero AI — Bonsai` no menu KDE. Entrada usa ícone próprio do mascote PhaseZero com bonsai, abre terminal no worktree principal e seleciona 9Router explicitamente; portanto não inicia Bonsai nem cria snapshot/upload. `PZ_BONSAI_DESKTOP_ROUTE=direct phasezero-ai-bonsai` permite sonda direta quando autenticação upstream voltar. Ícone, wrapper e `.desktop` participam da mesma transação e rollback.

Instalação local funcional não significa rota Bonsai pronta. `ready` exige runner validado, artefato confiável, token local válido e credential store seguro; `runtimeReady` descreve somente runtime. Se AuthKit estiver desativado e token estiver expirado, status, preflight e verify permanecem vermelhos com `upstream-auth-disabled`. Aceitação ponta a ponta só passa quando `bonsai login` inicia autenticação e `bonsai start` alcança consentimento upstream. PhaseZero não mascara indisponibilidade externa nem troca para 9Router sem seleção explícita.

Instalador aceita registry com SRI, cache npm 0.4.19 com SRI conhecida ou instalação externa cuja identidade e hashes constem na allowlist. Sem artefato confiável, retorna `upstream-distribution-unavailable` sem instalação parcial. `~/.local/bin` fica no início dos perfis para o shim interceptar todos comandos. Abra novo login shell após instalação.

OpenCode usa `~/.config/opencode/opencode.json` como configuração canônica. Provider 9Router aponta para `127.0.0.1:20128/v1`; `apiKey` referencia arquivo `0600`, sem chave embutida e sem variáveis Anthropic/OpenAI globais. `BONSAI_ROUTE=direct` é recusado no OpenCode por falta de suporte Bonsai documentado. `9router/Default` permanece configurado e disponível; `pz ai opencode run` e `verify --live` usam o combo ativo quando `--model` não foi informado, evitando prender execução num primeiro provider temporariamente limitado. O smoke executa prompt e chamada `read` sobre fixture temporária sintética.

Diagnóstico 9Router considera saudável apenas listener loopback pertencente à árvore do serviço PhaseZero. Processo alheio ou startup legado não satisfaz healthcheck.

## Odysseus

```bash
linux/pz ai odysseus install
linux/pz ai odysseus status
linux/pz ai odysseus open
linux/pz ai odysseus check-update
linux/pz ai odysseus update
linux/pz ai odysseus backup
linux/pz ai odysseus doctor
```

Upstream não publica releases ou tags. PhaseZero resolve `dev`, clona repositório oficial, exige SHA estável durante clone e fixa commit. Manifesto registra origem, commit e tree. Commit não assinado permanece identificado; atualização nunca ocorre automaticamente.

Deploy usa Podman rootless e Compose. UI, ChromaDB, SearXNG e ntfy ficam em loopback. Imagens dependentes são resolvidas e travadas por digest. Limites padrão preservam recursos do Steam Deck: 6 GiB/5 CPUs para app, 2 GiB para ChromaDB, 1 GiB para SearXNG e 256 MiB para ntfy. Autenticação é obrigatória; bypass localhost fica desligado; `no-new-privileges` fica ativo; socket Docker não é montado. Segredos residem em `~/.config/phasezero/odysseus/odysseus.env`, modo `0600`. Comando `credentials-path` revela somente caminho.

Patch local registrado remove `setup_requires` de Torch/CUDA usado somente ao construir wheels Python do Real-ESRGAN. Isso evita baixar toolchain NVIDIA num host AMD. Manifesto registra SHA-256 do diff junto ao tree upstream.

Odysseus recebe 9Router como endpoint OpenAI-compatible quando chave gerenciada existe. Um proxy interno no container atravessa socket Unix `0600`; 9Router continua preso ao loopback do host. Doctor valida socket e rota. Dashboard permite cadastrar outro endpoint sem acoplar workspace a provider.

Odysseus inclui console administrativo, execução de ferramentas e armazenamento de arquivos. Não publicar porta 7000 diretamente. Para acesso remoto, usar proxy TLS ou rede privada, `SECURE_COOKIES=true` e origem CORS exata.

## Roteamento IA por tarefa

O configurador (`linux/ai/routing_manager.py`, acionado por `pz ai routing`)
decide a cadeia de fallbacks de cada tarefa com base na saúde real do 9Router:

```bash
linux/pz ai routing status            # saúde, modelos e conexões (redigido)
linux/pz ai routing inventory --refresh-quota   # cotas reais por conexão
linux/pz ai routing recommend --task code --policy balanced
linux/pz ai routing plan --json      # diff entre combos phasezero-* e o plano
linux/pz ai routing apply --task code --yes     # materializa (transacional)
linux/pz ai routing run codex        # executa cliente com env de criança
linux/pz ai routing verify --live    # health, planMatches, isolamento Bonsai
linux/pz ai routing rollback <manifest>   # restaura bytes; recusa drift sem --force
```

- Tarefas: `code`, `analysis`, `plan`. Políticas: `quality`, `balanced`,
  `save-quota`, `privacy` (pesos somam 100; reserva de quota por política).
- Combos gerenciados `phasezero-code/analysis/plan` (máx. 5 modelos); combos do
  usuário (`Default`, `claude-Combo_Cleude`) nunca são alterados.
- Apply escreve manifesto em
  `~/.local/share/phasezero/ai-routing/operations/apply-*/` com bytes
  anteriores; rollback restaura combos e state, falhando em drift externo.
- Quota desconhecida nunca é tratada como 100%; confiança 1.0/0.4/0.15.
- 401/403/429 ativos e cooldowns excluem o provider até a próxima sessão;
  recomputar a rota antes de iniciar sessão.
- Segredos redigidos em todo output persistido (state/manifest 0600/0700).
- UI nativa: página "Roteamento IA" (cards por tarefa, políticas, editor de
  fallbacks, aplicar/reverter). Bonsai permanece isolado do roteador.

## Atualizações

```bash
linux/pz updates check
linux/pz updates install-service
linux/pz updates apply 9router
linux/pz updates apply odysseus
linux/pz updates apply codex-desktop
```

Inventário agrega PhaseZero, canais instalados, apps IA, frontends Windows, 9Router, Odysseus e pacotes Arch pendentes. Timer diário verifica e notifica; nunca aplica automaticamente.

Arch exige upgrade completo. PhaseZero não executa atualização parcial. Aplicação do host permanece explícita:

```bash
phasezero-admin pacman -Syu
```

Self-update PhaseZero mantém plano e confirmação próprios:

```bash
linux/pz self-update plan
linux/pz self-update apply <plan-id> <token>
```
