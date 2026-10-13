#!/usr/bin/env bash
# Guards the opencode CLI/desktop lockstep against the failure mode where npm
# reports success but leaves a binary that cannot run: npm >= 12 blocks lifecycle
# scripts by default, and opencode-ai fetches its real binary in postinstall.
# Publishing that stub into ~/.local/bin shadows the working system CLI on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export PZ_NPM_PREFIX="$HOME/.local/share/npm"
export PZ_LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$PZ_LOCAL_BIN" "$TMP_ROOT/stub" "$XDG_DATA_HOME/opencode"

npm_log="$TMP_ROOT/npm-args.log"
export NPM_LOG="$npm_log"
# Versions ending in .99 simulate a package whose postinstall never ran: npm
# still exits 0, but the installed binary refuses to execute.
cat > "$TMP_ROOT/stub/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "install" ] && [ "${2:-}" = "--help" ]; then
    printf -- '--allow-scripts <package-list>\n'
    exit 0
fi
printf '%s\n' "$*" >> "$NPM_LOG"
prefix=""
spec=""
for arg in "$@"; do
    case "$arg" in
        --prefix) prefix="NEXT" ;;
        opencode-ai@*) spec="${arg#opencode-ai@}" ;;
        *) [ "$prefix" = "NEXT" ] && { prefix="$arg"; }; ;;
    esac
done
[ -n "$prefix" ] || exit 1
mkdir -p "$prefix/bin" "$prefix/lib/node_modules/opencode-ai"
printf '{"version":"%s"}\n' "$spec" > "$prefix/lib/node_modules/opencode-ai/package.json"
if [[ "$spec" == *.99 ]]; then
    printf '#!/usr/bin/env bash\necho "Error: opencode-ai postinstall script was not run." >&2\nexit 1\n' \
        > "$prefix/bin/opencode"
else
    printf '#!/usr/bin/env bash\n[ "${1:-}" = "--version" ] && { echo "%s"; exit 0; }\nexit 0\n' "$spec" \
        > "$prefix/bin/opencode"
fi
chmod +x "$prefix/bin/opencode"
exit 0
EOF

cat > "$TMP_ROOT/stub/pacman" <<'EOF'
#!/usr/bin/env bash
echo "opencode-desktop-bin ${PZ_TEST_DESKTOP_VERSION:-1.0.0}-1"
EOF
chmod +x "$TMP_ROOT/stub"/*
export PATH="$TMP_ROOT/stub:$PZ_LOCAL_BIN:$PATH"

bash -n "$ROOT/linux/ai/setup-opencode.sh"

# 1. A healthy pin links the managed binary and passes the scoped allow-scripts
#    flag, without ever unblocking the whole dependency tree.
PZ_TEST_DESKTOP_VERSION=1.0.0 bash "$ROOT/linux/ai/setup-opencode.sh" sync >/dev/null
test "$("$PZ_LOCAL_BIN/opencode" --version)" = "1.0.0"
grep -Fq -- '--allow-scripts=opencode-ai' "$npm_log"
if grep -Fq -- '--dangerously-allow-all-scripts' "$npm_log"; then
    echo "opencode install must not unblock scripts for the whole tree" >&2
    exit 1
fi

# 2. An upgrade whose postinstall was blocked must fail loudly and roll back,
#    leaving a CLI that still runs rather than a stub on PATH.
set +e
PZ_TEST_DESKTOP_VERSION=2.0.99 bash "$ROOT/linux/ai/setup-opencode.sh" sync >/dev/null 2>&1
sync_rc=$?
set -e
test "$sync_rc" != 0
test "$("$PZ_LOCAL_BIN/opencode" --version)" = "1.0.0"

# 3. With no previous version to fall back to, the broken binary must not be
#    published into $LOCAL_BIN at all.
rm -rf "$PZ_NPM_PREFIX" "$PZ_LOCAL_BIN/opencode"
set +e
PZ_TEST_DESKTOP_VERSION=3.0.99 bash "$ROOT/linux/ai/setup-opencode.sh" sync >/dev/null 2>&1
sync_rc=$?
set -e
test "$sync_rc" != 0
if [ -e "$PZ_LOCAL_BIN/opencode" ]; then
    echo "broken opencode CLI was linked into $PZ_LOCAL_BIN" >&2
    exit 1
fi

echo "opencode lockstep rollback and scoped allow-scripts ok"
