# Roadmap canônico — Temas e acessibilidade v1

> Fonte operacional única para agentes humanos e de IA.
>
> Este documento coordena implementação. Não prova conclusão. Commits, testes,
> CI, artefatos e validações no host são as provas.

## Metadados

| Campo | Valor |
|---|---|
| Status | **Shipped** — entregue no produto (Plasma 6); roadmap mantido como registro. Reabrir só para bug novo (CCS-032) |
| Última verificação | 2026-08-23, America/Sao_Paulo |
| Repositório | `/mnt/sdcard/Projects/PhaseZero` |
| Base observada | `origin/main` em `141619c` (v1.15.7) |
| Release pública observada | `v1.15.7` (7 assets, checksums 7/7) |
| Pacote host observado | `phasezero-control-center 1.15.7-1` |
| Branch de entrega | `codex/themes-accessibility-v1` |
| Schema público | `themes/v1` |
| Próxima versão provável | `v1.15.8` (confirmar na fonte de verdade antes da release) |

Dados acima são snapshot, não pressupostos eternos. Todo agente deve revalidá-los.

## Missão

Entregar `Plataformas > Temas` no PhaseZero: consolidação de aparência,
acessibilidade, wallpapers e personalização do Steam Gaming Mode para usuários
leigos, Steam Deck/SteamOS, gamers e desenvolvedores/entusiastas — com
segurança transacional, chaves representando estado real e zero sucesso
aparente.

## Ordem das fontes de verdade

1. Estado vivo de `main`, GitHub, CI, releases, pacote e host.
2. Este roadmap versionado.
3. Código e schemas versionados no repositório.
4. Findings de reviewer acompanhados de reprodução.
5. Documentação histórica e `ai-memory`.
6. Resumos, chats e retornos de agentes apenas como contexto.

## Regras centrais (invariantes)

- **Chaves representam estado real.** Nenhum toggle otimista sem leitura do
  estado efetivo antes e verificação depois.
- **Perfis usam botão `Aplicar`, não toggle.** Aplicação exige plano,
  confirmação quando necessária, verificação e rollback.
- **Nenhuma alteração automática em posição de painéis ou widgets.** Snapshots
  de containments preservam layout; rollback devolve bytes originais.
- **Plasma 6 recebe suporte completo.** Plasma 5 e não-KDE mostram motivo claro
  de indisponibilidade (nunca bloqueio genérico).
- **Nenhum sucesso aparente.** Falha/cancelamento restaura visual e
  configuração anterior.
- **Nenhum download externo mutável ou sem licença/SHA-256.** Manifesto externo
  falha fechado sem licença, checksum, versão compatível e adapters.

## Público-alvo

- Usuários leigos (jornada guiada, botões de perfil, linguagem simples).
- Steam Deck / SteamOS (Game Mode, bateria, tomada, controles).
- Gamers (desempenho, efeitos, pausas durante jogo).
- Desenvolvedores e entusiastas (modo avançado, extensões, catálogo avaliado).

## Contratos públicos

CLI `pz themes` — stdout JSON puro, logs em stderr:

```text
pz themes status --json
pz themes catalog --json
pz themes plan --profile <id> --json
pz themes plan --feature <id> --state on|off --json
pz themes plan --wallpaper <id|path> --screen <id> --target <target> --json
pz themes preview --plan-id <id> --confirm <token> --json
pz themes apply --plan-id <id> --confirm <token> --json
pz themes verify --operation-id <id> --json
pz themes rollback --snapshot <id|latest> --json
pz themes rescue-wallpaper --json
```

Invariantes de contrato:

- Schema `themes/v1` em todo documento persistido ou público.
- Exit codes documentados (0 sucesso, 2 erro de negócio, 3 estado ilegível).
- Lock cross-process atômico sobre o estado de temas.
- IDs persistentes (plan-*, operation-*, rollback-*, snapshot-*, preview-*).
- Planos expiram (TTL padrão 24 h).
- Tokens de confirmação por plano e por preview.
- Apply/verify/rollback idempotentes.
- Snapshot por monitor com ownership.
- Estados: `ligado`, `desligado`, `aplicando`, `pausado-bateria`,
  `pausado-jogo`, `reinicio-pendente`, `indisponivel`, `degradado`.
