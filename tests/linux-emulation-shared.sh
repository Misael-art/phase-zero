#!/usr/bin/env bash
# Smoke tests for PhaseZero Linux emulation shared-content and media.
# shellcheck disable=SC2030,SC2031 # pz commands run in intentionally isolated subshell envs
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export PZ_EMULATION_ROOT="$TMP_ROOT/Emulation"
export PZ_APPLICATIONS_DIR="$TMP_ROOT/Applications"
export PZ_LOCAL_BIN="$TMP_ROOT/bin"
export PZ_RETRODECK_ROOT="$TMP_ROOT/retrodeck"
export PZ_EMULATION_FORCE_APPLY=1

mkdir -p "$HOME" "$PZ_RETRODECK_ROOT" "$PZ_EMULATION_ROOT"

# === shared-content tests ===

# shared plan does not write
"$REPO_ROOT/linux/pz" emulation layout >/dev/null
test -d "$PZ_EMULATION_ROOT/bios"
"$REPO_ROOT/linux/pz" emulation shared plan >/dev/null
[ ! -L "$PZ_RETRODECK_ROOT/roms" ] || { echo "FAIL: plan wrote symlink"; exit 1; }

# shared apply creates symlinks
mkdir -p "$PZ_EMULATION_ROOT/roms/switch" "$PZ_EMULATION_ROOT/bios" "$PZ_EMULATION_ROOT/cheats" "$PZ_EMULATION_ROOT/patches" "$PZ_EMULATION_ROOT/mods" "$PZ_EMULATION_ROOT/texture_packs"
"$REPO_ROOT/linux/pz" emulation shared apply >/dev/null
test -L "$PZ_RETRODECK_ROOT/roms" || { echo "FAIL: roms symlink missing"; exit 1; }
test -L "$PZ_RETRODECK_ROOT/bios" || { echo "FAIL: bios symlink missing"; exit 1; }
test -L "$PZ_RETRODECK_ROOT/cheats" || { echo "FAIL: cheats symlink missing"; exit 1; }
test -L "$PZ_RETRODECK_ROOT/patches" || { echo "FAIL: patches symlink missing"; exit 1; }
test -L "$PZ_RETRODECK_ROOT/mods" || { echo "FAIL: mods symlink missing"; exit 1; }
test -L "$PZ_RETRODECK_ROOT/texture_packs" || { echo "FAIL: texture_packs symlink missing"; exit 1; }
test "$(readlink "$PZ_RETRODECK_ROOT/roms")" = "$PZ_EMULATION_ROOT/roms" || { echo "FAIL: roms symlink wrong target"; exit 1; }
test "$(readlink "$PZ_RETRODECK_ROOT/bios")" = "$PZ_EMULATION_ROOT/bios" || { echo "FAIL: bios symlink wrong target"; exit 1; }
test "$(readlink "$HOME/ES-DE/gamelists")" = "$PZ_EMULATION_ROOT/metadata/gamelists" || { echo "FAIL: ES-DE gamelists wrong target"; exit 1; }
test "$(readlink "$HOME/ES-DE/themes")" = "$PZ_EMULATION_ROOT/themes" || { echo "FAIL: ES-DE themes wrong target"; exit 1; }

# shared apply with existing RetroDECK saves tree - backup + merge + root link
rm -f "$PZ_RETRODECK_ROOT/saves"
rm -rf "$PZ_EMULATION_ROOT/saves/psx"
mkdir -p "$PZ_RETRODECK_ROOT/saves/psx/duckstation"
echo "save-data" > "$PZ_RETRODECK_ROOT/saves/psx/duckstation/save.mcd"
"$REPO_ROOT/linux/pz" emulation shared apply >/dev/null
test -L "$PZ_RETRODECK_ROOT/saves" || { echo "FAIL: saves root symlink missing after migration"; exit 1; }
test "$(readlink "$PZ_RETRODECK_ROOT/saves")" = "$PZ_EMULATION_ROOT/saves" || { echo "FAIL: saves root wrong target"; exit 1; }
test -f "$PZ_EMULATION_ROOT/saves/psx/duckstation/save.mcd" || { echo "FAIL: migrated save file missing in canonical"; exit 1; }
# backup should exist
_backup_found=0
for _bf in "$PZ_EMULATION_ROOT/.phasezero/backups/"retrodeck-saves*; do
    [ -e "$_bf" ] && _backup_found=1 && break
done
[ "$_backup_found" -eq 1 ] || { echo "FAIL: saves backup not created"; exit 1; }

# shared status reports correct state
"$REPO_ROOT/linux/pz" emulation shared status >/dev/null
# verify status output contains expected info (no crash)

# drift vira dica de convergência no texto (rc0), alinhado ao --json
grep -q "pz emulation shared apply" "$REPO_ROOT/linux/emulation/shared-content.sh"
grep -q "pz emulation media apply --plan" "$REPO_ROOT/linux/emulation/media.sh"
echo "  drift hints ok"

# shared plan after apply shows no changes
"$REPO_ROOT/linux/pz" emulation shared plan >/dev/null
# should not error

# shared plan with conflict detection
mkdir -p "$PZ_RETRODECK_ROOT/bios.bak"
mv "$PZ_RETRODECK_ROOT/bios" "$PZ_RETRODECK_ROOT/bios.bak/orig"
mkdir -p "$PZ_RETRODECK_ROOT/bios"
echo "conflict-bios" > "$PZ_RETRODECK_ROOT/bios/scph1000.bin"
"$REPO_ROOT/linux/pz" emulation shared apply >/dev/null
test -f "$PZ_EMULATION_ROOT/bios/scph1000.bin" || { echo "FAIL: conflict bios not migrated"; exit 1; }

# shared repair - break symlink and fix
rm -f "$PZ_RETRODECK_ROOT/roms"
"$REPO_ROOT/linux/pz" emulation shared repair >/dev/null
test -L "$PZ_RETRODECK_ROOT/roms" || { echo "FAIL: repair did not recreate roms symlink"; exit 1; }

# === media tests ===

# media apply creates compat aliases
mkdir -p "$PZ_EMULATION_ROOT/tools/downloaded_media/psx/covers"
echo "cover-art" > "$PZ_EMULATION_ROOT/tools/downloaded_media/psx/covers/Crash.png"
mkdir -p "$PZ_EMULATION_ROOT/roms/psx"
echo "rom-data" > "$PZ_EMULATION_ROOT/roms/psx/Crash.chd"
"$REPO_ROOT/linux/pz" emulation media apply >/dev/null
test -d "$PZ_EMULATION_ROOT/media/steamgrid" || { echo "FAIL: steamgrid dir missing"; exit 1; }
test -f "$PZ_EMULATION_ROOT/media/index/media-index.json" || { echo "FAIL: media-index.json missing"; exit 1; }
test -L "$XDG_DATA_HOME/duckstation/covers" || { echo "FAIL: DuckStation covers media link missing"; exit 1; }
test "$(readlink "$XDG_DATA_HOME/duckstation/covers")" = "$PZ_EMULATION_ROOT/tools/downloaded_media/psx/covers" || { echo "FAIL: DuckStation covers wrong target"; exit 1; }
test -L "$PZ_EMULATION_ROOT/storage/pcsx2/covers" || { echo "FAIL: PCSX2 covers media link missing"; exit 1; }
test "$(readlink "$PZ_EMULATION_ROOT/storage/pcsx2/covers")" = "$PZ_EMULATION_ROOT/tools/downloaded_media/ps2/covers" || { echo "FAIL: PCSX2 covers wrong target"; exit 1; }
test -L "$HOME/.cache/dolphin-emu/GameCovers" || { echo "FAIL: Dolphin cover cache link missing"; exit 1; }
test "$(readlink "$HOME/.cache/dolphin-emu/GameCovers")" = "$PZ_EMULATION_ROOT/tools/downloaded_media/dolphin/covers" || { echo "FAIL: Dolphin cover cache wrong target"; exit 1; }
test -L "$XDG_CONFIG_HOME/retroarch/thumbnails" || { echo "FAIL: RetroArch thumbnails link missing"; exit 1; }
test "$(readlink "$XDG_CONFIG_HOME/retroarch/thumbnails")" = "$PZ_EMULATION_ROOT/tools/downloaded_media/retroarch/thumbnails" || { echo "FAIL: RetroArch thumbnails wrong target"; exit 1; }

