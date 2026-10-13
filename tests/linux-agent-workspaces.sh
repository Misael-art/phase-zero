#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME" "$TMP_ROOT/bin"

write_stub() {
    local name="$1"
    shift
    cat > "$TMP_ROOT/bin/$name"
    chmod +x "$TMP_ROOT/bin/$name"
}

write_stub hermes-manager <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = plan ]; then
  printf '%s\n' '{"schemaVersion":1,"id":"hermes","mode":"read-only-plan","deploymentAllowed":false,"blockers":["hermes-installer-untrusted"],"secretsRedacted":true}'
  exit 0
fi
cat <<'JSON'
{"schemaVersion":1,"id":"hermes","diagnosticComplete":true,"ready":false,
 "status":{"configured":false},"distribution":{"sha256Pinned":false},
 "issues":[{"severity":"error","component":"hermes","code":"hermes-installer-untrusted"}],
 "secretsRedacted":true}
JSON
SH

write_stub odysseus-manager <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = plan ]; then
  printf '%s\n' '{"schemaVersion":1,"id":"odysseus","mode":"read-only-plan","deploymentAllowed":false,"blockers":["upstream-commit-untrusted"],"secretsRedacted":true}'
  exit 0
fi
cat <<'JSON'
{"schemaVersion":1,"id":"odysseus","diagnosticComplete":true,"configured":false,"ready":false,"secure":false,"healthy":false,"commitTrusted":false,
 "issues":[{"severity":"error","component":"odysseus","code":"odysseus-commit-untrusted"}],
 "secretsRedacted":true}
JSON
SH

write_stub router-manager <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schemaVersion":1,"installed":true,"healthy":true,"secretsRedacted":true}'
SH

write_stub governor <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schemaVersion":1,"profile":"assistant-private","verdict":"pass","budgetMB":4224,"reasons":[]}'
SH

write_stub policy <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schemaVersion":1,"mode":"conservative","conservative":true,"deniedActions":["hermes-install"]}'
SH

write_stub docker <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  info) exit 0 ;;
  ps) printf '%s\n' 'akitaonrails/ai-memory:1.0|Up 2 hours (healthy)' ;;
esac
SH

write_stub podman <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = info ]; then printf '%s\n' 'true'; exit 0; fi
exit 1
SH

write_stub tailscale <<'SH'
#!/usr/bin/env bash
exit 1
SH

write_stub ollama <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'ollama version 1.0-test'
SH

write_stub curl <<'SH'
#!/usr/bin/env bash
exit 1
SH
write_stub xdg-open <<SH
#!/usr/bin/env bash
printf '%s\\n' called >> "$TMP_ROOT/odysseus-open-called"
SH

write_stub ss <<'SH'
#!/usr/bin/env bash
exit 0
SH

export PATH="$TMP_ROOT/bin:/usr/bin:/bin"
export PZ_HERMES_MANAGER="$TMP_ROOT/bin/hermes-manager"
export PZ_ODYSSEUS_MANAGER="$TMP_ROOT/bin/odysseus-manager"
export PZ_9ROUTER_MANAGER="$TMP_ROOT/bin/router-manager"
export PZ_HOMELAB_GOVERNOR="$TMP_ROOT/bin/governor"
export PZ_AI_POLICY_BROKER="$TMP_ROOT/bin/policy"

output="$(bash "$ROOT/linux/ai/agent-workspaces-diagnostic.sh" doctor)"
jq -e '
  .schemaVersion == 1 and .tool == "agent-workspaces-diagnostic"
  and .mode == "read-only" and .diagnosticComplete == true
  and .deploymentAllowed == false and .ready == false
  and .configurationReady == false
  and .components.router.healthy == true
  and .components.aiMemory.healthy == true
  and .runtime.podman.rootless == true
  and (.issues | any(.code == "roadmap-host-deployment-blocked"))
  and (.issues | any(.code == "hermes-installer-untrusted"))
  and (.issues | any(.code == "odysseus-commit-untrusted"))
  and (.issues | all(.component != null and .component != ""))
  and (.plan.phases | any(.id == "deploy" and .state == "blocked"))
  and .secretsRedacted == true
' <<< "$output" >/dev/null
if grep -q 'SENTINEL_SECRET' <<< "$output"; then
    echo "FAIL: diagnostic leaked secret sentinel" >&2
    exit 1
fi

