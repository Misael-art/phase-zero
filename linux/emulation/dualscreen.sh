#!/usr/bin/env bash
# dualscreen.sh - route dual-screen emulator windows to two physical displays
# (external monitor/TV + Steam Deck internal screen) in KDE Plasma Desktop Mode.
#
# gamescope (SteamOS Game Mode) is single-output + single-focus, so it cannot
# route two windows to two connectors. KWin (Plasma Wayland) is a true
# multi-output compositor with a "Screen" window rule. This feature operates in
# Desktop Mode only.
#
# Supported emulators:
#   cemu    - Wii U: opens GamePad as a 2nd window (open_pad=true)
#   azahar  - 3DS: Separate Windows layout (layout_option=5) [citra/lime3ds alias]
#   melonds - DS: single-window on TV (no native 2-window mode; documented limit)
#   ppsspp  - PSP: positions 2 instances on 2 screens (user starts both)
#   mgba    - GBA: positions 2 instances for link cable (user starts both)
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
# pz_ini_set/pz_ini_get vivem aqui; sem este source o apply do Azahar morria
# com "command not found" no meio da mutação (depois do backup, antes das
# regras KWin).
source "$PZ_ROOT/linux/emulation/common.sh"
source "$PZ_ROOT/linux/steamdeck/display-session.sh"

ACTION="${1:-status}"
KWINRULES="${XDG_CONFIG_HOME:-$HOME/.config}/kwinrulesrc"

# --- detection --------------------------------------------------------------

dualscreen_internal_connector() {
    # eDP-1 on the Deck; fall back to the first internal DRM connector.
    local root conn
    root="$(pz_display_sysfs_root)"
    for conn_dir in "$root"/class/drm/card*-eDP-* "$root"/class/drm/card*-DSI-* "$root"/class/drm/card*-LVDS-*; do
        [ -d "$conn_dir" ] || continue
        conn="$(basename "$conn_dir")"
        [ "$(cat "$conn_dir/status" 2>/dev/null)" = "connected" ] && { echo "$conn"; return 0; }
    done
    echo "eDP-1"
}

dualscreen_external_connector() {
    # First connected external connector (cardN- prefix stripped for KWin names).
    local raw
    raw="$(pz_display_connected_external_connectors | head -n1 || true)"
    [ -n "$raw" ] || return 0
    echo "${raw#card*-}"
}

dualscreen_available() {
    [ -n "$(dualscreen_external_connector)" ] && [ -n "$(dualscreen_internal_connector)" ]
}

# Resolve KWin screen indices via kscreen-doctor. Outputs: "<ext_idx> <int_idx>"
# on success; empty if kscreen-doctor is unavailable. The external (primary) is
# usually index 0 and the internal Deck panel index 1 when docked, but we resolve
# dynamically to survive output reordering.
dualscreen_kwin_indices() {
    command -v kscreen-doctor >/dev/null 2>&1 || return 0
    local ext int
    ext="$(dualscreen_external_connector)"
    int="$(dualscreen_internal_connector)"
    [ -n "$ext" ] && [ -n "$int" ] || return 0
    # kscreen-doctor -o prints "Output: <idx> <name>"; map names to indices.
    local out ext_idx int_idx
    # kscreen-doctor blocks forever when it cannot reach a KDE session (no
    # DBus/Wayland handle — e.g. a service, a test runner, or a fresh HOME).
    # A diagnostic must never hang: without indices, detect still reports
    # connectors and marks the KWin indices unknown.
    out="$(timeout 5 kscreen-doctor -o 2>/dev/null || true)"
    ext_idx="$(printf '%s\n' "$out" | sed -nE "s/.*Output:[[:space:]]*([0-9]+)[[:space:]]+$ext.*/\1/p" | head -n1)"
    int_idx="$(printf '%s\n' "$out" | sed -nE "s/.*Output:[[:space:]]*([0-9]+)[[:space:]]+$int.*/\1/p" | head -n1)"
    [ -n "$ext_idx" ] && [ -n "$int_idx" ] || return 0
    printf '%s %s\n' "$ext_idx" "$int_idx"
}

# --- KWin rule management ---------------------------------------------------

# Emit a single KWin rule group in kwinrulesrc INI format. Args:
#   $1 rule-id (uuid), $2 description, $3 wmclass, $4 screen index,
#   $5 position "x,y" (optional), $6 fullscreen "true/false" (optional)
dualscreen_kwin_rule_block() {
    local id="$1" desc="$2" wmclass="$3" screen="$4" pos="${5:-}" fs="${6:-}"
    cat <<EOF
[$id]
Description=$desc
pb_dualscreen_managed=true
wmclass=$wmclass
wmclasscomplete=false
wmclassmatch=1
screen=$screen
screenrule=2
types=1
EOF
    if [ -n "$pos" ]; then
        printf 'position=%s\npositionrule=2\n' "$pos"
    fi
    if [ "$fs" = "true" ]; then
        printf 'fullscreen=true\nfullscreenrule=2\n'
    elif [ "$fs" = "false" ]; then
        printf 'fullscreen=false\nfullscreenrule=2\n'
    fi
    printf '\n'
}

