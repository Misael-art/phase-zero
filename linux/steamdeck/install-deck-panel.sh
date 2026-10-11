#!/usr/bin/env bash
# install-deck-panel.sh - install the PhaseZero Deck panel widget.
# Registers the applet with kpackagetool6. Does not restart Plasma, KWin,
# SDDM, or the controller.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PZ_ROOT="$(cd "$DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$PZ_ROOT/linux/lib/common.sh"

PKG="$DIR/plasmoid/org.phasezero.deckpanel"
APPLET_ID="org.phasezero.deckpanel"
ACTION="${1:-status}"

kpackage_args() {
    # kpackagetool6 installs under $XDG_DATA_HOME/plasma/plasmoids.
    # --packageroot writes the tree but -s cannot see that copy, so a
    # private install is a sandboxed HOME and XDG_DATA_HOME, one export each.
    KPACKAGE_ARGS=(-t Plasma/Applet)
}

refresh_map() {
    bash "$DIR/export-deck-shortcuts.sh" "$PKG/contents/data/deck-shortcuts.json"
}

cmd_install() {
    if [ "${PZ_DRY_RUN:-0}" = 1 ] || [ "$ACTION" = "dry-run" ]; then
        pz_info "dry-run: would install $APPLET_ID from $PKG"
        return 0
    fi
    refresh_map
    kpackage_args
    if kpackagetool6 "${KPACKAGE_ARGS[@]}" -s "$APPLET_ID" >/dev/null 2>&1; then
        kpackagetool6 "${KPACKAGE_ARGS[@]}" -u "$PKG"
    else
        kpackagetool6 "${KPACKAGE_ARGS[@]}" -i "$PKG"
    fi
    pz_info "widget $APPLET_ID instalado. Adicione pelo painel: Adicionar widgets. O Plasma não foi reiniciado."
}

cmd_remove() {
    if [ "${PZ_DRY_RUN:-0}" = 1 ]; then
        pz_info "dry-run: would remove $APPLET_ID"
        return 0
    fi
    kpackage_args
    kpackagetool6 "${KPACKAGE_ARGS[@]}" -r "$APPLET_ID"
    pz_info "widget $APPLET_ID removido"
}

cmd_status() {
    kpackage_args
    if kpackagetool6 "${KPACKAGE_ARGS[@]}" -s "$APPLET_ID" >/dev/null 2>&1; then
        printf 'installed\n'
    else
        printf 'absent\n'
    fi
}

case "$ACTION" in
    install|dry-run) cmd_install ;;
    remove|uninstall) cmd_remove ;;
    status) cmd_status ;;
    *)
        pz_error "usage: install-deck-panel.sh (install|remove|status|dry-run)"
        exit 1
        ;;
esac
