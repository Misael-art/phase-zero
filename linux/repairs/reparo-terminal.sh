#!/usr/bin/env bash
# Confirmation handled by the shared repair manager.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/terminal.py" repair --yes "$@"
