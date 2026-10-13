# Roadmap — Homelab umbrelOS-parity v1

> Fonte operacional única para agentes humanos e de IA nesta frente.
>
> Este documento coordena implementação. Não prova conclusão. Commits, testes,
> CI, artefatos e validações são as provas.
>
> Regras permanentes anti-poluição, limites de host, ordem das fontes de
> verdade e formato de handoff herdam de
> `docs/roadmaps/homelab-v1.15.1-remediation.md` e aplicam-se integralmente
> aqui.

## Metadados

| Campo | Valor |
|---|---|
| Status | Fase 6: disposable CI verde; runner skip do compose real; fault injection porta/cert |
| Última verificação | 2026-08-26, America/Sao_Paulo |
| Repositório | `/mnt/sdcard/Projects/PhaseZero` |
| Base observada | `origin/main` `a85c7a4` (release v1.17.4) |
| Pré-requisito Player v2 | cumprido: `f7746de` ancestral de `origin/main` via PR #70 (`1f86913`) |
| CI da base | run `32965735176` success em `a85c7a4` |
| Branch | `feat/homelab-umbrelos-v1` |
| Worktree | `/mnt/sdcard/Projects/pz-homelab-umbrelos-v1` (dedicado; não reutilizar WinVM nem `pz-homelab-v1151` / `pz-homelab-f9`) |
| Referência externa | https://umbrel.com/umbrelos — funções-alvo, não código |
| Decisão do operador | 2026-08-26: dois papéis de instalação (appliance vs admin/consumidor); acesso remoto fasado (SSH bridge → agente+mDNS); dashboard web completo; catálogo curado um clique por app |
| Release alvo | indefinida; tag não reservada |

Dados acima são snapshot, não pressupostos eternos. Todo agente deve revalidá-los.

## Missão

PhaseZero cobre as funções-chave do umbrelOS sem virar umbrelOS e sem perder
os invariantes já provados. Dois papéis, um produto: uma máquina instala o
projeto para **funcionar como homelab**; outra instala o mesmo projeto para
**administrar e consumir** esse homelab, com foco na experiência do usuário.

Funções-alvo: catálogo um clique por app, gestão multi-host a partir do
Player, dashboard web com login no host homelab, descoberta/pareamento, e
onboarding leigo. Nada disso reduz “funcional” a presença de arquivo, import
smoke, mock ou Compose válido — prova comportamental proporcional é
obrigatória.

## Papéis de instalação (dois hosts, um produto)

Esta é a decisão arquitetural 0 desta frente. umbrelOS é um appliance
acessado por navegador. PhaseZero entrega o appliance **e** um cliente de
administração de primeira classe.

```text
Dispositivos da casa (TV, celular, notebook)
        |  consomem Jellyfin / Vaultwarden / Nextcloud / ...
        v
┌───────────────────────────┐         LAN / Tailscale        ┌───────────────────────────┐
│  Host Homelab (appliance) │◄──────────────────────────────►│ Host Admin/Consumidor     │
│  PhaseZero instalado para │                                 │ PhaseZero instalado para  │
│  FUNCIONAR como homelab   │                                 │ ADMINISTRAR e CONSUMIR    │
│                           │                                 │ foco: experiência do user │
│  - compose + backups      │                                 │  - Player desktop         │
│  - Tailscale              │                                 │  - seletor de host        │
│  - agente + mDNS          │                                 │  - pareamento SSH/token   │
│  - dashboard web HTTPS    │                                 │  - cards / onboarding     │
│  - CLI pz do usuário      │                                 │  - Abrir dashboard        │
└───────────────────────────┘                                 └───────────────────────────┘
```

Regras dos papéis:

1. **Homelab (appliance).** Máquina que corre a stack. Headless ok. Equivalente
   operacional de umbrel.local. Roda compose, backups, Tailscale, agente
   user-level, dashboard web e anúncio mDNS. Nunca recebe apply desta frente
   no host de desenvolvimento.
2. **Admin/consumidor (Player).** Máquina em que o usuário senta. Instala
   PhaseZero pelo painel, não precisa ter Docker nem a stack local. Descobre,
   pareia, opera o homelab remoto e abre os apps. Experiência é o objetivo —
   o terminal fica como escape, não como caminho principal.
3. **Co-localização é opt-in, não o modelo.** Um único computador pode
   desempenhar os dois papéis (modo local, badge Local). O desenho trata os
   papéis como distintos para que o caso de duas máquinas funcione sem
   gambiarra.
4. **Host de desenvolvimento desta frente não é nenhum dos dois papéis em
   produção.** Worktree + CI descartável. Validação em segundo host real exige
   autorização explícita do operador.

## Escopo decidido

