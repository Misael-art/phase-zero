#!/usr/bin/env bash
# Broad profiles may continue past the OpenClaw account-grant gate.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

rc=0
bash "$PZ_ROOT/linux/ai/setup-openclaw.sh" "$@" || rc=$?
if [ "$rc" -eq 69 ]; then
    echo "SKIP: OpenClaw use blocked until PhaseZero can enforce a grant on every request." >&2
    echo "SKIP: continue profile without OpenClaw; status and doctor remain read-only." >&2
    exit 0
fi
exit "$rc"
