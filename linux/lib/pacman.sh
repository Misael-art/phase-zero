#!/usr/bin/env bash
# pacman.sh - PhaseZero Linux unified package manager wrapper
set -euo pipefail

pz_pkg_install() {
    local pkg="$1" manager="${2:-auto}"
    [ -n "$pkg" ] || { pz_error "package name required"; return 2; }
    [[ "$pkg" =~ ^[A-Za-z0-9@._+:-]+$ ]] || {
        pz_error "invalid package name: $pkg"
        return 2
    }
    local equivalent=""
    case "$manager" in
        flatpak) equivalent="$(pz_equivalent_present flatpak "$pkg" 2>/dev/null)" || equivalent="" ;;
        *) equivalent="$(pz_equivalent_present pacman "$pkg" 2>/dev/null)" || equivalent="" ;;
    esac
    if [ -n "$equivalent" ]; then
        pz_info "skip $pkg: já presente via ${equivalent//$'\t'/ }"
        return 0
    fi
    case "$manager" in
        pacman)
            command -v pacman >/dev/null 2>&1 || { pz_error "pacman missing"; return 69; }
            pz_admin_run pacman -S --needed --noconfirm "$pkg"
            ;;
        yay)
            command -v yay >/dev/null 2>&1 || { pz_error "yay missing"; return 69; }
            yay -S --needed --noconfirm "$pkg"
            ;;
        paru)
            command -v paru >/dev/null 2>&1 || { pz_error "paru missing"; return 69; }
            paru -S --needed --noconfirm "$pkg"
            ;;
        flatpak)
            command -v flatpak >/dev/null 2>&1 || { pz_error "flatpak missing"; return 69; }
            flatpak --user install -y flathub "$pkg"
            ;;
        auto)
            if command -v pacman >/dev/null 2>&1 && pacman -Si "$pkg" &>/dev/null; then
                pz_admin_run pacman -S --needed --noconfirm "$pkg"
            elif command -v yay >/dev/null 2>&1 && yay -Si "$pkg" &>/dev/null; then
                yay -S --needed --noconfirm "$pkg"
            elif command -v paru >/dev/null 2>&1 && paru -Si "$pkg" &>/dev/null; then
                paru -S --needed --noconfirm "$pkg"
            elif command -v flatpak >/dev/null 2>&1; then
                flatpak --user install -y flathub "$pkg" 2>/dev/null || {
                    pz_error "could not install $pkg via any manager"
                    return 1
                }
            else
                pz_error "no supported package manager available for $pkg"
                return 69
            fi
            ;;
        *)
            pz_error "unknown package manager: $manager"
            return 2
            ;;
    esac
}

pz_pkg_list_installed() {
    pacman -Qq 2>/dev/null
}

pz_pkg_is_installed() {
    pacman -Qi "$1" &>/dev/null
}

pz_pkg_search() {
    local query="$1"
    echo "=== pacman ==="
    pacman -Ss "$query" 2>/dev/null | head -20
    if command -v yay &>/dev/null; then
        echo "=== AUR (yay) ==="
        yay -Ss "$query" 2>/dev/null | head -20
    fi
}

pz_pkg_update() {
    pz_admin_run pacman -Syu --noconfirm
    if command -v yay &>/dev/null; then
        yay -Sua --noconfirm
    fi
    if command -v flatpak &>/dev/null; then
        flatpak --user update -y
    fi
}

pz_pkg_cleanup() {
    local orphans=()
    pz_admin_run pacman -Sc --noconfirm
    mapfile -t orphans < <(pacman -Qdtq 2>/dev/null || true)
    if [ "${#orphans[@]}" -gt 0 ]; then
        pz_admin_run pacman -Rns --noconfirm "${orphans[@]}"
    else
        pz_info "no orphan packages to remove"
    fi
}