plan_output="$(bash "$ROOT/linux/ai/agent-workspaces-diagnostic.sh" plan)"
jq -e '
  .action == "plan"
  and .componentPlans.hermes.mode == "read-only-plan"
  and .componentPlans.odysseus.mode == "read-only-plan"
  and .componentPlans.hermes.deploymentAllowed == false
  and .componentPlans.odysseus.deploymentAllowed == false
' <<< "$plan_output" >/dev/null

hermes_status="$(HERMES_HOME="$HOME/.hermes" PZ_LOCAL_BIN="$HOME/.local/bin" bash "$ROOT/linux/ai/setup-hermes.sh" status)"
jq -e '.schemaVersion == 1 and .installed == false and .ready == false and .doctor.outputRedacted == true and .secretsRedacted == true' \
    <<< "$hermes_status" >/dev/null
grep -Fq "HERMES_GATEWAY_DROPIN=\"\${HERMES_GATEWAY_SERVICE}.d/phasezero.conf\"" "$ROOT/linux/ai/setup-hermes.sh"
grep -Fq "ExecStart=\$LOCAL_BIN/hermes gateway run" "$ROOT/linux/ai/setup-hermes.sh"
grep -Fq 'UnsetEnvironment=PHASEZERO_ADMIN PHASEZERO_ADMIN_BACKEND PHASEZERO_ADMIN_COMMAND' "$ROOT/linux/ai/setup-hermes.sh"
test "$(grep -Fc 'unset PYTHONPATH PYTHONHOME PHASEZERO_ADMIN PHASEZERO_ADMIN_BACKEND PHASEZERO_ADMIN_COMMAND' \
    "$ROOT/linux/ai/setup-hermes.sh")" -eq 3

mkdir -p "$XDG_CONFIG_HOME/phasezero/ai"
printf '%s\n' 'OPENAI_API_KEY=SENTINEL_SECRET' > "$XDG_CONFIG_HOME/phasezero/ai/hermes.env"
chmod 0600 "$XDG_CONFIG_HOME/phasezero/ai/hermes.env"
hermes_status="$(HERMES_HOME="$HOME/.hermes" PZ_LOCAL_BIN="$HOME/.local/bin" bash "$ROOT/linux/ai/setup-hermes.sh" status)"
jq -e '.auth.configured == true and .secretsRedacted == true' <<< "$hermes_status" >/dev/null
if grep -q 'SENTINEL_SECRET' <<< "$hermes_status"; then
    echo "FAIL: Hermes status leaked credential value" >&2
    exit 1
fi
mkdir -p "$HOME/.hermes"
printf '%s\n' 'model: test' > "$HOME/.hermes/config.yaml"
chmod 0644 "$HOME/.hermes/config.yaml"
hermes_doctor="$(HERMES_HOME="$HOME/.hermes" PZ_LOCAL_BIN="$HOME/.local/bin" bash "$ROOT/linux/ai/setup-hermes.sh" doctor)"
jq -e '.status.configured == false and .distribution.manifestValid == true
    and .distribution.installerPinned == true and .distribution.approvedForInstall == false
    and .distribution.transitiveArtifactsPinned == false and .distribution.semanticAudit == false
    and (.issues | any(.code == "hermes-config-permissions-unsafe"))
    and (.issues | any(.code == "hermes-distribution-unapproved"))
    and (.issues | any(.code == "hermes-transitive-artifacts-unpinned"))' \
    <<< "$hermes_doctor" >/dev/null

set +e
HERMES_HOME="$HOME/gated-hermes" bash "$ROOT/linux/ai/setup-hermes.sh" configure >/dev/null 2>&1
hermes_gate_rc=$?
set -e
test "$hermes_gate_rc" -eq 69
test ! -e "$HOME/gated-hermes"

# An operator-supplied checksum cannot promote an unaudited remote script.
write_stub curl <<SH
#!/usr/bin/env bash
printf '%s\n' called >> "$TMP_ROOT/hermes-curl-called"
exit 1
SH
set +e
PZ_HOMELAB_ALLOW_HOST_WORKLOADS=1 PZ_HERMES_INSTALL_SHA256="$(printf 'a%.0s' {1..64})" \
    HERMES_HOME="$HOME/checksum-bypass-hermes" \
    bash "$ROOT/linux/ai/setup-hermes.sh" install >/dev/null 2>&1
hermes_distribution_rc=$?
set -e
test "$hermes_distribution_rc" -eq 69
test ! -e "$TMP_ROOT/hermes-curl-called"
test ! -e "$HOME/checksum-bypass-hermes"

