#!/usr/bin/env bash
# homelab-boot-prepare.sh - brings up the enabled home-server components when the
# host was booted via the PhaseZero Homelab GRUB entry.
#
# Installed copy: /usr/lib/phasezero/linux/server/homelab-boot-prepare.sh (or the
# checkout path in development), driven by phasezero-homelab-boot-prepare.service.
# Reads /etc/phasezero/server-mode.env.
#
# Identity contract:
#   - Never creates state under /root. All user-scoped work (docker stack, hermes)
#     runs as $PZ_SERVER_USER via runuser with explicit HOME/XDG paths.
#   - Runtime is the installed copy under /usr/lib/phasezero when present; the
#     checkout path is only a development fallback.
#   - Essential bring-up failure (LLM service, homelab stack) fails the unit and
#     is surfaced in the journal and in the persisted degraded state.
set -euo pipefail

[ -n "${PZ_ROOT:-}" ] || { [ -f /etc/phasezero/server-mode.env ] && . /etc/phasezero/server-mode.env; }
PZ_ROOT="${PZ_ROOT:-}"
PZ_SERVER_USER="${PZ_SERVER_USER:-}"
PZ_SERVER_LLM="${PZ_SERVER_LLM:-0}"
PZ_SERVER_HOMELAB="${PZ_SERVER_HOMELAB:-0}"
PZ_SERVER_HERMES="${PZ_SERVER_HERMES:-0}"
PZ_SERVER_EXTRAS="${PZ_SERVER_EXTRAS:-0}"
PZ_HOMELAB_ACCESS_MODE="${PZ_HOMELAB_ACCESS_MODE:-local}"

log() { printf '[homelab-boot-prepare] %s\n' "$*"; }

# Only act on an actual homelab boot (belt-and-suspenders vs. the unit Condition).
# PZ_BOOT_MARKER=1 fakes the kernel command line for hermetic tests.
if [ "${PZ_BOOT_MARKER:-0}" != "1" ] && ! grep -qw 'phasezero.homelab=1' /proc/cmdline 2>/dev/null; then
    log "not a homelab boot (marker absent); nothing to do"
    exit 0
fi

# --- Runtime resolution: installed copy wins, never a bare checkout when the
#     package is present. -----------------------------------------------------
RUNTIME_ROOT=""
if [ -x /usr/lib/phasezero/linux/pz ]; then
    RUNTIME_ROOT="/usr/lib/phasezero"
elif [ -n "$PZ_ROOT" ] && [ -x "$PZ_ROOT/linux/pz" ]; then
    RUNTIME_ROOT="$PZ_ROOT"
else
    log "PhaseZero runtime not found (installed nor checkout); aborting bring-up"
    exit 1
fi
log "runtime: $RUNTIME_ROOT"

# --- Target user resolution --------------------------------------------------
TARGET_USER="$PZ_SERVER_USER"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)"
fi
[ -n "$TARGET_USER" ] || { log "no PZ_SERVER_USER resolved; aborting bring-up"; exit 1; }
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="/home/$TARGET_USER"
log "target user: $TARGET_USER (home $TARGET_HOME)"

# State dir is the target user's, never the root user's. Explicit overrides win.
HOMELAB_STATE="${PZ_HOMELAB_STATE:-${PZ_STATE_ROOT:-$TARGET_HOME/.local/state}/phasezero/homelab}"

as_user() {
    if [ "$(id -un)" = "$TARGET_USER" ]; then
        "$@"
    elif command -v runuser >/dev/null 2>&1; then
        runuser -u "$TARGET_USER" -- env \
            HOME="$TARGET_HOME" \
            XDG_STATE_HOME="${PZ_STATE_ROOT:-$TARGET_HOME/.local/state}" \
            XDG_CONFIG_HOME="${PZ_CONFIG_ROOT:-$TARGET_HOME/.config}" \
            XDG_CACHE_HOME="${PZ_CACHE_ROOT:-$TARGET_HOME/.cache}" \
            "$@"
    else
        log "runuser unavailable; cannot drop privileges to $TARGET_USER"
        return 1
    fi
}

mark_degraded() {
    local reason="$1" now ok=false
    if mkdir -p "$HOMELAB_STATE" 2>/dev/null; then
        now="$(command date -u +%Y-%m-%dT%H:%M:%SZ)"
        if jq -n --arg r "$reason" --arg t "$now" \
            '{reasons:[{reason:$r, at:$t}], updatedAt:$t}' \
            > "$HOMELAB_STATE/degraded.json" 2>/dev/null; then
            chmod 0644 "$HOMELAB_STATE/degraded.json" 2>/dev/null || true
            ok=true
        fi
    fi
    if [ "$ok" != "true" ]; then
        # shellcheck disable=SC2016 # single quotes: expansion happens inside sh -c
        as_user sh -c 'jq -n --arg r "$1" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "{reasons:[{reason:\$r, at:\$t}], updatedAt:\$t}" > "$2/degraded.json"' \
            _ "$reason" "$HOMELAB_STATE" 2>/dev/null || log "could not persist degraded state"
    fi
}

clear_degraded() {
    rm -f "$HOMELAB_STATE/degraded.json" 2>/dev/null || true
}

FAILED=0

if [ "${PZ_SERVER_LLM:-0}" = "1" ]; then
    if systemctl start ollama >/dev/null 2>&1; then
        log "ollama service started"
    else
        log "DEGRADED: ollama service failed to start"
        mark_degraded "ollama service failed to start"
        FAILED=1
    fi
fi

if [ "${PZ_SERVER_HOMELAB:-0}" = "1" ]; then
    if ! systemctl start docker >/dev/null 2>&1; then
        log "DEGRADED: docker service failed to start"
        mark_degraded "docker service failed to start"
        exit 1
    fi
    # PZ-AUD-012: boot converges the curated registry (disabled apps stay
    # down); reconcile falls back to legacy layer up when no registry exists.
    if as_user bash "$RUNTIME_ROOT/linux/server/homelab-stack.sh" reconcile --access "$PZ_HOMELAB_ACCESS_MODE"; then
        log "homelab docker stack reconciled (access=$PZ_HOMELAB_ACCESS_MODE)"
        clear_degraded
    else
        log "DEGRADED: homelab stack bring-up failed"
        mark_degraded "homelab stack bring-up failed"
        exit 1
    fi
fi

if [ "${PZ_SERVER_HERMES:-0}" = "1" ]; then
    # PZ-AUD-025: timeout wraps the inner executable, not the as_user shell
    # function (timeout cannot exec a function; the old form failed before
    # hermes-remote ever ran).
    if as_user timeout 120 bash "$RUNTIME_ROOT/linux/server/hermes-remote.sh" start; then
        log "hermes remote agent started for $TARGET_USER"
    else
        log "DEGRADED: hermes start skipped or failed for $TARGET_USER"
        mark_degraded "hermes agent failed to start"
        FAILED=1
    fi
fi

if [ "$FAILED" -ne 0 ]; then
    log "homelab boot bring-up complete with degraded components"
    exit 0
fi
log "homelab boot bring-up complete"