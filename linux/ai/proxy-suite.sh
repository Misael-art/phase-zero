#!/usr/bin/env bash
# Portable Linux installer/manager for PhaseZero AI proxy repositories.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
TARGET="${2:-all}"
ENSURE_DRY_RUN=0
case "$ACTION" in
    ensure|use|prepare)
        for _ensure_arg in "${@:3}"; do
            [ "$_ensure_arg" = "--dry-run" ] && ENSURE_DRY_RUN=1
        done
        if [ "$TARGET" = "--dry-run" ]; then
            TARGET="${3:-all}"
            ENSURE_DRY_RUN=1
            [ "$TARGET" = "--dry-run" ] && TARGET=all
        fi
        ;;
esac
ROOT="${PZ_AI_PROXY_ROOT:-$HOME/.local/share/phasezero/ai-proxies}"
BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
RUNTIME="$ROOT/.runtime/node24"
NODE_BIN="$RUNTIME/node_modules/node/bin/node"
NPM_CLI="$RUNTIME/node_modules/npm/bin/npm-cli.js"
PATCH_STATE_DIR="$ROOT/.phasezero-state"
TRUSTED_SOURCES_FILE="${PZ_AI_PROXY_TRUSTED_SOURCES_FILE:-$PZ_ROOT/assets/ai/proxy-suite-trusted-sources.json}"

# Ports mirror the Windows catalog (3010-3013) to avoid colliding with common
# local services: open-webui/grafana default to :3000 and uptime-kuma (homelab)
# to :3001, so the older 3000/3001 assignment made kimi/qwen fail with EADDRINUSE.
proxy_rows() {
    cat <<'EOF'
kimiproxy|https://github.com/pedrofariasx/kimiproxy.git|3010|node
qwen-worker-proxy|https://github.com/aptdnfapt/qwen-worker-proxy.git|0|worker
qwenproxy|https://github.com/pedrofariasx/qwenproxy.git|3011|node
antigravity-proxy|https://github.com/pedrofariasx/antigravity-proxy.git|8090|node
antigravity-openai-adapter|https://github.com/pedrofariasx/antigravity-openai-adapter.git|8081|node
ollieproxy|https://github.com/pedrofariasx/ollieproxy.git|3002|node
airlock|https://github.com/pedrofariasx/airlock.git|0|library
unlimited-ai-proxy|https://github.com/pedrofariasx/unlimited-ai-proxy.git|8787|node
deepsproxy|https://github.com/pedrofariasx/deepsproxy.git|3012|node
mimo-ai-proxy|https://github.com/pedrofariasx/mimo-ai-proxy.git|3013|go
9router|https://github.com/decolua/9router.git|20128|npm
EOF
}

# PZ-AUD-018: one supported set for every aggregate action. install all,
# ensure all and start all operate on exactly these; anything else is
# experimental (explicit id only) or externally managed (9router).
SUPPORTED_PROXY_IDS="kimiproxy qwenproxy deepsproxy mimo-ai-proxy"

connection_grant_blocked() {
    printf '%s\n' '{"schemaVersion":1,"ok":false,"ready":false,"completed":false,
      "resumable":true,"status":"blocked","blockedReason":"connection-grant-not-enforceable",
      "summary":"Uso bloqueado: este proxy não vincula cada requisição a uma conta e consumidor autorizados.",
      "next":"Mantenha consumidores desligados até existir adaptador que aplique o grant por requisição e rejeite fallback.",
      "needsUser":"none"}'
}

proxy_tier() {
    case " $SUPPORTED_PROXY_IDS " in
        *" $1 "*) printf 'supported\n' ;;
        *) [ "$1" = 9router ] && printf 'external-manager\n' || printf 'experimental\n' ;;
    esac
}

supported_rows() {
    local id
    for id in $SUPPORTED_PROXY_IDS; do
        lookup_proxy_row "$id"
    done
}

MANIFEST_FILE="${PZ_AI_PROXY_MANIFEST_FILE:-$PZ_ROOT/assets/ai/proxy-manifest.json}"

manifest_check_json() {
    # PZ-AUD-019: the manifest is the cross-OS contract; Linux rows, IDE
    # rows and approved snapshots must agree with it (repo, pin, port,
    # runtime, default model). Prints {ok, checks[]}.
    local manifest="$MANIFEST_FILE" fail=0
    local -a reasons=()
    [ -f "$manifest" ] || { pz_error "proxy manifest missing: $manifest"; return 2; }
    local id repo port kind pin mrepo mport mruntime mmodel mcommit
    while IFS='|' read -r id repo port kind; do
        [ -n "$id" ] || continue
        [ "$(proxy_tier "$id")" = supported ] || continue
        mrepo="$(jq -r --arg i "$id" '.proxies[] | select(.id == $i) | .repository // empty' "$manifest")"
        mport="$(jq -r --arg i "$id" '.proxies[] | select(.id == $i) | .port // empty' "$manifest")"
        mcommit="$(jq -r --arg i "$id" '.proxies[] | select(.id == $i) | .pin.commit // empty' "$manifest")"
        mruntime="$(jq -r --arg i "$id" '.proxies[] | select(.id == $i) | .runtime // empty' "$manifest")"
        mmodel="$(jq -r --arg i "$id" '.proxies[] | select(.id == $i) | .defaultModel // empty' "$manifest")"
        [ -z "$mrepo" ] && { reasons+=("$id: missing from manifest"); fail=1; continue; }
        [ "$mrepo" = "$repo" ] || { reasons+=("$id: repo drift (manifest=$mrepo catalog=$repo)"); fail=1; }
        [ "$mport" = "$port" ] || { reasons+=("$id: port drift (manifest=$mport catalog=$port)"); fail=1; }
        if [ "$id" != "mimo-ai-proxy" ]; then
            [ "$mruntime" = "$kind" ] || { reasons+=("$id: runtime drift (manifest=$mruntime catalog=$kind)"); fail=1; }
        fi
        pin="$(trusted_source_record "$id" 2>/dev/null | jq -r '.commit // empty' || true)"
        if [ -n "$mcommit" ] && [ -n "$pin" ] && [ "$mcommit" != "$pin" ]; then
            reasons+=("$id: pin drift (manifest=$mcommit snapshot=$pin)")
            fail=1
        fi
        [ -n "$mmodel" ] || { reasons+=("$id: manifest missing defaultModel"); fail=1; }
    done < <(supported_rows)
    local out
    out="$(jq -cn --argjson ok "$([ "$fail" -eq 0 ] && echo true || echo false)" \
        --argjson checks "$(printf '%s\n' "${reasons[@]}" | jq -R . | jq -cs 'map(select(length > 0))')" \
        '{schemaVersion:1, action:"manifest-check", ok:$ok, checks:$checks}')"
    printf '%s\n' "$out"
    [ "$fail" -eq 0 ]
}

selected_rows() {
    if [ "$TARGET" = all ]; then supported_rows; else proxy_rows | awk -F'|' -v id="$TARGET" '$1 == id'; fi
}

inventory_rows() {
    # Reporting scope: the whole universe for `all`, the single row for an
    # explicit id. Action scope (selected_rows) is narrower by design.
    if [ "$TARGET" = all ]; then proxy_rows; else proxy_rows | awk -F'|' -v id="$TARGET" '$1 == id'; fi
}

ensure_node_runtime() {
    local system_npm system_node
    system_npm="$(command -v npm || true)"
    system_node="$(command -v node || true)"
    [ -n "$system_npm" ] || { pz_error "npm required"; return 1; }
    if [ ! -x "$NODE_BIN" ] || [ ! -f "$NPM_CLI" ]; then
        pz_info "Installing isolated Node.js 24 runtime for proxy compatibility"
        install -d "$RUNTIME"
        # npm 11+/12 blocks the node package preinstall (downloads the real binary)
        # unless allowScripts lists it. A local package.json is required for
        # `npm install-scripts approve`.
        if [ ! -f "$RUNTIME/package.json" ]; then
            printf '%s\n' '{"private":true,"name":"phasezero-proxy-node24"}' > "$RUNTIME/package.json"
        fi
        (
            cd "$RUNTIME"
            "$system_npm" install --no-save --foreground-scripts "node@24" "npm@10" || true
            if [ ! -x "$NODE_BIN" ] && "$system_npm" install-scripts approve node >/dev/null 2>&1; then
                "$system_npm" install --no-save --foreground-scripts "node@24" "npm@10"
            fi
        )
    fi
    if [ ! -x "$NODE_BIN" ]; then
        if [ -n "$system_node" ]; then
            pz_warn "isolated Node 24 binary missing; falling back to system node $($system_node --version)"
            NODE_BIN="$system_node"
            NPM_CLI="$system_npm"
        else
            pz_error "isolated Node 24 failed to install (npm allowScripts blocked node@24 preinstall)"
            return 1
        fi
    fi
    install -d "$RUNTIME/bin"
    ln -sfn "$NODE_BIN" "$RUNTIME/bin/node"
    pz_info "Proxy runtime: Node $("$NODE_BIN" --version), npm $("$NODE_BIN" "$NPM_CLI" --version 2>/dev/null || "$system_npm" --version)"
}

run_npm() {
    local dir="$1"
    shift
    if [ -n "${NPM_CLI:-}" ] && [ -f "$NPM_CLI" ]; then
        (cd "$dir" && PATH="$RUNTIME/bin:$PATH" "$NODE_BIN" "$NPM_CLI" "$@")
    else
        (cd "$dir" && PATH="$RUNTIME/bin:$PATH" npm "$@")
    fi
}

# Parse dotenv as data. Never source it: a credential file must not execute shell.
load_proxy_env() {
    local file="$1" line key value
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            echo "invalid dotenv line in $file (expected NAME=value)" >&2
            return 2
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" == \"*\" && "$value" == *\" ]] ||
           [[ "$value" == \'*\' && "$value" == *\' ]]; then
            value="${value:1:${#value}-2}"
        fi
        case "$key" in
            PATH|IFS|CDPATH|ENV|BASH_ENV|SHELLOPTS|BASHOPTS|GLOBIGNORE|LD_*|DYLD_*|PYTHONPATH|PERL5OPT|RUBYOPT|NODE_OPTIONS)
                echo "unsafe dotenv variable rejected in $file: $key" >&2
                return 2
                ;;
        esac
        export "${key?}=$value"
    done < "$file"
}

managed_patch_file() {
    case "$1" in
        kimiproxy|deepsproxy) printf '%s\n' 'src/index.ts' ;;
        mimo-ai-proxy) printf '%s\n' 'main.go' ;;
        *) return 1 ;;
    esac
}

restore_managed_loopback_patch() {
    local id="$1" dir="$2" rel state file backup actual patched baseline backup_hash
    rel="$(managed_patch_file "$id" 2>/dev/null || true)"
    [ -n "$rel" ] || return 0
    state="$PATCH_STATE_DIR/$id.json"
    backup="$PATCH_STATE_DIR/$id.original"
    file="$dir/$rel"
    [ -f "$state" ] && [ -f "$file" ] && [ -f "$backup" ] || return 0
    actual="$(sha256sum "$file" | awk '{print $1}')"
    patched="$(jq -r '.patchedSha256 // empty' "$state" 2>/dev/null || true)"
    baseline="$(jq -r '.baselineSha256 // empty' "$state" 2>/dev/null || true)"
    backup_hash="$(sha256sum "$backup" | awk '{print $1}')"
    if [ -n "$patched" ] && [ "$actual" = "$patched" ] &&
       [ -n "$baseline" ] && [ "$backup_hash" = "$baseline" ]; then
        cp -p -- "$backup" "$file"
        rm -f -- "$state" "$backup"
        pz_info "restored managed loopback patch before update: $id"
    else
        pz_warn "managed proxy source changed after loopback patch; preserving local edits: $id/$rel"
    fi
}

apply_loopback_patch() {
    local id="$1" dir="$2" file rel baseline patched state backup
    case "$id" in
        kimiproxy|deepsproxy)
            rel="src/index.ts"
            file="$dir/$rel"
            [ -f "$file" ] || { pz_error "loopback patch target missing: $id/$rel"; return 1; }
            if grep -q 'process.env.PZ_BIND_HOST' "$file"; then return 0; fi
            if grep -Eq 'hostname:.*(process\.env\.(HOST|BIND_HOST)|127\.0\.0\.1)' "$file"; then
                pz_info "upstream already has configurable loopback bind: $id"
                return 0
            fi
            baseline="$(sha256sum "$file" | awk '{print $1}')"
            install -d "$PATCH_STATE_DIR"
            backup="$PATCH_STATE_DIR/$id.original"
            cp -p -- "$file" "$backup"
            perl -0pi -e 's/serve\(\{\s*fetch: app\.fetch,\s*port\s*\}\);/serve({\n      fetch: app.fetch,\n      port,\n      hostname: process.env.PZ_BIND_HOST || process.env.HOST || "127.0.0.1"\n    });/g' "$file"
            grep -q 'process.env.PZ_BIND_HOST' "$file" || { pz_error "loopback patch no longer matches upstream: $id"; return 1; }
            ;;
        mimo-ai-proxy)
            rel="main.go"
            file="$dir/$rel"
            [ -f "$file" ] || { pz_error "loopback patch target missing: $id/$rel"; return 1; }
            if grep -q 'PZ_BIND_HOST' "$file"; then return 0; fi
            baseline="$(sha256sum "$file" | awk '{print $1}')"
            install -d "$PATCH_STATE_DIR"
            backup="$PATCH_STATE_DIR/$id.original"
            cp -p -- "$file" "$backup"
            perl -0pi -e 's|// For Docker environments, it'"'"'s safer to bind to 0\.0\.0\.0 explicitly\s*\n\s*address := "0\.0\.0\.0:" \+ port|host := os.Getenv("PZ_BIND_HOST")\n\tif host == "" {\n\t\thost = os.Getenv("HOST")\n\t}\n\tif host == "" {\n\t\thost = "127.0.0.1"\n\t}\n\taddress := host + ":" + port|s' "$file"
            grep -q 'PZ_BIND_HOST' "$file" || { pz_error "loopback patch no longer matches upstream: $id"; return 1; }
            ;;
        *) return 0 ;;
    esac
    patched="$(sha256sum "$file" | awk '{print $1}')"
    state="$PATCH_STATE_DIR/$id.json"
    jq -n --arg id "$id" --arg file "$rel" --arg baselineSha256 "$baseline" \
        --arg patchedSha256 "$patched" --arg appliedAt "$(date -Iseconds)" \
        '{schemaVersion:1,id:$id,file:$file,baselineSha256:$baselineSha256,patchedSha256:$patchedSha256,appliedAt:$appliedAt}' \
        > "$state"
    pz_info "loopback bind patch applied: $id"
}

