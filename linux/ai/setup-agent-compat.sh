#!/usr/bin/env bash
# setup-agent-compat.sh - RTK/Caveman/ai-memory/Headroom/Ponytail compatibility runtime for Linux
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/ai"
STATE_FILE="$STATE_DIR/agent-compat.json"
PROJECTS_FILE="$STATE_DIR/projects.json"
WORKSPACE_ROOT="${PZ_WORKSPACE_ROOT:-}"
RTK_REPO_API="${PZ_RTK_REPO_API:-https://api.github.com/repos/rtk-ai/rtk/releases/latest}"
RTK_DOCS_URL="https://www.rtk-ai.app/docs/"
RTK_REPO_URL="https://github.com/rtk-ai/rtk"

first_line() {
    timeout 8 "$@" 2>/dev/null | head -1 | tr -d '\r' || true
}

tool_path() {
    local name="$1"
    command -v "$name" 2>/dev/null || {
        [ -x "$LOCAL_BIN/$name" ] && echo "$LOCAL_BIN/$name" && return 0
        [ -x "$HOME/.cargo/bin/$name" ] && echo "$HOME/.cargo/bin/$name" && return 0
        [ -x "$HOME/.local/share/uv/tools/$name/bin/$name" ] && echo "$HOME/.local/share/uv/tools/$name/bin/$name" && return 0
        return 1
    }
}

bool_json() {
    [ "$1" = "true" ] && printf 'true' || printf 'false'
}

registered_workspace_root() {
    [ -n "$WORKSPACE_ROOT" ] && [ -d "$WORKSPACE_ROOT" ] && { printf '%s\n' "$WORKSPACE_ROOT"; return 0; }
    [ -f "$PROJECTS_FILE" ] || return 1
    jq -r '.projects | reverse[]? | .path // empty' "$PROJECTS_FILE" 2>/dev/null | while IFS= read -r path; do
        [ -d "$path" ] || continue
        [ -f "$path/AGENTS.md" ] || continue
        grep -q 'BEGIN BOOTSTRAP CAVEMAN' "$path/AGENTS.md" 2>/dev/null || continue
        grep -q 'BEGIN PHASEZERO TOOLS' "$path/AGENTS.md" 2>/dev/null || continue
        printf '%s\n' "$path"
        break
    done
}

detected_client_bindings() {
    local memory_state="$STATE_DIR/memory-integrations.json" memory_clients='[]'
    if [ -f "$memory_state" ] && jq empty "$memory_state" >/dev/null 2>&1; then
        memory_clients="$(jq '.clients // []' "$memory_state")"
    fi
    jq -cn --argjson memoryClients "$memory_clients" \
        --argjson grok "$({ command -v grok >/dev/null 2>&1 || [ -d "$HOME/.grok" ]; } && echo true || echo false)" \
        --argjson kimi "$({ command -v kimi >/dev/null 2>&1 || command -v kimi-code >/dev/null 2>&1 || [ -d "$HOME/.kimi-code" ] || [ -d "$HOME/.kimi" ]; } && echo true || echo false)" \
        --argjson zcode "$({ command -v zcode >/dev/null 2>&1 || [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/ai.z.zcode/store.json" ]; } && echo true || echo false)" '
      def mem($id): ($memoryClients | map(select(.client == $id)) | first // {});
      {
        clients:[
          {id:"grok-build",label:"Grok Build CLI",detected:$grok,kind:"agent",rules:"AGENTS.md",rtk:"host-shell",memory:(mem("grok")),directRuleInjection:false},
          {id:"kimi-code",label:"Kimi Code CLI",detected:$kimi,kind:"agent",rules:"AGENTS.md",rtk:"host-shell",memory:(mem("kimi-code")),directRuleInjection:false},
          {id:"zcode",label:"ZCode",detected:$zcode,kind:"agent",rules:"AGENTS.md (OpenCode-compatible)",rtk:"host-shell",memory:(mem("zcode")),directRuleInjection:false}
        ],
        providers:[
          {id:"grok-provider",label:"Grok/xAI provider",kind:"provider",directRuleInjection:false,receivesRulesThrough:"selected agent client"},
          {id:"kimi-provider",label:"Kimi/Moonshot provider",kind:"provider",directRuleInjection:false,receivesRulesThrough:"selected agent client"}
        ],
        safety:"Rules stay project-scoped; providers never receive host instructions or secrets directly."
      }'
}

ensure_local_bin() {
    mkdir -p "$LOCAL_BIN" "$STATE_DIR"
}

rtk_asset_name() {
    case "$(uname -m)" in
        x86_64|amd64) echo "rtk-x86_64-unknown-linux-musl.tar.gz" ;;
        aarch64|arm64) echo "rtk-aarch64-unknown-linux-gnu.tar.gz" ;;
        *) return 1 ;;
    esac
}