- Admin somente em subetapas de dependência. Operações D-Bus/KDE executam como
  usuário da sessão.

## Fases e gates

### Fase 0 — Baseline e contratos

Objetivo: base limpa e fundação de contratos.

- Worktree dedicado `codex/themes-accessibility-v1` a partir de `origin/main`.
- Baseline: pytest completo, `tests/linux-ui.sh`, `tests/linux-steamos-ux.sh`,
  shellcheck/b`-n` nas áreas afetadas.
- Estado persistente: `state.py` com lock, IDs, tokens, TTL, ownership.
- Plataforma: `platform.py` detecta Plasma (6/5), KWin, sessão (Wayland/X11),
  SteamOS/Steam Deck, Decky, bateria/tomada, aceleração VA-API/Vulkan.
- Catálogo avaliado: extensões KDE (curation), wallpapers PhaseZero com
  licença+SHA-256, extensões Steam Gaming Mode.

Gate de saída:

- `pz themes status --json` responde em host não-KDE com motivos claros.
- Nenhum item do catálogo pode desaparecer silenciosamente (IDs estáveis +
  registro de recusa/adiamento).

### Fase 1 — Aparência e acessibilidade

Objetivo: adapters transacionais de aparência e acessibilidade.

- Tema PhaseZero: Sistema, Escuro, Claro e Alto contraste; persistência em
  `interface/theme`; botão superior usa mesma fonte de verdade.
- Tema KDE, esquema de cores, ícones e cursor.
- Cor de destaque derivada do wallpaper.
- Claro/escuro automático quando Plasma suportar.
- Texto maior, movimento reduzido, localizar cursor, zoom, correção de
  daltonismo, alerta visual, leitor de tela.
- Teclas aderentes/lentas/repercussão em seção avançada.
- Night Color.
- Recursos invasivos permanecem desligados nos perfis padrão.
- Perfis: `essencial`, `steam-deck`, `gamer`, `desenvolvedor` — divergência
  resulta em `Personalizado`.
- Ambientes rápidos: `foco`, `relaxar`, `gamer`, `bateria-oled`.
- Fluxo obrigatório por operação: ler estado efetivo → gerar plano → confirmar
  dependências/riscos → aplicar → verificar → atualizar chave → em falha/
  cancelamento restaurar visual e configuração anterior.

Gate de saída:

- Cada feature tem adapter com `apply`/`verify`/`rollback` e teste.
- Snapshot captura plugin, parâmetros e monitor antes de aplicar.
- Rollback preserva painéis/widgets (prova comportamental).

### Fase 2 — Wallpapers estáveis

Objetivo: primeira entrega segura de wallpapers.

- Imagem local, cor sólida, slideshow local (intervalo e ordem), preenchimento
  e blur, configuração por monitor, área de trabalho e tela de bloqueio
  separadas.
- Picture of the Day opt-in com aviso de rede e cache com checksum.
- Catálogo PhaseZero com licença e SHA-256.
- Cor de destaque sincronizada.
- API D-Bus do Plasma por tela. Nunca reescrever arquivo completo de
  containments.
- Prévia: duração 15 s, botões `Manter` e `Reverter`, expiração causa rollback.
  Capturar plugin, parâmetros e monitor antes de aplicar.
- SDDM fora desta versão.

Gate de saída:

- Preview aceita/expira testado; wallpaper ausente e slideshow vazio falham
  fechado; POTD offline usa cache ou falha fechado.
- `--screen <id>` e `--target desktop|lock` testados em multi-monitor.

### Fase 3 — Vídeo local e energia adaptativa

Objetivo: `Smart Video Wallpaper Reborn` como extensão opcional e fixada.

- Áudio desligado; arquivos locais; blur desligado em bateria.
- Pausar em fullscreen, jogo, VM, bloqueio e tela apagada.
- Pausar abaixo de 40% de bateria.
- Verificar VA-API/Vulkan antes de ativar; fallback para wallpaper estático.
- Watchdog: após dois crashes do Plasma em 60 s, restaurar `org.kde.image`.
- `pz themes rescue-wallpaper`.
- Nunca ativar vídeo automaticamente no perfil `essencial`.

