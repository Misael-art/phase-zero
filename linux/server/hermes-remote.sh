#!/usr/bin/env bash
# hermes-remote.sh - Hermes agent for remote actuation on the home server.
#
# Thin wrapper over linux/ai/setup-hermes.sh: installs+configures Hermes and
# surfaces the remote portal. Remote reachability itself is provided by Tailscale
# (see homelab-stack.sh); Hermes is the actuation layer on top.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

HERMES="$PZ_ROOT/linux/ai/setup-hermes.sh"

case "${1:-status}" in
    setup|install)
        bash "$HERMES" setup
        pz_info "Hermes ready. Remote actuation over Tailscale; open the portal with: pz server hermes start"
        ;;
    start|portal) bash "$HERMES" portal ;;
    status) bash "$HERMES" status ;;
    dry-run|plan) bash "$HERMES" dry-run ;;
    *) pz_error "usage: hermes-remote.sh (setup|start|status|dry-run)"; exit 2 ;;
esac