trusted_manifest_valid() {
    [ -f "$TRUSTED_SOURCES_FILE" ] || return 1
    jq -e '
      .schemaVersion == 1 and
      .trustMode == "snapshot-pin" and
      .semanticAudit == false and
      (.sources | type == "array" and length > 0) and
      (([.sources[].id] | unique | length) == (.sources | length)) and
      all(.sources[];
        (.id | type == "string" and length > 0) and
        (.repository | type == "string" and length > 0) and
        (.commit | test("^[0-9a-f]{40}$")) and
        (.tree | test("^[0-9a-f]{40}$")) and
        (.approvedForInstall == true) and
        (.license.path | test("^(?!/)(?!.*(^|/)\\.\\.(/|$)).+$")) and
        (.license.sha256 | test("^[0-9a-f]{64}$")) and
        all(.dependencyLocks[];
          (.path | test("^(?!/)(?!.*(^|/)\\.\\.(/|$)).+$")) and
          (.sha256 | test("^[0-9a-f]{64}$")))
      )
    ' "$TRUSTED_SOURCES_FILE" >/dev/null 2>&1
}

trusted_source_record() {
    local id="$1"
    trusted_manifest_valid || return 1
    jq -ce --arg id "$id" '.sources[] | select(.id == $id and .approvedForInstall == true)' \
        "$TRUSTED_SOURCES_FILE" 2>/dev/null
}

source_material_valid() {
    local dir="$1" record="$2" rel expected actual encoded
    rel="$(jq -r '.license.path' <<< "$record")"
    expected="$(jq -r '.license.sha256' <<< "$record")"
    [ -f "$dir/$rel" ] || return 1
    actual="$(sha256sum "$dir/$rel" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || return 1
    while IFS= read -r encoded; do
        [ -n "$encoded" ] || continue
        rel="$(base64 -d <<< "$encoded" | jq -r '.path')"
        expected="$(base64 -d <<< "$encoded" | jq -r '.sha256')"
        [ -f "$dir/$rel" ] || return 1
        actual="$(sha256sum "$dir/$rel" | awk '{print $1}')"
        [ "$actual" = "$expected" ] || return 1
    done < <(jq -r '.dependencyLocks[] | @base64' <<< "$record")
}

managed_worktree_valid() {
    local id="$1" dir="$2" rel state backup actual patched baseline backup_hash git_baseline changes
    changes="$(git -C "$dir" status --porcelain --untracked-files=all 2>/dev/null || true)"
    if [ "$id" = mimo-ai-proxy ]; then
        changes="$(printf '%s\n' "$changes" | grep -vFx '?? .phasezero-bin/mimo-ai-proxy' || true)"
    fi
    [ -z "$changes" ] && return 0
    rel="$(managed_patch_file "$id" 2>/dev/null || true)"
    [ -n "$rel" ] || return 1
    [ "$changes" = " M $rel" ] || return 1
    state="$PATCH_STATE_DIR/$id.json"
    backup="$PATCH_STATE_DIR/$id.original"
    [ -f "$state" ] && [ -f "$backup" ] && [ -f "$dir/$rel" ] || return 1
    [ "$(jq -r '.id // empty' "$state" 2>/dev/null)" = "$id" ] || return 1
    [ "$(jq -r '.file // empty' "$state" 2>/dev/null)" = "$rel" ] || return 1
    actual="$(sha256sum "$dir/$rel" | awk '{print $1}')"
    patched="$(jq -r '.patchedSha256 // empty' "$state" 2>/dev/null)"
    baseline="$(jq -r '.baselineSha256 // empty' "$state" 2>/dev/null)"
    backup_hash="$(sha256sum "$backup" | awk '{print $1}')"
    git_baseline="$(git -C "$dir" show "HEAD:$rel" | sha256sum | awk '{print $1}')"
    [ -n "$patched" ] && [ "$actual" = "$patched" ] &&
        [ -n "$baseline" ] && [ "$backup_hash" = "$baseline" ] &&
        [ "$git_baseline" = "$baseline" ]
}

provenance_json_one() {
    local id="$1" dir="$ROOT/$1" record="" expected_repo="" expected_commit="" expected_tree=""
    local actual_repo="" actual_commit="" actual_tree="" reason="snapshot aprovado e íntegro"
    local installed=false approved=false manifest_valid=false origin_match=false commit_match=false tree_match=false
    local materials_valid=false worktree_valid=false ready=false
    if trusted_manifest_valid; then manifest_valid=true; fi
    record="$(trusted_source_record "$id" 2>/dev/null || true)"
    if [ -n "$record" ]; then
        approved=true
        expected_repo="$(jq -r '.repository' <<< "$record")"
        expected_commit="$(jq -r '.commit' <<< "$record")"
        expected_tree="$(jq -r '.tree' <<< "$record")"
    else
        reason="fonte sem snapshot aprovado"
    fi
    if [ -d "$dir/.git" ] && git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        installed=true
        actual_repo="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
        actual_commit="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
        actual_tree="$(git -C "$dir" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
    elif [ -e "$dir" ]; then
        installed=true
        reason="instalação não é um checkout Git válido"
    else
        reason="ainda não instalado"
    fi
    if [ "$approved" = true ] && [ "$installed" = true ]; then
        [ "$actual_repo" = "$expected_repo" ] && origin_match=true
        [ "$actual_commit" = "$expected_commit" ] && commit_match=true
        [ "$actual_tree" = "$expected_tree" ] && tree_match=true
        source_material_valid "$dir" "$record" && materials_valid=true
        managed_worktree_valid "$id" "$dir" && worktree_valid=true
        if [ "$origin_match" = true ] && [ "$commit_match" = true ] && [ "$tree_match" = true ] &&
           [ "$materials_valid" = true ] && [ "$worktree_valid" = true ]; then
            ready=true
        elif [ "$origin_match" != true ]; then reason="origem Git diverge do snapshot aprovado"
        elif [ "$commit_match" != true ] || [ "$tree_match" != true ]; then reason="commit Git diverge do snapshot aprovado"
        elif [ "$materials_valid" != true ]; then reason="licença ou lockfile diverge do snapshot aprovado"
        else reason="arquivos locais não gerenciados alteram o snapshot"
        fi
    fi
    jq -nc --arg id "$id" --arg mode "snapshot-pin" --arg reason "$reason" \
        --arg manifest "$TRUSTED_SOURCES_FILE" --arg expectedRepository "$expected_repo" \
        --arg actualRepository "$actual_repo" --arg expectedCommit "$expected_commit" \
        --arg actualCommit "$actual_commit" --arg expectedTree "$expected_tree" --arg actualTree "$actual_tree" \
        --argjson semanticAudit false --argjson installed "$installed" --argjson approved "$approved" \
        --argjson manifestValid "$manifest_valid" --argjson originMatch "$origin_match" \
        --argjson commitMatch "$commit_match" --argjson treeMatch "$tree_match" \
        --argjson materialsValid "$materials_valid" --argjson managedWorktreeValid "$worktree_valid" \
        --argjson ready "$ready" \
        '{id:$id,trustMode:$mode,semanticAudit:$semanticAudit,installed:$installed,approvedForInstall:$approved,
          manifestValid:$manifestValid,originMatch:$originMatch,commitMatch:$commitMatch,treeMatch:$treeMatch,
          materialsValid:$materialsValid,managedWorktreeValid:$managedWorktreeValid,ready:$ready,reason:$reason,
          manifest:$manifest,expected:{repository:$expectedRepository,commit:$expectedCommit,tree:$expectedTree},
          actual:{repository:$actualRepository,commit:$actualCommit,tree:$actualTree}}'
}

provenance_ready() {
    provenance_json_one "$1" | jq -e '.ready == true' >/dev/null
}

provenance_status_json() {
    local id first=true item ready_count=0 approved_count=0 installed_count=0 invalid_installed=0 total=0 all_ready=true ids=()
    if [ "$TARGET" = all ]; then
        # shellcheck disable=SC2206
        ids=($SUPPORTED_PROXY_IDS)
    else
        ids=("$TARGET")
    fi
    printf '{"schemaVersion":1,"trustMode":"snapshot-pin","semanticAudit":false,"sources":['
    for id in "${ids[@]}"; do
        item="$(provenance_json_one "$id")"
        $first || printf ','
        first=false
        printf '%s' "$item"
        total=$((total + 1))
        jq -e '.approvedForInstall == true' <<< "$item" >/dev/null && approved_count=$((approved_count + 1))
        if jq -e '.installed == true' <<< "$item" >/dev/null; then
            installed_count=$((installed_count + 1))
            jq -e '.ready == true' <<< "$item" >/dev/null || invalid_installed=$((invalid_installed + 1))
        fi
        if jq -e '.ready == true' <<< "$item" >/dev/null; then
            ready_count=$((ready_count + 1))
        else
            all_ready=false
        fi
    done
    printf '],"summary":{"total":%d,"approved":%d,"installed":%d,"ready":%d,"invalidInstalled":%d,"allReady":%s}}\n' \
        "$total" "$approved_count" "$installed_count" "$ready_count" "$invalid_installed" "$all_ready"
}

clone_approved_snapshot() {
    local id="$1" repo="$2" dir="$3" record expected_commit stage
    record="$(trusted_source_record "$id" 2>/dev/null || true)"
    [ -n "$record" ] || { pz_error "blocked: no approved snapshot for $id"; return 69; }
    [ "$(jq -r '.repository' <<< "$record")" = "$repo" ] || {
        pz_error "blocked: catalog repository differs from approved snapshot for $id"
        return 69
    }
    expected_commit="$(jq -r '.commit' <<< "$record")"
    stage="$(mktemp -d "$ROOT/.stage-$id.XXXXXX")"
    if ! git -C "$stage" init -q ||
       ! git -C "$stage" remote add origin "$repo" ||
       ! git -C "$stage" fetch -q --depth=1 origin "$expected_commit" ||
       ! git -C "$stage" checkout -q --detach FETCH_HEAD ||
       [ "$(git -C "$stage" rev-parse HEAD 2>/dev/null || true)" != "$expected_commit" ] ||
       ! source_material_valid "$stage" "$record" ||
       [ "$(git -C "$stage" rev-parse 'HEAD^{tree}' 2>/dev/null || true)" != "$(jq -r '.tree' <<< "$record")" ]; then
        rm -rf -- "$stage"
        pz_error "blocked: fetched snapshot failed provenance checks for $id"
        return 69
    fi
    git -C "$stage" remote set-url --push origin DISABLED
    mv -- "$stage" "$dir"
}

verify_proxy_artifacts() {
    # PZ-AUD-016/017: no launcher may point at a missing binary, and no
    # "installed" record may exist without runnable artifacts.
    local id="$1" kind="$2" dir="$3"
    case "$kind" in
        node|worker|library)
            [ -f "$dir/package.json" ] || { pz_error "$id: package.json missing after build"; return 1; }
            if [ "$kind" = node ] && jq -er '.scripts.start // ""' "$dir/package.json" 2>/dev/null | grep -q 'dist/'; then
                [ -d "$dir/dist" ] || { pz_error "$id: dist/ missing (build did not emit it)"; return 1; }
            fi
            ;;
        go)
            [ -x "$dir/.phasezero-bin/$id" ] || { pz_error "$id: go binary missing after build"; return 1; }
            ;;
    esac
    return 0
}

verify_playwright_chromium() {
    # PZ-AUD-016: the browser binary must actually launch; a bare download
    # without OS libs is a deferred failure, not a success.
    local id="$1" dir="$2"
    local chromium
    chromium="$(find "$HOME/.cache/ms-playwright" -maxdepth 3 -name 'headless_shell' -o -maxdepth 3 -name 'chrome' 2>/dev/null | head -1)"
    [ -n "$chromium" ] || { pz_error "$id: no Playwright chromium binary after install"; return 1; }
    if ! "$chromium" --headless --no-sandbox --dump-dom about:blank >/dev/null 2>&1; then
        pz_error "$id: chromium binary present but cannot launch (missing OS libraries?). Install system deps, e.g.: pz dependencies install, then retry"
        return 1
    fi
    return 0
}

install_one() {
    local id="$1" repo="$2" port="$3" kind="$4" dir fresh_clone=false
    if [ "$id" = 9router ] && [ "$kind" = npm ]; then
        bash "$PZ_ROOT/linux/ai/9router-manager.sh" install
        return
    fi
    dir="$ROOT/$id"
    install -d "$ROOT" "$BIN" "$UNITS"
    # PZ-AUD-016: toolchains resolve BEFORE any clone/build, from every entry
    # point (install and ensure share this path).
    command -v git >/dev/null || { pz_error "git required"; return 1; }
    case "$kind" in
        node|worker|library) ensure_node_runtime || return 1 ;;
        go) command -v go >/dev/null || { pz_error "go toolchain required for $id"; return 1; } ;;
    esac
    if [ -d "$dir/.git" ]; then
        if ! provenance_ready "$id"; then
            pz_error "blocked: installed $id differs from approved snapshot; inspect 'pz ai proxies provenance $id'"
            return 69
        fi
    else
        [ ! -e "$dir" ] || { pz_error "blocked: $dir exists but is not a Git checkout"; return 69; }
        clone_approved_snapshot "$id" "$repo" "$dir" || return $?
        fresh_clone=true
    fi
    # PZ-AUD-017: every stage is explicit-checked (errexit is suppressed in
    # `if` contexts); on failure a fresh clone is removed for a clean retry.
    _proxy_fail_build() {
        pz_error "$id: build step failed: $1"
        if [ "$fresh_clone" = true ]; then
            rm -rf -- "$dir"
            pz_info "$id: removed partial clone for a clean retry"
        fi
        return 1
    }
    case "$kind" in
        node|worker|library)
            if [ -f "$dir/package-lock.json" ]; then run_npm "$dir" ci --ignore-scripts=false || return "$(_proxy_fail_build "npm ci")"
            elif [ -f "$dir/package.json" ]; then run_npm "$dir" install --ignore-scripts=false || return "$(_proxy_fail_build "npm install")"
            fi
            apply_loopback_patch "$id" "$dir" || return "$(_proxy_fail_build "loopback patch")"
            if [ "$kind" = node ] && jq -er '.scripts.start // ""' "$dir/package.json" 2>/dev/null | grep -q 'dist/'; then
                run_npm "$dir" run build || return "$(_proxy_fail_build "npm run build")"
            fi
            case "$id" in
                kimiproxy|qwenproxy|deepsproxy)
                    run_npm "$dir" exec -- playwright install chromium || return "$(_proxy_fail_build "playwright install chromium")"
                    verify_playwright_chromium "$id" "$dir" || return "$(_proxy_fail_build "chromium launch smoke")"
                    ;;
            esac
            if [ "$id" = qwenproxy ] && [ -f "$dir/web/package.json" ]; then
                # prestart runs `npm --prefix web run build` (vite). Root npm ci
                # does not install web/ node_modules, so the unit crash-loops.
                if [ -f "$dir/web/package-lock.json" ]; then
                    run_npm "$dir/web" ci --ignore-scripts=false || return "$(_proxy_fail_build "web npm ci")"
                else
                    run_npm "$dir/web" install --ignore-scripts=false || return "$(_proxy_fail_build "web npm install")"
                fi
                run_npm "$dir" run build:admin || return "$(_proxy_fail_build "npm run build:admin")"
            fi
            ;;
        go)
            apply_loopback_patch "$id" "$dir" || return "$(_proxy_fail_build "loopback patch")"
            if [ -f "$dir/go.mod" ]; then
                install -d "$dir/.phasezero-bin"
                (cd "$dir" && go build -o "$dir/.phasezero-bin/$id" .) || return "$(_proxy_fail_build "go build")"
            fi
            ;;
    esac
    verify_proxy_artifacts "$id" "$kind" "$dir" || return "$(_proxy_fail_build "artifact verification")"
    if [ "$kind" = node ] || [ "$kind" = go ]; then
        local run_command
        if [ "$kind" = node ]; then
            run_command="exec \"$NODE_BIN\" \"$NPM_CLI\" start"
        else
            run_command="exec \"$dir/.phasezero-bin/$id\""
        fi
        pz_write_managed_file "$BIN/$id" user <<EOF
