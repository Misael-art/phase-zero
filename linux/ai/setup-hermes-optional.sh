#!/usr/bin/env bash
# setup-hermes-optional.sh - best-effort Hermes step for broad profiles.
#
# Hermes is unavailable to managed profiles until per-request account grants
# are enforceable. Gate blocks become an explained skip; real errors propagate.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

rc=0
bash "$PZ_ROOT/linux/ai/setup-hermes.sh" "$@" || rc=$?
if [ "$rc" -eq 69 ]; then
    echo "SKIP: Hermes use is blocked until PhaseZero can enforce a grant on each request." >&2
    echo "SKIP: continue without Hermes; status and doctor remain read-only." >&2
    exit 0
fi
exit "$rc"