# media status works
"$REPO_ROOT/linux/pz" emulation media status >/dev/null
env -u XDG_CONFIG_HOME HOME="$HOME" XDG_DATA_HOME="$XDG_DATA_HOME" PZ_EMULATION_ROOT="$PZ_EMULATION_ROOT" PZ_RETRODECK_ROOT="$PZ_RETRODECK_ROOT" "$REPO_ROOT/linux/pz" emulation media status --json | jq -e '.module == "emulation"' >/dev/null || { echo "FAIL: media status --json without XDG_CONFIG_HOME"; exit 1; }

# media plan doesn't crash
"$REPO_ROOT/linux/pz" emulation media plan >/dev/null

# media index builds correctly
"$REPO_ROOT/linux/pz" emulation media index >/dev/null
jq -e '.stats.roms_indexed >= 1' "$PZ_EMULATION_ROOT/media/index/media-index.json" >/dev/null || { echo "FAIL: media index has no roms"; exit 1; }

# Switch Update/MOD/DLC folders must be ignored by media scans
mkdir -p \
    "$PZ_EMULATION_ROOT/roms/switch/Nintendo Switch (Update)" \
    "$PZ_EMULATION_ROOT/roms/switch/Nintendo Switch (MOD)" \
    "$PZ_EMULATION_ROOT/roms/switch/Nintendo Switch (DLC)"
echo "base" > "$PZ_EMULATION_ROOT/roms/switch/BaseGame.nsp"
echo "update" > "$PZ_EMULATION_ROOT/roms/switch/Nintendo Switch (Update)/BaseGame Update.nsp"
echo "mod" > "$PZ_EMULATION_ROOT/roms/switch/Nintendo Switch (MOD)/BaseGame Mod.nsp"
echo "dlc" > "$PZ_EMULATION_ROOT/roms/switch/Nintendo Switch (DLC)/BaseGame DLC.nsp"
"$REPO_ROOT/linux/pz" emulation media index >/dev/null
jq -e '.systems.switch.rom_count == 1 and (.systems.switch.roms | has("BaseGame")) and ((.systems.switch.roms | has("BaseGame Update")) | not) and ((.systems.switch.roms | has("BaseGame Mod")) | not) and ((.systems.switch.roms | has("BaseGame DLC")) | not)' "$PZ_EMULATION_ROOT/media/index/media-index.json" >/dev/null || { echo "FAIL: Switch Update/MOD/DLC folders not ignored"; jq '.systems.switch' "$PZ_EMULATION_ROOT/media/index/media-index.json"; exit 1; }

# SRM localImagesDirectory set
mkdir -p "$XDG_CONFIG_HOME/steam-rom-manager/userData"
cat > "$XDG_CONFIG_HOME/steam-rom-manager/userData/userSettings.json" <<'JSON'
{"environmentVariables":{"steamDirectory":"","romsDirectory":"","retroarchPath":"","localImagesDirectory":"","userAccounts":[]},"autoKillSteam":false,"autoRestartSteam":false}
JSON
"$REPO_ROOT/linux/pz" emulation media apply >/dev/null
jq -e --arg sg "$PZ_EMULATION_ROOT/media/steamgrid" '.environmentVariables.localImagesDirectory == $sg' "$XDG_CONFIG_HOME/steam-rom-manager/userData/userSettings.json" >/dev/null || { echo "FAIL: SRM localImagesDirectory not set"; exit 1; }

# RetroDECK ES-DE media pointing
mkdir -p "$PZ_RETRODECK_ROOT/ES-DE"
"$REPO_ROOT/linux/pz" emulation media apply >/dev/null
test -L "$PZ_RETRODECK_ROOT/ES-DE/downloaded_media" || { echo "FAIL: RetroDECK ES-DE media symlink missing"; exit 1; }
test "$(readlink "$PZ_RETRODECK_ROOT/ES-DE/downloaded_media")" = "$PZ_EMULATION_ROOT/tools/downloaded_media" || { echo "FAIL: RetroDECK ES-DE media wrong target"; exit 1; }

# ES-DE settings file gets updated
ESDE_SETTINGS="$HOME/.emulationstation/es_settings.xml"
mkdir -p "$HOME/.emulationstation"
cat > "$ESDE_SETTINGS" <<'XML'
<?xml version="1.0"?>
<config>
  <string name="MediaDirectory" value="/some/other/path" />
  <string name="ROMDirectory" value="/some/other/roms" />
</config>
XML
"$REPO_ROOT/linux/pz" emulation media apply >/dev/null
grep -q 'value="'"$PZ_EMULATION_ROOT/tools/downloaded_media"'"' "$ESDE_SETTINGS" || { echo "FAIL: ES-DE MediaDirectory not updated"; exit 1; }
grep -q 'value="'"$PZ_EMULATION_ROOT/roms"'"' "$ESDE_SETTINGS" || { echo "FAIL: ES-DE ROMDirectory not updated"; exit 1; }

# Hydra LevelDB not touched - verify it doesn't get created by our scripts
if test -d "$XDG_CONFIG_HOME/hydralauncher/leveldb"; then
    echo "FAIL: Hydra LevelDB should not be touched"
    exit 1
fi

# === LaunchBox compatibility tree and emulator bridge ===
LB_ROOT="$PZ_EMULATION_ROOT/tools/launchers/LaunchBox"
mkdir -p "$LB_ROOT/Data/Platforms" "$LB_ROOT/Data/Playlists" "$PZ_EMULATION_ROOT/roms/switch" "$PZ_EMULATION_ROOT/tools/downloaded_media/switch/videos"
cat > "$LB_ROOT/LaunchBox.exe" <<'EOF'
stub
EOF
cat > "$LB_ROOT/BigBox.exe" <<'EOF'
stub
EOF
cat > "$LB_ROOT/Data/Emulators.xml" <<'XML'
<?xml version="1.0" standalone="yes"?>
<LaunchBox>
  <Emulator>
    <ApplicationPath>..\emulators\Nintendo Switch\yuzu.exe</ApplicationPath>
    <CommandLine />
    <ID>switch</ID>
    <Title>Yuzu</Title>
  </Emulator>
  <Emulator>
    <ApplicationPath>..\emulators\RetroArch\retroarch.exe</ApplicationPath>
    <CommandLine />
    <ID>ra</ID>
    <Title>Retroarch</Title>
  </Emulator>
</LaunchBox>
XML
cat > "$LB_ROOT/Data/BigBoxSettings.xml" <<'XML'
<?xml version="1.0" standalone="yes"?>
<LaunchBox>
  <BigBoxSettings>
    <Theme>Pulse</Theme>
    <StartupTheme>StageBox</StartupTheme>
    <VideoPlaybackEngine>VLC</VideoPlaybackEngine>
    <ShowStartupSplashScreen>true</ShowStartupSplashScreen>
    <UseStartupScreen>true</UseStartupScreen>
    <PlatformsUseRandomGameVideos>true</PlatformsUseRandomGameVideos>
  </BigBoxSettings>