#!/usr/bin/env bash
set -euo pipefail
$(declare -f load_proxy_env)
cd "$dir"
load_proxy_env "\$HOME/.config/phasezero/ai-proxies/$id.env"
export PORT="\${PORT:-$port}"
export PZ_BIND_HOST="\${PZ_BIND_HOST:-\${PHASEZERO_AI_PROXY_HOST:-127.0.0.1}}"
export HOST="\$PZ_BIND_HOST"
export BIND_HOST="\$PZ_BIND_HOST"
export PATH="$RUNTIME/bin:\$PATH"
$run_command
EOF
        chmod +x "$BIN/$id"
        pz_write_managed_file "$UNITS/phasezero-$id.service" user <<EOF
[Unit]
Description=PhaseZero $id OpenAI-compatible proxy
After=network-online.target

[Service]
Type=simple
ExecStart=$BIN/$id
Restart=on-failure
RestartSec=5
SuccessExitStatus=143 15

[Install]
WantedBy=default.target
EOF
    fi
    pz_info "AI proxy installed: $id ($kind)"
}

install_selected() {
    command -v git >/dev/null || { pz_error "git required"; return 1; }
    command -v jq >/dev/null || { pz_error "jq required"; return 1; }
    command -v sha256sum >/dev/null || { pz_error "sha256sum required"; return 1; }
    command -v perl >/dev/null || { pz_error "perl required for safe loopback patching"; return 1; }
    local id repo port kind count=0
    while IFS='|' read -r id repo port kind; do
        [ -n "$id" ] || continue
        [ "$id" = 9router ] && continue
        trusted_source_record "$id" >/dev/null 2>&1 || {
            pz_error "blocked: no approved snapshot for $id"
            return 69
        }
    done < <(selected_rows)
    ensure_node_runtime
    while IFS='|' read -r id repo port kind; do
        [ -n "$id" ] || continue
        install_one "$id" "$repo" "$port" "$kind"
        count=$((count + 1))
    done < <(selected_rows)
    [ "$count" -gt 0 ] || { pz_error "unknown proxy: $TARGET"; return 2; }
    systemctl --user daemon-reload >/dev/null 2>&1 || true
}

status_json() {
    local first=true id repo port kind dir installed service
    printf '['
    while IFS='|' read -r id repo port kind; do
        [ -n "$id" ] || continue
        dir="$ROOT/$id"; installed=false; service="not-applicable"
        if [ "$id" = 9router ]; then
            [ -x "$dir/bin/9router" ] && installed=true
        else
            [ -d "$dir/.git" ] && installed=true
        fi
        { [ "$kind" = node ] || [ "$kind" = go ] || [ "$kind" = npm ]; } &&
            service="$(unit_service_state "$id" "$port")"
        $first || printf ','
        first=false
        jq -cn --arg id "$id" --arg repo "$repo" --arg kind "$kind" --arg path "$dir" \
            --arg service "${service:-inactive}" --argjson port "$port" --argjson installed "$installed" \
            --arg tier "$(proxy_tier "$id")" \
            '{id:$id,repo:$repo,kind:$kind,path:$path,port:$port,installed:$installed,service:$service,tier:$tier}'
    done < <(inventory_rows)
    printf ']\n'
}

service_rows() {
    local mode="$1" id
    if [ "$mode" = stop ] || [ "$TARGET" != all ]; then
        selected_rows
        return
    fi
    supported_rows
}

# Older 9Router managers repointed the shared $RUNTIME/bin/node shim to the
# system Node. Proxies resolve `npx tsx` through that shim, so their Node 24
# native modules then fail to load and the unit crash-loops. Relink it to the
# isolated runtime before (re)starting; no download, no-op when already right.
repair_runtime_shim() {
    [ -x "$NODE_BIN" ] || return 0
    [ "$(readlink -f "$RUNTIME/bin/node" 2>/dev/null)" = "$(readlink -f "$NODE_BIN")" ] && return 0
    install -d "$RUNTIME/bin"
    ln -sfn "$NODE_BIN" "$RUNTIME/bin/node"
    pz_warn "proxy runtime shim repointed to isolated Node $("$NODE_BIN" --version 2>/dev/null)"
}

service_action() {
    local mode="$1" id repo port kind count=0
    case "$mode" in
        stop|disable) ;;
        *) connection_grant_blocked; return 69 ;;
    esac
    [ "$mode" = stop ] || repair_runtime_shim
    if [ "$mode" != stop ]; then
        while IFS='|' read -r id repo port kind; do
            { [ "$kind" = node ] || [ "$kind" = go ] || [ "$kind" = npm ]; } || continue
            [ "$id" = 9router ] && continue
            provenance_ready "$id" || {
                pz_error "blocked: $id is not an intact approved snapshot"
                return 69
            }
        done < <(service_rows "$mode")
    fi
    while IFS='|' read -r id repo port kind; do
        { [ "$kind" = node ] || [ "$kind" = go ] || [ "$kind" = npm ]; } || continue
        case "$mode" in
            start) systemctl --user enable --now "phasezero-$id.service" ;;
            restart) systemctl --user restart "phasezero-$id.service" ;;
            *) systemctl --user disable --now "phasezero-$id.service" ;;
        esac
        count=$((count + 1))
    done < <(service_rows "$mode")
    [ "$count" -gt 0 ] || pz_warn "no local service for $TARGET"
}

# --- IDE integration (opencode / opencode-desktop / zcode) -------------------
#
# Parity with the Windows ai-proxy-suite: expose the local proxies as selectable
# OpenAI-compatible providers in the IDEs. The proxies scrape vendor web UIs via
# Playwright, so a model only *answers* after a one-time `npm run login`; wiring
# the provider is independent of that and safe to do up front. We deliberately do
# NOT make a proxy the opencode default (that would reintroduce "Interrompido"
# until the user logs in) — the keyless Zen free default from setup-opencode.sh
# stays in charge; proxies are just selectable.
OPENCODE_JSONC="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.jsonc"
OPENCODE_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"
ZCODE_STORE="${XDG_CONFIG_HOME:-$HOME/.config}/ai.z.zcode/store.json"
PROXY_ENV_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai-proxies"
IDE_ENV_DEFAULTS="$PROXY_ENV_DIR/ide-defaults.env"
MIMO_PLATFORM_URL="https://platform.xiaomimimo.com"
MIMO_PROVIDER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai-providers/mimo"
MIMO_PROVIDER_CONFIG="$MIMO_PROVIDER_DIR/config.json"
MIMO_PROVIDER_KEY="$MIMO_PROVIDER_DIR/api-key"
CONTINUE_CONFIG="${PZ_CONTINUE_CONFIG:-$HOME/.continue/config.json}"
CONTINUE_GLOBAL_CONTEXT="${PZ_CONTINUE_GLOBAL_CONTEXT:-$HOME/.continue/index/globalContext.json}"
CONTINUE_EXTENSION="Continue.continue"

# id|port|providerId|displayName|defaultModel|models(csv) — the user-facing four.
# Ports mirror proxy_rows() above so the provider baseURL matches the listener.
proxy_ide_rows() {
    cat <<'EOF'
kimiproxy|3010|phasezero-kimi|PhaseZero Kimi (K2, proxy)|k2d6-thinking|k2d6-thinking,k2d6
qwenproxy|3011|phasezero-qwen|PhaseZero Qwen (proxy)|qwen3.6-plus|qwen3.6-plus,qwen3.6-plus-no-thinking
deepsproxy|3012|phasezero-deepseek|PhaseZero DeepSeek (proxy)|deepseek-v4-flash|deepseek-v4-flash,deepseek-v4-flash-thinking,deepseek-v4-pro,deepseek-v4-pro-thinking
mimo-ai-proxy|3013|phasezero-mimo|PhaseZero Mimo (proxy)|mimo-v2.5-pro|mimo-v2.5-pro,mimo-v2.5,mimo-v2.5-no-thinking
EOF
}

# The proxy the shared env defaults point at (user preference: deepseek flash free).
IDE_DEFAULT_PROXY="${PZ_AI_PROXY_IDE_DEFAULT:-deepsproxy}"

ordered_proxy_ide_rows() {
    proxy_ide_rows | awk -F'|' -v preferred="$IDE_DEFAULT_PROXY" '$1 == preferred'
    proxy_ide_rows | awk -F'|' -v preferred="$IDE_DEFAULT_PROXY" '$1 != preferred'
}

upsert_env_var() {
    local file="$1" key="$2" value="$3" tmp
    install -d "$(dirname "$file")"
    [ -f "$file" ] || : > "$file"
    tmp="$(mktemp)"
    grep -vE "^${key}=" "$file" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$file"
    chmod 600 "$file"
}

# Return (and persist) a stable local API key for a proxy, without clobbering any
# other vars the user configured (QWEN_*, mimo tokens, ...).
ensure_proxy_key() {
    local id="$1" port="$2" file key=""
    file="$PROXY_ENV_DIR/$id.env"
    [ -f "$file" ] && key="$(awk -F= '$1=="API_KEY"{print $2; exit}' "$file")"
    if [ -z "$key" ]; then
        key="pz-$(od -An -N24 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]')"
        [ "${#key}" -ge 35 ] || { pz_error "secure proxy key generation failed"; return 1; }
    fi
    upsert_env_var "$file" PORT "$port"
    upsert_env_var "$file" API_KEY "$key"
    printf '%s\n' "$key"
}

merge_opencode_provider() {
    local file="$1" pid="$2" name="$3" baseurl="$4" key="$5" models_csv="$6"
    [ -f "$file" ] || return 0
    if ! jq empty "$file" >/dev/null 2>&1; then
        pz_warn "$(basename "$file") is not strict JSON (comments?); skipped proxy provider merge"
        return 0
    fi
    local models_json tmp
    models_json="$(printf '%s' "$models_csv" | jq -R 'split(",") | map({(.): {}}) | add')"
    pz_backup_file "$file" user >/dev/null
    tmp="$(mktemp)"
    jq --arg pid "$pid" --arg name "$name" --arg url "$baseurl" --arg key "$key" --argjson models "$models_json" '
        .provider = (.provider // {})
        | .provider[$pid] = {
            "npm": "@ai-sdk/openai-compatible",
            "name": $name,
            "options": {"baseURL": $url, "apiKey": $key},
            "models": $models
          }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

mimo_official_configured() {
    local base_url host
    [ -s "$MIMO_PROVIDER_KEY" ] && [ -f "$MIMO_PROVIDER_CONFIG" ] || return 1
    [ "$(stat -c '%a' "$MIMO_PROVIDER_KEY" 2>/dev/null || true)" = 600 ] || return 1
    [ "$(stat -c '%a' "$MIMO_PROVIDER_CONFIG" 2>/dev/null || true)" = 600 ] || return 1
    jq -e '
      .schemaVersion == 1 and
      (.baseUrl | type == "string" and startswith("https://")) and
      (.model | type == "string" and length > 0) and
      .validation.httpCode == "200"
    ' "$MIMO_PROVIDER_CONFIG" >/dev/null 2>&1 || return 1
    base_url="$(jq -r '.baseUrl' "$MIMO_PROVIDER_CONFIG")"
    host="$(sed -E 's#^https://([^/]+).*$#\1#' <<< "$base_url")"
    case "$host" in
        api.xiaomimimo.com|token-plan-cn.xiaomimimo.com|token-plan-sgp.xiaomimimo.com|token-plan-ams.xiaomimimo.com) return 0 ;;
        *) return 1 ;;
    esac
}

