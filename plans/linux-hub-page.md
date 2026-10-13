# Plano — seção "Linux" no menu lateral (UI nativa PySide)

Alvo: `linux/ui_native` (QMainWindow, sidebar agrupada estilo EmuDeck).
Fonte de dados: catálogo Linux real do repositório (sem portar `board.json`).

## 1. Objetivo

Uma seção `Linux` no menu lateral esquerdo que abre um hub único, categorizado e
visual, onde cada app / serviço / otimização aparece como um card com:

- ícone original do app (quando disponível) + nome
- descrição do que faz
- ações secundárias (abrir, logs, status, detalhes)
- toggle **instalar / desinstalar** (ligado = instalado)
- toggle **aplicar configuração / otimização** (ligado = aplicada)
- selos visuais de reversibilidade: `manual`, `automático`, `snapshot`,
  `backup-file`, `registry`/`config-file`, `defender-exclusion` (equivalente
  Linux: `firewall`, `selinux`, `systemd-unit`), `sem rollback`
- selo de modo: `recomendado` / `opt-in` / `avançado`
- estado derivado do backend, nunca otimista

## 2. O que já existe (reaproveitar)

| Peça | Arquivo | Serve para |
|---|---|---|
| Catálogo de recursos com install/remove/status/rollback | `linux/capabilities/{catalog,engine,providers,state}.py` | fonte primária dos apps (pacote/flatpak), plano → apply → verify → rollback com token |
| CLI JSON | `pz capabilities catalog\|status\|plan\|apply\|verify\|rollback` | contrato de dados/execução já versionado (`SCHEMA`) |
| Catálogo de ações da UI | `linux/ui_native/catalog.py` (`ActionSpec`, `CATEGORIES`, `SIDEBAR_GROUPS`) | ações não-capability (IA, emulação, servidor, flatpak, ajustes) |
| Sidebar + páginas | `linux/ui_native/main_window.py`, `pages/registry.py` | ponto de inserção da nova seção |
| Execução e status | `command_runner.py`, `status_loader.py` (QProcess paralelo, parse JSON) | toggles assíncronos sem travar a UI |
| Ledger / histórico | `operation_ledger.py`, `linux/lib/ledger.sh`, `pz_backup_file` | evidência de rollback e página Resultados |
| Widgets | `widgets.py` (`SwitchControl`, `ActionCard`, `StatusPill`, `PreviewDialog`, `ProgressDialog`, `Toast`) | base visual do card |

## 3. Lacunas reais (precisam de código novo, não só UI)

1. **Metadados de rollback e modo não existem por item.** `CapabilitySpec` tem
   `risk`/`reboot`; `ActionSpec` tem `risk`/`visibility`. Nenhum descreve
   *como* se reverte nem se é `recomendado`/`opt-in`.
2. **Tuning é apply-only.** `linux/tuning/*.sh` fazem `pz_backup_file` mas não
   têm verbo `revert`/`status`. Sem isso o segundo toggle não pode desligar,
   nem mostrar estado.
3. **Ícones originais.** Hoje só `QIcon.fromTheme` (ícone genérico do tema).
   Falta resolução de ícone real do app instalado (`.desktop` → ícone do tema
   do app; flatpak → ícone do app).
4. **Ações não-capability não expõem estado instalado/aplicado** de forma
   uniforme (cada família tem seu `status`).

## 4. Modelo de dados

Adicionar `linux/ui_native/linux_hub.py` com um `HubItem` derivado, e um
**overlay declarativo** `linux/ui_native/hub_overlay.json` só para o que o
backend não sabe dizer (modo, rollback, ícone, categoria de vitrine):

```python
@dataclass(frozen=True)
class HubItem:
    id: str                 # "gaming.mangohud" | "tune.gaming" | ActionSpec.id
    kind: str               # "capability" | "tuning" | "action"
    title: str
    description: str
    section: str            # categoria visual do hub
    icon: str               # nome de tema OU caminho resolvido
    install: ToggleSpec | None   # comandos + leitura de estado
    tune: ToggleSpec | None
    rollback: tuple[str, ...]    # ("automatic","snapshot","backup-file",...)
    mode: str               # "recommended" | "opt-in" | "advanced"
    risk: str
    reboot: str
    requires: tuple[str, ...]
    conflicts: tuple[str, ...]
    reason: str             # por que está indisponível neste host
```

`ToggleSpec` carrega `status_args`, `enable_args`, `disable_args`,
`preview_args` e o `state_path` no JSON de status — o toggle nunca infere.

Regras de derivação (sem duplicar verdade):

- `kind=capability` → um `HubItem` por `CapabilitySpec`, populado por
  `pz capabilities status --json`; `installed` vem do payload; rollback =
  `("automatic",)` porque o engine grava operação + `rollbackToken`.
- `kind=tuning` → `linux/tuning/*.sh`; rollback = `("backup-file",)`.
- `kind=action` → `ActionSpec` cujo `id` está numa allowlist do overlay
  (flatpak, IA, emulação, servidor). Rollback = `("manual",)` salvo overlay.
- Overlay só pode **acrescentar** metadados. Item no overlay sem contraparte
  no catálogo real = erro de teste (evita catálogo fantasma).

## 5. Backend — mudanças mínimas necessárias

1. `linux/tuning/*.sh`: aceitar `apply | revert | status [--dry-run]`.
   - `status` imprime envelope JSON (`linux/lib/json-envelope.sh`) com
     `{ "applied": bool, "backups": [...] }`.
   - `revert` restaura via backups do ledger e registra a reversão.