</LaunchBox>
XML
cat > "$LB_ROOT/Data/Settings.xml" <<'XML'
<?xml version="1.0" standalone="yes"?>
<LaunchBox>
  <Settings>
    <ShowLaunchBoxSplashScreen>true</ShowLaunchBoxSplashScreen>
    <UseStartupScreen>true</UseStartupScreen>
    <ShowDetailsVideo>true</ShowDetailsVideo>
    <VideoCheck>true</VideoCheck>
  </Settings>
</LaunchBox>
XML
cat > "$LB_ROOT/Data/Platforms.xml" <<'XML'
<?xml version="1.0" standalone="yes"?>
<LaunchBox>
  <Platform>
    <Category />
    <Name>Nintendo Switch</Name>
  </Platform>
  <Platform>
    <Category />
    <Name>PhaseZero Frontends</Name>
  </Platform>
  <PlatformCategory>
    <Name>Consoles</Name>
    <NestedName>Consoles</NestedName>
    <Category />
  </PlatformCategory>
  <PlatformCategory>
    <Name>Computers</Name>
    <NestedName>Computers</NestedName>
    <Category />
  </PlatformCategory>
</LaunchBox>
XML
cat > "$LB_ROOT/Data/Parents.xml" <<'XML'
<?xml version="1.0" standalone="yes"?>
<LaunchBox>
  <Parent>
    <PlatformName>Nintendo Switch</PlatformName>
    <PlaylistId />
    <PlatformCategoryName />
    <ParentPlatformName />
    <ParentPlaylistId />
    <ParentPlatformCategoryName>Consoles</ParentPlatformCategoryName>
  </Parent>
  <Parent>
    <PlatformName />
    <PlaylistId />
    <PlatformCategoryName>Consoles</PlatformCategoryName>
    <ParentPlatformName />
    <ParentPlaylistId />
    <ParentPlatformCategoryName />
  </Parent>
</LaunchBox>
XML
cat > "$LB_ROOT/Data/Platforms/Nintendo Switch.xml" <<'XML'
<?xml version="1.0" standalone="yes"?>
<LaunchBox>
  <Game>
    <Title>Base Game</Title>
    <Platform>Nintendo Switch</Platform>
    <ApplicationPath>..\Roms\Nintendo Switch\Base Game.nsp</ApplicationPath>
  </Game>
  <Game>
    <Title>Video</Title>
    <Platform>Nintendo Switch</Platform>
    <ApplicationPath>..\Roms\Nintendo Switch\media\videos\Base Game.mp4</ApplicationPath>
  </Game>
</LaunchBox>
XML
echo "rom" > "$PZ_EMULATION_ROOT/roms/switch/Base Game.nsp"
echo "video" > "$PZ_EMULATION_ROOT/tools/downloaded_media/switch/videos/Base Game.mp4"
PZ_LAUNCHBOX_SKIP_WINEBOOT=1 PZ_LAUNCHBOX_SKIP_FONTS=1 "$REPO_ROOT/linux/pz" emulation launchbox repair >/dev/null
test -L "$PZ_EMULATION_ROOT/tools/launchers/Roms/Nintendo Switch/Base Game.nsp" || { echo "FAIL: LaunchBox ROM symlink missing"; exit 1; }
test "$(readlink "$PZ_EMULATION_ROOT/tools/launchers/Roms/Nintendo Switch/Base Game.nsp")" = "$PZ_EMULATION_ROOT/roms/switch/Base Game.nsp" || { echo "FAIL: LaunchBox ROM symlink wrong target"; exit 1; }
test -L "$PZ_EMULATION_ROOT/tools/launchers/Roms/Nintendo Switch/media" || { echo "FAIL: LaunchBox media symlink missing"; exit 1; }
test "$(readlink "$PZ_EMULATION_ROOT/tools/launchers/Roms/Nintendo Switch/media")" = "$PZ_EMULATION_ROOT/tools/downloaded_media/switch" || { echo "FAIL: LaunchBox media symlink wrong target"; exit 1; }
grep -q '<Theme>Default</Theme>' "$LB_ROOT/Data/BigBoxSettings.xml" || { echo "FAIL: BigBox safe theme missing"; exit 1; }
grep -q '<VideoPlaybackEngine>VLC</VideoPlaybackEngine>' "$LB_ROOT/Data/BigBoxSettings.xml" || { echo "FAIL: BigBox VLC engine missing"; exit 1; }
grep -q '<UseStartupScreen>false</UseStartupScreen>' "$LB_ROOT/Data/BigBoxSettings.xml" || { echo "FAIL: BigBox startup screen not disabled"; exit 1; }
grep -q '<VideoPlaybackEngine>VLC</VideoPlaybackEngine>' "$LB_ROOT/Data/Settings.xml" || { echo "FAIL: LaunchBox VLC engine missing"; exit 1; }
grep -q '<ShowDetailsVideo>false</ShowDetailsVideo>' "$LB_ROOT/Data/Settings.xml" || { echo "FAIL: LaunchBox video safe setting missing"; exit 1; }
python3 - "$LB_ROOT/Data/Parents.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
bad_root = []
phasezero_parent = False
for parent in root.findall("Parent"):
    values = {child.tag: (child.text or "").strip() for child in parent}
    if values.get("PlatformCategoryName") and not any(
        values.get(key)
        for key in ("PlatformName", "PlaylistId", "ParentPlatformName", "ParentPlaylistId", "ParentPlatformCategoryName")
    ):
        bad_root.append(values.get("PlatformCategoryName"))
    if values.get("PlatformName") == "PhaseZero Frontends" and values.get("ParentPlatformCategoryName") == "Computers":
        phasezero_parent = True
if bad_root:
    raise SystemExit(f"FAIL: LaunchBox root category parent rows not removed: {bad_root}")
if not phasezero_parent:
    raise SystemExit("FAIL: LaunchBox PhaseZero Frontends parent missing")
PY
test -f "$PZ_EMULATION_ROOT/tools/launchers/emulators/PhaseZero/eden.bat" || { echo "FAIL: LaunchBox Eden batch wrapper missing"; exit 1; }
grep -q '..\\emulators\\PhaseZero\\eden.bat' "$LB_ROOT/Data/Emulators.xml" || { echo "FAIL: LaunchBox Emulators.xml not rewritten"; exit 1; }
test -x "$PZ_LOCAL_BIN/phasezero-launchbox" || { echo "FAIL: phasezero-launchbox wrapper missing"; exit 1; }
PZ_LAUNCHBOX_SKIP_WINEBOOT=1 PZ_LAUNCHBOX_SKIP_FONTS=1 "$REPO_ROOT/linux/pz" emulation launchbox status >/dev/null
PZ_LAUNCHBOX_SKIP_WINEBOOT=1 PZ_LAUNCHBOX_SKIP_FONTS=1 "$REPO_ROOT/linux/pz" emulation launchbox status --json | jq -e '.installed == true and .aliasesResolved >= 1' >/dev/null || { echo "FAIL: LaunchBox status JSON invalid"; exit 1; }