mimo_official_provider_values() {
    mimo_official_configured || return 1
    jq -r '[.baseUrl,.model] | @tsv' "$MIMO_PROVIDER_CONFIG"
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
mimo_chat_probe() {
    connection_grant_blocked
    return 69
    # PZ-AUD-020: configured != authenticated. A tiny real completion
    # proves key, model, quota and reachability; a stored 200 from setup
    # time proves none of those. The key travels in a header (same as the
    # setup validation), never in argv dumps, logs or stored config.
    local base_url="$1" model="$2" key http_code body
    key="$(cat "$MIMO_PROVIDER_KEY" 2>/dev/null || true)"
    [ -n "$key" ] || return 1
    body="$(jq -nc --arg m "$model" \
        '{model:$m,messages:[{role:"user",content:"reply with: ok"}],max_tokens:4,temperature:0}')"
    http_code="$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
        -d "$body" "$base_url/chat/completions" 2>/dev/null || true)"
    [ "$http_code" = 200 ]
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
configure_mimo_official_clients() {
    connection_grant_blocked
    return 69
    mimo_official_configured || return 0
    local values baseurl model key_ref models store_tmp
    values="$(mimo_official_provider_values)"
    baseurl="${values%%$'\t'*}"
    model="${values#*$'\t'}"
    key_ref="{file:$MIMO_PROVIDER_KEY}"
    models="$model,mimo-v2.5"
    merge_opencode_provider "$OPENCODE_JSON" phasezero-mimo-official \
        "Xiaomi MiMo (API oficial)" "$baseurl" "$key_ref" "$models"
    [ -f "$OPENCODE_JSONC" ] && merge_opencode_provider "$OPENCODE_JSONC" \
        phasezero-mimo-official "Xiaomi MiMo (API oficial)" "$baseurl" "$key_ref" "$models"

    install -d -m 700 "$(dirname "$ZCODE_STORE")"
    [ -f "$ZCODE_STORE" ] || jq -n '{}' > "$ZCODE_STORE"
    if jq empty "$ZCODE_STORE" >/dev/null 2>&1; then
        pz_backup_file "$ZCODE_STORE" user >/dev/null
        store_tmp="$(mktemp)"
        jq --arg baseUrl "$baseurl" --arg model "$model" --arg keyFile "$MIMO_PROVIDER_KEY" '
          ."phasezero-ai-providers" = (."phasezero-ai-providers" // {}) |
          ."phasezero-ai-providers".mimo = {
            source:"xiaomi-official", protocol:"openai-compatible",
            baseUrl:$baseUrl, defaultModel:$model, keyFile:$keyFile,
            secretEmbedded:false
          }
        ' "$ZCODE_STORE" > "$store_tmp" && mv "$store_tmp" "$ZCODE_STORE"
        chmod 600 "$ZCODE_STORE"
    fi
}

configure_opencode_ide() {
    local id port pid name default models key baseurl count=0
    while IFS='|' read -r id port pid name default models; do
        [ -n "$id" ] || continue
        key="$(ensure_proxy_key "$id" "$port")"
        baseurl="http://127.0.0.1:$port/v1"
        merge_opencode_provider "$OPENCODE_JSON" "$pid" "$name" "$baseurl" "$key" "$models"
        # Legacy JSONC is migration input only; never recreate parallel global config.
        [ -f "$OPENCODE_JSONC" ] && merge_opencode_provider "$OPENCODE_JSONC" "$pid" "$name" "$baseurl" "$key" "$models"
        count=$((count + 1))
    done < <(proxy_ide_rows)
    pz_info "opencode/opencode-desktop: wired $count PhaseZero proxy providers (default model unchanged; select a proxy model after 'npm run login')"
}

ensure_continue_extensions() {
    [ "${PZ_AI_PROXY_SKIP_EXTENSION_INSTALL:-0}" = 1 ] && return 0
    local cli installed found=false
    for cli in code code-oss codium cursor windsurf; do
        command -v "$cli" >/dev/null 2>&1 || continue
        found=true
        installed="$("$cli" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
        if ! grep -qx 'continue.continue' <<< "$installed"; then
            pz_info "installing Continue for $cli"
            "$cli" --install-extension "$CONTINUE_EXTENSION" --force >/dev/null || {
                pz_warn "$cli could not install $CONTINUE_EXTENSION (stub or broken editor CLI)"
                continue
            }
        fi
        "$cli" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -qx 'continue.continue' || {
            pz_warn "$CONTINUE_EXTENSION unavailable in $cli after installation"
            continue
        }
    done
    $found || pz_warn "VS Code-compatible editor not found; Continue configuration was still generated"
}

configure_continue_ide() {
    command -v jq >/dev/null 2>&1 || return 1
    install -d -m 700 "$(dirname "$CONTINUE_CONFIG")"
    if [ -f "$CONTINUE_CONFIG" ] && ! jq empty "$CONTINUE_CONFIG" >/dev/null 2>&1; then
        pz_error "$CONTINUE_CONFIG is not strict JSON; refusing to overwrite user configuration"
        return 1
    fi
    [ -f "$CONTINUE_CONFIG" ] || jq -n '{models:[]}' > "$CONTINUE_CONFIG"

    local rows_file models_file tmp id port pid name default models key baseurl model title model_list
    rows_file="$(mktemp)"
    models_file="$(mktemp)"
    tmp="$(mktemp)"
    trap 'rm -f -- "$rows_file" "$models_file" "$tmp"' RETURN
    : > "$rows_file"
    while IFS='|' read -r id port pid name default models; do
        [ -n "$id" ] || continue
        key="$(ensure_proxy_key "$id" "$port")"
        baseurl="http://127.0.0.1:$port/v1"
        IFS=',' read -ra model_list <<< "$models"
        for model in "${model_list[@]}"; do
            title="[PhaseZero Proxy] ${name#PhaseZero } — $model"
            jq -cn --arg title "$title" --arg model "$model" --arg apiBase "$baseurl" --arg apiKey "$key" \
                '{title:$title,provider:"openai",model:$model,apiBase:$apiBase,apiKey:$apiKey,useLegacyCompletionsEndpoint:false}' \
                >> "$rows_file"
        done
    done < <(ordered_proxy_ide_rows)
    jq -s '.' "$rows_file" > "$models_file"
    pz_backup_file "$CONTINUE_CONFIG" user >/dev/null
    jq --slurpfile managed "$models_file" '
      .models = (((.models // []) | if type == "array" then . else [] end)
        | map(select(((.title // "") | startswith("[PhaseZero Proxy] ")) | not)))
        + $managed[0]
      | .allowAnonymousTelemetry = false
    ' "$CONTINUE_CONFIG" > "$tmp"
    mv "$tmp" "$CONTINUE_CONFIG"
    chmod 600 "$CONTINUE_CONFIG"
    pz_backup_prune "$CONTINUE_CONFIG" 5
    trap - RETURN
    rm -f -- "$rows_file" "$models_file"
    configure_continue_selection
    pz_info "Continue: configured $(jq '[.models[] | select((.title // "") | startswith("[PhaseZero Proxy] "))] | length' "$CONTINUE_CONFIG") proxy models for VS Code/Code-OSS"
}

configure_continue_selection() {
    [ -f "$CONTINUE_GLOBAL_CONTEXT" ] || return 0
    jq empty "$CONTINUE_GLOBAL_CONTEXT" >/dev/null 2>&1 || return 0
    local default_title tmp
    default_title="$(jq -r --arg url "http://127.0.0.1:$(proxy_ide_rows | awk -F'|' -v i="$IDE_DEFAULT_PROXY" '$1==i{print $2}')/v1" \
        '[.models[] | select(.apiBase == $url)][0].title // empty' "$CONTINUE_CONFIG")"
    [ -n "$default_title" ] || return 0
    tmp="$(mktemp)"
    jq --arg title "$default_title" '
      if (.selectedModelsByProfileId | type) == "object" then
        .selectedModelsByProfileId |= with_entries(
          .value |= reduce ["chat","edit","apply"][] as $role (.;
            if ((.[$role] // "") == "" or ((.[$role] // "") | startswith("[PhaseZero Proxy] ")))
            then .[$role] = $title else . end))
      else . end
    ' "$CONTINUE_GLOBAL_CONTEXT" > "$tmp"
    pz_backup_file "$CONTINUE_GLOBAL_CONTEXT" user >/dev/null
    mv "$tmp" "$CONTINUE_GLOBAL_CONTEXT"
    chmod 600 "$CONTINUE_GLOBAL_CONTEXT"
    pz_backup_prune "$CONTINUE_GLOBAL_CONTEXT" 5
}

write_ide_env_defaults() {
    local id port pid name default models key baseurl def_key="" def_url="" def_model="" def_pid=""
    install -d "$PROXY_ENV_DIR"
    : > "$IDE_ENV_DEFAULTS.tmp"
    {
        printf '# PhaseZero AI proxy suite — OpenAI-compatible IDE defaults (Linux).\n'
        printf '# Source this for zcode/any OpenAI-compatible tool: set -a; . %s; set +a\n' "$IDE_ENV_DEFAULTS"
    } >> "$IDE_ENV_DEFAULTS.tmp"
    while IFS='|' read -r id port pid name default models; do
        [ -n "$id" ] || continue
        key="$(ensure_proxy_key "$id" "$port")"
        baseurl="http://127.0.0.1:$port/v1"
        local envprefix
        envprefix="$(printf '%s' "$pid" | tr 'a-z-' 'A-Z_')"
        {
            printf '%s_API_KEY=%s\n' "$envprefix" "$key"
            printf '%s_BASE_URL=%s\n' "$envprefix" "$baseurl"
            printf '%s_MODEL=%s\n' "$envprefix" "$default"
        } >> "$IDE_ENV_DEFAULTS.tmp"
        if [ "$id" = "$IDE_DEFAULT_PROXY" ]; then
            def_key="$key"; def_url="$baseurl"; def_model="$default"; def_pid="$pid"
        fi
    done < <(proxy_ide_rows)
    {
        printf 'OPENAI_API_KEY=%s\n' "$def_key"
        printf 'OPENAI_BASE_URL=%s\n' "$def_url"
        printf 'OPENAI_MODEL=%s\n' "$def_model"
        printf 'OPENAI_COMPAT_PROVIDER=%s\n' "$def_pid"
        printf 'PHASEZERO_AI_PROXY_DEFAULT=%s\n' "$def_pid"
    } >> "$IDE_ENV_DEFAULTS.tmp"
    mv "$IDE_ENV_DEFAULTS.tmp" "$IDE_ENV_DEFAULTS"
    chmod 600 "$IDE_ENV_DEFAULTS"
    pz_info "IDE env defaults written: $IDE_ENV_DEFAULTS (default provider: $def_pid/$def_model)"
}

# zcode (ai.z.zcode) is an electron-store app; like Windows it consumes
# OpenAI-compatible endpoints via environment/its own settings rather than a
# provider schema we can safely synthesize. We record the proxy providers in the
# store under a namespaced key (non-breaking) so the app and the user can see
# them, and rely on the shared env defaults for actual routing.
configure_zcode_ide() {
    command -v jq >/dev/null 2>&1 || return 0
    install -d "$(dirname "$ZCODE_STORE")"
    [ -f "$ZCODE_STORE" ] || jq -n '{}' > "$ZCODE_STORE"
    if ! jq empty "$ZCODE_STORE" >/dev/null 2>&1; then
        pz_warn "$ZCODE_STORE is not strict JSON; skipped zcode proxy record"
        return 0
    fi
    local rows_json tmp
    rows_json="$(proxy_ide_rows | jq -R -s '
        split("\n") | map(select(length>0)) | map(split("|")) |
        map({id: .[0], providerId: .[2], name: .[3],
             baseUrl: ("http://127.0.0.1:" + .[1] + "/v1"),
             defaultModel: .[4], models: (.[5] | split(","))})')"
    pz_backup_file "$ZCODE_STORE" user >/dev/null
    tmp="$(mktemp)"
    jq --argjson providers "$rows_json" \
       '."phasezero-ai-proxies" = {source:"phasezero", providers:$providers}' \
       "$ZCODE_STORE" > "$tmp" && mv "$tmp" "$ZCODE_STORE"
    pz_info "zcode: recorded $(printf '%s' "$rows_json" | jq 'length') PhaseZero proxy providers in $ZCODE_STORE"
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
configure_ides() {
    connection_grant_blocked
    return 69
    [ "${PZ_NO_IDES:-0}" = 1 ] && { pz_info "PZ_NO_IDES=1: skipping IDE configuration"; return 0; }
    command -v jq >/dev/null 2>&1 || { pz_error "jq required for IDE configuration"; return 1; }
    configure_opencode_ide
    configure_mimo_official_clients
    write_ide_env_defaults
    configure_zcode_ide
    ensure_continue_extensions
    configure_continue_ide
    pz_info "Proxy IDE configuration complete for OpenCode, VS Code, Code-OSS and ZCode. Browser proxies need one valid saved session."
}

port_open() {
    timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null
}

# `systemctl is-active` says "active" between the crashes of a unit that dies
# right after launch (Restart=on-failure), so status used to show a dead proxy
# as running. Repeated restarts with no listener mean crash-loop.
unit_service_state() {
    local id="$1" port="$2" state restarts
    state="$(systemctl --user is-active "phasezero-$id.service" 2>/dev/null || true)"
    case "$state" in
        active|activating) ;;
        *) printf '%s\n' "$state"; return 0 ;;
    esac
    restarts="$(systemctl --user show "phasezero-$id.service" -p NRestarts --value 2>/dev/null || true)"
    if [[ "$restarts" =~ ^[0-9]+$ ]] && [ "$restarts" -ge "${PZ_PROXY_CRASH_LOOP_RESTARTS:-3}" ] \
        && [[ "$port" =~ ^[1-9][0-9]*$ ]] && ! port_open "$port"; then
        printf '%s\n' crash-loop
        return 0
    fi
    printf '%s\n' "$state"
}

# --- Enable + OAuth login (UI "Habilitar" buttons) ---------------------------
#
# kimiproxy/qwenproxy/deepsproxy authenticate by scraping the vendor's own web
# chat via a real, visible Playwright browser (`npm run login`), not a token
# form — there is no headless OAuth endpoint to hit. mimo-ai-proxy is NOT
# included here (it authenticates via manually-copied session tokens in its
# .env, not a browser flow).
#
# On this host, launching `npm run login` through a spawned terminal emulator
# (kitty/alacritty/...), or fully daemonizing it (nohup+disown), reliably made
# Playwright pick chrome-headless-shell instead of a real visible window —
# even with DISPLAY/WAYLAND_DISPLAY correctly inherited either way. Only a
# plain `setsid`-detached child, launched directly (no terminal, no
# nohup/disown), reliably launches headed and survives this script exiting
# (background jobs of a non-interactive script are not SIGHUP'd on exit).
LOGIN_CAPABLE_PROXIES=(kimiproxy qwenproxy deepsproxy)
# Cards the Control Center "Usar" flow prepares: identical to the
# supported set by construction (PZ-AUD-018). Legacy sources remain
# catalog-only until they receive their own reviewed snapshots.
# shellcheck disable=SC2206
USER_FACING_PROXIES=($SUPPORTED_PROXY_IDS)

is_login_capable_proxy() {
    local id="$1" p
    for p in "${LOGIN_CAPABLE_PROXIES[@]}"; do [ "$p" = "$id" ] && return 0; done
    return 1
}

dotenv_has_any_key() {
    local file="$1"
    shift
    [ -f "$file" ] || return 1
    awk -F= -v keys="$*" '
        BEGIN { split(keys, wanted, " "); for (i in wanted) want[wanted[i]]=1 }
        /^[[:space:]]*#/ { next }
        {
            key=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            val=$0
            sub(/^[^=]*=/, "", val)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (key in want && val != "") found=1
        }
        END { exit found ? 0 : 1 }
    ' "$file"
}

session_artifact_present() {
    local id="$1" dir="$ROOT/$1" db count
    case "$id" in
        kimiproxy) [ -s "$dir/kimi_profile/Default/Cookies" ] ;;
        qwenproxy)
            db="$dir/data/qwenproxy.db"
            if [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1; then
                count="$(sqlite3 "$db" 'SELECT COUNT(*) FROM accounts;' 2>/dev/null || echo 0)"
                [ "${count:-0}" -gt 0 ]
            else
                find "$dir/qwen_profiles" -type f -name Cookies -size +0c -print -quit 2>/dev/null | grep -q .
            fi
            ;;
        deepsproxy) [ -s "$dir/deepseek_profile/Default/Cookies" ] ;;
        *) return 1 ;;
    esac
}

proxy_profile_needle() {
    case "$1" in
        kimiproxy) printf '%s\n' "kimi_profile" ;;
        qwenproxy) printf '%s\n' "qwen_profiles" ;;
        deepsproxy) printf '%s\n' "deepseek_profile" ;;
        *) return 1 ;;
    esac
}

proxy_window_pattern() {
    case "$1" in
        kimiproxy) printf '%s\n' 'kimi\.com|Kimi Chat' ;;
        qwenproxy) printf '%s\n' 'Qwen|qwen\.ai|qianwen' ;;
        deepsproxy) printf '%s\n' 'deepseek' ;;
        *) return 1 ;;
    esac
}