# Write/replacement a set of rule groups for an emulator. Removes any prior
# PhaseZero dualscreen rules for this emulator first (idempotent).
# Args: $1 emu-tag, then rule blocks on stdin.
dualscreen_kwin_write_rules() {
    local tag="$1"
    local blocks
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    blocks="$(pz_tempfile)"
    cat > "$blocks"
    if ! dualscreen_kwin_rewrite "$tag" "$blocks" false; then
        rm -f "$blocks"
        return 1
    fi
    rm -f "$blocks"

    # Reload KWin rules if a session is active.
    if [ "${PZ_DUALSCREEN_SKIP_RECONFIGURE:-0}" = "1" ]; then
        :
    elif command -v qdbus6 >/dev/null 2>&1; then
        qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true
    elif command -v qdbus >/dev/null 2>&1; then
        qdbus org.kde.KWin /KWin reconfigure 2>/dev/null || true
    fi
}

dualscreen_kwin_remove_all() {
    # Remove every PhaseZero dualscreen rule, leaving the rest intact.
    [ -f "$KWINRULES" ] || { pz_info "no kwinrulesrc present; nothing to remove"; return 0; }
    local empty
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    empty="$(pz_tempfile)"
    if ! dualscreen_kwin_rewrite "" "$empty" true; then
        rm -f "$empty"
        return 1
    fi
    rm -f "$empty"
    pz_info "removed PhaseZero dualscreen KWin rules"
    if [ "${PZ_DUALSCREEN_SKIP_RECONFIGURE:-0}" != "1" ] && command -v qdbus6 >/dev/null 2>&1; then
        qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true
    fi
}

dualscreen_kwin_rewrite() {
    local tag="$1" blocks="$2" remove_all="$3"
    install -d "$(dirname "$KWINRULES")"
    pz_backup_file "$KWINRULES" user >/dev/null
    python3 - "$KWINRULES" "$blocks" "$tag" "$remove_all" <<'PY'
import os
import re
import sys
import tempfile
from pathlib import Path

target = Path(sys.argv[1])
blocks_path = Path(sys.argv[2])
tag = sys.argv[3]
remove_all = sys.argv[4] == "true"
header = re.compile(r"^\[([^]]+)]\s*$")

def sections(text: str):
    preamble = []
    result = []
    current_name = None
    current_lines = []
    for line in text.splitlines(keepends=True):
        match = header.match(line.rstrip("\r\n"))
        if match:
            if current_name is None:
                preamble.extend(current_lines)
            else:
                result.append((current_name, current_lines))
            current_name = match.group(1)
            current_lines = [line]
        else:
            current_lines.append(line)
    if current_name is None:
        preamble.extend(current_lines)
    else:
        result.append((current_name, current_lines))
    return preamble, result

existing = target.read_text(encoding="utf-8", errors="replace") if target.exists() else ""
new_text = blocks_path.read_text(encoding="utf-8", errors="strict")
preamble, old_sections = sections(existing)
_, new_sections = sections(new_text)
kept = []
general_extra = []
prefix = f"Description=PhaseZero dualscreen: {tag}"
for name, lines in old_sections:
    if name == "General":
        general_extra = [
            line for line in lines[1:]
            if not re.match(r"^(?:count|rules)=", line)
        ]
        continue
    managed = any(line.strip() == "pb_dualscreen_managed=true" for line in lines)
    matches = remove_all or any(line.startswith(prefix) for line in lines)
    if managed and matches:
        continue
    kept.append((name, lines))
kept.extend((name, lines) for name, lines in new_sections if name != "General")
ids = [name for name, _lines in kept]
output = "".join(preamble)
for _name, lines in kept:
    if output and not output.endswith("\n"):
        output += "\n"
    output += "".join(lines)
    if not output.endswith("\n\n"):
        output += "\n"
output += "[General]\n"
output += "".join(general_extra)
output += f"count={len(ids)}\nrules={','.join(ids)}\n"
target.parent.mkdir(parents=True, exist_ok=True)
fd, temp_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(output)
        handle.flush()
        os.fsync(handle.fileno())
    if target.exists():
        os.chmod(temp_name, target.stat().st_mode & 0o777)
    else:
        os.chmod(temp_name, 0o600)
    os.replace(temp_name, target)
finally:
    try:
        os.unlink(temp_name)
    except FileNotFoundError:
        pass
PY
}

