# AI Coding Tools

Escopo: integrações opcionais. Nenhuma chave real entra no repositório.

## Fontes oficiais usadas

- Claude Code: https://docs.claude.com/en/docs/claude-code/setup
- Bonsai CLI: https://docs.trybons.ai/bonsai-cli
- Claude Desktop Linux: https://support.claude.com/en/articles/10065433-install-claude-desktop
- OpenCode: https://opencode.ai/docs/
- RTK / Rust Token Killer: https://www.rtk-ai.app/docs/
- Hermes Agent: https://hermes-agent.nousresearch.com/docs/getting-started/installation
- Hermes MCP: https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp
- OpenClaw: https://docs.openclaw.ai/install
- OpenClaw CLI: https://docs.openclaw.ai/cli/onboard
- AionUi: https://aionui.com/download/
- Google Antigravity: https://antigravity.google/
- Printing Press: https://github.com/mvanhorn/cli-printing-press
- IndexTTS2: https://github.com/index-tts/index-tts
- Odysseus: https://github.com/pewdiepie-archdaemon/odysseus
- Ollama: https://ollama.com/download
- LM Studio: https://lmstudio.ai/
- Open WebUI: https://docs.openwebui.com/
- n8n: https://docs.n8n.io/
- ai-usagebar: https://github.com/akitaonrails/ai-usagebar
- ai-memory: https://github.com/akitaonrails/ai-memory

## Suporte implementado

| Tool | Instalação | Validação | Configuração | Desinstalação |
| --- | --- | --- | --- | --- |
| `claude-code` | Instalador nativo oficial somente quando ausente; instalação saudável é preservada | `claude auth status --json`, wrappers e smoke opt-in | OAuth Claude.ai padrão; `claude-subscription` limpa rotas herdadas | Rollback pelo manifesto `cc-installer` |
| `bonsai` | npm user-local com `dist.integrity`; instalação saudável é reutilizada | versão, credential store e launcher protegido | `claude-bonsai`; consentimento de snapshot continua interativo | Rollback pelo manifesto; credenciais preservadas |
| `opencode` | `npm install -g --prefix <root> opencode-ai` | `opencode --version` | Manual/provider oficial | Remove pacote/prefixo/PATH gerenciado |
| `oh-my-openagent` (OMO) | Linux: `bunx oh-my-openagent install --no-tui --platform=opencode` (exige Bun; provider-agnostic por padrão, telemetria off) | `bunx oh-my-openagent doctor --platform=opencode --json` (`exitCode 0`) | Plugin registrado em `~/.config/opencode/opencode.jsonc`; `oh-my-openagent.json` com agentes/categorias; providers via `PZ_OMO_*` | `linux/pz ai omo disable` (desregistra) ou `uninstall` (remove config) |
| `openclaw` | Linux: `npm install -g --prefix <root> openclaw@latest` | `openclaw --version`, `openclaw doctor` | Linux: baseline non-interactive, MCP, ai-memory hooks; daemon guiado via `openclaw onboard --install-daemon` | Remove pacote/prefixo/PATH gerenciado |
| `rtk` | Windows: release GitHub; Linux: release GitHub `rtk-*-linux-*.tar.gz` com SHA-256 de `checksums.txt` | `rtk --version` | `rtk init`, `rtk gain`; no Linux via `linux/pz ai setup rtk` | Remove binario gerenciado em `~/.local/bin` |
| `antigravity-workflows` | Sem binário | Arquivos locais | Gera `.antigravity/workflows/*.md` | Manual, para preservar edições |
| `hermes-agent` | Linux/WSL2 + `install.sh --skip-setup --non-interactive` oficial | `hermes --version`, `hermes doctor` | Linux: MCP em `~/.hermes/config.yaml`; provider/login via `hermes setup --portal` ou `hermes model` | Manual, preserva `~/.hermes` |
| `hermes-desktop` | Manual | Detecta caminhos comuns | Manual | Não remove artefato não gerenciado |
| `aion-ui` | Manual/winget oficial | Detecta caminhos comuns | Manual | Não remove artefato não gerenciado |
| `printing-press` | `manual-workflow` oficial | Caminho/repo local quando usuario instala | Manual opt-in | Nao remove artefato nao gerenciado |
| `indextts2` | `manual-workflow` oficial | Caminho/repo local quando usuario instala | Manual opt-in, GPU/modelos por host | Nao remove artefato nao gerenciado |
| `odysseus` | `manual-workflow` oficial | Caminho/repo local quando usuario instala | Manual opt-in, admin console | Nao remove artefato nao gerenciado |
| `ollama` | Winget `Ollama.Ollama` sob demanda | `ollama --version` | Modelos/pulls manuais | Remocao via winget manual |
| `lm-studio` | Winget `LMStudio.LMStudio` sob demanda | Caminhos comuns/`lms` quando disponivel | Modelos manuais | Remocao via winget manual |
| `openwebui` | Docker manual | Container/porta sob escolha do usuario | Login/providers manuais | Manual para preservar volume |
| `n8n` | Template de workflow | `n8n --version` quando instalado | Workflows manuais com credenciais do usuario | Manual para preservar dados |
| `ai-usagebar` | Release Linux verificada (WSL) ou fallback cargo; no Windows experiencia e TUI/CLI `--json`, widget Waybar so em Linux | `ai-usagebar --help` / `ai-usagebar-tui` | `config.toml` gerado; chaves Z.AI/OpenRouter/DeepSeek vindas do manifesto validado; Claude/Codex usam OAuth dos CLIs oficiais | Remove binarios Windows gerenciados; preserva config/tokens |
| `ai-memory` | Release nativa Windows `ai-memory-windows-x86_64.zip` verificada por sha256; fallback `cargo install` | `ai-memory status` / `ai-memory --help` | `install-mcp`/`install-hooks --apply` por agente detectado; servidor loopback `127.0.0.1:49374` via task de logon | Remove binario gerenciado e task; preserva `wiki/`/`raw/`/`db/` do usuario |
| `headroom` | Linux: `uv tool install "headroom-ai[proxy]"` com fallback `pipx` | `headroom version` | Wrappers/proxy ficam explicitos via `linux/ai/headroom-agent.sh`; nada auto-wrap | Remove via `uv tool uninstall headroom-ai`/`pipx uninstall` |
| `phasezero-admin` | Linux: wrapper local; usa `bigsudo` oficial, fallback `pkexec`, fallback `sudo`; instala `bigsudo` via pacman/pkexec quando ausente e disponivel | `phasezero-admin --status` | Variaveis `PHASEZERO_ADMIN*` e regras para CLIs/IDEs; sem senha armazenada e sem sudoers passwordless | Remove `~/.local/bin/phasezero-admin`/fallback e configs user |
| `ai-proxy-suite` | Windows: git/npm/go por ferramenta; Linux: `linux/pz ai proxies install all` com Node 24 isolado | Windows: doctor/webValidation; Linux: `linux/pz ai proxies auth/test` | OpenAI-compatible providers kimi/qwen/deeps/mimo; browser-session ou env-session redigidos | Remove manual para preservar checkouts/sessões |