odysseus_status="$(PZ_ODYSSEUS_ROOT="$HOME/odysseus" bash "$ROOT/linux/ai/odysseus-manager.sh" status)"
jq -e '.schemaVersion == 1 and .installed == false and .configured == false and .ready == false
    and .usageBlocked == true and .blockedReason == "connection-grant-not-enforceable"
    and .provenance.releaseAudit.manifestValid == true
    and .provenance.releaseAudit.approvedForDeploy == false
    and .provenance.releaseAudit.baseImagesPinned == true
    and .provenance.releaseAudit.pythonDependenciesLocked == false
    and .secretsRedacted == true' \
    <<< "$odysseus_status" >/dev/null

for action in install start restart update open; do
    set +e
    odysseus_action_output="$(PZ_ODYSSEUS_ROOT="$HOME/odysseus" \
        bash "$ROOT/linux/ai/odysseus-manager.sh" "$action" 2>&1)"
    odysseus_action_rc=$?
    set -e
    test "$odysseus_action_rc" -eq 69
    jq -e '.status == "blocked" and .blockedReason == "connection-grant-not-enforceable"' \
        <<< "$odysseus_action_output" >/dev/null
done
test ! -e "$TMP_ROOT/odysseus-open-called"
grep -Fq 'Name=Odysseus (uso bloqueado)' "$ROOT/linux/ai/odysseus-manager.sh"
grep -Fq 'Terminal=true' "$ROOT/linux/ai/odysseus-manager.sh"

set +e
PZ_ODYSSEUS_ROOT="$HOME/gated-odysseus" bash "$ROOT/linux/ai/odysseus-manager.sh" install >/dev/null 2>&1
odysseus_gate_rc=$?
set -e
test "$odysseus_gate_rc" -eq 69
test ! -e "$HOME/gated-odysseus"

external="$TMP_ROOT/external-odysseus"
odysseus_root="$HOME/unsafe-odysseus"
odysseus_config="$XDG_CONFIG_HOME/phasezero/odysseus"
trusted="$TMP_ROOT/trusted-commits.json"
approved_audit="$TMP_ROOT/approved-release-audit.json"
commit="0123456789abcdef0123456789abcdef01234567"
tree="89abcdef0123456789abcdef0123456789abcdef"
mkdir -p "$external" "$odysseus_root" "$odysseus_config"
touch "$external/docker-compose.yml"
ln -s "$external" "$odysseus_root/current"
printf '%s\n' "{\"schemaVersion\":1,\"commits\":[{\"commit\":\"$commit\",\"tree\":\"$tree\"}]}" > "$trusted"
jq --arg commit "$commit" --arg tree "$tree" \
  '.source.commit=$commit | .source.tree=$tree | .semanticAudit=true |
   .pythonDependenciesLocked=true | .approvedForDeploy=true' \
  "$ROOT/assets/ai/odysseus-release-audit.json" > "$approved_audit"
printf '%s\n' "{\"schemaVersion\":1,\"commit\":\"$commit\",\"tree\":\"$tree\"}" > "$odysseus_config/manifest.json"
printf '%s\n' 'AUTH_ENABLED=true' 'LOCALHOST_BYPASS=false' > "$odysseus_config/odysseus.env"
chmod 0600 "$odysseus_config/odysseus.env"
chroma_ref="$(jq -r '.images[] | select(.service=="chromadb") | .reference' "$ROOT/assets/ai/odysseus-dependency-images.json")"
searx_ref="$(jq -r '.images[] | select(.service=="searxng") | .reference' "$ROOT/assets/ai/odysseus-dependency-images.json")"
ntfy_ref="$(jq -r '.images[] | select(.service=="ntfy") | .reference' "$ROOT/assets/ai/odysseus-dependency-images.json")"
cat > "$odysseus_config/compose.images.lock.yml" <<YAML
services:
  chromadb:
    image: $chroma_ref
  searxng:
    image: $searx_ref
  ntfy:
    image: $ntfy_ref
YAML
unsafe_status="$(PZ_ODYSSEUS_ROOT="$odysseus_root" PZ_ODYSSEUS_TRUSTED_COMMITS_FILE="$trusted" bash "$ROOT/linux/ai/odysseus-manager.sh" status)"
jq -e '.installed == true and .pathsSafe == false and .configured == false and .ready == false
  and .provenance.dependencyImageManifestValid == true
  and .provenance.dependencyImagesLocked == true
  and .provenance.buildBaseManifestValid == true
  and .provenance.releaseAuditApproved == false
  and .provenance.semanticAudit == false' <<< "$unsafe_status" >/dev/null

