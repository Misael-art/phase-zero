#!/usr/bin/env bash
# gaming-tweaks.sh - gaming performance optimizations (apply | revert | status)
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
source "$PZ_ROOT/linux/tuning/tune-common.sh"

pz_tune_init gaming "$@"

pz_configure_gamemode() {
    pz_tune_file /etc/gamemode.ini root <<'EOF'
[general]
reaper_freq=5
defaultgov=performance
igpu_desired_freq=1600
igpu_power_threshold=0.3

[gpu]
apply_gpu_optimisations=accept-responsibility
gpu_device=0
amd_performance_level=high

[cpu]
apply_cpu_optimisations=yes
park_cores=no
pin_cores=yes

[custom]
start=notify-send "GameMode started" "Optimizations applied"
end=notify-send "GameMode ended" "Optimizations reverted"
EOF
    pz_info "gamemode configured: /etc/gamemode.ini"
}

pz_configure_mangohud() {
    local cfg="${HOME}/.config/MangoHud/MangoHud.conf"
    pz_tune_file "$cfg" user <<'EOF'
# PhaseZero MangoHud preset
fps_limit=0
fps_color=00FF00
fps_position=top-left
font_size=24
cpu_stats=true
gpu_stats=true
ram_stats=true
vram_stats=true
temp=true
power=true
frame_timing=1
time=no
version=no
toggle_hud=F2
EOF
    pz_info "mangohud configured: $cfg"
}

pz_configure_ananicy() {
    [ -d /etc/ananicy.d ] || return 0
    pz_tune_file /etc/ananicy.d/99-phasezero.rules root <<'EOF'
# PhaseZero ananicy rules for gaming
{
  "name": "steam",
  "type": "match",
  "command": "steam",
  "nice": -10,
  "class": "latency"
}
{
  "name": "games",
  "type": "regex",
  "command": ".*.exe",
  "nice": -8,
  "class": "latency"
}
{
  "name": "wine",
  "type": "match",
  "command": "wine",
  "nice": -5,
  "class": "latency"
}
{
  "name": "mangohud",
  "type": "match",
  "command": "mangohud",
  "nice": -5,
  "class": "latency"
}
EOF
    pz_tune_service ananicy
    pz_info "ananicy rules added"
}

pz_configure_corectrl() {
    local cfg="${HOME}/.config/corectrl/corectrl.conf"
    pz_tune_file "$cfg" user <<'EOF'
[General]
polkit=false

[Profiles]
apply_on_login=true
apply_on_startup=true
EOF
    pz_info "corectrl configured"
}

pz_tune_apply() {
    pz_configure_gamemode
    pz_configure_mangohud
    pz_configure_ananicy
    pz_configure_corectrl
    pz_info "gaming tweaks complete"
}

pz_tune_main