install_rtk_release() {
    ensure_local_bin
    local existing=""
    existing="$(tool_path rtk || true)"
    if [ -n "$existing" ] && [ "${PZ_RTK_FORCE:-0}" != "1" ]; then
        pz_info "rtk already installed: $existing"
        return 0
    fi

    pz_check_deps curl jq tar sha256sum >/dev/null
    local asset release tag asset_url checksum_url work archive checksums expected actual extract rtk_found
    asset="$(rtk_asset_name)" || {
        pz_warn "unsupported RTK Linux architecture: $(uname -m)"
        return 1
    }
    work="$(mktemp -d)"
    trap 'rm -rf -- "${work:?}"; trap - RETURN' RETURN
    release="$(curl -fsSL "$RTK_REPO_API")"
    tag="$(jq -r '.tag_name // empty' <<< "$release")"
    asset_url="$(jq -r --arg asset "$asset" '.assets[]? | select(.name == $asset) | .browser_download_url' <<< "$release" | head -1)"
    checksum_url="$(jq -r '.assets[]? | select(.name == "checksums.txt") | .browser_download_url' <<< "$release" | head -1)"
    if [ -z "$tag" ] || [ -z "$asset_url" ] || [ -z "$checksum_url" ]; then
        pz_warn "RTK release asset not found for $asset"
        return 1
    fi

    archive="$work/$asset"
    checksums="$work/checksums.txt"
    curl -fL "$asset_url" -o "$archive"
    curl -fsSL "$checksum_url" -o "$checksums"
    expected="$(awk -v asset="$asset" '$2 == asset {print $1}' "$checksums" | head -1)"
    [ -n "$expected" ] || {
        pz_warn "RTK checksum missing for $asset"
        return 1
    }
    actual="$(sha256sum "$archive" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || {
        pz_error "RTK checksum mismatch. expected=$expected actual=$actual"
        return 1
    }

    extract="$work/extract"
    mkdir -p "$extract"
    tar -xzf "$archive" -C "$extract"
    rtk_found="$(find "$extract" -type f -name rtk -perm -u+x -print -quit 2>/dev/null || true)"
    [ -n "$rtk_found" ] || rtk_found="$(find "$extract" -type f -name rtk -print -quit 2>/dev/null || true)"
    [ -n "$rtk_found" ] || {
        pz_warn "RTK archive extracted, but binary not found"
        return 1
    }
    install -m 0755 "$rtk_found" "$LOCAL_BIN/rtk"
    pz_record_created ai "$LOCAL_BIN/rtk"
    jq -n \
        --arg tag "$tag" \
        --arg asset "$asset" \
        --arg source "$asset_url" \
        --arg checksum "$expected" \
        --arg path "$LOCAL_BIN/rtk" \
        --arg installedAt "$(date -Iseconds)" \
        '{schemaVersion:1,tool:"rtk",releaseTag:$tag,asset:$asset,source:$source,sha256:$checksum,path:$path,installedAt:$installedAt}' \
        > "$STATE_DIR/rtk.json"
    pz_info "RTK installed: $LOCAL_BIN/rtk ($tag)"
}

install_rtk_fallback() {
    install_rtk_release && return 0
    if command -v yay >/dev/null 2>&1; then
        yay -S --needed --noconfirm rtk-bin || yay -S --needed --noconfirm rtk
        return $?
    fi
    if command -v cargo >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
        local src="${PZ_AI_SOURCE_DIR:-$HOME/.local/share/phasezero/src}/rtk"
        mkdir -p "$(dirname "$src")"
        if [ -d "$src/.git" ]; then
            git -C "$src" pull --ff-only
        else
            git clone --depth 1 "$RTK_REPO_URL" "$src"
        fi
        cargo build --release --manifest-path "$src/Cargo.toml" --bin rtk
        install -m 0755 "$src/target/release/rtk" "$LOCAL_BIN/rtk"
        pz_record_created ai "$LOCAL_BIN/rtk"
        pz_info "RTK built from source: $LOCAL_BIN/rtk"
        return 0
    fi
    pz_error "could not install RTK"
    return 1
}

configure_rtk() {
    local cmd=""
    cmd="$(tool_path rtk || true)"
    [ -n "$cmd" ] || {
        pz_warn "rtk missing; skipping rtk init"
        return 0
    }
    timeout 20 "$cmd" init --global --codex >/dev/null 2>&1 || pz_warn "rtk Codex init skipped/failed"
    timeout 20 "$cmd" init --global --agent claude --no-patch >/dev/null 2>&1 || pz_warn "rtk Claude init skipped/failed"
    timeout 10 "$cmd" gain >/dev/null 2>&1 || true
}

install_headroom() {
    ensure_local_bin
    if tool_path headroom >/dev/null 2>&1; then
        pz_info "headroom already installed: $(tool_path headroom)"
        return 0
    fi
    if command -v uv >/dev/null 2>&1; then
        uv tool install --reinstall 'headroom-ai[proxy]' || uv tool install --reinstall headroom-ai
    elif command -v pipx >/dev/null 2>&1; then
        pipx install --include-deps 'headroom-ai[proxy]' || pipx install headroom-ai
    else
        pz_warn "uv/pipx missing; cannot install Headroom"
        return 1
    fi
    tool_path headroom >/dev/null 2>&1 || {
        pz_warn "headroom install finished but command not found in PATH/local bin"
        return 1
    }
    pz_info "headroom installed: $(tool_path headroom)"
}

block_file() {
    local label="$1" body_file="$2" header_kind="${3:-none}" out="$4"
    local description="PhaseZero agent compatibility"
    [ "$label" = "BOOTSTRAP CAVEMAN" ] && description="Caveman always-on mode"
    : > "$out"
    case "$header_kind" in
        cursor)
            printf '%s\n' '---' "description: $description" 'alwaysApply: true' '---' '' >> "$out"
            ;;
        windsurf)
            printf '%s\n' '---' "description: $description" 'trigger: always_on' '---' '' >> "$out"
            ;;
    esac
    if [ "$header_kind" = "hash" ]; then
        {
            printf '# >>> %s >>>\n' "$label"
            sed 's/\r$//' "$body_file"
            printf '\n# <<< %s <<<\n' "$label"
        } >> "$out"
    else
        {
            printf '<!-- BEGIN %s -->\n' "$label"
            sed 's/\r$//' "$body_file"
            printf '\n<!-- END %s -->\n' "$label"
        } >> "$out"
    fi
}

trim_trailing_blank_lines() {
    local path="$1" tmp_trim
    tmp_trim="$(mktemp)"
    awk '
        { lines[NR] = $0 }
        END {
            n = NR
            while (n > 0) {
                line = lines[n]
                sub(/\r$/, "", line)
                if (line !~ /^[[:space:]]*$/) break
                n--
            }
            for (i = 1; i <= n; i++) print lines[i]
        }
    ' "$path" > "$tmp_trim"
    mv "$tmp_trim" "$path"
}