# === Frontend switcher across BigBox, Steam, ES-DE, SRM and Heroic ===
mkdir -p "$HOME/.local/share/Steam/userdata/123/config"
: > "$HOME/.local/share/Steam/userdata/123/config/shortcuts.vdf"
PZ_LAUNCHBOX_SKIP_WINEBOOT=1 PZ_LAUNCHBOX_SKIP_FONTS=1 "$REPO_ROOT/linux/pz" emulation frontends repair >/dev/null
test -x "$PZ_LOCAL_BIN/phasezero-frontend" || { echo "FAIL: frontend router missing"; exit 1; }
test -x "$PZ_LOCAL_BIN/phasezero-steam-big-picture" || { echo "FAIL: Steam Big Picture wrapper missing"; exit 1; }
test -x "$PZ_LOCAL_BIN/phasezero-heroic" || { echo "FAIL: Heroic wrapper missing"; exit 1; }
test -x "$PZ_EMULATION_ROOT/tools/launchers/frontends/bigbox.sh" || { echo "FAIL: BigBox frontend launcher missing"; exit 1; }
grep -q 'heroic.py" session --mode auto' "$PZ_LOCAL_BIN/phasezero-heroic" || { echo "FAIL: Heroic wrapper does not tune session"; exit 1; }
grep -q 'PZ_HEROIC_CONSOLE_MODE' "$PZ_EMULATION_ROOT/tools/launchers/frontends/heroic.sh" || { echo "FAIL: Heroic frontend launcher does not request console mode"; exit 1; }
grep -q '<name>frontends</name>' "$HOME/ES-DE/custom_systems/es_systems.xml" || { echo "FAIL: ES-DE frontends system missing"; exit 1; }
jq -e 'map(select(.configTitle == "Frontends - PhaseZero")) | length == 1' "$XDG_CONFIG_HOME/steam-rom-manager/userData/userConfigurations.json" >/dev/null || { echo "FAIL: SRM frontends parser missing"; exit 1; }
jq -e '.games | map(select(.app_name == "phasezero-frontend-bigbox")) | length == 1' "$XDG_CONFIG_HOME/heroic/sideload_apps/library.json" >/dev/null || { echo "FAIL: Heroic BigBox entry missing"; exit 1; }
grep -q 'PhaseZero Frontends' "$LB_ROOT/Data/Platforms/PhaseZero Frontends.xml" || { echo "FAIL: LaunchBox frontends platform missing"; exit 1; }
grep -q 'PhaseZero Frontend Switcher' "$LB_ROOT/Data/Emulators.xml" || { echo "FAIL: LaunchBox frontend emulator missing"; exit 1; }
grep -q '<Category>Computers</Category>' "$LB_ROOT/Data/Platforms.xml" || { echo "FAIL: LaunchBox frontends category missing"; exit 1; }
test -L "$PZ_EMULATION_ROOT/tools/launchers/Roms/PhaseZero Frontends/bigbox.sh" || { echo "FAIL: LaunchBox frontends symlink missing"; exit 1; }
test "$(readlink "$PZ_EMULATION_ROOT/tools/launchers/Roms/PhaseZero Frontends/bigbox.sh")" = "$PZ_EMULATION_ROOT/tools/launchers/frontends/bigbox.sh" || { echo "FAIL: LaunchBox frontends symlink wrong target"; exit 1; }
PZ_LAUNCHBOX_SKIP_WINEBOOT=1 PZ_LAUNCHBOX_SKIP_FONTS=1 "$REPO_ROOT/linux/pz" emulation launchbox status --json | jq -e '.aliasesUnresolved | index("PhaseZero Frontends") == null' >/dev/null || { echo "FAIL: LaunchBox frontends alias unresolved"; exit 1; }
python3 "$REPO_ROOT/linux/emulation/steam-shortcut.py" status --steam-root "$HOME/.local/share/Steam" --app-name "Big Box" >/dev/null || { echo "FAIL: Steam Big Box shortcut missing"; exit 1; }
PZ_LAUNCHBOX_SKIP_WINEBOOT=1 PZ_LAUNCHBOX_SKIP_FONTS=1 "$REPO_ROOT/linux/pz" emulation frontends status --json | jq -e '.routerInstalled == true and .launcherCount == .expectedLaunchers and .srmParserInstalled == true and .heroicManagedFrontends >= 6 and .steamShortcuts.frontendsFound >= 6 and .launchbox.platformInstalled == true' >/dev/null || { echo "FAIL: frontends status JSON invalid"; exit 1; }

# === Heroic defaults and KDE menu hygiene ===
mkdir -p "$XDG_CONFIG_HOME/heroic" "$XDG_DATA_HOME/applications"
cat > "$XDG_CONFIG_HOME/heroic/config.json" <<'JSON'
{"version":"test","defaultSettings":{"addDesktopShortcuts":true,"autoInstallDxvk":false,"verboseLogs":true}}
JSON
cat > "$XDG_DATA_HOME/applications/phasezero-pc-menu-test.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Menu Test
Exec=$PZ_EMULATION_ROOT/tools/pc-games/launchers/menu-test.sh
Categories=Game;
EOF
cat > "$XDG_DATA_HOME/applications/phasezero-es-de.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=ES-DE
Exec=$PZ_LOCAL_BIN/phasezero-es-de
Categories=Game;
EOF
cat > "$XDG_DATA_HOME/applications/ES-DE.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=ES-DE
Exec=/tmp/duplicate-es-de
Categories=Game;
EOF
"$REPO_ROOT/linux/pz" emulation heroic repair >/dev/null
jq -e --arg install "$PZ_EMULATION_ROOT/roms/steam" --arg prefix "$PZ_EMULATION_ROOT/storage/pc-prefixes/heroic" '.defaultSettings.addDesktopShortcuts == false and .defaultSettings.addStartMenuShortcuts == false and .defaultSettings.autoInstallDxvk == true and .defaultSettings.autoInstallVkd3d == true and .defaultSettings.autoInstallDxvkNvapi == true and .defaultSettings.enableEsync == true and .defaultSettings.enableFsync == true and .defaultSettings.defaultInstallPath == $install and .defaultSettings.defaultWinePrefixDir == $prefix and (.defaultSettings.useGameMode | type == "boolean")' "$XDG_CONFIG_HOME/heroic/config.json" >/dev/null || { echo "FAIL: Heroic optimized defaults missing"; exit 1; }
jq -e '.defaultSettings.autoUpdateGames == false and .defaultSettings.hideChangelogsOnStartup == true and .defaultSettings.startInConsoleMode == false and .defaultSettings.noTrayIcon == true and .defaultSettings.exitToTray == false and .defaultSettings.startInTray == false and .defaultSettings.framelessWindow == false and .defaultSettings.enableWineWayland == false and .defaultSettings.enableWoW64 == false and .defaultSettings.enableFSRHack == false and .defaultSettings.FsrSharpnessStrenght == 2 and .defaultSettings.downloadNoHttps == false and .defaultSettings.disableGOGPresence == true and .defaultSettings.discordRPC == false and .defaultSettings.disable_controller == false and .defaultSettings.allowInstallationBrokenAnticheat == false and .defaultSettings.experimentalFeatures.cometSupport == true and .defaultSettings.experimentalFeatures.zoomPlatform == false' "$XDG_CONFIG_HOME/heroic/config.json" >/dev/null || { echo "FAIL: Heroic experience defaults missing"; exit 1; }
PZ_HEROIC_CONSOLE_MODE=1 "$REPO_ROOT/linux/pz" emulation heroic session --mode auto --json | jq -e '.gameSession == true and .startInConsoleMode == true' >/dev/null || { echo "FAIL: Heroic game session not detected"; exit 1; }
jq -e '.defaultSettings.startInConsoleMode == true' "$XDG_CONFIG_HOME/heroic/config.json" >/dev/null || { echo "FAIL: Heroic console mode not enabled for game session"; exit 1; }
PZ_HEROIC_CONSOLE_MODE=0 "$REPO_ROOT/linux/pz" emulation heroic session --mode auto --json | jq -e '.gameSession == false and .startInConsoleMode == false' >/dev/null || { echo "FAIL: Heroic desktop session not detected"; exit 1; }
jq -e '.defaultSettings.startInConsoleMode == false' "$XDG_CONFIG_HOME/heroic/config.json" >/dev/null || { echo "FAIL: Heroic console mode not disabled for desktop session"; exit 1; }
test -f "$PZ_EMULATION_ROOT/media/icons/phasezero/heroic.svg" || { echo "FAIL: Heroic icon missing"; exit 1; }
grep -q '^NoDisplay=true$' "$XDG_DATA_HOME/applications/phasezero-pc-menu-test.desktop" || { echo "FAIL: PhaseZero PC menu entry not hidden"; exit 1; }
grep -q 'pc-game.svg$' "$XDG_DATA_HOME/applications/phasezero-pc-menu-test.desktop" || { echo "FAIL: PhaseZero PC menu icon missing"; exit 1; }
grep -q '^NoDisplay=true$' "$XDG_DATA_HOME/applications/ES-DE.desktop" || { echo "FAIL: duplicate ES-DE launcher not hidden"; exit 1; }
"$REPO_ROOT/linux/pz" emulation heroic status --json | jq -e '.optimizedDefaults == true and .iconsInstalled == true and .visiblePhaseZeroPcGames == 0 and .hiddenDuplicates >= 1 and .phasezeroWithoutIcon == 0 and .heroicManagedEntries >= 6 and .heroicArtworkComplete == .heroicManagedEntries and .heroicWithoutArtwork == 0' >/dev/null || { echo "FAIL: Heroic status JSON invalid"; exit 1; }

