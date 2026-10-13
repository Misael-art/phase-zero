# Roadmap canônico — Homelab v1.15.1

> Fonte operacional única para agentes humanos e de IA.
>
> Este documento coordena implementação. Não prova conclusão. Commits, testes,
> CI, artefatos e validações são as provas.

## Metadados

| Campo | Valor |
|---|---|
| Status | Planejado; implementação ainda não aceita como concluída (appliance NÃO está done) |
| Última verificação | 2026-08-23, America/Sao_Paulo |
| Repositório | `/mnt/sdcard/Projects/PhaseZero` |
| Base observada | `main` em `ea9b927` (repo version.json 1.16.6); revalidar |
| Release instalada observada | snapshot desatualizado removido; conferir `pacman -Q phasezero-control-center` antes de mutar |
| Release pública observada | v1.16.x na main; conferir GitHub antes da release |
| Branch rejeitada | `codex/homelab-appliance` em `d24b233` |
| PR rejeitada | `#36`, aberta, conflitante, CI vermelha |
| Tag reservada | `v1.15.0`; não mover, apagar ou recriar |
| Release alvo | `v1.15.1`, somente a partir de `main` verde |
| Branch de remediação | `codex/homelab-v1151-remediation` |

Dados acima são snapshot, não pressupostos eternos. Todo agente deve revalidá-los.

## Missão

Entregar Homelab PhaseZero coeso, resiliente, seguro e amigável sem implantar os
workloads no host de desenvolvimento. Entrega inclui fundação, perfis, operações,
Player, segurança, backup/restore, Resource Governor, testes, documentação, merge,
release e validação do pacote instalado.

Nenhum agente pode reduzir “funcional” a presença de arquivo, import smoke, mock ou
Compose válido. Comportamento exige prova comportamental proporcional.

## Ordem das fontes de verdade

Quando houver conflito, usar esta ordem:

1. Estado vivo de `main`, GitHub, CI, releases, pacote e host.
2. Este roadmap versionado.
3. Código e schemas versionados no repositório.
4. Findings do reviewer acompanhadas de reprodução.
5. Documentação histórica e `ai-memory`.
6. Resumos, chats e retornos de agentes apenas como contexto.

O arquivo histórico `tool_fcfd9c5d4001YpNoFLb9Fx0EOq` não é prompt puro. O
contrato original estava entre as linhas 642 e 1708; o restante contém conversa e
avaliações. Nunca tratar as 1908 linhas inteiras como especificação.

## Regras permanentes anti-poluição

### Antes de alterar

1. Ler `AGENTS.md` e referências integralmente.
2. Consultar `ai-memory` para Homelab, release, Docker security, worktree bleed e
   conflito de recursos com WinVM.
3. Revalidar Git, branches, worktrees, tags, PR, CI e releases.
4. Registrar arquivos modificados e untracked antes do trabalho.
5. Verificar processos/agentes concorrentes e worktrees existentes.
6. Criar worktree dedicado. Nunca reutilizar worktree de WinVM ou outra frente.
7. Executar baseline dos gates afetados antes da primeira mudança.

### Durante alterações

- Uma responsabilidade por commit.
- Nunca usar `git add -A` ou staging indiscriminado.
- Nunca sobrescrever, limpar, stashar ou commitar WIP alheio.
- Nunca force-push.
- Nunca editar tag antiga.
- Nunca copiar runtime manualmente para `/usr/lib/phasezero`.
- Nunca introduzir `latest` como dependência estável.
- Nunca adicionar segredo, token, senha ou material privado ao Git, logs ou testes.
- Alteração fora do escopo exige prova da dependência e registro no handoff.
- Arquivos WinVM ficam fora de escopo, salvo interface mínima do Resource Governor
  aprovada por teste de contrato.
- Gate vermelho interrompe avanço da fase. Corrigir causa; não mascarar.
- Falha “preexistente” exige reprodução em `main` limpo.

### Depois de cada unidade de trabalho

1. Executar testes específicos e regressões afetadas.
2. Executar `git diff --check`.
3. Revisar diff por segredos, paths do host e mudanças não relacionadas.
4. Atualizar somente as seções `Estado vivo` e `Ledger de execução` deste roadmap.
5. Produzir handoff no formato definido no fim do documento.

## Limites operacionais do host

Até a release ser publicada e verificada:

- Não executar `homelab apply`, `homelab up` ou `docker compose up` no host real.
- Não criar, apagar ou reiniciar containers e serviços reais.
- Não tocar no container `ai-memory` existente.
- Não instalar ou configurar Ollama, Hermes, OpenClaw, Dify, n8n ou Tailscale.
- Não alterar firewall, GRUB, `grubenv`, SDDM, WinVM, mounts ou discos.
- Não reiniciar host ou guest.
- Não usar `rsync`, `cp` ou symlinks para atualizar runtime privilegiado.
- Testes Docker executam somente em CI descartável com projeto, portas, volumes e
  cleanup próprios.

Após release, somente pacote PhaseZero pode ser instalado. Workloads continuam
desligados.

## Decisões arquiteturais fechadas

### Runtime e identidade

- Runtime instalado vem de `/usr/lib/phasezero`.
- Serviços usam usuário/grupo alvo explícitos; nunca criam estado em `/root`.
- `HOME` e paths XDG são explícitos.
- Estado e operações têm schema versionado, lock atômico e IDs persistentes.
- Erro essencial produz falha e estado degradado; nunca sucesso aparente.

### Docker e imagens

- Nenhum serviço recebe `/var/run/docker.sock` diretamente.
- Portainer usa socket proxy de privilégio mínimo ou fica indisponível.
- Imagem estável usa manifest-list digest ou lock por plataforma.
- Adapter experimental pode usar versão fixa resolvida para digest, nunca `latest`.
- Compose renderizado não contém segredos.
- Redes internas, healthchecks, readiness, limites, rotação de logs,
  `no-new-privileges` e `cap_drop` são padrão quando suportados.

### Segredos e backup

- Aplicações recebem referências, não segredos copiados entre arquivos.
- Entrada de segredo usa UI protegida ou stdin/fd; nunca argv.
- Backup de segredos exige formato autenticado, KDF, rotação e teste de senha
  incorreta. Implementação requer ADR antes do código.
- Restore sempre oferece `--plan`, valida antes de escrever, faz backup prévio e
  rollback automático após falha parcial.

### Maturidade

- Estável somente após E2E representativo.
- Integração que exige credencial/canal real permanece preview até teste do operador.
- Recursos sem prova ficam `preview`, `experimental` ou `blocked` no status e UI.
- ZeroClaw, NanoClaw e CrewAI permanecem experimentais/templates.
- Vellum, memU e MimiClaw permanecem integração externa/documentação até backend
  local auditado.

## Arquitetura-alvo

```text
Clientes e canais
      ↓
Acesso autenticado: loopback, Tailscale ou proxy TLS
      ↓
Um gateway: Hermes | OpenClaw | ZeroClaw
      ↓
PhaseZero Policy Broker
      ↓
9Router
      ↓
Ollama local | providers externos
      ↓
Memória, workflows e workers isolados
```

Invariantes:

- Um gateway principal por perfil.
- 9Router roteia modelos; não executa ação privilegiada.
- `ai-memory` é memória canônica PhaseZero.
- n8n não recebe shell irrestrito ou Docker socket.
- OpenHands executa por tarefa em sandbox efêmero.
- LangGraph assume fluxos críticos, persistência, retry e aprovação humana.
- CrewAI fornece templates; não duplica runtime LangGraph.

## Perfis públicos

| Perfil | Objetivo | Componentes principais | Maturidade inicial |
|---|---|---|---|
| `assistant-private` | Assistente local privado | Hermes, 9Router, Ollama, ai-memory, OpenWebUI opcional | Preview até E2E |
| `assistant-multichannel` | Canais externos supervisionados | Hermes; OpenClaw avançado; pairing e allowlist | Preview |
| `automation` | Workflows auditáveis | n8n, PostgreSQL, LangGraph | Preview |
| `ai-studio` | Dify isolado | Dify, DB, Redis, vector store, 9Router/Ollama | Pesado; desligado |
| `developer` | Coding assistido | Aider padrão, OpenHands sob demanda | Preview |
| `edge` | Gateway leve supervisionado | ZeroClaw, modelo remoto via 9Router | Experimental |

Nenhum perfil pesado sobe por padrão. Host sem orçamento recebe `blocked` com razão e
plano de impacto.

## Interfaces públicas mínimas

CLI deve manter stdout JSON puro e logs em stderr:

```text
pz server homelab profiles --json
pz server homelab plan --profile <id> --json
pz server homelab apply --profile <id> --json
pz server homelab status --json
pz server homelab verify --json
pz server homelab repair --json
pz server homelab backup --json
pz server homelab restore --plan --json
pz server homelab rollback --operation-id <id> --json
pz server homelab player
pz server homelab resource-status --json
pz server homelab security-audit --json
```

Contratos obrigatórios:

- `schemaVersion` em todos documentos persistidos ou públicos.
- Exit codes documentados.
- Paths canônicos.
- Lock cross-process.
- Operation ID persistente.
- Apply, repair, cancel, attach, resume e rollback idempotentes.
- Redação centralizada de segredos.

## Fases e gates

### Fase 0 — Baseline e recuperação da rejeição

Objetivo: estabelecer base limpa e reproduzível.

- Criar worktree da `origin/main` atual.
- Criar `codex/homelab-v1151-remediation`.
- Extrair requisitos históricos para matriz versionada.
- Reproduzir ShellCheck, Pester e demais falhas da PR #36.
- Portar seletivamente código válido; não carregar metadata release prematura.
- Corrigir bugs confirmados: ShellCheck, Pester, `QFileDialog`, bloqueios GUI e restore
  com confirmação cega.
- Abrir novo PR que substitui #36. Fechar #36 somente após novo PR existir.

Gate de saída:

- Baseline documentado.
- CI existente totalmente verde no novo PR.
- Nenhum claim de feature nova sem teste.
- Tag `v1.15.0` intacta.

### Fase 1 — Fundação operacional

Objetivo: runtime, identidade, configuração e lifecycle confiáveis.

- Usuário/grupo, HOME e XDG corretos.
- Configuração e `accessMode` persistentes com migração idempotente.
- `up/down/restart/update/repair/cancel/resume` no mesmo conjunto de serviços.
- Lock atômico e recuperação de operação interrompida.
- Status verdadeiro: installed, configured, active, healthy, ready, degraded,
  reasons, endpoints, versões, digests, orçamento, conflitos e rollback.
- Mídia via XDG pt-BR, permissões e mounts read-only.

Gate de saída:

- Nada escrito em `/root`.
- Segunda execução idempotente.
- Crash→resume e cancel seguros.
- Estado corrompido falha fechado.
- Testes shell/Python/Pester afetados verdes.

### Fase 2 — Compose e serviços

Objetivo: stacks completas e endurecidas.

- Redes internas e exposição loopback por padrão.
- Healthchecks e readiness reais.
- Digests/lock por plataforma.
- Socket proxy para Portainer.
- Jellyfin com mídia read-only e `/dev/dri` somente após preflight.
- Nextcloud com Redis, cron e trusted proxies.
- Paperless com Valkey e ingest/export.
- n8n com PostgreSQL, encryption key e controles SSRF/nodes.
- Prometheus com configuração; Grafana com datasource/dashboard/alertas.
- Uptime Kuma provisionado idempotentemente.

Gate de saída:

