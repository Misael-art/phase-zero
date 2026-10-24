#!/usr/bin/env bash
# Contributor environment only. No PhaseZero services, packages or boot settings.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-doctor}"
if (($#)); then shift; fi
PROFILE=core
YES=0
while (($#)); do
    case "$1" in
        --profile) [[ $# -ge 2 ]] || { echo 'missing --profile value' >&2; exit 64; }; PROFILE="$2"; shift 2 ;;
        --yes) YES=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
    esac
done
case "$ACTION" in plan|install|doctor) ;; *) echo "unknown action: $ACTION" >&2; exit 64 ;; esac
case "$PROFILE" in core|ui) ;; *) echo "unknown profile: $PROFILE" >&2; exit 64 ;; esac

if [[ ! -r /etc/os-release ]]; then echo 'Linux OS metadata unavailable' >&2; exit 69; fi
# shellcheck disable=SC1091
source /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
    *arch*|*manjaro*|*biglinux*) ;;
    *) echo "Unsupported Linux distribution: ${ID:-unknown}. Supported: Arch family." >&2; exit 69 ;;
esac
command -v pacman >/dev/null || { echo 'pacman missing' >&2; exit 69; }

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
DEV_HOME="${PZ_DEV_HOME:-$DATA_HOME/phasezero-dev}"
VENV="$DEV_HOME/venv-$PROFILE"
REQUIREMENTS="$ROOT/requirements/dev-$PROFILE.txt"
PACKAGES=(git python python-pip jq ripgrep shellcheck)
if [[ "$PROFILE" == ui ]]; then
    PACKAGES+=(libglvnd libxkbcommon libxcb xorg-server-xvfb qemu-img)
fi

print_plan() {
    printf 'PhaseZero dev: action=%s profile=%s\n' "$ACTION" "$PROFILE"
    printf 'pacman packages: %s\n' "${PACKAGES[*]}"
    printf 'Python requirements: %s\n' "$REQUIREMENTS"
    printf 'venv: %s\n' "$VENV"
    echo 'Host scope: pacman packages only. No product install, service, VM, login or boot change.'
}
print_plan
[[ "$ACTION" == plan ]] && exit 0

missing=()
for binary in git python3 jq rg shellcheck; do
    command -v "$binary" >/dev/null || missing+=("$binary")
done
if [[ "$PROFILE" == ui ]]; then
    for binary in Xvfb qemu-img; do
        command -v "$binary" >/dev/null || missing+=("$binary")
    done
fi
if [[ "$ACTION" == doctor ]]; then
    if ((${#missing[@]})); then printf 'Missing commands: %s\n' "${missing[*]}" >&2; fi
    if [[ ! -x "$VENV/bin/python" ]] || ! "$VENV/bin/python" -m pip check >/dev/null 2>&1 || \
        ! "$VENV/bin/python" -c 'import pytest, pytest_timeout, PIL, argon2' >/dev/null 2>&1; then
        echo "Python environment missing or incomplete: $VENV" >&2
        exit 2
    fi
    if [[ "$PROFILE" == ui ]] && ! "$VENV/bin/python" -c 'import importlib.metadata as m; assert m.version("PySide6") == "6.11.1"' >/dev/null 2>&1; then
        echo "PySide6 missing: $VENV" >&2
        exit 2
    fi
    ((${#missing[@]} == 0)) || exit 2
    echo 'ready: true'
    exit 0
fi

[[ "$YES" == 1 ]] || { echo 'Install requires --yes after reviewing plan.' >&2; exit 64; }
[[ "$EUID" != 0 ]] || { echo 'Run as regular user; elevation applies only to pacman.' >&2; exit 77; }
if [[ "$DEV_HOME" == /run/user/* || "$DEV_HOME" == /tmp/* ]]; then
    echo 'Choose persistent PZ_DEV_HOME outside runtime/tmp.' >&2; exit 64
fi
if [[ "$PROFILE" == ui ]]; then minimum_kib=$((3 * 1024 * 1024)); else minimum_kib=$((1 * 1024 * 1024)); fi
available_kib="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
if [[ -z "$available_kib" || "$available_kib" -lt 786432 ]]; then
    echo 'Insufficient available memory (<768 MiB); installation deferred.' >&2; exit 75
fi
mkdir -p -- "$DEV_HOME"
free_kib="$(df -Pk -- "$DEV_HOME" | awk 'NR==2 {print $4}')"
if [[ -z "$free_kib" || "$free_kib" -lt "$minimum_kib" ]]; then
    echo "Insufficient free disk for $PROFILE profile; need $minimum_kib KiB." >&2; exit 75
fi
if ((${#missing[@]})); then
    # Avoid an Arch partial upgrade: use the existing sync database, never -Sy.
    # If upgrades are pending, let the operator complete a normal -Syu first.
    updates="$(pacman -Qu)" || { echo 'Cannot inspect pending system upgrades.' >&2; exit 75; }
    if [[ -n "$updates" ]]; then
        echo 'Pending system upgrades. Run normal pacman -Syu first, then retry.' >&2
        exit 75
    fi
    if command -v phasezero-admin >/dev/null; then
        phasezero-admin pacman -S --needed --noconfirm -- "${PACKAGES[@]}"
    elif command -v bigsudo >/dev/null; then
        bigsudo pacman -S --needed --noconfirm -- "${PACKAGES[@]}"
    elif command -v pkexec >/dev/null; then
        pkexec pacman -S --needed --noconfirm -- "${PACKAGES[@]}"
    else
        echo 'Admin bridge unavailable. Run linux/pz ai setup admin or install polkit/pkexec.' >&2
        exit 77
    fi
fi
for binary in git python3 jq rg shellcheck; do command -v "$binary" >/dev/null || { echo "Missing after install: $binary" >&2; exit 70; }; done
if [[ "$PROFILE" == ui ]]; then
    for binary in Xvfb qemu-img; do command -v "$binary" >/dev/null || { echo "Missing after install: $binary" >&2; exit 70; }; done
fi

old="$DEV_HOME/.venv-$PROFILE.previous"
if [[ -e "$old" || -L "$old" ]]; then
    echo "Previous rollback path already exists: $old. Remove it manually after review." >&2
    exit 73
fi
stage="$(mktemp -d -- "$DEV_HOME/.venv-$PROFILE.XXXXXXXX")"
cleanup() { if [[ -d "$stage" ]]; then rm -rf -- "$stage"; fi; }
trap cleanup EXIT
python3 -m venv "$stage"
"$stage/bin/python" -m pip install --disable-pip-version-check -r "$REQUIREMENTS"
"$stage/bin/python" -m pip check
"$stage/bin/python" -c 'import pytest, pytest_timeout, PIL, argon2'
if [[ "$PROFILE" == ui ]]; then "$stage/bin/python" -c 'import importlib.metadata as m; assert m.version("PySide6") == "6.11.1"'; fi
if [[ -e "$VENV" || -L "$VENV" ]]; then mv -- "$VENV" "$old"; fi
# Python virtualenv scripts contain absolute interpreter paths. Keep stage at
# its original path; switch only the stable symlink.
if ! ln -s -- "$stage" "$VENV"; then
    if [[ ! -e "$VENV" && ( -e "$old" || -L "$old" ) ]]; then mv -- "$old" "$VENV"; fi
    exit 74
fi
trap - EXIT
echo "ready: true; Python: $VENV/bin/python"
if [[ -e "$old" ]]; then echo "Previous venv retained for rollback: $old"; fi
