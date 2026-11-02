#!/usr/bin/env bash
# host.sh - higiene do host PhaseZero (ledger, backups, pegada)
#
# Dry-run é o padrão em tudo que muta. Nada aqui toca ~/Emulation.
#
#   pz host status                   pegada atual (JSON)
#   pz host backups migrate          move .bak legados p/ store central
#   pz host backups migrate --apply  idem, de verdade
#   pz host backups list             lista backups centralizados
#   pz host backups prune [--keep N] mantém só os N mais recentes por arquivo
#   pz host prune [--keep N]         poda backups e logs antigos (não desinstala)
#   pz host wipe                     preview do que o wipe removeria
#   pz host wipe --apply --confirm PHASEZERO-WIPE   remove a pegada do ledger
#
# `wipe` é dirigido pelo LEDGER: só sai o que o PhaseZero registrou ter criado.
# ~/Emulation e dados do usuário nunca entram na lista.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
source "$PZ_ROOT/linux/lib/json-envelope.sh"

PZ_MODULE="host"
PRESERVE="$HOME/Emulation"
CONFIRM_TOKEN="PHASEZERO-WIPE"

usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '1,20p'
}

# --- backups --------------------------------------------------------------

host_backups_migrate() {
    local apply=0 arg
    for arg in "$@"; do
        case "$arg" in
            --apply) apply=1 ;;
            --dry-run|-n) apply=0 ;;
            *) pz_warn "flag desconhecida ignorada: $arg" ;;
        esac
    done

    if [ "$apply" = 1 ]; then
        PZ_DRY_RUN=0 migrate_legacy_baks
    else
        printf 'MODO: DRY-RUN (nada será movido). Para aplicar: --apply\n'
        PZ_DRY_RUN=1 migrate_legacy_baks
    fi
}

host_backups_list() {
    local dir origin count
    if [ ! -d "$PZ_BACKUP_ROOT" ]; then
        printf 'nenhum backup centralizado em %s\n' "$PZ_BACKUP_ROOT"
        return 0
    fi
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        origin="$(cat "$dir/origin" 2>/dev/null || echo '(origem desconhecida)')"
        count="$({ find "$dir" -maxdepth 1 -type f -name '*.bak.*' 2>/dev/null || true; } | wc -l | tr -d ' ')"
        printf '%-4s %s\n' "$count" "$origin"
    done < <({ find "$PZ_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true; } | sort)
}

host_backups_prune() {
    local keep=5 arg
    while [ $# -gt 0 ]; do
        case "$1" in
            --keep) keep="${2:-5}"; shift 2 ;;
            --keep=*) keep="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done
    [ -d "$PZ_BACKUP_ROOT" ] || { printf 'nada a podar\n'; return 0; }
    local dir origin
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        origin="$(cat "$dir/origin" 2>/dev/null || true)"
        [ -n "$origin" ] || continue
        pz_backup_prune "$origin" "$keep"
    done < <(find "$PZ_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    printf 'poda concluída (keep=%s por arquivo)\n' "$keep"
}

# --- wipe dirigido pelo ledger --------------------------------------------

# Guarda absoluta. Um path só é removível se: não vazio, não "/", não $HOME,
# está sob $HOME, e NÃO está dentro de ~/Emulation. Igual à guarda do
# uninstall.sh — duplicada de propósito: é a última linha de defesa.
host_is_safe_target() {
    local target="${1:-}" real
    [ -n "$target" ] || return 1
    real="$(realpath -m -- "$target" 2>/dev/null || printf '%s' "$target")"
    case "$real" in
        "" | "/" | "$HOME") return 1 ;;
    esac
    case "$real" in
        "$HOME"/*) ;;
        *) return 1 ;;
    esac
    [ "$real" = "$PRESERVE" ] && return 1
    case "$real/" in
        "$PRESERVE"/*) return 1 ;;
    esac
    return 0
}

# Paths que o ledger registrou como criados por nós, ainda existentes.
host_wipe_targets() {
    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        # entradas simbólicas (flatpak-remote:foo) não são paths
        case "$path" in */*) ;; *) continue ;; esac
        [ -e "$path" ] || [ -L "$path" ] || continue
        host_is_safe_target "$path" || continue
        printf '%s\n' "$path"
    done < <(pz_ledger_created_paths)
}