chrome_cmd_has_profile() {
    local needle="$1" pid cmd
    for pid in /proc/[0-9]*; do
        [ -r "$pid/cmdline" ] || continue
        cmd="$(tr '\0' ' ' < "$pid/cmdline" 2>/dev/null || true)"
        case "$cmd" in
            *ms-playwright*) ;;
            *) continue ;;
        esac
        case "$cmd" in
            *headless-shell*|*--type=*|*crashpad*) continue ;;
        esac
        case "$cmd" in
            *"$needle"*) return 0 ;;
        esac
    done
    return 1
}

login_window_kind() {
    local id="$1" pattern titles needle
    pattern="$(proxy_window_pattern "$id" || true)"
    needle="$(proxy_profile_needle "$id" || true)"
    [ -n "$pattern" ] || { printf '%s\n' none; return 0; }
    titles=""
    if command -v kdotool >/dev/null 2>&1; then
        titles="$(kdotool search 2>/dev/null | while read -r wid; do
            [ -n "$wid" ] || continue
            kdotool getwindowname "$wid" 2>/dev/null || true
        done)"
    fi
    if [ -n "$titles" ] && grep -qiE "$pattern" <<< "$titles"; then
        printf '%s\n' headed
        return 0
    fi
    if chrome_cmd_has_profile "$needle"; then
        printf '%s\n' zombie
        return 0
    fi
    printf '%s\n' none
}

login_pid_alive() {
    local id="$1" state="$PZ_STATE/ai-proxies/$1-login.json" pid cwd
    [ -f "$state" ] || return 1
    pid="$(jq -r '.pid // 0' "$state" 2>/dev/null || echo 0)"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    [ "$cwd" = "$ROOT/$id" ]
}

reap_stale_login() {
    local id="$1" state="$PZ_STATE/ai-proxies/$1-login.json" pid needle
    pid="$(jq -r '.pid // 0' "$state" 2>/dev/null || echo 0)"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
        kill "$pid" >/dev/null 2>&1 || true
        sleep 1
        kill -9 "$pid" >/dev/null 2>&1 || true
        pkill -P "$pid" >/dev/null 2>&1 || true
    fi
    needle="$(proxy_profile_needle "$id" || true)"
    if [ -n "$needle" ]; then
        for proc in /proc/[0-9]*; do
            [ -r "$proc/cmdline" ] || continue
            cmd="$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)"
            case "$cmd" in
                *ms-playwright*"$needle"*)
                    case "$cmd" in
                        *--type=*|*crashpad*) continue ;;
                    esac
                    kill "${proc##*/}" >/dev/null 2>&1 || true
                    ;;
            esac
        done
    fi
    rm -f "$PZ_STATE/ai-proxies/$id-login.fifo"
    if [ -f "$state" ]; then
        record_login_status "$id" needs-login
    fi
}

login_process_running() {
    local id="$1" kind
    login_pid_alive "$id" || return 1
    kind="$(login_window_kind "$id")"
    if [ "$kind" = headed ]; then
        return 0
    fi
    reap_stale_login "$id"
    return 1
}

login_tsx() {
    local dir="$1"
    if [ -f "$dir/node_modules/tsx/dist/cli.mjs" ]; then
        printf '%s\n' "$dir/node_modules/tsx/dist/cli.mjs"
    elif [ -x "$dir/node_modules/.bin/tsx" ]; then
        printf '%s\n' "$dir/node_modules/.bin/tsx"
    else
        return 1
    fi
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
quick_chat_ok() {
    connection_grant_blocked
    return 69
    local id="$1" row port model key url code payload
    row="$(proxy_ide_rows | awk -F'|' -v i="$id" '$1==i{print; exit}')"
    [ -n "$row" ] || return 1
    port="$(cut -d'|' -f2 <<< "$row")"
    model="$(cut -d'|' -f5 <<< "$row")"
    key="$(awk -F= '$1=="API_KEY"{print $2; exit}' "$PROXY_ENV_DIR/$id.env" 2>/dev/null || true)"
    [ -n "$key" ] || return 1
    port_open "$port" || return 1
    url="http://127.0.0.1:$port/v1/chat/completions"
    payload="$(jq -nc --arg model "$model" '{model:$model,messages:[{role:"user",content:"Reply only: OK"}],stream:false,max_tokens:8}')"
    code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' -X POST "$url" \
        -H "Authorization: Bearer $key" -H 'Content-Type: application/json' --data "$payload" 2>/dev/null || true)"
    [ "$code" = 200 ]
}

wait_port_free() {
    local port="$1" i
    [ -n "$port" ] && [ "$port" != 0 ] || return 0
    for ((i = 0; i < 12; i++)); do
        port_open "$port" || return 0
        sleep 1
    done
    return 1
}

wait_for_login_window() {
    local log="$1" pid="$2" timeout="${3:-40}" i
    for ((i = 0; i < timeout; i++)); do
        kill -0 "$pid" 2>/dev/null || return 1
        if grep -Eqi 'Browser opened|Launching chromium|Opening chromium|Opening DeepSeek' "$log" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
start_proxy_service() {
    connection_grant_blocked
    return 69
    local id="$1" row port i
    row="$(lookup_proxy_row "$id")"
    [ -n "$row" ] || return 1
    if ! provenance_ready "$id"; then
        pz_error "blocked: $id is not an intact approved snapshot"
        return 69
    fi
    port="$(cut -d'|' -f3 <<< "$row")"
    systemctl --user reset-failed "phasezero-$id.service" >/dev/null 2>&1 || true
    if ! systemctl --user enable --now "phasezero-$id.service"; then
        return 1
    fi
    for ((i = 0; i < 12; i++)); do
        if systemctl --user is-active --quiet "phasezero-$id.service" 2>/dev/null && port_open "$port"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
wait_proxy_chat() {
    connection_grant_blocked
    return 69
    local id="$1" attempts="${2:-8}" i
    for ((i = 0; i < attempts; i++)); do
        quick_chat_ok "$id" && return 0
        sleep 2
    done
    return 1
}

emit_login_json() {
    local id="$1" ok="$2" status="$3" summary="$4" next="$5" log="${6:-}"
    local ready=false completed=false resumable=false
    [ "$status" = ready ] && { ready=true; completed=true; }
    case "$status" in needs-login|gui-required) resumable=true ;; esac
    jq -nc --arg id "$id" --arg name "$(proxy_display_name "$id")" \
        --arg status "$status" --arg summary "$summary" --arg next "$next" \
        --arg log "$log" --argjson ok "$ok" --argjson ready "$ready" \
        --argjson completed "$completed" --argjson resumable "$resumable" \
        '{schemaVersion:1,id:$id,name:$name,ok:$ok,ready:$ready,completed:$completed,resumable:$resumable,
          status:$status,summary:$summary,next:$next,
          nextAction:(if $status=="gui-required" then ("linux/pz ai proxies login " + $id) else null end),
          needsUser:(if $status=="ready" or $status=="authenticated" then "none" else "browser-login" end),log:$log}'
}

patch_proxy_unit_success_exit() {
    local id="$1" unit="$UNITS/phasezero-$1.service"
    [ -f "$unit" ] || return 0
    grep -q '^SuccessExitStatus=' "$unit" && return 0
    local tmp
    tmp="$(mktemp)"
    awk '{print} /^RestartSec=/ && !seen {print "SuccessExitStatus=143 15"; seen=1}' "$unit" > "$tmp"
    mv "$tmp" "$unit"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
}

watch_login_completion() {
    local id="$1" pid="$2" log="$PZ_STATE/ai-proxies/$1-login.log"
    (
        login_marker=false
        while kill -0 "$pid" 2>/dev/null; do
            if grep -Eqi 'Account added|Login detected|session saved' "$log" 2>/dev/null; then
                login_marker=true
                sleep 2
                kill "$pid" >/dev/null 2>&1 || true
                sleep 1
                kill -9 "$pid" >/dev/null 2>&1 || true
                break
            fi
            sleep 2
        done
        # Kimi and DeepSeek do not print a success marker. Their supported
        # flow is: user signs in, closes Chromium, then the persistent profile
        # is inspected for a saved session. Login never starts the consumer.
        if [ "$login_marker" = true ] || session_artifact_present "$id"; then
            record_login_authenticated "$id"
            printf '%s\n' "PhaseZero: sessão local salva; serviço permanece parado até grant por requisição" >>"$log"
        else
            record_login_status "$id" needs-login
            printf '%s\n' "PhaseZero: navegador fechou sem uma sessão detectável" >>"$log"
        fi
    ) >/dev/null 2>&1 &
}

saved_login_status() {
    local state="$PZ_STATE/ai-proxies/$1-login.json"
    [ -f "$state" ] || return 1
    [ "$(jq -r '.status // empty' "$state" 2>/dev/null || true)" = authenticated ]
}

mimo_missing_groups_json() {
    local file="$1" missing=()
    dotenv_has_any_key "$file" SERVICE_TOKEN SERVICE_TOKENS MIMO_SERVICE_TOKEN MIMO_SERVICE_TOKENS XIAOMI_SERVICE_TOKEN XIAOMI_SERVICE_TOKENS || missing+=("service-token-group")
    dotenv_has_any_key "$file" USER_ID USER_IDS MIMO_USER_ID MIMO_USER_IDS XIAOMI_USER_ID XIAOMI_USER_IDS || missing+=("user-id-group")
    dotenv_has_any_key "$file" XIAOMI_CHATBOT_PH XIAOMI_CHATBOT_PHS MIMO_XIAOMI_CHATBOT_PH MIMO_XIAOMI_CHATBOT_PHS || missing+=("chatbot-ph-group")
    jq -cn '$ARGS.positional' --args "${missing[@]}"
}

auth_status_json() {
    local first=true id repo port kind dir installed service env_file api_configured=false
    local required=false web_kind="" web_status="not-applicable" command="" log_path="" missing_json="[]"
    printf '['
    while IFS='|' read -r id repo port kind; do
        [ -n "$id" ] || continue
        dir="$ROOT/$id"
        env_file="$PROXY_ENV_DIR/$id.env"
        installed=false
        if [ "$id" = 9router ]; then [ -x "$dir/bin/9router" ] && installed=true
        else [ -d "$dir/.git" ] && installed=true
        fi
        [ "$id" = "mimo-ai-proxy" ] && mimo_official_configured && installed=true
        service="not-applicable"
        { [ "$kind" = node ] || [ "$kind" = go ] || [ "$kind" = npm ]; } &&
            service="$(unit_service_state "$id" "$port")"
        api_configured=false
        dotenv_has_any_key "$env_file" API_KEY && api_configured=true
        [ "$id" = "mimo-ai-proxy" ] && mimo_official_configured && api_configured=true
        required=false; web_kind=""; web_status="not-applicable"; command=""; log_path=""; missing_json="[]"
        if is_login_capable_proxy "$id"; then
            required=true
            web_kind="browser-session"
            command="linux/pz ai proxies login $id"
            log_path="$PZ_STATE/ai-proxies/$id-login.log"
            if ! $installed; then
                web_status="not-installed"
            elif saved_login_status "$id"; then
                web_status="authenticated"
            elif login_process_running "$id"; then
                web_status="login-running"
            elif session_artifact_present "$id"; then
                web_status="session-present"
            elif [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
                web_status="gui-required"
            else
                web_status="ready-for-login"
            fi
        elif [ "$id" = "mimo-ai-proxy" ]; then
            required=true
            web_kind="official-api-key"
            command="linux/pz ai proxies open-studio"
            if mimo_official_configured; then
                web_status="configured"
            else
                missing_json='["api-key"]'
                web_status="missing-credentials"
            fi
        elif [ "$id" = "9router" ]; then
            required=true
            web_kind="dashboard-provider"
            command="blocked:connection-grant-not-enforceable"
            if ! $installed; then web_status="not-installed"
            elif [ "$service" != active ]; then web_status="start-required"
            else web_status="grant-required"
            fi
        elif [ "$id" = "qwen-worker-proxy" ]; then
            web_kind="external-deploy"
            web_status="cloudflare-required"
        elif [ "$id" = "airlock" ]; then
            web_kind="library"
            web_status="not-applicable"
        else
            web_kind="local-service"
            web_status="not-required"
        fi
        $first || printf ','
        first=false
        jq -cn --arg id "$id" --arg repo "$repo" --arg kind "$kind" --arg path "$dir" \
            --arg envPath "$env_file" --arg service "${service:-inactive}" --arg webKind "$web_kind" \
            --arg webStatus "$web_status" --arg command "$command" --arg loginLog "$log_path" \
            --argjson port "$port" --argjson installed "$installed" --argjson required "$required" \
            --argjson apiKeyConfigured "$api_configured" --argjson missing "$missing_json" \
            --arg tier "$(proxy_tier "$id")" \
            '{
              id:$id, repo:$repo, kind:$kind, path:$path, port:$port,
              installed:$installed, service:$service, envPath:$envPath,
              apiKeyConfigured:$apiKeyConfigured,
              tier:$tier,
              webValidation:{
                required:$required, kind:$webKind, status:$webStatus,
                command:$command, loginLog:$loginLog, missing:$missing
              }
            }'
    done < <(inventory_rows)
    printf ']\n'
}

# Product detail receives one normalized proxy status. Origin is trusted only
# when the working tree still matches the approved source snapshot and managed
# worktree metadata; merely residing under the private store proves nothing.
product_status_json() {
    local entry provenance
    case "$TARGET" in
        kimiproxy|qwenproxy|deepsproxy|mimo-ai-proxy) ;;
        *) pz_error "product status requires one supported proxy id"; return 2 ;;
    esac
    entry="$(auth_status_json | jq -c '.[0]')"
    provenance="$(provenance_json_one "$TARGET")"
    jq -cn --argjson entry "$entry" --argjson provenance "$provenance" \
        --arg manager "phasezero-ai-proxy-suite" \
        '($entry.webValidation.status // "") as $auth |
         ($entry.service // "unknown") as $service |
         {
           schemaVersion:1,
           hasStatus:true,
           installationState:(if $entry.installed == true then "present" else "unknown" end),
           origin:(if $provenance.ready == true then "phasezero" else "unknown" end),
           configurationState:(
             if ($auth == "authenticated" or $auth == "configured") then "ready"
             elif (["not-installed","login-running","session-present","gui-required",
                    "ready-for-login","missing-credentials","start-required"] | index($auth)) then "needed"
             else "unknown" end
           ),
           health:(
             if $service == "active" then "online"
             elif $service == "inactive" then "offline"
             elif ($service == "failed" or $service == "crash-loop") then "failed"
             else "unknown" end
           ),
           manager:$manager
         }'
}