| Pilar umbrelOS | Entrega PhaseZero | Fase |
|---|---|---|
| App store one-click | Catálogo curado expandido, card por app (habilitar/atualizar/remover) | 1 |
| Acesso multi-dispositivo | Player no host admin opera homelab remoto (SSH bridge) | 2 |
| umbrel.local / descoberta | Agente leve + mDNS `phasezero-homelab._tcp` + pareamento por token | 3 |
| Dashboard web qualquer dispositivo | Web completo com login de usuário, mesmas ações do Player, no host homelab | 4 |
| Gestão de sistema | Página Servidor honesta (SMART/rede/disco) + onboarding guiado | 5 |
| Backups | Já verificado no roadmap v1.15.1 (HL-BKP-001); reaproveitar, expor na web | — |
| Tailscale | Já existe (`up --access tailscale`); permanece único caminho externo | — |
| Network sharing (SMB) | Deferred — decisão futura separada | — |

## Matriz extraída do umbrelOS (funções-alvo)

Fonte: https://umbrel.com/umbrelos e suporte umbrel (apps, backups, remote
access, files) em 2026-08-26. Não copiar chrome (dock, LiveTile, widgets).
Copiar a função que o leigo sente.

| Função umbrelOS | Em v1? | Mapeamento PhaseZero | Evidência |
|---|---|---|---|
| `umbrel.local` no browser, qualquer dispositivo da LAN | sim | dashboard web HTTPS no host homelab + mDNS | HL-WEB-*, HL-DSC-001 |
| App Store um clique (install/update/uninstall) | sim, catálogo **curado** (não a loja comunitária) | `apps enable/disable/update` + cards no Player/web | HL-APP-001..004 |
| Atualização de app por digest, sem `latest` | sim | lock/manifest por plataforma | HL-APP-004 |
| Gestão a partir de outro dispositivo | sim | Player no host admin; web no appliance | HL-HOST-*, HL-WEB-* |
| Login que protege a superfície de gestão | sim | usuários locais, sessão/CSRF; 2FA **deferred** | HL-WEB-001, HL-WEB-004, HL-WEB-006 |
| Backups + restore | reaproveitar | HL-BKP-001 já verified; expor no Player (já) e na web | HL-WEB-002 |
| Backups horários / Rewind de arquivo | não | deferred | — |
| Tailscale como único caminho fora de casa | manter | `--access tailscale`; sem UPnP/port-forward | HL-WEB-005 |
| Partilha SMB / Files app / NAS browser | não | deferred | — |
| Settings: RAM, disco, temperatura | sim, read-only honesto | página Servidor | HL-SRV-001 |
| Community app stores | não | catálogo no repo; contrib via PR | — |
| Bitcoin/Lightning/mempool | fora | não entra nesta frente | — |
| App permissions / dependências visíveis | parcial | orçamento governor + deps no manifest | HL-APP-002 |
| Credenciais default num diálogo | não nesta v1 | segredos só por referência | invariante v1.15.1 |
| OTA one-click do SO | fora | release canônica `packaging/release.sh` | Fase 8 |

Catálogo curado inicial = o que o compose já declara, promovido a cards
individuais. Não é a loja umbrel com centenas de apps.

| Camada atual | Serviços user-facing | Infra (não são cards) |
|---|---|---|
| core (`docker-compose.homelab.yml`) | jellyfin, syncthing, vaultwarden, uptime-kuma | — |
| extras (`docker-compose.extras.yml`) | portainer, nextcloud, grafana, prometheus, paperless, n8n | socket-proxy, nextcloud-db, node-exporter |

Hoje `up`/`down` sobe a camada inteira. Fase 1 parte isso em subconjunto.

`docker-compose.lock.json` pinna **tags**, não digests (`"no digest claims"`).
HL-APP-004 fecha esse buraco.

## Gap revalidado contra `origin/main` `a85c7a4`

CLI pública atual (`linux/pz` → `homelab-stack.sh` / `homelab-status.sh` /
`homelab-governor.sh`):

```text
pz server homelab status|verify|repair|plan|up|down|restart|open|logs
pz server homelab backup|restore|update|tailscale
pz server homelab profile list|set|get
pz server homelab governor ...
pz server homelab profiles
```

Ausente (esta frente cria):

```text
pz server homelab apps list|enable|disable|update --json
pz server homelab hosts add|list|remove|ping --json
pz server homelab --host <alias> <comando-homelab> [--json]
pz server homelab discover --json
pz server homelab agent install|uninstall|status|pair|revoke --json
pz server homelab web status|enable|disable --json
pz server homelab web user add|remove|password --json
```

Player (`linux/ui_native/pages/homelab.py`): tabela de serviços, perfil,
plan/up/down/backup/verify/restore com QProcess e restore via `--confirm-file`
(nunca `--yes` automático). Sem grid de cards por app, sem seletor de host,
sem pareamento SSH, sem “Abrir dashboard”.

