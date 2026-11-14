#!/usr/bin/env bash
# desktop-apps.sh - trusted Claude/Qwen Desktop install and Codex Desktop update repair.
set -euo pipefail

PZ_ROOT="${PZ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$PZ_ROOT/linux/lib/common.sh"

CLAUDE_REPO_BASE="${PZ_CLAUDE_REPO_BASE:-https://downloads.claude.ai/claude-desktop/apt/stable}"
CLAUDE_KEY_URL="${PZ_CLAUDE_KEY_URL:-https://downloads.claude.ai/claude-desktop/key.asc}"
CLAUDE_EXPECTED_FPR="${PZ_CLAUDE_EXPECTED_FPR:-31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE}"
CLAUDE_ROOT="${PZ_CLAUDE_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/phasezero/claude-desktop}"
CLAUDE_CACHE="${PZ_CLAUDE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/phasezero/claude-desktop}"
CLAUDE_STATE="$CLAUDE_ROOT/state.json"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CODEX_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/codex-update-manager/state.json"
CODEX_WORKSPACES="${PZ_CODEX_WORKSPACES:-${CODEX_WORKSPACES:-${XDG_CACHE_HOME:-$HOME/.cache}/codex-update-manager/workspaces}}"
CODEX_SEED="${PZ_CODEX_UPDATE_BUILDER:-/opt/codex-desktop/update-builder}"
CODEX_REPAIR_STATE="$PZ_STATE/codex-desktop-repair.json"
QWEN_API_URL="${PZ_QWEN_API_URL:-https://api.github.com/repos/QwenLM/qwen-code/releases/tags/desktop-latest}"
QWEN_RELEASE_BASE="https://github.com/QwenLM/qwen-code/releases/download/"
QWEN_ROOT="${PZ_QWEN_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/phasezero/qwen-code-desktop}"
QWEN_CACHE="${PZ_QWEN_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/phasezero/qwen-code-desktop}"
QWEN_STATE="$QWEN_ROOT/state.json"
QWEN_CONFIG_DIR="${CRAFT_CONFIG_DIR:-$HOME/.craft-agent}"

CLAUDE_VERSION=""
CLAUDE_FILENAME=""
CLAUDE_SIZE=""
CLAUDE_SHA256=""
CLAUDE_ARCH=""

usage() {
    cat <<'EOF'
Usage: desktop-apps.sh <action>

Actions:
  status                 Print Claude/Qwen/Codex desktop status JSON
  install-claude         Install/update official Claude Desktop for current user
  update-claude          Update Claude Desktop when newer
  check-claude           Compare installed Claude Desktop with signed repo (JSON, no changes)
  launch-claude          Launch installed Claude Desktop
  test-claude            Run binary/linkage and live launch checks
  install-qwen           Install/update official Qwen Code Desktop AppImage
  update-qwen            Alias for install-qwen
  launch-qwen            Launch installed Qwen Code Desktop
  codex-guard-once       Repair existing Codex update workspaces
  codex-guard-watch      Watch and repair new Codex update workspaces
  repair-codex           Rebuild failed Codex Desktop candidate
  install-codex-ready    Install rebuilt Codex package through PolicyKit
  apply-codex           Install a ready Codex Desktop update or repair a failed candidate
  check-codex            Run guarded Codex update check
  install-services       Enable Codex guard and periodic desktop updates
  update                 Update Claude and check Codex
  disable-updates        Stop the periodic desktop app update timer
  repair                 Repair desktop apps and services
EOF
}

bool_json() {
    "$@" >/dev/null 2>&1 && printf true || printf false
}

claude_arch() {
    case "$(uname -m)" in
        x86_64) printf amd64 ;;
        aarch64|arm64) printf arm64 ;;
        *) pz_error "Claude Desktop unsupported architecture: $(uname -m)"; return 1 ;;
    esac
}

file_sha256() {
    sha256sum "$1" | awk '{print $1}'
}