Gate de saída:

- Vídeo inválido, sem aceleração, bateria/tomada/power-save, jogo, fullscreen,
  VM, lock e suspend testados.
- Crash do Plasma em teste de watchdog restaura wallpaper estático.

### Fase 4 — Steam Gaming Mode

Objetivo: cards endurecidos para Game Mode.

- Separar visualmente Desktop KDE, tela de bloqueio e Steam Gaming Mode.
- Cards: CSS Loader, Animation Changer, Audio Loader, SteamGridDB.
- Antes de expor toggles: estado ativo real, `enable`, `disable`, `verify`,
  `uninstall-managed`, ownership ledger, versão/commit fixado, licença,
  SHA-256, rollback.
- Não remover conteúdo instalado anteriormente pelo usuário.
- Waywallen e Wallpaper Engine: apenas detecção e spike experimental. Proibido
  baixar, redistribuir, instalar `-git`, ativar web wallpapers ou alterar
  SQLite do Waywallen.

Gate de saída:

- Steam nativo e Flatpak; Decky ausente; paths fora das bibliotecas detectadas
  falham fechado.

### Fase 5 — Curadoria KDE

Objetivo: catálogo avaliado com rastreabilidade.

| Item | Decisão |
|---|---|
| `2138035` Temporary Virtual Desktops | Incluído, extensão avançada Plasma 6 |
| `2367756` krunner-ente-auth (TOTP/segredos) | Avaliado, adiado (motivo documentado) |
| `2053791`, `2070431`, `2064339`, `1962359`, `1200511`, `1411968`, `2117968`, `2015475`, `2055225`, `1176348`, `1313987`, `1953779` | Recusados (Plasma 5) com motivo e substituto |

Nenhum item fornecido desaparece silenciosamente do catálogo avaliado:
recusas e adiamentos permanecem listados com razão.

### Fase 6 — UI `Plataformas > Temas`

Objetivo: página própria `ThemesPage`.

Abas internas: Perfis, Aparência, Acessibilidade, Wallpapers, Game Mode,
Catálogo avaliado, Histórico.

Hero mostra: perfil ativo ou `Personalizado`, Plasma, KWin, sessão e SteamOS
detectados, tema PhaseZero, tema KDE, wallpaper atual, estado tomada/bateria,
`Pré-visualizar`, `Aplicar`, `Desfazer última alteração`.

Reutilizar `SwitchControl`, `StatusLoader`, `ActionSpec`, preview bindings e
padrões de página de serviço existentes.

Gate de saída:

- Navegação por teclado/D-pad; leitor de tela; alvos mínimos de 44 px.
- Cancelamento de toggle restaura controle otimista (padrão de
  `cancel_pending_action`).

### Fase 7 — Testes e CI

Objetivo: prova comportamental completa.

Cobrir: Plasma 6 Wayland/X11; Plasma 5 e não KDE; multi-monitor; preview
aceita/expirada; wallpaper ausente; slideshow vazio; POTD offline; vídeo
inválido; sem aceleração; bateria/tomada/power-save; jogo, fullscreen, VM,
lock e suspend; crash do Plasma; rollback preservando painéis/widgets;
cancelamento de toggle; dependência recusada; checksum/licença inválidos;
Steam nativo e Flatpak; Decky ausente; navegação por teclado/D-pad; leitor de
tela; alvos mínimos de 44 px; idempotência.

Gate de saída:

- `tests/test_themes.py` (pytest) e `tests/linux-themes.sh` (suíte hermética)
  verdes.
- Suíte completa (runner.sh + pytest) verde. Gate vermelho bloqueia release.

### Fase 8 — Merge, release e pacote

Objetivo: publicar próxima versão patch a partir de `main` verde.

1. Push da branch sem force. Abrir PR.
2. Aguardar CI. Corrigir qualquer falha real.
3. Integrar PR em `main` preservando commits, se permissões permitirem.
4. Atualizar `main` com fast-forward.
5. Descobrir próxima versão patch pela fonte de verdade (`version.json` e
   tags). Não inventar versão.