Invariantes que permanecem: socket-proxy (nenhum serviço recebe
`/var/run/docker.sock` direto), redação de segredos, JSON no stdout / logs
no stderr, `schemaVersion`, lock atómico, sem apply no host de
desenvolvimento, Docker só em CI descartável.

## Decisões arquiteturais fechadas

0. **Dois papéis.** Ver seção “Papéis de instalação”. Código, CLI, UI e
   testes distinguem *onde a stack corre* de *onde o usuário administra*.
   Comando sem `--host` fala com o runtime local (papel appliance no mesmo
   sítio). `--host <alias>` fala com o appliance remoto (papel admin).
1. **Multi-host fasado.** Fase SSH primeiro (nenhum daemon novo); agente
   HTTP/TLS com descoberta depois. O Player nunca grava senha de host; usa
   chave SSH existente ou pareamento guiado de chave.
2. **Registro de hosts.** Arquivo local sob XDG no **host admin**,
   `schemaVersion`, escrita atómica `0600`, lock cross-process, IDs
   persistentes. Contém alias, `user@host` e metadados — nunca chaves
   privadas, senhas ou tokens de app.
3. **Agente.** `phasezero-agent` corre `systemd --user` no **host homelab**,
   como o usuário dono do runtime. TLS self-signed gerado localmente;
   token de pareamento aleatório exibido uma vez; allowlist FECHADA de
   comandos (subconjunto JSON do CLI homelab); rate limit; audit trail
   append-only; kill switch local. Nunca recebe `/var/run/docker.sock`,
   nunca corre como root, nunca executa shell arbitrário — só invoca `pz`
   do usuário.
4. **Dashboard web.** Serviço no **host homelab**, HTTPS obrigatório
   (certificado próprio), bind LAN explícito opt-in, usuários LOCAIS
   geridos por CLI/Player no host admin, hash de senha forte, sessão com
   expiração, CSRF, rate limit. Restore na web exige confirmação em duas
   etapas — nunca `--yes` automático. Sem UPnP, sem port-forward, sem
   exposição externa; fora de casa o caminho continua sendo Tailscale.
   Bootstrap da primeira conta é local (CLI/Player), nunca pela web aberta.
5. **Catálogo.** Manifest versionado por app dentro do repo (imagem pinada
   por manifest-list digest ou lock por plataforma, portas, volumes,
   healthcheck, camada, orçamento estimado, dependências de infra). Compose
   renderizado por subconjunto; segredos só por referência; nenhum socket
   direto; `latest` proibido.
6. **Descoberta.** mDNS via avahi quando habilitado; `os-slim.sh` pode
   desabilitar avahi em host headless — instalação do agente deve detectar,
   orientar e nunca reativar silenciosamente (mudança de serviço exige
   consentimento). Fallback sempre disponível: entrada manual `IP:porta`.
7. **Host de desenvolvimento intocado.** Nada disto corre no host dev antes
   da release; Docker só em CI descartável; validação em segundo host real
   exige autorização explícita do operador.

## Interfaces públicas mínimas

CLI mantém stdout JSON puro e logs em stderr. Novidades sobre o conjunto
existente de `pz server homelab`:

```text
pz server homelab apps list --json
pz server homelab apps enable <app> --json
pz server homelab apps disable <app> --json
pz server homelab apps update [<app>|--all] --json
pz server homelab hosts add <alias> <user@host> --json
pz server homelab hosts list --json
pz server homelab hosts remove <alias> --json
pz server homelab hosts ping <alias> --json
pz server homelab discover --json
pz server homelab --host <alias> <comando-homelab> [--json]
pz server homelab agent install|uninstall|status|pair|revoke --json
pz server homelab web status|enable|disable --json
pz server homelab web user add|remove|password --json
```

Contratos obrigatórios (acumulam com os do roadmap v1.15.1):

- `schemaVersion` em todo documento persistido ou público.
- Exit codes documentados; envelope JSON uniforme para resultado remoto
  (`{hostAlias, rc, payload, error}`) com timeout explícito.
- Apply/disable/update/removal idempotentes; operation ID persistente.
- Redação centralizada de segredos em toda saída, inclusive envelopes remotos.
- Host inalcançável ou versão remote incompatível falha fechado com razão
  accionável, nunca sucesso aparente.
- `--host` sem alias no registro falha fechado; alias local implícito não
  inventa entrada.

## Fases e gates

### Fase 0 — Fundação

Objetivo: base limpa e pré-requisitos cumpridos.

- Confirmar merge de `feat/homelab-player-v2` em `main`. **Cumprido:** PR #70
  em `1f86913`; ancestral `f7746de`; release v1.17.4 `a85c7a4`.
