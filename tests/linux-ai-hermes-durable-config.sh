#!/usr/bin/env bash
# AISR-011/013: Hermes config writers must (a) restore an empty config.yaml from
# .pz-bak instead of rebuilding it from {}, (b) never overwrite a good .pz-bak
# with an empty file, (c) fsync before the atomic replace. Runs the real Python
# writer blocks from each script against fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Print the heredoc body that contains the durable writer.
writer_block() {
    awk '
        /<<'"'"'PY'"'"'/ { on = 1; buf = ""; next }
        on && /^PY$/ { if (buf ~ /pz_durable_write\(path, yaml/) { printf "%s", buf; exit } on = 0; next }
        on { buf = buf $0 "\n" }
    ' "$1"
}

run_writer() {
    local script="$1" config="$2"
    case "$script" in
        hermes-router.sh) python3 "$WORK/writer.py" "$config" "http://127.0.0.1:20128/v1" "phasezero-live" ;;
        9router-hermes-provider.sh) python3 "$WORK/writer.py" "$config" "http://127.0.0.1:20128/v1" "9router" "9Router" "phasezero-live" ;;
        setup-hermes.sh) python3 "$WORK/writer.py" "$config" "http://127.0.0.1:20128/v1" "phasezero-live" ;;
    esac
}

for script in hermes-router.sh 9router-hermes-provider.sh setup-hermes.sh; do
    writer_block "$ROOT/linux/ai/$script" > "$WORK/writer.py"
    [ -s "$WORK/writer.py" ] || { echo "FAIL: no durable writer block in $script" >&2; exit 1; }
    grep -q 'os.fsync(handle.fileno())' "$WORK/writer.py"
    grep -q '_pz_fsync_dir(path.parent)' "$WORK/writer.py"

    home="$WORK/$script"
    mkdir -p "$home"
    config="$home/config.yaml"

    # (a)+(b): empty config, good backup.
    : > "$config"
    printf 'model:\n  default: user-combo\nmcp_servers:\n  memory:\n    command: ai-memory\nuser_setting: keep-me\n' > "$config.pz-bak"
    run_writer "$script" "$config" 2> "$home/err"
    grep -q 'restaurado de config.yaml.pz-bak' "$home/err" || { echo "FAIL: $script did not report restore" >&2; cat "$home/err" >&2; exit 1; }
    python3 - "$config" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
assert data.get("user_setting") == "keep-me", data
assert "memory" in data.get("mcp_servers", {}), data
PY
    [ -s "$config.pz-bak" ] || { echo "FAIL: $script left an empty .pz-bak" >&2; exit 1; }
    grep -q 'user_setting: keep-me' "$config.pz-bak"
    [ "$(stat -c %a "$config")" = 600 ]

    # (b) again: an empty config never replaces a good backup, even with no restore.
    : > "$config"
    printf 'user_setting: keep-me\n' > "$config.pz-bak"
    run_writer "$script" "$config" 2>/dev/null
    grep -q 'user_setting: keep-me' "$config.pz-bak"

    # Normal path: non-empty config is backed up before the rewrite.
    printf 'other: 1\n' > "$config"
    run_writer "$script" "$config" 2>/dev/null
    grep -q '^other: 1' "$config.pz-bak"
    grep -q '^other: 1' "$config"
    [ ! -e "$home/.config.yaml.pz-tmp" ]
done

# The three copies of the helper block stay identical.
block() { sed -n '/^# --- PhaseZero durable config IO/,/^# --- end PhaseZero durable config IO ---/p' "$ROOT/linux/ai/$1" | tail -n +3; }
for script in 9router-hermes-provider.sh setup-hermes.sh; do
    diff <(block hermes-router.sh) <(block "$script") >/dev/null || { echo "FAIL: durable IO block diverged in $script" >&2; exit 1; }
done

# The routing default survives the restore.
# shellcheck disable=SC2016 # Match literal shell source.
grep -q 'default_source="$HERMES_CONFIG.pz-bak"' "$ROOT/linux/ai/hermes-router.sh"

echo "PASS: Hermes config writers are durable and restore empty configs"
