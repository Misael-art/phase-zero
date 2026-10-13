#!/usr/bin/env bash
# dev-tweaks.sh - development environment optimizations (apply | revert | status)
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
source "$PZ_ROOT/linux/tuning/tune-common.sh"

pz_tune_init dev "$@"

PZ_DEV_SYSCTL="${PZ_DEV_SYSCTL:-/etc/sysctl.d/99-phasezero-dev.conf}"

pz_apply_sysctl() {
    pz_tune_file "$PZ_DEV_SYSCTL" root <<'EOF'
# PhaseZero Dev Tweaks
# Increase file watcher limit (Node.js, VS Code, watchers)
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024
fs.inotify.max_queued_events = 32768

# Network tuning for dev tools
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Memory management
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 50

# Kernel same-page merging (KSM) for VMs
kernel.nmi_watchdog = 0
EOF
    pz_reload_sysctl
    pz_info "sysctl dev tweaks applied: $PZ_DEV_SYSCTL"
}

pz_reload_sysctl() {
    [ -f "$PZ_DEV_SYSCTL" ] || [ "$PZ_TUNE_ACTION" = "revert" ] || return 0
    if pz_tune_dry_run; then
        pz_info "dry-run: recarregaria sysctl --system"
        return 0
    fi
    pz_admin_run sysctl --system >/dev/null 2>&1 || pz_warn "sysctl --system não recarregado (sem privilégio)"
}

pz_configure_git() {
    pz_tune_setting git core.fsmonitor true
    pz_tune_setting git core.untrackedcache true
    pz_tune_setting git core.autocrlf input
    pz_tune_setting git pull.rebase true
    pz_tune_setting git fetch.prune true
    pz_tune_setting git diff.algorithm histogram
    pz_tune_setting git status.showUntrackedFiles normal
    pz_tune_setting git init.defaultBranch main
    pz_info "git config optimized"
}

pz_configure_npm() {
    pz_tune_setting npm fund false
    pz_tune_setting npm audit false
    pz_tune_setting npm update-notifier false
    pz_tune_setting npm cache "${HOME}/.cache/npm"
    pz_info "npm config optimized"
}

pz_tune_apply() {
    pz_apply_sysctl
    pz_configure_git
    pz_configure_npm
    pz_info "dev tweaks complete"
}

# O arquivo já foi removido pelo revert genérico; falta o kernel voltar aos
# valores da distro, o que só acontece recarregando o conjunto de sysctls.
pz_tune_after_revert() { pz_reload_sysctl; }

pz_tune_main
