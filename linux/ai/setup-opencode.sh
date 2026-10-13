#!/usr/bin/env bash
# setup-opencode.sh - configure OpenCode with MCPs, secrets and Steam Deck desktop UX
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

OPENCODE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"
NPM_PREFIX="${PZ_NPM_PREFIX:-$HOME/.local/share/npm}"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
OPENCODE_DB="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db"
OPENCODE_DESKTOP_SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/ai.opencode.desktop/default.dat"
SYNC_HOOK_FILE="/etc/pacman.d/hooks/phasezero-opencode-sync.hook"
SYNC_HOOK_SCRIPT="/usr/local/lib/phasezero/opencode-sync-hook"

# Terminals whose OSC 52 clipboard write works out of the box, preference order.
# kitty first: it also implements text-input-v3, which KWin needs to surface the
# Maliit virtual keyboard for a terminal. Konsole is deliberately absent: it
# ignores OSC 52, so OpenCode's copy silently fails inside it (OpenCode has no
# wl-copy/xclip fallback).
OSC52_TERMINALS=(kitty ghostty foot wezterm alacritty)

admin_run() {
    if pz_can_sudo_noninteractive; then
        sudo -n "$@"
    elif command -v phasezero-admin >/dev/null 2>&1; then
        phasezero-admin "$@"
    else
        return 127
    fi
}

opencode_npm_managed() {
    [ -x "$NPM_PREFIX/bin/opencode" ]
}

link_managed_bin() {
    local command_name="$1" source_path="$2"
    [ -x "$source_path" ] || return 0
    mkdir -p "$LOCAL_BIN"
    ln -sfn "$source_path" "$LOCAL_BIN/$command_name"
    pz_info "linked $command_name into $LOCAL_BIN"
}

# --- version orchestration (CLI <-> desktop lockstep) ------------------------
#
# The opencode CLI and opencode-desktop share one SQLite DB
# (~/.local/share/opencode/opencode.db). Its schema is migrated forward by
# whichever binary is newest. If the CLI and desktop drift apart, the older one
# crashes on the migrated schema (e.g. `no such column: replacement_seq`).
#
# Guarantee: pin the CLI to the *exact* desktop version. Newer would migrate the
# DB and break the desktop; older breaks the CLI. We install the CLI from npm
# into the user prefix and link it into ~/.local/bin, which precedes /usr/bin on
# PATH, so it shadows any system (pacman) opencode without root.

# Never fails: a broken CLI prints nothing parseable, and under `set -e` a
# non-zero grep here would abort the caller mid-repair instead of letting it
# diagnose and roll back.
version_of() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<< "${1:-}" | head -1 || true; }

opencode_cli_version() {
    command -v opencode >/dev/null 2>&1 || return 0
    version_of "$(opencode --version 2>/dev/null)"
}

opencode_cli_path() { command -v opencode 2>/dev/null || true; }

opencode_desktop_version() {
    command -v pacman >/dev/null 2>&1 || return 0
    version_of "$(pacman -Q opencode-desktop-bin 2>/dev/null)"
}

cli_is_managed() {
    local cp; cp="$(opencode_cli_path)"
    [ -n "$cp" ] || return 1
    [ "$(readlink -f "$cp" 2>/dev/null)" = "$(readlink -f "$NPM_PREFIX/bin/opencode" 2>/dev/null)" ]
}

resolve_cli_target() {
    if [ -n "${PZ_OPENCODE_VERSION:-}" ]; then printf '%s\n' "$PZ_OPENCODE_VERSION"; return 0; fi
    local dv; dv="$(opencode_desktop_version)"
    if [ -n "$dv" ]; then printf '%s\n' "$dv"; return 0; fi
    local cv; cv="$(opencode_cli_version)"
    if [ -n "$cv" ]; then printf '%s\n' "$cv"; return 0; fi
    printf 'latest\n'
}

backup_opencode_db() {
    [ -f "$OPENCODE_DB" ] || return 0
    local bak="${OPENCODE_DB}.pz-bak"
    # Root is btrfs here: reflink is an instant COW copy that costs no space
    # until the files diverge. Fall back to a plain copy elsewhere.
    if cp --reflink=auto -f "$OPENCODE_DB" "$bak" 2>/dev/null || cp -f "$OPENCODE_DB" "$bak" 2>/dev/null; then
        pz_info "backed up opencode.db -> $bak"
    fi
}

