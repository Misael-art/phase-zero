#!/usr/bin/env bash
# setup-codex.sh - install/update OpenAI Codex CLI in the user npm prefix.
#
# Codex self-updates through its own standalone installer. An existing install
# at or above the supported minimum is left alone: reinstalling a fixed old
# version here used to downgrade it and repoint ~/.local/bin/codex.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

NPM_PREFIX="${PZ_NPM_PREFIX:-$HOME/.local/share/npm}"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"

CODEX_MIN_VERSION="${PZ_CODEX_MIN_VERSION:-0.66.0}"
CODEX_VERSION="${PZ_CODEX_VERSION:-latest}"

active_codex_version() {
    command -v codex >/dev/null 2>&1 || return 1
    timeout 10 codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

version_at_least() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

keep_existing() {
    [ -n "$1" ] && version_at_least "$1" "$CODEX_MIN_VERSION" && [ "${PZ_CODEX_FORCE:-0}" != 1 ]
}

install_codex() {
    mkdir -p "$NPM_PREFIX"
    pz_info "installing Codex CLI @openai/codex@$CODEX_VERSION into user npm prefix: $NPM_PREFIX"
    npm install -g --prefix "$NPM_PREFIX" "@openai/codex@$CODEX_VERSION"
}

link_managed_bin() {
    local command_name="$1" source_path="$2"
    [ -x "$source_path" ] || return 0
    mkdir -p "$LOCAL_BIN"
    ln -sfn "$source_path" "$LOCAL_BIN/$command_name"
    pz_info "linked $command_name into $LOCAL_BIN"
}

status_json() {
    local version path="" supported=false keep=false
    version="$(active_codex_version || true)"
    [ -n "$version" ] && path="$(command -v codex)"
    [ -n "$version" ] && version_at_least "$version" "$CODEX_MIN_VERSION" && supported=true
    keep_existing "$version" && keep=true
    jq -cn --arg version "$version" --arg path "$path" --arg min "$CODEX_MIN_VERSION" \
        --arg pkg "@openai/codex@$CODEX_VERSION" --argjson supported "$supported" --argjson keep "$keep" \
        '{tool:"codex",installed:($version != ""),version:$version,path:$path,minimumVersion:$min,
          supported:$supported,
          planned:(if $keep then ["keep existing codex"] else ["npm install -g " + $pkg, "link ~/.local/bin/codex"] end),
          next:(if $supported then "" else "linux/pz ai setup codex" end)}'
}

setup() {
    local version active_path active_version
    version="$(active_codex_version || true)"
    if keep_existing "$version"; then
        pz_info "Codex CLI $version already installed at $(command -v codex) (>= $CODEX_MIN_VERSION); leaving it alone"
        return 0
    fi
    pz_check_deps npm
    install_codex
    link_managed_bin codex "$NPM_PREFIX/bin/codex"

    if command -v codex >/dev/null 2>&1; then
        active_path="$(command -v codex)"
        active_version="$(codex --version 2>/dev/null | head -1 || true)"
        pz_info "active codex: $active_version ($active_path)"
        if [ "$active_path" != "$LOCAL_BIN/codex" ] && [ -x "$LOCAL_BIN/codex" ]; then
            pz_warn "PATH resolves codex to $active_path before $LOCAL_BIN/codex"
        fi
    else
        pz_warn "codex installed but not on PATH; add $LOCAL_BIN"
    fi
}

case "${1:-setup}" in
    setup|install) setup ;;
    status) status_json ;;
    dry-run|plan) status_json | jq -c '. + {dryRun:true}' ;;
    *) echo "usage: setup-codex.sh (setup|status|dry-run)" >&2; exit 2 ;;
esac
