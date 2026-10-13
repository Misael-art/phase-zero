#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_HOME="${XDG_BIN_HOME:-$HOME/.local/bin}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_DIR="$DATA_HOME/applications"
ICON_DIR="$DATA_HOME/icons/hicolor/scalable/apps"
INSTALL_BASE="${PZ_USER_INSTALL_ROOT:-$DATA_HOME/phasezero}"
VERSION="$(jq -er '.version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+([+-][0-9A-Za-z.-]+)?$"))' "$ROOT/version.json")"
RELEASE_DIR="$INSTALL_BASE/releases/$VERSION"
CURRENT_LINK="$INSTALL_BASE/current"
STAGE=""
CURRENT_STAGE=""
RELEASE_BACKUP=""
SOURCE_TMP=""

cleanup() {
    [ -z "$SOURCE_TMP" ] || [ ! -d "$SOURCE_TMP" ] || rm -rf -- "$SOURCE_TMP"
    [ -z "$STAGE" ] || [ ! -e "$STAGE" ] || rm -rf -- "$STAGE"
    [ -z "$CURRENT_STAGE" ] || [ ! -L "$CURRENT_STAGE" ] || rm -f -- "$CURRENT_STAGE"
    if [ -n "$RELEASE_BACKUP" ] && [ -e "$RELEASE_BACKUP" ] && [ ! -e "$RELEASE_DIR" ]; then
        mv "$RELEASE_BACKUP" "$RELEASE_DIR" || true
    fi
}
trap cleanup EXIT

install -d "$BIN_HOME" "$APP_DIR" "$ICON_DIR" "$INSTALL_BASE/releases"
SOURCE_TMP="$(mktemp -d "$INSTALL_BASE/.source.XXXXXX")"
bash "$ROOT/packaging/linux/export-source.sh" "$SOURCE_TMP"
STAGE="$(mktemp -d "$INSTALL_BASE/.stage.XXXXXX")"
install -d "$STAGE/packaging/linux"
cp -a "$SOURCE_TMP/linux" "$SOURCE_TMP/profiles" "$SOURCE_TMP/assets" "$SOURCE_TMP/version.json" "$STAGE/"
install -m 0755 "$SOURCE_TMP/packaging/linux/phasezero-control-center" \
    "$STAGE/packaging/linux/phasezero-control-center"
find "$STAGE" -type d -name __pycache__ -prune -exec rm -rf -- {} +
rm -rf -- "$SOURCE_TMP"
SOURCE_TMP=""

if [ -e "$RELEASE_DIR" ] || [ -L "$RELEASE_DIR" ]; then
    BACKUP_DIR="$INSTALL_BASE/backups"
    install -d "$BACKUP_DIR"
    RELEASE_BACKUP="$BACKUP_DIR/$VERSION.$(date +%Y%m%d%H%M%S).$$"
    mv "$RELEASE_DIR" "$RELEASE_BACKUP"
    echo "Backup da versão anterior: $RELEASE_BACKUP"
fi
mv "$STAGE" "$RELEASE_DIR"
STAGE=""
CURRENT_STAGE="$INSTALL_BASE/.current.$$.tmp"
ln -s "$RELEASE_DIR" "$CURRENT_STAGE"
mv -Tf "$CURRENT_STAGE" "$CURRENT_LINK"
CURRENT_STAGE=""
RELEASE_BACKUP=""
ln -sfn "$CURRENT_LINK/packaging/linux/phasezero-control-center" \
    "$BIN_HOME/phasezero-control-center"
# PZ-AUD-001: same PATH contract as the system packages.
ln -sfn "$CURRENT_LINK/packaging/linux/pz" \
    "$BIN_HOME/pz"
# Absolute Exec: desktop launchers don't always have ~/.local/bin on PATH.
awk -v executable="$BIN_HOME/phasezero-control-center" \
    '/^Exec=/{print "Exec=" executable; next} {print}' \
    "$ROOT/packaging/linux/io.phasezero.ControlCenter.desktop" > \
    "$APP_DIR/io.phasezero.ControlCenter.desktop.tmp"
mv "$APP_DIR/io.phasezero.ControlCenter.desktop.tmp" \
    "$APP_DIR/io.phasezero.ControlCenter.desktop"
chmod 644 "$APP_DIR/io.phasezero.ControlCenter.desktop"
install -m644 "$ROOT/packaging/linux/io.phasezero.ControlCenter.svg" \
    "$ICON_DIR/io.phasezero.ControlCenter.svg"

prune_install_tree() {
    local base="$1" keep="$2" protected="${3:-}" index path
    local -a entries=()
    [ -d "$base" ] || return 0
    mapfile -d '' entries < <(
        find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\0' | sort -zrn
    )
    for ((index = keep; index < ${#entries[@]}; index++)); do
        path="${entries[$index]#* }"
        [ -n "$protected" ] && [ "$(readlink -f "$path")" = "$protected" ] && continue
        if ! rm -rf -- "$path"; then
            echo "Aviso: backup antigo não pôde ser removido: $path" >&2
        fi
    done
}
prune_install_tree "$INSTALL_BASE/releases" 3 "$(readlink -f "$CURRENT_LINK")"
prune_install_tree "$INSTALL_BASE/backups" 3

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "PhaseZero instalado para usuário."
echo "Versão:  $VERSION"
echo "Runtime: $RELEASE_DIR"
echo "Comando: $BIN_HOME/phasezero-control-center"
echo "Desktop: $APP_DIR/io.phasezero.ControlCenter.desktop"