# opencode-ai ships a postinstall that fetches the platform-specific binary, so
# the package is useless without it. npm >= 12 blocks lifecycle scripts unless
# the package is named explicitly -- and it still exits 0, leaving a stub that
# dies with "postinstall script was not run". Allow scripts for this one package
# only; never --dangerously-allow-all-scripts, which would also unblock the
# whole transitive tree.
npm_allow_scripts_args() {
    npm install --help 2>/dev/null | grep -q -- '--allow-scripts' || return 0
    printf '%s\n' "--allow-scripts=opencode-ai"
}

managed_cli_package_version() {
    local manifest="$NPM_PREFIX/lib/node_modules/opencode-ai/package.json"
    [ -f "$manifest" ] || return 0
    version_of "$(jq -r '.version // empty' "$manifest" 2>/dev/null || true)"
}

# The only trustworthy signal that an install worked: run the binary. npm's exit
# code does not cover a blocked postinstall, and a stub still passes -x.
managed_cli_runs_as() {
    local target="$1" probe
    [ -x "$NPM_PREFIX/bin/opencode" ] || return 1
    probe="$("$NPM_PREFIX/bin/opencode" --version 2>/dev/null || true)"
    [ "$(version_of "$probe")" = "$target" ]
}

npm_install_cli() {
    local version="$1" allow_scripts
    mapfile -t allow_scripts < <(npm_allow_scripts_args)
    npm install -g --prefix "$NPM_PREFIX" "${allow_scripts[@]}" "opencode-ai@$version"
}

align_cli_to() {
    local target="$1" current previous
    current="$(opencode_cli_version)"

    if [ "$current" = "$target" ] && cli_is_managed; then
        pz_info "opencode CLI already pinned to $target (managed)"
        return 0
    fi

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would pin opencode CLI to $target via npm and link into $LOCAL_BIN"
        return 0
    fi

    pz_check_deps npm
    backup_opencode_db
    mkdir -p "$NPM_PREFIX"
    # Remember what worked so a failed upgrade can be undone instead of leaving
    # the host with no usable CLI.
    previous="$(managed_cli_package_version)"
    pz_info "pinning opencode CLI to $target (npm user prefix, shadows system opencode)"
    if ! npm_install_cli "$target"; then
        pz_error "npm install opencode-ai@$target failed"
        restore_previous_cli "$previous"
        return 1
    fi

    # Probe before linking: a broken binary must never be published into
    # $LOCAL_BIN, where it shadows the system opencode on PATH.
    if ! managed_cli_runs_as "$target"; then
        pz_error "opencode CLI $target installed but does not execute (blocked postinstall or bad platform build)"
        restore_previous_cli "$previous"
        return 1
    fi

    link_managed_bin opencode "$NPM_PREFIX/bin/opencode"
    hash -r 2>/dev/null || true

    local resolved; resolved="$(opencode_cli_version)"
    if [ "$resolved" = "$target" ] && cli_is_managed; then
        pz_info "opencode CLI now $resolved (in lockstep with desktop/target)"
    elif [ "$resolved" = "$target" ]; then
        pz_info "opencode CLI resolves to $resolved"
    else
        pz_warn "opencode CLI resolves to ${resolved:-none}, not $target: $LOCAL_BIN may sit behind /usr/bin on PATH."
        pz_warn "managed binary is $NPM_PREFIX/bin/opencode; ensure $LOCAL_BIN precedes /usr/bin, or remove the system opencode package."
    fi
}

# Undo a failed pin. Reinstalling the previous version is preferred; if that is
# gone or also broken, unlink the managed binary so PATH falls back to whatever
# the host already had rather than resolving to a stub.
restore_previous_cli() {
    local previous="${1:-}"
    if [ -n "$previous" ] && npm_install_cli "$previous" >/dev/null 2>&1 &&
        managed_cli_runs_as "$previous"; then
        link_managed_bin opencode "$NPM_PREFIX/bin/opencode"
        hash -r 2>/dev/null || true
        pz_warn "rolled opencode CLI back to $previous"
        return 0
    fi
    if [ -L "$LOCAL_BIN/opencode" ] &&
        [ "$(readlink -f "$LOCAL_BIN/opencode" 2>/dev/null)" = "$(readlink -f "$NPM_PREFIX/bin/opencode" 2>/dev/null)" ]; then
        rm -f "$LOCAL_BIN/opencode"
        hash -r 2>/dev/null || true
        pz_warn "unlinked broken managed opencode from $LOCAL_BIN; host CLI (if any) is back on PATH"
    fi
    return 0
}