# Serviços que o ledger registrou como habilitados por nós.
host_wipe_services() {
    pz_ledger_services
}

host_wipe() {
    local apply=0 confirm="" arg
    while [ $# -gt 0 ]; do
        case "$1" in
            --apply) apply=1; shift ;;
            --dry-run|-n) apply=0; shift ;;
            --confirm) confirm="${2:-}"; shift 2 ;;
            --confirm=*) confirm="${1#*=}"; shift ;;
            *) pz_warn "flag desconhecida ignorada: $1"; shift ;;
        esac
    done

    local -a targets=() services=()
    while IFS= read -r arg; do [ -n "$arg" ] && targets+=("$arg"); done < <(host_wipe_targets)
    while IFS= read -r arg; do [ -n "$arg" ] && services+=("$arg"); done < <(host_wipe_services)

    if [ "$apply" = 1 ] && [ "$confirm" != "$CONFIRM_TOKEN" ]; then
        pz_result_envelope refused \
            "wipe real exige token de confirmação" \
            "Reexecute com: pz host wipe --apply --confirm $CONFIRM_TOKEN" \
            "Para revisar antes: pz host wipe"
        pz_result_emitted
        return 2
    fi

    local removed=0 skipped=0 target service scope unit
    if [ "$apply" = 0 ]; then
        PZ_DRY_RUN=1
        printf 'MODO: DRY-RUN. Preservado SEMPRE: %s\n' "$PRESERVE" >&2
        for target in ${targets[@]+"${targets[@]}"}; do
            printf '  [dry] rm   %s\n' "$target" >&2
        done
        for service in ${services[@]+"${services[@]}"}; do
            printf '  [dry] disable %s\n' "$service" >&2
        done
        pz_result_envelope ok \
            "wipe planejado: ${#targets[@]} path(s), ${#services[@]} serviço(s)" \
            "Para aplicar: pz host wipe --apply --confirm $CONFIRM_TOKEN" \
            "$HOME/Emulation e dados do usuário não entram na lista"
        pz_result_emitted
        return 0
    fi

    for service in ${services[@]+"${services[@]}"}; do
        scope="${service%%:*}"
        unit="${service#*:}"
        if [ "$scope" = "user" ]; then
            systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
        else
            pz_admin_run systemctl disable --now "$unit" >/dev/null 2>&1 || true
        fi
    done

    for target in ${targets[@]+"${targets[@]}"}; do
        if ! host_is_safe_target "$target"; then
            pz_warn "PROTEGIDO (ignorado): $target"
            skipped=$((skipped + 1))
            continue
        fi
        rm -rf -- "$target" && removed=$((removed + 1))
    done

    # o próprio $PZ_STATE (ledger, backups, logs) sai por último
    if host_is_safe_target "$PZ_STATE"; then
        rm -rf -- "$PZ_STATE"
        removed=$((removed + 1))
    fi

    local code="ok"
    pz_degraded && code="degraded"
    if [ "$code" = "degraded" ]; then
        pz_result_degraded_admin \
            "wipe aplicado no escopo de usuário: $removed removido(s), $skipped protegido(s); itens de sistema não foram tocados" \
            "Itens root pendentes: pz host wipe --apply --confirm $CONFIRM_TOKEN com a bridge instalada"
    else
        pz_result_envelope ok \
            "wipe aplicado: $removed removido(s), $skipped protegido(s)" \
            "$HOME/Emulation permanece intacto"
    fi
    pz_result_emitted
}

# --- prune (poda, não desinstala) -----------------------------------------