desktop_download_guard() {
    local size="$1" url="$2" digest="$3" destination="$4" limit="${PZ_DESKTOP_DOWNLOAD_MAX_BYTES:-0}"
    if [[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -gt 0 ] && [ "$size" -gt "$limit" ]; then
        pz_error "download manual necessário: $size bytes"
        printf 'Origem: %s\nSHA-256: %s\nDestino: %s\n' "$url" "$digest" "$destination"
        return 1
    fi
}

download_atomic() {
    local url="$1" target="$2" tmp
    tmp="${target}.part.$$"
    mkdir -p "$(dirname "$target")"
    rm -f "$tmp"
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "$url" -o "$tmp"
    mv -f "$tmp" "$target"
}

verify_size_hash() {
    local file="$1" expected_size="$2" expected_hash="$3"
    local actual_size actual_hash
    actual_size="$(stat -c %s "$file")"
    [ "$actual_size" = "$expected_size" ] || {
        pz_error "size mismatch for $file: expected $expected_size, got $actual_size"
        return 1
    }
    actual_hash="$(file_sha256 "$file")"
    [ "${actual_hash,,}" = "${expected_hash,,}" ] || {
        pz_error "SHA-256 mismatch for $file"
        return 1
    }
}

read_github_appimage_metadata() {
    local api_url="$1" expected_name="$2" json asset digest url size
    json="$(curl -fsSL --retry 3 --connect-timeout 15 \
        -H 'Accept: application/vnd.github+json' "$api_url")"
    asset="$(jq -ce --arg name "$expected_name" \
        '.assets[] | select(.name == $name and .state == "uploaded")' <<< "$json")" || {
        pz_error "official GitHub asset missing: $expected_name"
        return 1
    }
    url="$(jq -r '.browser_download_url' <<< "$asset")"
    size="$(jq -r '.size' <<< "$asset")"
    digest="$(jq -r '.digest // empty' <<< "$asset")"
    [[ "$url" == "$QWEN_RELEASE_BASE"*"/$expected_name" ]] || {
        pz_error "unexpected Qwen release URL: $url"
        return 1
    }
    [[ "$digest" =~ ^sha256:([0-9a-fA-F]{64})$ ]] || {
        pz_error "Qwen release has no trusted SHA-256 digest"
        return 1
    }
    jq -cn \
        --arg version "$(jq -r '.name // .tag_name' <<< "$json")" \
        --arg tag "$(jq -r '.tag_name' <<< "$json")" \
        --arg publishedAt "$(jq -r '.published_at // empty' <<< "$json")" \
        --arg url "$url" --arg size "$size" --arg sha256 "${BASH_REMATCH[1],,}" \
        '{version:$version,tag:$tag,publishedAt:$publishedAt,url:$url,size:($size|tonumber),sha256:$sha256}'
}

write_qwen_launcher() {
    mkdir -p "$LOCAL_BIN" "$QWEN_CONFIG_DIR"
    chmod 0700 "$QWEN_CONFIG_DIR"
    pz_write_managed_file "$LOCAL_BIN/qwen-code-desktop" <<EOF
#!/usr/bin/env bash
set -euo pipefail
appimage="$QWEN_ROOT/current/Qwen-Code-Desktop-x86_64.AppImage"
if [ ! -x "\$appimage" ]; then
    echo "Qwen Code Desktop not installed. Run: $PZ_ROOT/linux/pz ai desktop install-qwen" >&2
    exit 1
fi
export CRAFT_CONFIG_DIR="\${CRAFT_CONFIG_DIR:-$QWEN_CONFIG_DIR}"
export ELECTRON_OZONE_PLATFORM_HINT="\${ELECTRON_OZONE_PLATFORM_HINT:-auto}"
if [ ! -e /dev/fuse ]; then
    export APPIMAGE_EXTRACT_AND_RUN=1
fi
exec "\$appimage" "\$@"
EOF
    chmod 0755 "$LOCAL_BIN/qwen-code-desktop"
}

write_qwen_desktop_entry() {
    mkdir -p "$APPLICATIONS_DIR"
    pz_desktop_write_entry "$APPLICATIONS_DIR/qwen-code-desktop.desktop" web.ai <<EOF
[Desktop Entry]
Name=Qwen Code
Comment=Local-first desktop coding agent
GenericName=AI Coding Agent
Keywords=AI;Code;Agent;Qwen;LLM;
Exec=$LOCAL_BIN/qwen-code-desktop %U
Icon=applications-development
Type=Application
StartupNotify=true
StartupWMClass=Qwen Code
Categories=Development;Utility;
EOF
    chmod 0644 "$APPLICATIONS_DIR/qwen-code-desktop.desktop"
}

install_qwen() {
    pz_check_deps curl jq sha256sum
    [ "$(uname -m)" = "x86_64" ] || {
        pz_error "Qwen Code Desktop official AppImage supports x86_64 only"
        return 1
    }
    local metadata version url size sha256 cache stage final link
    metadata="$(read_github_appimage_metadata "$QWEN_API_URL" 'Qwen-Code-Desktop-x86_64.AppImage')"
    version="$(jq -r '.version' <<< "$metadata")"
    url="$(jq -r '.url' <<< "$metadata")"
    size="$(jq -r '.size' <<< "$metadata")"
    sha256="$(jq -r '.sha256' <<< "$metadata")"
    cache="$QWEN_CACHE/Qwen-Code-Desktop-x86_64.AppImage"
    mkdir -p "$QWEN_CACHE" "$QWEN_ROOT/versions"
    if [ -x "$QWEN_ROOT/current/Qwen-Code-Desktop-x86_64.AppImage" ] &&
        [ "$(jq -r '.sha256 // empty' "$QWEN_STATE" 2>/dev/null || true)" = "$sha256" ]; then
        write_qwen_launcher
        write_qwen_desktop_entry
        pz_info "Qwen Code Desktop already current: $version"
        return 0
    fi
    if [ -f "$cache" ] && ! verify_size_hash "$cache" "$size" "$sha256"; then
        pz_warn "discarding invalid cached Qwen Code Desktop AppImage"
        rm -f "$cache"
    fi
    if [ ! -f "$cache" ]; then
        desktop_download_guard "$size" "$url" "$sha256" "$cache" || return
        pz_info "downloading official Qwen Code Desktop: $version"
        download_atomic "$url" "$cache"
    fi
    verify_size_hash "$cache" "$size" "$sha256"
    stage="$QWEN_ROOT/versions/.${sha256:0:16}.stage.$$"
    final="$QWEN_ROOT/versions/${sha256:0:16}"
    rm -rf "$stage"
    mkdir -p "$stage"
    install -m 0755 "$cache" "$stage/Qwen-Code-Desktop-x86_64.AppImage"
    printf '%s\n' "$version" > "$stage/version"
    jq --arg installedAt "$(date -Iseconds)" '. + {installedAt:$installedAt,source:"official-qwen-github-release",userScoped:true}' \
        <<< "$metadata" > "$stage/manifest.json"
    rm -rf "$final"
    mv "$stage" "$final"
    link="$QWEN_ROOT/.current.$$"
    ln -s "versions/${sha256:0:16}" "$link"
    mv -Tf "$link" "$QWEN_ROOT/current"
    cp "$final/manifest.json" "$QWEN_STATE"
    chmod 0600 "$QWEN_STATE"
    write_qwen_launcher
    write_qwen_desktop_entry
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APPLICATIONS_DIR" >/dev/null 2>&1 || true
    fi
    pz_info "Qwen Code Desktop installed: $version"
}

launch_qwen() {
    [ -x "$LOCAL_BIN/qwen-code-desktop" ] || {
        pz_error "Qwen Code Desktop launcher missing"
        return 1
    }
    nohup "$LOCAL_BIN/qwen-code-desktop" "$@" >"$PZ_STATE/qwen-code-desktop.log" 2>&1 &
    disown || true
    pz_info "Qwen Code Desktop launched"
}

read_claude_metadata() {
    pz_check_deps curl gpg gpgv awk sha256sum sort
    local work="$1" key keyring inrelease release
    local packages_rel packages_file package_size package_hash fingerprint record
    key="$work/key.asc"
    keyring="$work/keyring.gpg"
    inrelease="$work/InRelease"
    release="$work/Release"

    CLAUDE_ARCH="$(claude_arch)"
    packages_rel="main/binary-${CLAUDE_ARCH}/Packages"
    packages_file="$work/Packages"

    download_atomic "$CLAUDE_KEY_URL" "$key"
    fingerprint="$(
        gpg --batch --show-keys --with-colons "$key" 2>/dev/null |
            awk -F: '$1 == "fpr" {print toupper($10); exit}'
    )"
    [ "$fingerprint" = "$CLAUDE_EXPECTED_FPR" ] || {
        pz_error "Anthropic signing key fingerprint mismatch: $fingerprint"
        return 1
    }

    gpg --batch --yes --dearmor --output "$keyring" "$key"
    download_atomic "$CLAUDE_REPO_BASE/dists/stable/InRelease" "$inrelease"
    gpgv --keyring "$keyring" --output "$release" "$inrelease" >/dev/null 2>&1 || {
        pz_error "Anthropic repository signature verification failed"
        return 1
    }

    package_hash="$(
        awk -v target="$packages_rel" '
            /^SHA256:/ {in_sha=1; next}
            in_sha && /^[A-Z][A-Za-z0-9-]*:/ {exit}
            in_sha && $3 == target {print $1; exit}
        ' "$release"
    )"
    package_size="$(
        awk -v target="$packages_rel" '
            /^SHA256:/ {in_sha=1; next}
            in_sha && /^[A-Z][A-Za-z0-9-]*:/ {exit}
            in_sha && $3 == target {print $2; exit}
        ' "$release"
    )"
    if [ -z "$package_hash" ] || [ -z "$package_size" ]; then
        pz_error "signed Packages digest missing for $packages_rel"
        return 1
    fi

    download_atomic "$CLAUDE_REPO_BASE/dists/stable/$packages_rel" "$packages_file"
    verify_size_hash "$packages_file" "$package_size" "$package_hash"

    record="$(
        awk -v arch="$CLAUDE_ARCH" '
            BEGIN {RS=""; FS="\n"}
            {
                pkg=""; ver=""; found_arch=""; filename=""; size=""; sha=""
                for (i=1; i<=NF; i++) {
                    if ($i ~ /^Package: /) {pkg=substr($i,10)}
                    else if ($i ~ /^Version: /) {ver=substr($i,10)}
                    else if ($i ~ /^Architecture: /) {found_arch=substr($i,15)}
                    else if ($i ~ /^Filename: /) {filename=substr($i,11)}
                    else if ($i ~ /^Size: /) {size=substr($i,7)}
                    else if ($i ~ /^SHA256: /) {sha=substr($i,9)}
                }
                if (pkg == "claude-desktop" && found_arch == arch && ver && filename && size && sha) {
                    print ver "\t" filename "\t" size "\t" sha
                }
            }
        ' "$packages_file" | sort -t $'\t' -k1,1V | tail -1
    )"
    [ -n "$record" ] || {
        pz_error "claude-desktop package not found for $CLAUDE_ARCH"
        return 1
    }
    IFS=$'\t' read -r CLAUDE_VERSION CLAUDE_FILENAME CLAUDE_SIZE CLAUDE_SHA256 <<< "$record"
}