opencode_sync() {
    # Lock guard: the async pacman hook can fire overlapping runs if multiple
    # opencode packages upgrade in one transaction. Bail out silently if another
    # sync is already in flight.
    local lock_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/phasezero-opencode-sync.lock"
    if mkdir "$lock_dir" 2>/dev/null; then
        # Use the literal path in the trap (not the local var) so cleanup works
        # even after the function returns and the local goes out of scope.
        trap 'rmdir "'"$lock_dir"'" 2>/dev/null || true' EXIT
    else
        pz_info "opencode sync already in progress; skipping"
        return 0
    fi
    local dv; dv="$(opencode_desktop_version)"
    # A lone system CLI with no desktop cannot skew; leave it untouched unless a
    # version is explicitly requested or the CLI is already npm-managed.
    if [ -z "$dv" ] && [ -z "${PZ_OPENCODE_VERSION:-}" ] && ! cli_is_managed && command -v opencode >/dev/null 2>&1; then
        pz_info "no opencode-desktop and CLI is system-managed; no lockstep needed"
        return 0
    fi
    local target; target="$(resolve_cli_target)"
    if [ -n "$dv" ]; then
        pz_info "opencode-desktop $dv present; aligning CLI to it (shared DB: $OPENCODE_DB)"
    fi
    align_cli_to "$target"
}

opencode_version_status() {
    local cv dv cp target insync=true
    cv="$(opencode_cli_version)"; dv="$(opencode_desktop_version)"
    cp="$(opencode_cli_path)"; target="$(resolve_cli_target)"
    [ -n "$dv" ] && { [ "$cv" = "$dv" ] && insync=true || insync=false; }
    jq -n \
        --arg cli "$cv" --arg cliPath "$cp" --arg desktop "$dv" \
        --arg target "$target" --arg db "$OPENCODE_DB" \
        --argjson managed "$(cli_is_managed && echo true || echo false)" \
        --argjson inSync "$insync" \
        --argjson dbPresent "$([ -f "$OPENCODE_DB" ] && echo true || echo false)" \
        --argjson hook "$([ -f "$SYNC_HOOK_FILE" ] && echo true || echo false)" \
        --argjson creds "$(opencode_has_credentials && echo true || echo false)" \
        --argjson usable "$(opencode_has_usable_model && echo true || echo false)" \
        --argjson localProvider "$([ -f "$OPENCODE_CONFIG" ] && jq -e '.provider.ollama.models | length > 0' "$OPENCODE_CONFIG" >/dev/null 2>&1 && echo true || echo false)" \
        '{
            tool: "opencode-version",
            cli: (if $cli == "" then null else $cli end),
            cliPath: (if $cliPath == "" then null else $cliPath end),
            cliManaged: $managed,
            desktop: (if $desktop == "" then null else $desktop end),
            target: $target,
            inSync: $inSync,
            autoSyncHook: $hook,
            model: {hasCredentials: $creds, localProvider: $localProvider, usable: $usable},
            db: {path: $db, present: $dbPresent}
        }'
}