host_prune() {
    local keep=5 arg
    while [ $# -gt 0 ]; do
        case "$1" in
            --keep) keep="${2:-5}"; shift 2 ;;
            --keep=*) keep="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done
    host_backups_prune --keep "$keep" >/dev/null
    [ -f "$PZ_LOG.1" ] && rm -f "$PZ_LOG.1"
    pz_result_envelope ok "poda concluída (keep=$keep backups por arquivo)" \
        "Nada foi desinstalado; para remover a pegada use: pz host wipe"
    pz_result_emitted
}

# --- status ---------------------------------------------------------------

host_status() {
    # `set -o pipefail` está ativo: todo pipeline com `find` sobre diretório
    # ainda inexistente precisa de guarda explícita, senão o status morre calado.
    local legacy_count backup_groups ledger_entries admin_mode wipe_targets
    legacy_count="$(PZ_DRY_RUN=1 migrate_legacy_baks 2>/dev/null | grep -c '^  \[dry\] migrar' || true)"
    backup_groups="$( { find "$PZ_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true; } | wc -l | tr -d ' ')"
    ledger_entries="$(pz_ledger_count || echo 0)"
    [ -n "$legacy_count" ] || legacy_count=0
    [ -n "$backup_groups" ] || backup_groups=0
    [ -n "$ledger_entries" ] || ledger_entries=0
    admin_mode="$(pz_admin_mode)"
    wipe_targets="$(host_wipe_targets | wc -l | tr -d ' ')"
    [ -n "$wipe_targets" ] || wipe_targets=0

    jq -n \
        --arg stateDir "$PZ_STATE" \
        --arg backupRoot "$PZ_BACKUP_ROOT" \
        --arg ledgerFile "$PZ_LEDGER_FILE" \
        --argjson ledgerEntries "${ledger_entries:-0}" \
        --argjson backupGroups "${backup_groups:-0}" \
        --argjson legacyBaks "${legacy_count:-0}" \
        --argjson wipeTargets "${wipe_targets:-0}" \
        --arg adminMode "$admin_mode" \
        --arg preserved "$PRESERVE" \
        --arg logPath "$PZ_LOG" \
        '{
            ok: true,
            module: "host",
            code: (if $adminMode == "degraded" then "degraded" else "ok" end),
            status: (if $legacyBaks > 0 then "attention" else "ok" end),
            summary: ("\($ledgerEntries) mutação(ões) no ledger, \($wipeTargets) path(s) removível(is)"),
            howToFix: (if $adminMode == "degraded"
                       then ["Instale a admin bridge: linux/pz ai setup admin"]
                       else [] end),
            ledgerRef: ($ledgerFile + "#status"),
            logPath: $logPath,
            adminMode: $adminMode,
            stateDir: $stateDir,
            backupRoot: $backupRoot,
            ledgerFile: $ledgerFile,
            ledgerEntries: $ledgerEntries,
            backupGroups: $backupGroups,
            legacyBaksPending: $legacyBaks,
            wipeTargets: $wipeTargets,
            preserved: [$preserved]
        }'
}

# --- dispatch -------------------------------------------------------------

main() {
    local action="${1:-status}"
    shift 2>/dev/null || true
    case "$action" in
        status) host_status ;;
        wipe)   pz_result_guard_install host; host_wipe "$@" ;;
        prune)  pz_result_guard_install host; host_prune "$@" ;;
        backups)
            local sub="${1:-list}"
            shift 2>/dev/null || true
            case "$sub" in
                migrate) host_backups_migrate "$@" ;;
                list)    host_backups_list ;;
                prune)   host_backups_prune "$@" ;;
                *) pz_error "pz host backups: ação desconhecida: $sub"; usage; return 2 ;;
            esac
            ;;
        duplicates|duplicidades|dup)
            exec python3 "$PZ_ROOT/linux/audit/duplicates.py" "$@"
            ;;
        help|--help|-h) usage ;;
        *) pz_error "pz host: ação desconhecida: $action"; usage; return 2 ;;
    esac
}

main "$@"