# Read-only snapshot of what configure_ides has already wired, so the UI can
# show integration health without mutating any IDE configuration.
ide_status_json() {
    local defaults=false opencode=0 continue_models=0 zcode=0 file
    [ -f "$IDE_ENV_DEFAULTS" ] && defaults=true
    for file in "$OPENCODE_JSON" "$OPENCODE_JSONC"; do
        [ -f "$file" ] || continue
        jq empty "$file" >/dev/null 2>&1 || continue
        opencode="$(jq '[(.provider // {}) | keys[] | select(startswith("phasezero-"))] | length' "$file")"
        [ "$opencode" -gt 0 ] && break
    done
    if [ -f "$CONTINUE_CONFIG" ] && jq empty "$CONTINUE_CONFIG" >/dev/null 2>&1; then
        continue_models="$(jq '[.models[]? | select((.title // "") | startswith("[PhaseZero Proxy] "))] | length' "$CONTINUE_CONFIG")"
    fi
    if [ -f "$ZCODE_STORE" ] && jq empty "$ZCODE_STORE" >/dev/null 2>&1; then
        zcode="$(jq '."phasezero-ai-proxies".providers // [] | length' "$ZCODE_STORE")"
    fi
    jq -cn --argjson envDefaults "$defaults" --argjson opencodeProviders "$opencode" \
        --argjson continueModels "$continue_models" --argjson zcodeProviders "$zcode" \
        --arg envDefaultsPath "$IDE_ENV_DEFAULTS" --arg defaultProxy "$IDE_DEFAULT_PROXY" \
        '{envDefaults:$envDefaults, envDefaultsPath:$envDefaultsPath, defaultProxy:$defaultProxy,
          opencodeProviders:$opencodeProviders, continueModels:$continueModels, zcodeProviders:$zcodeProviders}'
}

# One consolidated read-only payload for the native UI "Proxies IA" page:
# install/service/auth per proxy plus IDE integration counters, in one call.
detailed_status_json() {
    local previous_target="$TARGET"
    TARGET=all
    jq -cn --argjson proxies "$(auth_status_json)" --argjson ide "$(ide_status_json)" \
        --argjson provenance "$(provenance_status_json)" \
        '{schemaVersion:1, proxies:$proxies, ide:$ide, provenance:$provenance}'
    TARGET="$previous_target"
}

login_proxy() {
    local id="$1" dir="$ROOT/$1" log state login_pid port tsx fifo name
    name="$(proxy_display_name "$id")"
    if ! is_login_capable_proxy "$id"; then
        pz_error "no browser login flow for '$id' (supported: ${LOGIN_CAPABLE_PROXIES[*]})" >&2
        emit_login_json "$id" false error "Este proxy não usa login no navegador." "Use as credenciais no arquivo de ambiente." ""
        return 2
    fi
    if ! provenance_ready "$id"; then
        emit_login_json "$id" false blocked \
            "$name foi bloqueado: a instalação não corresponde ao snapshot aprovado." \
            "Abra Procedência dos proxies para revisar origem, commit e arquivos locais." ""
        return 69
    fi
    if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        emit_login_json "$id" false "gui-required" \
            "$name precisa de uma sessão gráfica para abrir o Chromium." \
            "Abra a Central no desktop (não via SSH) e clique em Usar de novo." ""
        return 3
    fi
    if [ ! -d "$dir/.git" ]; then
        emit_login_json "$id" false error "$name ainda não está instalado." "Clique em Usar para instalar." ""
        return 1
    fi
    if login_process_running "$id"; then
        log="$PZ_STATE/ai-proxies/$id-login.log"
        emit_login_json "$id" false "needs-login" \
            "O login do $name já está aberto no navegador." \
            "Conclua o login na janela do Chromium. O serviço não inicia após o login." "$log"
        return 0
    fi
    if saved_login_status "$id"; then
        emit_login_json "$id" true authenticated \
            "$name tem uma sessão local salva; nenhum teste de inferência foi executado." \
            "Uso permanece bloqueado até grant aplicado por requisição." ""
        return 0
    fi
    ensure_node_runtime >/dev/null

    port="$(lookup_proxy_row "$id" | cut -d'|' -f3)"
    patch_proxy_unit_success_exit "$id"
    systemctl --user stop "phasezero-$id.service" >/dev/null 2>&1 || true
    wait_port_free "$port" || true

    install -d -m 700 "$PZ_STATE/ai-proxies"
    log="$PZ_STATE/ai-proxies/$id-login.log"
    state="$PZ_STATE/ai-proxies/$id-login.json"
    : > "$log"

    if [ "$id" = qwenproxy ]; then
        tsx="$(login_tsx "$dir")" || { emit_login_json "$id" false error "Qwen não tem o runtime de login (tsx)." "Reinstale o proxy." "$log"; return 2; }
        fifo="$PZ_STATE/ai-proxies/$id-login.fifo"
        rm -f "$fifo"
        mkfifo -m 600 "$fifo"
        (
            cd "$dir"
            exec setsid env PATH="$RUNTIME/bin:$PATH" "$NODE_BIN" "$tsx" src/login.ts
        ) <"$fifo" >"$log" 2>&1 &
        login_pid=$!
        (
            printf 'M\n'
            waited=0
            while [ "$waited" -lt 50 ]; do
                grep -q 'Press Enter to open the browser' "$log" 2>/dev/null && break
                kill -0 "$login_pid" 2>/dev/null || exit 0
                sleep 0.2
                waited=$((waited + 1))
            done
            printf '\n'
            waited=0
            while [ "$waited" -lt 180 ]; do
                grep -q 'Login detected' "$log" 2>/dev/null && break
                kill -0 "$login_pid" 2>/dev/null || exit 0
                sleep 2
                waited=$((waited + 1))
            done
            printf 'phasezero-qwen@local\n\nQ\n'
            while kill -0 "$login_pid" 2>/dev/null; do sleep 2; done
        ) >"$fifo" &
    else
        tsx="$(login_tsx "$dir")" || {
            emit_login_json "$id" false error "$name não tem o runtime de login (tsx)." "Reinstale o proxy." "$log"
            return 2
        }
        (
            cd "$dir"
            exec setsid env PATH="$RUNTIME/bin:$PATH" "$NODE_BIN" "$tsx" src/login.ts
        ) </dev/null >"$log" 2>&1 &
        login_pid=$!
    fi

    jq -n --arg id "$id" --arg log "$log" --arg startedAt "$(date -Iseconds)" --argjson pid "$login_pid" \
        '{schemaVersion:1,id:$id,status:"started",pid:$pid,log:$log,startedAt:$startedAt,serviceAfterLogin:"stopped"}' > "$state"

    watch_login_completion "$id" "$login_pid"

    if wait_for_login_window "$log" "$login_pid" 40; then
        emit_login_json "$id" false "needs-login" \
            "Uma janela do navegador abriu para o login do $name." \
            "Conclua o login no Chromium e feche a janela. O serviço permanecerá parado." "$log"
        return 0
    fi
    if kill -0 "$login_pid" 2>/dev/null; then
        emit_login_json "$id" false "needs-login" \
            "Login do $name iniciado. O Chromium deve abrir em instantes." \
            "Se a janela não aparecer, use o modo avançado." "$log"
        return 0
    fi
    emit_login_json "$id" false error "Não foi possível abrir o login do $name." \
        "Tente de novo. Detalhes técnicos ficam no modo avançado." "$log"
    return 1
}

record_login_authenticated() {
    record_login_status "$1" authenticated
}

record_login_needs_login() {
    record_login_status "$1" needs-login
}

record_login_status() {
    local id="$1" status="$2" state="$PZ_STATE/ai-proxies/$1-login.json" tmp
    install -d -m 700 "$PZ_STATE/ai-proxies"
    tmp="$(mktemp)"
    if [ -f "$state" ] && jq empty "$state" >/dev/null 2>&1; then
        jq --arg status "$status" --arg checkedAt "$(date -Iseconds)" '.status=$status | .checkedAt=$checkedAt | .pid=0' "$state" > "$tmp"
    else
        jq -n --arg id "$id" --arg status "$status" --arg checkedAt "$(date -Iseconds)" \
            '{schemaVersion:1,id:$id,status:$status,pid:0,checkedAt:$checkedAt}' > "$tmp"
    fi
    mv "$tmp" "$state"
    chmod 600 "$state"
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
proxy_chat_probe() {
    connection_grant_blocked
    return 69
    local id="$1" row port model key url code payload
    row="$(proxy_ide_rows | awk -F'|' -v i="$id" '$1==i{print; exit}')"
    [ -n "$row" ] || return 1
    port="$(cut -d'|' -f2 <<< "$row")"
    model="$(cut -d'|' -f5 <<< "$row")"
    key="$(sed -n 's/^API_KEY=//p' "$PROXY_ENV_DIR/$id.env" 2>/dev/null | head -1)"
    [ -n "$key" ] || return 1
    port_open "$port" || return 1
    url="http://127.0.0.1:$port/v1/chat/completions"
    payload="$(jq -nc --arg model "$model" '{model:$model,messages:[{role:"user",content:"Reply only: OK"}],stream:false,max_tokens:8}')"
    code="$(curl -s -m 35 -o /dev/null -w '%{http_code}' -X POST "$url" \
        -H "Authorization: Bearer $key" -H 'Content-Type: application/json' --data "$payload" 2>/dev/null || true)"
    [ "$code" = 200 ]
}

# Honest end-to-end probe. These proxies launch a Playwright/Chromium session
# BEFORE binding (kimi/deepseek/mimo serve a static /v1/models; qwen's is dynamic
# and needs a Qwen session), so we (1) warm every service in parallel, (2) wait
# for the TCP port, then (3) classify: service up/down, models ok/needs-login,
# chat ok/needs-login. Chat and qwen's models require a one-time `npm run login`.
# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
test_proxies() {
    connection_grant_blocked
    return 69
    local id repo port kind first=true
    local ids=() ports=()
    repair_runtime_shim
    # Pass 1: start every user-facing proxy so they warm up concurrently.
    while IFS='|' read -r id repo port kind; do
        [ -n "$id" ] || continue
        { [ "$kind" = node ] || [ "$kind" = go ]; } || continue
        proxy_ide_rows | awk -F'|' -v i="$id" '$1==i{f=1} END{exit f?0:1}' || continue
        systemctl --user start "phasezero-$id.service" >/dev/null 2>&1 || true
        ids+=("$id"); ports+=("$port")
    done < <(selected_rows)

    printf '['
    local idx key url up i models chat model
    for idx in "${!ids[@]}"; do
        id="${ids[$idx]}"; port="${ports[$idx]}"
        key="$(awk -F= '$1=="API_KEY"{print $2; exit}' "$PROXY_ENV_DIR/$id.env" 2>/dev/null || true)"
        url="http://127.0.0.1:$port/v1"
        model="$(proxy_ide_rows | awk -F'|' -v i="$id" '$1==i{print $5}')"
        up=false
        for ((i = 1; i <= 40; i++)); do port_open "$port" && { up=true; break; }; sleep 1; done
        models=unreachable; chat=unreachable
        if $up; then
            local mbody
            mbody="$(curl -s -m 10 -H "Authorization: Bearer $key" "$url/models" 2>/dev/null || true)"
            # Require a real OpenAI models list; rejects HTML from a colliding
            # service (e.g. open-webui) that merely returns HTTP 200.
            if printf '%s' "$mbody" | jq -e '(.data|type=="array" and length>0) or (.object=="list")' >/dev/null 2>&1; then
                models=ok
            else
                models=needs-login
            fi
            ccode="$(curl -s -m 25 -o /dev/null -w '%{http_code}' -X POST "$url/chat/completions" \
                -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
                --data "$(jq -nc --arg m "$model" '{model:$m, messages:[{role:"user",content:"ping"}], stream:false, max_tokens:8}')" 2>/dev/null || true)"
            [ "$ccode" = "200" ] && chat=ok || chat=needs-login
            if [ "$chat" = ok ]; then
                record_login_authenticated "$id"
            elif is_login_capable_proxy "$id"; then
                record_login_needs_login "$id"
            fi
        fi
        $first || printf ','
        first=false
        jq -nc --arg id "$id" --arg url "$url" --arg svc "$($up && echo running || echo down)" \
            --arg models "$models" --arg chat "$chat" \
            '{id:$id, endpoint:$url, service:$svc, modelsEndpoint:$models, chat:$chat}'
    done
    printf ']\n'
}

proxy_display_name() {
    case "$1" in
        kimiproxy) printf '%s\n' "Kimi" ;;
        qwenproxy) printf '%s\n' "Qwen" ;;
        deepsproxy) printf '%s\n' "DeepSeek" ;;
        mimo-ai-proxy) printf '%s\n' "Mimo" ;;
        9router) printf '%s\n' "9Router" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

proxy_is_installed() {
    local id="$1" dir="$ROOT/$1"
    if [ "$id" = 9router ]; then
        [ -x "$dir/bin/9router" ]
    else
        [ -d "$dir/.git" ]
    fi
}

lookup_proxy_row() {
    proxy_rows | awk -F'|' -v i="$1" '$1==i {print; exit}'
}

