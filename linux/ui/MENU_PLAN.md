# Menu PhaseZero unificado

> Implementação atual: `linux/ui/menu.py`. Os scripts de jogos e web apps
> materializam uma única raiz reversível; esta seção substitui o plano legado
> de duas raízes descrito abaixo.

```text
PhaseZero
├── Central de Controle
├── Jogos e emulação
│   ├── Biblioteca e favoritos
│   ├── Frontends
│   ├── Emuladores
│   └── Ferramentas
├── Apps web
│   ├── Comunicação
│   ├── Mídia
│   ├── IA
│   ├── Nuvem e documentos
│   └── Produtividade
└── Sistema e sessões
    ├── Steam Deck
    ├── Boot e recuperação
    └── Máquinas e Android
```

Comandos: `pz ui menu scan|plan|apply|rollback`. Scan/plan são somente leitura.
Apply usa escrita atômica e ledger privado `0600`. Jogos individuais permanecem
ocultos, salvo `X-PhaseZero-Favorite=true` ou `X-PHZ-ShowInMenu=true`.

## Aplicativos PhaseZero gerenciados

`pz ui launchers install|status|verify` materializa e valida os aplicativos
operacionais do host. Cada entrada chama `phasezero-kde-launch`, usa caminho
estável e possui ícone SVG próprio no tema `hicolor`.

Grupos atuais:

- Sistema: Control Center, Port_Steam, 9Router e Windows VM.
- Sessões: perfis Steam Deck, interface Steam, teclado, voz e atalhos.
- Boot: Windows VM e SteamOS Plus, sempre com confirmação e preflight.
- IA local: Odysseus, Hermes e Ollama. Política Homelab pode bloquear execução.
- Proxies: uma entrada por backend conhecido. Ausência segura mostra diagnóstico;
  não baixa código mutável nem executa instalador sem proveniência validada.

`status --json` separa prontidão do lançador (`launcherReady`, `desktopReady`,
`iconReady`) da prontidão do backend (`backend`). Assim, menu continua íntegro
mesmo quando serviço opcional está bloqueado ou ainda não instalado.

Ícones PhaseZero são adicionados somente em `hicolor/scalable/apps`. O
instalador não cria `~/.local/share/icons/hicolor/index.theme`: índice local
parcial sombreia o índice completo do sistema e quebra ícones nativos em outros
tamanhos. Migração remove somente o índice incompleto legado de hash conhecido;
índice personalizado do usuário permanece byte a byte. A mesma migração invalida
uma única vez `icon-cache.kcache` e reconstrói `ksycoca` sem incremento. Plasma
recarrega o cache no ciclo normal; instalador nunca reinicia nem recarrega shell.

## Histórico: estrutura anterior

## 1. XDG Menu Structure

### Submenus inseridos (merged, não substitui existente)

```
Aplicativos
├── Web Apps              ← novo (merged menu)
│   ├── Comunicação       ← subdirectory
│   ├── Mídia
│   ├── IA
│   ├── Nuvem & Docs
│   └── Produtividade
├── Jogos                 ← novo (merged menu)
│   ├── Jogos PC
│   ├── Emuladores
│   ├── Frontends
│   └── Ferramentas
└── ... (resto existente, untouched)
```

## 2. Files Created (all in home local)

| Path | Content |
|------|---------|
| `~/.local/share/applications/phz-<slug>.desktop` | Web app launcher |
| `~/.local/share/applications/phz-game-<slug>.desktop` | Game/emulator launcher |
| `~/.local/share/desktop-directories/phz-webapps.directory` | Root Web Apps category |
| `~/.local/share/desktop-directories/phz-communication.directory` | Comunicação subcategory |
| `~/.local/share/desktop-directories/phz-media.directory` | Mídia subcategory |
| `~/.local/share/desktop-directories/phz-ai.directory` | IA subcategory |
| `~/.local/share/desktop-directories/phz-cloud.directory` | Nuvem & Docs subcategory |
| `~/.local/share/desktop-directories/phz-productivity.directory` | Produtividade subcategory |
| `~/.local/share/desktop-directories/phz-games.directory` | Root Jogos category |
| `~/.local/share/desktop-directories/phz-games-pc.directory` | Jogos PC subcategory |
| `~/.local/share/desktop-directories/phz-emulators.directory` | Emuladores subcategory |
| `~/.local/share/desktop-directories/phz-frontends.directory` | Frontends subcategory |
| `~/.local/share/desktop-directories/phz-gaming-tools.directory` | Ferramentas subcategory |
| `~/.config/menus/applications-merged/phz-webapps.menu` | Web Apps merged menu |
| `~/.config/menus/applications-merged/phz-games.menu` | Jogos merged menu |
| `~/.local/share/icons/hicolor/*/apps/phz-<slug>.svg/.png` | App icons |

## 3. Scripts

### `linux/ui/webapp.sh`

```
linux/pz webapp <command> [slug]

Commands:
  install <slug>     Cria .desktop + icon para um webapp
  install-all        Instala todos os 36 webapps
  remove <slug>      Remove .desktop + icon
  status             Lista instalados vs available
  icons              Baixa SVGs (SimpleIcons) + converte ICO→PNG
  menu               Gera .directory + .menu XML
```