- Criar worktree dedicado de `origin/main`; branch `feat/homelab-umbrelos-v1`.
- Revalidar matriz abaixo contra o código atual; ajustar sem reutilizar IDs.
- Registrar WIP alheio existente e não tocá-lo (ver Estado vivo).
- Extrair funções umbrelOS → IDs PhaseZero (seção acima).
- Documentar os dois papéis de instalação.

Gate de saída:

- CI existente verde na base do branch (`a85c7a4` run `32965735176` success).
- Baseline hermética local da suíte homelab na worktree.
- Nenhum claim novo sem teste correspondente previsto na matriz.

### Fase 1 — Catálogo um clique por app

Objetivo: apps individuais instaláveis/atualizáveis/removíveis com orçamento
honesto. Corre no papel **appliance**; o Player no papel **admin** dispara as
ações (local ou via `--host` na Fase 2).

- Refactor de `linux/server/homelab-stack.sh` em módulos por app com manifest
  versionado (decisão 5).
- `apps list/enable/disable/update`; compose render por subconjunto; preflight
  do Resource Governor por app; card bloqueia com razão quando recusado.
- Player: grid de cards com estado real por app, ações com plan/preview,
  progresso e cancel; nenhum modal que bloqueie o event loop (padrões
  HL-UI-001/002 do v1.15.1 / Player v2).

Gate de saída:

- `docker compose config` válido para cada subconjunto testado em CI
  descartável.
- Teste prova enable→health→disable de um app sem afectar os demais.
- Update resolve digest por plataforma; nenhum `latest` renderizado.
- Segredos só por referência; socket-proxy inalterado.

### Fase 2 — Multi-host via bridge SSH

Objetivo: o Player no host **admin** opera o homelab no host **appliance**
via SSH, com pareamento guiado. Nenhum daemon novo.

- Registro de hosts conforme decisão 2 (vive no host admin).
- Envelope remoto: `--host <alias>` executa `ssh <user@host> -- pz …`;
  timeout; stderr separado; fail-closed offline; checagem de versão mínima
  remota antes de mutação.
- Pareamento guiado de chave SSH na UI (checa chave local, oferece
  `ssh-copy-id` via QProcess, testa conexão) — nunca bloqueia event loop,
  nunca pede senha em argv.
- HomelabPage: seletor de host no topo, badge Local/Remoto, diagnósticos sem
  segredos.

Gate de saída:

- Suíte hermética com stub de ssh prova envelope, timeout e fail-closed.
- Contrato: saída remota é JSON puro; erro de rede vira razão accionável.
- Gitleaks verde; registro contém zero material privado.

### Fase 3 — Agente remoto + descoberta mDNS

Objetivo: experiência umbrel-like de descobrir e parear sem terminal. O
agente vive no host **homelab**; o Player no host **admin** descobre e pareia.

- **ADR antes do código** (HL-AGT-004): threat model, schemas de API,
  armazenamento do token, expiração/revogação, auditoria, integração. Testes
  de contrato que falhem antes da implementação.
- `phasezero-agent` conforme decisão 3; API = allowlist fechada espelhando o
  CLI homelab (leitura + ações com confirmação).
- mDNS advertise `phasezero-homelab._tcp`; detecção de avahi desabilitado
  (conflito conhecido com `os-slim.sh`) com orientação explícita; fallback
  manual `IP:porta` sempre funcional.
- Painel: `discover`, pareamento colando o token, revogação, status do agente.

Gate de saída:

- Requisição sem token/expirada → negada (provado em teste).
- Revogação corta sessão activa (provado).
- Comando fora da allowlist → negado e auditado (teste tenta shell arbitrário).
- Rate limit dispara; kill switch local para o agente (provado).
- Fuzz básico de auth (HL-AGT-005).
- Nenhum segredo em stdout/stderr/logs/audit (gitleaks + scan).

### Fase 4 — Dashboard web completo

Objetivo: mesmas funções do Player no navegador, de qualquer dispositivo da
rede, servido pelo host **homelab**. Superfície nova maior — ADR de ameaça
antes do código.

- **ADR antes do código**: threat model de sessões/cookies/CSRF/senha,
  recuperação, bootstrap de conta.
- Serviço web conforme decisão 4; paridade de ações: status, cards de apps,
  up/down, backup, restore assistido em duas etapas, logs.
- Gestão de usuários locais via CLI/Player no host admin; primeira conta
  nunca nasce pela web.
- Player no host admin ganha “Abrir dashboard” do host selecionado (URL
  HTTPS do appliance).

Gate de saída:

- E2E descartável: login→ação→logout; senha fraca recusada; requisição sem
  CSRF/token → negada; cookie sem Secure/HttpOnly → falha de contrato.
- Restore na web nunca aplica sem confirmação explícita (teste prova).
- Bind padrão não é `0.0.0.0` sem opt-in explícito persistido.
- Secret scan verde.