# pz emulation doctor runs both shared + media status
"$REPO_ROOT/linux/pz" emulation doctor >/dev/null 2>&1 || true

# Layout dirs from common.sh exist
test -d "$PZ_EMULATION_ROOT/cheats" || { echo "FAIL: cheats layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/patches" || { echo "FAIL: patches layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/shaders" || { echo "FAIL: shaders layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/states" || { echo "FAIL: states layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/screenshots" || { echo "FAIL: screenshots layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/videos" || { echo "FAIL: videos layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/borders" || { echo "FAIL: borders layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/themes" || { echo "FAIL: themes layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/metadata/gamelists" || { echo "FAIL: gamelists layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/texture_packs" || { echo "FAIL: texture_packs layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/tools/downloaded_media" || { echo "FAIL: downloaded_media layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/tools/launchers/frontends" || { echo "FAIL: frontends launchers layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/media/steamgrid" || { echo "FAIL: media/steamgrid layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/media/index" || { echo "FAIL: media/index layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/metadata/gamelists/frontends" || { echo "FAIL: frontends gamelist layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/metadata/frontends" || { echo "FAIL: frontends metadata layout dir missing"; exit 1; }
test -d "$PZ_EMULATION_ROOT/.phasezero/backups" || { echo "FAIL: .phasezero/backups layout dir missing"; exit 1; }

# === Regression: PZ_RETRODECK_ROOT ausente ===
echo "=== Regression: missing RetroDECK root ==="
TMP2="$(mktemp -d)"
(
export HOME="$TMP2/home" XDG_CONFIG_HOME="$TMP2/home/.config" XDG_DATA_HOME="$TMP2/home/.local/share"
export PZ_EMULATION_ROOT="$TMP2/Emulation" PZ_RETRODECK_ROOT="$TMP2/retrodeck"
mkdir -p "$HOME" "$PZ_EMULATION_ROOT"
"$REPO_ROOT/linux/pz" emulation layout >/dev/null 2>&1 || true
mkdir -p "$PZ_EMULATION_ROOT/roms" "$PZ_EMULATION_ROOT/bios"
# retrodeck parent dir does NOT exist yet
"$REPO_ROOT/linux/pz" emulation shared apply >/dev/null 2>&1
test -L "$PZ_RETRODECK_ROOT/roms" || { echo "FAIL: missing retrodeck root - roms symlink missing"; exit 1; }
test -L "$PZ_RETRODECK_ROOT/bios" || { echo "FAIL: missing retrodeck root - bios symlink missing"; exit 1; }
echo "  missing retrodeck root handled ok"
)
rm -rf "$TMP2"

# === Regression: media aliases cover e box2dfront ===
echo "=== Regression: cover and box2dfront aliases ==="
TMP3="$(mktemp -d)"
(
export HOME="$TMP3/home" XDG_CONFIG_HOME="$TMP3/home/.config" XDG_DATA_HOME="$TMP3/home/.local/share"
export PZ_EMULATION_ROOT="$TMP3/Emulation" PZ_RETRODECK_ROOT="$TMP3/retrodeck"
mkdir -p "$HOME"
"$REPO_ROOT/linux/pz" emulation layout >/dev/null 2>&1 || true
mkdir -p "$PZ_EMULATION_ROOT/tools/downloaded_media/psx/covers"
echo "cover" > "$PZ_EMULATION_ROOT/tools/downloaded_media/psx/covers/game.png"
"$REPO_ROOT/linux/pz" emulation media apply >/dev/null 2>&1
test -L "$PZ_EMULATION_ROOT/tools/downloaded_media/psx/cover" || { echo "FAIL: cover alias missing"; ls -la "$PZ_EMULATION_ROOT/tools/downloaded_media/psx/"; exit 1; }
test -L "$PZ_EMULATION_ROOT/tools/downloaded_media/psx/box2dfront" || { echo "FAIL: box2dfront alias missing"; exit 1; }
test "$(readlink "$PZ_EMULATION_ROOT/tools/downloaded_media/psx/cover")" = "$PZ_EMULATION_ROOT/tools/downloaded_media/psx/covers" || { echo "FAIL: cover wrong target"; exit 1; }
test "$(readlink "$PZ_EMULATION_ROOT/tools/downloaded_media/psx/box2dfront")" = "$PZ_EMULATION_ROOT/tools/downloaded_media/psx/covers" || { echo "FAIL: box2dfront wrong target"; exit 1; }
echo "  cover and box2dfront aliases ok"
)
rm -rf "$TMP3"

# === Regression: RetroDECK/ES-DE sem downloaded_media ===
echo "=== Regression: RetroDECK ES-DE sem downloaded_media ==="
TMP4="$(mktemp -d)"
(
export HOME="$TMP4/home" XDG_CONFIG_HOME="$TMP4/home/.config" XDG_DATA_HOME="$TMP4/home/.local/share"
export PZ_EMULATION_ROOT="$TMP4/Emulation" PZ_RETRODECK_ROOT="$TMP4/retrodeck"
mkdir -p "$HOME" "$PZ_RETRODECK_ROOT/ES-DE" "$PZ_EMULATION_ROOT"
"$REPO_ROOT/linux/pz" emulation layout >/dev/null 2>&1 || true
mkdir -p "$PZ_EMULATION_ROOT/tools/downloaded_media"
"$REPO_ROOT/linux/pz" emulation media apply >/dev/null 2>&1
test -L "$PZ_RETRODECK_ROOT/ES-DE/downloaded_media" || { echo "FAIL: retrodeck ES-DE downloaded_media symlink missing"; ls -la "$PZ_RETRODECK_ROOT/ES-DE/"; exit 1; }
test "$(readlink "$PZ_RETRODECK_ROOT/ES-DE/downloaded_media")" = "$PZ_EMULATION_ROOT/tools/downloaded_media" || { echo "FAIL: retrodeck ES-DE symlink wrong target"; exit 1; }
echo "  retrodeck ES-DE sem downloaded_media ok"
)
rm -rf "$TMP4"

# === Regression: ES-DE settings sem MediaDirectory ===
echo "=== Regression: ES-DE settings sem MediaDirectory ==="
TMP5="$(mktemp -d)"
(
export HOME="$TMP5/home" XDG_CONFIG_HOME="$TMP5/home/.config" XDG_DATA_HOME="$TMP5/home/.local/share"
export PZ_EMULATION_ROOT="$TMP5/Emulation" PZ_RETRODECK_ROOT="$TMP5/retrodeck"
mkdir -p "$HOME" "$HOME/.emulationstation"
cat > "$HOME/.emulationstation/es_settings.xml" <<'XML'
<?xml version="1.0"?>
<config>
  <bool name="SomeSetting" value="true" />
</config>
XML
"$REPO_ROOT/linux/pz" emulation layout >/dev/null 2>&1 || true
mkdir -p "$PZ_EMULATION_ROOT/tools/downloaded_media"
"$REPO_ROOT/linux/pz" emulation media apply >/dev/null 2>&1
grep -q 'name="MediaDirectory"' "$HOME/.emulationstation/es_settings.xml" || { echo "FAIL: MediaDirectory entry missing"; cat "$HOME/.emulationstation/es_settings.xml"; exit 1; }
grep -q "value=\"$PZ_EMULATION_ROOT/tools/downloaded_media\"" "$HOME/.emulationstation/es_settings.xml" || { echo "FAIL: MediaDirectory value wrong"; cat "$HOME/.emulationstation/es_settings.xml"; exit 1; }
grep -q 'name="ROMDirectory"' "$HOME/.emulationstation/es_settings.xml" || { echo "FAIL: ROMDirectory entry missing"; cat "$HOME/.emulationstation/es_settings.xml"; exit 1; }
grep -q "value=\"$PZ_EMULATION_ROOT/roms\"" "$HOME/.emulationstation/es_settings.xml" || { echo "FAIL: ROMDirectory value wrong"; cat "$HOME/.emulationstation/es_settings.xml"; exit 1; }
echo "  ES-DE settings sem MediaDirectory ok"
)
rm -rf "$TMP5"

# === Regression: RetroDECK Flatpak ES-DE settings path ===
echo "=== Regression: RetroDECK Flatpak ES-DE settings path ==="
TMP5B="$(mktemp -d)"
(
export HOME="$TMP5B/home" XDG_CONFIG_HOME="$TMP5B/home/.config" XDG_DATA_HOME="$TMP5B/home/.local/share"
export PZ_EMULATION_ROOT="$TMP5B/Emulation" PZ_RETRODECK_ROOT="$TMP5B/retrodeck"
mkdir -p "$HOME/.var/app/net.retrodeck.retrodeck/config/ES-DE/settings"
cat > "$HOME/.var/app/net.retrodeck.retrodeck/config/ES-DE/settings/es_settings.xml" <<'XML'
<?xml version="1.0"?>
<config>
  <string name="MediaDirectory" value="/home/test/retrodeck/ES-DE/downloaded_media" />
  <string name="ROMDirectory" value="/home/test/retrodeck/roms" />
</config>
XML
"$REPO_ROOT/linux/pz" emulation layout >/dev/null 2>&1 || true
"$REPO_ROOT/linux/pz" emulation media apply >/dev/null 2>&1
grep -q "value=\"$PZ_RETRODECK_ROOT/ES-DE/downloaded_media\"" "$HOME/.var/app/net.retrodeck.retrodeck/config/ES-DE/settings/es_settings.xml" || { echo "FAIL: RetroDECK Flatpak MediaDirectory value wrong"; cat "$HOME/.var/app/net.retrodeck.retrodeck/config/ES-DE/settings/es_settings.xml"; exit 1; }
grep -q "value=\"$PZ_RETRODECK_ROOT/roms\"" "$HOME/.var/app/net.retrodeck.retrodeck/config/ES-DE/settings/es_settings.xml" || { echo "FAIL: RetroDECK Flatpak ROMDirectory value wrong"; cat "$HOME/.var/app/net.retrodeck.retrodeck/config/ES-DE/settings/es_settings.xml"; exit 1; }
echo "  RetroDECK Flatpak ES-DE settings ok"
)
rm -rf "$TMP5B"

# === Regression: RetroDECK manifest custom paths ===
echo "=== Regression: RetroDECK manifest custom paths ==="
TMP5C="$(mktemp -d)"
(
export HOME="$TMP5C/home" XDG_CONFIG_HOME="$TMP5C/home/.config" XDG_DATA_HOME="$TMP5C/home/.local/share"
export PZ_EMULATION_ROOT="$TMP5C/Emulation"
unset PZ_RETRODECK_ROOT
mkdir -p "$HOME/.var/app/net.retrodeck.retrodeck/config/retrodeck" \
    "$HOME/.var/app/net.retrodeck.retrodeck/config/ES-DE/settings"
CUSTOM_ROOT="$TMP5C/custom-rd"
cat > "$HOME/.var/app/net.retrodeck.retrodeck/config/retrodeck/retrodeck.json" <<JSON
{
  "version": "test",
  "paths": {
    "rd_home_path": "$CUSTOM_ROOT",
    "roms_path": "$CUSTOM_ROOT/custom-roms",
    "bios_path": "$CUSTOM_ROOT/custom-bios",
    "saves_path": "$CUSTOM_ROOT/custom-saves",
    "states_path": "$CUSTOM_ROOT/custom-states",
    "downloaded_media_path": "$CUSTOM_ROOT/custom-media",
    "themes_path": "$CUSTOM_ROOT/custom-themes"
  }
}
JSON
cat > "$HOME/.var/app/net.retrodeck.retrodeck/config/ES-DE/settings/es_settings.xml" <<XML
<?xml version="1.0"?>
<config>
  <string name="MediaDirectory" value="$CUSTOM_ROOT/custom-media" />
  <string name="ROMDirectory" value="$CUSTOM_ROOT/custom-roms" />
</config>
XML
mkdir -p "$CUSTOM_ROOT/custom-roms/psx" "$CUSTOM_ROOT/custom-saves/psx/duckstation" "$CUSTOM_ROOT/custom-media/psx/covers"
echo rom > "$CUSTOM_ROOT/custom-roms/psx/Game.chd"
echo save > "$CUSTOM_ROOT/custom-saves/psx/duckstation/Game.mcd"
echo cover > "$CUSTOM_ROOT/custom-media/psx/covers/Game.png"
"$REPO_ROOT/linux/pz" emulation retrodeck integrate >/dev/null 2>&1
test -L "$CUSTOM_ROOT/custom-roms" || { echo "FAIL: manifest custom roms not linked"; exit 1; }
test -L "$CUSTOM_ROOT/custom-saves" || { echo "FAIL: manifest custom saves not linked"; exit 1; }
test -L "$CUSTOM_ROOT/custom-states" || { echo "FAIL: manifest custom states not linked"; exit 1; }
test -L "$CUSTOM_ROOT/custom-media" || { echo "FAIL: manifest custom media not linked"; exit 1; }
test -L "$CUSTOM_ROOT/custom-themes" || { echo "FAIL: manifest custom themes not linked"; exit 1; }
test -f "$PZ_EMULATION_ROOT/roms/psx/Game.chd" || { echo "FAIL: manifest ROM not migrated"; exit 1; }
test -f "$PZ_EMULATION_ROOT/saves/psx/duckstation/Game.mcd" || { echo "FAIL: manifest save not migrated"; exit 1; }
test -f "$PZ_EMULATION_ROOT/tools/downloaded_media/psx/covers/Game.png" || { echo "FAIL: manifest media not migrated"; exit 1; }
"$REPO_ROOT/linux/pz" emulation retrodeck status >/dev/null
echo "  RetroDECK manifest custom paths ok"
)
rm -rf "$TMP5C"

# === Regression: malformed ES-DE gamelist does not block integration ===
echo "=== Regression: malformed ES-DE gamelist ==="
TMP5D="$(mktemp -d)"
(
export HOME="$TMP5D/home" XDG_CONFIG_HOME="$TMP5D/home/.config" XDG_DATA_HOME="$TMP5D/home/.local/share"
export PZ_EMULATION_ROOT="$TMP5D/Emulation" PZ_RETRODECK_ROOT="$TMP5D/retrodeck"
mkdir -p "$PZ_EMULATION_ROOT/roms/switch" "$PZ_EMULATION_ROOT/metadata/gamelists/switch"
echo game > "$PZ_EMULATION_ROOT/roms/switch/Game.nsp"
cat > "$PZ_EMULATION_ROOT/metadata/gamelists/switch/gamelist.xml" <<'XML'
<?xml version="1.0"?>
<alternativeEmulator><label>Eden (Standalone)</label></alternativeEmulator>
<gameList>
  <game><path>./Nintendo Switch (DLC)/Game DLC.nsp</path><name>Game DLC</name></game>
</gameList>
XML
mkdir -p "$PZ_EMULATION_ROOT/roms/switch/Nintendo Switch (DLC)"
echo dlc > "$PZ_EMULATION_ROOT/roms/switch/Nintendo Switch (DLC)/Game DLC.nsp"
"$REPO_ROOT/linux/pz" emulation media apply >/dev/null 2>&1
test -L "$PZ_RETRODECK_ROOT/ES-DE/downloaded_media" || { echo "FAIL: malformed gamelist blocked media integration"; exit 1; }
grep -q '<alternativeEmulator>' "$PZ_EMULATION_ROOT/metadata/gamelists/switch/gamelist.xml" || { echo "FAIL: alternative emulator prefix lost"; exit 1; }
grep -q '<hidden>true</hidden>' "$PZ_EMULATION_ROOT/metadata/gamelists/switch/gamelist.xml" || { echo "FAIL: fragment gamelist exclusion not applied"; exit 1; }
echo "  malformed ES-DE gamelist tolerated"
)
rm -rf "$TMP5D"

# === Regression: media repair com mídia só no RetroDECK ===
echo "=== Regression: media repair migra mídia do RetroDECK ==="
TMP6="$(mktemp -d)"
(
export HOME="$TMP6/home" XDG_CONFIG_HOME="$TMP6/home/.config" XDG_DATA_HOME="$TMP6/home/.local/share"
export PZ_EMULATION_ROOT="$TMP6/Emulation" PZ_RETRODECK_ROOT="$TMP6/retrodeck"
mkdir -p "$HOME" "$PZ_RETRODECK_ROOT/ES-DE"
"$REPO_ROOT/linux/pz" emulation layout >/dev/null 2>&1 || true
mkdir -p "$PZ_RETRODECK_ROOT/ES-DE/downloaded_media/psx/covers"
echo "repair-media" > "$PZ_RETRODECK_ROOT/ES-DE/downloaded_media/psx/covers/game.png"
mkdir -p "$PZ_EMULATION_ROOT/tools/downloaded_media"
# media apply first to create symlink
"$REPO_ROOT/linux/pz" emulation media apply >/dev/null 2>&1
# break the symlink - replace with real dir with new content
rm -f "$PZ_RETRODECK_ROOT/ES-DE/downloaded_media"
mkdir -p "$PZ_RETRODECK_ROOT/ES-DE/downloaded_media/psx/screenshots"
echo "repair-only" > "$PZ_RETRODECK_ROOT/ES-DE/downloaded_media/psx/screenshots/game.png"
# now run repair - should migrate, backup, and recreate symlink
"$REPO_ROOT/linux/pz" emulation media repair >/dev/null 2>&1
# file should be in canonical
test -f "$PZ_EMULATION_ROOT/tools/downloaded_media/psx/screenshots/game.png" || { echo "FAIL: repair did not migrate media file"; find "$PZ_EMULATION_ROOT/tools/downloaded_media/"; exit 1; }
# backup should exist
_repair_backup_found=0
for _rf in "$PZ_EMULATION_ROOT/.phasezero/backups/"retrodeck-downloaded_media*; do
    [ -e "$_rf" ] && _repair_backup_found=1 && break
done
[ "$_repair_backup_found" -eq 1 ] || { echo "FAIL: repair backup not created"; exit 1; }
# symlink should point to canonical
test -L "$PZ_RETRODECK_ROOT/ES-DE/downloaded_media" || { echo "FAIL: repair did not recreate symlink"; exit 1; }
echo "  media repair com mídia no RetroDECK ok"
)
rm -rf "$TMP6"

# === Regression: multi-system media index coverage ===
echo "=== Regression: multi-system media index coverage ==="
TMP7="$(mktemp -d)"
(
export HOME="$TMP7/home" XDG_CONFIG_HOME="$TMP7/home/.config" XDG_DATA_HOME="$TMP7/home/.local/share"
export PZ_EMULATION_ROOT="$TMP7/Emulation" PZ_RETRODECK_ROOT="$TMP7/retrodeck"
mkdir -p "$HOME"
"$REPO_ROOT/linux/pz" emulation layout >/dev/null 2>&1 || true
for sys in psx ps2 gc wii snes gba; do
    mkdir -p "$PZ_EMULATION_ROOT/roms/$sys" "$PZ_EMULATION_ROOT/tools/downloaded_media/$sys/covers"
    case "$sys" in
        ps2) ext=iso ;;
        gc|wii) ext=rvz ;;
        snes) ext=sfc ;;
        gba) ext=gba ;;
        *) ext=chd ;;
    esac
    echo "rom" > "$PZ_EMULATION_ROOT/roms/$sys/Game.$ext"
    echo "cover" > "$PZ_EMULATION_ROOT/tools/downloaded_media/$sys/covers/Game.png"
done
"$REPO_ROOT/linux/pz" emulation media index >/dev/null 2>&1
jq -e '
    (.systems.psx.rom_count == 1) and
    (.systems.ps2.rom_count == 1) and
    (.systems.gc.rom_count == 1) and
    (.systems.wii.rom_count == 1) and
    (.systems.snes.rom_count == 1) and
    (.systems.gba.rom_count == 1) and
    (.stats.media_files == 6)
' "$PZ_EMULATION_ROOT/media/index/media-index.json" >/dev/null || { echo "FAIL: multi-system media index coverage incomplete"; jq '.stats, .systems | keys' "$PZ_EMULATION_ROOT/media/index/media-index.json"; exit 1; }
echo "  multi-system media index ok"
)
rm -rf "$TMP7"

# === Regression: scan-safe policy for recursive frontends ===
echo "=== Regression: scan-safe media and frontend policy ==="
TMP8="$(mktemp -d)"
(
export HOME="$TMP8/home" XDG_CONFIG_HOME="$TMP8/home/.config" XDG_DATA_HOME="$TMP8/home/.local/share"
export PZ_EMULATION_ROOT="$TMP8/Emulation" PZ_RETRODECK_ROOT="$TMP8/retrodeck"
export PZ_EMULATION_FORCE_APPLY=1
mkdir -p \
    "$HOME/.config/Ryujinx" \
    "$HOME/ES-DE/gamelists/switch" \
    "$PZ_EMULATION_ROOT/roms/switch/Nintendo Switch (DLC)" \
    "$PZ_EMULATION_ROOT/roms/steam/Art of Rally/ArtOfRally_Data" \
    "$PZ_EMULATION_ROOT/roms/steam/media/covers" \
    "$PZ_EMULATION_ROOT/roms/xbox360/roms/Forza Horizon" \
    "$PZ_EMULATION_ROOT/roms/xbox360/cache" \
    "$PZ_EMULATION_ROOT/roms/ps3/pkg" \
    "$PZ_EMULATION_ROOT/roms/ps3/Extracted Game/PS3_GAME/USRDIR" \
    "$PZ_EMULATION_ROOT/roms/ps4/shortcuts" \
    "$PZ_EMULATION_ROOT/roms/ps4/Installed Game/sce_sys"

echo base > "$PZ_EMULATION_ROOT/roms/switch/Legend Quest [0100123412340000][v0].nsp"
echo update > "$PZ_EMULATION_ROOT/roms/switch/Legend Quest [0100123412340800][v65536].nsp"
echo simple > "$PZ_EMULATION_ROOT/roms/switch/Simple Game.nsp"
echo dlc > "$PZ_EMULATION_ROOT/roms/switch/Nintendo Switch (DLC)/Legend Quest [DLC] [0100123412341001][v0].nsp"
echo launcher > "$PZ_EMULATION_ROOT/roms/steam/Art of Rally/Art of Rally.sh"
echo resource > "$PZ_EMULATION_ROOT/roms/steam/Art of Rally/ArtOfRally_Data/resource.zip"
echo artwork > "$PZ_EMULATION_ROOT/roms/steam/media/covers/Art of Rally.png"
echo xex > "$PZ_EMULATION_ROOT/roms/xbox360/roms/Forza Horizon/default.xex"
echo cache > "$PZ_EMULATION_ROOT/roms/xbox360/cache/default.xex"
echo iso > "$PZ_EMULATION_ROOT/roms/ps3/Disc Game With Spaces.iso"
echo eboot > "$PZ_EMULATION_ROOT/roms/ps3/Extracted Game/PS3_GAME/USRDIR/EBOOT.BIN"
echo pkg > "$PZ_EMULATION_ROOT/roms/ps3/pkg/update.pkg"
echo desktop > "$PZ_EMULATION_ROOT/roms/ps4/shortcuts/Shortcut Game.desktop"
echo sfo > "$PZ_EMULATION_ROOT/roms/ps4/Installed Game/sce_sys/param.sfo"

cat > "$HOME/.config/Ryujinx/Config.json" <<JSON
{"game_dirs":["$PZ_EMULATION_ROOT/roms/switch","/another/library"]}
JSON
cat > "$HOME/ES-DE/gamelists/switch/gamelist.xml" <<'XML'
<?xml version="1.0"?>
<alternativeEmulator>
  <label>Eden (Standalone)</label>
</alternativeEmulator>
<gameList>
  <game><path>./Legend Quest [0100123412340000][v0].nsp</path><name>Legend Quest</name></game>
  <game><path>./Legend Quest [0100123412340800][v65536].nsp</path><name>Legend Quest Update</name></game>
</gameList>
XML

"$REPO_ROOT/linux/pz" emulation media prepare-scan >/dev/null

SCAN_SWITCH="$PZ_EMULATION_ROOT/.phasezero/scan-safe/roms/switch"
test -L "$SCAN_SWITCH/Legend Quest [0100123412340000][v0].nsp" || { echo "FAIL: base Switch game absent from safe view"; exit 1; }
test -L "$SCAN_SWITCH/Simple Game.nsp" || { echo "FAIL: untagged Switch game absent from safe view"; exit 1; }
test ! -e "$SCAN_SWITCH/Legend Quest [0100123412340800][v65536].nsp" || { echo "FAIL: Switch update leaked into safe view"; exit 1; }
test -f "$PZ_EMULATION_ROOT/roms/switch/Nintendo Switch (DLC)/noload.txt" || { echo "FAIL: Switch DLC noload marker missing"; exit 1; }
test -f "$PZ_EMULATION_ROOT/roms/steam/Art of Rally/ArtOfRally_Data/noload.txt" || { echo "FAIL: Steam resource noload marker missing"; exit 1; }
test -f "$PZ_EMULATION_ROOT/roms/steam/media/noload.txt" || { echo "FAIL: Steam auxiliary root noload marker missing"; exit 1; }
test -f "$PZ_EMULATION_ROOT/roms/xbox360/cache/noload.txt" || { echo "FAIL: Xbox 360 cache noload marker missing"; exit 1; }
test -f "$PZ_EMULATION_ROOT/roms/ps3/pkg/noload.txt" || { echo "FAIL: PS3 pkg noload marker missing"; exit 1; }

jq -e --arg view "$SCAN_SWITCH" --arg source "$PZ_EMULATION_ROOT/roms/switch" \
    '(.game_dirs | index($view)) != null and ((.game_dirs | index($source)) == null) and (.game_dirs | index("/another/library")) != null' \
    "$HOME/.config/Ryujinx/Config.json" >/dev/null || { echo "FAIL: Ryujinx game_dirs not isolated"; exit 1; }

python3 - "$HOME/ES-DE/gamelists/switch/gamelist.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("<gameList")
end = text.index("</gameList>", start) + len("</gameList>")
root = ET.fromstring(text[start:end])
entries = {node.findtext("path"): node for node in root.findall("game")}
update = entries["./Legend Quest [0100123412340800][v65536].nsp"]
assert update.findtext("hidden") == "true"
assert update.findtext("nogamecount") == "true"
assert update.findtext("nomultiscrape") == "true"
base = entries["./Legend Quest [0100123412340000][v0].nsp"]
assert base.find("hidden") is None
PY

jq -e '
    .version == 2 and
    .systems.switch.rom_count == 2 and
    .systems.switch.ignored_count == 2 and
    (.systems.switch.roms | has("Legend Quest [0100123412340000][v0]")) and
    (.systems.switch.roms | has("Simple Game")) and
    .systems.steam.rom_count == 1 and
    (.systems.steam.roms | has("Art of Rally")) and
    ((.systems.steam.roms | has("media")) | not) and
    .systems.xbox360.rom_count == 1 and
    (.systems.xbox360.roms | has("Forza Horizon")) and
    .systems.ps3.rom_count == 2 and
    (.systems.ps3.roms | has("Disc Game With Spaces")) and
    (.systems.ps3.roms | has("Extracted Game")) and
    .systems.ps4.rom_count == 2 and
    (.systems.ps4.roms | has("Shortcut Game")) and
    (.systems.ps4.roms | has("Installed Game"))
' "$PZ_EMULATION_ROOT/media/index/media-index.json" >/dev/null || {
    echo "FAIL: logical media catalog polluted or incomplete"
    jq '.stats, .systems' "$PZ_EMULATION_ROOT/media/index/media-index.json"
    exit 1
}
echo "  scan-safe policy ok"
)
rm -rf "$TMP8"

echo "linux-emulation-shared smoke ok"
