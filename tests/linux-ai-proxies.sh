#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
export WORK
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
# proxy-suite.sh resolves opencode/zcode/ide-defaults under $XDG_CONFIG_HOME, so
# keep it aligned with the seeded $HOME/.config tree (Continue already uses HOME).
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$WORK/state"
export PZ_AI_PROXY_SKIP_EXTENSION_INSTALL=1
mkdir -p "$HOME/.config/opencode" "$HOME/.continue/index"
printf '{}\n' > "$HOME/.config/opencode/opencode.json"
printf '{}\n' > "$HOME/.config/opencode/opencode.jsonc"
printf '%s\n' '{"selectedModelsByProfileId":{"local":{"chat":"[PhaseZero Proxy] Kimi — old","edit":null,"apply":"External model"}}}' \
    > "$HOME/.continue/index/globalContext.json"

expect_grant_block() {
    local output rc
    set +e
    output="$("$@" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 69 ] || {
        printf 'FAIL: expected grant block (exit 69), got %s: %s\n' "$rc" "$output" >&2
        return 1
    }
    jq -e '.status == "blocked" and .blockedReason == "connection-grant-not-enforceable"' \
        <<< "$output" >/dev/null
}

grep -q 'apply_loopback_patch' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'PZ_BIND_HOST' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'unsafe dotenv variable rejected' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'secure proxy key generation failed' "$ROOT/linux/ai/proxy-suite.sh"
status="$("$ROOT/linux/pz" ai proxies status)"
[ "$(jq 'length' <<< "$status")" -eq 11 ]
jq -e 'map(.id) | index("qwen-worker-proxy") != null and index("unlimited-ai-proxy") != null' <<< "$status" >/dev/null
jq -e '
  .[] | select(.id == "unlimited-ai-proxy") | .kind == "node" and .port == 8787
' <<< "$status" >/dev/null
jq -e '
  .[] | select(.id == "mimo-ai-proxy") | .kind == "go" and .port == 3013
' <<< "$status" >/dev/null
plan="$("$ROOT/linux/pz" ai proxies plan all)"
[ "$(grep -c '^would install ' <<< "$plan")" -eq 4 ]
# PZ-AUD-018: one supported set for batch actions; the rest is explicit
# preview, never an indistinct blocked batch.
[ "$(grep -c '^preview ' <<< "$plan")" -eq 6 ]
[ "$(grep -c '^blocked ' <<< "$plan")" -eq 0 ]
grep -Eq '^would install kimiproxy .* at commit [0-9a-f]{40} ' <<< "$plan"
auth="$("$ROOT/linux/pz" ai proxies auth all)"
[ "$(jq 'length' <<< "$auth")" -eq 11 ]
scoped_auth="$("$ROOT/linux/pz" ai proxies auth qwenproxy)"
[ "$(jq 'length' <<< "$scoped_auth")" -eq 1 ]
jq -e '.[0].id == "qwenproxy"' <<< "$scoped_auth" >/dev/null
product_status="$("$ROOT/linux/pz" ai proxies product-status qwenproxy)"
jq -e '
  .schemaVersion == 1 and .hasStatus == true and
  .installationState == "unknown" and .origin == "unknown" and
  .configurationState == "needed" and .manager == "phasezero-ai-proxy-suite" and
  (keys | sort) == ["configurationState","hasStatus","health","installationState",
                    "manager","origin","schemaVersion"]
' <<< "$product_status" >/dev/null
if "$ROOT/linux/pz" ai proxies product-status all >/dev/null 2>&1; then
    echo "FAIL: product status accepted aggregate target"
    exit 1
fi
jq -e '
  .[] | select(.id == "qwenproxy") |
  .webValidation.required == true and
  .webValidation.kind == "browser-session" and
  (.webValidation.command | test("login qwenproxy"))
' <<< "$auth" >/dev/null
jq -e '
  .[] | select(.id == "mimo-ai-proxy") |
  .webValidation.required == true and
  .webValidation.kind == "official-api-key" and
  .webValidation.status == "missing-credentials" and
  .webValidation.missing == ["api-key"]