- `docker compose config` em todos perfis.
- Nenhuma porta pública inesperada.
- Nenhum socket direto ou segredo renderizado.
- Integração CI descartável prova health→degraded→repair.

### Fase 3 — Backup e restore

Objetivo: backup consistente e restore reversível.

- Preflight recusa `/`, `$HOME`, symlink escape e destino dentro da origem.
- Quiesce ou dumps nativos para PostgreSQL, MariaDB e SQLite.
- Staging seguro, manifestos, versões, digests, checksums e timestamps ISO.
- Segredos cifrados conforme ADR.
- Retenção configurável e adaptador offsite opcional.
- Restore plan, validação de compatibilidade, limpeza controlada, backup prévio,
  rollback automático e relatório.

Gate de saída:

- CI prova backup→destruição de fixture→restore→dados iguais.
- Checksum inválido, senha incorreta e versão incompatível falham fechados.
- Falha parcial restaura estado anterior.

### Fase 4 — Perfis e Resource Governor

Objetivo: seleção amigável com orçamento honesto.

- Implementar os seis perfis públicos.
- Inventariar CPU, MemAvailable, swap, GPU/VRAM, disco, I/O e temperatura.
- Classes: always-on-light, local-inference, automation, heavy-studio,
  coding-worker e winvm.
- WinVM tem prioridade configurável; conflito gera plano de impacto.
- Suspensão é graciosa, persistida e retomável. Nunca kill silencioso.

Gate de saída:

- Host limitado recusa perfil pesado com razão verificável.
- Falha de stop aparece no status.
- Resume correto após término da WinVM.
- Nenhum arquivo WinVM alterado sem teste de contrato.

### Fase 5 — AI e Policy Broker

Objetivo: adapters mínimos e enforcement real.

- `ai-memory`: digest, mounts mínimos, histórico read-only, sem `$HOME`, limites,
  healthcheck e migração preservando dados.
- Ollama: loopback, escolha explícita, espaço, progresso/cancel/resume e benchmark.
- Hermes: versão/checksum, pairing, allowlist, aprovação manual e workspace mínimo.
- OpenClaw: sandbox total, install policy fail-closed, skills/plugins desligados.
- Dify, OpenHands, Aider, LangGraph e ZeroClaw conforme maturidade declarada.
- Policy Broker: identidade, classificação de ação, aprovação, secret references,
  audit trail, quotas, rate limits, timeouts, kill switch, egress, denylist,
  symlink protection e idempotency keys.

Antes do código do broker:

- Criar ADR de schemas, storage, aprovação, auditoria, expiração e integração.
- Adicionar testes de contrato que falhem antes da implementação.

Gate de saída:

- SSH, credenciais cloud, `.env` e outros projetos invisíveis aos adapters.
- Ação não confiável bloqueada por padrão.
- Nenhum segredo em stdout, stderr, logs, estados ou snapshots.
- Integrações sem E2E real permanecem preview/experimental.

### Fase 6 — Homelab Player

Objetivo: experiência gráfica não bloqueante e recuperável.

Fluxo:

```text
Discover → Select → Preflight → Configure → Security review
→ Plan → Confirm → Apply → Validate → Done
```

- PySide6 não modal e singleton.
- QProcess/QThreadPool para toda operação externa.
- stdout/stderr separados, timeout e proteção contra double emit.
- Wizard por perfil, custos, orçamento, privacidade, canais e segredos protegidos.
- Operation ID, attach, resume, cancel, repair e rollback.
- Close event interrompe polling, não operação persistente.
- Restore nunca passa `--yes` automaticamente.
- Diagnóstico exportado sem segredos.

Gate de saída:

- Import, singleton, lifecycle, timeout, close, cancel, attach, resume, repair,
  rollback e secret redaction testados.
- Teste prova event loop responsivo durante subprocesso lento.

### Fase 7 — CLI e schemas

Objetivo: compatibilidade e contratos públicos finais.

- Consolidar comandos mínimos listados acima.
- Publicar JSON schemas.
- Documentar exit codes, migração e compatibilidade.
- Garantir JSON puro e idempotência.

Gate de saída:

- Contract tests shell/Python/Pester.
- Snapshots não contêm valores específicos do host ou segredos.

### Fase 8 — Testes e CI

Objetivo: provar resiliência sem tocar host real.

Jobs obrigatórios:

- `homelab-shell-test`
- `homelab-python-test`
- `compose-validate`
- `homelab-integration-disposable`
- `security-secret-scan`
- `package-smoke`

Fault injection mínimo:

- Docker indisponível.
- Imagem ausente ou pull interrompido.
- Disco cheio simulado.
- Porta ocupada.
- Banco ou serviço unhealthy.
- Estado corrompido.
- Permissão negada.
- Timeout e processo morto.
- Rede offline.
- Segredo ausente.
- Versão incompatível.

Gate de saída:

- Python completo.
- `tests/runner.sh`.
- Pester.
- `bash -n` em todos scripts.
- ShellCheck 0.9.0 e 0.11.x com os mesmos excludes do CI.
- `git diff --check`.
- Compose e JSON schemas válidos.
- Gitleaks/secret scan.
- Package build e install-root test.
- Nenhum `continue-on-error` em gate obrigatório.

### Fase 9 — Documentação

Objetivo: operação e limitações compreensíveis sem contexto de chat.

- Arquitetura e perfis.
- Matriz de suporte e recursos.
- Threat model e policy de skills/plugins.
- Segredos, rede e acesso.
- Backup, restore e disaster recovery.
- Governor e conflitos WinVM.
- Operação sem UI, troubleshooting e rollback.
- Limitações honestas e release notes.

Gate de saída:

- Documentação corresponde ao comportamento testado.
- Nenhum uso de “pronto”, “seguro”, “privado” ou “funcional” sem prova citada.

### Fase 10 — Merge, release e pacote

Objetivo: publicar v1.15.1 de forma reproduzível.

1. CI obrigatória totalmente verde no PR.
2. PR documenta arquitetura, riscos, migrações, testes, limitações e rollback.
3. Merge em `main`.
4. Atualizar `main` e confirmar árvore limpa.
5. Executar fluxo canônico `packaging/release.sh 1.15.1`.
6. Criar tag anotada `v1.15.1`; preservar `v1.15.0`.
7. Exigir CI, release e gitleaks verdes.
8. Confirmar sete assets:
   - source tarball
   - `.deb`
   - `.rpm`
   - `.pkg.tar.zst`
   - `.AppImage`
   - `.flatpak`
   - `SHA256SUMS-1.15.1`
9. Baixar assets e verificar checksums e conteúdo básico dos pacotes.
10. Entregar comando administrativo ao usuário. Não esperar Polkit em background.

Comando esperado, somente após SHA256 confirmado:

```bash
phasezero-admin pacman -U --noconfirm <phasezero-control-center-1.15.1-1-any.pkg.tar.zst>
```

Depois da confirmação do usuário, validar somente:

- versão;
- imports UI;
- arquivos e checksum do runtime instalado;
- `profiles --json`;
- `status --json`;
- `plan --profile assistant-private --json`;
- dry-runs dos outros perfis.

Containers, serviços, listeners, mounts, `grubenv` e WinVM devem permanecer iguais.

## Matriz de evidência obrigatória

Cada requisito precisa de uma linha. Não aceitar relatório narrativo sem matriz.