backup_managed_file() {
    local path="$1"
    [ -f "$path" ] || return 0
    pz_backup_file "$path" user >/dev/null
}

write_marked_block() {
    local path="$1" label="$2" body_file="$3" header_kind="${4:-none}" dir tmp block begin end
    dir="$(dirname "$path")"
    mkdir -p "$dir"
    tmp="$(mktemp)"
    block="$(mktemp)"
    if [ "$header_kind" = "hash" ]; then
        begin="# >>> $label >>>"
        end="# <<< $label <<<"
    else
        begin="<!-- BEGIN $label -->"
        end="<!-- END $label -->"
    fi
    if [ -f "$path" ]; then
        case "$header_kind" in
            hash) block_file "$label" "$body_file" "hash" "$block" ;;
            *) block_file "$label" "$body_file" "none" "$block" ;;
        esac
        awk -v begin="$begin" -v end="$end" -v block_file="$block" '
            BEGIN {
                while ((getline line < block_file) > 0) replacement = replacement line ORS
                in_block = 0
                replaced = 0
            }
            {
                clean = $0
                sub(/\r$/, "", clean)
            }
            clean == begin {
                if (!replaced) printf "%s", replacement
                in_block = 1
                replaced = 1
                next
            }
            clean == end {
                in_block = 0
                next
            }
            !in_block { print }
            END {
                if (!replaced) {
                    if (NR > 0) print ""
                    printf "%s", replacement
                }
            }
        ' "$path" > "$tmp"
    else
        block_file "$label" "$body_file" "$header_kind" "$block"
        cat "$block" > "$tmp"
    fi
    trim_trailing_blank_lines "$tmp"
    if [ ! -f "$path" ] || ! cmp -s "$tmp" "$path"; then
        backup_managed_file "$path"
        mv "$tmp" "$path"
        pz_info "wrote $path"
    else
        rm -f "$tmp"
    fi
    rm -f "$block"
}

# zcode is an OpenCode fork and reads AGENTS.md natively; the dedicated
# .zcode/rules/ copies stay opt-in until upstream documents project rules.
zcode_rules_enabled() {
    [ "${PZ_INIT_ZCODE:-0}" = "1" ]
}

phasezero_targets() {
    printf '%s\t%s\t%s\n' "agents" "$WORKSPACE_ROOT/AGENTS.md" "none"
    printf '%s\t%s\t%s\n' "claude" "$WORKSPACE_ROOT/CLAUDE.md" "none"
    printf '%s\t%s\t%s\n' "gemini" "$WORKSPACE_ROOT/GEMINI.md" "none"
    printf '%s\t%s\t%s\n' "github-copilot" "$WORKSPACE_ROOT/.github/copilot-instructions.md" "none"
    printf '%s\t%s\t%s\n' "cursor" "$WORKSPACE_ROOT/.cursor/rules/phasezero-tools.mdc" "cursor"
    printf '%s\t%s\t%s\n' "windsurf" "$WORKSPACE_ROOT/.windsurf/rules/phasezero-tools.md" "windsurf"
    printf '%s\t%s\t%s\n' "cline" "$WORKSPACE_ROOT/.clinerules/phasezero-tools.md" "none"
    if zcode_rules_enabled; then
        printf '%s\t%s\t%s\n' "zcode" "$WORKSPACE_ROOT/.zcode/rules/phasezero-tools.md" "none"
    fi
}

caveman_targets() {
    printf '%s\t%s\t%s\n' "agents" "$WORKSPACE_ROOT/AGENTS.md" "none"
    printf '%s\t%s\t%s\n' "claude" "$WORKSPACE_ROOT/CLAUDE.md" "none"
    printf '%s\t%s\t%s\n' "gemini" "$WORKSPACE_ROOT/GEMINI.md" "none"
    printf '%s\t%s\t%s\n' "github-copilot" "$WORKSPACE_ROOT/.github/copilot-instructions.md" "none"
    printf '%s\t%s\t%s\n' "cursor" "$WORKSPACE_ROOT/.cursor/rules/caveman.mdc" "cursor"
    printf '%s\t%s\t%s\n' "windsurf" "$WORKSPACE_ROOT/.windsurf/rules/caveman.md" "windsurf"
    printf '%s\t%s\t%s\n' "cline" "$WORKSPACE_ROOT/.clinerules/caveman.md" "none"
    if zcode_rules_enabled; then
        printf '%s\t%s\t%s\n' "zcode" "$WORKSPACE_ROOT/.zcode/rules/caveman.md" "none"
    fi
}

rule_pairs() {
    printf '%s\t%s\t%s\n' "agents" "$WORKSPACE_ROOT/AGENTS.md" "$WORKSPACE_ROOT/AGENTS.md"
    printf '%s\t%s\t%s\n' "claude" "$WORKSPACE_ROOT/CLAUDE.md" "$WORKSPACE_ROOT/CLAUDE.md"
    printf '%s\t%s\t%s\n' "gemini" "$WORKSPACE_ROOT/GEMINI.md" "$WORKSPACE_ROOT/GEMINI.md"
    printf '%s\t%s\t%s\n' "github-copilot" "$WORKSPACE_ROOT/.github/copilot-instructions.md" "$WORKSPACE_ROOT/.github/copilot-instructions.md"
    printf '%s\t%s\t%s\n' "cursor" "$WORKSPACE_ROOT/.cursor/rules/caveman.mdc" "$WORKSPACE_ROOT/.cursor/rules/phasezero-tools.mdc"
    printf '%s\t%s\t%s\n' "windsurf" "$WORKSPACE_ROOT/.windsurf/rules/caveman.md" "$WORKSPACE_ROOT/.windsurf/rules/phasezero-tools.md"
    printf '%s\t%s\t%s\n' "cline" "$WORKSPACE_ROOT/.clinerules/caveman.md" "$WORKSPACE_ROOT/.clinerules/phasezero-tools.md"
    if zcode_rules_enabled; then
        printf '%s\t%s\t%s\n' "zcode" "$WORKSPACE_ROOT/.zcode/rules/caveman.md" "$WORKSPACE_ROOT/.zcode/rules/phasezero-tools.md"
    fi
}

