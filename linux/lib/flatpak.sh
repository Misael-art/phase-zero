#!/usr/bin/env bash
# flatpak.sh - PhaseZero Flatpak remote/override management library
set -euo pipefail

pz_flatpak_require() {
    if ! command -v flatpak &>/dev/null; then
        pz_error "flatpak not installed"
        return 1
    fi
}

pz_flatpak_has_remote() {
    local name="$1"
    flatpak --user remote-list --columns=name 2>/dev/null | grep -qxF "$name"
}

pz_flatpak_remote_url() {
    local name="$1"
    flatpak --user remote-list --columns=name,url 2>/dev/null |
        awk -F '\t' -v r="$name" '$1 == r {print $2; exit}' || true
}

pz_flatpak_remote_prio() {
    local name="$1"
    flatpak --user remote-list --columns=name,priority 2>/dev/null |
        awk -v r="$name" '$1 == r {print $2; exit}' || echo ""
}

pz_flatpak_ensure_remote() {
    local name="$1" url="$2"
    shift 2
    pz_flatpak_require || return 1

    if pz_flatpak_has_remote "$name"; then
        local existing_url
        existing_url=$(pz_flatpak_remote_url "$name")
        if [ "$existing_url" != "$url" ]; then
            pz_warn "remote '$name' exists with diff URL: $existing_url != $url"
            pz_info "skip. use --force to reconfigure"
            return 1
        fi
        pz_info "remote '$name' ok"
        return 0
    fi

    pz_info "adding flatpak remote: $name"
    flatpak --user remote-add --if-not-exists "$name" "$url"
    pz_rollback_register "flatpak-remote" "$name" ""
    pz_info "remote '$name' added"
}

pz_flatpak_remove_remote() {
    local name="$1"
    pz_flatpak_require || return 1
    if pz_flatpak_has_remote "$name"; then
        pz_info "removing flatpak remote: $name"
        flatpak --user remote-delete "$name"
    else
        pz_info "remote '$name' not present"
    fi
}

pz_flatpak_override_gaming() {
    local app="${1:-}" scope="${2:-user}"
    shift 2 2>/dev/null || true
    local extras=("$@")

    pz_flatpak_require || return 1

    local base_overrides=(
        --device=dri
        --device=shm
        --device=all
        --filesystem=host:ro
        --filesystem=~/.local/share/Steam:ro
        --filesystem=~/.var/app:ro
        --share=network
        --share=ipc
        --socket=pulseaudio
        --socket=x11
        --socket=wayland
        --socket=fallback-x11
        --env=DXVK_HUD=0
        --env=MANGOHUD=0
        --env=GAMESCOPE_WAYLAND_DISPLAY=1
    )

    if [ -z "$app" ]; then
        pz_info "applying global gaming flatpak overrides ($scope)"
        flatpak override --"$scope" "${base_overrides[@]}" "${extras[@]}"
        return 0
    fi

    if ! flatpak info "$app" &>/dev/null; then
        pz_warn "app $app not installed, skip override"
        return 1
    fi

    pz_info "applying gaming overrides for $app ($scope)"
    flatpak override --"$scope" "${base_overrides[@]}" "${extras[@]}" "$app"
}

pz_flatpak_override_steamdeck() {
    local app="${1:-}" scope="${2:-user}"
    shift 2 2>/dev/null || true

    pz_flatpak_override_gaming "$app" "$scope" \
        --env=STEAM_GAMESCOPE_ENABLED=1 \
        --env=STEAM_DISABLE_MANGOAPP=0 \
        --env=GAMESCOPE_LIMIT=60 \
        "${@}"
}

pz_flatpak_remove_overrides() {
    local app="${1:-}" scope="${2:-user}"
    pz_flatpak_require || return 1
    case "$scope" in
        user|system) ;;
        *) pz_error "invalid flatpak scope: $scope"; return 2 ;;
    esac

    if [ -z "$app" ]; then
        pz_info "removing global gaming flatpak overrides ($scope)"
        flatpak override --"$scope" --reset
        return 0
    fi

    pz_info "removing overrides for $app ($scope)"
    flatpak override --"$scope" --reset "$app"
}

