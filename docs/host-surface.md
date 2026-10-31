# Mapa de superfície de mutação do host

Entregável da **correção 2** (hook único do ledger). Lista, módulo a módulo,
tudo que o PhaseZero escreve/instala/habilita no host do usuário e se aquela
mutação passa por `ledger_record()`.

Regra: **nenhuma mutação de host sem `ledger_record()`**. O que ainda não está
instrumentado aparece na seção [Dívida técnica](#dívida-técnica-explícita) com
`arquivo:linha` — não em silêncio.

- Ledger: `$PZ_STATE/ledger/ledger.jsonl` (JSONL, uma linha por operação).
- Store de backups: `$PZ_STATE/backups/<sha256 do path original>/`.
- `$PZ_STATE` = `${XDG_STATE_HOME:-~/.local/state}/phasezero`.

### Contrato `~/Emulation` (CCS-017)

São **dois contratos diferentes** — não um:

1. **Wipe / higiene / uninstall nunca tocam `~/Emulation`.** É dado do
   usuário (ROMs, saves, BIOS, mídias). `linux/uninstall.sh`, `host.sh`
   (`host wipe`/`prune`) e qualquer rotina de limpeza não gravam, movem nem
   removem nada lá — e continuam assim.
2. **O módulo de emulação escreve dentro da raiz de emulação por design.**
   Layout, library, romopt, media e journeys usam
   `${PZ_EMULATION_ROOT:-$HOME/Emulation}` (`linux/emulation/common.sh`) como
   raiz de trabalho do usuário. Isso é operação normal do módulo, com backup
   via chokepoints, e não viola o item 1.

Resumo: *wipe nunca*; *módulo de emulação sim, restrito a `$PZ_EMULATION_ROOT`*.

## Chokepoints instrumentados

Estas cinco funções concentram a maioria das mutações. Instrumentando-as,
todos os call sites herdam o registro no ledger sem edição individual.

| Chokepoint | Arquivo | Registra | Call sites |
|---|---|---|---|
| `pz_write_managed_file` | `linux/lib/common.sh` | `created` (arquivo novo) ou `modified` + `backups` (arquivo pré-existente) | ~40 |
| `pz_backup_file` | `linux/lib/common.sh` | `modified` + `backups` + `rollback_cmd` | ~28 |
| `pz_systemd_install_unit` | `linux/lib/systemd.sh` | `created`/`modified` + `services` | todos os installs de unit via lib |
| `pz_systemd_enable` | `linux/lib/systemd.sh` | `services` + `rollback_cmd` | todos os enables via lib |
| `pz_rollback_register` | `linux/lib/common.sh` | `packages` (pacman/flatpak), `services`, `created` (remotes flatpak) | pipeline de perfis |
| `pz_record_created` | `linux/lib/common.sh` | `created` avulso, para mutações fora dos chokepoints acima | pontual |
| `pz_hostbackup.backup_file` | `linux/lib/pz_hostbackup.py` | contraparte Python; grava no MESMO ledger e MESMO store | 9 |

## Cobertura por módulo

Legenda: **✅ coberto** = toda mutação passa por um chokepoint · **⚠️ parcial**
= chokepoints cobrem o principal, resta dívida listada abaixo.

### `steamdeck`

| Mutação | Onde | Cobertura |
|---|---|---|
| unidades `--user` (`mode-watcher`, hotkeys) | `install-mode-watcher.sh`, `install-hotkeys.sh` | ✅ `pz_backup_file` + `pz_write_managed_file` |
| `kglobalshortcutsrc`, `kwinrc` | `install-hotkeys.sh`, `input-actions.sh` | ✅ `pz_backup_file` |
| launchers `.desktop` de conveniência | `convenience-launchers.sh` | ✅ `pz_write_managed_file` |
| bridge TDP/GPU privilegiada + polkit | `install-privileged-controls.sh` | ⚠️ escopo root, ver dívida |
| entrada GRUB console SteamOS | `install-steamos-boot.sh` | ⚠️ escopo root, ver dívida |
| plugins Decky | `plugins.sh` | ⚠️ backup de **diretório**, ver dívida |

### `windows-vm`

| Mutação | Onde | Cobertura |
|---|---|---|
| `.desktop` (launch + reboot) | `windows-vm.sh:722-725` | ✅ `pz_record_created` |
| config/wrappers da VM | `windows-vm.sh` | ✅ `pz_write_managed_file` |
| entrada GRUB direta | `windows-vm.sh boot install` | ⚠️ escopo root, ver dívida |

### `waydroid`

| Mutação | Onde | Cobertura |
|---|---|---|
| `.desktop` (launch + reboot) | `waydroid.sh:266-283` | ✅ `pz_record_created` |
| unidade `--user` `phasezero-waydroid.service` | `waydroid.sh` | ✅ `pz_record_created` |
| entrada GRUB direta / hook LXC | `waydroid.sh boot`, `waydroid-boot-prepare.sh` | ⚠️ escopo root, ver dívida |

### `emulation`

| Mutação | Onde | Cobertura |
|---|---|---|
| configs de emulador (Hydra, RPCS3, EmuDeck, SRM, Sony, dualscreen, controllers, performance) | `emulation/*.sh` | ✅ `pz_backup_file` |
| configs via Python (`write_json`) | `frontends.py`, `heroic.py`, `pc-games.py`, `launchbox.sh` | ✅ `pz_hostbackup.backup_file` |
| launchers `.desktop` de frontend | `emulation/frontends.sh`, `shortcuts.sh` | ✅ `pz_write_managed_file` |
| **`~/Emulation`** | wipe/uninstall/higiene: **nunca tocado** (contrato acima). Módulo de emulação: grava **somente** dentro de `$PZ_EMULATION_ROOT` por design | ✅ contratos separados |

### `server`

| Mutação | Onde | Cobertura |
|---|---|---|
| stack Docker homelab (compose, env) | `homelab-stack.sh` | ✅ `pz_write_managed_file` |
| LLM server (config, exposição LAN) | `llm-server.sh` | ✅ `pz_write_managed_file` |
| entrada GRUB homelab | `install-homelab-boot.sh` | ⚠️ escopo root, ver dívida |
| OS-slim (remoção reversível de pacotes) | `os-slim.sh` | ⚠️ ver dívida |

### `ai`

| Mutação | Onde | Cobertura |
|---|---|---|
| wrappers em `~/.local/bin` (9router, omniroute, odysseus, codexbar, hermes, memory, rtk) | `ai/*.sh` | ✅ `pz_write_managed_file` / `pz_record_created` |
| unidades `--user` + timers | `9router-manager.sh`, `omniroute-manager.sh`, `odysseus-manager.sh`, `proxy-suite.sh`, `desktop-apps.sh`, `setup-codexbar.sh` | ✅ `pz_write_managed_file` |
| configs de IDE/agente (Continue, ZCode, OpenCode, OMO, VS Code) | `proxy-suite.sh`, `setup-omo.sh`, `setup-opencode.sh`, `setup-ides.sh` | ✅ `pz_backup_file` |
| catálogo de MCPs | `mcp-manager.sh` | ✅ backups já em `$PZ_STATE/backups/ai-mcp` |
| segredos rotacionados | `rotate-secrets.sh` | ✅ `pz_backup_file` + `pz_rollback_register` |
| admin bridge (`phasezero-admin`, `bigsudo`) | `setup-admin-bridge.sh` | ✅ `pz_write_managed_file` |
| AppImages/ícones de desktop apps | `desktop-apps.sh` | ⚠️ ver dívida |
| metadados de contas Codex, configuração inicial por perfil, ícones/wrappers/atalhos, exclusão de perfis personalizados, organização de ícones/menu, Aparência por cor e reutilização do arquivo público Web | `ai/codex_profiles.py` | ✅ `pz_hostbackup.backup_file` / `ledger_record`, domínio `ai-codex-profiles`; metadados em `$XDG_DATA_HOME/phasezero/ai-accounts/codex-profiles`, execução em `$XDG_DATA_HOME/phasezero/codex/<id>`; Aparência altera destaque/fundo dos temas claro/escuro em configs de perfis adicionais, com backup/validação TOML; padrão intocado; ícone/wrappers do padrão em `codex-profiles/primary`; override nativo de usuário preserva protocolos, duplicações Codex conhecidas usam NoDisplay e bridge recebe owner visual/snapshot atualizado com backup; exclusão move dados/atalhos para recuperação privada em `codex-profiles/removed/<operação>/manifest.json`, remove runtime inativo e protege instalação padrão/Web padrão |

Login e atualização de credenciais/sessões continuam pertencendo ao Codex,
Chromium e ao manager Web existente. O gerenciador de perfis não lê nem copia
seus tokens. Seus registros contêm apenas identificação local. Arquivar faz
backup dos atalhos antes de remover; não apaga sessões nem para aplicativos.
Atalho `PhaseZero — Contas Codex` aponta ao launcher da raiz canônica; pacote
instalado do Control Center e suas entradas originais não são substituídos.
Configurações Electron isoladas recebem `user-dirs.dirs` gerenciado contendo
somente caminhos dos oito diretórios padrão. Atualizações usam backup central
no manager de contas, ou journal próprio no bridge standalone; configuração
global e mapas personalizados são preservados. Não amplia direitos do sandbox.

### `boot`

| Mutação | Onde | Cobertura |
|---|---|---|
| bundle de backup de boot (GRUB, ESP, efibootmgr) | `pz_boot_backup_bundle` em `linux/lib/common.sh` | ✅ `ledger_record` (`action: boot-backup-bundle`) |
| `grub.cfg` regenerado | `pz_boot_refresh_grub_config` | ⚠️ ver dívida |
| drop-in de menu seguro | `boot/recovery.sh:229` | ⚠️ ver dívida |
| entradas ISO/USB/grubfm | `boot/iso-boot.sh` | ⚠️ ver dívida |

### `capabilities`

| Mutação | Onde | Cobertura |
|---|---|---|
| receitas de capability | `capabilities/recipes.py` | ✅ delega para os módulos acima; não muta o host diretamente |

### `tuning`

| Mutação | Onde | Cobertura |
|---|---|---|
| `user.js` do Firefox | `browser-hardening.sh` | ✅ `pz_backup_file` |
| `/etc/sysctl.d/99-phasezero-dev.conf` | `dev-tweaks.sh` | ✅ backup via `pz_backup_file … root`; **escrita** ainda em dívida |
| tweaks de gaming | `gaming-tweaks.sh` | ⚠️ ver dívida |

## Dívida técnica explícita

> CCS-031 (2026-08-23): **D2–D5 ficam `deferred`** neste plano. Instrumentar
> essas mutações root (polkit, GRUB de quatro módulos, `pz_boot_atomic_install`,
> sysctl via `sudo` cru) exige executar os caminhos privilegiados no host real
> para provar comportamento — e mutar GRUB/sysctl ao vivo é proibido no
> mandato da sessão CCS. A lista abaixo permanece a fonte da dívida; um commit
> por chokepoint quando houver janela de boot autorizada.

Mutações **conhecidas e ainda não instrumentadas**. Cada linha é um item de
trabalho, não uma omissão. Nenhuma delas grava backup ao lado do original — o
critério da correção 1 continua satisfeito.

| # | Local | O que muta | Por que ainda não | Impacto |
|---|---|---|---|---|
| D1 | `linux/steamdeck/plugins.sh:884` | move plugin Decky pré-existente para `$PZ_DECKY_HOME/plugin-backups` | `pz_backup_file` só lida com arquivo; aqui é **diretório**, e o path do backup é reusado por um rollback local imediato | wipe não conhece o backup do plugin |
| D2 | `linux/steamdeck/install-privileged-controls.sh` | unidades e regras polkit em `/etc` | escrita root fora de `pz_write_managed_file`; instrumentar exige admin bridge ativa para testar | `pz host wipe` não remove; `print_root_items` cobre manualmente |
| D3 | `linux/*/[boot install]` (`steamdeck`, `windows-vm`, `waydroid`, `server`) | entradas GRUB em `/etc/grub.d` + `grub.cfg` | idem D2 | idem D2 |
| D4 | `linux/boot/recovery.sh:229`, `linux/boot/iso-boot.sh:521` | drop-in de menu seguro, payload EFI | escrita root direta via `pz_boot_atomic_install` | reversão manual pelo card de rescue |
| D5 | `linux/tuning/dev-tweaks.sh` | `sudo tee` no `sysctl.d` | usa `sudo` cru em vez de `pz_admin_run`; corrigir junto com a passagem de admin bridge | backup já centralizado; escrita não registrada |
| D6 | `linux/ai/desktop-apps.sh:200,364,536,601` | AppImages e ícones em `~/.local/share` | `install -m` direto; muitos sites, baixo risco (tudo sob namespace de dados do usuário do PhaseZero) | wipe cobre por diretório, não por ledger |
| D7 | `linux/server/os-slim.sh` | remoção reversível de pacotes do OS | tem manifesto próprio de restore; unificar com o ledger é refator maior | `pz server slim restore` continua sendo o caminho |
| D8 | `linux/ai/odysseus-manager.sh`, `9router-manager.sh`, `omniroute-manager.sh` (`install -m 0600 … MANIFEST/ENV_FILE`) | manifestos e env files | já vivem sob `$PZ_STATE`/namespace; ledger redundante para o wipe | nenhum: o wipe remove o diretório inteiro |

## Como verificar

```bash
# nenhum .bak PhaseZero fora do store central
pz host status | jq '.legacyBaksPending'      # deve ser 0

# o que o ledger conhece
jq -c '{module,action,created,modified}' ~/.local/state/phasezero/ledger/ledger.jsonl

# testes (sandboxed, sem sudo, sem tocar o host real)
pytest tests/test_host_ledger.py tests/test_help_no_host_touch.py \
       tests/test_uninstall_leaves_clean.py -q
```