_ensure_steps_add() {
    local file="$1" name="$2" status="$3" detail="${4:-}" tmp
    tmp="$(mktemp)"
    jq --arg name "$name" --arg status "$status" --arg detail "$detail" \
        '. + [{name:$name, status:$status, detail:$detail}]' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# One-click Control Center path: install if missing, start, open headed login
# when the proxy still needs a browser session. Stdout is a single JSON object
# so the simple UI can show `summary`/`next` without npm/git noise.
# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
ensure_one() {
    connection_grant_blocked
    return 69
    local id="$1" dry="$2"
    local name row repo port kind dir log steps_file
    local installed=false service="" auth_status="" needs_user="none"
    local status="ready" summary="" next="" ok=true
    name="$(proxy_display_name "$id")"
    row="$(lookup_proxy_row "$id")"
    if [ -z "$row" ]; then
        jq -nc --arg id "$id" --arg summary "Proxy desconhecido: $id" \
            '{schemaVersion:1,id:$id,ok:false,status:"error",summary:$summary,needsUser:"none",dryRun:false,steps:[]}'
        return 2
    fi
    IFS='|' read -r _id repo port kind <<< "$row"
    dir="$ROOT/$id"
    log="$PZ_STATE/ai-proxies/$id-ensure.log"
    install -d -m 700 "$PZ_STATE/ai-proxies"
    steps_file="$(mktemp)"
    printf '[]\n' > "$steps_file"

    # MiMo uses Xiaomi's supported OpenAI-compatible API. Do not clone or run
    # the legacy browser-session scraper on the normal user journey.
    if [ "$id" = "mimo-ai-proxy" ]; then
        if mimo_official_configured; then
            _ensure_steps_add "$steps_file" credentials ok "chave oficial em arquivo protegido"
            _ensure_steps_add "$steps_file" start skipped "API remota; serviço local desnecessário"
            if [ "$dry" = 1 ]; then
                summary="MiMo oficial já está configurado. Vai sincronizar o provedor nas IDEs."
                jq -nc --arg id "$id" --arg name "$name" --arg summary "$summary" \
                    --argjson dryRun true \
                    --argjson steps "$(cat "$steps_file")" \
                    '{schemaVersion:1,id:$id,name:$name,ok:true,ready:true,completed:true,resumable:false,
                      status:"ready",summary:$summary,next:"Abra o MiMo pelo botão Usar.",needsUser:"none",
                      dryRun:$dryRun,installed:true,steps:$steps,inference:{probed:false}}'
            else
                local mimo_values mimo_base mimo_model
                mimo_values="$(mimo_official_provider_values)"
                mimo_base="${mimo_values%%$'\t'*}"
                mimo_model="${mimo_values#*$'\t'}"
                # PZ-AUD-020: only a real answer closes readiness.
                if mimo_chat_probe "$mimo_base" "$mimo_model"; then
                    _ensure_steps_add "$steps_file" inference ok "resposta real da API oficial"
                    configure_mimo_official_clients >>"$log" 2>&1 || true
                    summary="MiMo oficial está configurado e respondeu na API oficial."
                    jq -nc --arg id "$id" --arg name "$name" --arg summary "$summary" \
                        --argjson dryRun false \
                        --argjson steps "$(cat "$steps_file")" \
                        '{schemaVersion:1,id:$id,name:$name,ok:true,ready:true,completed:true,resumable:false,
                          status:"ready",summary:$summary,next:"Abra o MiMo pelo botão Usar.",needsUser:"none",
                          dryRun:$dryRun,installed:true,steps:$steps,inference:{probed:true,httpCode:"200"}}'
                else
                    _ensure_steps_add "$steps_file" inference failed "sem resposta de chat (chave revogada, quota, modelo ou rede)"
                    summary="MiMo tem chave armazenada, mas a API oficial não respondeu a uma pergunta real."
                    jq -nc --arg id "$id" --arg name "$name" --arg summary "$summary" \
                        --argjson dryRun false \
                        --argjson steps "$(cat "$steps_file")" \
                        '{schemaVersion:1,id:$id,name:$name,ok:false,ready:false,completed:false,resumable:true,
                          status:"needs-credentials",
                          summary:$summary,
                          next:"Confira quota/modelo da conta, gere nova chave se preciso e rode set-credentials de novo.",
                          nextAction:"linux/pz ai proxies set-credentials mimo-ai-proxy",needsUser:"api-key",
                          dryRun:$dryRun,installed:true,steps:$steps,inference:{probed:true,httpCode:"non-200"}}'
                    rm -f "$steps_file"
                    return 1
                fi
            fi
        else
            _ensure_steps_add "$steps_file" credentials missing "chave da API oficial"
            _ensure_steps_add "$steps_file" start deferred "aguarda chave oficial"
            [ "$dry" = 1 ] || open_mimo_studio >/dev/null 2>&1 || true
            jq -nc --arg id "$id" --arg name "$name" \
                --argjson dryRun "$([ "$dry" = 1 ] && echo true || echo false)" \
                --argjson steps "$(cat "$steps_file")" \
                '{schemaVersion:1,id:$id,name:$name,ok:false,ready:false,completed:false,resumable:true,
                  status:"needs-credentials",summary:"Falta a chave oficial da API Xiaomi MiMo.",
                  next:"Abra API Service e guarde a chave em Contas. Uso via proxy permanece bloqueado sem grant por requisição.",
                  nextAction:null,needsUser:"api-key",
                  dryRun:$dryRun,installed:false,steps:$steps}'
        fi
        rm -f "$steps_file"
        return 0
    fi

    if proxy_is_installed "$id"; then
        if [ "$id" != 9router ] && ! provenance_ready "$id"; then
            local provenance reason
            provenance="$(provenance_json_one "$id")"
            reason="$(jq -r '.reason' <<< "$provenance")"
            _ensure_steps_add "$steps_file" provenance blocked "$reason"
            jq -nc --arg id "$id" --arg name "$name" --arg reason "$reason" \
                --argjson provenance "$provenance" --argjson steps "$(cat "$steps_file")" \
                '{schemaVersion:1,id:$id,name:$name,ok:false,status:"blocked",
                  summary:($name + " foi bloqueado: " + $reason + "."),
                  next:"Abra Procedência dos proxies. Reinstalação exige snapshot aprovado; alterações locais não são executadas.",
                  needsUser:"review-provenance",dryRun:false,installed:true,provenance:$provenance,steps:$steps}'
            rm -f "$steps_file"
            return 69
        fi
        installed=true
        _ensure_steps_add "$steps_file" provenance ok "snapshot aprovado e íntegro"
        _ensure_steps_add "$steps_file" install skipped "já instalado"
    elif [ "$id" != 9router ] && [ -e "$dir" ]; then
        local collision_provenance collision_reason
        collision_provenance="$(provenance_json_one "$id")"
        collision_reason="$(jq -r '.reason' <<< "$collision_provenance")"
        _ensure_steps_add "$steps_file" provenance blocked "$collision_reason"
        jq -nc --arg id "$id" --arg name "$name" --arg reason "$collision_reason" \
            --argjson provenance "$collision_provenance" --argjson steps "$(cat "$steps_file")" \
            '{schemaVersion:1,id:$id,name:$name,ok:false,status:"blocked",
              summary:($name + " foi bloqueado: " + $reason + "."),
              next:"Revise o diretório existente antes de instalar o snapshot aprovado.",
              needsUser:"review-provenance",dryRun:false,installed:true,provenance:$provenance,steps:$steps}'
        rm -f "$steps_file"
        return 69
    elif [ "$id" != 9router ] && ! trusted_source_record "$id" >/dev/null 2>&1; then
        _ensure_steps_add "$steps_file" provenance blocked "fonte sem snapshot aprovado"
        jq -nc --arg id "$id" --arg name "$name" --argjson steps "$(cat "$steps_file")" \
            '{schemaVersion:1,id:$id,name:$name,ok:false,status:"blocked",
              summary:($name + " foi bloqueado: fonte sem snapshot aprovado."),
              next:"Uma revisão precisa fixar repositório, commit, árvore, licença e lockfiles antes da instalação.",
              needsUser:"review-provenance",dryRun:false,installed:false,steps:$steps}'
        rm -f "$steps_file"
        return 69
    elif [ "$dry" = 1 ]; then
        _ensure_steps_add "$steps_file" provenance ok "snapshot aprovado para instalação"
        _ensure_steps_add "$steps_file" install would-run "clone e build"
    else
        echo >&2 "Preparando $name…"
        if install_one "$id" "$repo" "$port" "$kind" >>"$log" 2>&1; then
            installed=true
            _ensure_steps_add "$steps_file" install ok
        else
            _ensure_steps_add "$steps_file" install failed "veja $log"
            jq -nc --arg id "$id" --arg name "$name" --arg log "$log" \
                --arg summary "Não foi possível instalar $name." \
                --argjson steps "$(cat "$steps_file")" \
                '{schemaVersion:1,id:$id,ok:false,status:"error",summary:$summary,next:"Tente de novo. Detalhes técnicos ficam no modo avançado.",needsUser:"none",dryRun:false,log:$log,steps:$steps}'
            rm -f "$steps_file"
            return 1
        fi
    fi

    service="$(unit_service_state "$id" "$port")"

    if is_login_capable_proxy "$id"; then
        if saved_login_status "$id"; then
            auth_status="authenticated"
        elif login_process_running "$id"; then
            auth_status="login-running"
        elif session_artifact_present "$id"; then
            auth_status="session-present"
        elif [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            auth_status="gui-required"
        else
            auth_status="ready-for-login"
        fi
        if [ "$auth_status" = "authenticated" ]; then
            if [ "$service" = active ]; then
                _ensure_steps_add "$steps_file" start skipped "já rodando"
            elif [ "$dry" = 1 ]; then
                _ensure_steps_add "$steps_file" start would-run
            else
                if start_proxy_service "$id" >>"$log" 2>&1; then
                    _ensure_steps_add "$steps_file" start ok
                else
                    _ensure_steps_add "$steps_file" start failed "veja $log"
                    ok=false
                    status=error
                    summary="Não foi possível iniciar $name."
                    next="Tente de novo. Detalhes técnicos ficam no modo avançado."
                fi
            fi
            if [ "$dry" = 1 ]; then
                _ensure_steps_add "$steps_file" login skipped "sessão salva; será validada"
                summary="Vai iniciar $name e validar a sessão salva."
            elif [ "$ok" = true ] && wait_proxy_chat "$id" 5; then
                _ensure_steps_add "$steps_file" login skipped "sessão validada por chat"
                summary="$name tem sessão local; uso continua bloqueado até grant por requisição."
            elif [ "$ok" = true ]; then
                record_login_needs_login "$id"
                _ensure_steps_add "$steps_file" login stale "sessão salva não respondeu"
                if login_proxy "$id" >>"$log" 2>&1; then
                    _ensure_steps_add "$steps_file" login opened "renovação necessária"
                    needs_user="browser-login"
                    status="needs-login"
                    summary="A sessão salva do $name expirou. O navegador foi aberto."
                    next="Conclua o login no Chromium. O serviço permanecerá parado."
                else
                    _ensure_steps_add "$steps_file" login failed "veja $log"
                    ok=false
                    status=error
                    summary="A sessão do $name expirou e o login não abriu."
                    next="Tente de novo. Detalhes técnicos ficam no modo avançado."
                fi
            fi
        elif [ "$auth_status" = "login-running" ]; then
            _ensure_steps_add "$steps_file" start skipped "login em andamento"
            _ensure_steps_add "$steps_file" login skipped "janela já aberta"
            needs_user="browser-login"
            status="needs-login"
            summary="O login do $name já está aberto no navegador."
            next="Conclua o login na janela do Chromium. O proxy inicia sozinho depois."
        elif [ "$auth_status" = "gui-required" ]; then
            if [ "$dry" = 1 ]; then
                _ensure_steps_add "$steps_file" start would-run
                _ensure_steps_add "$steps_file" login blocked "precisa de sessão gráfica"
                summary="Vai preparar $name. O login só abre no desktop gráfico."
            else
                if start_proxy_service "$id" >>"$log" 2>&1; then
                    _ensure_steps_add "$steps_file" start ok
                else
                    _ensure_steps_add "$steps_file" start failed "veja $log"
                    ok=false
                    status=error
                fi
                _ensure_steps_add "$steps_file" login blocked "precisa de sessão gráfica"
                if [ "$ok" = true ]; then
                    summary="$name está instalado, mas o login precisa de uma sessão gráfica."
                else
                    summary="$name foi instalado, mas o serviço não iniciou."
                fi
            fi
            needs_user="gui"
            status="gui-required"
            ok=true
            next="Abra a Central no desktop (não via SSH) e clique em Usar de novo."
        else
            needs_user="browser-login"
            status="needs-login"
            if [ "$dry" = 1 ]; then
                _ensure_steps_add "$steps_file" start deferred "depois do login"
                _ensure_steps_add "$steps_file" login would-open "Chromium visível"
                summary="Vai instalar o $name se faltar, abrir o navegador para login e iniciar o serviço."
                next="Uma janela do Chromium abre para você entrar na conta. O proxy sobe sozinho depois."
            else
                _ensure_steps_add "$steps_file" start deferred "depois do login"
                if login_proxy "$id" >>"$log" 2>&1; then
                    _ensure_steps_add "$steps_file" login opened
                    summary="Uma janela do navegador abriu para o login do $name."
                    next="Conclua o login no Chromium e volte. O serviço permanecerá parado."
                else
                    _ensure_steps_add "$steps_file" login failed "veja $log"
                    ok=false
                    status="error"
                    summary="Não foi possível abrir o login do $name."
                    next="Tente de novo. Detalhes técnicos ficam no modo avançado."
                fi
            fi
        fi
    else
        if [ "$kind" != node ] && [ "$kind" != go ] && [ "$kind" != npm ]; then
            _ensure_steps_add "$steps_file" start skipped "sem serviço local"
            summary="$name não tem serviço local para iniciar."
        elif [ "$service" = active ]; then
            _ensure_steps_add "$steps_file" start skipped "já rodando"
            summary="$name já está rodando."
        elif [ "$dry" = 1 ]; then
            _ensure_steps_add "$steps_file" start would-run
            summary="Vai iniciar $name."
        else
            if start_proxy_service "$id" >>"$log" 2>&1; then
                _ensure_steps_add "$steps_file" start ok
                summary="$name iniciado."
            else
                _ensure_steps_add "$steps_file" start failed "veja $log"
                ok=false
                status=error
                summary="Não foi possível iniciar $name."
                next="Tente de novo. Detalhes técnicos ficam no modo avançado."
            fi
        fi
    fi

    if [ "$dry" = 1 ] && [ "$status" = "ready" ]; then
        status="planned"
        [ -n "$summary" ] || summary="Vai preparar $name."
    fi

    local dry_json=false result_ok="$ok" ready=false completed=false resumable=false
    [ "$dry" = 1 ] && dry_json=true
    case "$status" in
        ready) ready=true; completed=true ;;
        planned) result_ok=true ;;
        needs-login|needs-credentials|gui-required)
            result_ok=false
            resumable=true
            ;;
        error|blocked) result_ok=false ;;
    esac
    jq -nc --arg id "$id" --arg name "$name" --arg status "$status" \
        --arg summary "$summary" --arg next "$next" --arg needsUser "$needs_user" \
        --arg log "$log" --argjson ok "$result_ok" --argjson ready "$ready" \
        --argjson completed "$completed" --argjson resumable "$resumable" --argjson dryRun "$dry_json" \
        --argjson installed "$installed" --argjson steps "$(cat "$steps_file")" \
        '{schemaVersion:1,id:$id,name:$name,ok:$ok,ready:$ready,completed:$completed,resumable:$resumable,
          status:$status,summary:$summary,next:$next,needsUser:$needsUser,
          nextAction:null,
          dryRun:$dryRun,installed:$installed,log:$log,steps:$steps}'
    rm -f "$steps_file"
    [ "$ok" = true ]
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
ensure_selected() {
    connection_grant_blocked
    return 69
    local dry="$ENSURE_DRY_RUN" id item results_file ok=true dry_json=false
    local ide_ok=false ide_status="connection-grant-not-enforceable" ide_log=""
    local ids=() envelope_status=ready
    [ "$dry" = 1 ] && dry_json=true
    results_file="$(mktemp)"
    printf '[]\n' > "$results_file"
    if [ "$TARGET" = all ]; then
        ids=("${USER_FACING_PROXIES[@]}")
    else
        ids=("$TARGET")
    fi
    for id in "${ids[@]}"; do
        item="$(ensure_one "$id" "$dry")" || true
        printf '%s\n' "$item" | jq -e . >/dev/null 2>&1 || item="$(jq -nc --arg id "$id" '{schemaVersion:1,id:$id,ok:false,status:"error",summary:"Falha inesperada ao preparar o proxy.",needsUser:"none",dryRun:false,steps:[]}')"
        jq --argjson item "$item" '. + [$item]' "$results_file" > "$results_file.tmp"
        mv "$results_file.tmp" "$results_file"
        jq -e '.status != "error" and .status != "blocked"' <<< "$item" >/dev/null || ok=false
    done
    if [ "$TARGET" = all ]; then
        local login=0 creds=0 failed=0 summary next=""
        login="$(jq '[.[] | select(.needsUser=="browser-login")] | length' "$results_file")"
        creds="$(jq '[.[] | select(.needsUser=="env-credentials")] | length' "$results_file")"
        failed="$(jq '[.[] | select(.ok==false)] | length' "$results_file")"
        if [ "$failed" -gt 0 ]; then
            envelope_status=error
            summary="Alguns proxies não puderam ser preparados."
            next="Abra o modo avançado para ver o que falhou."
        elif [ "$dry" = 1 ]; then
            envelope_status=planned
            summary="Preparação bloqueada até enforcement de grants por requisição."
            next="Esta operação está bloqueada até enforcement de grants por requisição."
        elif [ "$login" -gt 0 ]; then
            envelope_status=needs-login
            summary="Proxies prontos. $login ainda precisam de login no navegador."
            next="Conclua o login nas janelas do Chromium que abriram."
        elif [ "$creds" -gt 0 ]; then
            envelope_status=needs-credentials
            summary="Proxies prontos. Mimo ainda precisa das credenciais da conta."
        elif [ "$ide_ok" != true ]; then
            envelope_status=blocked
            summary="Preparação de uso bloqueada: falta vínculo por conexão e consumidor."
            next="Nenhuma IDE foi configurada ou habilitada."
        else
            summary="Os quatro proxies estão prontos para usar."
        fi
        local result_ok="$ok" ready=false completed=false resumable=false
        if [ "$envelope_status" = ready ]; then ready=true; completed=true; fi
        case "$envelope_status" in needs-login|needs-credentials|gui-required) result_ok=false; resumable=true ;; esac
        jq -nc --argjson ok "$result_ok" --argjson ready "$ready" --argjson completed "$completed" \
            --argjson resumable "$resumable" --argjson dryRun "$dry_json" --arg status "$envelope_status" \
            --arg summary "$summary" --arg next "$next" --argjson proxies "$(cat "$results_file")" \
            --arg ideStatus "$ide_status" --arg ideLog "$ide_log" --argjson ideOk "$ide_ok" \
            '{schemaVersion:1,ok:$ok,ready:$ready,completed:$completed,resumable:$resumable,
              status:$status,summary:$summary,next:$next,
              nextAction:null,dryRun:$dryRun,proxies:$proxies,
              ide:{ok:$ideOk,status:$ideStatus,log:$ideLog}}'
    else
        jq --arg ideStatus "$ide_status" --arg ideLog "$ide_log" --argjson ideOk "$ide_ok" '
          .[0] | .ide={ok:$ideOk,status:$ideStatus,log:$ideLog} |
          if ($ideOk|not) and .status=="ready" then
            .status="degraded" |
            .summary=(.name + " está pronto, mas a integração com as IDEs falhou.") |
            .next="Use Configurar IDEs (proxies) ou abra o modo avançado para ver o log."
          else . end
        ' "$results_file"
    fi
    rm -f "$results_file"
    [ "$ok" = true ]
}