installed_claude_version() {
    if [ -L "$CLAUDE_ROOT/current" ] && [ -f "$CLAUDE_ROOT/current/version" ]; then
        cat "$CLAUDE_ROOT/current/version"
    elif [ -f "$CLAUDE_STATE" ]; then
        jq -r '.version // empty' "$CLAUDE_STATE" 2>/dev/null
    fi
}

claude_launcher_managed() {
    [ -f "$LOCAL_BIN/claude-desktop" ] && [ ! -L "$LOCAL_BIN/claude-desktop" ] &&
        grep -q "$CLAUDE_ROOT/current/app/claude-desktop" "$LOCAL_BIN/claude-desktop" 2>/dev/null
}

# A launcher installed by something else (e.g. an unofficial AppImage symlink)
# is recorded before it is replaced, so it can be restored by hand.
record_foreign_claude_launcher() {
    local launcher="$LOCAL_BIN/claude-desktop" record="$CLAUDE_ROOT/replaced-launcher.json"
    { [ -e "$launcher" ] || [ -L "$launcher" ]; } || return 0
    claude_launcher_managed && return 0
    [ -f "$record" ] && return 0
    mkdir -p "$CLAUDE_ROOT"
    jq -n --arg path "$launcher" --arg target "$(readlink -f "$launcher" 2>/dev/null || true)" \
        --argjson symlink "$([ -L "$launcher" ] && echo true || echo false)" \
        --arg at "$(date -Iseconds)" \
        '{path:$path,symlink:$symlink,target:$target,replacedAt:$at,restore:"ln -sfn TARGET PATH"}' > "$record"
    chmod 0600 "$record"
    pz_warn "replacing non-PhaseZero Claude launcher ($launcher -> $(readlink -f "$launcher" 2>/dev/null || echo file)); recorded in $record, original file kept"
}

claude_running_pids() {
    pgrep -f -- "$CLAUDE_ROOT/versions/[^ ]*/app/claude-desktop( |$)" 2>/dev/null || true
}

check_claude() {
    pz_check_deps curl gpg gpgv jq sha256sum
    local installed available=false
    CLAUDE_CHECK_WORK="$(mktemp -d)"
    trap 'rm -rf -- "${CLAUDE_CHECK_WORK:?}"' EXIT
    read_claude_metadata "$CLAUDE_CHECK_WORK" >&2
    installed="$(installed_claude_version || true)"
    if [ -z "$installed" ] || [ "$(printf '%s\n%s\n' "$installed" "$CLAUDE_VERSION" | sort -V | tail -1)" != "$installed" ]; then
        available=true
    fi
    jq -n --arg installed "$installed" --arg latest "$CLAUDE_VERSION" --argjson available "$available" \
        --argjson running "$([ -n "$(claude_running_pids)" ] && echo true || echo false)" \
        '{installed:$installed,latest:$latest,available:$available,running:$running,source:"official-anthropic-apt",signatureVerified:true}'
}