## CLI

Exemplos:

```powershell
.\install-cli.bat --tool claude-code --validate --dry-run --yes --no-admin
.\install-cli.bat --tool opencode --install-root "$env:TEMP\PhaseZero AI Tools" --yes --no-admin
.\install-cli.bat --tool opencode --uninstall --install-root "$env:TEMP\PhaseZero AI Tools" --yes --no-admin
.\install-cli.bat --tool hermes-agent --yes
.\install-cli.bat --tool printing-press --install --dry-run --yes --no-admin
.\install-cli.bat --all-ai-tools --validate --dry-run --yes
```

## Linux / SteamOS-like host

Entrada: `linux/pz ai`.

```bash
linux/pz ai status
linux/pz ai setup opencode
linux/pz ai opencode sync      # fixa o CLI na versão do opencode-desktop (anti-skew de DB)
linux/pz ai opencode version-status  # JSON: versão CLI vs desktop, inSync, DB, hook
linux/pz ai opencode status    # JSON redigido: config canônica, segredo por arquivo e 9Router
linux/pz ai opencode install --dry-run
linux/pz ai opencode install --yes
linux/pz ai opencode verify
linux/pz ai opencode verify --live
linux/pz ai opencode run --route=9router -- run
linux/pz ai opencode rollback ~/.local/share/opencode-route-installer/operations/<id>/manifest.json
linux/pz ai opencode install-hook  # hook pacman: re-sincroniza o CLI após updates
linux/pz ai setup omo          # oh-my-openagent plugin para OpenCode (opt-in)
linux/pz ai omo doctor         # bunx oh-my-openagent doctor --platform=opencode
linux/pz ai omo status         # status JSON (bun, opencode, plugin registrado)
linux/pz ai omo disable        # desregistra o plugin (evita consumo em background)
linux/pz ai setup codex
linux/pz ai setup claude
linux/pz ai claude status
linux/pz ai claude install --dry-run
linux/pz ai claude install --yes
linux/pz ai claude verify
linux/pz ai claude verify --auth=subscription --live
linux/pz ai claude preflight bonsai --cwd /projeto/revisado
linux/pz ai claude run subscription -- --help
linux/pz ai claude run bonsai --cwd /projeto/revisado
linux/pz ai claude run proxy --proxy=9router -- --help
linux/pz ai claude rollback ~/.local/share/cc-installer/operations/<id>/manifest.json
BONSAI_ROUTE=direct bonsai start --cwd /projeto/revisado
BONSAI_ROUTE=9router bonsai start --cwd /projeto/revisado
linux/pz ai desktop install-claude
linux/pz ai desktop install-qwen
linux/pz ai desktop status
linux/pz ai desktop repair-codex
linux/pz ai desktop install-services
linux/pz ai setup memory
linux/pz ai setup compat
linux/pz ai setup admin
linux/pz ai admin status
linux/pz ai setup rtk
linux/pz ai setup caveman
linux/pz ai setup headroom
linux/pz ai setup frugality
linux/pz ai compat status
linux/pz ai token-economy status
linux/pz ai setup ides
linux/pz ai setup hermes
linux/pz ai setup openclaw
linux/pz ai mcp sync
linux/pz ai mcp repair
linux/pz ai mcp doctor
linux/pz ai mcp status
linux/pz ai menu
linux/pz ai proxies auth all
linux/pz ai proxies detailed-status
linux/pz ai proxies login kimiproxy
linux/pz ai proxies login qwenproxy
linux/pz ai proxies login deepsproxy
linux/pz ai proxies login all
linux/pz ai proxies restart kimiproxy
linux/pz ai proxies test
```