' <<< "$auth" >/dev/null
jq -e '
  .[] | select(.id == "9router") |
  .webValidation.command == "blocked:connection-grant-not-enforceable"
' <<< "$auth" >/dev/null
if grep -Eq 'SERVICE_TOKEN|USER_ID|XIAOMI_CHATBOT_PH|API_KEY|phasezero-qwen' <<< "$auth"; then
    echo "FAIL: credentials leaked into proxies auth output"
    exit 1
fi
before_opencode="$(sha256sum "$HOME/.config/opencode/opencode.json" | awk '{print $1}')"
before_continue_context="$(sha256sum "$HOME/.continue/index/globalContext.json" | awk '{print $1}')"
expect_grant_block "$ROOT/linux/pz" ai proxies configure-ides
[ "$(sha256sum "$HOME/.config/opencode/opencode.json" | awk '{print $1}')" = "$before_opencode" ]
[ "$(sha256sum "$HOME/.continue/index/globalContext.json" | awk '{print $1}')" = "$before_continue_context" ]
[ ! -e "$HOME/.continue/config.json" ]
mkdir -p "$HOME/.local/share/phasezero/ai-proxies/deepsproxy/.git" \
    "$HOME/.local/share/phasezero/ai-proxies/deepsproxy/deepseek_profile/Default"
printf 'session-data\n' > "$HOME/.local/share/phasezero/ai-proxies/deepsproxy/deepseek_profile/Default/Cookies"
DISPLAY=:0 "$ROOT/linux/pz" ai proxies auth deepsproxy \
    | jq -e '.[0].webValidation.status == "session-present"' >/dev/null
grep -q 'done < <(selected_rows)' "$ROOT/linux/ai/proxy-suite.sh"

# Consolidated snapshot for the native UI "Proxies IA" page: same 11 proxies as
# auth plus redacted IDE integration counters, in a single read-only command.
detailed="$("$ROOT/linux/pz" ai proxies detailed-status)"
jq -e '.schemaVersion == 1 and (.proxies | length == 11)' <<< "$detailed" >/dev/null
jq -e '.proxies[] | select(.id == "deepsproxy") | .webValidation.kind == "browser-session"' <<< "$detailed" >/dev/null
jq -e '.ide | has("envDefaults") and has("opencodeProviders") and has("continueModels") and has("zcodeProviders")' <<< "$detailed" >/dev/null
jq -e '.ide.envDefaults == false and .ide.opencodeProviders == 0 and .ide.continueModels == 0 and .ide.zcodeProviders == 0' <<< "$detailed" >/dev/null
jq -e '.provenance.trustMode == "snapshot-pin" and .provenance.semanticAudit == false and (.provenance.sources | length == 4)' <<< "$detailed" >/dev/null
if grep -Eq 'API_KEY=|Bearer ' <<< "$detailed"; then
    echo "FAIL: credentials leaked into detailed auth output"
    exit 1
fi
grep -q 'configure-ides|ides|configure|ensure|use|prepare|open|open-client|launch|set-credentials|credentials|start|enable|restart|test|verify' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'SuccessExitStatus=143' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'emit_login_json' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'login_window_kind' "$ROOT/linux/ai/proxy-suite.sh"
login_watcher="$(sed -n '/^watch_login_completion() {/,/^}$/p' "$ROOT/linux/ai/proxy-suite.sh")"
grep -q 'record_login_authenticated' <<< "$login_watcher"
if grep -Eq 'start_proxy_service|wait_proxy_chat|quick_chat_ok' <<< "$login_watcher"; then
    echo "FAIL: browser login starts service or sends inference"
    exit 1
fi
login_impl="$(sed -n '/^login_proxy() {/,/^}$/p' "$ROOT/linux/ai/proxy-suite.sh")"
if grep -Eq 'quick_chat_ok|proxy_chat_probe|start_proxy_service' <<< "$login_impl"; then
    echo "FAIL: login route sends inference or starts consumer"
    exit 1
