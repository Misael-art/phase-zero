#!/usr/bin/env bash
# setup-open-webui.sh - fail closed until Open WebUI can enforce request grants
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

pz_error "Open WebUI setup blocked: provider connections can hold shared credentials, but requests are not bound to PhaseZero grants"
exit 69