write_claude_launcher() {
    mkdir -p "$LOCAL_BIN"
    record_foreign_claude_launcher
    pz_write_managed_file "$LOCAL_BIN/claude-desktop" <<EOF
#!/usr/bin/env bash
# PhaseZero managed: claude-desktop
set -euo pipefail
binary="$CLAUDE_ROOT/current/app/claude-desktop"
if [ ! -x "\$binary" ]; then
    echo "Claude Desktop not installed. Run: $PZ_ROOT/linux/pz ai desktop install-claude" >&2
    exit 1
fi
export ELECTRON_OZONE_PLATFORM_HINT="\${ELECTRON_OZONE_PLATFORM_HINT:-auto}"
exec "\$binary" "\$@"
EOF
    chmod 0755 "$LOCAL_BIN/claude-desktop"
}

write_claude_desktop_entry() {
    mkdir -p "$APPLICATIONS_DIR"
    pz_desktop_write_entry "$APPLICATIONS_DIR/claude-desktop.desktop" web.ai <<EOF
[Desktop Entry]
Name=Claude
Comment=Desktop application for Claude.ai
GenericName=AI Assistant
Keywords=AI;Chat;Assistant;Claude;Code;LLM;
Exec=$LOCAL_BIN/claude-desktop %U
Icon=claude-desktop
Type=Application
StartupNotify=true
StartupWMClass=claude-desktop
SingleMainWindow=true
Categories=Utility;Development;
MimeType=x-scheme-handler/claude;
Actions=NewChat;NewCode;

[Desktop Action NewChat]
Name=New chat
Exec=$LOCAL_BIN/claude-desktop claude://claude.ai/new

[Desktop Action NewCode]
Name=New Claude Code session
Exec=$LOCAL_BIN/claude-desktop claude://code/new
EOF
    chmod 0644 "$APPLICATIONS_DIR/claude-desktop.desktop"
}

install_claude_icons() {
    local extracted="$1" source size
    for size in 16 32 48 128 256; do
        source="$extracted/usr/share/icons/hicolor/${size}x${size}/apps/claude-desktop.png"
        [ -f "$source" ] || continue
        mkdir -p "$ICONS_DIR/${size}x${size}/apps"
        install -m 0644 "$source" "$ICONS_DIR/${size}x${size}/apps/claude-desktop.png"
    done
}

prune_claude_versions() {
    local keep=2 version_dir current_target
    [ -d "$CLAUDE_ROOT/versions" ] || return 0
    current_target="$(readlink -f "$CLAUDE_ROOT/current" 2>/dev/null || true)"
    while IFS= read -r version_dir; do
        [ -n "$version_dir" ] || continue
        [ "$(readlink -f "$version_dir")" = "$current_target" ] && continue
        rm -rf "$version_dir"
    done < <(
        find "$CLAUDE_ROOT/versions" -mindepth 1 -maxdepth 1 -type d ! -name '.*.stage.*' -printf '%p\n' |
            sort -V | head -n "-$keep" 2>/dev/null || true
    )
}