fi
grep -q 'serviceAfterLogin:"stopped"' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'set_proxy_credentials' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'open_opencode_proxy' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'qwenproxy.db' "$ROOT/linux/ai/proxy-suite.sh"
# MiMo normal flow must use the official API and reject session scraping instructions.
grep -q 'phasezero-mimo-official' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'MIMO_PROVIDER_KEY' "$ROOT/linux/ai/proxy-suite.sh"
if grep -q 'F12.*Rede.*bot/chat' "$ROOT/linux/ai/proxy-suite.sh"; then
    echo "FAIL: MiMo journey still instructs DevTools session extraction"
    exit 1
fi
# Regression: `[ id = qwenproxy ] && pz_info` as last command made kimi/deeps login exit 1.
if grep -n "\\[ \"\\\$id\" = qwenproxy \\] && pz_info" "$ROOT/linux/ai/proxy-suite.sh"; then
    echo "FAIL: login_proxy still ends with a failing && for non-qwen ids"
    exit 1
fi
# Kimi/DeepSeek must execute the pinned local tsx runtime directly. `npm run
# login` re-entered npx and stalled before the script's first log line.
# Patterns match literal $ in the proxy source; no expansion is intended.
# shellcheck disable=SC2016
grep -q '"\$NODE_BIN" "\$tsx" src/login.ts' "$ROOT/linux/ai/proxy-suite.sh"
# shellcheck disable=SC2016
grep -q 'session_artifact_present "\$id"' "$ROOT/linux/ai/proxy-suite.sh"
# Remove deliberately incomplete auth-only fixture before provenance-gated ensure.
rm -rf "$HOME/.local/share/phasezero/ai-proxies/deepsproxy"
expect_grant_block "$ROOT/linux/pz" ai proxies ensure qwenproxy --dry-run
expect_grant_block "$ROOT/linux/pz" ai proxies ensure all --dry-run
expect_grant_block "$ROOT/linux/pz" ai proxies open qwenproxy
expect_grant_block "$ROOT/linux/pz" ai proxies start qwenproxy
expect_grant_block "$ROOT/linux/pz" ai proxies test qwenproxy
expect_grant_block "$ROOT/linux/pz" ai proxies test all
expect_grant_block "$ROOT/linux/pz" ai proxies restart qwenproxy
expect_grant_block "$ROOT/linux/pz" ai proxies enable all

# Trusted-source manifest must pin four exact snapshots, never a moving branch.
jq -e '
  .trustMode == "snapshot-pin" and .semanticAudit == false and
  (.sources | length == 4) and
  all(.sources[]; (.commit | test("^[0-9a-f]{40}$")) and (.tree | test("^[0-9a-f]{40}$")) and .approvedForInstall == true)
' "$ROOT/assets/ai/proxy-suite-trusted-sources.json" >/dev/null

