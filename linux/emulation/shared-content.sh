#!/usr/bin/env bash
# shared-content.sh - canonical content links for RetroDECK and other consumers
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"
source "$PZ_ROOT/linux/lib/json-envelope.sh"

PZ_JSON=false
args=()
for arg in "$@"; do
    if [ "$arg" = "--json" ]; then
        PZ_JSON=true
    else
        args+=("$arg")
    fi
done

ACTION="${args[0]:-status}"
PZ_BACKUP_DIR="$PZ_EMULATION_ROOT/.phasezero/backups"
PZ_SHARED_MIGRATIONS="$PZ_BACKUP_DIR/shared-migrations.json"

pz_shared_mappings() {
    local root
    root="$(pz_retrodeck_root)"
    printf 'roms|%s/roms|%s\n' "$PZ_EMULATION_ROOT" "$(pz_retrodeck_path roms_path roms)"
    printf 'bios|%s/bios|%s\n' "$PZ_EMULATION_ROOT" "$(pz_retrodeck_path bios_path bios)"
    printf 'saves|%s/saves|%s\n' "$PZ_EMULATION_ROOT" "$(pz_retrodeck_path saves_path saves)"
    printf 'states|%s/states|%s\n' "$PZ_EMULATION_ROOT" "$(pz_retrodeck_path states_path states)"
    printf 'shaders|%s/shaders|%s\n' "$PZ_EMULATION_ROOT" "$(pz_retrodeck_path shaders_path shaders)"
    printf 'screenshots|%s/screenshots|%s\n' "$PZ_EMULATION_ROOT" "$(pz_retrodeck_path screenshots_path screenshots)"
    printf 'videos|%s/videos|%s\n' "$PZ_EMULATION_ROOT" "$(pz_retrodeck_path videos_path videos)"
    printf 'borders|%s/borders|%s\n' "$PZ_EMULATION_ROOT" "$(pz_retrodeck_path borders_path borders)"
    printf 'themes|%s/themes|%s\n' "$PZ_EMULATION_ROOT" "$(pz_retrodeck_path themes_path ES-DE/themes)"
    printf 'gamelists|%s/metadata/gamelists|%s/ES-DE/gamelists\n' "$PZ_EMULATION_ROOT" "$root"
    printf 'collections|%s/metadata/collections|%s/ES-DE/collections\n' "$PZ_EMULATION_ROOT" "$root"
    printf 'esde.gamelists|%s/metadata/gamelists|%s/ES-DE/gamelists\n' "$PZ_EMULATION_ROOT" "$HOME"
    printf 'esde.collections|%s/metadata/collections|%s/ES-DE/collections\n' "$PZ_EMULATION_ROOT" "$HOME"
    printf 'esde.themes|%s/themes|%s/ES-DE/themes\n' "$PZ_EMULATION_ROOT" "$HOME"
    printf 'cheats|%s/cheats|%s\n' "$PZ_EMULATION_ROOT" "$(pz_retrodeck_path cheats_path cheats)"
    printf 'mods|%s/mods|%s\n' "$PZ_EMULATION_ROOT" "$(pz_retrodeck_path mods_path mods)"
    printf 'texture_packs|%s/texture_packs|%s\n' "$PZ_EMULATION_ROOT" "$(pz_retrodeck_path texture_packs_path texture_packs)"
    printf 'firmware|%s/firmware|%s/firmware\n' "$PZ_EMULATION_ROOT" "$root"
    printf 'keys|%s/keys|%s/keys\n' "$PZ_EMULATION_ROOT" "$root"
    printf 'patches|%s/patches|%s/patches\n' "$PZ_EMULATION_ROOT" "$root"
}

pz_shared_path_status() {
    local canonical="$1" consumer="$2"
    if [ -L "$consumer" ] && [ "$(readlink "$consumer")" = "$canonical" ]; then
        echo "linked"
    elif [ -L "$consumer" ]; then
        echo "wrong-link"
    elif [ -d "$consumer" ]; then
        echo "directory"
    elif [ -e "$consumer" ]; then
        echo "file"
    else
        echo "missing"
    fi
}