is_ponytail_workspace() {
    local root="${1:-$WORKSPACE_ROOT}" candidate
    [ -d "$root/src-tauri" ] && return 0
    for candidate in "$root/Cargo.toml" "$root/package.json" "$root/config/project_state.json" "$root/config/project.json" "$root/src-tauri/src/main.rs"; do
        [ -f "$candidate" ] || continue
        grep -Eqi '(ponytail|sgdk|sgdk-import|SpriteMetadata|generate_sgdk_code|tauri)' "$candidate" && return 0
    done
    for candidate in "$root/sgdk" "$root/assets/sprites" "$root/resources/sprites"; do
        [ -e "$candidate" ] && return 0
    done
    return 1
}

apply_rules() {
    # Every target is "$WORKSPACE_ROOT/<file>": an empty root would write
    # /AGENTS.md, /CLAUDE.md, ... (and succeed under sudo).
    case "$WORKSPACE_ROOT" in
        ""|/|"$HOME") pz_error "refusing to write agent rules without a project (workspace: '${WORKSPACE_ROOT}')"; return 2 ;;
    esac
    local caveman_body="$PZ_ROOT/assets/agent-skills/caveman-always-on.md"
    local tools_body="$PZ_ROOT/assets/agent-skills/phasezero-tools-always-on.md"
    local ponytail_body="$PZ_ROOT/assets/agent-skills/ponytail-architecture-runtime.md"
    local id path header
    while IFS=$'\t' read -r id path header; do
        [ -n "$path" ] || continue
        write_marked_block "$path" "BOOTSTRAP CAVEMAN" "$caveman_body" "$header"
    done < <(caveman_targets)
    while IFS=$'\t' read -r id path header; do
        [ -n "$path" ] || continue
        write_marked_block "$path" "PHASEZERO TOOLS" "$tools_body" "$header"
    done < <(phasezero_targets)
    if is_ponytail_workspace "$WORKSPACE_ROOT" || [ "${PZ_PONYTAIL_FORCE:-0}" = "1" ]; then
        while IFS=$'\t' read -r id path header; do
            [ -n "$path" ] || continue
            write_marked_block "$path" "PONYTAIL ARCHITECTURE" "$ponytail_body" "$header"
        done < <(phasezero_targets)
    else
        pz_info "Ponytail not detected; architecture rules skipped"
    fi
}

frugality_aider_body() {
    cat <<'EOF'
# PhaseZero AI context frugality
# Keep reproducibility lockfiles visible by default.

.codex/ai-context/
.codex/context-packs/
.phasezero/tmp/
.phasezero/cache/

node_modules/
.next/
.nuxt/
.turbo/
dist/
build/
out/
coverage/

.pytest_cache/
.mypy_cache/
.ruff_cache/
__pycache__/

target/debug/
target/release/

*.log
*.tmp
*.bak
hs_err_pid*.log
EOF
}