2. `linux/pz`: `cmd_tune` passa a rotear `revert`/`status`; usage atualizado.
3. `linux/capabilities/engine.py`: `catalog_payload` ganha `mode` e
   `rollback` no item (lidos do próprio `CapabilitySpec`, campos novos com
   default `"opt-in"` / `("automatic",)`), para a UI não adivinhar.
4. `pz capabilities remove --capability <id>`: atalho que resolve a última
   operação de instalação e chama `rollback_operation` com o token
   armazenado — hoje a UI teria que carregar `operation-id` na mão.

## 6. UI — mudanças

1. `catalog.py`
   - `CATEGORIES += ("Linux", "distributor-logo", "Apps, serviços e otimizações do sistema")`
   - `SIDEBAR_GROUPS`: novo grupo no topo, `("Linux", ("Linux",))`, ou item
     dentro de `Ações rápidas` — decidir na revisão visual; padrão do plano:
     grupo próprio, primeiro depois de `Ações rápidas`.
2. `pages/linux_hub.py` — `LinuxHubPage(BasePage)`:
   - coluna de filtros à esquerda do conteúdo (seções + chips: `instalado`,
     `recomendado`, `opt-in`, `reversível`), busca no topo;
   - grade responsiva de `HubAppCard`;
   - carregamento assíncrono: skeletons (`SkeletonCard`) → `StatusLoader`
     dispara `capabilities status` (1 chamada, cobre N itens) + status por
     família; item sem status vira chip `desconhecido`, nunca "desligado".
3. `widgets.py` — `HubAppCard`:
   - linha 1: ícone 32px + título + selo de modo;
   - linha 2: descrição (2 linhas, elide);
   - linha 3: selos de rollback (ícone + tooltip explicando o mecanismo);
   - linha 4: `SwitchControl` "Instalado" e `SwitchControl` "Otimizado" +
     botão `⋯` (ações secundárias / detalhes / logs).
   - Estado desabilitado quando `applicable=False`, com `reason` no tooltip.
4. `icons.py` (novo): resolução em cascata
   `overlay explícito → ícone do .desktop instalado → ícone do tema por nome
   do pacote/flatpak → fallback da categoria`. Sem download de logo pela rede.
5. `pages/registry.py`: mapear `"Linux": LinuxHubPage`.

## 7. Fluxo dos toggles (o ponto crítico de confiança)

Ligar instalação:
1. `plan` (`pz capabilities plan --capability <id>`) → `PreviewDialog` mostra
   comandos, fontes, dependências arrastadas, reboot e risco;
2. confirmação → `apply` via `CommandRunner` com `ProgressDialog`;
3. `verify` → só então o switch fica ligado; falha ⇒ volta ao estado anterior
   e abre `ResultDialog` com stderr saneado.

Desligar: `remove` (§5.4) com o mesmo ciclo preview → confirmar → verificar.

Toggle de otimização: idêntico, usando `tune <area> apply|revert` com
`--dry-run` como preview.

Invariantes:
- o switch **nunca** muda antes da verificação; usa estado `pending`;
- ação elevada mantém o caminho de escalonamento existente (`phasezero-admin`),
  sem sudo sem senha;
- toda operação grava no `operation_ledger` e aparece em **Resultados**.

## 8. Testes

- `tests/` (pytest do lado Linux): derivação `HubItem` — todo item do overlay
  existe no catálogo real; todo `HubItem` mutável tem preview e status.
- Contrato: `pz capabilities status` e `pz tune <area> status` retornam JSON
  válido com as chaves consumidas pela página.
- `linux/tuning/*.sh`: apply → status(applied) → revert → status(not applied),
  em HOME sandboxado (um `export` por variável).
- Smoke da UI: instanciar `LinuxHubPage` offscreen (`QT_QPA_PLATFORM=offscreen`)
  e conferir contagem de cards e selos.

## 9. Ordem de execução

1. ~~Verbos `status`/`revert` no tuning + roteamento no `pz` (+ testes bash).~~ **feito**
   (`linux/tuning/tune-common.sh`, `tests/linux-tuning-lifecycle.sh`, CI registrada)
2. ~~`mode`/`rollback` no payload de capabilities + `capabilities remove`.~~ **feito**
   (`mode_for`/`rollback_kinds` derivados; `remove-plan` / `remove` / `verify-removal`)
3. ~~`linux_hub.py` (derivação) + overlay + testes de derivação.~~ **feito**
   (`linux/ui_native/linux_hub.py`, `hub_overlay.json`, `tests/test_linux_hub.py`;
   `hasStatus` no payload distingue "não instalado" de "não perguntamos")
4. ~~`icons.py`.~~ **feito** (`linux/ui_native/icons.py` + `widgets.hub_item_icon`;
   `tests/test_linux_hub_icons.py`)
5. ~~`HubAppCard` + `LinuxHubPage` + registro da categoria/sidebar.~~ **feito**
   (`widgets.HubAppCard`, `pages/linux_hub.py`, categoria em `CATEGORIES` +
   `SIDEBAR_GROUPS`, estilos `#hub*` em `theme.qss`; `tests/test_linux_hub_ui.py`)
6. ~~Smoke offscreen, revisão visual, ajuste de agrupamento da sidebar.~~ **feito**
   (render offscreen do app inteiro; cartão passou a ser linha densa depois da
   primeira revisão visual, rótulos curtos no trilho lateral)

Etapas 1–3 entregam valor sozinhas (CLI reversível e honesta); 4–6 são a
camada visual.