pz_flatpak_audit() {
    pz_flatpak_require || return 1

    echo "=== Flatpak Audit ==="

    local conflicts=0

    echo "--- Remotes ---"
    flatpak remote-list --columns=name,url,options,priority 2>/dev/null | sort

    local flathub_url
    flathub_url=$(pz_flatpak_remote_url "flathub" 2>/dev/null || true)
    if [ -n "$flathub_url" ] && [ "$flathub_url" != "https://dl.flathub.org/repo/" ]; then
        echo "WARN: flathub URL != expected (https://dl.flathub.org/repo/): $flathub_url"
        conflicts=$((conflicts + 1))
    fi

    echo "--- Runtimes ---"
    flatpak list --runtime --columns=application,branch,origin 2>/dev/null | sort -u

    local runtimes multi_branch
    runtimes=$(flatpak list --runtime --columns=application,branch 2>/dev/null | awk '{print $1, $2}' | sort -u)
    multi_branch=$(echo "$runtimes" | awk 'NF >= 2 {print $1}' | sort | uniq -d)
    if [ -n "$multi_branch" ]; then
        echo "INFO: multiple runtime branches installed (normal when apps target different runtimes):"
        echo "$multi_branch" | while read -r app; do
            [ -n "$app" ] && echo "  $app"
        done
    fi

    echo "--- Overrides ---"
    local user_overrides
    user_overrides=$(flatpak override --user --show 2>/dev/null || echo "(none)")
    echo "user: $user_overrides"
    local system_overrides
    system_overrides=$(flatpak override --system --show 2>/dev/null || echo "(none)")
    echo "system: $system_overrides"

    echo "--- Install Scope ---"
    local system_apps user_apps duplicate_apps
    system_apps=$(flatpak list --system --app --columns=application 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')
    user_apps=$(flatpak list --user --app --columns=application 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')
    duplicate_apps=$(comm -12 \
        <(flatpak list --system --app --columns=application 2>/dev/null | sort -u) \
        <(flatpak list --user --app --columns=application 2>/dev/null | sort -u) || true)
    echo "system: $system_apps apps, user: $user_apps apps"
    if [ -n "$duplicate_apps" ]; then
        echo "WARN: apps installed in both system and user scopes:"
        # shellcheck disable=SC2086 # intentional word splitting: one app id per line
        printf '  %s\n' $duplicate_apps
        conflicts=$((conflicts + 1))
    fi

    if [ "$conflicts" -gt 0 ]; then
        echo "---"
        echo "FOUND $conflicts conflict(s). use 'pz flatpak audit --repair' to fix"
    else
        echo "---"
        echo "OK: no conflicts detected"
    fi

    [ "$conflicts" -lt 126 ] || conflicts=125
    return "$conflicts"
}

pz_flatpak_audit_repair() {
    pz_flatpak_require || return 1
    local rc=0
    pz_flatpak_audit || rc=$?

    if [ "$rc" -eq 0 ]; then
        return 0
    fi

    local flathub_url
    flathub_url=$(pz_flatpak_remote_url "flathub" 2>/dev/null || true)
    if [ -n "$flathub_url" ] && [ "$flathub_url" != "https://dl.flathub.org/repo/" ]; then
        pz_info "repair: reconfiguring flathub remote"
        flatpak remote-modify flathub --url=https://dl.flathub.org/repo/ 2>/dev/null || {
            flatpak remote-delete flathub 2>/dev/null || true
            flatpak remote-add flathub https://flathub.org/repo/flathub.flatpakrepo
        }
    fi

    pz_info "removing unused flatpak runtimes"
    flatpak uninstall --unused -y 2>/dev/null || true

    pz_info "audit repair complete"
}

pz_flatpak_steamdeck_compat() {
    local dry_run="${PZ_DRY_RUN:-0}"

    pz_flatpak_require || return 1

    pz_info "configuring steamdeck flatpak compat"

    if [ "$dry_run" = "1" ]; then
        pz_info "dry-run: would add flathub"
    else
        pz_flatpak_ensure_remote \
            "flathub" \
            "https://dl.flathub.org/repo/flathub.flatpakrepo"
    fi

    if [ "$dry_run" = "1" ]; then
        pz_info "dry-run: would add flathub-beta"
    else
        pz_flatpak_ensure_remote \
            "flathub-beta" \
            "https://flathub.org/beta-repo/flathub-beta.flatpakrepo"
    fi

    if [ "$dry_run" = "1" ]; then
        pz_info "dry-run: would apply gaming overrides"
        return 0
    fi

    local installed
    installed=$(flatpak list --columns=application 2>/dev/null)
    local gaming_apps=(
        "com.valvesoftware.Steam"
        "org.libretro.RetroArch"
        "net.lutris.Lutris"
        "com.heroicgameslauncher.hgl"
        "org.prismlauncher.PrismLauncher"
    )
    for app in "${gaming_apps[@]}"; do
        if echo "$installed" | grep -qxF "$app"; then
            pz_flatpak_override_steamdeck "$app"
        fi
    done

    pz_flatpak_override_gaming "" "user"
}

pz_flatpak_setup_from_profile() {
    local profile_file="$1"
    local dry_run="${PZ_DRY_RUN:-0}"

    local flatpak_raw
    flatpak_raw=$(jq -r '.packages.linux.flatpak // empty' "$profile_file" 2>/dev/null || true)
    [ -z "$flatpak_raw" ] && return 0

    # PZ-AUD-027: a declared flatpak selection bootstraps its own runtime
    # instead of silently skipping when flatpak is absent.
    if ! command -v flatpak &>/dev/null; then
        if [ "$dry_run" = "1" ]; then
            pz_info "would bootstrap flatpak runtime for declared selection"
        elif command -v pacman &>/dev/null; then
            pz_info "bootstrapping flatpak runtime..."
            pz_admin_run pacman -S --needed --noconfirm flatpak || {
                pz_error "profile needs flatpak but it could not be installed; install flatpak and re-run"
                return 1
            }
        else
            pz_error "profile needs flatpak but no supported installer exists on this host"
            return 1
        fi
    fi
    pz_flatpak_require 2>/dev/null || return 0

    local is_object=false
    echo "$flatpak_raw" | jq -e '. | type == "object"' >/dev/null 2>&1 && is_object=true

    if [ "$is_object" = true ]; then
        local remotes packages overrides
        remotes=$(jq -r '.packages.linux.flatpak.remotes // [] | .[] | "\(.name)\t\(.url)\t\(.required // true)"' "$profile_file" 2>/dev/null || true)
        packages=$(jq -r '.packages.linux.flatpak.packages // [] | .[]' "$profile_file" 2>/dev/null || true)
        overrides=$(jq -r '.packages.linux.flatpak.overrides // {}' "$profile_file" 2>/dev/null || true)

        if [ -n "$remotes" ]; then
            if [ "$dry_run" = "1" ]; then pz_info "planning flatpak remotes..."; else pz_info "configuring flatpak remotes..."; fi
            while IFS=$'\t' read -r name url required; do
                [ -z "$name" ] || [ -z "$url" ] && continue
                if [ "$dry_run" = "1" ]; then
                    pz_info "  would add remote: $name -> $url"
                    continue
                fi
                pz_flatpak_ensure_remote "$name" "$url" || {
                    if [ "$required" = "true" ]; then
                        pz_error "required remote '$name' failed"
                        return 1
                    fi
                    pz_warn "optional remote '$name' failed"
                }
            done < <(printf '%s\n' "$remotes")
        fi

        if [ -n "$packages" ] && [ "$dry_run" = "1" ]; then
            pz_info "planning flatpak packages from profile..."
            echo "$packages" | while IFS= read -r pkg; do
                [ -z "$pkg" ] && continue
                pz_info "  would install: $pkg"
            done
        fi

        if [ -n "$overrides" ] && [ "$overrides" != "{}" ]; then
            local override_type
            override_type=$(echo "$overrides" | jq -r 'keys[]' 2>/dev/null || true)
            for ot in $override_type; do
                if [ "$dry_run" = "1" ]; then
                    pz_info "  would apply $ot overrides"
                else
                    case "$ot" in
                        gaming) pz_flatpak_override_gaming "" "user" ;;
                        steamdeck) pz_flatpak_override_steamdeck "" "user" ;;
                        *) pz_info "unknown override type: $ot" ;;
                    esac
                fi
            done
        fi
    fi
}