apply_frugality_pack() {
    local context_dir="$WORKSPACE_ROOT/.codex/context-packs"
    local ai_context_dir="$WORKSPACE_ROOT/.codex/ai-context"
    local doc="$context_dir/ai-context-frugality.md"
    local manifest="$ai_context_dir/frugality-manifest.json"
    local skeleton_json="$ai_context_dir/repo-skeleton.json"
    local skeleton_md="$ai_context_dir/repo-skeleton.md"
    local tmp
    mkdir -p "$context_dir" "$ai_context_dir"
    pz_write_managed_file "$doc" <<'EOF'
# AI Context Frugality Pack

Purpose: reduce noisy AI context for IDEs and CLIs without hiding reproducibility or security-critical files.

Safety:
- No secrets are written.
- No CLI/IDE wrapper runs automatically.
- Lockfiles remain visible by default.
- Build/cache/generated folders stay out of routine context.
EOF
    tmp="$(mktemp)"
    frugality_aider_body > "$tmp"
    write_marked_block "$WORKSPACE_ROOT/.aiderignore" "PHASEZERO AI CONTEXT FRUGALITY" "$tmp" "hash"
    rm -f "$tmp"

    find "$WORKSPACE_ROOT" -maxdepth 3 -type f \
        \( -name '*.sh' -o -name '*.ps1' -o -name '*.json' -o -name '*.md' -o -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.rs' -o -name '*.go' \) \
        ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/.codex/ai-context/*' \
        -printf '%P\n' 2>/dev/null | sort | head -500 | jq -R . | jq -s \
        --arg root "$WORKSPACE_ROOT" --arg generatedAt "$(date -Iseconds)" \
        '{schemaVersion:1,root:$root,generatedAt:$generatedAt,files:.}' > "$skeleton_json"
    jq -r '.files[]' "$skeleton_json" | sed 's/^/- /' > "$skeleton_md"
    jq -n \
        --arg root "$WORKSPACE_ROOT" \
        --arg generatedAt "$(date -Iseconds)" \
        '{version:1,id:"ai-context-frugality-pack",root:$root,generatedAt:$generatedAt,policy:{noSecrets:true,automaticWrappers:false,sessionResetAutomation:false,lockfilesVisible:true}}' \
        > "$manifest"
    pz_info "AI context frugality pack applied"
}

rule_records() {
    local id caveman_path tools_path exists=false caveman=false tools=false ponytail=false
    while IFS=$'\t' read -r id caveman_path tools_path; do
        [ -n "$id" ] || continue
        exists=false; caveman=false; tools=false; ponytail=false
        [ -f "$caveman_path" ] && [ -f "$tools_path" ] && exists=true
        [ -f "$caveman_path" ] && grep -q 'BEGIN BOOTSTRAP CAVEMAN' "$caveman_path" && caveman=true
        [ -f "$tools_path" ] && grep -q 'BEGIN PHASEZERO TOOLS' "$tools_path" && tools=true
        [ -f "$tools_path" ] && grep -q 'BEGIN PONYTAIL ARCHITECTURE' "$tools_path" && ponytail=true
        jq -cn --arg id "$id" --arg cavemanPath "$caveman_path" --arg toolsPath "$tools_path" \
            --argjson exists "$(bool_json "$exists")" \
            --argjson caveman "$(bool_json "$caveman")" \
            --argjson phasezeroTools "$(bool_json "$tools")" \
            --argjson ponytail "$(bool_json "$ponytail")" \
            '{id:$id,cavemanPath:$cavemanPath,toolsPath:$toolsPath,exists:$exists,caveman:$caveman,phasezeroTools:$phasezeroTools,ponytail:$ponytail}'
    done < <(rule_pairs)
}

frugality_configured() {
    [ -f "$WORKSPACE_ROOT/.codex/ai-context/frugality-manifest.json" ] && return 0
    [ -f "$WORKSPACE_ROOT/.codex/ai-context/repo-skeleton.json" ] && return 0
    [ -f "$WORKSPACE_ROOT/.codex/context-packs/ai-context-frugality.md" ] && return 0
    [ -f "$WORKSPACE_ROOT/.aiderignore" ] && grep -q 'PHASEZERO AI CONTEXT FRUGALITY' "$WORKSPACE_ROOT/.aiderignore"
}

status_json() {
    local rtk_path="" memory_path="" headroom_path="" rtk_ver="" memory_ver="" headroom_ver=""
    local ponytail=false frugality=false rule_json='[]' rules_ok=false mode="degraded" workspace_source="none" bindings
    if [ -n "${PZ_WORKSPACE_ROOT:-}" ]; then
        WORKSPACE_ROOT="${PZ_WORKSPACE_ROOT}"
        workspace_source="explicit"
    elif WORKSPACE_ROOT="$(registered_workspace_root || true)" && [ -n "$WORKSPACE_ROOT" ]; then
        workspace_source="registered"
    else
        WORKSPACE_ROOT=""
        mode="needs-project"
    fi
    rtk_path="$(tool_path rtk || true)"
    memory_path="$(tool_path ai-memory || true)"
    headroom_path="$(tool_path headroom || true)"
    [ -n "$rtk_path" ] && rtk_ver="$(first_line "$rtk_path" --version)"
    [ -n "$memory_path" ] && memory_ver="$(first_line "$memory_path" --version)"
    [ -n "$headroom_path" ] && headroom_ver="$(first_line "$headroom_path" --version)"
    if [ -n "$WORKSPACE_ROOT" ]; then
        is_ponytail_workspace "$WORKSPACE_ROOT" && ponytail=true
        frugality_configured && frugality=true
        rule_json="$(rule_records | jq -s .)"
        jq -e 'length > 0 and all(.[]; .caveman == true and .phasezeroTools == true)' <<< "$rule_json" >/dev/null && rules_ok=true
    fi
    bindings="$(detected_client_bindings)"
    if [ -n "$rtk_path" ] && [ -n "$memory_path" ] && [ "$rules_ok" = "true" ]; then
        mode="ready"
    elif [ -z "$WORKSPACE_ROOT" ]; then
        mode="needs-project"
    fi
    jq -cn \
        --arg mode "$mode" \
        --arg workspaceRoot "$WORKSPACE_ROOT" \
        --arg workspaceSource "$workspace_source" \
        --arg docs "$RTK_DOCS_URL" \
        --arg rtkPath "$rtk_path" \
        --arg rtkVersion "$rtk_ver" \
        --arg memoryPath "$memory_path" \
        --arg memoryVersion "$memory_ver" \
        --arg headroomPath "$headroom_path" \
        --arg headroomVersion "$headroom_ver" \
        --arg stateFile "$STATE_FILE" \
        --argjson rules "$rule_json" \
        --argjson rulesOk "$(bool_json "$rules_ok")" \
        --argjson ponytailDetected "$(bool_json "$ponytail")" \
        --argjson frugalityConfigured "$(bool_json "$frugality")" \
        --argjson bindings "$bindings" \
        '{
          schemaVersion:1,
          mode:$mode,
          workspaceRoot:$workspaceRoot,
          workspaceSource:$workspaceSource,
          stateFile:$stateFile,
          tools:{
            caveman:{id:"caveman",status:(if $rulesOk then "available" else "missing-rules" end),role:"style",configured:$rulesOk},
            rtk:{id:"rtk",status:(if $rtkPath != "" then "available" else "absent" end),role:"shell-compression",path:$rtkPath,version:$rtkVersion,docs:$docs,configured:($rtkPath != "")},
            aiMemory:{id:"ai-memory",status:(if $memoryPath != "" then "available" else "absent" end),role:"memory-handoff",path:$memoryPath,version:$memoryVersion,configured:($memoryPath != "")},
            headroom:{id:"headroom",status:(if $headroomPath != "" then "available" else "absent" end),role:"context-compression",path:$headroomPath,version:$headroomVersion,configured:($headroomPath != "")},
            ponytail:{id:"ponytail",status:(if $ponytailDetected then "active" else "inactive" end),role:"workspace-architecture",configured:$ponytailDetected},
            aiContextFrugality:{id:"ai-context-frugality",status:(if $frugalityConfigured then "configured" else "notConfigured" end),role:"context-hygiene",configured:$frugalityConfigured},
            graphify:{id:"graphify",status:"notConfigured",role:"placeholder",configured:false,placeholder:true,repairKind:"none"}
          },
          rules:{ok:$rulesOk,files:$rules},
          integrations:$bindings,
          conflictRules:["style=caveman","shell=rtk-when-present","memory=ai-memory-when-present","architecture=ponytail-workspace-only","no-duplicate-wrappers","no-secrets-in-rules"]
        }'
}

