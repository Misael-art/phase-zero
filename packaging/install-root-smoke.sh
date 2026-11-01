#!/usr/bin/env bash
# install-root-smoke.sh - stage the runtime into a fake install root and prove
# the deployed tree behaves like a package without touching the real host.
#
# Mirrors the layout the release packages install (/usr/lib/phasezero) and
# checks, from that root:
#   - version probe
#   - homelab profiles --json contract
#   - homelab status --json fail-closed (no docker daemon)
#   - UI module imports (offscreen)
#   - deployed tree matches the source tree (checksum)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DEST="$TMP/usr/lib/phasezero"
mkdir -p "$DEST"

echo "staging runtime into $DEST"
cp -r "$ROOT/linux" "$DEST/linux"
cp -r "$ROOT/assets" "$DEST/assets"
mkdir -p "$DEST/packaging"
cp -r "$ROOT/packaging/deepseek-harness" "$DEST/packaging/"
cp "$ROOT/version.json" "$DEST/version.json"

export PZ_STATE_ROOT="$TMP/state"
export PZ_HOMELAB_STATE="$TMP/state/homelab"
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$HOME" "$PZ_STATE_ROOT"

PZ="$DEST/linux/pz"

echo "== version probe =="
"$PZ" --version | rg -q 'PhaseZero Linux v[0-9]+\.[0-9]+\.[0-9]+'

echo "== installed Harness metadata and read-only report =="
export PZ_DSH_ROOT="$TMP/absent-harness"
"$PZ" ai deepseek-harness status --json | jq -e \
  '.appId == "app.deepseek-harness" and .state == "not-installed" and .quota == "unknown"' >/dev/null
test ! -e "$PZ_DSH_ROOT"
for metadata in pins.json package.json package-lock.json sbom.cdx.json; do
    cmp "$ROOT/packaging/deepseek-harness/$metadata" "$DEST/packaging/deepseek-harness/$metadata"
done

echo "== profiles --json contract =="
"$PZ" server homelab profiles --json | jq -e \
  '.schemaVersion == 1 and (.profiles|length) == 6 and .default == "edge"' >/dev/null

echo "== status --json fail-closed without daemon =="
out="$("$PZ" server homelab status --json 2>/dev/null || true)"
printf '%s\n' "$out" | jq -e '.schemaVersion == "1" and .ready == false and (.reasons | type == "array")' >/dev/null

echo "== homelab verify --json contract =="
"$PZ" server homelab verify --json | jq -e '.action == "verify" and (.checks | type == "array")' >/dev/null

echo "== UI imports from staged root (offscreen) =="
if command -v python3 >/dev/null 2>&1 && python3 -c 'import PySide6' 2>/dev/null; then
    QT_QPA_PLATFORM=offscreen PYTHONPATH="$DEST" python3 - <<'PY'
from linux.ui_native.pages.homelab import HomelabPage
from linux.ui_native.pages.registry import PageRegistry
print("ui imports ok")
PY
else
    echo "PySide6 not available; skipping UI import check"
fi

echo "== deployed tree matches source (checksum) =="
( cd "$ROOT" && find linux assets -type f -print0 | sort -z | xargs -0 sha256sum > "$TMP/source.sha256" )
( cd "$DEST" && find linux assets -type f -print0 | sort -z | xargs -0 sha256sum > "$TMP/dest.sha256" )
diff -u <(sed 's#  /#  /#' "$TMP/source.sha256") \
        <(sed "s#$DEST/##" "$TMP/dest.sha256") >/dev/null

test ! -e /root/.local/state/phasezero
test ! -e "$DEST/linux/.git"

echo "install-root smoke ok"