### Fase 5 — Amigabilidade restante

Objetivo: página Servidor honesta e onboarding leigo no host **admin**.

- Página Servidor: SMART read-only (quando `smartctl` existir), rede, disco,
  temperatura; dado indisponível aparece como indisponível — nunca inventado.
- Onboarding guiado: descobrir host → parear → perfil/apps → revisão de
  segurança → aplicar.
- SMB sharing: permanece `deferred`.

Gate de saída:

- Página não apresenta dado fabricado (teste com sensores ausentes).
- Onboarding E2E com stubs completa sem toque no host real.

### Fase 6 — Testes e CI

Objetivo: provar resiliência sem tocar host real.

- Novos jobs seguindo o padrão atual do `ci.yml` (nomes finais na PR):
  validação de manifests/catálogo, shell dos hosts/envelope, Python do agente
  e da web, E2E descartável do web/agente.
- Fault injection mínimo adicional: host offline, ssh lento/morto, versão
  remota incompatível, certificado expirado, token inválido/expirado, porta
  ocupada, avahi ausente, agente morto no meio da operação, disco cheio.

Gate de saída:

- Suíte completa verde; `bash -n` global; ShellCheck 0.9.0 e 0.11.x com os
  excludes do CI; pytest completo; `git diff --check`; gitleaks.
- Nenhum `continue-on-error` em gate obrigatório.

### Fase 7 — Documentação

Objetivo: operação compreensível sem contexto de chat.

- Arquitectura dos dois papéis, bridge e agente, threat model agente+web,
  guia de pareamento e revogação, catálogo (como adicionar app), limitações
  honestas, release notes.

Gate de saída:

- Docs correspondem ao comportamento testado; nenhum “pronto/seguro/privado”
  sem prova citada.

### Fase 8 — Merge, release e pacote

Objetivo: publicar de forma reproduzível.

1. CI obrigatória verde na PR; PR documenta arquitectura, riscos, migrações,
   testes, limitações e rollback.
2. Merge squash em `main`; fluxo canônico `packaging/release.sh <versão>`;
   tag anotada nova (nunca mover tags históricas); 7 assets +
   `SHA256SUMS` conferidos por download real.
3. Instalação no host só com comando administrativo entregue ao usuário
   (`phasezero-admin pacman -U`), após SHA256 confirmado; nunca Polkit em
   background.
4. Validação pós-instalação: versão, imports UI, `profiles/status --json`,
   dry-runs; containers, serviços, listeners, mounts, `grubenv` e WinVM devem
   permanecer iguais.
5. Validação em segundo host real: somente com autorização explícita do
   operador e registrada no ledger.

## Matriz de evidência obrigatória

Cada requisito precisa de uma linha. Estados permitidos: `pending`,
`in_progress`, `blocked`, `verified`, `deferred`. Adicionar IDs novos; nunca
reutilizar ID para requisito diferente.