pz_shared_record_migration() {
    local name="$1" source="$2" backup="$3" files="$4" timestamp tmp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    install -d "$PZ_BACKUP_DIR"
    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    tmp="$(pz_tempfile)"
    if [ -f "$PZ_SHARED_MIGRATIONS" ] && jq -e '.migrations | type == "array"' "$PZ_SHARED_MIGRATIONS" >/dev/null 2>&1; then
        jq --arg name "$name" --arg source "$source" --arg backup "$backup" \
            --arg timestamp "$timestamp" --argjson files "$files" \
            '.migrations += [{name:$name, source:$source, backup:$backup, files:$files, timestamp:$timestamp}]' \
            "$PZ_SHARED_MIGRATIONS" > "$tmp"
    else
        jq -n --arg name "$name" --arg source "$source" --arg backup "$backup" \
            --arg timestamp "$timestamp" --argjson files "$files" \
            '{version:1, migrations:[{name:$name, source:$source, backup:$backup, files:$files, timestamp:$timestamp}]}' > "$tmp"
    fi
    mv "$tmp" "$PZ_SHARED_MIGRATIONS"
}

pz_shared_copy_missing() {
    local source="$1" target="$2"
    if command -v rsync >/dev/null 2>&1; then
        rsync --ignore-existing -a "$source/" "$target/"
    else
        cp -an "$source/." "$target/"
    fi
}

pz_shared_link_one() {
    local name="$1" canonical="$2" consumer="$3" mode="${4:-apply}"
    local status files=0 backup safe_name
    install -d "$canonical" "$PZ_BACKUP_DIR"
    status="$(pz_shared_path_status "$canonical" "$consumer")"
    [ "$status" = "linked" ] && return 0

    safe_name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '_')"
    backup="$PZ_BACKUP_DIR/retrodeck-${safe_name}-$(date +%s)-$$"

    case "$status" in
        directory)
            files="$(pz_emulation_count_files "$consumer")"
            if [ "$files" -gt 0 ]; then
                pz_info "migrating RetroDECK $name: $files file(s)"
                pz_shared_copy_missing "$consumer" "$canonical"
            fi
            install -d "$backup"
            mv "$consumer" "$backup/original"
            pz_shared_record_migration "$name" "$consumer" "$backup/original" "$files"
            pz_info "backup: $backup/original"
            ;;
        wrong-link|file)
            install -d "$backup"
            mv "$consumer" "$backup/original"
            pz_shared_record_migration "$name" "$consumer" "$backup/original" 0
            pz_warn "noncanonical RetroDECK path backed up: $consumer"
            ;;
    esac

    install -d "$(dirname "$consumer")"
    ln -s "$canonical" "$consumer"
    pz_info "$mode RetroDECK $name -> $canonical"
}

pz_shared_retrodeck_flatpak_status() {
    if ! command -v flatpak >/dev/null 2>&1; then
        echo "flatpak-not-available"
        return 0
    fi
    if ! flatpak info "$PZ_RETRODECK_APP_ID" >/dev/null 2>&1; then
        echo "retrodeck-not-installed"
        return 0
    fi
    local user_override app_permissions
    user_override="$(flatpak override --user --show "$PZ_RETRODECK_APP_ID" 2>/dev/null || true)"
    app_permissions="$(flatpak info --show-permissions "$PZ_RETRODECK_APP_ID" 2>/dev/null || true)"
    if printf '%s\n%s\n' "$user_override" "$app_permissions" | grep -qF "$PZ_EMULATION_ROOT"; then
        echo "configured"
    elif printf '%s\n' "$app_permissions" | grep -Eq '(^|[=;])(host|home)(;|$)'; then
        echo "configured"
    else
        echo "missing"
    fi
}

pz_shared_apply_flatpak_override() {
    local status
    status="$(pz_shared_retrodeck_flatpak_status)"
    if [ "$status" = "missing" ]; then
        flatpak override --user --filesystem="$PZ_EMULATION_ROOT:rw" "$PZ_RETRODECK_APP_ID"
        pz_info "RetroDECK Flatpak access -> $PZ_EMULATION_ROOT"
    fi
}

