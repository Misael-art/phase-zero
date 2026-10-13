#!/usr/bin/env bash
# runtime-drift.sh - compare the script copies PhaseZero installs outside the
# repo (systemd timers run these, not the checkout) with their repo source.
#
# Installers copy once; later repo fixes never reach the host until the copy is
# refreshed. `status` is read-only. `sync` reruns each copy's own installer so
# the pinning/unit logic stays in one place.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

RUNTIME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/phasezero/runtime"
CC_TOOLS_DIR="${PZ_CC_INSTALLER_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/cc-installer}/tools"

# name|installed copy|repo source|refresh command (relative to PZ_ROOT)
managed_copies() {
    printf '%s\n' \
        "hermes-router|$RUNTIME_DIR/hermes-router.sh|linux/ai/hermes-router.sh|linux/ai/hermes-router.sh install" \
        "9router-hermes-provider|$RUNTIME_DIR/9router-hermes-provider.sh|linux/ai/9router-hermes-provider.sh|linux/ai/9router-hermes-provider.sh install" \
        "desktop-apps|$RUNTIME_DIR/desktop-apps.sh|linux/ai/desktop-apps.sh|linux/ai/desktop-apps.sh install-services"
}

# Installers pin PZ_ROOT="<repo>" into the copy; that line is expected to differ.
normalized_sha() {
    sed 's|^PZ_ROOT=.*$|PZ_ROOT=|' "$1" | sha256sum | cut -d' ' -f1
}

status_json() {
    local name installed source refresh state installed_sha repo_sha rows=() unmanaged=()
    while IFS='|' read -r name installed source refresh; do
        repo_sha="$(normalized_sha "$PZ_ROOT/$source")"
        if [ ! -f "$installed" ]; then
            state="not-installed"; installed_sha=""
        else
            installed_sha="$(normalized_sha "$installed")"
            [ "$installed_sha" = "$repo_sha" ] && state="in-sync" || state="drift"
        fi
        rows+=("$(jq -cn --arg name "$name" --arg installed "$installed" --arg source "$source" \
            --arg state "$state" --arg refresh "linux/pz ai drift sync" \
            --arg installedSha "$installed_sha" --arg repoSha "$repo_sha" \
            '{name:$name,installed:$installed,source:$source,state:$state,installedSha:$installedSha,repoSha:$repoSha,
              nextAction:(if $state == "drift" then $refresh else "" end)}')")
    done < <(managed_copies)
    # Copies under cc-installer/tools that no repo installer produces: report,
    # never touch (they may be hand-made and hold behavior the repo lacks).
    if [ -d "$CC_TOOLS_DIR" ]; then
        while IFS= read -r -d '' path; do
            unmanaged+=("$path")
        done < <(find "$CC_TOOLS_DIR" -mindepth 2 -maxdepth 2 -type f -print0 2>/dev/null)
    fi
    printf '%s\n' "${rows[@]}" | jq -s \
        --argjson unmanaged "$(printf '%s\n' "${unmanaged[@]+"${unmanaged[@]}"}" | jq -R . | jq -s 'map(select(. != ""))')" \
        '{schemaVersion:1,
          state:(if any(.[]; .state == "drift") then "drift" else "in-sync" end),
          copies:.,
          unmanagedCopies:$unmanaged,
          summary:(if any(.[]; .state == "drift")
                   then "Cópias instaladas divergem do repositório; correções não estão ativas."
                   else "Cópias instaladas iguais ao repositório." end),
          nextAction:(if any(.[]; .state == "drift") then "linux/pz ai drift sync" else "" end)}'
}

sync_copies() {
    local dry="${1:-false}" name installed source refresh
    while IFS='|' read -r name installed source refresh; do
        [ -f "$installed" ] || continue
        [ "$(normalized_sha "$installed")" = "$(normalized_sha "$PZ_ROOT/$source")" ] && continue
        if [ "$dry" = true ]; then
            printf 'would refresh %s: bash %s\n' "$name" "$refresh"
        else
            pz_info "refreshing $name from repo"
            # shellcheck disable=SC2086 # refresh is "<script> <subcommand>"
            bash "$PZ_ROOT"/$refresh
        fi
    done < <(managed_copies)
}

case "${1:-status}" in
    status)
        out="$(status_json)"
        printf '%s\n' "$out"
        [ "$(jq -r .state <<< "$out")" = "in-sync" ] || exit 2
        ;;
    sync)
        case "${2:-}" in
            --dry-run) sync_copies true ;;
            "") sync_copies false ;;
            *) echo "usage: runtime-drift.sh sync [--dry-run]" >&2; exit 2 ;;
        esac
        ;;
    dry-run|plan) sync_copies true ;;
    *) echo "usage: runtime-drift.sh (status|sync [--dry-run]|dry-run)" >&2; exit 2 ;;
esac