install_claude() {
    pz_check_deps bsdtar curl gpg gpgv jq sha256sum
    local work deb ar_dir extracted stage final current_link installed
    work="$(mktemp -d)"
    trap 'rm -rf -- "${work:?}"' EXIT
    read_claude_metadata "$work"
    installed="$(installed_claude_version || true)"
    if [ "$installed" = "$CLAUDE_VERSION" ] &&
        [ -x "$CLAUDE_ROOT/current/app/claude-desktop" ] &&
        [ "$(jq -r '.sha256 // empty' "$CLAUDE_ROOT/current/manifest.json" 2>/dev/null || true)" = "$CLAUDE_SHA256" ]; then
        pz_info "Claude Desktop already current: $CLAUDE_VERSION"
        write_claude_launcher
        write_claude_desktop_entry
        rm -rf "$work"
        trap - EXIT
        return 0
    fi

    deb="$CLAUDE_CACHE/$(basename "$CLAUDE_FILENAME")"
    if [ -f "$deb" ] && ! verify_size_hash "$deb" "$CLAUDE_SIZE" "$CLAUDE_SHA256"; then
        pz_warn "discarding invalid cached Claude package"
        rm -f "$deb"
    fi
    if [ ! -f "$deb" ]; then
        desktop_download_guard "$CLAUDE_SIZE" "$CLAUDE_REPO_BASE/$CLAUDE_FILENAME" "$CLAUDE_SHA256" "$deb" || return
        pz_info "downloading official Claude Desktop $CLAUDE_VERSION"
        download_atomic "$CLAUDE_REPO_BASE/$CLAUDE_FILENAME" "$deb"
        verify_size_hash "$deb" "$CLAUDE_SIZE" "$CLAUDE_SHA256"
    fi

    ar_dir="$work/ar"
    extracted="$work/extracted"
    mkdir -p "$ar_dir" "$extracted" "$CLAUDE_ROOT/versions"
    bsdtar -xf "$deb" -C "$ar_dir"
    local data_archive
    data_archive="$(find "$ar_dir" -maxdepth 1 -name 'data.tar.*' -type f -print -quit)"
    [ -n "$data_archive" ] || {
        pz_error "official Claude package has no data archive"
        return 1
    }
    bsdtar -xf "$data_archive" -C "$extracted"
    [ -x "$extracted/usr/lib/claude-desktop/claude-desktop" ] || {
        pz_error "official Claude package has no executable"
        return 1
    }
    if ldd "$extracted/usr/lib/claude-desktop/claude-desktop" | grep -q 'not found'; then
        pz_error "Claude Desktop has unresolved host libraries"
        ldd "$extracted/usr/lib/claude-desktop/claude-desktop" | grep 'not found' >&2
        return 1
    fi

    stage="$CLAUDE_ROOT/versions/.${CLAUDE_VERSION}.stage.$$"
    final="$CLAUDE_ROOT/versions/$CLAUDE_VERSION"
    rm -rf "$stage"
    mkdir -p "$stage"
    cp -a "$extracted/usr/lib/claude-desktop" "$stage/app"
    printf '%s\n' "$CLAUDE_VERSION" > "$stage/version"
    jq -n \
        --arg version "$CLAUDE_VERSION" \
        --arg source "$CLAUDE_REPO_BASE/$CLAUDE_FILENAME" \
        --arg sha256 "$CLAUDE_SHA256" \
        --arg fingerprint "$CLAUDE_EXPECTED_FPR" \
        --arg installedAt "$(date -Iseconds)" \
        '{version:$version,source:$source,sha256:$sha256,signingKeyFingerprint:$fingerprint,installedAt:$installedAt}' \
        > "$stage/manifest.json"
    rm -rf "$final"
    mv "$stage" "$final"
    current_link="$CLAUDE_ROOT/.current.$$"
    ln -s "versions/$CLAUDE_VERSION" "$current_link"
    mv -Tf "$current_link" "$CLAUDE_ROOT/current"
    cp "$final/manifest.json" "$CLAUDE_STATE"

    write_claude_launcher
    write_claude_desktop_entry
    install_claude_icons "$extracted"
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APPLICATIONS_DIR" >/dev/null 2>&1 || true
    fi
    if command -v xdg-mime >/dev/null 2>&1; then
        xdg-mime default claude-desktop.desktop x-scheme-handler/claude >/dev/null 2>&1 || true
    fi
    bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync claude-desktop >/dev/null ||
        pz_warn "Claude Desktop MCP sync failed"
    prune_claude_versions
    rm -rf "$work"
    trap - EXIT
    pz_info "Claude Desktop installed: $CLAUDE_VERSION"
    if [ -n "$(claude_running_pids)" ]; then
        pz_warn "Claude Desktop is still running the previous version; close and reopen it to use $CLAUDE_VERSION"
        command -v notify-send >/dev/null 2>&1 &&
            notify-send --app-name=PhaseZero "Claude Desktop atualizado" \
                "Versão $CLAUDE_VERSION instalada. Feche e abra o Claude para usar." >/dev/null 2>&1 || true
    fi
}

launch_claude() {
    [ -x "$LOCAL_BIN/claude-desktop" ] || {
        pz_error "Claude Desktop launcher missing"
        return 1
    }
    nohup "$LOCAL_BIN/claude-desktop" "$@" >"$PZ_STATE/claude-desktop.log" 2>&1 &
    disown || true
    pz_info "Claude Desktop launched"
}

test_claude() {
    local binary="$CLAUDE_ROOT/current/app/claude-desktop" pid
    [ -x "$binary" ] || {
        pz_error "Claude Desktop binary missing"
        return 1
    }
    if ldd "$binary" | grep -q 'not found'; then
        ldd "$binary" | grep 'not found' >&2
        pz_error "Claude Desktop linkage failed"
        return 1
    fi
    launch_claude
    pid="$!"
    sleep 8
    if kill -0 "$pid" 2>/dev/null || pgrep -f "$binary" >/dev/null 2>&1; then
        pz_info "Claude Desktop live launch test passed"
    else
        pz_error "Claude Desktop exited during launch test; see $PZ_STATE/claude-desktop.log"
        tail -n 40 "$PZ_STATE/claude-desktop.log" >&2 || true
        return 1
    fi
}

patch_codex_builder() {
    local builder="$1" script tmp
    script="$builder/scripts/build-pacman.sh"
    [ -f "$script" ] || return 0
    if grep -q 'PHASEZERO_PKGEXT_COMPAT' "$script"; then
        sed -i 's/zstd -q -T0 --rm/zstd -q -f -T0 --rm/' "$script"
        return 0
    fi
    bash -n "$script" 2>/dev/null || return 0
    tmp="${script}.phasezero.$$"
    awk '
        /local pkg_file=""/ && !done {
            print "\t# PHASEZERO_PKGEXT_COMPAT: normalize hosts configured for uncompressed pacman packages."
            print "\tlocal plain_pkg=\"\""
            print "\tplain_pkg=\"$(find \"$DIST_DIR\" -name \"${PACKAGE_NAME}-${PACMAN_PKGVER}-*.pkg.tar\" -type f -print -quit 2>/dev/null || true)\""
            print "\tif [ -f \"$plain_pkg\" ]; then"
            print "\t\tcommand -v zstd >/dev/null 2>&1 || error \"zstd is required to normalize $plain_pkg\""
            print "\t\tzstd -q -f -T0 --rm \"$plain_pkg\""
            print "\tfi"
            done=1
        }
        {print}
    ' "$script" > "$tmp"
    chmod --reference="$script" "$tmp"
    mv "$tmp" "$script"
}

repair_codex_workspace() {
    local workspace="$1" builder
    builder="$workspace/builder"
    [ -d "$builder" ] || return 0
    if [ -d "$CODEX_SEED" ]; then
        rsync -a --ignore-existing "$CODEX_SEED/" "$builder/"
    elif [ ! -f "$builder/assets/codex-linux.png" ] &&
        [ -f /usr/share/icons/hicolor/256x256/apps/codex-desktop.png ]; then
        mkdir -p "$builder/assets"
        install -m 0644 /usr/share/icons/hicolor/256x256/apps/codex-desktop.png \
            "$builder/assets/codex-linux.png"
    fi
    patch_codex_builder "$builder"
}

