#!/usr/bin/env bash
# AISR-003: setup-codex must not downgrade or relink an existing, supported
# Codex CLI (the standalone installer keeps it current on its own).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export PZ_LOCAL_BIN="$WORK/home/.local/bin"
export PZ_NPM_PREFIX="$WORK/npm"
mkdir -p "$WORK/stub" "$WORK/standalone" "$PZ_LOCAL_BIN"

# npm stub records any install attempt.
printf '#!/bin/sh\necho "$*" >> "%s/npm.log"\n' "$WORK" > "$WORK/stub/npm"
printf '#!/bin/sh\necho "codex-cli %s"\n' 0.156.1 > "$WORK/standalone/codex"
chmod +x "$WORK/stub/npm" "$WORK/standalone/codex"
ln -s "$WORK/standalone/codex" "$PZ_LOCAL_BIN/codex"
export PATH="$PZ_LOCAL_BIN:$WORK/stub:$PATH"

# 1. Newer existing install: no npm call, symlink untouched.
"$ROOT/linux/ai/setup-codex.sh" setup >/dev/null 2>&1
[ ! -e "$WORK/npm.log" ] || { echo "FAIL: npm install ran over a supported codex" >&2; exit 1; }
[ "$(readlink "$PZ_LOCAL_BIN/codex")" = "$WORK/standalone/codex" ]

"$ROOT/linux/ai/setup-codex.sh" status | jq -e '.version == "0.156.1" and .supported and .coherent == null and .next == "linux/pz ai codex status"' >/dev/null
"$ROOT/linux/ai/setup-codex.sh" dry-run | jq -e '.dryRun and .planned == ["keep existing codex"]' >/dev/null

# 2. Below the minimum: installs latest, never a fixed old version.
printf '#!/bin/sh\necho "codex-cli 0.10.0"\n' > "$WORK/standalone/codex"
"$ROOT/linux/ai/setup-codex.sh" setup >/dev/null 2>&1
grep -q '@openai/codex@latest' "$WORK/npm.log"

# 3. Explicit force still reinstalls.
: > "$WORK/npm.log"
printf '#!/bin/sh\necho "codex-cli 0.156.1"\n' > "$WORK/standalone/codex"
PZ_CODEX_FORCE=1 "$ROOT/linux/ai/setup-codex.sh" setup >/dev/null 2>&1
grep -q '@openai/codex@latest' "$WORK/npm.log"

# 4. A newer CLI with an older managed daemon must be visible. The official
# update command updates both packages; PhaseZero checks the resulting state.
cat > "$WORK/standalone/codex" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    --version) echo 'codex-cli 0.166.0' ;;
    'app-server daemon version')
        version="$(cat "$CODEX_TEST_DAEMON_VERSION")"
        printf '{"status":"running","managedCodexVersion":"%s","appServerVersion":"%s","cliVersion":"0.166.0"}\n' "$version" "$version" ;;
    update) echo 'updated CLI' >> "$CODEX_TEST_LOG" ;;
    'app-server daemon update')
        echo 'updated daemon' >> "$CODEX_TEST_LOG"
        echo '0.166.0' > "$CODEX_TEST_DAEMON_VERSION"
        echo '{"status":"updated"}' ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$WORK/standalone/codex"
export CODEX_TEST_DAEMON_VERSION="$WORK/daemon-version"
export CODEX_TEST_LOG="$WORK/codex.log"
echo '0.162.1' > "$CODEX_TEST_DAEMON_VERSION"
"$ROOT/linux/ai/setup-codex.sh" status | jq -e '
  .version == "0.166.0" and .daemon.appServerVersion == "0.162.1" and
  .coherent == false and .requiresAttention and .next == "linux/pz updates apply codex" and
  .planned == ["codex update", "codex app-server daemon update"]
' >/dev/null
"$ROOT/linux/ai/setup-codex.sh" update | jq -e '.coherent == true and .requiresAttention == false' >/dev/null
[ "$(cat "$CODEX_TEST_LOG")" = "$(printf 'updated CLI\nupdated daemon')" ]

echo "PASS: codex setup keeps supported installs"
