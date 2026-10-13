# Suite Linux de proxies de IA

## Estado

Implementada por `linux/ai/proxy-suite.sh`. Instalação é por usuário e não grava segredos no repositório.

```bash
linux/pz ai proxies status all
linux/pz ai proxies plan all
linux/pz ai proxies ensure kimiproxy
linux/pz ai proxies ensure qwenproxy --dry-run
linux/pz ai proxies ensure all
linux/pz ai proxies install kimiproxy
linux/pz ai proxies auth all
linux/pz ai proxies login kimiproxy
linux/pz ai proxies login qwenproxy
linux/pz ai proxies login deepsproxy
linux/pz ai proxies test deepsproxy
linux/pz ai proxies test all
linux/pz ai proxies restart kimiproxy
linux/pz ai proxies login all
linux/pz ai proxies detailed-status
linux/pz ai proxies provenance all
```

`ensure` é o fluxo de um clique da Central: instala se faltar, sobe o serviço e abre o Chromium só quando o proxy ainda precisa de login. Stdout é um JSON com `summary`/`next` para o modo simples; npm/git ficam no log. `ensure all` cobre Kimi, Qwen, DeepSeek e Mimo.

`detailed-status` devolve em um único JSON redigido instalação, serviço,
autenticação (`webValidation`), procedência e integração com IDEs. É o contrato
consumido pela página **Proxies IA**. O botão **Usar** dispara `ensure`;
`start`/`login`/`install` isolados ficam no modo avançado.

## Procedência fail-closed

Kimi, Qwen, DeepSeek e Mimo usam
`assets/ai/proxy-suite-trusted-sources.json`. Cada registro fixa repositório,
commit, árvore Git, licença e hashes dos lockfiles. Instalação busca o commit
exato em staging e valida antes de publicar o checkout. Atualização nunca segue
automaticamente a ponta da branch.

Antes de iniciar, reiniciar, autenticar, gravar credencial Mimo ou abrir uma IDE,
o backend revalida snapshot e alterações locais. Só o patch PhaseZero de bind em
loopback, acompanhado pelo próprio estado e backup, é aceito. Divergência bloqueia
a execução; `stop` permanece permitido.

`semanticAudit: false` é intencional: o manifesto prova identidade e integridade
do snapshot, não segurança semântica do código upstream. Os seis proxies legados
sem snapshot aprovado permanecem catalogados para diagnóstico, mas instalação e
execução novas são bloqueadas. 9Router mantém seu gerenciador de integridade
separado.

## Catálogo

Portas alinhadas ao catálogo Windows (3010-3013) para não colidir com open-webui/grafana (`:3000`) nem uptime-kuma (`:3001`). A antigravity-proxy saiu de `:8080` (reservada ao CEF do Steam, usado pelo Decky/CSS Loader) para `:8090`.

| ID | Upstream | Tipo | Porta PhaseZero |
|---|---|---|---:|
| `kimiproxy` | `pedrofariasx/kimiproxy` | Node | 3010 |
| `qwen-worker-proxy` | `aptdnfapt/qwen-worker-proxy` | Cloudflare Worker | externa |
| `qwenproxy` | `pedrofariasx/qwenproxy` | Node | 3011 |
| `antigravity-proxy` | `pedrofariasx/antigravity-proxy` | Node | 8090 |
| `antigravity-openai-adapter` | `pedrofariasx/antigravity-openai-adapter` | Node | 8081 |
| `ollieproxy` | `pedrofariasx/ollieproxy` | Node | 3002 |
| `airlock` | `pedrofariasx/airlock` | biblioteca Node | externa |
| `unlimited-ai-proxy` | `pedrofariasx/unlimited-ai-proxy` | Node | 8787 |
| `deepsproxy` | `pedrofariasx/deepsproxy` | Node | 3012 |
| `mimo-ai-proxy` | `pedrofariasx/mimo-ai-proxy` | Go | 3013 |