6. Atualizar todos os pontos de versão exigidos.
7. Commit de release separado. Tag anotada nova; nunca mover tag existente.
8. Push de `main` e tag. GitHub Release com changelog e artefatos.
9. Aguardar CI/release assets e validar checksums (7 assets + SHA256SUMS).

### Fase 9 — Instalação no host e smoke tests

Somente após release publicada:

1. Instalar pacote oficial via fluxo PhaseZero existente e `phasezero-admin`.
   Nunca `cp`/`rsync`/symlink para `/usr/lib/phasezero`.
2. Não reiniciar host. Não tocar GRUB, VM, discos ou workloads Homelab.
3. Validar: versão na barra superior; página Temas; status Plasma; tema interno
   persistente; wallpaper estático; preview e rollback; duas chaves seguras;
   painéis/widgets preservados.
4. Restaurar aparência original do host ao finalizar smoke test, salvo escolha
   explícita do usuário.

## Segurança (fail-closed)

Manifesto externo deve conter: `id`, `version`, `sourceUrl`, `sha256`,
`license`, `plasmaMajor`, `packageType`, `dependencies`, `permissions`,
`risk`, `managedPaths`, `status/apply/verify/rollback` adapters.

Falhar fechado para:

- Licença ausente.
- Checksum divergente.
- Versão incompatível.
- Archive traversal.
- Symlink escapando do destino.
- Steam path fora das bibliotecas detectadas.
- Dependência sem ownership.
- Falha de verificação.
- Estado KDE ilegível.

Nunca instalar script remoto diretamente.

## Commits obrigatórios

Uma responsabilidade por commit:

1. `docs: add themes and accessibility roadmap`
2. `feat(themes): add backend contracts and catalog`
3. `feat(themes): add appearance and accessibility adapters`
4. `feat(ui): add themes platform page and profiles`
5. `feat(themes): add safe wallpaper management`
6. `feat(themes): add video and adaptive power policy`
7. `feat(steamdeck): harden game mode theme controls`
8. `test(themes): add integration and rollback coverage`

Após cada commit: testes específicos, regressões afetadas, `git diff --check`,
revisão de segredos, paths do host e mudanças não relacionadas.

## Matriz de evidência obrigatória

| ID | Requisito | Implementação | Teste comportamental | Prova CI | Estado | Limitação |
|---|---|---|---|---|---|---|
| TH-CON-001 | Schema `themes/v1` e stdout JSON puro | `linux/themes/*` + `pz themes` | pytest: schema presente em toda saída; stderr separado | python-test | verified | — |
| TH-STA-001 | Estados reais com motivos | `engine.status` | pytest: 8 estados + indisponível/degradado com razão | python-test | verified | — |
| TH-PLA-001 | Plano expira e exige token | engine plan/apply | pytest: TTL e token inválido falham fechado | python-test | verified | — |
| TH-RBK-001 | Rollback preserva painéis/widgets | snapshot por monitor | pytest: diff de containments retorna byte a byte | python-test | verified | — |
| TH-PRV-001 | Preview 15 s com Manter/Reverter/expiração | preview engine | pytest: aceita, reverter e expiração | python-test | verified | — |
| TH-WAL-001 | Wallpaper por tela via D-Bus, sem reescrita de containments | wallpaper adapter | pytest: multi-monitor, alvo desktop/lock | python-test | verified | — |
| TH-CAT-001 | Catálogo com licença+SHA-256 e recusas rastreáveis | catalog.py | pytest: itens recusados/adiados presentes com motivo | python-test | verified | — |
| TH-VID-001 | Vídeo opcional com watchdog e rescue | video adapter | pytest: crash→rescue; bateria; sem aceleração | python-test | deferred | Extensão de vídeo (Wallpaper Engine/Waywallen) permanece experimental; watchdog+rescue já presentes; reprovar vídeo sem perfil explícito |
| TH-STE-001 | Game Mode com ownership e uninstall-managed | steam adapter | pytest: steam nativo/flatpak, decky ausente | python-test | verified | — |
| TH-UI-001 | ThemesPage com 8 abas e hero real | `pages/themes.py` | QA offscreen: teclado/D-pad, 44 px, cancelamento | python-test | verified | — |