install_sync_hook() {
    local user
    # When invoked via bigsudo/pkexec/sudo the effective user is root; resolve
    # the real invoking user so the async sync runs in their session/HOME (npm
    # prefix, opencode DB live there).
    user="${SUDO_USER:-${PKEXEC_USER:-$(id -un)}}"
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would install pacman hook re-pinning the CLI after opencode/opencode-desktop-bin upgrades"
        return 0
    fi
    local tmp_script tmp_hook
    tmp_script="$(mktemp)"; tmp_hook="$(mktemp)"
    cat > "$tmp_script" <<EOF
#!/usr/bin/env bash
# PhaseZero: keep the opencode CLI pinned to the opencode-desktop version.
# Installed by linux/ai/setup-opencode.sh install-hook.
#
# Runs ASYNC: the sync shells out to npm (network), which can take long enough
# to abort or time out a pacman/pamac PostTransaction and roll the whole update
# back. Instead of blocking the transaction, we dispatch the sync as a detached
# user job (systemd-run --user when available, nohup otherwise) and return at
# once. A lock guard prevents overlapping syncs.
user="$user"
sync_cmd='bash "$PZ_ROOT/linux/ai/setup-opencode.sh" sync'
if command -v systemd-run >/dev/null 2>&1; then
    runuser -l "\$user" -c "systemd-run --user --unit=phasezero-opencode-sync --quiet -- bash -lc \"\$sync_cmd\"" >/dev/null 2>&1 || \
        runuser -l "\$user" -c "setsid nohup bash -lc \"\$sync_cmd\" >/dev/null 2>&1 &" >/dev/null 2>&1 || true
else
    runuser -l "\$user" -c "setsid nohup bash -lc \"\$sync_cmd\" >/dev/null 2>&1 &" >/dev/null 2>&1 || true
fi
exit 0
EOF
    cat > "$tmp_hook" <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = opencode
Target = opencode-desktop-bin

[Action]
Description = PhaseZero: re-pin opencode CLI to the opencode-desktop version
When = PostTransaction
Exec = $SYNC_HOOK_SCRIPT
EOF
    if admin_run install -Dm755 "$tmp_script" "$SYNC_HOOK_SCRIPT" &&
        admin_run install -Dm644 "$tmp_hook" "$SYNC_HOOK_FILE"; then
        pz_info "installed opencode auto-sync pacman hook (async; $SYNC_HOOK_FILE)"
    else
        pz_warn "could not install pacman hook (needs root); run manually: linux/pz ai opencode sync after opencode updates"
    fi
    rm -f "$tmp_script" "$tmp_hook"
}

remove_sync_hook() {
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then pz_info "dry-run: would remove opencode auto-sync pacman hook"; return 0; fi
    admin_run rm -f "$SYNC_HOOK_FILE" "$SYNC_HOOK_SCRIPT" 2>/dev/null || true
    pz_info "removed opencode auto-sync pacman hook (if present)"
}

find_osc52_terminal() {
    local term
    if [ -n "${PZ_OPENCODE_TERMINAL:-}" ] && command -v "$PZ_OPENCODE_TERMINAL" >/dev/null 2>&1; then
        printf '%s\n' "$PZ_OPENCODE_TERMINAL"
        return 0
    fi
    for term in "${OSC52_TERMINALS[@]}"; do
        if command -v "$term" >/dev/null 2>&1; then
            printf '%s\n' "$term"
            return 0
        fi
    done
    return 1
}

ensure_clipboard_stack() {
    local missing=()
    command -v wl-copy >/dev/null 2>&1 || missing+=(wl-clipboard)
    find_osc52_terminal >/dev/null || missing+=(kitty)

    [ ${#missing[@]} -gt 0 ] || return 0

    if ! command -v pacman >/dev/null 2>&1; then
        pz_warn "OpenCode clipboard needs: ${missing[*]}; install them manually"
        return 0
    fi

    pz_info "installing OpenCode clipboard stack: ${missing[*]}"
    if admin_run pacman -S --needed --noconfirm "${missing[@]}"; then
        pz_info "clipboard stack installed"
    else
        pz_warn "could not install ${missing[*]} automatically; run: sudo pacman -S ${missing[*]}"
    fi
}

write_deck_launcher() {
    mkdir -p "$LOCAL_BIN"
    pz_write_managed_file "$LOCAL_BIN/opencode-deck" <<EOF
#!/usr/bin/env bash
# opencode-deck - run OpenCode in an OSC52-capable terminal with the Steam Deck
# virtual keyboard. Konsole ignores OSC 52, so OpenCode copy fails inside it.
# --auto: aceitar permissões automaticamente (mesma opção da UI).
set -euo pipefail
PZ_ROOT="$PZ_ROOT"

TERMINAL="\${PZ_OPENCODE_TERMINAL:-}"
if [ -z "\$TERMINAL" ]; then
    for term in ${OSC52_TERMINALS[*]}; do
        if command -v "\$term" >/dev/null 2>&1; then
            TERMINAL="\$term"
            break
        fi
    done
fi
if [ -z "\$TERMINAL" ]; then
    TERMINAL="konsole"
    echo "warn: no OSC52-capable terminal found; copy inside OpenCode will not reach the clipboard (run: pz ai setup opencode)" >&2
fi

# Surface the virtual keyboard for touch typing on the Deck itself. It must be
# requested AFTER the terminal is focused: KWin only shows Maliit while a
# text-input client (e.g. kitty) holds focus.
if [ "\${PZ_OPENCODE_NO_KEYBOARD:-0}" != "1" ] &&
    [ "\$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)" = "Jupiter" ] &&
    [ -f "\$PZ_ROOT/linux/steamdeck/input-actions.sh" ]; then
    ( sleep 2; bash "\$PZ_ROOT/linux/steamdeck/input-actions.sh" open >/dev/null 2>&1 ) &
fi

case "\$TERMINAL" in
    wezterm) exec wezterm start -- opencode --auto "\$@" ;;
    kitty|foot) exec "\$TERMINAL" opencode --auto "\$@" ;;
    *) exec "\$TERMINAL" -e opencode --auto "\$@" ;;
