#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$WORK/bin" "$WORK/memory" "$XDG_CONFIG_HOME/phasezero/ai-proxies" \
    "$XDG_DATA_HOME/opencode"
printf 'semantic-memory\n' > "$WORK/memory/page.md"
printf 'PROVIDER_KEY=test-secret\n' > "$XDG_CONFIG_HOME/phasezero/ai-proxies/9router.env"
printf '{"test":"secret"}\n' > "$XDG_DATA_HOME/opencode/auth.json"
chmod 600 "$XDG_CONFIG_HOME/phasezero/ai-proxies/9router.env" "$XDG_DATA_HOME/opencode/auth.json"

cat > "$WORK/bin/ai-memory" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
command="${1:-}"; shift || true
case "$command" in
  backup)
    output=""
    while [ "$#" -gt 0 ]; do [ "$1" = --to ] && { output="${2:-}"; break; }; shift; done
    [ -n "$output" ]
    tar -C "$FAKE_MEMORY" -czf "$output" .
    ;;
  restore)
    input=""
    while [ "$#" -gt 0 ]; do [ "$1" = --from ] && { input="${2:-}"; break; }; shift; done
    [ -n "$input" ]
    tar -tzf "$input" >/dev/null
    printf 'restored\n' >> "$FAKE_MEMORY_LOG"
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$WORK/bin/ai-memory"
export PATH="$WORK/bin:$PATH"
export AI_MEMORY_BIN="$WORK/bin/ai-memory"
export FAKE_MEMORY="$WORK/memory"
export FAKE_MEMORY_LOG="$WORK/memory-restore.log"
PASS='correct horse battery staple'
BUNDLE="$WORK/phasezero-ai.tar.gz.gpg"

plan="$("$ROOT"/linux/pz ai backup plan --include-credentials --output "$BUNDLE")"
jq -e '.ok and .encrypted and .credentials.count == 2 and (.exclusions|index("cookies"))' <<< "$plan" >/dev/null
if grep -q 'test-secret' <<< "$plan"; then
    echo 'FAIL: backup plan leaked a secret' >&2
    exit 1
fi

created="$(printf '%s\n' "$PASS" | "$ROOT/linux/pz" ai backup create \
    --include-credentials --output "$BUNDLE" --passphrase-stdin)"
jq -e '.ok and .status == "created" and .encrypted' <<< "$created" >/dev/null
[ -s "$BUNDLE" ] && [ "$(stat -c '%a' "$BUNDLE")" = 600 ]
if strings "$BUNDLE" | grep -q 'test-secret'; then
    echo 'FAIL: encrypted bundle contains visible secret' >&2
    exit 1
fi

set +e
printf 'this password is wrong\n' | "$ROOT/linux/pz" ai backup verify \
    --bundle "$BUNDLE" --passphrase-stdin >/dev/null 2>&1
wrong_rc=$?
set -e
[ "$wrong_rc" -ne 0 ]

verified="$(printf '%s\n' "$PASS" | "$ROOT/linux/pz" ai backup verify \
    --bundle "$BUNDLE" --passphrase-stdin)"
jq -e '.ok and .status == "verified" and .items == 3' <<< "$verified" >/dev/null

printf 'PROVIDER_KEY=changed\n' > "$XDG_CONFIG_HOME/phasezero/ai-proxies/9router.env"
restore_plan="$(printf '%s\n' "$PASS" | "$ROOT/linux/pz" ai backup restore --plan \
    --bundle "$BUNDLE" --passphrase-stdin)"
jq -e '.ok and .verified and (.files|length == 2) and .memory.preBackup' <<< "$restore_plan" >/dev/null
grep -q 'PROVIDER_KEY=changed' "$XDG_CONFIG_HOME/phasezero/ai-proxies/9router.env"

restored="$(printf '%s\n' "$PASS" | "$ROOT/linux/pz" ai backup restore \
    --bundle "$BUNDLE" --passphrase-stdin --confirm RESTORE)"
jq -e '.ok and .status == "restored" and (.rollback|length > 0)' <<< "$restored" >/dev/null
grep -q 'PROVIDER_KEY=test-secret' "$XDG_CONFIG_HOME/phasezero/ai-proxies/9router.env"
[ "$(wc -l < "$FAKE_MEMORY_LOG")" -eq 1 ]

echo 'linux-ai-backup smoke ok'