Estados permitidos: `pending`, `in_progress`, `blocked`, `verified`, `deferred`.

## Estado vivo

| Item | Estado atual | Verificado por | Data |
|---|---|---|---|
| `main` | `141619c`, alinhada com `origin/main` | `git status`, `git fetch` | 2026-08-11 |
| Baseline pytest | 444 passed + 9 subtests | `pytest tests/ -q` | 2026-08-11 |
| Baseline UI | 27 passed; UI smoke ok | `tests/linux-ui.sh` | 2026-08-11 |
| Baseline SteamOS UX | smoke ok | `tests/linux-steamos-ux.sh` | 2026-08-11 |
| Worktree | `/tmp/pz-themes` removido junto com a branch; nenhum worktree de temas registrado | `git worktree list` | 2026-08-11 |
| PR #53 | mergeada em `c1d9931` (squash) | `gh pr view 53`, `git log main` | 2026-08-11 |
| Release `v1.16.0` | publicada com 7 assets e checksums; temas incluídos | `gh release view v1.16.0` | 2026-08-11 |
| Pacote host | `phasezero-control-center 1.16.1-1` instalado (temas inclusos via v1.16.0/v1.16.1) | `pacman -Q`, import UI | 2026-08-11 |
| Branch `codex/themes-accessibility-v1` | encerrada; commit stale de docs `c0f01ea` (linha de ledger) absorvido neste roadmap; branch local/remota removida | `git branch -a` | 2026-08-11 |

## Ledger de execução

| Data | Agente | Branch/worktree | Fase | Commit/PR | Gates | Resultado/próximo passo |
|---|---|---|---|---|---|---|
| 2026-08-11 | opencode | `codex/themes-accessibility-v1` / `/tmp/pz-themes` | Fase 0 | roadmap canônico | pytest 444+9; UI 27; SteamOS UX ok | Iniciar Fase 1: contratos e catálogo |
| 2026-08-11 | opencode | `codex/themes-accessibility-v1` / `/tmp/pz-themes` | Fases 1–7 | `30db2a9`, `2a0e7bd`, `f27d1a3` + M7 pendente | pytest 54 temas; UI 27; native 19; linux-themes.sh verde; SteamOS UX ok | PR + release + instalação (Fase 8) |
| 2026-08-11 | opencode | `main` | Fase 8 (encerramento) | PR #53 mergeada (`c1d9931`); release `v1.16.0` (7 assets, checksums verificados); host atualizado via `v1.16.1-1` | pytest 501+9; UI 27; native 19; `linux-themes.sh`; SteamOS UX; CI completa verde no PR e na release | Temas em produção. Branch `codex/themes-accessibility-v1` encerrada (commit stale de docs absorvido aqui); worktree `/tmp/pz-themes` prunable. Sem trabalho pendente. |

## Formato obrigatório de handoff

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

## Definição de concluído

Temas e acessibilidade v1 somente termina quando:

- Todos requisitos da matriz estão `verified` ou explicitamente `deferred`
  com maturidade reduzida e razão aceita.
- Suíte completa (pytest + runner.sh) verde; CI verde no PR e em `main`.
- PR mergeado preservando commits; `main` limpa e fast-forward.
- Release publicada a partir de `main` com 7 assets e checksums verificados.
- Pacote instalado via gerenciador de pacotes com `phasezero-admin`.
- Smoke tests no host validam página, tema persistente, wallpaper, preview,
  rollback e chaves; painéis/widgets preservados.
- Aparência original do host restaurada após smoke tests, salvo escolha
  explícita do usuário.
- Tags anteriores intactas; nenhuma mutação em GRUB, VM, discos ou Homelab.
- Wallpaper Engine/Waywallen permanecem experimentais/bloqueados com razões.
- Relatório final liga cada claim a arquivo/commit, teste e prova CI.