| ID | Requisito | Implementação | Teste comportamental | Prova CI | Estado | Limitação |
|---|---|---|---|---|---|---|
| HL-APP-001 | Apps individuais com manifest versionado e compose por subconjunto | `assets/home-server/apps/catalog.json` + `apps/compose/*.yml` + `linux/server/homelab-apps.sh` | compose config por subconjunto; enable/disable isolado no estado; job `homelab-apps-disposable` (vaultwarden health) | homelab-shell-test + compose-validate + homelab-apps-disposable | verified | catálogo curado; `tests/runner.sh` ignora scripts `# Disposable CI`; prova run `33009994646` |
| HL-APP-002 | Preflight de orçamento por card | governor soma enabled+app+deps vs RAM (headroom 20%); card desliga Ligar quando fail | `PZ_HOMELAB_RAM_TOTAL_OVERRIDE=256` recusa n8n com razão; não persiste | homelab-shell-test | in_progress | prova hermética local; aguarda CI |
| HL-APP-003 | UI cards um clique no Player (host admin) | grid no Player, Prévia/Ligar/Atualizar via QProcess | offscreen: 26 testes; preview spawna `apps enable --dry-run`; sem subprocess.run | homelab-python-test | in_progress | prova unitária local; aguarda CI |
| HL-APP-004 | Update por digest sem `latest` | lock+catálogo pinam tags; `apps update --dry-run` recusa `:latest`; digest só após pull permitido | render/catálogo sem `latest`; digest ainda não pinado no lock | compose-validate + shell test | in_progress | lock continua por tag; digest em `$HOMELAB_STATE/image-digests.json` após pull |
| HL-HOST-001 | Registro de hosts seguro no host admin | XDG, schemaVersion, atómico 0600, lock | segunda execução idempotente; corrupção falha fechado; zero material privado | homelab-shell-test | in_progress | prova hermética local; aguarda CI |
| HL-HOST-002 | Comandos remotos via `--host` fail-closed | envelope `{hostAlias, rc, payload, error}`, timeout ssh | stub ssh: offline→razão accionável; JSON puro | homelab-shell-test | in_progress | prova hermética local; aguarda CI |
| HL-HOST-003 | Pareamento guiado de chave SSH na UI | QProcess ssh-copy-id BatchMode, sem senha em argv | Player: seletor + badge Local/Remoto; source sem sshpass/--password | homelab-python-test | in_progress | E2E ssh-copy-id com stub ainda raso |
| HL-HOST-004 | Versão remota incompatível recusada antes de mutação | handshake `pz --version` remoto | stub `old` → rc 69, payload null | homelab-shell-test | in_progress | prova hermética local; aguarda CI |
| HL-DSC-001 | Descoberta mDNS com fallback manual | `discover --json` anuncia `phasezero-homelab._tcp`; nunca reativa avahi | avahi ausente → orientação + `wouldReenableAvahi:false` | test_homelab_agent_contract | in_progress | advertise real (avahi-publish) ainda não |
| HL-AGT-001 | Agente user-level TLS+token no host homelab | `homelab_agent.py`; token one-shot hashed; HTTPS 401 sem Bearer; unit `systemd --user` como ficheiro | sem/expirado → 401; HTTPS 401; unit WantedBy=default.target, sem systemctl no install | homelab-python-test | in_progress | install não arranca systemd no host; aguarda CI |
| HL-AGT-002 | Pareamento e revogação | pair consome token; revoke corta sessão HTTP | HTTP pair→status→revoke→401 | homelab-python-test | in_progress | prova local; aguarda CI |
| HL-AGT-003 | Allowlist fechada, audit, rate limit, kill switch | API allowlist; audit.log append-only; `shell=False`; kill file | shell arbitrário 403+audit; 429; kill 503 | homelab-python-test | in_progress | prova local; aguarda CI |
| HL-AGT-004 | Threat model ADR antes do código do agente | `docs/adr/0003-homelab-agent-mdns.md` | ADR versionado no repo | docs | in_progress | TDD vermelho isolado não foi commitado à parte |
| HL-AGT-005 | Fuzz básico de auth + agente sem socket/shell | corpus vazio/lixo/traversal; source sem docker.sock/`shell=True` | fuzz recusado; source prova `shell=False` | homelab-python-test | in_progress | prova local; aguarda CI |
| HL-WEB-001 | Dashboard web HTTPS com login local no host homelab | `homelab_web.py`; bind opt-in; argon2id (scrypt fallback); sessão/CSRF | login→ação→logout; CSRF ausente 403; cookie Secure/HttpOnly/SameSite=Strict | homelab-python-test | in_progress | HTML mínimo; 2FA deferred; serve não arranca systemd |
| HL-WEB-002 | Paridade de ações com restore em duas etapas | API status/apps/backup/logs/restore; never `--yes` | restore sem confirmação não chama pz; `--confirm-file` na apply | homelab-python-test | in_progress | paridade visual Player ainda rasa |
| HL-WEB-003 | “Abrir dashboard” do host selecionado no Player | botão; URL HTTPS local `127.0.0.1:17443` ou host do registro | URL local/remota; `QDesktopServices.openUrl` | homelab-python-test | in_progress | prova unitária; browser real não aberto nos testes |
| HL-WEB-004 | Senha fraca recusada | política em `web user add/password`; `--password-file` | rejeição com razão; hash nunca em HTML/audit | homelab-python-test + homelab-shell-test | in_progress | 2FA deferred |
| HL-WEB-005 | Bind LAN, sem UPnP/port-forward; externo só Tailscale | default loopback; `lanBind` persistido; zero UPnP | bind `0.0.0.0` sem opt-in → `127.0.0.1`; source sem upnp | homelab-python-test | in_progress | unit file só como ficheiro |
| HL-WEB-006 | Primeira conta nunca nasce pela web aberta | bootstrap CLI; `POST /signup` 403; login sem users 403 | E2E: web sem users recusa; CLI cria | homelab-python-test | in_progress | Player ainda não tem UI de `web user add` |
| HL-SRV-001 | Página Servidor honesta | `homelab-host-facts.sh` + cartão Hardware; SMART/rede/disco/temp | sensores ausentes → “indisponível”; sysfs 42 °C só com ficheiro | homelab-shell-test + python-test | in_progress | smartctl `-H` read-only; sem parse inventivo de `sensors -u` |
| HL-ONB-001 | Onboarding guiado ponta a ponta no host admin | wizard Player: discover→pair→profile→review→apply (`repair --json`) | E2E stubs; apply sem revisão não dispara; nunca `--yes` | homelab-python-test | in_progress | apply é repair/preview, não `up` no host |
| HL-BKP-001 | Backup/restore reversível | herdado do v1.15.1; expor na web na Fase 4 | já verified na CI disposable | homelab-shell-test + homelab-integration-disposable | verified | Rollback cobre dados de volume; `.env`/segredos fora do manifest. Rewind/horário deferred |