# --- per-emulator config writers -------------------------------------------

cemu_settings() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/Cemu/settings.xml"; }

dualscreen_apply_cemu() {
    local settings ext_idx int_idx indices
    settings="$(cemu_settings)"
    [ -f "$settings" ] || { pz_warn "Cemu settings.xml not found ($settings); skipped"; return 0; }
    indices="$(dualscreen_kwin_indices)"
    if [ -n "$indices" ]; then ext_idx="${indices% *}"; int_idx="${indices#* }"; else ext_idx=0; int_idx=1; fi

    pz_backup_file "$settings" user >/dev/null
    # open_pad=true opens the GamePad view as a separate window; fullscreen=false
    # lets KWin control placement instead of Cemu grabbing one screen.
    sed -i -E 's#<open_pad>(true|false)</open_pad>#<open_pad>true</open_pad>#' "$settings"
    sed -i -E 's#<fullscreen>(true|false)</fullscreen>#<fullscreen>false</fullscreen>#' "$settings"

    local main_id pad_id
    main_id="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    pad_id="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    {
        dualscreen_kwin_rule_block "$main_id" "PhaseZero dualscreen: cemu-main" "Cemu" "$ext_idx" "" "true"
        dualscreen_kwin_rule_block "$pad_id" "PhaseZero dualscreen: cemu-pad" "Cemu" "$int_idx" "0,0" "false"
    } | dualscreen_kwin_write_rules "cemu"

    pz_info "Cemu dual-screen: open_pad=true, main→screen $ext_idx, GamePad→screen $int_idx"
}

dualscreen_apply_azahar() {
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/azahar-emu/qt-config.ini"
    [ -f "$cfg" ] || cfg="${XDG_CONFIG_HOME:-$HOME/.config}/citra-emu/qt-config.ini"
    [ -f "$cfg" ] || { pz_warn "Azahar/Citra qt-config.ini not found; skipped"; return 0; }

    local indices ext_idx int_idx
    indices="$(dualscreen_kwin_indices)"
    if [ -n "$indices" ]; then ext_idx="${indices% *}"; int_idx="${indices#* }"; else ext_idx=0; int_idx=1; fi

    pz_backup_file "$cfg" user >/dev/null
    # layout_option=5 = Separate Windows (top screen + bottom screen as 2 windows).
    pz_ini_set "$cfg" "Layout" "layout_option" "5"
    pz_ini_set "$cfg" "Layout" "layout_option\\default" "false"

    local main_id bot_id
    main_id="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    bot_id="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    {
        dualscreen_kwin_rule_block "$main_id" "PhaseZero dualscreen: azahar-main" "azahar" "$ext_idx" "" "true"
        dualscreen_kwin_rule_block "$bot_id" "PhaseZero dualscreen: azahar-bottom" "azahar" "$int_idx" "0,0" "false"
    } | dualscreen_kwin_write_rules "azahar"

    pz_info "Azahar dual-screen: Separate Windows, top→screen $ext_idx, bottom→screen $int_idx"
}

dualscreen_apply_ppsspp() {
    local indices ext_idx int_idx
    indices="$(dualscreen_kwin_indices)"
    if [ -n "$indices" ]; then ext_idx="${indices% *}"; int_idx="${indices#* }"; else ext_idx=0; int_idx=1; fi
    local p1_id p2_id
    p1_id="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    p2_id="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    {
        dualscreen_kwin_rule_block "$p1_id" "PhaseZero dualscreen: ppsspp-p1" "PPSSPPQt" "$ext_idx" "" "true"
        dualscreen_kwin_rule_block "$p2_id" "PhaseZero dualscreen: ppsspp-p2" "PPSSPPQt" "$int_idx" "0,0" "false"
    } | dualscreen_kwin_write_rules "ppsspp"
    pz_info "PPSSPP dual-screen: P1→screen $ext_idx, P2→screen $int_idx (start 2 instances)"
}

dualscreen_apply_mgba() {
    local indices ext_idx int_idx
    indices="$(dualscreen_kwin_indices)"
    if [ -n "$indices" ]; then ext_idx="${indices% *}"; int_idx="${indices#* }"; else ext_idx=0; int_idx=1; fi
    local p1_id p2_id
    p1_id="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    p2_id="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    {
        dualscreen_kwin_rule_block "$p1_id" "PhaseZero dualscreen: mgba-p1" "mGBA" "$ext_idx" "" "true"
        dualscreen_kwin_rule_block "$p2_id" "PhaseZero dualscreen: mgba-p2" "mGBA" "$int_idx" "0,0" "false"
    } | dualscreen_kwin_write_rules "mgba"
    pz_info "mGBA dual-screen: P1→screen $ext_idx, P2→screen $int_idx (start 2 instances for link)"
}