esac
EOF
    chmod +x "$LOCAL_BIN/opencode-deck"

    pz_write_managed_file "$APPLICATIONS_DIR/phasezero-opencode.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=OpenCode (Deck)
Comment=OpenCode with working clipboard and virtual keyboard for Steam Deck desktop mode
Exec=$LOCAL_BIN/opencode-deck
Icon=utilities-terminal
Terminal=false
Categories=Development;Utility;
EOF
}

print_dry_run() {
    local terminal=""
    terminal="$(find_osc52_terminal || true)"
    jq -n \
        --arg tool "opencode" \
        --arg terminal "${terminal:-}" \
        --argjson npmManaged "$(opencode_npm_managed && echo true || echo false)" \
        --argjson wlClipboard "$(command -v wl-copy >/dev/null 2>&1 && echo true || echo false)" \
        --argjson installed "$(command -v opencode >/dev/null 2>&1 && echo true || echo false)" \
        '{
            tool: $tool,
            installed: $installed,
            npmManaged: $npmManaged,
            clipboard: {
                wlClipboard: $wlClipboard,
                osc52Terminal: (if $terminal == "" then null else $terminal end)
            },
            launcher: "opencode-deck"
        }'
}

# --- local model provider (Ollama) ------------------------------------------
#
# With no authenticated cloud provider, every model opencode/OMO reference needs
# credentials, so any chat is "Interrupted" immediately. If the host runs Ollama
# we wire it as a key-free local provider so opencode has a usable model. Local
# inference is CPU-slow on weak APUs (the Deck); a small model keeps it usable.

OLLAMA_URL="${PZ_OLLAMA_URL:-http://127.0.0.1:11434}"
OPENCODE_AUTH="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json"

ollama_models() {
    # Always exit 0: an unreachable Ollama (curl 7 under pipefail) must not abort
    # callers running with set -e.
    { curl -fsS "$OLLAMA_URL/api/tags" 2>/dev/null || true; } | jq -r '.models[].name' 2>/dev/null || true
}

opencode_has_credentials() {
    [ -f "$OPENCODE_AUTH" ] && [ "$(jq 'length' "$OPENCODE_AUTH" 2>/dev/null || echo 0)" -gt 0 ]
}

# --- keyless cloud free models (opencode Zen) --------------------------------
#
# opencode.ai serves several "*-free" Zen models that need NO auth and answer in
# ~1s. A local Ollama default is keyless too, but CPU inference on weak APUs is
# slow enough that the first token can exceed opencode-desktop's request timeout,
# and the chat shows "Interrompido"/"Interrupted". So we prefer a fast keyless
# Zen free model as the *default* (e.g. deepseek-v4-flash-free) and keep Ollama
# as an offline-capable provider the user can switch to explicitly.
ZEN_FREE_PREFERENCE=(
    opencode/deepseek-v4-flash-free
    opencode/mimo-v2.5-free
    opencode/north-mini-code-free
    opencode/nemotron-3-ultra-free
    opencode/big-pickle
)