write_state() {
    mkdir -p "$STATE_DIR"
    status_json > "$STATE_FILE"
    pz_info "wrote agent compatibility state: $STATE_FILE"
}

dry_run() {
    local asset=""
    if [ -z "$WORKSPACE_ROOT" ]; then
        WORKSPACE_ROOT="$(registered_workspace_root || true)"
    fi
    asset="$(rtk_asset_name || true)"
    jq -cn \
        --arg workspaceRoot "$WORKSPACE_ROOT" \
        --arg localBin "$LOCAL_BIN" \
        --arg rtkAsset "$asset" \
        '{tool:"agent-compat",planned:["install RTK release with sha256 verification","run rtk init when available","install Headroom via uv/pipx","configure ai-memory service/hooks","apply Caveman and PhaseZero tool rules","apply Ponytail rules only when workspace detected","write AI context frugality pack","write status state"],workspaceRoot:$workspaceRoot,localBin:$localBin,rtkAsset:$rtkAsset}'
}

remove_marked_block() {
    local path="$1" label="$2" kind="${3:-none}" begin end tmp
    [ -f "$path" ] || return 0
    if [ "$kind" = "hash" ]; then
        begin="# >>> $label >>>"
        end="# <<< $label <<<"
    else
        begin="<!-- BEGIN $label -->"
        end="<!-- END $label -->"
    fi
    grep -qF "$begin" "$path" || return 0
    tmp="$(mktemp)"
    awk -v begin="$begin" -v end="$end" '
        { clean = $0; sub(/\r$/, "", clean) }
        clean == begin { in_block = 1; next }
        clean == end { in_block = 0; next }
        !in_block { print }
    ' "$path" > "$tmp"
    trim_trailing_blank_lines "$tmp"
    backup_managed_file "$path"
    if grep -q '[^[:space:]]' "$tmp"; then
        mv "$tmp" "$path"
        pz_info "removed $label block from $path"
    else
        rm -f "$tmp" "$path"
        pz_info "removed $path"
    fi
}

projects_file_init() {
    mkdir -p "$STATE_DIR"
    [ -f "$PROJECTS_FILE" ] || printf '{"schemaVersion":1,"projects":[]}\n' > "$PROJECTS_FILE"
}

rules_source_hash() {
    local ponytail="${1:-false}"
    local files=(
        "$PZ_ROOT/assets/agent-skills/caveman-always-on.md"
        "$PZ_ROOT/assets/agent-skills/phasezero-tools-always-on.md"
    )
    [ "$ponytail" = "true" ] && files+=("$PZ_ROOT/assets/agent-skills/ponytail-architecture-runtime.md")
    cat "${files[@]}" | sha256sum | awk '{print "sha256-"$1}'
}

register_project() {
    local path="$1" ponytail="$2" zcode="$3" hash="$4" rules_applied="$5" tmp
    projects_file_init
    tmp="$(mktemp)"
    jq --arg path "$path" --arg at "$(date -Iseconds)" --arg hash "$hash" \
        --argjson ponytail "$(bool_json "$ponytail")" \
        --argjson zcode "$(bool_json "$zcode")" \
        --argjson rulesApplied "$(bool_json "$rules_applied")" '
        .projects = [.projects[] | select(.path != $path)] + [{
            path: $path,
            injectedAt: $at,
            agents: (if $rulesApplied
                then ["agents","claude","gemini","github-copilot","cursor","windsurf","cline","grok-build","kimi-code","zcode"]
                else [] end),
            ponytail: $ponytail,
            zcodeDedicatedRules: $zcode,
            rulesHash: $hash,
            lastStatus: "ready"
        }]' "$PROJECTS_FILE" > "$tmp" && mv "$tmp" "$PROJECTS_FILE"
}

unregister_project() {
    local path="$1" tmp
    [ -f "$PROJECTS_FILE" ] || return 0
    tmp="$(mktemp)"
    jq --arg path "$path" '.projects = [.projects[] | select(.path != $path)]' \
        "$PROJECTS_FILE" > "$tmp" && mv "$tmp" "$PROJECTS_FILE"
}

list_projects() {
    projects_file_init
    jq . "$PROJECTS_FILE"
}

init_planned_files() {
    local only_rules="$1" only_frugality="$2"
    if [ "$only_frugality" != "true" ]; then
        caveman_targets | cut -f2
        phasezero_targets | cut -f2
    fi
    if [ "$only_rules" != "true" ]; then
        printf '%s\n' \
            "$WORKSPACE_ROOT/.codex/context-packs/ai-context-frugality.md" \
            "$WORKSPACE_ROOT/.codex/ai-context/frugality-manifest.json" \
            "$WORKSPACE_ROOT/.codex/ai-context/repo-skeleton.json" \
            "$WORKSPACE_ROOT/.codex/ai-context/repo-skeleton.md" \
            "$WORKSPACE_ROOT/.aiderignore"
    fi
    if [ "$only_rules" != "true" ] && [ "$only_frugality" != "true" ]; then
        printf '%s\n' "$WORKSPACE_ROOT/.vscode/extensions.json"
    fi
}