IDEs: `pz ai proxies configure-ides` conecta kimi/qwen/deeps/mimo ao OpenCode/OpenCode Desktop (providers `phasezero-*`), VS Code/Code-OSS via Continue e ZCode. O comando instala `Continue.continue` nos editores detectados, atualiza `~/.continue/config.json` preservando modelos externos e grava `~/.config/phasezero/ai-proxies/ide-defaults.env`. O chat via proxy exige sessão web válida. `pz ai proxies auth` distingue sessão presente, login em andamento e autenticação validada; `pz ai proxies test <id>` é um probe real e restrito ao alvo (`/v1/models` + chat).

## Portabilidade

- Checkouts: `~/.local/share/phasezero/ai-proxies/<id>`.
- Wrappers: `~/.local/bin/<id>`.
- Units: `~/.config/systemd/user/phasezero-<id>.service`.
- Ambientes: `~/.config/phasezero/ai-proxies/<id>.env`.
- Bind: wrappers PhaseZero definem `PZ_BIND_HOST=127.0.0.1` por padrão; `qwenproxy` usa `HOST`, e Kimi/Deep/Mimo recebem patch compat local para honrar loopback em vez de expor `0.0.0.0`.
- Node: runtime 24 isolado em `.runtime/node24`; não depende da versão Node global.
- Playwright: Chromium de usuário é instalado para KimiProxy, QwenProxy e DeepsProxy.
- Go: build nativo em `.phasezero-bin`.
- Atualização: somente por mudança revisada do manifesto. Branch móvel e
  fast-forward automático não são aceitos.
- Paridade Windows: portas 3010-3013, `webValidation.required/kind/status`, provider OpenAI-compatible e ausência de segredos no resultado JSON seguem o contrato do `ai-proxy-suite` em PowerShell.

Node com `start` baseado em `dist/` recebe build TypeScript. Worker e biblioteca recebem dependências, sem serviço local inventado. Serviços locais são instalados desativados.

## Credenciais e ativação

Cada upstream mantém seu próprio login, token ou fluxo OAuth. PhaseZero não fabrica credenciais e não grava segredos no repositório.

### Browser-session: Kimi, Qwen e DeepSeek

```bash
linux/pz ai proxies auth kimiproxy
linux/pz ai proxies login kimiproxy
linux/pz ai proxies login qwenproxy
linux/pz ai proxies login deepsproxy
linux/pz ai proxies test
```

`login` abre Chromium real/visível via Playwright (`npm run login`) e para o serviço user antes de abrir o browser para evitar lock do perfil em modo headless. Cliques repetidos reutilizam o fluxo em andamento. Se chat real já responde, login não reabre. Ao fechar o fluxo, `phasezero-<id>.service` reinicia automaticamente e reaproveita cookies/sessão salvos. Logs ficam em `~/.local/state/phasezero/ai-proxies/<id>-login.log`; estado fica em `<id>-login.json`.

`qwenproxy` tem menu interativo antes do browser. PhaseZero seleciona o fluxo manual de browser e fornece um rótulo local gerado; o login real continua no Chromium visível.

### Env-session: Mimo

```bash
install -d -m 700 ~/.config/phasezero/ai-proxies
$EDITOR ~/.config/phasezero/ai-proxies/mimo-ai-proxy.env
linux/pz ai proxies auth mimo-ai-proxy
linux/pz ai proxies start mimo-ai-proxy
```

Mimo não usa browser login. Ele exige grupos de sessão Mimo/Xiaomi no `.env` local do usuário. O JSON de `auth` mostra apenas grupos genéricos faltantes (`service-token-group`, `user-id-group`, `chatbot-ph-group`), nunca nomes exatos de variáveis nem valores.

### Integrações legadas

`qwen-worker-proxy`, Antigravity, Ollie, Airlock e Unlimited permanecem visíveis
no inventário histórico. Sem snapshot aprovado, `plan` mostra `blocked` e o
backend não baixa nem executa esses códigos.

Teste de catálogo e dry-run: `tests/linux-ai-proxies.sh`.