cmd_status() {
    local name canonical consumer status ret=0
    echo "=== RetroDECK Shared Content ==="
    echo "  manifest: $PZ_RETRODECK_MANIFEST"
    echo "  root: $(pz_retrodeck_root)"
    while IFS='|' read -r name canonical consumer; do
        status="$(pz_shared_path_status "$canonical" "$consumer")"
        printf "  %-16s %-11s %s -> %s\n" "$name" "[$status]" "$consumer" "$canonical"
        [ "$status" != "linked" ] && ret=1
    done < <(pz_shared_mappings)
    status="$(pz_shared_retrodeck_flatpak_status)"
    echo "  flatpak access: $status"
    [ "$status" = "missing" ] && ret=1
    # Drift is a reported state, not a tool failure (matches --json rc0).
    if [ "$ret" -ne 0 ]; then
        echo "  next: run 'pz emulation shared apply' to migrate/link divergent paths"
    fi
    return 0
}

cmd_plan() {
    local name canonical consumer status files
    echo "=== RetroDECK Shared Content Plan ==="
    echo "  manifest: $PZ_RETRODECK_MANIFEST"
    echo "  root: $(pz_retrodeck_root)"
    while IFS='|' read -r name canonical consumer; do
        status="$(pz_shared_path_status "$canonical" "$consumer")"
        case "$status" in
            linked) echo "  ok: $name linked" ;;
            directory)
                files="$(pz_emulation_count_files "$consumer")"
                echo "  migrate+backup+link: $name ($files file(s))"
                ;;
            *) echo "  backup+link: $name ($status)" ;;
        esac
    done < <(pz_shared_mappings)
    status="$(pz_shared_retrodeck_flatpak_status)"
    [ "$status" = "missing" ] && echo "  grant Flatpak rw: $PZ_EMULATION_ROOT"
    return 0
}

cmd_apply() {
    local name canonical consumer
    pz_emulation_abort_if_frontend_running
    pz_emulation_ensure_layout
    pz_shared_apply_flatpak_override
    while IFS='|' read -r name canonical consumer; do
        pz_shared_link_one "$name" "$canonical" "$consumer" "linked"
    done < <(pz_shared_mappings)
    pz_info "RetroDECK shared content ready"
}

cmd_repair() {
    local name canonical consumer
    pz_emulation_abort_if_frontend_running
    pz_emulation_ensure_layout
    pz_shared_apply_flatpak_override
    while IFS='|' read -r name canonical consumer; do
        pz_shared_link_one "$name" "$canonical" "$consumer" "repaired"
    done < <(pz_shared_mappings)
    pz_info "RetroDECK shared content repaired"
}

cmd_status_json() {
    local name canonical consumer status overall="ok" flatpak_status
    pz_json_envelope_start "emulation" "ok"
    pz_json_append_check "shared.retrodeck.manifest" \
        "$([ -f "$PZ_RETRODECK_MANIFEST" ] && echo ok || echo warn)" \
        "$PZ_RETRODECK_MANIFEST root=$(pz_retrodeck_root)"
    while IFS='|' read -r name canonical consumer; do
        status="$(pz_shared_path_status "$canonical" "$consumer")"
        [ "$status" != "linked" ] && overall="warn"
        pz_json_append_check "shared.$name" \
            "$([ "$status" = "linked" ] && echo ok || echo warn)" \
            "$status consumer=$consumer canonical=$canonical"
    done < <(pz_shared_mappings)
    flatpak_status="$(pz_shared_retrodeck_flatpak_status)"
    [ "$flatpak_status" = "missing" ] && overall="warn"
    pz_json_append_check "shared.flatpak" \
        "$([ "$flatpak_status" = "configured" ] && echo ok || echo warn)" \
        "$flatpak_status"
    pz_json_append_action "emulation.retrodeck.plan" "Ver plano RetroDECK" false
    pz_json_append_action "emulation.retrodeck.integrate" "Integrar RetroDECK" true
    pz_json_append_action "emulation.retrodeck.repair" "Reparar RetroDECK" true
    PZ_JSON_STATUS="$overall"
    [ "$overall" != "ok" ] && PZ_JSON_OK=false
    pz_json_envelope_end
}

case "$ACTION" in
    status) if $PZ_JSON; then cmd_status_json; else cmd_status; fi ;;
    plan|dry-run) cmd_plan ;;
    apply|integrate) cmd_apply ;;
    repair) cmd_repair ;;
    *)
        pz_error "usage: shared-content.sh (status|plan|apply|integrate|repair)"
        exit 1
        ;;
esac