# Cache `opencode models` (a few seconds to run) for the life of the process.
_OPENCODE_MODELS_CACHE=""
_OPENCODE_MODELS_CACHED=0
opencode_available_models() {
    if [ "$_OPENCODE_MODELS_CACHED" = "0" ]; then
        command -v opencode >/dev/null 2>&1 &&
            _OPENCODE_MODELS_CACHE="$(timeout 30 opencode models 2>/dev/null || true)"
        _OPENCODE_MODELS_CACHED=1
    fi
    printf '%s\n' "$_OPENCODE_MODELS_CACHE"
}

# Print the first keyless Zen free model opencode actually exposes (honours
# PZ_OPENCODE_FREE_MODEL override), or non-zero if none is reachable.
pick_zen_free_default() {
    local models m
    models="$(opencode_available_models)"
    [ -n "$models" ] || return 1
    if [ -n "${PZ_OPENCODE_FREE_MODEL:-}" ]; then
        grep -qxF "$PZ_OPENCODE_FREE_MODEL" <<<"$models" &&
            { printf '%s\n' "$PZ_OPENCODE_FREE_MODEL"; return 0; }
    fi
    for m in "${ZEN_FREE_PREFERENCE[@]}"; do
        grep -qxF "$m" <<<"$models" && { printf '%s\n' "$m"; return 0; }
    done
    return 1
}

opencode_config_model() {
    [ -f "$OPENCODE_CONFIG" ] || return 0
    jq -r '.model // ""' "$OPENCODE_CONFIG" 2>/dev/null || true
}

