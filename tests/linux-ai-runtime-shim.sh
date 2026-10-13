#!/usr/bin/env bash
# shellcheck disable=SC2034 # NODE_BIN/NPM_CLI feed the eval-extracted functions
# AISR-001: 9Router and the proxy suite share $PROXY_ROOT/.runtime/node24. The
# proxies resolve `npx tsx` through $RUNTIME/bin/node and carry Node 24 native
# modules, so 9Router must never repoint that shim to a newer system Node.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

extract_fn() {
    awk -v name="$2" '
        $0 ~ "^" name "\\(\\) \\{" { on = 1 }
        on { print }
        on && /^}/ { exit }
    ' "$1"
}

pz_debug() { :; }
pz_info() { :; }
pz_warn() { printf 'WARN: %s\n' "$*" >&2; }
pz_error() { printf 'ERROR: %s\n' "$*" >&2; }

# Fake toolchain: a "system" Node 26 on PATH, the isolated Node 24 in the runtime.
PROXY_ROOT="$WORK/ai-proxies"
RUNTIME="$PROXY_ROOT/.runtime/node24"
mkdir -p "$WORK/sysbin" "$RUNTIME/node_modules/node/bin" "$RUNTIME/node_modules/npm/bin"
printf '#!/bin/sh\necho v26.8.1\n' > "$WORK/sysbin/node"
printf '#!/bin/sh\necho 11.0.0\n' > "$WORK/sysbin/npm"
printf '#!/bin/sh\necho v24.19.0\n' > "$RUNTIME/node_modules/node/bin/node"
: > "$RUNTIME/node_modules/npm/bin/npm-cli.js"
chmod +x "$WORK/sysbin/node" "$WORK/sysbin/npm" "$RUNTIME/node_modules/node/bin/node"
PATH="$WORK/sysbin:$PATH"
ISOLATED="$RUNTIME/node_modules/node/bin/node"
mkdir -p "$RUNTIME/bin"
ln -sfn "$ISOLATED" "$RUNTIME/bin/node"

# 1. 9Router adopts the system Node 26 without touching the proxy shim.
eval "$(extract_fn "$ROOT/linux/ai/9router-manager.sh" ensure_node_runtime)"
ROUTER_BIN="$PROXY_ROOT/.runtime/9router-bin"
NODE_BIN="$ISOLATED"
NPM_CLI="$RUNTIME/node_modules/npm/bin/npm-cli.js"
ln -sfn "$WORK/sysbin/npm" "$WORK/sysbin/npm-cli.js"
ensure_node_runtime
[ "$(readlink -f "$ROUTER_BIN/node")" = "$(readlink -f "$WORK/sysbin/node")" ]
[ "$(readlink -f "$RUNTIME/bin/node")" = "$(readlink -f "$ISOLATED")" ] || {
    echo "FAIL: 9Router repointed the proxy runtime shim" >&2
    exit 1
}
# shellcheck disable=SC2016 # Match literal shell source.
grep -q 'ROUTER_BIN="$PROXY_ROOT/.runtime/9router-bin"' "$ROOT/linux/ai/9router-manager.sh"

# 2. The proxy suite heals a shim an older 9Router already repointed.
ln -sfn "$WORK/sysbin/node" "$RUNTIME/bin/node"
eval "$(extract_fn "$ROOT/linux/ai/proxy-suite.sh" repair_runtime_shim)"
NODE_BIN="$ISOLATED"
repair_runtime_shim 2> "$WORK/warn.log"
[ "$(readlink -f "$RUNTIME/bin/node")" = "$(readlink -f "$ISOLATED")" ]
grep -q 'repointed to isolated Node v24' "$WORK/warn.log"
# Idempotent: no warning once the shim is right.
repair_runtime_shim 2> "$WORK/warn2.log"
[ ! -s "$WORK/warn2.log" ]
# Guarded handlers retain shim repair after the request-grant gate.
service_action_body="$(sed -n '/^service_action() {/,/^}/p' "$ROOT/linux/ai/proxy-suite.sh")"
test_proxies_body="$(sed -n '/^test_proxies() {/,/^}/p' "$ROOT/linux/ai/proxy-suite.sh")"
grep -q 'connection_grant_blocked' <<< "$service_action_body"
grep -q 'repair_runtime_shim' <<< "$service_action_body"
grep -q 'connection_grant_blocked' <<< "$test_proxies_body"
grep -q 'repair_runtime_shim' <<< "$test_proxies_body"

echo "PASS: proxy runtime shim isolated from 9Router"