init_status() {
    local target="$1" ponytail=false frugality=false initialized=false
    local record record_ponytail hash match=null rule_json
    WORKSPACE_ROOT="$target"
    [ -d "$target/.zcode/rules" ] && export PZ_INIT_ZCODE=1
    is_ponytail_workspace "$target" && ponytail=true
    rule_json="$(rule_records | jq -s .)"
    frugality_configured && frugality=true
    jq -e 'all(.[]; .caveman == true and .phasezeroTools == true)' <<< "$rule_json" >/dev/null && initialized=true
    projects_file_init
    record="$(jq -c --arg path "$target" '[.projects[] | select(.path == $path)] | first // null' "$PROJECTS_FILE")"
    record_ponytail="$(jq -r 'if type == "object" then (.ponytail | tostring) else empty end' <<< "$record")"
    case "$record_ponytail" in true|false) ;; *) record_ponytail="$ponytail" ;; esac
    hash="$(rules_source_hash "$record_ponytail")"
    if [ "$record" != "null" ]; then
        if [ "$(jq -r '.rulesHash // ""' <<< "$record")" = "$hash" ]; then match=true; else match=false; fi
    fi
    jq -cn \
        --arg path "$target" \
        --arg sourceHash "$hash" \
        --argjson rules "$rule_json" \
        --argjson record "$record" \
        --argjson initialized "$(bool_json "$initialized")" \
        --argjson frugality "$(bool_json "$frugality")" \
        --argjson ponytail "$(bool_json "$ponytail")" \
        --argjson rulesHashMatch "$match" \
        '{schemaVersion:1,action:"init-status",path:$path,initialized:$initialized,frugalityConfigured:$frugality,ponytailDetected:$ponytail,sourceRulesHash:$sourceHash,rulesHashMatch:$rulesHashMatch,registered:($record != null),record:$record,rules:$rules}'
}

init_undo_target() {
    local path="$1" base
    [ -e "$path" ] || return 0
    base="$(basename "$path")"
    case "$base" in
        caveman.*|phasezero-tools.*)
            backup_managed_file "$path"
            rm -f "$path"
            pz_info "removed $path"
            ;;
        *)
            remove_marked_block "$path" "BOOTSTRAP CAVEMAN"
            remove_marked_block "$path" "PHASEZERO TOOLS"
            remove_marked_block "$path" "PONYTAIL ARCHITECTURE"
            ;;
    esac
}

init_undo() {
    local target="$1" id path header dir
    WORKSPACE_ROOT="$target"
    [ -d "$target/.zcode/rules" ] && export PZ_INIT_ZCODE=1
    while IFS=$'\t' read -r id path header; do
        [ -n "$path" ] || continue
        init_undo_target "$path"
    done < <(caveman_targets; phasezero_targets)
    remove_marked_block "$target/.aiderignore" "PHASEZERO AI CONTEXT FRUGALITY" "hash"
    rm -f \
        "$target/.codex/context-packs/ai-context-frugality.md" \
        "$target/.codex/context-packs/ai-context-frugality.md.bak."* \
        "$target/.codex/ai-context/frugality-manifest.json" \
        "$target/.codex/ai-context/repo-skeleton.json" \
        "$target/.codex/ai-context/repo-skeleton.md"
    for dir in \
        "$target/.codex/context-packs" "$target/.codex/ai-context" "$target/.codex" \
        "$target/.cursor/rules" "$target/.cursor" \
        "$target/.windsurf/rules" "$target/.windsurf" \
        "$target/.clinerules" "$target/.zcode/rules" "$target/.zcode"; do
        if [ -d "$dir" ]; then
            rmdir --ignore-fail-on-non-empty "$dir" 2>/dev/null
        fi
    done
    unregister_project "$target"
    jq -cn --arg path "$target" \
        '{schemaVersion:1,action:"init-undo",path:$path,removed:true,note:"managed blocks removed; fully-managed rule files deleted; .vscode/extensions.json kept (merged with user content)"}'
}

init_usage() {
    cat >&2 <<'EOF'
usage: setup-agent-compat.sh init [--dry-run] [--force] [--zcode] [--only-rules|--only-frugality] [<project-dir>]
       setup-agent-compat.sh init --status [<project-dir>]
       setup-agent-compat.sh init --register-existing [<project-dir>]
       setup-agent-compat.sh init --list
       setup-agent-compat.sh init --undo [<project-dir>]
EOF
}