# A changed image digest invalidates the lock and blocks start before systemctl mutation.
sed -i 's/sha256:1e0b/sha256:ffff/' "$odysseus_config/compose.images.lock.yml"
tampered_status="$(PZ_ODYSSEUS_ROOT="$odysseus_root" PZ_ODYSSEUS_TRUSTED_COMMITS_FILE="$trusted" bash "$ROOT/linux/ai/odysseus-manager.sh" status)"
jq -e '.provenance.dependencyImageManifestValid == true and .provenance.dependencyImagesLocked == false' \
    <<< "$tampered_status" >/dev/null
write_stub systemctl <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = is-active ]; then printf '%s\n' inactive; exit 3; fi
printf '%s\n' mutate >> "$TMP_ROOT/systemctl-mutate"
exit 0
SH
set +e
PZ_HOMELAB_ALLOW_HOST_WORKLOADS=1 PZ_ODYSSEUS_ROOT="$odysseus_root" \
    PZ_ODYSSEUS_TRUSTED_COMMITS_FILE="$trusted" \
    bash "$ROOT/linux/ai/odysseus-manager.sh" start >/dev/null 2>&1
odysseus_start_rc=$?
set -e
test "$odysseus_start_rc" -eq 69
test ! -e "$TMP_ROOT/systemctl-mutate"

# Invalid image manifest blocks provision before the first directory write.
bad_images="$TMP_ROOT/bad-images.json"
printf '%s\n' '{"schemaVersion":1,"trustMode":"registry-manifest-digest","semanticAudit":false,"images":[]}' > "$bad_images"
write_stub git <<SH
#!/usr/bin/env bash
printf '%s\n' '$commit refs/heads/dev'
SH
# Even an allowlisted commit cannot deploy while release audit stays incomplete.
set +e
PZ_HOMELAB_ALLOW_HOST_WORKLOADS=1 PZ_ODYSSEUS_ROOT="$HOME/audit-gated-odysseus" \
    PZ_ODYSSEUS_TRUSTED_COMMITS_FILE="$trusted" \
    bash "$ROOT/linux/ai/odysseus-manager.sh" install >/dev/null 2>&1
audit_gate_rc=$?
set -e
test "$audit_gate_rc" -eq 69
test ! -e "$HOME/audit-gated-odysseus"

set +e
PZ_HOMELAB_ALLOW_HOST_WORKLOADS=1 PZ_ODYSSEUS_ROOT="$HOME/image-gated-odysseus" \
    PZ_ODYSSEUS_TRUSTED_COMMITS_FILE="$trusted" PZ_ODYSSEUS_RELEASE_AUDIT_FILE="$approved_audit" \
    PZ_ODYSSEUS_TRUSTED_IMAGES_FILE="$bad_images" \
    bash "$ROOT/linux/ai/odysseus-manager.sh" install >/dev/null 2>&1
image_gate_rc=$?
set -e
test "$image_gate_rc" -eq 69
test ! -e "$HOME/image-gated-odysseus"

# Invalid build-base evidence also blocks before the first directory write.
bad_base="$TMP_ROOT/bad-build-base.json"
printf '%s\n' '{"schemaVersion":1,"trustMode":"registry-manifest-digest","semanticAudit":false,"images":[]}' > "$bad_base"
set +e
PZ_HOMELAB_ALLOW_HOST_WORKLOADS=1 PZ_ODYSSEUS_ROOT="$HOME/base-gated-odysseus" \
    PZ_ODYSSEUS_TRUSTED_COMMITS_FILE="$trusted" PZ_ODYSSEUS_RELEASE_AUDIT_FILE="$approved_audit" \
    PZ_ODYSSEUS_TRUSTED_BUILD_BASES_FILE="$bad_base" \
    bash "$ROOT/linux/ai/odysseus-manager.sh" install >/dev/null 2>&1
base_gate_rc=$?
set -e
test "$base_gate_rc" -eq 69
test ! -e "$HOME/base-gated-odysseus"

# Stable runtime path contains no moving dependency tags or registry pulls.
if grep -Eq 'chromadb/chroma:latest|binwiederhier/ntfy:latest|podman pull' "$ROOT/linux/ai/odysseus-manager.sh"; then
    echo "FAIL: Odysseus still resolves mutable dependency images at deploy time" >&2
    exit 1