Automacoes Linux:

- `linux/ai/status.sh`: status JSON para runtime, CLIs, IDEs, MCP, Docker/Open WebUI, Ollama, RTK e ai-memory.
- `linux/ai/setup-agent-compat.sh`: instala RTK Linux por release GitHub verificada, aplica `rtk init`, instala Headroom via `uv`/`pipx`, reaplica regras Caveman/PhaseZero, mantém Ponytail limitado a workspace detectado, gera pack `ai-context-frugality` e status `agentCompat`.
- `linux/ai/setup-admin-bridge.sh`: cria `phasezero-admin`, detecta/instala `bigsudo`, fornece fallback `pkexec`/`sudo`, escreve estado/env user e sincroniza regra para agentes/IDEs.
- `linux/ai/headroom-agent.sh`: helper explícito para `headroom status/proxy/wrap-*`; wrappers não rodam automaticamente.
- `linux/ai/claude_code_manager.py`: inventário redigido, quarentena de env, reparo de hooks órfãos, launchers por processo, migração 9Router e rollback byte a byte. Bonsai bloqueia diretórios sensíveis e mantém confirmação upstream de upload.
- A rota Bonsai usa autenticação externa isolada. Claude.ai connectors ficam indisponíveis por definição nessa sessão; `status` e `verify --auth=bonsai --live` reportam essa capacidade sem tratar o aviso como erro.
- `linux/ai/proxy-suite.sh`: instala e gerencia dez proxies Linux com runtime Node 24 isolado, build Go e units systemd de usuário desativadas por padrão. Porta o contrato Windows `webValidation`: `auth` retorna status redigido; `login` abre browser real para Kimi/Qwen/DeepSeek; Mimo fica por env-session local. Contrato completo em `docs/linux-ai-proxies.md`.
- `linux/ai/desktop-apps.sh`: instala Claude Desktop pelo repositorio apt oficial Anthropic e Qwen Code Desktop pela release oficial `desktop-latest`, em prefixos atomicos do usuario. Valida assinatura/digestos e SHA-256. Corrige o pipeline do Codex Desktop Linux, habilita guarda de workspace e timer user.
- `linux/ai/setup-codex.sh`: instala/atualiza `@openai/codex` no prefixo npm do usuario e publica symlink em `~/.local/bin`.
- `linux/ai/setup-memory.sh`: instala `ai-memory` por AUR (`ai-memory-bin`) quando disponivel; fallback Docker wrapper; fallback build Cargo. Configura serviço user loopback `127.0.0.1:49374` e roda `install-mcp`/`install-hooks` para agentes detectados.
- `linux/ai/setup-hermes.sh`: instala release/commit/árvore e instalador fixados no
  manifesto. Release não aprovada exige aceite explícito preso ao commit exato.
  Integra o modelo `Default` ao 9Router em loopback por referência de credencial,
  cria launchers/desktop entry, fixa Playwright Python, sincroniza MCP ai-memory e
  habilita `hermes-gateway.service` como serviço de usuário persistente. Um
  drop-in mantém o launcher PhaseZero mesmo quando Hermes regenera sua unit. O
  launcher importa somente a chave cliente canônica; não carrega o arquivo inteiro
  de segredos do roteador.