dualscreen_apply_melonds() {
    # melonDS has no native 2-window mode; position the single window on the TV.
    local indices ext_idx
    indices="$(dualscreen_kwin_indices)"
    ext_idx="${indices% *}"
    [ -n "$ext_idx" ] || ext_idx=0
    local id
    id="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    {
        dualscreen_kwin_rule_block "$id" "PhaseZero dualscreen: melonds-main" "melonDS" "$ext_idx" "" "true"
    } | dualscreen_kwin_write_rules "melonds"
    pz_warn "melonDS has no native 2-window mode; single window on TV, Deck screen stays free"
}

dualscreen_apply() {
    local emu="${1:-all}"
    dualscreen_available || { pz_error "dual-screen unavailable: need external monitor + internal panel connected"; return 1; }
    case "$emu" in
        cemu) dualscreen_apply_cemu ;;
        azahar|citra|lime3ds) dualscreen_apply_azahar ;;
        melonds) dualscreen_apply_melonds ;;
        ppsspp) dualscreen_apply_ppsspp ;;
        mgba) dualscreen_apply_mgba ;;
        all)
            dualscreen_apply_cemu
            dualscreen_apply_azahar
            dualscreen_apply_melonds
            dualscreen_apply_ppsspp
            dualscreen_apply_mgba
            ;;
        *) pz_error "usage: dualscreen.sh apply (cemu|azahar|melonds|ppsspp|mgba|all)"; return 1 ;;
    esac
}

# --- status / detect --------------------------------------------------------

dualscreen_detect() {
    local ext int available indices ext_idx int_idx ext_res
    ext="$(dualscreen_external_connector || true)"
    int="$(dualscreen_internal_connector)"
    available=false; dualscreen_available && available=true
    indices="$(dualscreen_kwin_indices)"
    ext_idx="${indices% *}"; int_idx="${indices#* }"
    if [ -n "$ext" ]; then
        ext_res="$(pz_display_native_resolution "card1-$ext" 2>/dev/null | tr ' ' 'x')"
    fi
    jq -n \
        --argjson available "$available" \
        --arg external "$ext" --arg internal "$int" \
        --arg externalResolution "${ext_res:-unknown}" \
        --arg externalKwinIndex "${ext_idx:-unknown}" \
        --arg internalKwinIndex "${int_idx:-unknown}" \
        --arg mode "desktop-kwin" \
        '{available:$available, mode:$mode,
          externalConnector:$external, internalConnector:$internal,
          externalResolution:$externalResolution,
          externalKwinIndex:$externalKwinIndex, internalKwinIndex:$internalKwinIndex,
          note:"Desktop Mode (KWin) only; Game Mode (gamescope) is single-output"}'
}

dualscreen_status() {
    local cemu_pad=false azahar_sep=false rules_active=false
    [ -f "$(cemu_settings)" ] && grep -q '<open_pad>true</open_pad>' "$(cemu_settings)" 2>/dev/null && cemu_pad=true
    [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/azahar-emu/qt-config.ini" ] && \
        grep -qE '^layout_option[[:space:]]*=[[:space:]]*5\b' "${XDG_CONFIG_HOME:-$HOME/.config}/azahar-emu/qt-config.ini" 2>/dev/null && azahar_sep=true
    [ -f "$KWINRULES" ] && grep -q "PhaseZero dualscreen" "$KWINRULES" 2>/dev/null && rules_active=true
    jq -n --argjson cemuPad "$cemu_pad" --argjson azaharSep "$azahar_sep" --argjson rulesActive "$rules_active" \
        '{cemu:{gamePadOpen:$cemuPad}, azahar:{separateWindows:$azaharSep}, kwinRulesActive:$rulesActive}'
}

if [ "${PZ_DUALSCREEN_LIB_ONLY:-0}" = "1" ]; then
    if [ "${BASH_SOURCE[0]}" != "$0" ]; then
        return 0
    fi
    exit 0
fi

case "$ACTION" in
    apply) shift; dualscreen_apply "${1:-all}" ;;
    remove|reset) dualscreen_kwin_remove_all ;;
    detect) dualscreen_detect ;;
    status) dualscreen_status ;;
    dry-run|plan) dualscreen_detect ;;
    *) pz_error "usage: dualscreen.sh (apply [emu]|remove|detect|status|dry-run)"; exit 1 ;;
esac