| ID | Requisito | Implementação | Teste comportamental | Prova CI | Estado | Limitação |
|---|---|---|---|---|---|---|
| HL-F0-001 | Baseline reproduzível | Worktree dedicado + 19 commits por fase | Suíte hermética exit 0; pytest 437; smoke | `homelab-*` verdes em `main` (run `31257317111`, merge `3cb05fb`) | verified | — |
| HL-RUN-001 | Estado nunca em `/root` | `boot-prepare`/ops com HOME/XDG explícitos | `tests/linux-homelab.sh` (identity; boot-prepare) | homelab-shell-test | verified | — |
| HL-CMP-001 | Nenhum Docker socket direto | `socket-proxy` (read-only, allowlist) + Portainer via `DOCKER_HOST` | Suíte: compose pins/binds/hardening; compose-validate assina `socket-proxy` ro=true apenas | compose-validate | verified | — |
| HL-BKP-001 | Restore reversível | manifest schemaVersion 2 + verify-then-apply + snapshot prévio `<source>.pre-restore` + rollback automático em falha parcial (`rollbackApplied`); `status` ignora `*.pre-restore` | Suíte: tamper fail-closed, restore sem `--yes` recusa, verify antes de aplicar, falha parcial com volume envenenado → estado prévio devolvido; E2E Docker: backup→destroy→restore→igualdade byte a byte | homelab-shell-test + homelab-integration-disposable (PR #38, run `31265085899` success) | verified | Rollback cobre dados de volume; `.env`/segredos fora do manifest |
| HL-GOV-001 | WinVM gera suspensão graciosa | governor: `winvm-status`/`winvm-suspend [--dry-run]`/`winvm-resume`; boundary `PZ_HOMELAB_WINVM_STATUS_FILE` ou `pz windows-vm status --json`; `winvmMB` (default 2048) descontado do orçamento; suspensão só via QGA (`PZ_HOMELAB_WINVM_SUSPEND_CMD`, default `guest-login shutdown --json`); `killUsed:"never"`; nenhum arquivo da VM tocado | Suíte: seção "winvm contract" (idle/active via stub, fail-closed com guest ativa, plano de impacto, dry-run sem efeito, execução capturada, no-op idle, resume) | homelab-shell-test (PR #38, run `31265085899` success) | verified | Maturação real da suspensão depende de guest Windows real (não exercitada em CI) |
| HL-SEC-001 | Segredos ausentes das saídas | repair gera `.env` sem leak; redação no status | Suíte: valor secreto ausente do JSON de repair | security-secret-scan (gitleaks) verde em `main` e no release | verified | — |
| HL-UI-001 | Player não bloqueia event loop | async QProcess; separado stdout/stderr; timeout | 13 testes do player (offscreen) incl. spawn/close/timeout | homelab-python-test | verified | — |
| HL-UI-002 | Interface leiga com revelação progressiva | modo simplificado padrão; comandos/logs/JSON recolhidos; páginas visuais Windows VM, Waydroid, Servidor e Saúde; modo avançado global | pytest 428 + 9 subtestes; UI smoke 27; provision 226/0; QA offscreen de 6 superfícies | PR #48: CI `31327861952` e gitleaks verdes; `main` `31329472867` verde | verified | Sliders de recursos são somente leitura enquanto backend não expõe mutação tipada segura |
| HL-WIN-GFX-001 | Instalação WinVM aceita somente perfis gráficos executáveis | manifesto `windows-vm-graphics/v1` compartilhado; plan/start revalidam; UI filtra `provisionSupported`; Venus permanece plan-only | pytest 449 + 9; runner 39/39; provision 248/0; preflight host `compat`/`virtio-gl` true e Venus false; operação real alcançou `setup` 50% | PR #54; CI main `31501159700` success; release `31501162559` success | verified | Setup WinPE usa QXL deliberadamente; perfil `virtio-gl` aplica-se ao relaunch da VM instalada |
| HL-IMG-001 | Jornada leiga de imagem: achar ISO, ler edições por índice, reproduzir, habilitar no boot, restaurar GRUB e remover com segurança | `image_registry.py` (registro versionado `schemaVersion 1`, escrita atômica 0600, idempotente por `sha256`, fail-closed em versão futura); `media scan --json` aditivo em `media-inspect.sh` (bases canônicas de `detect_windows_iso`, `maxdepth 4`); `ImageManagerDialog` reutiliza `media inspect`, `ProvisionPlayerWindow.open`, `windows.boot.install` e `boot.safe-menu`; action `windows.images.manage` (não-elevada, não-mutável) interceptada no `main_window` | `tests/test_image_registry.py` (19); `tests/test_image_manager_dialog.py` (19, incl. regressões de índices 1–10 sem WIM legível, `moveToTrash` tupla, lote que não aborta e botão primário inerte); `tests/test_windows_vm_ui.py` (botão emite a action); `tests/linux-windows-vm.sh` (scan dedupe + schema de `inspect` inalterado); prova de host: `media scan` → `inspect` → 10 edições → reproduzir habilitado, com estado em diretório temporário | PR #55 run `31526162284` success (29 checks, 0 falhas) + gitleaks `31526162389`; merge `9e5f3be` | in_progress | Remoção de arquivo só via `QFile.moveToTrash` (reversível) e sempre com consentimento; boot/GRUB continuam passando pelo fluxo elevado com preview, nunca com `--yes` automático. Nomes de edição continuam ilegíveis em mídia de varejo (limitação de `media inspect`); a numeração 1–10 é o contorno já usado pela instalação. Registro não é seguro contra escritor concorrente (um único escritor por desenho) |

Adicionar IDs, nunca reutilizar ID para requisito diferente. Estados permitidos:
`pending`, `in_progress`, `blocked`, `verified`, `deferred`.

## Estado vivo

Atualizar esta seção no início e fim de cada sessão. Não alterar metadados históricos
sem evidência.

| Item | Estado atual | Verificado por | Data |
|---|---|---|---|
| Verificação70d959f | QA dark confirma UX-001..004 nos cenários locais; próxima UX-005/007/009 | `reports/verify-ux-70d959f/README.md` e validation.json | 2026-09-08 |
| `main` | `31642be`, alinhada com `origin/main` | `git status`, `ls-remote` | 2026-08-07 |
| `main` | `c11155b`, alinhada com `origin/main` | `git status`, `ls-remote` | 2026-08-08 |
| PR #38 | mergeada via squash (`fc7ede8`); branch local/remota apagadas; worktree `pz-homelab-f9` preservado | `gh pr view 38`, `git ls-remote`, `git worktree list` | 2026-08-08 |
| CI pós-merge | run `31266597239` (ci) + `31266597234` (gitleaks) success em `main` | `gh run view` | 2026-08-08 |
| Pendências Fase 2/3/9 | implementadas; CI run `31265085899` 14/14 success | `gh run view 31265085899` | 2026-08-08 |
| CI homelab | + job `homelab-integration-disposable` (E2E Docker real, sudo, seed→backup→verify→destroy→restore→igualdade) | ci.yml, run `31265085899` | 2026-08-08 |
| Suíte hermética | exit 0 incluindo "winvm contract" e "restore partial failure rolls back" | bash | 2026-08-08 |
| Worktree pendências | `pz-homelab-f9` (branch `codex/homelab-f9`, HEAD `ce1f072`) preservado | git worktree list | 2026-08-08 |
| PR #36 | fechada (substituída) | `gh pr close 36` | 2026-08-08 |
| PR novo | `#37` aberta; `codex/homelab-v1151-remediation` -> `main` | `gh pr view 37` | 2026-08-08 |
| Branch de remediação | mergeada via PR #37; branch local e remota apagadas; worktree `pz-homelab-v1151` preservado | `gh pr view 37`, `git ls-remote` | 2026-08-08 |
| Latest release | `v1.15.1` publicada (7 assets + SHA256SUMS) | `gh release view v1.15.1` | 2026-08-08 |
| Pacote host | `1.15.1-1` instalado via `bigsudo pacman -U` (assets re-baixados, `SHA256SUMS-1.15.1` 7/7 SUCESSO) | `pacman -Q`, `sha256sum -c` | 2026-08-08 |
| Tag `v1.15.0` | existente; preservada/intacta | `git ls-remote` | 2026-08-08 |
| Homelab real | não deve ser implantado | revalidar antes/depois | 2026-08-07 |
| Player UI | async QProcess; restore sem `--yes`; 13 testes verdes | `pytest tests/test_homelab_player.py` | 2026-08-07 |
| Suíte hermética | `tests/linux-homelab.sh` exit 0 (perfis, governo, backup, broker) | bash | 2026-08-07 |
| Socket Docker | somente `socket-proxy` read-only; Portainer via `DOCKER_HOST` | compose test, suíte | 2026-08-07 |
| CI homelab | `homelab-shell-test`, `-python-test`, `compose-validate`, `security-secret-scan`, `package-smoke` adicionados | ci.yml | 2026-08-07 |
| `main` | `93adbca`, alinhada com `origin/main`; PR #49 mergeada em `7923035` | `git status`, `gh pr view 49` | 2026-08-09 |
| Latest release | `v1.15.4` publicada com 7 assets; workflow `31349835128` success | `gh release view`, `SHA256SUMS-1.15.4` | 2026-08-09 |
| Pacote host | `phasezero-control-center 1.15.3-1`; pacote `1.15.4-1` validado, instalação bloqueada por autorização Bigsudo | `pacman -Q`, `phasezero-admin pacman -U` | 2026-08-09 |
| Homelab real | não configurado/ativo; 0 workloads; nenhum apply executado | `pz server homelab status --json`, `docker ps` | 2026-08-09 |
| Jornada Windows/integrações | PR #49 mergeada; ISO antecipada, índices 1–10, player modal e controles reversíveis Windows/Waydroid/Servidor publicados em `v1.15.4` | pytest 436 + 9; provision 228/0; CI PR `31348479922` success; CI main `31349833848` success; release `31349835128` success | 2026-08-09 |
| Feedback visual e prontidão Windows | branch `codex/ui-state-feedback`; switches explícitos e otimistas, janelas de instalação opacas, launch bloqueado sem guest inicializável e saúde acionável | pytest 437 + 9; shell Windows exit 0; ShellCheck; QA offscreen | 2026-08-10 |
| `main` | `9b0e6e3`, alinhada com `origin/main`; PR #50 mergeada em `f0d88fe` | `git status`, `gh pr view 50` | 2026-08-10 |
| Latest release | `v1.15.5` publicada com 7 assets; workflow `31377411747` success | `gh release view`, `SHA256SUMS-1.15.5` | 2026-08-10 |
| Pacote host | `phasezero-control-center 1.15.5-1` instalado via `phasezero-admin pacman -U`; pacote Arch SHA-256 validado | `pacman -Q`, `sha256sum -c`, import UI | 2026-08-10 |
| Boot direto Windows | runtime em `/usr/local/lib/phasezero/windows-vm-runtime` permanece `stale`; nenhuma mutação de boot executada nesta release | `pz windows-vm boot runtime-check` | 2026-08-10 |
| Recuperação do Player Windows | branch `codex/windows-provision-state-recovery`; estado órfão é validado, preservado para diagnóstico e substituído por nova jornada acionável | pytest 441 + 9; Player 38/38; descarte/recuperação 6 rodadas; shell Windows exit 0 | 2026-08-10 |
| Latest release | `v1.15.6` publicada com 7 assets; workflow `31419021099` success | `gh release view`, `SHA256SUMS-1.15.6` | 2026-08-10 |
| Pacote host | `phasezero-control-center 1.15.6-1` instalado; estado sintético `op-test` movido para quarentena e Player retorna a `idle` | `pacman -Q`, import/instanciação UI instalada, arquivo de quarentena | 2026-08-10 |
| Status Windows VM | PR #52 mergeada em `98d8419`; status configurado evita descoberta exaustiva, sonda Samba é limitada, timeout UI específico é 45 s e cabeçalho exibe a versão | pytest 444 + 9; shell Windows; CI PR `31452172396` e `31452241293` success; 5 sondas host | 2026-08-11 |
| Latest release | `v1.15.7` publicada com 7 assets; workflow `31454088820` success | `gh release view`, `SHA256SUMS-1.15.7` 7/7 | 2026-08-11 |
| Pacote host | `phasezero-control-center 1.15.7-1` instalado; Qt retorna `needsinstall` e barra mostra `PhaseZero v1.15.7` | `pacman -Q`, `pz --version`, StatusLoader/UI offscreen instalada | 2026-08-11 |
| Boot direto Windows | runtime em `/usr/local/lib/phasezero/windows-vm-runtime` permanece `stale`; pacote não alterou GRUB nem runtime de boot | `pz windows-vm boot runtime-check` | 2026-08-11 |
| Contrato gráfico WinVM | PR #54 mergeada em `db12d68`; instalador expõe somente `compat`/`virtio-gl`; Venus segue como plano experimental | pytest 449 + 9; provision 248/0; CI `31501159700` success | 2026-08-11 |
| Latest release | `v1.16.1` publicada com 7 assets; workflow `31501162559` success; checksums 6/6 | `gh release view`, `sha256sum -c SHA256SUMS-1.16.1` | 2026-08-11 |
| Pacote host | `phasezero-control-center 1.16.1-1` instalado via `phasezero-admin pacman -U`; runtime e barra usam `v1.16.1` | `pacman -Q`, `pz --version`, import UI instalada, `widgets.py` | 2026-08-11 |
| Recuperação WinVM | operação Venus antiga cancelada sem staging; novo plano `plan-20260811-120552-23165`, operação `op-20260811-120613-9550` em `setup` 50% | status JSON, processo QEMU/TPM, log de boot da ISO | 2026-08-11 |
| Correção de release concorrente | tag temporária `v1.15.8` removida antes de publicação apó concorrência com `v1.16.0`; release patch correta é `v1.16.1` | `git ls-remote --tags`, `gh release view v1.16.1` | 2026-08-11 |
| Gestão de imagens WinVM | PR #55 mergeada em `9e5f3be`; branch `codex/winvm-image-manager` removida (local e remota); worktree `/tmp/pz-winvm-image-manager` perdido por limpeza de `/tmp` e podado — nenhum commit perdido, `origin` já tinha `c6d2ced` | pytest 545 + 9; `tests/runner.sh` 40/40; `tests/test_provision.sh` 248/0; `tests/linux-ui.sh` 27; ShellCheck 0.11 no repositório inteiro (0 falhas); `bash -n` global; `git diff --check`; CI PR `31526162284` | 2026-08-11 |
| Temas (encerramento) | `themes-accessibility-v1` encerrada; PR #53 mergeada em `c1d9931`; branch local e remota removidas; commit stale `c0f01ea` (docs) absorvido no roadmap de temas | `git branch -a`, `docs/roadmaps/themes-accessibility-v1.md` | 2026-08-11 |
| `main` | `5ac5427`, alinhada com `origin/main`; CI pós-merge `31551200375` e gitleaks `31551200362` success em `9e5f3be` | `git status`, `gh run list` | 2026-08-12 |
| Latest release | `v1.16.2` publicada com 7 assets; workflow `31553130028` success; checksums 6/6 SUCESSO após download real | `gh release view v1.16.2`, `sha256sum -c SHA256SUMS-1.16.2` | 2026-08-12 |
| Pacote `1.16.2` validado sem instalar | pacote Arch contém `image_manager_dialog.py`, `image_registry.py` e `media-inspect.sh`; `version.json` do pacote é `1.16.2`; `media scan --json` do pacote executa e devolve candidatos reais; catálogo do pacote expõe `windows.images.manage` e a UI importa offscreen | extração em diretório temporário, execução do script empacotado, import Qt offscreen | 2026-08-12 |
| Pacote host | continua `phasezero-control-center 1.16.1-1`; instalação de `1.16.2` **não** executada, aguarda autorização explícita | `pacman -Q` | 2026-08-12 |
| Host inalterado pela release | `grubenv` mantém mtime 2026-08-04 10:19:03; 45 mounts; 0 processos QEMU; nenhuma mutação de GRUB/VM/discos | `stat`, `mount`, `pgrep` | 2026-08-12 |
| Tags | `v1.16.2` criada como tag anotada; `v1.16.0`, `v1.16.1` e todas as anteriores preservadas (87 refs de tag) | `git ls-remote --tags` | 2026-08-12 |
| Auditoria UI/UX e remoção de VM | PR #57 mergeada em `b95c62e`; viewport estreito refluído, ações da gestão de imagens contidas em 780×540 e VM gerenciada removível via lixeira com preview, consentimento e bloqueio durante provisionamento | pytest 570 + 9; runner 40/40; provision 248/0; UI 27; CI PR verde; CI `main` `31892440978` success | 2026-08-15 |
| Latest release | `v1.16.4` publicada com 7 assets; workflow `31894002944` success; manifesto baixado e 6/6 checksums OK | `gh release view v1.16.4`, `sha256sum -c SHA256SUMS-1.16.4` | 2026-08-15 |
| Pacote host | `phasezero-control-center 1.16.4-1` instalado do asset Arch oficial via `phasezero-admin`; versão CLI/JSON `1.16.4`; UI instalada validada offscreen em 780×540 | `pacman -Q`, `pz --version`, import Qt instalado | 2026-08-15 |
| Host pós-v1.16.4 | VM/disco/OVMF/ISO e `grubenv` inalterados; 0 QEMU; Homelab inativo e sem workloads; `ai-memory` preservado; doctor 71 PASS/44 WARN/1 FAIL/0 ERROR/28 INFO | `stat`, `ps`, `systemctl`, status JSON, `docker ps`, doctor | 2026-08-15 |
| Boot direto WinVM v1.16.6 | PR #60 mergeada em `2f5f262`; Deck é display primário em 1280×800/59.999 Hz, externo opcional herda 2560×1080/74.991 Hz, touch passa pelo multitouch GTK rotacionado, controles usam evdev e teclado virtual Windows é autoativado | CI PR duplicada verde; CI main `31988802642`; release-commit `31990545037`; testes no hardware conectado e QEMU dry-run | 2026-08-17 |
| Latest release | `v1.16.6` publicada com 7 assets; workflow `31990545769` success; manifesto baixado e 6/6 checksums OK | `gh release view v1.16.6`, `sha256sum -c SHA256SUMS-1.16.6` | 2026-08-17 |
| Pacote host | permanece `phasezero-control-center 1.16.5-1`; instalação 1.16.6 não iniciou porque Polkit não foi autorizado; tentativa cancelada limpa, `grubenv` mtime `1785849543`, 0 QEMU | `pacman -Q`, `pgrep`, `stat`; nenhum lock `pacman` criado | 2026-08-17 |
| Pacote host | `phasezero-control-center 1.16.6-1` instalado via `phasezero-admin pacman -U` (rebuild do `main` `fe76f0f`, não o asset da release); prévia de remoção da VM atual retorna `ready:true` com 0 blockers e aviso de VM adotada; `grubenv` mtime `1785849543` e 0 QEMU preservados; runtime GRUB segue `OUTDATED` (sincronização deliberadamente adiada) | `pacman -Q`, `pz --version`, `pz windows-vm remove --json`, `stat`, `pgrep` | 2026-08-19 |
| VMs legadas | as 2 VMs concluídas de 2026-08-16 foram removidas em 2026-08-19 05:42 local com `vmRemovedAt` registrado (`op-20260805-152412-5248`, `op-20260811-120613-9550`); `provision inventory --json` devolve `count:0`; resta `PhaseZero-Windows-Primary-final-20260816` como VM atual | `provision inventory --json`, `operation.json` de cada operação | 2026-08-19 |
| IA, proxies e workspaces | jornada auditada; autenticação/ledger centrais; quatro proxies com snapshots fixos; três imagens Odysseus fixadas por digest; deploy Odysseus continua bloqueado sem commit aprovado | pytest 640 + 9; testes shell IA/Homelab/UI; testes adversariais de commit/digest; ShellCheck; QA offscreen; diff-check | 2026-08-24 |
| Auditoria host limpo 2026-09-06 | main `2180c94`, v1.19.0; 31 itens abertos (1 P0 restore). Bootstrap incompleto, sucesso falso e divergências IA/proxies documentados; nenhum workload implantado | [relatório e provas](../../reports/portfolio-clean-host-2026-09-06/README.md); 364 pytest direcionados, 4 suítes shell, 13 Compose cliente, asset Arch verificado | 2026-09-06 |
| Fase 0 auditoria host limpo | PZ-AUD-005,006,009,010,011,012 verified em `codex/aud-fase0`; lifecycle honesto, isolamento por projeto, reconcile, backup consistente, restore transacional, prontidão estrita | `tests/linux-homelab.sh` + `linux-ai-proxies` + `linux-9router` + `linux-agent-workspaces` exit 0; pytest Homelab 76; fixtures /tmp (nenhum workload real) | 2026-09-07 |
| Fase 1 auditoria host limpo | PZ-AUD-001,002,003,004,026,027 verified em `codex/aud-fase1`; pz no PATH, prepare com deps, perfis ordenados, compose declarado, providers AUR, manifests validados | `tests/linux-homelab.sh` exit 0; pytest 153 (capabilities, deps, cohesion, profile-packages, homelab); daemon real intocado | 2026-09-07 |
| Fase 2 auditoria host limpo | PZ-AUD-007,008,015,025,030,031 verified em `codex/aud-fase2`; broker Paperless, receitas por app, lifecycle agente/dashboard, boot Hermes, pins/valores Compose, governor unificado | `tests/linux-homelab.sh` + 3 suítes shell exit 0; pytest 157; daemon real intocado | 2026-09-07 |
| Fase 3 auditoria host limpo | PZ-AUD-016–024 verified em `codex/aud-fase3`; runtimes/build transacional, conjuntos, manifesto cross-OS, MiMo inferência, Hermes opcional, appliance preview, broker delimitado, LLM com prova | `tests/linux-ai-proxies.sh` + agent-workspaces + homelab + 9router exit 0; pytest 158; daemon intocado | 2026-09-07 |
| Fase 4 auditoria host limpo | PZ-AUD-013,014,029 verified em `codex/aud-fase4`; wizard real, pair via registro, objetivos no Início | `tests/linux-homelab.sh` exit 0; pytest player/navigation; viewport preservado | 2026-09-07 |
| Remediação REV-001/002/003/018 | `codex/rev-remediation` (sobre `9d6be9d`): maturidade antes de Docker no `up` (rc 69 honesto sem daemon), volume registrado antes da primeira mutação no restore + `recoveryRequired` verdadeiro, `cmd_down` antes do snapshot pré-restore e PROPAGANDO falha do compose down (R01-001), sqlite `.backup` na origem viva com reason estruturado e TSDB real fail-closed | `tests/linux-homelab.sh` exit 0 com daemon presente E com docker indisponível; matriz de mutação falha por posição; pytest player 44; contratos agent/web 38; `git diff --check` | 2026-09-07 |
| Fase 5 auditoria host limpo | PZ-AUD-028 verified em `codex/aud-fase5`; job arch-clean-host, gates de manifesto/exatidão, matriz de evidência | Arch descartável real (15 perfis, asset, entrypoints); CI estendido; sem mutação no host | 2026-09-07 |

## Ledger de execução

Adicionar uma linha por sessão material. Não apagar histórico.

| Data | Agente | Branch/worktree | Fase | Commit/PR | Gates | Resultado/próximo passo |
|---|---|---|---|---|---|---|
| 2026-09-08 | Codex | codex/verify-ux-70d959f, dedicada | verificação UX | base70d959f; docs via git log | QA dark800→1280→800; pytest-final/validation.json | aceite local; nenhum host mutado; próxima jornada simples |
| 2026-09-06 | Codex | `codex/portfolio-clean-host-audit` / `pz-portfolio-clean-host-audit` | diagnóstico transversal | docs sobre `2180c94` | 364 pytest; 4 shell; 12 registros reproduzidos; 2 contratos PS; 13 Compose; asset Arch verificado | PZ-AUD-001..031 pending; [plano/handoff](../../reports/portfolio-clean-host-2026-09-06/PLANO.md); P0 restore aberto. Sem mutação de runtime |
| 2026-09-07 | opencode | `codex/aud-fase0` / `pz-aud-fase0` | Fase 0 (005,006,009,010,011,012) | `076b4ba`, `1a47c15`, `98b75a1`, `7fc3564` | linux-homelab/ai-proxies/9router/agent-workspaces exit 0; pytest Homelab 76; diff-check | 6 itens verified no backlog; P0 restore fechado em fixture. Sem workload/container/servidor tocado. Próximo: Fase 1 (001,002,003,004,026,027) em worktree novo |
| 2026-09-07 | opencode | `codex/aud-fase1` / `pz-aud-fase1` | Fase 1 (001,002,003,004,026,027) | `b9523da`, `134a3a3`, `c13a304`, `7e7435c`, `209524d`, `ba3a12a`, `b23c0a9`, `1a48cda` | linux-homelab exit 0; pytest 153; diff-check | 6 itens verified no backlog. Daemon real intocado. Próximo: Fase 2 (007,008,015,025,030,031) em worktree novo |
| 2026-09-07 | opencode | `codex/aud-fase2` / `pz-aud-fase2` | Fase 2 (007,008,015,025,030,031) | `8b024f8`, `4060b55`, `7fed458`, `49bb844`, `e8a1b1e` + fechamento | linux-homelab + ai-proxies + 9router + agent-workspaces exit 0; pytest 157; diff-check | 6 itens verified no backlog. Daemon real intocado. Próximo: Fase 3 (016-024) em worktree novo |
| 2026-09-07 | opencode | `codex/aud-fase3` / `pz-aud-fase3` | Fase 3 (016-024) | commits fase3 + fechamento | linux-ai-proxies + agent-workspaces + homelab + 9router exit 0; pytest 158; diff-check | 9 itens verified no backlog. Daemon real intocado. Próximo: Fase 4 (013,014,029) em worktree novo |
| 2026-09-07 | opencode | `codex/aud-fase4` / `pz-aud-fase4` | Fase 4 (013,014,029) | commits fase4 + fechamento | linux-homelab exit 0; pytest 55 (player/navigation/cohesion); diff-check | 3 itens verified no backlog. 30/31. Próximo: Fase 5 (028) em worktree novo |
| 2026-09-07 | opencode | `codex/aud-fase5` / `pz-aud-fase5` | Fase 5 (028) | commits fase5 + fechamento | arch-clean-host provado em container descartável; suites herméticas; diff-check | 31/31 verified no backlog. Auditoria host-limpo remediada em fixture+CI; E2E físico segue gates próprios |
| 2026-08-07 | Codex | `main` | Roadmap | não commitado | `git diff --check` passou | Roadmap canônico criado; iniciar Fase 0 em worktree novo |
| 2026-08-07 | opencode | `codex/homelab-v1151-remediation` / `pz-homelab-v1151` | Fase 0 (baseline) | `22298d3`..`92d576b` (8 commits) | suíte hermética exit 0; pytest 437; shellcheck; `git diff --check` | Port validado em commits por fase; Player reescrito (async QProcess) + 12 testes verdes |
| 2026-08-07 | opencode | idem | Fase 4 (perfis) | `4458ff3` | suíte hermética exit 0 | 6 perfis públicos implementados: assistant-private, assistant-multichannel, automation, ai-studio (blocked), developer, edge (default) |
| 2026-08-07 | opencode | idem | Fase 5/8 (CLI+CI) | `0e261eb`, `6bac525`, `9676b8e` | suíte exit 0; smoke install-root exit 0; compose-validate local OK | alias `profiles --json`; socket-proxy; 5 jobs homelab no CI; `homelab-integration-disposable` delegado à Fase 2 (probe E2E faltante) |
| 2026-08-08 | opencode | idem | Fase 0/10 (PR) | branch pushed; PR #37 aberto; #36 fechada | gitleaks green; compose-validate green; homelab-python-test green; security-secret-scan green (parcial) | CI principal em andamento (lint, shell-lint, python-test, shell-test, pester); aguardar conclusão antes do merge |
| 2026-08-08 | opencode | idem | Fase 0/10 (CI verde + fixes) | `4d15f15` (SC2120/0.9.0), `f373266` (chmod +x), `0429af3` (rg nos jobs), `9c02010` (PZ_ROOT pin) | CI PR #37 run `31255687739`: 12/12 jobs success | CI verde completo: lint, shell-lint 0.9.0 e 0.11.0, python-test, pester, shell-test, windows-vm, homelab-python-test, homelab-shell-test, compose-validate, package-smoke, security-secret-scan. Próximo: merge da PR #37 |

Prova CI: run `31255687739` — status `success`, 12 jobs verdes (`gh run view 31255687739`).

Prova CI pendências Fase 2/3/9: run `31265085899` — status `success`, 14 jobs
verdes incluindo o novo `homelab-integration-disposable` (PR #38).

| Data | Agente | Branch/worktree | Fase | Primeiro item | Gates | Resultado/próximo passo |
|---|---|---|---|---|---|---|
| 2026-08-08 | opencode | `codex/homelab-f9` / `pz-homelab-f9` | Fase 2/3/9 (pendências) | `0259b55` (winvm contract), `676c643` (pre-restore + rollback), `6ff4298` (E2E disposable), `ce1f072` (docs/changelog) | suíte hermética exit 0; bash -n; shellcheck; diff --check; CI run `31265085899` 14/14 success | PR #38 mergeada (`fc7ede8`); main CI + gitleaks verdes (`31266597239`/`31266597234`); suíte exit 0 em `main`. **Próximo**: usuário instala `1.15.1-1` via `phasezero-admin pacman -U <pkg>` e valida pós-instalação (0 dry-runs) |

Prova release: workflow `31258447568` success; assets em `gh release view v1.15.1` (7); checksums 7/7 `SUCESSO`; `e2b85e6` release commit no `main`.

| Data | Agente | Branch/worktree | Fase | Primeiro item | Gates | Resultado/próximo passo |
|---|---|---|---|---|---|---|
| 2026-08-08 | opencode | `main` (worktree principal) | Fase 10 (merge/release/pacote) | `3cb05fb` (squash PR #37), `e2b85e6` (release v1.15.1), tag `v1.15.1` | run `31257317111` main verde; release `31258447568` verde; `SHA256SUMS-1.15.1` 7/7 SUCESSO; conteúdo arch/deb/rpm/src conferido | **Próximo**: usuário instala via `phasezero-admin pacman -U <pkg.tar.zst>` e valida versão/profiles/status/plan (0 dry-runs) após confirmação |
| 2026-08-09 | opencode | `main` (worktree principal) | Pós-v1.15.1: release v1.15.2 (auditoria CX/UX + dependabot) | 10+ PRs audit (dead pages, doctor timeouts, dedup catálogo, UX core, labels, flaky) + 5 dependabot; `release.sh 1.15.2 --push` (`d4bc8a2`, tag `v1.15.2`) | run release `31314293821` success; `SHA256SUMS-1.15.2` 7/7 SUCESSO; bigsudo pacman -U exit 0 | Instalado `phasezero-control-center 1.15.2-1`; `pz --version` → v1.15.2; homelab status fail-closed (`configured:false active:false`, 0 workloads); doctor 130 PASS / 0 técnico (1 FAIL `CPU01` sensor 88°C — estado real do HW, não regressão); CLI `profiles/status/plan` top-level não existem — usar `pz server homelab status --json` e `pz server homelab profile list` |
| 2026-08-09 | Codex | `codex/ui-progressive-disclosure` (`/tmp/pz-ui-progressive`) + `main` | HL-UI-002: UX leiga, release v1.15.3 e instalação | 6 commits de implementação/docs + PR #48 (`32664a1`); release `1339a35`, tag `v1.15.3` | pytest 428 + 9; runner CI 39/39; ShellCheck 0.9/0.11; Pester; gitleaks; CI PR `31327861952`; CI main `31329472867`; release `31329478165` | Instalado `1.15.3-1`; Arch SHA `924feeda…` OK; 5/6 binários baixados validaram localmente e 7/7 digests da API GitHub coincidem com manifesto (AppImage local corrompida por retomada NAT64, rejeitada); Homelab `configured:false active:false`, 0 workloads; mounts/cmdline/Docker iguais; listener adicional pertence a pytest concorrente de `Port_Steam`, não ao pacote |
| 2026-08-09 | Codex | `codex/ui-windows-install-journey` (`/tmp/pz-ui-windows-install`) | HL-UI-002: correção da jornada Windows e controles reais | `6338d21` (implementação), `153a973` (contratos/testes), base `fc1af96` | pytest 436 + 9; provision 228 PASS/0 FAIL; Windows VM shell exit 0; Waydroid smoke exit 0; bash -n; compileall; diff-check | ISO exigida antes do player; edições limitadas e já concluídas bloqueadas; janela não incorpora no painel; logs recolhidos; toggles executam pares enable/disable e recarregam estado. Sem push, PR, release ou instalação; próximo: revisão, push/PR e release somente sob autorização explícita |
| 2026-08-09 | Codex | `codex/ui-windows-install-journey` + `main` | HL-UI-002: merge, release e instalação | PR #49 mergeada (`7923035`); release `93adbca`, tag `v1.15.4` | CI PR `31348479922` success; CI main `31349833848` success; release `31349835128` success; Arch SHA256 OK | 7/7 assets publicados; pacote Arch `1.15.4-1` validado. Host continua `1.15.3-1`: Bigsudo recusou autorização, sem fallback sudo. Próximo: autorizar Bigsudo e repetir `phasezero-admin pacman -U <pkg>`. |
| 2026-08-10 | Codex | `codex/ui-state-feedback` (`/tmp/pz-ui-state-feedback`) | HL-UI-002: feedback de estado, opacidade e saúde Windows | `4fb2e5c`, `80a30d9`, `d9f09c5` | pytest 437 + 9; 63 testes focados; `tests/linux-windows-vm.sh` exit 0; bash -n; ShellCheck; QA offscreen | Toggles mostram Ligado/Desligado/Aplicando e restauram cancelamento; player virou QDialog opaco; status real reporta `needsinstall`, `guest-not-installed` e `boot-runtime-stale`; sem push/release/install nesta sessão. |
| 2026-08-10 | Codex | `main` + `codex/ui-state-feedback` | HL-UI-002: merge, release e pacote | PR #50 (`f0d88fe`); release `9b0e6e3`, tag `v1.15.5` | CI PR `31374802265` + `31374785566` success; release `31377411747` success; `SHA256SUMS-1.15.5` Arch OK; import UI OK | Host atualizado para `1.15.5-1`. WinVM reporta `needsinstall` por disco ainda não inicializável e runtime de boot direto `stale`; nenhuma mudança em VM, GRUB ou runtime de boot. |
| 2026-08-10 | Codex | `codex/windows-provision-state-recovery` (`/tmp/pz-windows-state-recovery`) | HL-UI-002: recuperação de sessão órfã | `9a88e75` | pytest 441 + 9; Player 38/38; descarte/recuperação 6/6; `tests/linux-windows-vm.sh` exit 0; diff-check | `op-test` sintético não bloqueia nova instalação; registro órfão é preservado; erro backend fica acionável; lifecycle de testes fecha todas as janelas. Próximo: PR/release/instalação após CI. |
| 2026-08-10 | Codex | `main` + `codex/windows-provision-state-recovery` | HL-UI-002: merge, release e recuperação no host | PR #51 (`4197d6e`); release `33c6311`, tag `v1.15.6` | CI PR `31416105858` success; release `31419021099` success; Arch SHA-256 OK; UI instalada retorna `idle`/start visível | Host em `1.15.6-1`; `player.json` órfão preservado como `player.orphaned-20260810T191226218069Z.json`; status `needsinstall`, sem iniciar VM. Boot runtime continua `stale` e exige autorização administrativa separada. |
| 2026-08-11 | Codex | `codex/windows-status-version` (`/tmp/pz-windows-status-version`) + `main` | HL-UI-002: status Windows resiliente, versão visível e release | `5cef80b`; PR #52 (`98d8419`); release `2e6e482`, tag `v1.15.7` | pytest 444 + 9; Windows shell; CI PR duplicada verde; CI main `31454086764`; release `31454088820`; checksums 7/7; Qt instalada `ready/needsinstall` | Host atualizado para `1.15.7-1`; falso `Estado indisponível` removido, RAM/CPU carregadas e cabeçalho mostra `PhaseZero v1.15.7`. Disco segue legitimamente `needsinstall`; boot runtime continua `stale`, sem mutação de GRUB/VM. |
| 2026-08-11 | Codex | `codex/winvm-provision-graphics-contract` (`/tmp/pz-winvm-graphics`) + `main` | HL-WIN-GFX-001: contrato gráfico, release e recuperação real | `12da34b`, `98203ea`, `b91eacd`; PR #54 (`db12d68`); release `bd9a0b7`, tag `v1.16.1` | pytest 449 + 9; runner 39/39; provision 248/0; CI `31501159700`; release `31501162559`; SHA 6/6; host `setup` 50% | Host em `1.16.1-1`; Venus antigo cancelado sem staging; edição 2 reutilizada legitimamente; instalação `virtio-gl` avançou por validate/assets/mídia/disco e iniciou Setup. Tag temporária `v1.15.8` foi removida antes de publicação; nenhuma tag histórica movida. |
| 2026-08-11 | Codex + Claude | `codex/winvm-image-manager` (`/tmp/pz-winvm-image-manager`) | HL-IMG-001 Fases A–E: encerramento de temas, registro de imagens, `media scan`, `ImageManagerDialog`, wiring e testes | `abfc5c5` (docs temas), `d63b66a` (registro), `3a4da5f` (scan), `1b2fad5` (dialog), `117d430` (wiring), `03ae621`, `12ccf4b`, `fda34e8`, `c6d2ced` (correções de revisão); PR #55 → `9e5f3be` | pytest 545 + 9; `tests/runner.sh` 40/40; `tests/test_provision.sh` 248/0; `tests/linux-ui.sh` 27; ShellCheck 0.11 repo inteiro; `bash -n`; `git diff --check`; CI PR `31526162284` 29/29 success | Dirigir a tela contra a ISO real do host expôs que a jornada principal terminava em beco sem saída: `media inspect` devolve `valid:true` com `imageCount:0` em mídia de varejo, então nenhuma edição era selecionável e reproduzir nunca habilitava. Corrigido reusando a faixa 1–10 da instalação. Mais três defeitos corrigidos: `moveToTrash` estático devolve tupla sempre verdadeira (falha reportada como sucesso), falha de `inspect` abortava o resto do lote, e o botão primário ficava habilitado e inerte sem seleção. Revisão automatizada acrescentou emissão dupla no timeout, avanço de lote só no caminho feliz, schema 0 lido como v1, sha maiúsculo/minúsculo duplicando imagem e dois monkeypatches de teste sem reversão. Todos com teste que falha contra a implementação anterior. Nenhuma mutação de GRUB/`grubenv`/VM/discos/mounts. **Próximo**: release `v1.16.2` |
| 2026-08-12 | Claude | `main` (worktree principal) | HL-IMG-001 Fase F: merge, release e validação do pacote | PR #55 squash → `9e5f3be`; `9cc0a2f` (evidências no roadmap); `5ac5427` (release v1.16.2), tag anotada `v1.16.2` | CI main `31551200375` + gitleaks `31551200362` success; release workflow `31553130028` success; 7 assets; `sha256sum -c SHA256SUMS-1.16.2` 6/6 SUCESSO após download real | Pacote `1.16.2` validado sem instalar: contém `image_manager_dialog.py`/`image_registry.py`, `version.json` correto, `media scan --json` empacotado devolve candidatos reais e a UI empacotada importa offscreen expondo `windows.images.manage`. Host segue em `1.16.1-1`; `grubenv`, mounts e VM inalterados. HL-IMG-001 permanece `in_progress`: falta somente a validação pós-instalação, que exige autorização explícita do usuário. **Próximo**: `phasezero-admin pacman -U <phasezero-control-center-1.16.2-1-any.pkg.tar.zst>` somente após autorização, depois marcar HL-IMG-001 como `verified` |
| 2026-08-15 | Codex | `codex/phasezero-ui-functional-audit` (`/mnt/sdcard/Projects/pz-ui-functional-audit`) + `main` | P1 UI narrow viewport + HL-IMG-001: reavaliação, remoção de VM, release e validação do host | `0e21c54`, `5f49dbd`, `ce79038`, `b56c826`, `ac9e210`, `90f9234`, `4649e1c`; PR #57 → `b95c62e`; release `15ccd72`, tag `v1.16.4` | pytest 570 + 9; runner 40/40; provision 248/0; UI 27; CI PR verde; CI main `31892440978` e `31894001140` success; gitleaks `31894001162` success; release `31894002944` success; checksums 6/6 | Host atualizado para `1.16.4-1`. Preview instalado de remoção retorna `ready:true`, 0 blockers e recuperação via lixeira; nenhuma VM foi removida no teste. VM, disco, firmware, ISO, `grubenv`, Homelab e container `ai-memory` preservados. Runtime de boot direto segue `stale`, fora do escopo da atualização do pacote. |
| 2026-08-16 | Codex | `codex/winvm-legacy-removal` (`/mnt/sdcard/Projects/pz-winvm-legacy-removal`) + `main` | HL-IMG-001: inventário e remoção segura de VMs concluídas legadas | `2be2b2a`, `b205668`, `913c702`, `2f2e937`; PR #58 → `d202139`; release `2d721b7`, tag `v1.16.5` | pytest 573 + 9; UI 27; remoção e provisionamento herméticos; CI PR 30/30; CI main `31947914357` e release-commit `31949400280` success; release `31949402337` success; 7 assets e checksums 6/6 | Host atualizado para `1.16.5-1`. Inventário instalado encontra 2 VMs desligadas/removíveis, 43.133.304.832 bytes; ambas prévias permanentes retornam `ready:true`, 0 blockers. Nenhuma VM removida. `grubenv` mtime `1785849543`, 46 mounts e 0 QEMU preservados. UI instalada mostra `VMs instaladas · 2`, `40.2 GB` e ação separada para VM atual. Runtime GRUB segue `stale`; atualização deliberadamente adiada para validação física da próxima release. |
| 2026-08-17 | Codex | `codex/winvm-direct-input` (`/mnt/sdcard/Projects/pz-winvm-direct-input`) + `main` | Boot GRUB WinVM: display, frequência, touchscreen, controles e teclado virtual | `25344d0`, `9e06323`, `39c7e35`, `6af07f6`; PR #60 → `2f5f262`; release `da86960`, tag `v1.16.6` | PR CI duplicada success; main `31988802642`; release-commit `31990545037`; gitleaks `31990545071`; release `31990545769`; checksums 6/6; provision 252/0; Windows VM/graphics/UI verdes | Release oficial pronta. Auditoria detectou e removeu passthrough cru do touchscreen 800×1280, substituído por `virtio-multitouch` via GTK/Gamescope para respeitar rotação. Host ainda `1.16.5-1`: diálogo Polkit não autorizado, processo cancelado antes de `pacman`; `grubenv` e VM intactos. **Próximo**: autorizar `phasezero-admin pacman -U` do pacote validado, executar `pz windows-vm boot install`, validar runtime `current`, depois boot físico e evidência dentro do Windows. |
| 2026-08-19 | ZCode | `main` (worktree principal) | Pós-v1.16.6: instalar 1.16.6 no host; terceiro defeito de remoção (lock vazio) achado e corrigido | fix `d6b6285` (sessão anterior) + `fe76f0f` (lock vazio); docs roadmap | TDD: teste do lock vazio falhou antes e passou depois; `tests/test_windows_vm_remove.sh` ok; `tests/test_provision.sh` 257/0; `tests/linux-windows-vm.sh` ok; `bash -n`; shellcheck com excludes do CI; `git diff --check`; rebuild + reinstalação `1.16.6-1` exit 0 | Host em `1.16.6-1`. Prévia de remoção da VM atual: `ready:true`, 0 blockers, aviso de adotada. Causa raiz: `provision_lock_clear` trunca `active.lock` e nunca apaga (design), mas `provision_removal_blocker` chamava lock vazio de inconsistente — todo host liberado ficava `ready:false` para sempre. Não-mutação: `grubenv` mtime `1785849543`, 0 QEMU, VM intacta, inventário `count:0` coerente com as 2 remoções legadas de 05:42. **Próximo**: CI verde no push de `fe76f0f`; runtime GRUB `OUTDATED` segue adiado até o boot físico planejado. |
| 2026-08-24 | Codex | `feat/ai-proxies-runtime` / worktree principal | AI-UX-001: diagnóstico, UX, proxies, roteamento e gates de workspaces | não commitado | pytest 634 + 9; `linux-ai`, `linux-ai-proxies`, `linux-agent-workspaces`, `linux-homelab`, `linux-ui`; ShellCheck; `bash -n`; QA offscreen; diff-check | Corrigidos falso sucesso, continuação Mimo, falhas assíncronas e divergência de política. Catálogo essencial/opcional e seção Hermes/9Router/Odysseus adicionados. Odysseus e perfis incompletos falham antes de mutação. Nenhum workload aplicado. Próximo: aprovar allowlists/digests, decidir “Nova Router” e criar AuthRegistry/OperationLedger. |
| 2026-08-24 | Codex | `feat/ai-proxies-runtime` / worktree principal | AI-UX-002: AuthRegistry, OperationLedger e latência do status | não commitado | pytest 640 + 9; linux-ai/proxies/workspaces/UI; ShellCheck; `bash -n`; QA 1280×1080; diff-check | `pz ai auth` agrega 20 integrações/16 contas sem identidade ou segredo. Ledger registra ciclo, recupera interrupção e oferece retry com nova confirmação. `pz ai status` caiu de ~6,7 s para ~4,6 s por paralelismo. Próximo: expiração/revogação por adapter, checkpoints internos e allowlists/digests. |
| 2026-08-24 | Codex | `feat/ai-proxies-runtime` / worktree principal | AI-UX-003: procedência dos proxies | não commitado | pytest focado 64; `linux-ai-proxies`; ShellCheck; `bash -n`; diff-check; quatro checkouts reais validados | Kimi, Qwen, DeepSeek e Mimo fixados por repo/commit/tree/licença/lockfiles. Clone usa staging; start/restart/login/Mimo/IDE falham antes de executar snapshot divergente. Legados sem revisão bloqueados. `semanticAudit:false`; próximo: SBOM/diff/rollback e digests Odysseus. |
| 2026-08-24 | Codex | `feat/ai-proxies-runtime` / worktree principal | AI-UX-004: imagens Odysseus por digest | não commitado | `linux-agent-workspaces`; ShellCheck; `bash -n`; diff-check; Registry v2 header/body SHA iguais | Chroma 1.5.9, SearXNG 2026.5.31 e ntfy v2.26.3 fixados por manifest-list digest. `latest`/pull removidos do deploy. Instalação bloqueia antes de escrita; start/restart antes de systemd se lock divergir. Commit Odysseus segue sem allowlist; nenhum workload iniciado. |
| 2026-08-24 | Codex | `feat/ai-proxies-runtime` / worktree principal | AI-UX-005: auditoria de distribuição Hermes e release Odysseus | não commitado | `linux-agent-workspaces`, `linux-ai`; ShellCheck; `bash -n`; hashes raw; npm audit; Registry v2 header/body SHA iguais | Checksum arbitrário não promove mais instalador Hermes. Release `v2026.8.19` ficou pinada, porém bloqueada por cadeia transitiva e auditoria incompletas. Odysseus `b4d1293` assinado ficou catalogado, não aprovado; base Python fixada por digest, grafo Python e superfície shell mantêm deploy bloqueado. Plano sem allowlist voltou a retornar JSON estruturado. Nenhum workload iniciado. |
| 2026-08-24 | Codex | `feat/ai-proxies-runtime` / worktree principal | AI-UX-006: instalação Hermes ponta a ponta autorizada | não commitado | commit/árvore exatos; config/doctor; chat real `HERMES_OK`; Browser live; MCP ai-memory; OSV 107/0; gateway ativo e isolado | Hermes `v0.20.5` instalado do release `v2026.8.19` por aceite de risco preso ao commit `fcbd1076`; integrado ao 9Router canônico em loopback, gateway user habilitado com linger, desktop/CLI/ACP, 77 skills e Playwright. Fallback destravado do instalador e assinatura ausente permanecem avisos explícitos. |
| 2026-09-07 | ZCode | `codex/rev-remediation` (`pz-rev-remediation`) | R0+R1 do plano REV: REV-018; REV-004..007; REV-001/002/003 | `52da4d3`, `8686279`, `87c31a1`, `765e791`, `53d5314` | `tests/linux-homelab.sh` exit 0 (com daemon e com docker indisponível); pytest player 40 passed; agent/web 38 passed; `bash -n`; `git diff --check`; ShellCheck sem achado novo vs baseline | P0 de restore fechado em fixture: swap falho em qualquer posição retorna ao estado pré-restore; rollback incompleto reporta `recoveryRequired`. Onboarding: parser de documento, pair gate por host, plano amarrado a host capturado, perfil transmitido ao backend. Matriz canônica: `docs/roadmaps/rev-remediation-v1.md`. Nenhum workload/boot/pacote alterado. **Próximo**: REV-008 (SSH de primeiro acesso na UI) e R3 (contrato gráfico WinVM hermético) antes dos gates físicos. |
| 2026-09-07 (2) | ZCode | `codex/rev-remediation` (`pz-rev-remediation`) | Contrarrevisão R01: R01-001..005 do retorno R0/R1 | `174a233`, `b447312`, `6d8cf39` | suíte exit 0 2× (daemon presente e sombreado); pytest player 44; agent/web 38; bash -n; diff-check | P0 de stop fechado: `cmd_down` propaga falha do compose down e restore recusa mutação (cmd_down real + stub exit 42). Matriz REV-001 por posição (cp/wipe). Reason de backup sobrevive à subshell (R01-004); TSDB real nunca consistente (R01-005); pareamento tardio descartado para host trocado (R01-002); plano declara verdade budget-only do perfil (R01-003). Roadmap REV com tiers planned/unproven e estados fixture vs física. **Próximo**: R2 (REV-008). |
| 2026-09-07 (3) | ZCode | `codex/rev-remediation` (`pz-rev-remediation`) | UX-001..004 da revisão r01-ux | `408d7e9`, `85bedf1` | pytest player 47 + windows_vm 30 (todos verdes); pytest completo 635 passed + 1 falha pré-existente em `a82e2cc` (`emulation.dualscreen.status`, fora do escopo); QA offscreen com capturas 800×600/1280×800 | UX-001: confirmação de revisão por clique real (E2E por input público). UX-002: hash do plano cobre a intenção e ignora telemetria de RAM/disco; verdict fail bloqueia. UX-003: Homelab com scroll vertical global, zero scroll horizontal, geometria de cada botão provada em 800×600. UX-004: Windows VM reflow <1000px (1 coluna + hero empilhado), CTA intacto. UX-005..011 registrados planned no roadmap REV. Falha pré-existente `emulation.dualscreen.status` reproduzida em `a82e2cc` — não é regressão. **Próximo**: UX-005/007/009 (jornadas do modo simples), depois R2 (REV-008/UX-008). |
| 2026-09-07 (4) | ZCode | `codex/rev-remediation` (`pz-rev-remediation`) | Retorno da revisão ux004: UX-001 reaberto + tema real | `c784373` | pytest player 49 (E2E com hit-test real + aceite temático MainWindow 800→1280→800) + windows_vm 30 + agent/web 38; capturas temáticas conferidas | Causa-raiz UX-001: segunda definição de `_refresh_onboard_label` sobrescrevia a lógica do botão — removida; teste endurecido (visível E habilitado, retângulo inteiro, clique via `widgetAt`) e scan de duplicatas. UX-003: header/perfil/ações refluem (linhas únicas ditavam mínimo de 797px). UX-004: hero num grid único e card de manutenção refluído (mínimo de 785px eliminado); captions com wrap. Aceite com tema real: zero overflow horizontal nas duas páginas na alternância. **Próximo**: UX-005/007/009, depois R2. |

### Escopo obrigatório da próxima release WinVM

- Integrar `3302a3b8db6870f89c15eec31384e080ecf4b7af`
  (`fix(windows-vm): honor active display at GRUB boot`) em `main`, com revisão e
  CI verde; não copiar o patch manualmente.
- Propagar ao boot GRUB também a frequência ativa do monitor. Preferir a
  frequência realmente usada pelo host; fallback deve ser explícito, seguro e
  testado para EDID/modos ausentes.
- Adotar uma das instalações concluídas como VM principal somente após escolha
  explícita entre os IDs disponíveis, prévia e backup do arquivo de configuração.
- Validar dentro do Windows: resolução real, driver WDDM, Direct3D funcional e
  ausência de `Microsoft Basic Display Adapter`; registrar versões e evidência.
- Executar boot físico pela entrada GRUB PhaseZero e capturar evidência visual.
  Antes disso, sincronizar o runtime `stale` com o pacote publicado e preservar
  rollback da entrada, `grubenv` e runtime anterior.

## Formato obrigatório de handoff

Todo agente encerra trabalho material com este bloco:

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
Próximo passo exato:
```

Handoff sem comandos/resultados verificáveis não altera requisito para `verified`.

### Handoff — HL-IMG-001 (2026-08-12)

```text
Objetivo da sessão: concluir o plano de gestão de imagens Windows para leigo
  (achar ISO, ver edições por índice, reproduzir, habilitar no boot, restaurar
  GRUB, remover) e harmonizar as pendências de temas, retomando o trabalho
  parado de outro agente.
Fase/IDs assumidos: HL-IMG-001, Fases A–F.
Branch e worktree: `codex/winvm-image-manager` em `/tmp/pz-winvm-image-manager`
  (perdido por limpeza de `/tmp` e podado); conclusão feita em `main`
  (`/mnt/sdcard/Projects/PhaseZero`).
HEAD inicial: `0abc5ad` (main) / `117d430` (branch, deixada pelo agente anterior).
HEAD final: `5ac5427` (main, release v1.16.2).
Arquivos alterados: `linux/ui_native/image_registry.py` (novo),
  `linux/ui_native/image_manager_dialog.py` (novo), `linux/ui_native/catalog.py`,
  `linux/ui_native/main_window.py`, `linux/ui_native/pages/windows_vm.py`,
  `linux/ui/actions.json`, `linux/windows-vm/media-inspect.sh`,
  `linux/windows-vm/windows-vm.sh`, `tests/test_image_registry.py` (novo),
  `tests/test_image_manager_dialog.py` (novo), `tests/test_windows_vm_ui.py`,
  `tests/linux-windows-vm.sh`, `CHANGELOG.md`, os dois roadmaps.
Commits criados: `03ae621`, `12ccf4b`, `fda34e8`, `c6d2ced` (correções desta
  sessão sobre o trabalho herdado), `36891ec`/`3337983` (docs), merge `9e5f3be`,
  `9cc0a2f` (evidências), `5ac5427` (release).
Testes executados e resultados: pytest 545 passed + 9 subtests; `tests/runner.sh`
  40/40; `tests/test_provision.sh` 248 PASS/0 FAIL; `tests/linux-ui.sh` 27;
  `tests/linux-windows-vm.sh` exit 0; ShellCheck 0.11 no repositório inteiro com
  0 falhas; `bash -n` global; `git diff --check`.
CI/PR: PR #55 run `31526162284` success (29 checks, 0 falhas) + gitleaks
  `31526162389`; CI de `main` `31551200375` e gitleaks `31551200362` success;
  release workflow `31553130028` success.
Estado do host antes/depois: pacote `phasezero-control-center 1.16.1-1` antes e
  depois — a instalação de `1.16.2` NÃO foi executada. `grubenv` mantém mtime
  2026-08-04 10:19:03, 45 mounts, 0 processos QEMU. Nenhuma mutação de GRUB, VM,
  discos ou mounts. As únicas execuções contra o host foram leituras
  (`media scan`, `media inspect`) com estado gravado em diretório temporário.
Segredos verificados como ausentes: gitleaks verde no PR, em `main` e na release;
  `security-secret-scan` verde; nenhum valor de segredo lido, logado ou gravado
  pelo registro de imagens.
Limitações e riscos restantes: (1) `media inspect` não consegue ler os nomes das
  edições em mídia de varejo — a tela oferece a faixa numérica 1–10, o mesmo
  contorno já usado pela instalação; (2) o registro não é seguro contra escritor
  concorrente (um único escritor por desenho, limitação documentada no
  docstring); (3) o SHA-256 de uma ISO grande leva dezenas de segundos, embora
  assíncrono; (4) worktrees em `/tmp` são frágeis — esta sessão perdeu a sua para
  uma limpeza de `/tmp` no meio do trabalho, sem perda de commits porque tudo já
  estava em `origin`.
Bloqueios reais: nenhum técnico. HL-IMG-001 permanece `in_progress` apenas porque
  a validação pós-instalação exige autorização explícita do usuário.
Próximo passo exato: com autorização, `phasezero-admin pacman -U
  <phasezero-control-center-1.16.2-1-any.pkg.tar.zst>`; validar versão, imports
  da UI instalada, `windows-vm status`, abrir "Gerenciar imagens" e confirmar 0
  mutação de GRUB/VM/discos/mounts; só então marcar HL-IMG-001 como `verified`.
```

### Handoff — instalação v1.16.6 + fix lock vazio (2026-08-19)

```text
Objetivo da sessão: instalar `1.16.6-1` autorizado pelo usuário e provar a
  correção da remoção na UI instalada; um terceiro defeito de remoção apareceu
  na validação e foi corrigido.
Fase/IDs assumidos: pós-Fase 10 (validação do pacote no host); sem ID novo de
  requisito (defeito de regressão do HL-IMG-001/remoção).
Branch e worktree: `main`, worktree principal
  (`/mnt/sdcard/Projects/PhaseZero`).
HEAD inicial: `d6b6285`.
HEAD final: `fe76f0f` (+ commit de docs deste registro).
Arquivos alterados: `linux/windows-vm/windows-vm.sh`,
  `tests/test_windows_vm_remove.sh`, `CHANGELOG.md`, este roadmap.
Commits criados: `fe76f0f` fix(winvm): treat empty provision lock as idle in
  removal preview; docs do roadmap.
Testes executados e resultados: teste novo (lock vazio → plan ready) falhou
  antes do fix e passou depois; `tests/test_windows_vm_remove.sh` ok;
  `tests/test_provision.sh` 257 PASS/0 FAIL; `tests/linux-windows-vm.sh` ok;
  `bash -n`; shellcheck com os excludes do CI (0 erros); `git diff --check`.
CI/PR: push de `fe76f0f` dispara CI de `main`; verificar run verde.
Estado do host antes/depois: antes `1.16.5-1`, lock vazio pré-existente
  (truncado em 2026-08-19 05:42 pelas remoções legadas), 2 VMs já removidas
  com `vmRemovedAt`; depois `1.16.6-1` (rebuild do `fe76f0f` via
  `build-arch.sh`, fix verificado dentro do artefato antes de instalar),
  `pz --version` v1.16.6, import da UI instalada ok, prévia de remoção da VM
  atual `ready:true` com 0 blockers e aviso de VM adotada. `grubenv` mtime
  `1785849543`, 0 QEMU, VM/disco/OVMF/ISO intactos. Runtime GRUB permanece
  `OUTDATED`/`stale` — sincronização adiada por decisão anterior.
Segredos verificados como ausentes: diff revisado; nenhum segredo adicionado;
  leitura de config excluiu linhas sensíveis.
Limitações e riscos restantes: pacote instalado é rebuild do `main` pós-tag
  `v1.16.6` (`d6b6285`+`fe76f0f`), não o asset publicado da release; se a
  release oficial for reinstalada depois, o fix do lock volta a faltar até uma
  nova release. Procedência da VM atual segue `adopted-existing` (legítima,
  gravada antes do fix): remoção liberada com aviso, não silenciosa.
Bloqueios reais: nenhum. Polkit autorizado nesta sessão.
Próximo passo exato: confirmar CI verde no push; quando planejar o boot físico,
  sincronizar o runtime GRUB (`phasezero-admin /usr/lib/phasezero/linux/pz
  windows-vm boot install`) e validar `runtime-check` `current`.
```

### Handoff — auditoria IA/UX, autenticação, ledger e procedência (2026-08-24)

```text
Objetivo da sessão: diagnosticar e corrigir jornadas IA/proxies/autenticação,
  integrar Hermes/9Router/Odysseus, remover falso sucesso e adicionar continuidade,
  recuperação e procedência fail-closed.
Fase/IDs assumidos: AI-UX-001, AI-UX-002, AI-UX-003, AI-UX-004 e AI-UX-005.
Branch e worktree: `feat/ai-proxies-runtime`, worktree principal
  `/mnt/sdcard/Projects/PhaseZero` já sujo; WIP pré-existente preservado.
HEAD inicial: `c09dd4d0cdbaf86bf047c957d1fc36e9cdcada25`.
HEAD final: `c09dd4d0cdbaf86bf047c957d1fc36e9cdcada25` (sem commit).
Arquivos alterados: backend IA/proxy/Hermes/Odysseus/Homelab, CLI `linux/pz`,
  catálogo/UI nativa/resultados/roteamento, testes IA/UI/workspaces, ações geradas,
  `assets/ai/*.json`, documentação e relatório de auditoria. `.mimosa/` e
  `uber-defesa-privada/` eram WIP alheio e não foram tocados.
Commits criados: nenhum. Sem stage, push, PR ou release.
Testes executados e resultados: pytest completo 640 passed + 9 subtests;
  `tests/linux-ai.sh`, `tests/linux-ai-proxies.sh`,
  `tests/linux-agent-workspaces.sh`, `tests/linux-ui.sh` verdes; ShellCheck com
  exclusões documentadas SC1091/SC2016, `bash -n`, `py_compile`, JSON e
  `git diff --check` verdes. QA offscreen 1280x800 e 1280x1080 aprovada.
CI/PR: não executados; trabalho não commitado.
Estado do host antes/depois: Homelab configurado, inativo e não saudável porque
  nenhum container está rodando; zero containers com label PhaseZero Homelab.
  Nenhum pacote, proxy, serviço, container ou workload iniciado/alterado.
Segredos verificados como ausentes: saídas AuthRegistry/proxies e ledger têm
  testes de redação; sentinelas não vazaram; novos manifests contêm somente
  URLs, versões, commits, árvores e hashes públicos, sem credencial.
Limitações e riscos restantes: snapshots/digests declaram `semanticAudit:false`;
  faltam SBOM, assinatura e rollback de atualização. Odysseus candidato tem commit
  assinado e base por digest, mas dependências Python e superfícies shell não foram
  aprovadas. Hermes tem instalador/commit fixos, mas cadeia transitiva mutável e
  release sem assinatura. Ambos continuam bloqueados. Login Mimo ainda depende de DevTools.
  “Nova Router” continua ambíguo e não foi inventado. Worktree contém WIP amplo.
Bloqueios reais: deploy Odysseus bloqueado por allowlist, lock Python, auditoria
  semântica e gate de workload; Hermes bloqueado por dependências transitivas,
  auditoria semântica, assinatura ausente e gate de workload.
Próximo passo exato: gerar SBOMs, tornar grafos transitivos reproduzíveis e revisar
  superfícies de execução; somente depois mudar `approvedForInstall/Deploy` e criar
  allowlist. Não aplicar workloads no host nesta etapa.
```

### Handoff — Hermes ponta a ponta no host (2026-08-24)

```text
Objetivo da sessão: instalar a versão estável mais recente do Hermes Agent e
  comprovar integração funcional com o host e o 9Router.
Fase/IDs assumidos: AI-UX-006; implantação posterior ao fechamento publicado do
  roadmap, autorizada explicitamente pelo usuário.
Branch e worktree: `feat/ai-proxies-runtime`, worktree principal
  `/mnt/sdcard/Projects/PhaseZero`, já sujo; WIP pré-existente preservado.
HEAD inicial: `c09dd4d0cdbaf86bf047c957d1fc36e9cdcada25`.
HEAD final: `c09dd4d0cdbaf86bf047c957d1fc36e9cdcada25` (sem commit).
Arquivos alterados nesta continuação: `linux/ai/setup-hermes.sh`, relatório de
  auditoria IA/UX e este roadmap. Demais arquivos sujos pertencem ao WIP anterior.
Commits criados: nenhum. Sem stage, push, PR ou release.
Testes executados e resultados: commit `fcbd1076a93841fa88855acce810e342a5b78101`
  e árvore `cc9f987a403a1d02b8b17cc527a57b54402e864b` conferem; `hermes config check`
  e status/doctor PhaseZero prontos; chat real via 9Router retornou `HERMES_OK`;
  Chromium headless abriu uma página; doctor live validou Browser e MCP ai-memory;
  auditoria OSV examinou 107 componentes e encontrou zero achados; testes do
  repositório: pytest 640 passed + 9 subtests; `linux-agent-workspaces`,
  `linux-ai` e `linux-ai-proxies` verdes; ShellCheck, `bash -n` e diff-check verdes.
CI/PR: não executados; trabalho não commitado.
Estado do host antes/depois: antes Hermes ausente e 9Router ativo; depois Hermes
  Agent `v0.20.5` do release `v2026.8.19` instalado em `~/.hermes`, launchers e
  desktop entry locais criados, gateway systemd de usuário habilitado/ativo com
  drop-in PhaseZero persistente e linger habilitado. Nenhum pacote de sistema,
  container, serviço root, GRUB,
  WinVM ou perfil Homelab alterado.
Segredos verificados como ausentes: configuração contém somente referência
  `${PHASEZERO_9ROUTER_API_KEY}`; launcher lê apenas a chave cliente do ambiente
  canônico modo 0600. Processo gateway não herda JWT, service secret ou variáveis
  administrativas; evidências registram nomes/estado, nunca valores.
Limitações e riscos restantes: release/commit/tag sem assinatura verificada;
  auditoria semântica e pinagem transitiva incompletas. `uv sync --locked` do
  upstream falhou e o instalador oficial caiu para resolução destravada. Doctor
  reporta 4 avisos high no workspace web e 3 no ui-tui, todos em tooling de build;
  snapshot upstream permaneceu limpo e não recebeu `npm audit fix`.
Bloqueios reais: nenhum para chat, gateway, Browser, MCP, Skills Hub, CLI ou ACP.
  Canais Telegram/Discord e acesso remoto Tailscale permanecem opcionais e não
  configurados porque exigem credenciais/escolha próprias.
Próximo passo exato: não atualizar automaticamente para `main`; auditar novo
  release, atualizar manifesto/commit e repetir provas antes de qualquer upgrade.
```

### Handoff — release v1.17.0 e validação IA/Hermes no host (2026-08-24)

```text
Objetivo da sessão: concluir implementação IA/UX, publicar release estável,
  atualizar pacote oficial no host e provar Hermes/9Router/proxies ponta a ponta.
Fase/IDs assumidos: AI-UX-001 a AI-UX-006; pós-Fase 10 para instalação oficial.
Branches e worktrees: `feat/ai-proxies-runtime` no worktree principal sujo;
  `codex/release-v1.17.0` e `codex/handoff-v1.17.0` no worktree limpo
  `/tmp/phasezero-release-v1.17.0`. WIP `.mimosa/` e
  `uber-defesa-privada/` permaneceu excluído e intocado.
HEAD inicial: `c09dd4d0cdbaf86bf047c957d1fc36e9cdcada25`.
HEADs finais: feature `9d9a722`, merge PR #64 `f0554d8`, release
  `f18079a`, merge PR #65 `2a15da7` e tag `v1.17.0`.
Arquivos alterados: UI nativa IA, ações/tarefas, CLI e backends de proxy,
  autenticação, ledger, Hermes/Odysseus/9Router, manifests de procedência,
  testes, documentação, changelog e metadados de pacote/release.
Commits criados: `d035c7b` (feature), `59b1572` e `9d9a722` (CI),
  `f18079a` (release), além deste handoff.
Testes executados e resultados: pytest 640 passed + 9 subtests;
  `tests/runner.sh` 44/44; UI smoke 28; package smoke e install-root verdes;
  ShellCheck 0.9/0.11, `bash -n`, diff-check e gitleaks verdes. CI do SHA exato
  de release run `32750364264` success, gitleaks `32750364129` success e
  release workflow `32753660173` success. Pester: 797 passed, 0 failed,
  2 skipped. Artefatos publicados: source, AppImage, Flatpak, Arch, RPM, DEB
  e SHA256SUMS; 6/6 artefatos conferiram com o manifesto e o digest GitHub.
CI/PR/release: PR #64 e PR #65 mergeados; release pública
  `https://github.com/Misael-art/PhaseZero/releases/tag/v1.17.0`.
Estado do host antes/depois: pacote `1.16.6-1` -> `1.17.0-1` pelo asset Arch
  oficial. UI instalada abriu em offscreen. Hermes Agent v0.20.5 segue
  habilitado/ativo, zero restarts/erros recentes, linger habilitado e chat real
  pós-upgrade retornou `HERMES_HOST_OK`. 9Router está saudável com 108 modelos,
  16 provedores e chat HTTP 200; DeepSeek proxy passou modelos+chat. Kimi e Qwen
  exigem renovar login; Mimo exige credenciais próprias. Registro de autenticação:
  20 entradas, 8 prontas, 0 essencial ausente; 9Router, OpenCode e Hermes prontos.
  Nenhum processo QEMU. `grubenv` manteve mtime 2026-08-04 10:19:03; runtime
  WinVM continua stale e não foi sincronizado por estar fora do escopo IA.
Conflitos/recuperação: arquivo manual antigo, sem dono e modo 777 em
  `/usr/lib/phasezero/linux/ui_native/pages/ai_dev.py` bloqueou pacman. Cópia
  modo 0600 salva em
  `~/.local/state/phasezero/backups/v1.17.0-preinstall-20260824T1706Z/ai_dev.py`;
  somente esse caminho foi sobrescrito pelo pacote. `pacman -Qkk` reporta apenas
  o launcher desktop modificado pelo hook global BigLinux com ação
  `SoftwareRender`, comportamento esperado e registrado no ai-memory.
Segredos verificados como ausentes: gitleaks e security-secret-scan verdes;
  AuthRegistry, status e logs redigem valores. Hermes referencia somente a chave
  cliente canônica 9Router; nenhum valor foi exposto ou commitado.
Limitações e riscos restantes: Hermes upstream mantém release sem assinatura,
  auditoria semântica e pinagem transitiva incompletas; risco aceito pelo operador
  e exibido como aviso. Kimi/Qwen/Mimo dependem de login humano. Odysseus permanece
  bloqueado corretamente: commit/dependências/imagens/auditoria e política de
  workload ainda não aprovados. Não instalar até fechar esses gates.
Bloqueios reais: nenhum para PhaseZero 1.17.0, Hermes, 9Router, UI, MCP,
  autenticação essencial ou inferência. Logins opcionais e Odysseus são deferred.
Próximo passo exato: renovar sessões Kimi/Qwen e fornecer credenciais Mimo apenas
  se o usuário quiser esses backends; manter Hermes no commit auditado. Não
  sincronizar GRUB nem implantar Odysseus sem autorização e gates próprios.
```

## Definição de concluído

Homelab v1.15.1 somente termina quando:

- Todos requisitos da matriz estão `verified` ou explicitamente `deferred` com
  maturidade reduzida e razão aceita.
- Fundação, perfis, operações, Player, Policy Broker, backup e governor possuem
  provas comportamentais.
- CI completa está verde.
- Novo PR foi mergeado em `main`.
- `main` está limpa.
- Release `v1.15.1` foi publicada a partir de `main`.
- Sete assets e checksums foram baixados e verificados.
- Pacote foi instalado via gerenciador de pacotes após aprovação do usuário.
- Validação pós-instalação não implantou workloads.
- Containers, serviços, listeners, mounts, GRUB e WinVM permaneceram inalterados.
- Tags anteriores permanecem intactas.
- Relatório final liga cada claim a arquivo/commit, teste e prova CI.