- `linux/ai/setup-openclaw.sh`: instala `openclaw@latest` no prefixo npm do usuário, executa baseline não interativo (`openclaw setup --non-interactive --accept-risk` com fallback legado), sincroniza MCPs em `~/.openclaw/config.json`, aplica `ai-memory` MCP/hooks e instala o Gateway user service via `openclaw gateway install/start`.
- `linux/ai/setup-ides.sh`: gera recomendações `.vscode/extensions.json`, sincroniza MCP seguro em VS Code workspace/user, Cursor, Zed e ZCode, adiciona helper Neovim opcional e grava estado em `~/.local/state/phasezero/ai/ides.json`.
- `linux/ai/mcp-manager.sh`: sincroniza MCP seguro por padrao (`ai-memory` loopback), repara configs quebradas, e permite install explicito de remotos em OpenCode (`mcp`), Claude/Claude Desktop, Codex TOML, VS Code, Cursor, Zed, ZCode, Hermes YAML e OpenClaw JSON.
- `linux/ai/setup-usagebar.sh`: instala `ai-usagebar-bin` quando AUR existe e cria config por env vars.
- `linux/ai/setup-opencode.sh`: além de clipboard/launcher/MCP, orquestra o **lockstep de versão CLI↔desktop**. O CLI e o `opencode-desktop` compartilham um único SQLite (`~/.local/share/opencode/opencode.db`) cujo schema é migrado para frente pelo binário mais novo; se as versões divergem, a mais antiga quebra (ex.: `no such column: replacement_seq`). `sync` fixa o CLI na **versão exata** do desktop instalando `opencode-ai@<versão>` no prefixo npm do usuário e ligando em `~/.local/bin` (que precede `/usr/bin` no PATH, sombreando o pacote pacman sem root); faz backup do DB por reflink btrfs antes. `version-status` reporta skew; `install-hook` instala um hook pacman `PostTransaction` que re-sincroniza o CLI sempre que `opencode`/`opencode-desktop-bin` são atualizados (paru usa pacman, então updates AUR também disparam). `setup` chama `sync` automaticamente quando há desktop.
- `linux/ai/setup-omo.sh`: instala/configura o plugin `oh-my-openagent` (OMO) para OpenCode. Garante Bun (pacman, fallback instalador oficial em `~/.bun`) e `ast-grep` opcional (skill `/refactor`); registra o plugin via `bunx oh-my-openagent install --no-tui --platform=opencode` (nunca install global); telemetria off por padrão (`OMO_DISABLE_POSTHOG=1`, sobrescreva com `PZ_OMO_TELEMETRY=1`); provider-agnostic por padrão (`PZ_OMO_CLAUDE/OPENAI/GEMINI/COPILOT` ou `PZ_OMO_INSTALL_ARGS`). Subcomandos `doctor|status|enable|disable|uninstall|dry-run`; `disable` desregistra o plugin do `opencode.jsonc`/`tui.json` preservando o MCP `ai-memory`.

O perfil `profiles/dev-ai.json` preserva Windows e expande só Linux com `python-pipx`, `uv`, `git`, `github-cli`, `direnv` e scripts AI novos.

Resultados estruturados:

- `--result-path <file>` grava JSON.
- `--log-path <file>` grava JSONL.
- Exit `0`: ação validada/planejada/concluída ou validação sem bloqueio.
- Exit `2`: argumento/tool inválido ou erro de execução.
- Exit `3`: install/configure/uninstall bloqueado por suporte externo ou falha validada.

## Segurança