open_mimo_studio() {
    command -v xdg-open >/dev/null 2>&1 || { pz_error "xdg-open missing"; return 1; }
    xdg-open "$MIMO_PLATFORM_URL" >/dev/null 2>&1 &
    jq -nc --arg url "$MIMO_PLATFORM_URL" \
        '{schemaVersion:1,ok:false,ready:false,completed:false,resumable:true,status:"needs-credentials",summary:"Portal oficial Xiaomi MiMo aberto.",next:"Abra API Service, crie uma chave e cole-a na Central. Não use DevTools, cookies ou tokens de sessão.",studioUrl:$url,needsUser:"api-key"}'
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
set_proxy_credentials() {
    connection_grant_blocked
    return 69
    local id="${TARGET:-mimo-ai-proxy}" payload api_key base_url model host http_code tmp
    [ "$id" = "mimo-ai-proxy" ] || [ "$id" = mimo ] || { pz_error "set-credentials only supports mimo-ai-proxy"; return 2; }
    id=mimo-ai-proxy
    payload="$(cat)"
    printf '%s' "$payload" | jq -e 'type=="object"' >/dev/null 2>&1 || {
        jq -nc '{schemaVersion:1,ok:false,status:"error",summary:"Configuração inválida.",needsUser:"api-key"}'
        return 2
    }
    api_key="$(jq -r '.apiKey // empty' <<< "$payload")"
    base_url="$(jq -r '.baseUrl // "https://api.xiaomimimo.com/v1"' <<< "$payload")"
    model="$(jq -r '.model // "mimo-v2.5-pro"' <<< "$payload")"
    if [ "${#api_key}" -lt 12 ] || [[ "$api_key" =~ [[:space:]] ]]; then
        jq -nc '{schemaVersion:1,ok:false,status:"needs-credentials",summary:"Chave da API ausente ou inválida.",next:"Cole a chave completa criada em API Service.",needsUser:"api-key"}'
        return 2
    fi
    host="$(sed -E 's#^https://([^/]+).*$#\1#' <<< "$base_url")"
    case "$host" in
        api.xiaomimimo.com|token-plan-cn.xiaomimimo.com|token-plan-sgp.xiaomimimo.com|token-plan-ams.xiaomimimo.com) ;;
        *) jq -nc '{schemaVersion:1,ok:false,status:"blocked",summary:"Endpoint MiMo não aprovado.",next:"Use o endpoint oficial mostrado pela Xiaomi.",needsUser:"api-key"}'; return 2 ;;
    esac
    [[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || {
        jq -nc '{schemaVersion:1,ok:false,status:"error",summary:"Nome de modelo inválido.",needsUser:"api-key"}'
        return 2
    }
    http_code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $api_key" "$base_url/models" 2>/dev/null || true)"
    if [ "$http_code" = 401 ] || [ "$http_code" = 403 ]; then
        jq -nc '{schemaVersion:1,ok:false,status:"needs-credentials",summary:"A Xiaomi recusou esta chave.",next:"Revogue a chave inválida, crie outra em API Service e tente novamente.",needsUser:"api-key"}'
        return 2
    fi
    if [ "$http_code" != 200 ]; then
        jq -nc --arg code "${http_code:-000}" \
            '{schemaVersion:1,ok:false,status:"error",summary:"Não foi possível validar a API oficial do MiMo.",
              next:"Verifique internet, endpoint e plano da conta; tente novamente.",validation:{httpCode:$code},needsUser:"api-key"}'
        return 1
    fi
    install -d -m 700 "$MIMO_PROVIDER_DIR"
    printf '%s\n' "$api_key" > "$MIMO_PROVIDER_KEY"
    chmod 600 "$MIMO_PROVIDER_KEY"
    tmp="$(mktemp)"
    jq -n --arg baseUrl "$base_url" --arg model "$model" --arg checkedAt "$(date -Iseconds)" \
        --arg httpCode "${http_code:-000}" \
        '{schemaVersion:1,source:"xiaomi-official",protocol:"openai-compatible",baseUrl:$baseUrl,
          model:$model,keyFile:"api-key",validation:{checkedAt:$checkedAt,httpCode:$httpCode}}' > "$tmp"
    mv "$tmp" "$MIMO_PROVIDER_CONFIG"
    chmod 600 "$MIMO_PROVIDER_CONFIG"
    configure_mimo_official_clients
    jq -nc --arg code "${http_code:-000}" \
        '{schemaVersion:1,ok:true,ready:true,completed:true,resumable:false,status:"configured",
          summary:"MiMo oficial configurado sem copiar cookies do navegador.",
          next:"Abra o OpenCode com MiMo. A chave permanece em arquivo protegido e não aparece na configuração.",
          validation:{httpCode:$code},needsUser:"none"}'
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
open_opencode_proxy() {
    connection_grant_blocked
    return 69
    local id="$TARGET" row port provider model spec name
    [ "$id" != all ] || id="$IDE_DEFAULT_PROXY"
    row="$(proxy_ide_rows | awk -F'|' -v i="$id" '$1==i{print; exit}')"
    [ -n "$row" ] || { jq -nc --arg id "$id" '{schemaVersion:1,ok:false,status:"error",summary:"Proxy desconhecido.",id:$id}'; return 2; }
    port="$(cut -d'|' -f2 <<< "$row")"
    provider="$(cut -d'|' -f3 <<< "$row")"
    model="$(cut -d'|' -f5 <<< "$row")"
    name="$(proxy_display_name "$id")"
    spec="$provider/$model"
    if [ "$id" = "mimo-ai-proxy" ] && mimo_official_configured; then
        local mimo_values
        mimo_values="$(mimo_official_provider_values)"
        model="${mimo_values#*$'\t'}"
        provider="phasezero-mimo-official"
        spec="$provider/$model"
        configure_mimo_official_clients
    elif [ "$id" = "mimo-ai-proxy" ]; then
        open_mimo_studio
        return 0
    fi
    if [ "$id" != "mimo-ai-proxy" ] && ! start_proxy_service "$id" >/dev/null 2>&1; then
        jq -nc --arg name "$name" \
            '{schemaVersion:1,ok:false,status:"error",summary:("O serviço do " + $name + " não iniciou."),next:"Tente Usar novamente; detalhes técnicos ficam no modo avançado."}'
        return 1
    fi
    if [ "$id" != "mimo-ai-proxy" ] && ! wait_proxy_chat "$id" 5; then
        if is_login_capable_proxy "$id"; then
            record_login_needs_login "$id"
            login_proxy "$id"
            return $?
        fi
        jq -nc --arg name "$name" \
            '{schemaVersion:1,ok:false,ready:false,completed:false,resumable:true,status:"needs-login",summary:("O serviço do " + $name + " iniciou, mas a conta não respondeu."),next:"Renove a autenticação e tente novamente.",needsUser:"browser-login"}'
        return 0
    fi
    if ! command -v opencode >/dev/null 2>&1; then
        jq -nc --arg summary "OpenCode CLI não está no PATH." --arg spec "$spec" \
            '{schemaVersion:1,ok:false,status:"error",summary:$summary,next:"Configure o OpenCode em IA e Dev, depois clique de novo.",model:$spec}'
        return 1
    fi
    if command -v konsole >/dev/null 2>&1; then
        konsole -p tabtitle="OpenCode $name" -e opencode -m "$spec" --auto >/dev/null 2>&1 &
    else
        opencode -m "$spec" --auto >/dev/null 2>&1 &
    fi
    jq -nc --arg name "$name" --arg spec "$spec" \
        '{schemaVersion:1,ok:true,status:"ready",summary:("OpenCode aberto com " + $name + " (" + $spec + ")."),next:"A conversa já usa este proxy.",model:$spec,needsUser:"none"}'
}

case "$ACTION" in
    status|list) status_json ;;
    plan|dry-run)
        while IFS='|' read -r id repo port kind; do
            if [ "$id" = 9router ]; then
                printf 'would delegate %s integrity to 9router manager\n' "$id"
            elif record="$(trusted_source_record "$id" 2>/dev/null || true)" && [ -n "$record" ]; then
                printf 'would install %s from %s at commit %s (%s)\n' \
                    "$id" "$repo" "$(jq -r '.commit' <<< "$record")" "$kind"
            elif [ "$(proxy_tier "$id")" = experimental ]; then
                printf 'preview %s: experimental, install explicitly after review (no approved snapshot)\n' "$id"
            else
                printf 'blocked %s: no approved snapshot\n' "$id"
            fi
        done < <(inventory_rows)
        ;;
    install|setup|update|repair)
        install_selected
        ;;
    auth|auth-status|login-status) auth_status_json ;;
    product-status) product_status_json ;;
    provenance|sources|source-status) provenance_status_json ;;
    manifest|manifest-check) manifest_check_json ;;
    detailed-status|detailed|overview) detailed_status_json ;;
    configure-ides|ides|configure|ensure|use|prepare|open|open-client|launch|set-credentials|credentials|start|enable|restart|test|verify)
        connection_grant_blocked
        exit 69
        ;;
    stop|disable) service_action stop ;;
    login)
        if [ "$TARGET" = all ]; then
            # Batch OAuth: open one headed login per browser-session proxy that
            # still needs it. login_proxy detaches and skips proxies already
            # authenticated, so this stays honest and non-blocking.
            for login_id in "${LOGIN_CAPABLE_PROXIES[@]}"; do
                login_proxy "$login_id" || pz_warn "login flow failed to open for $login_id"
            done
        else
            login_proxy "$TARGET"
        fi
        ;;
    open-studio)
        open_mimo_studio
        ;;
    *) pz_error "usage: proxy-suite.sh (status|detailed-status|provenance|plan|install|configure-ides|auth|product-status|test|start|stop|restart|login|ensure|open|set-credentials) [all|id] [--dry-run]"; exit 2 ;;
esac