codex_guard_once() {
    pz_check_deps rsync
    local workspace repaired=0
    [ -d "$CODEX_WORKSPACES" ] || return 0
    for workspace in "$CODEX_WORKSPACES"/*; do
        [ -d "$workspace/builder" ] || continue
        repair_codex_workspace "$workspace"
        repaired=$((repaired + 1))
    done
    pz_info "Codex update workspaces guarded: $repaired"
}

codex_guard_watch() {
    pz_check_deps rsync
    local workspace builder
    while true; do
        if [ -d "$CODEX_WORKSPACES" ]; then
            for workspace in "$CODEX_WORKSPACES"/*; do
                builder="$workspace/builder"
                [ -d "$builder" ] || continue
                if [ ! -f "$builder/assets/codex-linux.png" ] ||
                    [ ! -d "$builder/record-replay-linux" ] ||
                    ! grep -q 'PHASEZERO_PKGEXT_COMPAT' "$builder/scripts/build-pacman.sh" 2>/dev/null; then
                    repair_codex_workspace "$workspace"
                fi
            done
        fi
        sleep 0.25
    done
}

codex_failed_workspace() {
    [ -f "$CODEX_STATE" ] || return 1
    jq -r 'select(.status == "failed") | .artifact_paths.workspace_dir // empty' "$CODEX_STATE"
}

codex_candidate_version() {
    [ -f "$CODEX_STATE" ] || return 1
    jq -r '.candidate_version // empty' "$CODEX_STATE"
}

repair_codex() {
    pz_check_deps jq rsync zstd pacman
    local workspace version builder dist updater_copy package rc=0
    workspace="$(codex_failed_workspace || true)"
    version="$(codex_candidate_version || true)"
    if [ -z "$workspace" ] || [ ! -d "$workspace/builder" ] || [ ! -d "$workspace/codex-app" ]; then
        pz_error "no failed Codex Desktop workspace available"
        return 1
    fi
    [ -n "$version" ] || {
        pz_error "Codex candidate version missing"
        return 1
    }
    repair_codex_workspace "$workspace"
    builder="$workspace/builder"
    dist="$workspace/dist"
    mkdir -p "$dist"
    updater_copy="$workspace/codex-update-manager-phasezero"
    install -m 0755 /usr/bin/codex-update-manager "$updater_copy"
    touch "$updater_copy"
    pz_info "rebuilding Codex Desktop candidate: $version"
    env \
        APP_DIR_OVERRIDE="$workspace/codex-app" \
        DIST_DIR_OVERRIDE="$dist" \
        PACKAGE_VERSION="$version" \
        PACKAGE_WITH_UPDATER=1 \
        UPDATER_BINARY_SOURCE="$updater_copy" \
        MAX_BUILD_THREADS="${PZ_CODEX_BUILD_THREADS:-4}" \
        "$builder/scripts/build-pacman.sh" || rc=$?
    package="$(
        find "$dist" -maxdepth 1 -type f \
            \( -name "codex-desktop-${version}-*.pkg.tar.zst" -o \
               -name "codex-desktop-${version}-*.pkg.tar.xz" \) \
            -print -quit
    )"
    if [ -z "$package" ]; then
        pz_error "Codex rebuild produced no installable package (builder rc=$rc)"
        return 1
    fi
    pacman -Qip "$package" >/dev/null
    jq -n \
        --arg version "$version" \
        --arg package "$package" \
        --arg sha256 "$(file_sha256 "$package")" \
        --arg repairedAt "$(date -Iseconds)" \
        '{version:$version,package:$package,sha256:$sha256,repairedAt:$repairedAt,ready:true}' \
        > "$CODEX_REPAIR_STATE"
    pz_info "Codex Desktop package ready: $package"
}

install_codex_ready() {
    pz_check_deps jq
    local package expected actual
    [ -f "$CODEX_REPAIR_STATE" ] || {
        pz_error "no PhaseZero-rebuilt Codex package"
        return 1
    }
    package="$(jq -r '.package // empty' "$CODEX_REPAIR_STATE")"
    expected="$(jq -r '.sha256 // empty' "$CODEX_REPAIR_STATE")"
    [ -f "$package" ] || {
        pz_error "rebuilt Codex package missing: $package"
        return 1
    }
    actual="$(file_sha256 "$package")"
    [ "$actual" = "$expected" ] || {
        pz_error "rebuilt Codex package checksum mismatch"
        return 1
    }
    pz_check_deps pkexec
    pz_info "requesting PolicyKit authorization for Codex Desktop update"
    pkexec /usr/bin/codex-update-manager install-pacman --path "$package"
    jq --arg installedAt "$(date -Iseconds)" \
        '.ready = false | .installedAt = $installedAt' \
        "$CODEX_REPAIR_STATE" > "${CODEX_REPAIR_STATE}.tmp"
    mv "${CODEX_REPAIR_STATE}.tmp" "$CODEX_REPAIR_STATE"
}

apply_codex() {
    pz_check_deps codex-update-manager pacman jq
    local state candidate installed diagnosis
    state="$(codex-update-manager status)"
    diagnosis="$(codex-update-manager diagnose --json 2>/dev/null || true)"
    if jq -e '.app.running == true or .appRunning == true' <<< "$diagnosis" >/dev/null 2>&1; then
        pz_error "close Codex Desktop before installing its prepared update"
        return 1
    fi
    candidate="$(jq -r '.candidate_version // empty' <<< "$state")"
    case "$(jq -r '.status // empty' <<< "$state")" in
        ready_to_install)
            [ -n "$candidate" ] || { pz_error "Codex Desktop candidate version missing"; return 1; }
            codex-update-manager install-ready
            ;;
        failed)
            repair_codex
            candidate="$(jq -r '.version' "$CODEX_REPAIR_STATE")"
            install_codex_ready
            ;;
        up_to_date)
            pz_info "Codex Desktop already current"
            return 0
            ;;
        *)
            pz_error "Codex Desktop has no prepared update; run check-codex and inspect status"
            return 1
            ;;
    esac
    installed="$(pacman -Q codex-desktop | awk '{print $2}')"
    [[ "$installed" == "$candidate"-* ]] || {
        pz_error "Codex Desktop install not confirmed: candidate $candidate, installed $installed"
        return 1
    }
    pz_info "Codex Desktop installed: $installed"
}

check_codex() {
    command -v codex-update-manager >/dev/null 2>&1 || {
        pz_warn "codex-update-manager not installed"
        return 0
    }
    codex_guard_once
    codex-update-manager check-now
}

install_services() {
    local runtime_dir="${XDG_DATA_HOME:-$HOME/.local/share}/phasezero/runtime"
    mkdir -p "$runtime_dir"
    install -m 0755 "$PZ_ROOT/linux/ai/desktop-apps.sh" "$runtime_dir/desktop-apps.sh"
    mkdir -p "$SYSTEMD_USER_DIR" "$SYSTEMD_USER_DIR/codex-update-manager.service.d"
    pz_write_managed_file "$SYSTEMD_USER_DIR/phasezero-codex-desktop-guard.service" <<EOF
[Unit]
Description=PhaseZero Codex Desktop update workspace guard
After=local-fs.target

[Service]
Type=simple
Environment=PZ_ROOT=$PZ_ROOT
ExecStart=$runtime_dir/desktop-apps.sh codex-guard-watch
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF
    pz_write_managed_file "$SYSTEMD_USER_DIR/codex-update-manager.service.d/phasezero-guard.conf" <<EOF
[Unit]
Wants=phasezero-codex-desktop-guard.service
After=phasezero-codex-desktop-guard.service
EOF
    pz_write_managed_file "$SYSTEMD_USER_DIR/phasezero-ai-desktop-update.service" <<EOF
[Unit]
Description=PhaseZero AI desktop application update
After=network-online.target phasezero-codex-desktop-guard.service
Wants=network-online.target phasezero-codex-desktop-guard.service

[Service]
Type=oneshot
Environment=PZ_ROOT=$PZ_ROOT
ExecStart=$runtime_dir/desktop-apps.sh update
EOF
    pz_write_managed_file "$SYSTEMD_USER_DIR/phasezero-ai-desktop-update.timer" <<'EOF'
[Unit]
Description=Periodic PhaseZero AI desktop application update

[Timer]
OnBootSec=10m
OnUnitActiveSec=12h
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now phasezero-codex-desktop-guard.service
    systemctl --user restart phasezero-codex-desktop-guard.service
    systemctl --user enable --now phasezero-ai-desktop-update.timer
    systemctl --user try-restart codex-update-manager.service >/dev/null 2>&1 || true
    pz_info "AI desktop update services enabled"
}

desktop_status() {
    local claude_version="" codex_status="" codex_installed="" codex_candidate=""
    local repaired_package="" repaired_version="" repaired_ready=false repaired_state_ready=false codex_cli='{"status":"unavailable"}'
    local codex_diagnosis='{}' codex_app_running=null
    claude_version="$(installed_claude_version || true)"
    codex_cli="$(bash "$PZ_ROOT/linux/ai/setup-codex.sh" status 2>/dev/null || true)"
    jq -e 'type == "object" and .tool == "codex"' <<< "$codex_cli" >/dev/null 2>&1 || codex_cli='{"status":"unavailable"}'
    if command -v codex-update-manager >/dev/null 2>&1; then
        codex_diagnosis="$(codex-update-manager diagnose --json 2>/dev/null || true)"
        codex_app_running="$(jq -r 'if .app.running == true or .appRunning == true then true elif .app.running == false or .appRunning == false then false else null end' <<< "$codex_diagnosis" 2>/dev/null || echo null)"
    fi
    if [ -f "$CODEX_STATE" ]; then
        codex_status="$(jq -r '.status // "unknown"' "$CODEX_STATE" 2>/dev/null || true)"
        codex_installed="$(jq -r '.installed_version // empty' "$CODEX_STATE" 2>/dev/null || true)"
        codex_candidate="$(jq -r '.candidate_version // empty' "$CODEX_STATE" 2>/dev/null || true)"
    fi
    if [ -f "$CODEX_REPAIR_STATE" ]; then
        repaired_package="$(jq -r '.package // empty' "$CODEX_REPAIR_STATE" 2>/dev/null || true)"
        repaired_version="$(jq -r '.version // empty' "$CODEX_REPAIR_STATE" 2>/dev/null || true)"
        repaired_state_ready="$(jq -r '.ready // false' "$CODEX_REPAIR_STATE" 2>/dev/null || echo false)"
        if [ -f "$repaired_package" ] && [ "$repaired_state_ready" = "true" ]; then
            if [ -z "$codex_installed" ] || [ -z "$repaired_version" ]; then
                repaired_ready=true
            elif command -v vercmp >/dev/null 2>&1 &&
                [ "$(vercmp "${repaired_version}-1" "$codex_installed")" -gt 0 ]; then
                repaired_ready=true
            fi
        fi
    fi
    local qwen_version="" qwen_sha256=""
    if [ -f "$QWEN_STATE" ]; then
        qwen_version="$(jq -r '.version // empty' "$QWEN_STATE" 2>/dev/null || true)"
        qwen_sha256="$(jq -r '.sha256 // empty' "$QWEN_STATE" 2>/dev/null || true)"
    fi
    jq -n \
        --arg claudeVersion "$claude_version" \
        --arg claudeBinary "$CLAUDE_ROOT/current/app/claude-desktop" \
        --arg claudeLauncher "$LOCAL_BIN/claude-desktop" \
        --arg claudeDesktopEntry "$APPLICATIONS_DIR/claude-desktop.desktop" \
        --arg codexStatus "$codex_status" \
        --arg codexInstalled "$codex_installed" \
        --arg codexCandidate "$codex_candidate" \
        --arg repairedPackage "$repaired_package" \
        --arg qwenVersion "$qwen_version" \
        --arg qwenSha256 "$qwen_sha256" \
        --arg qwenBinary "$QWEN_ROOT/current/Qwen-Code-Desktop-x86_64.AppImage" \
        --arg qwenLauncher "$LOCAL_BIN/qwen-code-desktop" \
        --arg qwenConfigDir "$QWEN_CONFIG_DIR" \
        --argjson claudeInstalled "$([ -x "$CLAUDE_ROOT/current/app/claude-desktop" ] && echo true || echo false)" \
        --argjson claudeLauncherOk "$([ -x "$LOCAL_BIN/claude-desktop" ] && echo true || echo false)" \
        --argjson claudeLauncherManaged "$(claude_launcher_managed && echo true || echo false)" \
        --argjson claudeDesktopEntryOk "$([ -f "$APPLICATIONS_DIR/claude-desktop.desktop" ] && echo true || echo false)" \
        --argjson qwenInstalled "$([ -x "$QWEN_ROOT/current/Qwen-Code-Desktop-x86_64.AppImage" ] && echo true || echo false)" \
        --argjson repairedReady "$repaired_ready" \
        --argjson codexCli "$codex_cli" \
        --argjson codexAppRunning "$codex_app_running" \
        --argjson guardActive "$(bool_json systemctl --user is-active phasezero-codex-desktop-guard.service)" \
        --argjson guardEnabled "$(bool_json systemctl --user is-enabled phasezero-codex-desktop-guard.service)" \
        --argjson timerActive "$(bool_json systemctl --user is-active phasezero-ai-desktop-update.timer)" \
        --argjson timerEnabled "$(bool_json systemctl --user is-enabled phasezero-ai-desktop-update.timer)" \
        '{
          schemaVersion: 2,
          claudeDesktop: {
            installed: $claudeInstalled,
            version: $claudeVersion,
            binary: $claudeBinary,
            launcher: $claudeLauncher,
            launcherOk: $claudeLauncherOk,
            launcherManaged: $claudeLauncherManaged,
            desktopEntry: $claudeDesktopEntry,
            desktopEntryOk: $claudeDesktopEntryOk,
            source: "official-anthropic-apt",
            userScoped: true
          },
          qwenCodeDesktop: {
            installed: $qwenInstalled,
            version: $qwenVersion,
            sha256: $qwenSha256,
            binary: $qwenBinary,
            launcher: $qwenLauncher,
            configDir: $qwenConfigDir,
            source: "official-qwen-github-release",
            userScoped: true,
            secretsManaged: false
          },
          codexDesktop: {
            installedVersion: $codexInstalled,
            candidateVersion: $codexCandidate,
            updateStatus: $codexStatus,
            repairedPackage: $repairedPackage,
            repairedPackageReady: $repairedReady,
            guardActive: $guardActive,
            guardEnabled: $guardEnabled,
            appRunning: $codexAppRunning
          },
          codexCli: $codexCli,
          updater: {
            timerActive: $timerActive,
            timerEnabled: $timerEnabled
          }
        }'
}

update_all() {
    # Timer updates only what is already installed; never installs new apps.
    if [ -x "$CLAUDE_ROOT/current/app/claude-desktop" ]; then
        # Separate process: `||` would disable errexit inside the function.
        bash "${BASH_SOURCE[0]}" install-claude || pz_warn "Claude Desktop update failed"
    fi
    if [ -x "$QWEN_ROOT/current/Qwen-Code-Desktop-x86_64.AppImage" ]; then
        bash "${BASH_SOURCE[0]}" install-qwen || pz_warn "Qwen Code Desktop update failed"
    fi
    check_codex || pz_warn "Codex Desktop update check failed; run: $PZ_ROOT/linux/pz ai desktop repair-codex"
}

repair_all() {
    install_claude
    install_qwen
    codex_guard_once
    if [ "$(jq -r '.status // empty' "$CODEX_STATE" 2>/dev/null || true)" = "failed" ]; then
        repair_codex
    fi
    install_services
}

disable_updates() {
    local unit=phasezero-ai-desktop-update.timer state
    # A failed bus/query is not evidence that the timer is absent.
    state="$(systemctl --user show "$unit" --property=LoadState --value)" || {
        pz_error "Cannot query update timer; check systemctl --user status $unit"
        return 1
    }
    if [[ "$state" != not-found ]]; then
        systemctl --user disable --now "$unit" || {
            pz_error "Cannot disable update timer; check systemctl --user status $unit"
            return 1
        }
    fi
    state="$(systemctl --user show "$unit" --property=LoadState,ActiveState,UnitFileState)" || {
        pz_error "Cannot confirm update timer state; retry disable-updates"
        return 1
    }
    if ! grep -qx 'ActiveState=inactive' <<< "$state" ||
       ! grep -Eq '^(UnitFileState=(disabled|masked)|LoadState=not-found)$' <<< "$state"; then
        pz_error "Update timer is not confirmed inactive and disabled; check systemctl --user status $unit"
        return 1
    fi
    pz_info "AI desktop automatic updates disabled (run install-services to enable)"
}

main() {
    local action="${1:-status}"
    case "$action" in
        status) desktop_status ;;
        install-claude|update-claude) install_claude ;;
        launch-claude) shift; launch_claude "$@" ;;
        test-claude) test_claude ;;
        check-claude) check_claude ;;
        install-qwen|update-qwen) install_qwen ;;
        launch-qwen) shift; launch_qwen "$@" ;;
        codex-guard-once) codex_guard_once ;;
        codex-guard-watch) codex_guard_watch ;;
        repair-codex) repair_codex ;;
        install-codex-ready) install_codex_ready ;;
        apply-codex) apply_codex ;;
        check-codex) check_codex ;;
        install-services) install_services ;;
        disable-updates)
            disable_updates ;;
        update) update_all ;;
        repair) repair_all ;;
        help|-h|--help) usage ;;
        *) pz_error "unknown desktop app action: $action"; usage; return 1 ;;
    esac
}

main "$@"