fi
jq -e '.trustMode == "registry-manifest-digest" and .semanticAudit == false and
  (.images | length == 3) and all(.images[]; .versionTag != "latest" and
    (.reference | test("@sha256:[0-9a-f]{64}$")))' \
  "$ROOT/assets/ai/odysseus-dependency-images.json" >/dev/null

if grep -Fq "printf 'OPENAI_API_KEY=%s" "$ROOT/linux/ai/odysseus-manager.sh"; then
    echo "FAIL: Odysseus duplicates the canonical 9Router credential" >&2
    exit 1
fi
# shellcheck disable=SC2016 # assertions intentionally match literal shell variables
grep -Fq -- '--env-file "$ROUTER_ENV" --env-file "$ENV_FILE"' "$ROOT/linux/ai/odysseus-manager.sh"
# shellcheck disable=SC2016 # assertion intentionally matches literal Compose interpolation
grep -Fq 'OPENAI_API_KEY: \${PHASEZERO_9ROUTER_API_KEY:' "$ROOT/linux/ai/odysseus-manager.sh"

echo "=== hermes stays optional in broad profiles (PZ-AUD-021) ==="
# The gate block (rc 69) becomes an explained skip, never a profile abort.
# Chamar como o produto chama: pz_run_profile executa scripts de perfil com
# `bash "$script"`, e o bit de execução não faz parte do contrato — este
# arquivo está commitado como 100644, como outros do repositório.
skip_out="$(env -u PZ_HOMELAB_ALLOW_HOST_WORKLOADS bash "$ROOT/linux/ai/setup-hermes-optional.sh" setup 2>&1 || true)"
echo "$skip_out" | rg -qi "SKIP|experimental|blocked" || {
    # Sem a saída real, a falha só diz que algo não bateu: mostre o que o
    # script respondeu, que é a única evidência que decide o caso.
    echo "FAIL: hermes gate block not explained; saída real:"
    printf '%s\n' "$skip_out" | head -10
    exit 1
}
# ...but a real failure still propagates.
if bash "$ROOT/linux/ai/setup-hermes-optional.sh" bogus-action >/dev/null 2>&1; then
    echo "FAIL: hermes misuse accepted"; exit 1
fi
rg -q 'setup-hermes-optional\.sh' "$ROOT/profiles/dev-ai.json" \
    || { echo "FAIL: dev-ai still calls raw setup-hermes"; exit 1; }
if rg -q '"linux/ai/setup-hermes\.sh"' "$ROOT/profiles/dev-ai.json"; then
    echo "FAIL: dev-ai references blocking hermes setup"; exit 1
fi
echo "  hermes optional ok"

echo "=== llm model proven by inference, never backgrounded (PZ-AUD-024) ==="
LLMBIN="$TMP_ROOT/llmbin"
mkdir -p "$LLMBIN"
cat > "$LLMBIN/ollama" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-}" = "list" ]; then
    printf 'NAME\nqwen2.5-coder:1.5b\n'
    exit 0
fi
exit 0
EOS
cat > "$LLMBIN/curl" <<'EOS'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        */api/generate) printf '{"model":"qwen2.5-coder:1.5b","response":"ok","done":true}'; exit 0 ;;
    esac
done
exit 1
EOS
chmod +x "$LLMBIN/ollama" "$LLMBIN/curl"
export PZ_LLM_SERVER_STATE="$TMP_ROOT/llm-server.json"
if ! PATH="$LLMBIN:$PATH" PZ_DRY_RUN=0 "$ROOT/linux/server/llm-server.sh" install >/dev/null 2>&1; then
    echo "FAIL: llm install with answering model failed"; exit 1
fi
jq -e '.defaultModel == "qwen2.5-coder:1.5b" and .inference.probed == true and .inference.httpCode == "200"' \
    "$PZ_LLM_SERVER_STATE" >/dev/null
rg -q 'nohup ollama pull' "$ROOT/linux/server/llm-server.sh" && { echo "FAIL: background pull still present"; exit 1; }
# A present model that cannot answer is not ready.
cat > "$LLMBIN/curl" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
chmod +x "$LLMBIN/curl"
if PATH="$LLMBIN:$PATH" PZ_DRY_RUN=0 "$ROOT/linux/server/llm-server.sh" install >/dev/null 2>&1; then
    echo "FAIL: silent model reported ready"; exit 1
fi
echo "  llm inference proof ok"

echo "linux-agent-workspaces smoke ok"