cmd_init() {
    local target="" mode="apply" arg
    local dry_run=false force=false zcode=false only_rules=false only_frugality=false
    for arg in "$@"; do
        case "$arg" in
            --dry-run|-n) dry_run=true ;;
            --force) force=true ;;
            --zcode) zcode=true ;;
            --only-rules) only_rules=true ;;
            --only-frugality) only_frugality=true ;;
            --status) mode="status" ;;
            --register-existing) mode="register-existing" ;;
            --list) mode="list" ;;
            --undo) mode="undo" ;;
            --help|-h) init_usage; return 0 ;;
            -*) pz_error "unknown init flag: $arg"; init_usage; return 2 ;;
            *) target="$arg" ;;
        esac
    done
    if [ "$mode" = "list" ]; then
        list_projects
        return 0
    fi
    target="${target:-$PWD}"
    target="$(realpath -m "$target" 2>/dev/null || printf '%s' "$target")"
    [ -d "$target" ] || { pz_error "not a directory: $target"; return 1; }
    case "$mode" in
        status) init_status "$target"; return $? ;;
        undo) init_undo "$target"; return $? ;;
        register-existing)
            WORKSPACE_ROOT="$target"
            local existing_rules ponytail_existing=false existing_hash
            existing_rules="$(rule_records | jq -s .)"
            if ! jq -e 'length > 0 and all(.[]; .caveman == true and .phasezeroTools == true)' <<< "$existing_rules" >/dev/null; then
                pz_error "managed Caveman/PhaseZero rules are incomplete in $target"
                return 1
            fi
            is_ponytail_workspace "$target" && ponytail_existing=true
            existing_hash="$(rules_source_hash "$ponytail_existing")"
            register_project "$target" "$ponytail_existing" false "$existing_hash" true
            jq -cn --arg path "$target" --arg hash "$existing_hash" \
                '{schemaVersion:1,action:"register-existing",path:$path,status:"ready",rulesHash:$hash,modifiedProjectFiles:false}'
            return 0
            ;;
    esac
    if [ "$only_rules" = "true" ] && [ "$only_frugality" = "true" ]; then
        pz_error "--only-rules and --only-frugality are mutually exclusive"
        return 2
    fi
    case "$target" in
        /|"$HOME") pz_error "refusing to inject agent rules at $target"; return 1 ;;
    esac
    [ -w "$target" ] || { pz_error "directory not writable: $target"; return 1; }
    [ "$zcode" = "true" ] && export PZ_INIT_ZCODE=1
    WORKSPACE_ROOT="$target"

    local ponytail=false
    if is_ponytail_workspace "$target" || [ "${PZ_PONYTAIL_FORCE:-0}" = "1" ]; then
        ponytail=true
    fi
    local hash
    hash="$(rules_source_hash "$ponytail")"

    if [ "$dry_run" = "true" ]; then
        init_planned_files "$only_rules" "$only_frugality" | sort -u | jq -R . | jq -cs \
            --arg path "$target" --arg hash "$hash" \
            --argjson ponytail "$(bool_json "$ponytail")" \
            --argjson zcode "$(bool_json "$zcode")" \
            '{schemaVersion:1,action:"init",dryRun:true,path:$path,ponytail:$ponytail,zcode:$zcode,sourceRulesHash:$hash,plannedFiles:.}'
        return 0
    fi

    if [ "$force" != "true" ] && [ "$only_frugality" != "true" ] &&
        [ -f "$target/AGENTS.md" ] && grep -q 'BEGIN PHASEZERO TOOLS' "$target/AGENTS.md"; then
        pz_warn "project already initialized: $target (use --force to refresh)"
        jq -cn --arg path "$target" \
            '{schemaVersion:1,action:"init",path:$path,status:"already-initialized",hint:"re-run with --force to refresh managed blocks"}'
        return 3
    fi

    local wrote_rules=false wrote_frugality=false wrote_vscode=false
    if [ "$only_frugality" != "true" ]; then
        apply_rules
        wrote_rules=true
    fi
    if [ "$only_rules" != "true" ]; then
        apply_frugality_pack
        wrote_frugality=true
    fi
    if [ "$only_rules" != "true" ] && [ "$only_frugality" != "true" ]; then
        if PZ_WORKSPACE_ROOT="$target" bash "$PZ_ROOT/linux/ai/setup-ides.sh" recommendations >/dev/null; then
            wrote_vscode=true
        else
            pz_warn "vscode workspace recommendations skipped"
        fi
    fi
    register_project "$target" "$ponytail" "$zcode" "$hash" "$wrote_rules"
    jq -cn \
        --arg path "$target" --arg hash "$hash" --arg projectsFile "$PROJECTS_FILE" \
        --argjson ponytail "$(bool_json "$ponytail")" \
        --argjson zcode "$(bool_json "$zcode")" \
        --argjson rules "$(bool_json "$wrote_rules")" \
        --argjson frugality "$(bool_json "$wrote_frugality")" \
        --argjson vscode "$(bool_json "$wrote_vscode")" \
        '{schemaVersion:1,action:"init",path:$path,status:"ready",wrote:{rules:$rules,frugality:$frugality,vscodeRecommendations:$vscode},ponytail:$ponytail,zcode:$zcode,rulesHash:$hash,projectsFile:$projectsFile}'
}

setup_all() {
    install_rtk_fallback
    configure_rtk
    install_headroom || true
    bash "$PZ_ROOT/linux/ai/setup-memory.sh" setup >/dev/null || pz_warn "ai-memory setup skipped/failed"
    if [ -z "$WORKSPACE_ROOT" ]; then
        WORKSPACE_ROOT="$(registered_workspace_root || true)"
    fi
    if [ -n "$WORKSPACE_ROOT" ]; then
        apply_rules
        apply_frugality_pack
    else
        pz_warn "no registered project; global tools configured, project rules unchanged"
    fi
    write_state
    status_json
}

case "${1:-setup}" in
    setup|install|configure) setup_all ;;
    status) status_json ;;
    dry-run|plan) dry_run ;;
    install-rtk|rtk)
        install_rtk_fallback
        configure_rtk
        status_json | jq '.tools.rtk'
        ;;
    headroom|install-headroom)
        install_headroom
        status_json | jq '.tools.headroom'
        ;;
    rules|caveman)
        [ -n "$WORKSPACE_ROOT" ] || WORKSPACE_ROOT="$(registered_workspace_root || true)"
        if [ -z "$WORKSPACE_ROOT" ]; then
            jq -cn '{mode:"needs-project",rules:[],summary:"Nenhum projeto registrado para receber as regras.",next:"linux/pz ai init <pasta-do-projeto>"}'
            exit 2
        fi
        apply_rules
        write_state
        status_json | jq '{mode,rules,tools:{caveman:.tools.caveman,ponytail:.tools.ponytail}}'
        ;;
    frugality|context-frugality)
        apply_frugality_pack
        status_json | jq '.tools.aiContextFrugality'
        ;;
    rtk-init)
        configure_rtk
        ;;
    init|initialize|bootstrap)
        shift
        cmd_init "$@"
        ;;
    *) echo "usage: setup-agent-compat.sh (setup|status|dry-run|install-rtk|headroom|rules|frugality|rtk-init|init)" >&2; exit 1 ;;
esac