# Build a local exact snapshot. It validates provenance without network access.
mkdir -p "$WORK/bin" "$WORK/mimo-source" "$HOME/.config/phasezero/ai-proxies"
printf '%s\n' 'package main' 'func main() {}' > "$WORK/mimo-source/main.go"
printf '%s\n' 'test license' > "$WORK/mimo-source/LICENSE"
printf '%s\n' 'example.invalid/module v1.0.0 h1:test' > "$WORK/mimo-source/go.sum"
git -C "$WORK/mimo-source" init -q
git -C "$WORK/mimo-source" config user.name PhaseZero
git -C "$WORK/mimo-source" config user.email phasezero@example.invalid
git -C "$WORK/mimo-source" add main.go LICENSE go.sum
git -C "$WORK/mimo-source" commit -qm snapshot
mimo_commit="$(git -C "$WORK/mimo-source" rev-parse HEAD)"
mimo_tree="$(git -C "$WORK/mimo-source" rev-parse 'HEAD^{tree}')"
mimo_license="$(sha256sum "$WORK/mimo-source/LICENSE" | awk '{print $1}')"
mimo_lock="$(sha256sum "$WORK/mimo-source/go.sum" | awk '{print $1}')"
rm -rf "$HOME/.local/share/phasezero/ai-proxies/mimo-ai-proxy"
git clone -q "$WORK/mimo-source" "$HOME/.local/share/phasezero/ai-proxies/mimo-ai-proxy"
jq -n --arg repo "$WORK/mimo-source" --arg commit "$mimo_commit" --arg tree "$mimo_tree" \
    --arg license "$mimo_license" --arg lock "$mimo_lock" '
  {schemaVersion:1,trustMode:"snapshot-pin",semanticAudit:false,sources:[{
    id:"mimo-ai-proxy",repository:$repo,branch:"main",commit:$commit,tree:$tree,
    approvedForInstall:true,license:{path:"LICENSE",spdx:"test",sha256:$license},
    dependencyLocks:[{path:"go.sum",sha256:$lock}]
  }]}
' > "$WORK/mimo-manifest.json"
PZ_AI_PROXY_TRUSTED_SOURCES_FILE="$WORK/mimo-manifest.json" \
    "$ROOT/linux/pz" ai proxies provenance mimo-ai-proxy \
    | jq -e '.sources[0].ready == true and .sources[0].commitMatch == true' >/dev/null

# MiMo credentials cannot enter a legacy file or wire consumers until the
# secret-store reference and per-request grant adapter are connected.
cat > "$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "$WORK/curl-called"
printf '200'
SH
chmod +x "$WORK/bin/curl"
set +e
mimo_key_result="$(printf '%s\n' '{"apiKey":"sk-fixture-only-key","baseUrl":"https://api.xiaomimimo.com/v1","model":"mimo-v2.5-pro"}' \
  | PATH="$WORK/bin:$PATH" "$ROOT/linux/pz" ai proxies set-credentials mimo-ai-proxy 2>&1)"
mimo_key_rc=$?
set -e
[ "$mimo_key_rc" -eq 69 ]
jq -e '.status == "blocked" and .blockedReason == "connection-grant-not-enforceable"' \
    <<< "$mimo_key_result" >/dev/null
[ ! -e "$HOME/.config/phasezero/ai-providers/mimo/api-key" ]
[ ! -e "$WORK/curl-called" ]
expect_grant_block env PATH="$WORK/bin:$PATH" "$ROOT/linux/pz" ai proxies ensure mimo-ai-proxy

# A commit mismatch blocks runtime before systemctl can start anything.
git -C "$HOME/.local/share/phasezero/ai-proxies/mimo-ai-proxy" config user.name PhaseZero
git -C "$HOME/.local/share/phasezero/ai-proxies/mimo-ai-proxy" config user.email phasezero@example.invalid
git -C "$HOME/.local/share/phasezero/ai-proxies/mimo-ai-proxy" commit --allow-empty -qm unapproved
cat > "$WORK/bin/systemctl" <<SH
#!/usr/bin/env bash
printf '%s\n' called >> "$WORK/systemctl-called"
exit 0
SH
chmod +x "$WORK/bin/systemctl"
expect_grant_block env PZ_AI_PROXY_TRUSTED_SOURCES_FILE="$WORK/mimo-manifest.json" \
    PATH="$WORK/bin:$PATH" "$ROOT/linux/pz" ai proxies start mimo-ai-proxy
[ ! -e "$WORK/systemctl-called" ]
PZ_AI_PROXY_TRUSTED_SOURCES_FILE="$WORK/mimo-manifest.json" \
    "$ROOT/linux/pz" ai proxies provenance mimo-ai-proxy \
    | jq -e '.sources[0].ready == false and .sources[0].commitMatch == false' >/dev/null
grep -q 'start_proxy_service' "$ROOT/linux/ai/proxy-suite.sh"
grep -q 'wait_proxy_chat' "$ROOT/linux/ai/proxy-suite.sh"

