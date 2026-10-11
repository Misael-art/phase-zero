#!/usr/bin/env bash
# Hermetic: the shortcut map comes from the desktop profile, and the
# plasmoid package installs under the sandboxed XDG_DATA_HOME.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_RUNTIME_DIR="$TMP/run"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME"

EXPORTER="$REPO_ROOT/linux/steamdeck/export-deck-shortcuts.sh"
INSTALLER="$REPO_ROOT/linux/steamdeck/install-deck-panel.sh"
REAL_APPLET="/home/misael/.local/share/plasma/plasmoids/org.phasezero.deckpanel"
if [ -e "$REAL_APPLET" ]; then
    REAL_APPLET_STAMP="$(stat -c %Y "$REAL_APPLET")"
else
    REAL_APPLET_STAMP=""
fi

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

json="$(bash "$EXPORTER")"
printf '%s' "$json" | jq -e . >/dev/null || fail "exporter did not emit JSON"

printf '%s' "$json" | jq -e '
  ([.groups[] | select(.id == "chords") | .items[].label] | sort) == ["Steam + A", "Steam + B", "Steam + X", "Steam + Y"]
' >/dev/null || fail "Steam chords missing"

printf '%s' "$json" | jq -e '
  .groups[] | select(.id == "chords") | .items[] | select(.label == "Steam + Y") | .keys == "Print"
' >/dev/null || fail "Steam+Y is not Print"

printf '%s' "$json" | jq -e '
  .groups[] | select(.id == "chords") | .items[] | select(.label == "Steam + B") | .keys == "Ctrl+C"
' >/dev/null || fail "Steam+B is not copy"

printf '%s' "$json" | jq -e '
  .groups[] | select(.id == "chords") | .items[] | select(.label == "Steam + A") | .keys == "Ctrl+V"
' >/dev/null || fail "Steam+A is not paste"

printf '%s' "$json" | jq -e '
  .groups[] | select(.id == "chords") | .items[] | select(.label == "Steam + X") | .name == "Teclado virtual"
' >/dev/null || fail "Steam+X is not the keyboard"

printf '%s' "$json" | jq -e '
  [.groups[] | select(.id == "face") | .items[] | select(.label == "A") | .keys] == ["Enter"]
    and ([.groups[] | select(.id == "shoulders") | .items[] | select(.label == "L1") | .keys] == ["Ctrl+Shift+Tab"])
    and ([.groups[] | select(.id == "back") | .items[] | select(.label == "L4") | .keys] == ["Shift+Tab"])
    and ([.groups[] | select(.id == "pointing") | .items[] | select(.label == "L2") | .keys] == ["Clique direito"])
    and ([.groups[] | select(.id == "pointing") | .items[] | select(.label == "R2") | .keys] == ["Clique esquerdo"])
' >/dev/null || fail "solo map drifted"

if printf '%s' "$json" | jq -e 'tostring | test("Dolphin|org.kde.dolphin")' >/dev/null; then
    fail "map mentions Dolphin"
fi
printf '%s' "$json" | jq -e '[.groups[].items[].label] | index("Steam") == null' >/dev/null || fail "Steam alone has an action"
printf '%s' "$json" | jq -e '.note | contains("Ashyterm") and contains("Ctrl+Shift+C")' >/dev/null || fail "Ashyterm note missing"

grep -q 'install-deck-panel.sh' "$REPO_ROOT/linux/pz" || fail "pz does not dispatch panel"

# Ubuntu CI has no KDE package tool. The fake copies into the sandboxed
# XDG_DATA_HOME the same way kpackagetool6 -i/-u/-r/-s does on a Deck.
if ! command -v kpackagetool6 >/dev/null 2>&1; then
    mkdir -p "$TMP/bin"
    cat >"$TMP/bin/kpackagetool6" <<'EOF'
#!/bin/bash
type=""
op=""
target=""
while [ $# -gt 0 ]; do
    case "$1" in
        -t) type="${2:-}"; shift 2 ;;
        -s|-i|-u|-r) op="${1#-}"; target="${2:-}"; shift 2 ;;
        *) echo "fake kpackagetool6: unknown arg $1" >&2; exit 2 ;;
    esac
done
[ "$type" = "Plasma/Applet" ] || { echo "fake kpackagetool6: bad type" >&2; exit 2; }
root="${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids"
case "$op" in
    s)
        meta="$root/$target/metadata.json"
        [ -f "$meta" ] || exit 1
        grep -q "$target" "$meta" || exit 1
        ;;
    i|u)
        id="$(basename "$target")"
        mkdir -p "$root"
        rm -rf "$root/$id"
        cp -a "$target" "$root/$id"
        printf '%s instalado com sucesso\n' "$root/$id/"
        ;;
    r) rm -rf "$root/$target" ;;
    *) echo "fake kpackagetool6: missing op" >&2; exit 2 ;;
esac
EOF
    chmod +x "$TMP/bin/kpackagetool6"
    export PATH="$TMP/bin:$PATH"
fi

PRIVATE_APPLET="$XDG_DATA_HOME/plasma/plasmoids/org.phasezero.deckpanel"

PZ_DRY_RUN=1 bash "$INSTALLER" install | grep -q 'dry-run' || fail "dry-run silent"
[ ! -e "$PRIVATE_APPLET" ] || fail "dry-run installed the applet"

bash "$INSTALLER" install >/dev/null
[ -f "$PRIVATE_APPLET/metadata.json" ] || fail "package was not installed under XDG_DATA_HOME"
grep -q 'org.phasezero.deckpanel' "$PRIVATE_APPLET/metadata.json" || fail "installed metadata has the wrong id"
[ -f "$PRIVATE_APPLET/contents/data/deck-shortcuts.json" ] || fail "installed package has no shortcut map"
jq -e '.groups[] | select(.id == "chords") | .items[] | select(.label == "Steam + Y") | .keys == "Print"' \
    "$PRIVATE_APPLET/contents/data/deck-shortcuts.json" >/dev/null || fail "installed map is not the exporter output"
if [ -n "$REAL_APPLET_STAMP" ]; then
    [ "$(stat -c %Y "$REAL_APPLET")" = "$REAL_APPLET_STAMP" ] || fail "install touched the real user plasmoid directory"
else
    [ ! -e "$REAL_APPLET" ] || fail "install created the real user plasmoid directory"
fi

bash "$INSTALLER" status | grep -qx installed || fail "status did not see the private install"
bash "$INSTALLER" remove >/dev/null
[ ! -e "$PRIVATE_APPLET" ] || fail "remove left the package in place"

printf 'ok\n'