- Instalações automatizadas usam root gerenciado por usuário.
- PATH é alterado só no escopo User e registrado em manifesto.
- Uninstall remove apenas artefatos registrados pelo projeto.
- Chaves/API/login ficam em métodos oficiais das ferramentas ou SecretStore/Credential Manager; placeholders em docs.
- No Linux, `rotate-secrets.sh` grava chaves no `pass`; aplicação de valor cru em config exige `PZ_AI_APPLY_RAW_SECRETS=1`.
- Claude Desktop usa somente o repositorio oficial Anthropic. BigLinux extrai o `.deb` validado para `~/.local/share/phasezero`; nenhum AUR e nenhuma escrita root.
- Qwen Code Desktop usa somente AppImage oficial `QwenLM/qwen-code`. Config compartilhada fica em `~/.craft-agent` com permissão 0700. Autenticação fica a cargo do usuário; PhaseZero não grava API keys. OAuth gratuito Qwen foi descontinuado em 15/04/2026, então use Alibaba Coding Plan, OpenRouter, Fireworks ou chave própria suportada pelo aplicativo.
- Codex Desktop Linux continua sendo wrapper comunitario sobre o DMG macOS. PhaseZero valida o pacote pacman local e usa PolicyKit; Codex CLI permanece pacote oficial `@openai/codex`.
- Hermes Agent não usa o pacote npm `hermes` como sinal oficial. Em Windows, o caminho automatizado suportado é WSL2; se `wsl.exe` retornar `Wsl/CallMsi/Install/REGDB_E_CLASSNOTREG`, o fluxo bloqueia cedo com `blockerKind=wsl-msi-registration-broken`.
- Integrações sem método Windows oficial ou silent installer confirmado ficam `manual`.
- OpenRouter Owl Alpha foi tratado como modelo opcional com ID `openrouter/owl-alpha`; disponibilidade/limites/preço dependem do provedor e devem ser validados antes de configurar Hermes.
- Providers BYOK OpenAI-compatible extras (`minimax`, `nex`, `zhipu-glm`) ficam manual opt-in no catalogo de secrets.
- `ai-usagebar` nao raspa APIs de billing com chaves brutas: Claude/Codex usam as credenciais OAuth gravadas pelos CLIs oficiais; Z.AI/OpenRouter/DeepSeek usam env vars vindas do manifesto validado (`validation.state == passed`). Z.AI permanece manual opt-in (zhipu-glm).
- `ai-memory` e beta (autor pede uso com cautela). O servidor loopback `127.0.0.1:49374` e opt-in via task de logon; `install-mcp`/`install-hooks` so rodam para agentes detectados e sao idempotentes. Dados de memoria do usuario (`wiki/`, `raw/`, `db/`) sao preservados na desinstalacao.
- RTK no Linux usa somente release oficial `rtk-ai/rtk`, asset por arquitetura e checksum publicado. Se RTK estiver ausente, PhaseZero fica em modo degradado e comandos seguem diretos.
- Headroom nunca auto-envolve agentes. O usuario chama `linux/ai/headroom-agent.sh wrap-codex`, `wrap-claude`, `proxy` ou `mcp-install` conscientemente. `linux/pz ai token-economy status` valida Codex/Claude por presença das regras, RTK, ai-memory, Headroom e `ai-context-frugality`; status `ready` não altera sessão ativa nem injeta wrapper.
- Admin bridge nunca grava senha, nunca cria sudoers passwordless e nunca executa comando privilegiado em validação. Ele só padroniza o caminho: `phasezero-admin <cmd>` ou `bigsudo <cmd>`.
- `oh-my-openagent` (OMO) é opt-in e nunca entra no `ai setup all`: é um harness de agentes autônomos de laço longo que gera tráfego de API pesado (a doc oficial recomenda Claude Opus, mas o esquema é neutro). O wrapper PhaseZero instala provider-agnostic (nenhuma assinatura forçada; nenhuma ToS de provedor é engajada até o usuário optar via `PZ_OMO_*`), deixa telemetria off por padrão e expõe `linux/pz ai omo disable` para desregistrar o plugin durante testes manuais longos, evitando consumo fantasma de tokens por sub-agentes ociosos. Ao habilitar um provedor, respeite os limites de taxa/uso dele — automações de alto volume podem violar políticas e levar a bloqueios de conta, independentemente do provedor.
- OMO Ultimate exige Bun e OpenCode ≥ 1.4.
- **Skew de versão OpenCode CLI↔desktop** (resolvido por `linux/pz ai opencode sync`): o repo `extra` traz `opencode` 1.17.7, mas `opencode-desktop-bin` (AUR) fica à frente (ex.: 1.17.11) e ambos compartilham o mesmo SQLite. O CLI antigo falha em `opencode run` com `no such column: replacement_seq` (schema já migrado pelo desktop; reproduzível com `--pure`, alheio ao OMO). Como o `extra` não acompanha, o PhaseZero fixa o CLI via npm (`opencode-ai@<versão-do-desktop>`) sombreando o pacote pacman em `~/.local/bin`, sem root, e oferece hook pacman para manter o lockstep em updates. O CLI **nunca** deve ficar mais novo que o desktop (migraria o DB e quebraria o desktop) — por isso o alvo é a versão exata do desktop, não `latest`.