## Estado vivo

Actualizar esta seção no início e fim de cada sessão.

| Item | Estado atual | Verificado por | Data |
|---|---|---|---|
| Verificação70d959f | QA dark confirma UX-001..004 nos cenários locais; próxima UX-005/007/009 | `reports/verify-ux-70d959f/README.md` e validation.json | 2026-09-08 |
| Base | `origin/main` `a85c7a4` (v1.17.4) | `git fetch` + `git log origin/main` | 2026-08-26 |
| Player v2 | mergeado: PR #70 `1f86913`; `f7746de` ancestral | `git merge-base --is-ancestor f7746de origin/main` | 2026-08-26 |
| CI da base | success run `32965735176` | GitHub Actions `ci.yml` push `main` | 2026-08-26 |
| Branch/worktree | `feat/homelab-umbrelos-v1` em `/mnt/sdcard/Projects/pz-homelab-umbrelos-v1` | `git worktree list` | 2026-08-26 |
| Baseline local | `tests/linux-homelab.sh` exit 0; `test_homelab_player.py` 26 passed | worktree, 2026-08-26 | 2026-08-26 |
| Catálogo v1 | 10 apps user-facing; compose por módulo válido; enable/disable isolado; governor recusa host curto | `tests/linux-homelab.sh` + `docker compose -f apps/compose/*.yml config` | 2026-08-26 |
| WIP alheio (checkout principal) | untracked `.mimosa/`, `uber-defesa-privada/`; NÃO tocar `dashboard.py` nem `test_status_journey_contract.py`; NÃO stashar/commitar no checkout `feat/homelab-player-v2` | `git status` em `/mnt/sdcard/Projects/PhaseZero` | 2026-08-26 |
| Homelab real | segue sem workload desta frente; nenhum apply | herdado do v1.15.1; revalidar | 2026-08-26 |
| Catálogo atual | 10 apps user-facing em `apps/catalog.json`; `up --extras` ainda all-or-nothing; lock por tag | `assets/home-server/apps/` + compose legado | 2026-08-26 |
| Auditoria host limpo 2026-09-06 | main `2180c94`, v1.19.0; 31 itens abertos (1 P0 restore). Bootstrap incompleto, sucesso falso e divergências IA/proxies documentados; nenhum workload implantado | [relatório e provas](../../reports/portfolio-clean-host-2026-09-06/README.md); 364 pytest direcionados, 4 suítes shell, 13 Compose cliente, asset Arch verificado | 2026-09-06 |

## Ledger de execução

Adicionar uma linha por sessão material. Não apagar histórico.