pz_flatpak_status() {
    pz_flatpak_require 2>/dev/null || { echo '{"flatpak":false}'; return 0; }

    local remotes runtimes apps user_apps system_apps
    remotes=$(flatpak remote-list --columns=name,url 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')
    runtimes=$(flatpak list --runtime --columns=application 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')
    apps=$(flatpak list --app --columns=application 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')
    user_apps=$(flatpak list --user --app --columns=application 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')
    system_apps=$(flatpak list --system --app --columns=application 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')

    jq -n \
        --argjson flatpak true \
        --argjson remotes "$remotes" \
        --argjson runtimes "$runtimes" \
        --argjson apps "$apps" \
        --argjson user_apps "$user_apps" \
        --argjson system_apps "$system_apps" \
        '{flatpak: $flatpak, remotes: $remotes, runtimes: $runtimes, apps: $apps, user_apps: $user_apps, system_apps: $system_apps}'
}

pz_flatpak_rollback() {
    if [ ! -f "$PZ_MANIFEST" ]; then return 0; fi
    local entries
    entries=$(jq -c 'reverse | .[] | select(.action == "flatpak-remote")' "$PZ_MANIFEST" 2>/dev/null || true)
    [ -z "$entries" ] && return 0
    echo "$entries" | while read -r entry; do
        local name
        name=$(echo "$entry" | jq -r '.target')
        pz_flatpak_remove_remote "$name"
    done
}