# opencode has a usable model if it has cloud credentials, a local provider, or a
# non-local default model already set (e.g. a keyless Zen free model).
opencode_has_usable_model() {
    opencode_has_credentials && return 0
    [ -f "$OPENCODE_CONFIG" ] && jq -e '.provider.ollama.models | length > 0' "$OPENCODE_CONFIG" >/dev/null 2>&1 && return 0
    local m; m="$(opencode_config_model)"
    [ -n "$m" ] && [[ "$m" != ollama/* ]]
}

# Heal the default so the very first desktop/CLI chat answers instead of hanging.
# Only touches hosts without cloud credentials, and only overrides an empty or
# Ollama default (never a user's explicit cloud/proxy choice).
configure_free_default_model() {
    command -v jq >/dev/null 2>&1 || { pz_warn "jq required for free model default"; return 0; }
    opencode_has_credentials && return 0

    local model small current models
    model="$(pick_zen_free_default || true)"
    if [ -z "$model" ]; then
        pz_warn "no keyless opencode free model reachable (offline?); leaving default model unchanged"
        return 0
    fi
    models="$(opencode_available_models)"
    for small in "${ZEN_FREE_PREFERENCE[@]}"; do
        [ "$small" != "$model" ] && grep -qxF "$small" <<<"$models" && break
        small=""
    done
    [ -n "$small" ] || small="$model"

    current="$(opencode_config_model)"
    if [ -n "$current" ] && [[ "$current" != ollama/* ]]; then
        pz_info "opencode default model already set to $current; leaving as-is"
        return 0
    fi
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would set opencode default model to $model (small_model: $small)"
        return 0
    fi

    mkdir -p "$(dirname "$OPENCODE_CONFIG")"
    # shellcheck disable=SC2016 # intentional literal JSON key "$schema" in printf template
    [ -f "$OPENCODE_CONFIG" ] || printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' > "$OPENCODE_CONFIG"
    pz_backup_file "$OPENCODE_CONFIG" user >/dev/null
    local tmp; tmp="$(mktemp)"
    jq --arg model "$model" --arg small "$small" '.model = $model | .small_model = $small' \
        "$OPENCODE_CONFIG" > "$tmp" && mv "$tmp" "$OPENCODE_CONFIG"
    pz_info "opencode default model set to keyless free model: $model (fallback small_model: $small)"
}

pick_local_default() {
    local models m
    models="$(ollama_models)"
    [ -n "$models" ] || return 1
    # smallest/fastest tool-capable first, for responsiveness on CPU-only hosts
    for m in qwen2.5-coder:1.5b qwen2.5-coder:3b llama3.2:3b llama3.2:1b llama3.1:latest gemma3:latest; do
        grep -qx "$m" <<< "$models" && { printf 'ollama/%s\n' "$m"; return 0; }
    done
    printf 'ollama/%s\n' "$(head -1 <<< "$models")"
}

configure_local_model() {
    command -v jq >/dev/null 2>&1 || { pz_warn "jq required for local model config"; return 0; }
    local models; models="$(ollama_models)"
    if [ -z "$models" ]; then
        pz_warn "Ollama not reachable at $OLLAMA_URL; skipping local model."
        pz_warn "Either start Ollama (pz has models via 'ollama pull'), or authenticate a cloud provider: opencode auth login"
        return 0
    fi

    local default; default="${PZ_OPENCODE_LOCAL_MODEL:-$(pick_local_default)}"
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would add Ollama provider ($(wc -w <<< "$models") models) and default to $default"
        return 0
    fi

    local models_json tmp
    models_json="$(jq -Rn '[inputs] | map({(.): {name: (. + " (local)"), tools: true, options: {num_ctx: 8192}}}) | add' <<< "$models")"
    mkdir -p "$(dirname "$OPENCODE_CONFIG")"
    # shellcheck disable=SC2016 # intentional literal JSON key "$schema" in printf template
    [ -f "$OPENCODE_CONFIG" ] || printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' > "$OPENCODE_CONFIG"
    pz_backup_file "$OPENCODE_CONFIG" user >/dev/null
    tmp="$(mktemp)"
    # Set the default model only when the host has no cloud credentials (nothing
    # else would work) or no model is set yet; never override a user's choice.
    jq --argjson models "$models_json" --arg url "$OLLAMA_URL/v1" --arg default "$default" '
        .provider.ollama = {
            "npm": "@ai-sdk/openai-compatible",
            "name": "Ollama (local)",
            "options": {"baseURL": $url, "apiKey": "ollama"},
            "models": $models
        }
        | (if ((.model // "") == "") then .model = $default else . end)
    ' "$OPENCODE_CONFIG" > "$tmp" && mv "$tmp" "$OPENCODE_CONFIG"

    pz_info "configured opencode Ollama provider; default model: $(jq -r '.model // "unset"' "$OPENCODE_CONFIG")"
    pz_info "Local models are key-free but CPU-slow on the Deck APU; first reply can take ~1-2 min. For speed: GPU/ROCm ollama, a smaller model, or a cloud key (opencode auth login)."
    if [ -f "$OPENCODE_CONFIG" ] && jq -e '(.plugin // []) | any(startswith("oh-my-openagent"))' "$OPENCODE_CONFIG" >/dev/null 2>&1; then
        pz_warn "OMO is enabled: its Sisyphus 'ultraworker' agent is too heavy for local CPU models. For a responsive local desktop: linux/pz ai omo disable"
    fi
}

# Default PhaseZero: "Aceitar permissões automaticamente" ligado e persistente.
# O host tinha permission.bash."*"=ask, o que força prompt e deixa o toggle
# da UI em autoApprove:false (default.dat). Substituímos o objeto inteiro.
configure_auto_permissions() {
    command -v jq >/dev/null 2>&1 || { pz_warn "jq required for OpenCode auto permissions"; return 0; }
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would set OpenCode permission=* allow and desktop autoApprove=true"
        return 0
    fi
    mkdir -p "$(dirname "$OPENCODE_CONFIG")"
    # shellcheck disable=SC2016
    [ -f "$OPENCODE_CONFIG" ] || printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' > "$OPENCODE_CONFIG"
    pz_backup_file "$OPENCODE_CONFIG" user >/dev/null
    local tmp mode
    mode="$(stat -c '%a' "$OPENCODE_CONFIG" 2>/dev/null || echo 600)"
    tmp="$(mktemp)"
    jq '.permission = {
            "*": "allow",
            "bash": "allow",
            "edit": "allow",
            "webfetch": "allow",
            "websearch": "allow",
            "external_directory": "allow"
        }' "$OPENCODE_CONFIG" > "$tmp" && mv "$tmp" "$OPENCODE_CONFIG"
    chmod "$mode" "$OPENCODE_CONFIG" 2>/dev/null || chmod 600 "$OPENCODE_CONFIG"
    pz_info "OpenCode permission set to allow (auto-accept)"

    if [ -f "$OPENCODE_DESKTOP_SETTINGS" ]; then
        pz_backup_file "$OPENCODE_DESKTOP_SETTINGS" user >/dev/null
        python3 - "$OPENCODE_DESKTOP_SETTINGS" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
raw = data.get("settings.v3")
if isinstance(raw, str):
    settings = json.loads(raw)
else:
    settings = raw if isinstance(raw, dict) else {}
perms = settings.setdefault("permissions", {})
if not isinstance(perms, dict):
    perms = {}
    settings["permissions"] = perms
perms["autoApprove"] = True
data["settings.v3"] = json.dumps(settings, separators=(",", ":"))
path.write_text(json.dumps(data, indent="\t") + "\n", encoding="utf-8")
PY
        pz_info "OpenCode desktop autoApprove=true ($OPENCODE_DESKTOP_SETTINGS)"
        pz_info "Reabra o OpenCode Desktop para a opção 'Aceitar permissões automaticamente' aparecer ligada"
    fi
}

setup_templates() {
    mkdir -p "$(dirname "$OPENCODE_CONFIG")"
    if [ ! -f "$OPENCODE_CONFIG" ]; then
        pz_info "creating default OpenCode config"
        pz_write_managed_file "$OPENCODE_CONFIG" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {},
  "permission": {
    "*": "allow",
    "bash": "allow",
    "edit": "allow",
    "webfetch": "allow",
    "websearch": "allow",
    "external_directory": "allow"
  }
}
EOF
    fi

    local template_dir="$PZ_ROOT/linux/ai/templates" tmpl name target
    if [ -d "$template_dir" ]; then
        for tmpl in "$template_dir"/*; do
            [ -f "$tmpl" ] || continue
            name=$(basename "$tmpl")
            target="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/${name}"
            if [ ! -f "$target" ]; then
                cp "$tmpl" "$target"
                pz_info "installed template: $name"
            fi
        done
    fi
}

case "${1:-setup}" in
    setup)
        pz_check_deps npm jq
        setup_templates
        # Orchestrated CLI install: when a desktop is present, pin the CLI to
        # its exact version so the shared DB never skews; otherwise install/keep
        # a working CLI.
        opencode_sync
        ensure_clipboard_stack
        write_deck_launcher
        bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync opencode >/dev/null || pz_warn "OpenCode MCP sync failed"
        # Keyless host: wire Ollama as an offline provider (when present) but make
        # the DEFAULT a fast keyless Zen free model, so the first chat answers
        # instead of hanging on slow local inference ("Interrompido").
        if ! opencode_has_credentials; then
            [ -n "$(ollama_models)" ] && configure_local_model
            configure_free_default_model
        fi
        configure_auto_permissions
        pz_info "OpenCode setup complete. Config at $OPENCODE_CONFIG"
        ;;
    permissions-auto|auto-permissions)
        configure_auto_permissions
        ;;
    sync|align)
        # Re-pin the CLI to the opencode-desktop version (idempotent).
        opencode_sync
        ;;
    local-model|ollama)
        configure_local_model
        ;;
    free-model|free|zen)
        # Heal the default to a fast keyless opencode Zen free model (fixes the
        # "Interrompido" caused by a slow local Ollama default).
        [ -n "$(ollama_models)" ] && ! opencode_has_credentials && configure_local_model
        configure_free_default_model
        ;;
    version-status|version)
        opencode_version_status
        ;;
    install-hook)
        install_sync_hook
        ;;
    remove-hook)
        remove_sync_hook
        ;;
    desktop-integration)
        # launcher + desktop entry only; no package installs, no npm, no MCP sync
        write_deck_launcher
        pz_info "OpenCode desktop integration written (launcher: $LOCAL_BIN/opencode-deck)"
        ;;
    dry-run)
        print_dry_run
        ;;
    *)
        pz_error "usage: setup-opencode.sh (setup|sync|version-status|local-model|free-model|install-hook|remove-hook|desktop-integration|permissions-auto|dry-run)"
        exit 1
        ;;
esac