echo "=== proxy build is transactional with validated runtimes (PZ-AUD-016/017) ==="
export PZ_AI_PROXY_ROOT="$WORK/tx-proxies" PZ_LOCAL_BIN="$WORK/tx-bin"
mkdir -p "$PZ_AI_PROXY_ROOT" "$PZ_LOCAL_BIN"
# A failing npm step rejects the install and removes the fresh clone.
if bash -c '
    set -- status kimiproxy
    source "$0/linux/ai/proxy-suite.sh" >/dev/null 2>&1
    ensure_node_runtime() { return 0; }
    clone_approved_snapshot() {
        mkdir -p "$3/.git"
        printf "%s\n" "{\"scripts\":{\"start\":\"node dist/index.js\"}}" > "$3/package.json"
        printf "%s\n" "{}" > "$3/package-lock.json"
    }
    run_npm() { echo fixture-npm-failed >&2; return 42; }
    apply_loopback_patch() { return 0; }
    install_one kimiproxy https://example.invalid/fixture.git 3010 node
' "$ROOT" >/dev/null 2>&1; then
    echo "FAIL: failed npm build was accepted"; exit 1
fi
[ ! -e "$PZ_AI_PROXY_ROOT/kimiproxy" ] || { echo "FAIL: partial clone left behind"; exit 1; }
# A missing Go toolchain fails closed with an actionable reason.
go_out="$(bash -c '
    set -- status mimo-ai-proxy
    source "$0/linux/ai/proxy-suite.sh" >/dev/null 2>&1
    command() { [ "$1" = "-v" ] && [ "$2" = "git" ] && return 0; return 1; }
    install_one mimo-ai-proxy https://example.invalid/fixture.git 3013 go
' "$ROOT" 2>&1 || true)"
if grep -qi "go toolchain" <<< "$go_out"; then
    :
else
    echo "FAIL: missing go toolchain not reported"; exit 1
fi
# A node proxy installed without dist/ fails artifact verification.
if bash -c '
    set -- status kimiproxy
    source "$0/linux/ai/proxy-suite.sh" >/dev/null 2>&1
    verify_proxy_artifacts kimiproxy node "$0/nonexistent-dir"
' "$ROOT" >/dev/null 2>&1; then
    echo "FAIL: artifact verification accepted missing dist"; exit 1
fi
echo "  transactional build ok"

echo "=== proxy manifest is the cross-OS contract (PZ-AUD-019) ==="
manifest_out="$("$ROOT/linux/pz" ai proxies manifest 2>/dev/null)"
echo "$manifest_out" | jq -e '.ok == true and (.checks | length == 0)' >/dev/null
# Manifest pins/ports/repos agree with approved snapshots and catalog rows.
for pid in kimiproxy qwenproxy deepsproxy mimo-ai-proxy; do
    mrepo="$(jq -r --arg i "$pid" '.proxies[] | select(.id == $i) | .repository' "$ROOT/assets/ai/proxy-manifest.json")"
    mcommit="$(jq -r --arg i "$pid" '.proxies[] | select(.id == $i) | .pin.commit // empty' "$ROOT/assets/ai/proxy-manifest.json")"
    srepo="$(jq -r --arg i "$pid" '.sources[] | select(.id == $i) | .repository' "$ROOT/assets/ai/proxy-suite-trusted-sources.json")"
    scommit="$(jq -r --arg i "$pid" '.sources[] | select(.id == $i) | .commit' "$ROOT/assets/ai/proxy-suite-trusted-sources.json")"
    [ "$mrepo" = "$srepo" ] || { echo "FAIL: manifest repo drift for $pid"; exit 1; }
    [ "$mcommit" = "$scommit" ] || { echo "FAIL: manifest pin drift for $pid"; exit 1; }
done
echo "  manifest contract ok"
bash "$ROOT/tests/linux-omniroute-grant-gate.sh"
echo "linux-ai-proxies smoke ok"