| Data | Agente | Branch/worktree | Fase | Commit/PR | Gates | Resultado/próximo passo |
|---|---|---|---|---|---|---|
| 2026-09-08 | Codex | codex/verify-ux-70d959f, dedicada | verificação UX | base70d959f; docs via git log | QA dark800→1280→800; pytest-final/validation.json | aceite local; nenhum host mutado; próxima jornada simples |
| 2026-09-06 | Codex | `codex/portfolio-clean-host-audit` / `pz-portfolio-clean-host-audit` | diagnóstico transversal | documentação; base `2180c94` | 364 pytest; 4 shell; 12 registros reproduzidos; 2 contratos PS; 13 Compose válidos sem healthchecks declarados | PZ-AUD-001..031 pending; [plano/handoff](../../reports/portfolio-clean-host-2026-09-06/PLANO.md); priorizar integridade do restore e estados honestos. Nenhum runtime alterado |
| 2026-08-26 | opencode (checkout principal) | `feat/homelab-player-v2` (somente docs, sem commit) | rascunho | não commitado | — | rascunho untracked no checkout principal; não reutilizar |
| 2026-08-26 | grok | `feat/homelab-umbrelos-v1` `/mnt/sdcard/Projects/pz-homelab-umbrelos-v1` | 0 | `0ebc7cc` | CI base `32965735176` success; suíte hermética + player 23 passed | Roadmap + dois papéis. |
| 2026-08-26 | grok | `feat/homelab-umbrelos-v1` `/mnt/sdcard/Projects/pz-homelab-umbrelos-v1` | 1 | `02b1360` | suíte hermética + 26 player | catálogo um clique |
| 2026-08-26 | grok | `feat/homelab-umbrelos-v1` `/mnt/sdcard/Projects/pz-homelab-umbrelos-v1` | 1–2 | `192d2eb` | hosts stub + disposable script | CI 02b1360 vermelho (SC2016/SC2005); 192d2eb ainda a correr |
| 2026-08-26 | grok | `feat/homelab-umbrelos-v1` `/mnt/sdcard/Projects/pz-homelab-umbrelos-v1` | 3 | `179bd93` | python-test + homelab-python + shellcheck 0.11 verdes; **0.9.0 SC2015** | disposable skipped |
| 2026-08-26 | grok | `feat/homelab-umbrelos-v1` `/mnt/sdcard/Projects/pz-homelab-umbrelos-v1` | 3–4 | `98ddde9` | pytest 45 passed; SC2015 corrigido; HTTPS 401; unit user sem systemctl | ADR 0004. Disposable CI vermelho (compose stdout) |
| 2026-08-26 | grok | `feat/homelab-umbrelos-v1` `/mnt/sdcard/Projects/pz-homelab-umbrelos-v1` | 1+4 | `a8f7da1` | docker_cli stderr; contratos web CSRF/cookie/restore/bind; Player Abrir dashboard | CI 33006026031: python/homelab-python verdes; **shell-lint 0.11 SC2030**; disposable skipped |
| 2026-08-26 | grok | `feat/homelab-umbrelos-v1` `/mnt/sdcard/Projects/pz-homelab-umbrelos-v1` | 5 | `075abf4` | SC2030 via `env`; host-facts honestos; onboarding Player | CI 33009994646: lint/python/disposable verdes; **shell-test** falhou (runner globou disposable) |
| 2026-08-26 | grok | `feat/homelab-umbrelos-v1` `/mnt/sdcard/Projects/pz-homelab-umbrelos-v1` | 6 | este commit | runner skip `# Disposable CI`; porta ocupada + cert corrupto | CI shell-test + homelab-python-test |
| 2026-09-07 | ZCode | `codex/rev-remediation` (`pz-rev-remediation`) | R0 (revisão REV: onboarding Fase 5) | `87c31a1` (+ `8686279` backend) | pytest player 40 passed (6 regressões REV novas); contratos agent/web 38 passed | Correções de auditoria no onboarding do Player (HL-ONB-001): parser de documento único (pretty/compact/envelope `--host`), pair=false bloqueia avanço, plano amarrado a host capturado (troca de host invalida pair/revisão), perfil revisado transmitido via `prepare --profile`. Base `9d6be9d`; ver matriz em `docs/roadmaps/rev-remediation-v1.md`. |
| 2026-09-07 (2) | ZCode | `codex/rev-remediation` (`pz-rev-remediation`) | Contrarrevisão R01 (onboarding) | `b447312`, `6d8cf39` | pytest player 44 passed; suíte shell exit 0 2× | R01-002: pareamento tardio captura alias e descarta resultado de outro host (sem ingest/avanço/ping). R01-003: plano declara `profileInstallable/profileNote/profileServices/budget/appsSource` e UI exibe aviso ORÇAMENTO; `profile.active` documentado como seleção de orçamento, não entrega de appliance. |
| 2026-09-07 (3) | ZCode | `codex/rev-remediation` (`pz-rev-remediation`) | UX Player: confirmação e responsividade | `408d7e9`, `85bedf1` | pytest player 47 passed (E2E por cliques + geometria 800×600); windows_vm 30 passed | UX-001: revisão confirmável por botão visível (onboard_confirm_review ligado ao fluxo); UX-002: plano estável sob telemetria variável (intent hash, verdict fail bloqueia); UX-003: Player com scroll vertical global sem corte em 800×600; UX-004: página Windows VM reflow para 1 coluna com CTA intacto (afeta HL-ONB-001 e HL-APP-003). UX-005..011 permanecem planned na matriz REV. |
| 2026-09-07 (4) | ZCode | `codex/rev-remediation` (`pz-rev-remediation`) | Retorno ux004: confirmação e tema real | `c784373` | pytest player 49 + windows_vm 30 (aceite temático com alternância e hit-test real) | Duplicata de `_refresh_onboard_label` removida (causa-raiz do botão invisível); E2E exige visível E habilitado com clique via `widgetAt`; reflow de header/perfil/ações do Player e de hero/manutenção da página Windows validado com MainWindow + tema real (zero overflow horizontal na alternância 800→1280→800). |

## Formato obrigatório de handoff

Herdado integralmente de `docs/roadmaps/homelab-v1.15.1-remediation.md`
(§ Formato obrigatório de handoff). Handoff sem comandos/resultados
verificáveis não altera requisito para `verified`.

```text
Objetivo da sessão:
Fase/IDs assumidos:
Branch e worktree:
HEAD inicial:
HEAD final:
Arquivos alterados:
Commits criados:
Testes executados e resultados:
CI/PR:
Estado do host antes/depois:
Segredos verificados como ausentes:
Limitações e riscos restantes:
Bloqueios reais:
Próximo passo exacto:
```