### `linux/ui/games.sh`

```
linux/pz games <command> [slug]

Commands:
  scan               Detecta emuladores/jogos instalados no sistema
  install <slug>     Cria .desktop wrappers para um game app
  install-all        Instala .desktop para todos detectados
  remove <slug>      Remove .desktop
  status             Lista detectados vs com .desktop
  menu               Gera .directory + .menu XML
```

## 4. Web Apps per Subgrupo

| Subgrupo | Apps (slug → URL) |
|----------|-------------------|
| **Comunicação** | discord → https://discord.com/app, slack → https://slack.com, whatsapp → https://web.whatsapp.com, telegram → https://web.telegram.org, zoom → https://zoom.us |
| **Mídia** | netflix → https://netflix.com, youtube → https://youtube.com, spotify → https://open.spotify.com, amazon-prime-video → https://primevideo.com, photopea → https://photopea.com |
| **IA** | gemini → https://gemini.google.com, kimi → https://kimi.com, z-ai → https://chat.z.ai, manus → https://manus.im, google-ai-studio → https://aistudio.google.com, xiaomi-ai-studio → https://aistudio.xiaomimimo.com, v0-dev → https://v0.dev, lovable-dev → https://lovable.dev, bolt-new → https://bolt.new |
| **Nuvem & Docs** | google-drive → https://drive.google.com, google-docs → https://docs.google.com, google-sheets → https://sheets.google.com, google-slides → https://slides.google.com, gmail → https://mail.google.com, google-agenda → https://calendar.google.com, google-keep → https://keep.google.com, google-meet → https://meet.google.com, icloud → https://icloud.com, onedrive → https://onedrive.live.com, dropbox → https://dropbox.com, mega → https://mega.nz |
| **Produtividade** | notion → https://notion.so, trello → https://trello.com, office-word → https://office.com, office-excel → https://office.com, office-powerpoint → https://office.com, photopea → https://photopea.com |

## 5. Games per Subgrupo

| Subgrupo | Apps | .desktop target |
|----------|------|----------------|
| **Jogos PC** | Steam | system steam.desktop |
| | Heroic | system heroic.desktop |
| | Lutris | system lutris.desktop |
| **Emuladores** | RetroArch | system retroarch.desktop |
| | Dolphin | system dolphin-emu (se instalado) |
| | PCSX2 | system pcsx2 (se instalado) |
| | RPCS3 | system rpcs3 (se instalado) |
| | Ryujinx | system ryujinx (se instalado) |
| | DuckStation | system duckstation (se instalado) |
| | Citron | PhaseZero-installed AppImage |
| | Eden | PhaseZero-installed AppImage |
| **Frontends** | EmuDeck | PhaseZero-installed AppImage |
| | RetroDECK | system retrodeck (se instalado) |
| | LaunchBox | PhaseZero-managed |
| | ES-DE | system es-de (se instalado) |
| | Steam ROM Manager | PhaseZero-managed AppImage |
| **Ferramentas** | Steam Gamepad UI | custom .desktop |
| | Steam Deck Handheld | custom .desktop |
| | Steam Deck Dock TV | custom .desktop |
| | Steam Deck Dock Monitor | custom .desktop |
| | Steam Deck Dev | custom .desktop |

## 6. Icon Sources

| Source | Count | Method |
|--------|-------|--------|
| SimpleIcons SVG | 23 webapps | `curl -fsSL https://cdn.simpleicons.org/<slug>` |
| ICO→PNG | 13 webapps | `convert assets/webapp-icons/<slug>.ico` |
| System theme | games (referência) | link existente ou themed_icon |

## 7. Desktop File Template

```ini
[Desktop Entry]
Type=Application
Name=<Display Name>
Comment=<description>
Exec=xdg-open <url>
Icon=phz-<slug>
Categories=X-PhaseZero-WebApp;
X-PHZ-Group=<subgrupo>
Terminal=false
StartupNotify=true
```

For games:

```ini
[Desktop Entry]
Type=Application
Name=<Display Name>
Comment=<description>
Exec=<game-binary> %f
Icon=phz-game-<slug>
Categories=X-PhaseZero-Game;
X-PHZ-Group=<subgrupo>
Terminal=false
StartupNotify=true
MimeType=<se aplicável>
```

## 8. .menu XML structure

```xml
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
 "http://www.freedesktop.org/standards/menu-spec/1.0/menu.dtd">
<Menu>
  <Name>Web Apps</Name>
  <Directory>phz-webapps.directory</Directory>
  <Include>
    <Category>X-PhaseZero-WebApp</Category>
  </Include>
  <Menu>
    <Name>Comunicação</Name>
    <Directory>phz-communication.directory</Directory>
    <Include>
      <Filename>phz-discord.desktop</Filename>
      <Filename>phz-slack.desktop</Filename>
      ...
    </Include>
  </Menu>
  ...
</Menu>
```
