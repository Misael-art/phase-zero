#!/usr/bin/env bash
# common.sh - PhaseZero Linux shared library
set -euo pipefail
umask 077

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PZ_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero"
PZ_OPERATION_ID="${PZ_OPERATION_ID:-legacy-$(date +%Y%m%d-%H%M%S)-${BASHPID:-$$}}"
PZ_MANIFEST="${PZ_MANIFEST:-$PZ_STATE/operations/$PZ_OPERATION_ID.json}"
PZ_LOG="$PZ_STATE/pz.log"
PZ_BACKUP_ROOT="${PZ_BACKUP_ROOT:-$PZ_STATE/backups}"
PZ_TEMP_FILES=()
PZ_CLEANUP_REGISTERED=0
PZ_STATE_READY=0

pz_tempfile() {
    local t registry template_base
    template_base="${TMPDIR:-/tmp}"
    if [ "$#" -eq 1 ] && [[ "$1" != -* ]] && [[ "$1" != */* ]]; then
        set -- "$template_base/$1"
    fi
    t="$(mktemp "$@")"
    PZ_TEMP_FILES+=("$t")
    registry="${XDG_RUNTIME_DIR:-$template_base}/phasezero-temp-registry.$UID.$$.list"
    umask 077
    printf '%s\0' "$t" >> "$registry"
    echo "$t"
}

pz_cleanup_temp() {
    local rc=$?
    local registry="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/phasezero-temp-registry.$UID.$$.list" entry
    if [ ${#PZ_TEMP_FILES[@]} -gt 0 ]; then
        rm -f "${PZ_TEMP_FILES[@]}" 2>/dev/null || true
    fi
    if [ -f "$registry" ] && [ ! -L "$registry" ]; then
        while IFS= read -r -d '' entry; do
            [ -n "$entry" ] || continue
            if [ "$entry" = "/" ] || [ "$entry" = "$HOME" ]; then
                continue
            fi
            if [ -d "$entry" ] && [ ! -L "$entry" ]; then
                rm -rf -- "$entry" 2>/dev/null || true
            else
                rm -f -- "$entry" 2>/dev/null || true
            fi
        done < "$registry"
        rm -f -- "$registry" 2>/dev/null || true
    fi
    return "$rc"
}

if [ "${PZ_CLEANUP_REGISTERED:-0}" = "0" ]; then
    trap pz_cleanup_temp EXIT
    PZ_CLEANUP_REGISTERED=1
fi

# O estado é criado SOB DEMANDA, nunca no `source`. Comandos puramente
# informativos (`pz help`, `pz version`) não podem tocar o host.
pz_state_init() {
    [ "${PZ_STATE_READY:-0}" = "1" ] && return 0
    mkdir -p "$PZ_STATE" "$PZ_STATE/operations"
    chmod 0700 "$PZ_STATE" "$PZ_STATE/operations" 2>/dev/null || true
    if [ -f "$PZ_LOG" ] && [ "$(stat -c %s "$PZ_LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
        mv -f "$PZ_LOG" "$PZ_LOG.1"
    fi
    touch "$PZ_LOG"
    chmod 0600 "$PZ_LOG" 2>/dev/null || true
    PZ_STATE_READY=1
}

pz_log() {
    local level="$1" msg="$2"
    pz_state_init
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >> "$PZ_LOG"
    case "$level" in
        ERROR) echo >&2 "ERROR: $msg" ;;
        WARN)  echo >&2 "WARN:  $msg" ;;
        INFO)  echo "INFO:  $msg" ;;
        DEBUG) : ;;
        *)     echo "$msg" ;;
    esac
}

pz_info() { pz_log INFO "$*"; }
pz_warn() { pz_log WARN "$*"; }
pz_error() { pz_log ERROR "$*"; }
# DEBUG só vai para o arquivo de log: nunca polui stdout de envelopes JSON.
# Também nunca CRIA o log — senão um dry-run puro passaria a sujar o host só
# por ter emitido rastreio.
pz_debug() {
    [ -f "$PZ_LOG" ] || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*" >> "$PZ_LOG"
}

# O ledger é dependência dura das rotinas de mutação abaixo. Carregado aqui,
# depois de pz_log/pz_debug existirem (ledger.sh usa ambos).
# shellcheck source=linux/lib/ledger.sh
source "$PZ_ROOT/linux/lib/ledger.sh"

pz_can_sudo_noninteractive() {
    command -v sudo &>/dev/null && sudo -n true &>/dev/null
}

# Código de saída reservado para "sem admin bridge". Chamadores que sabem
# degradar tratam 77; quem não trata, propaga — mas nunca crasha calado.
PZ_RC_NO_ADMIN=77

# ready   = dá para escalar privilégio agora
# degraded= não dá; o produto continua, só que em dry-run para mutações root
pz_admin_mode() {
    if [ "$EUID" -eq 0 ] \
        || command -v phasezero-admin >/dev/null 2>&1 \
        || command -v bigsudo >/dev/null 2>&1 \
        || { [ "${PZ_USE_SUDO:-0}" = "1" ] && pz_can_sudo_noninteractive; }; then
        echo ready
    else
        echo degraded
    fi
}

pz_admin_available() { [ "$(pz_admin_mode)" = "ready" ]; }

# Mensagem acionável única, para não divergir entre CLI e UI.
pz_admin_howtofix() {
    printf '%s\n' \
        "Instale a admin bridge: linux/pz ai setup admin" \
        "Alternativa: rode o comando dentro de um shell root (bigsudo / phasezero-admin)" \
        "Sem a bridge, mutações de sistema ficam em dry-run — nada foi alterado"
}

pz_admin_run() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    elif command -v phasezero-admin >/dev/null 2>&1; then
        phasezero-admin "$@"
    elif command -v bigsudo >/dev/null 2>&1; then
        bigsudo "$@"
    elif [ "${PZ_USE_SUDO:-0}" = "1" ] && pz_can_sudo_noninteractive; then
        sudo -n "$@"
    else
        # DEGRADE, não crash: a operação root vira um no-op anunciado e o
        # chamador recebe PZ_RC_NO_ADMIN para montar o envelope result.
        PZ_DEGRADED=1
        pz_warn "admin bridge ausente; degradando para dry-run: $*"
        return "$PZ_RC_NO_ADMIN"
    fi
}

# Verdadeiro quando alguma chamada nesta execução foi degradada.
pz_degraded() { [ "${PZ_DEGRADED:-0}" = "1" ]; }

# --- host capacity (PZ-AUD-031): one definition of available memory/disk ---
#
# availableMB is memory actually free for new workloads (MemAvailable), not
# MemTotal. Total is reported separately for transparency. Both governors
# (per-app and per-profile) read through these helpers so app and profile
# verdicts can never diverge on the same host.

pz_mem_available_mb() {
    if [ -n "${PZ_HOMELAB_RAM_TOTAL_OVERRIDE:-}" ]; then
        printf '%s\n' "$PZ_HOMELAB_RAM_TOTAL_OVERRIDE"
        return 0
    fi
    awk '/^MemAvailable:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null         || { pz_error "cannot read available RAM"; return 1; }
}

pz_mem_total_mb() {
    awk '/^MemTotal:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null         || { pz_error "cannot read total RAM"; return 1; }
}

pz_disk_available_mb() {
    local path="${1:-$PZ_STATE}"
    df -Pm "$path" 2>/dev/null | awk 'NR==2 {printf "%d", $4; exit}'         || { pz_error "cannot read free disk for $path"; return 1; }
}

# --- backups centralizados ------------------------------------------------
#
# Backup NUNCA fica ao lado do arquivo original (isso é lixo no host do
# usuário e escapa do uninstall). Layout canônico:
#
#   $PZ_STATE/backups/<sha256 do path original>/<basename>.bak.<epoch-ns>
#   $PZ_STATE/backups/<sha256 do path original>/origin   <- path original
#
# `origin` existe para tornar o store auditável e permitir restore sem
# recalcular hashes.

pz_backup_path_key() {
    local path="$1" real
    real="$(realpath -m -- "$path" 2>/dev/null || printf '%s' "$path")"
    printf '%s' "$real" | sha256sum | awk '{print $1}'
}

pz_backup_dir_for() {
    printf '%s/%s\n' "$PZ_BACKUP_ROOT" "$(pz_backup_path_key "$1")"
}

# pz_backup_file <path> [scope]
# Imprime o path do backup criado (ou nada, se o original não existe).
# Respeita PZ_DRY_RUN: planeja o destino sem copiar.
pz_backup_file() {
    local path="${1:-}" scope="${2:-user}" real dir dest
    [ -n "$path" ] || return 0
    real="$(realpath -m -- "$path" 2>/dev/null || printf '%s' "$path")"
    [ -f "$real" ] || [ -L "$real" ] || return 0

    dir="$PZ_BACKUP_ROOT/$(pz_backup_path_key "$real")"
    dest="$dir/$(basename "$real").bak.$(date +%s%N)"

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_debug "[dry] backup $real -> $dest"
        printf '%s\n' "$dest"
        return 0
    fi

    pz_state_init
    mkdir -p "$dir"
    chmod 0700 "$dir" 2>/dev/null || true
    printf '%s\n' "$real" > "$dir/origin"

    if [ "$scope" = "root" ] && [ "$EUID" -ne 0 ]; then
        pz_admin_run cat "$real" > "$dest" 2>/dev/null || { rm -f "$dest"; return 0; }
    else
        cp -p "$real" "$dest" 2>/dev/null || return 0
    fi

    ledger_record \
        --module "${PZ_MODULE:-common}" \
        --action backup \
        --modified "$real" \
        --backup "$dest" \
        --scope "$([ "$scope" = "root" ] && echo system || echo user)" \
        --reversible true \
        --rollback-cmd "cp -p -- $(printf '%q' "$dest") $(printf '%q' "$real")"

    printf '%s\n' "$dest"
}

# Backup mais recente de <path>, com DUAL-READ: store novo primeiro, depois
# os `.bak` legados gravados ao lado do original por versões anteriores.
pz_backup_latest() {
    local path="${1:-}" real dir newest base
    [ -n "$path" ] || return 1
    real="$(realpath -m -- "$path" 2>/dev/null || printf '%s' "$path")"

    dir="$PZ_BACKUP_ROOT/$(pz_backup_path_key "$real")"
    if [ -d "$dir" ]; then
        newest="$(find "$dir" -maxdepth 1 -type f -name '*.bak.*' -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2- || true)"
        if [ -n "$newest" ]; then
            printf '%s\n' "$newest"
            return 0
        fi
    fi

    # legado: ${path}.bak.* e ${path}.phasezero.bak.*
    base="$(basename "$real")"
    newest="$(find "$(dirname "$real")" -maxdepth 1 -type f \
        \( -name "$base.bak.*" -o -name "$base.phasezero.bak.*" \) \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
    if [ -n "$newest" ]; then
        printf '%s\n' "$newest"
        return 0
    fi
    return 1
}

# pz_backup_prune <path> [keep] — mantém apenas os N backups mais recentes de
# <path> no store central. Substitui os `find | head -N | xargs rm` que os
# módulos faziam ao lado do arquivo original.
pz_backup_prune() {
    local path="${1:-}" keep="${2:-5}" dir
    [ -n "$path" ] || return 0
    dir="$PZ_BACKUP_ROOT/$(pz_backup_path_key "$path")"
    [ -d "$dir" ] || return 0
    [ "${PZ_DRY_RUN:-0}" = "1" ] && return 0
    find "$dir" -maxdepth 1 -type f -name '*.bak.*' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | awk -v keep="$keep" 'NR>keep{sub(/^[^ ]+ /, ""); print}' \
        | xargs -r rm -f --
    return 0
}

# pz_restore_file <path> [scope] — restaura do backup mais recente (dual-read).
pz_restore_file() {
    local path="${1:-}" scope="${2:-user}" src real
    [ -n "$path" ] || return 1
    real="$(realpath -m -- "$path" 2>/dev/null || printf '%s' "$path")"
    if ! src="$(pz_backup_latest "$real")"; then
        pz_warn "sem backup para restaurar: $real"
        return 1
    fi
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "[dry] restauraria $real de $src"
        return 0
    fi
    if [ "$scope" = "root" ] && [ "$EUID" -ne 0 ]; then
        pz_admin_run install -m 0644 "$src" "$real"
    else
        mkdir -p "$(dirname "$real")"
        cp -p "$src" "$real"
    fi
    pz_info "restaurado $real de $src"
}

# Raízes varridas por migrate_legacy_baks. Curadoria explícita: só diretórios
# onde o PhaseZero comprovadamente grava. Nunca varre $HOME inteiro e nunca
# entra em ~/Emulation.
pz_legacy_bak_roots() {
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
    local data="${XDG_DATA_HOME:-$HOME/.local/share}"
    local state="${XDG_STATE_HOME:-$HOME/.local/state}"
    printf '%s\n' \
        "${PZ_LOCAL_BIN:-$HOME/.local/bin}" \
        "$cfg/systemd/user" \
        "$data/applications" \
        "$cfg/phasezero" \
        "$data/phasezero" \
        "$state/phasezero" \
        "$cfg/opencode" \
        "$cfg/ai.z.zcode" \
        "$cfg/codexbar" \
        "$cfg/ai-usagebar" \
        "$cfg/ai-memory" \
        "$cfg/openclaw" \
        "$cfg/omo" \
        "$cfg/hydra" \
        "$cfg/Code/User" \
        "$cfg/kwinrulesrc.d" \
        "$HOME/.continue" \
        "$HOME/.codexbar" \
        "$HOME/.9router" \
        "$HOME/.codex"
}

# Arquivos soltos (não-diretórios) que o PhaseZero versiona e cujos `.bak`
# legados ficam no diretório-pai compartilhado com dados do usuário.
pz_legacy_bak_files() {
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
    printf '%s\n' \
        "$HOME/.bashrc" \
        "$HOME/.zshrc" \
        "$HOME/.profile" \
        "$cfg/kwinrulesrc" \
        "$cfg/kglobalshortcutsrc" \
        "$cfg/kwinrc"
}

pz_is_legacy_bak_name() {
    # .bak.<epoch>[.<pid>[.<rand>]]  |  .bak.<epoch-ns>  |  .phasezero.bak.<...>
    [[ "${1:-}" =~ \.(phasezero\.)?bak\.[0-9]+(\.[0-9]+)*(\.[A-Za-z0-9_-]+)?$ ]]
}

# Path original a partir do nome de um backup legado.
pz_legacy_bak_origin() {
    local bak="${1:-}"
    printf '%s\n' "${bak%%.bak.*}" | sed 's/\.phasezero$//'
}

# migrate_legacy_baks — move `*.bak.*` legados do PhaseZero para o store
# central. Idempotente (rodar duas vezes não muda nada) e dry-run-aware.
# Critério de pronto: zero `*.bak.*` PhaseZero fora de $PZ_BACKUP_ROOT.
migrate_legacy_baks() {
    local preserve="$HOME/Emulation"
    local moved=0 planned=0
    local root file origin dir dest candidates=()

    while IFS= read -r root; do
        [ -d "$root" ] || continue
        case "$root/" in "$preserve"/*) continue ;; esac
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            candidates+=("$file")
        done < <(find "$root" -type f -name '*.bak.*' 2>/dev/null)
    done < <(pz_legacy_bak_roots)

    while IFS= read -r file; do
        [ -n "$file" ] || continue
        [ -f "$file" ] || continue
        candidates+=("$file")
    done < <(
        pz_legacy_bak_files | while IFS= read -r target; do
            [ -n "$target" ] || continue
            find "$(dirname "$target")" -maxdepth 1 -type f \
                \( -name "$(basename "$target").bak.*" \
                -o -name "$(basename "$target").phasezero.bak.*" \) 2>/dev/null
        done
    )

    for file in ${candidates[@]+"${candidates[@]}"}; do
        # já está no store central: nada a fazer (idempotência)
        case "$file" in "$PZ_BACKUP_ROOT"/*) continue ;; esac
        case "$file/" in "$preserve"/*) continue ;; esac
        pz_is_legacy_bak_name "$file" || continue

        origin="$(pz_legacy_bak_origin "$file")"
        dir="$PZ_BACKUP_ROOT/$(pz_backup_path_key "$origin")"
        dest="$dir/$(basename "$origin").bak.$(date +%s%N)"

        if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
            printf '  [dry] migrar %s -> %s\n' "$file" "$dest"
            planned=$((planned + 1))
            continue
        fi

        pz_state_init
        mkdir -p "$dir"
        chmod 0700 "$dir" 2>/dev/null || true
        printf '%s\n' "$origin" > "$dir/origin"
        if mv -f -- "$file" "$dest" 2>/dev/null; then
            moved=$((moved + 1))
            ledger_record \
                --module common \
                --action migrate-legacy-backup \
                --backup "$dest" \
                --modified "$origin" \
                --scope user \
                --reversible false
        else
            pz_warn "não foi possível migrar backup legado: $file"
        fi
    done

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "migração de backups legados (dry-run): $planned candidato(s)"
    else
        pz_info "migração de backups legados: $moved movido(s)"
    fi
    return 0
}

pz_write_managed_file() {
    local path="$1" scope="${2:-user}"
    local dir tmp backup existed=0
    dir="$(dirname "$path")"
    tmp="$(mktemp)"
    cat > "$tmp"
    [ -f "$path" ] && existed=1

    if [ "$scope" = "root" ] && [ "$EUID" -ne 0 ]; then
        if command -v phasezero-admin >/dev/null 2>&1 || command -v bigsudo >/dev/null 2>&1 || { [ "${PZ_USE_SUDO:-0}" = "1" ] && pz_can_sudo_noninteractive; }; then
            backup="$(pz_backup_file "$path" root)"
            pz_admin_run install -d "$dir"
            pz_admin_run install -m 0644 "$tmp" "$path"
            rm -f "$tmp"
            pz_write_managed_file_record "$path" system "$existed" "$backup"
            pz_info "wrote $path"
            return 0
        fi

        rm -f "$tmp"
        pz_warn "$path requires root; skipped non-interactive write"
        return 77
    fi

    mkdir -p "$dir"
    backup="$(pz_backup_file "$path" user)"
    install -m 0644 "$tmp" "$path"
    rm -f "$tmp"
    pz_write_managed_file_record "$path" user "$existed" "$backup"
    pz_info "wrote $path"
}

# Hook de ledger de pz_write_managed_file: arquivo novo entra como `created`
# (o wipe pode removê-lo); arquivo pré-existente entra como `modified` com o
# backup correspondente (o rollback restaura).
pz_write_managed_file_record() {
    local path="$1" scope="$2" existed="$3" backup="${4:-}"
    local -a args=(--module "${PZ_MODULE:-common}" --action write-managed-file --scope "$scope")
    if [ "$existed" = "1" ]; then
        args+=(--modified "$path" --reversible true)
        [ -n "$backup" ] && args+=(--backup "$backup" \
            --rollback-cmd "cp -p -- $(printf '%q' "$backup") $(printf '%q' "$path")")
    else
        args+=(--created "$path" --reversible true \
            --rollback-cmd "rm -f -- $(printf '%q' "$path")")
    fi
    ledger_record "${args[@]}"
}

# Atalho para mutações que NÃO passam por pz_write_managed_file (instalação de
# binário, .desktop escrito com `cat >`, diretório de runtime criado à mão).
# Use logo APÓS a mutação ter acontecido de fato.
#   pz_record_created <module> <path> [scope]
pz_record_created() {
    local module="${1:-${PZ_MODULE:-unknown}}" path="${2:-}" scope="${3:-user}"
    [ -n "$path" ] || return 0
    ledger_record --module "$module" --action create-path --created "$path" \
        --scope "$scope" --reversible true \
        --rollback-cmd "rm -rf -- $(printf '%q' "$path")"
}

pz_check_deps() {
    local missing=()
    for dep in "$@"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        pz_error "missing dependencies: ${missing[*]}"
        echo "Install: sudo pacman -S ${missing[*]}"
        return 1
    fi
}

pz_require_root() {
    if [ "$EUID" -ne 0 ]; then
        if command -v phasezero-admin &>/dev/null; then
            exec phasezero-admin "$0" "$@"
        elif command -v bigsudo &>/dev/null; then
            exec bigsudo "$0" "$@"
        else
            PZ_DEGRADED=1
            pz_warn "root required but admin bridge is missing; run: linux/pz ai setup admin"
            return "$PZ_RC_NO_ADMIN"
        fi
    fi
}

pz_boot_target_root() {
    local root="${PZ_BOOT_TARGET_ROOT:-/}"
    [ -n "$root" ] || root="/"
    if command -v realpath >/dev/null 2>&1 && [ -e "$root" ]; then
        realpath -m "$root"
    else
        printf '%s\n' "$root"
    fi
}

pz_boot_path() {
    local rel="${1:-/}" target
    target="$(pz_boot_target_root)"
    rel="/${rel#/}"
    if [ "$target" = "/" ]; then
        printf '%s\n' "$rel"
    else
        printf '%s%s\n' "${target%/}" "$rel"
    fi
}

pz_boot_require_current_root_target() {
    local target
    target="$(pz_boot_target_root)"
    if [ "$target" != "/" ]; then
        pz_error "target-root mutation must run inside target chroot. use: arch-chroot $target"
        return 1
    fi
}

pz_boot_mount_value() {
    local field="$1" target
    target="$(pz_boot_target_root)"
    findmnt -no "$field" -T "$target" 2>/dev/null | head -1
}

pz_boot_root_uuid() {
    pz_boot_mount_value UUID
}

pz_boot_root_subvol() {
    pz_boot_mount_value OPTIONS | tr ',' '\n' | awk -F= '$1 == "subvol" {print $2; exit}'
}

pz_boot_root_fstype() {
    pz_boot_mount_value FSTYPE
}

pz_boot_latest_kernel_version() {
    local boot_dir
    boot_dir="$(pz_boot_path /boot)"
    find "$boot_dir" -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null |
        sort -V | tail -1 | sed 's/^vmlinuz-//'
}

pz_boot_grub_relpath() {
    local target fstype subvol
    target="$(pz_boot_target_root)"
    fstype="$(pz_boot_root_fstype || true)"
    subvol="$(pz_boot_root_subvol || true)"
    if [ "$target" = "/" ] && command -v grub-mkrelpath >/dev/null 2>&1 && [ -d /boot/grub ]; then
        grub-mkrelpath /boot/grub
        return 0
    fi
    if [ "$fstype" = "btrfs" ] && [ -n "$subvol" ]; then
        printf '%s\n' "${subvol%/}/boot/grub"
    else
        printf '%s\n' "/boot/grub"
    fi
}

pz_boot_file_relpath() {
    local rel="${1:-}" target fstype subvol
    rel="/${rel#/}"
    target="$(pz_boot_target_root)"
    fstype="$(pz_boot_root_fstype || true)"
    subvol="$(pz_boot_root_subvol || true)"
    if [ "$target" = "/" ] && command -v grub-mkrelpath >/dev/null 2>&1 && [ -e "$rel" ]; then
        grub-mkrelpath "$rel"
        return 0
    fi
    if [ "$fstype" = "btrfs" ] && [ -n "$subvol" ]; then
        printf '%s\n' "${subvol%/}$rel"
    else
        printf '%s\n' "$rel"
    fi
}

pz_boot_esp_dir() {
    pz_boot_path "${PZ_BOOT_ESP_DIR:-/boot/efi}"
}

pz_boot_file_state() {
    local path="$1" parent
    if [ -e "$path" ]; then
        echo present
        return 0
    fi
    parent="$(dirname "$path")"
    while [ "$parent" != "/" ] && [ ! -e "$parent" ]; do
        parent="$(dirname "$parent")"
    done
    if [ -e "$parent" ] && [ ! -x "$parent" ]; then
        echo permission-denied
    else
        echo missing
    fi
}

pz_boot_refuse_live_root() {
    local source fstype target
    target="$(pz_boot_target_root)"
    source="$(findmnt -no SOURCE -T "$target" 2>/dev/null | head -1 || true)"
    fstype="$(findmnt -no FSTYPE -T "$target" 2>/dev/null | head -1 || true)"

    if [ "${PZ_ALLOW_LIVE_BOOT_MUTATION:-0}" = "1" ]; then
        pz_warn "PZ_ALLOW_LIVE_BOOT_MUTATION=1 set; live-root boot guard bypassed"
        return 0
    fi

    if [ -d /run/miso/bootmnt ] && { [ -z "$source" ] || [[ "$source" != /dev/* ]]; }; then
        pz_error "refusing GRUB mutation from live/root overlay target: $target. chroot into target root or set PZ_ALLOW_LIVE_BOOT_MUTATION=1"
        return 1
    fi

    case "$fstype" in
        overlay|squashfs|iso9660)
            pz_error "refusing GRUB mutation on live filesystem type: $fstype target=$target"
            return 1
            ;;
    esac
}

pz_boot_preflight_grub() {
    pz_boot_refuse_live_root
    command -v grub-mkrelpath >/dev/null 2>&1 || { pz_error "grub-mkrelpath missing"; return 1; }
    if ! command -v update-grub >/dev/null 2>&1 && ! command -v grub-mkconfig >/dev/null 2>&1; then
        pz_error "update-grub/grub-mkconfig missing"
        return 1
    fi
    [ -d "$(pz_boot_path /boot/grub)" ] || { pz_error "$(pz_boot_path /boot/grub) missing"; return 1; }
    [ -n "$(pz_boot_root_uuid)" ] || { pz_error "could not resolve target root UUID"; return 1; }
    [ -n "$(pz_boot_latest_kernel_version)" ] || { pz_error "could not resolve /boot/vmlinuz-*"; return 1; }
    if [ ! -d "$(pz_boot_esp_dir)" ]; then
        pz_error "ESP not mounted at $(pz_boot_esp_dir)"
        return 1
    fi
}

pz_boot_backup_bundle() {
    local reason="${1:-grub-mutation}" ts base dir target
    ts="$(date '+%Y%m%d-%H%M%S')"
    target="$(pz_boot_target_root)"
    base="$(pz_boot_path /var/lib/phasezero/boot-backups)"
    install -d "$base"
    dir="$(mktemp -d "$base/${ts}.XXXXXX")"
    if [ -f "$(pz_boot_path /etc/default/grub)" ]; then
        cp -a "$(pz_boot_path /etc/default/grub)" "$dir/grub.default" 2>/dev/null || true
    fi
    if [ -d "$(pz_boot_path /etc/default/grub.d)" ]; then
        cp -a "$(pz_boot_path /etc/default/grub.d)" "$dir/grub.d.default" 2>/dev/null || true
    fi
    if [ -d "$(pz_boot_path /etc/grub.d)" ]; then
        cp -a "$(pz_boot_path /etc/grub.d)" "$dir/grub.d.scripts" 2>/dev/null || true
    fi
    if [ -f "$(pz_boot_path /boot/grub/grub.cfg)" ]; then
        cp -a "$(pz_boot_path /boot/grub/grub.cfg)" "$dir/grub.cfg" 2>/dev/null || true
    fi
    if [ -f "$(pz_boot_path /boot/grub/grubenv)" ]; then
        cp -a "$(pz_boot_path /boot/grub/grubenv)" "$dir/grubenv" 2>/dev/null || true
    fi
    if [ -d "$(pz_boot_esp_dir)/EFI" ]; then
        cp -a "$(pz_boot_esp_dir)/EFI" "$dir/EFI" 2>/dev/null || true
    fi
    lsblk -f > "$dir/lsblk-f.txt" 2>&1 || true
    blkid > "$dir/blkid.txt" 2>&1 || true
    findmnt > "$dir/findmnt.txt" 2>&1 || true
    if command -v efibootmgr >/dev/null 2>&1; then
        efibootmgr -v > "$dir/efibootmgr-v.txt" 2>&1 || true
    fi
    printf '%s\n' "$reason" > "$dir/reason.txt"
    printf '%s\n' "$target" > "$dir/target-root.txt"
    ledger_record \
        --module boot \
        --action boot-backup-bundle \
        --created "$dir" \
        --backup "$dir" \
        --scope system \
        --reversible false
    pz_info "boot backup bundle: $dir"
}

pz_boot_refresh_grub_config() {
    local cfg="${1:-/boot/grub/grub.cfg}" log log_dir log_target rc=0
    pz_boot_require_current_root_target
    log="$(mktemp)"
    if command -v update-grub >/dev/null 2>&1; then
        update-grub 2>&1 | tee "$log" || rc=$?
    else
        grub-mkconfig -o "$cfg" 2>&1 | tee "$log" || rc=$?
    fi
    log_dir="/var/lib/phasezero/boot-logs"
    install -d "$log_dir" 2>/dev/null || log_dir="$PZ_STATE/boot-logs"
    install -d "$log_dir"
    log_target="$log_dir/grub-refresh-$(date '+%Y%m%d-%H%M%S').log"
    cp "$log" "$log_target" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        pz_error "GRUB config refresh failed rc=$rc log=$log_target"
        rm -f "$log"
        return "$rc"
    fi
    if pz_boot_grub_log_has_fatal_errors "$log"; then
        pz_error "GRUB config refresh reported errors log=$log_target"
        rm -f "$log"
        return 1
    fi
    if grep -Eiq '(^|[[:space:]])error:' "$log"; then
        pz_warn "GRUB config refresh ignored os-prober warning for unaddressable hybrid/removable media log=$log_target"
    fi
    rm -f "$log"
    pz_info "GRUB config refresh log: $log_target"
}

pz_boot_grub_log_has_fatal_errors() {
    local log="$1" line
    while IFS= read -r line; do
        grep -Eiq '(^|[[:space:]])error:' <<< "$line" || continue
        if [[ "$line" =~ ^grub-probe:\ error:\ cannot\ find\ a\ GRUB\ drive\ for\ /dev/[^.]+\.\ \ Check\ your\ device\.map\.$ ]]; then
            continue
        fi
        return 0
    done < "$log"
    return 1
}

pz_boot_validate_grub_cfg_safe() {
    local cfg="${1:-/boot/grub/grub.cfg}"
    [ -f "$cfg" ] || { pz_error "missing GRUB config: $cfg"; return 1; }
    if grep -Eq 'terminal_input console usb_keyboard at_keyboard|insmod at_keyboard|set gfxmode=800x600,640x480,auto' "$cfg"; then
        pz_error "unsafe global GRUB input/video settings detected in $cfg"
        return 1
    fi
}

pz_boot_grub_dquote() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    value="${value//\`/\\\`}"
    printf '"%s"' "$value"
}

pz_boot_valid_id() {
    [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
}

pz_boot_fs_module_for_fstype() {
    case "${1:-}" in
        btrfs) echo btrfs ;;
        ext2|ext3|ext4) echo ext2 ;;
        vfat|fat|fat16|fat32) echo fat ;;
        ntfs|ntfs3|fuseblk) echo ntfs ;;
        exfat) echo exfat ;;
        xfs) echo xfs ;;
        f2fs) echo f2fs ;;
        iso9660) echo iso9660 ;;
        *) return 1 ;;
    esac
}

pz_boot_grub_module_available() {
    local module="${1:-}" platform dir
    [ -n "$module" ] || return 1
    platform="${PZ_BOOT_GRUB_PLATFORM:-x86_64-efi}"
    for dir in "$(pz_boot_path /boot/grub)/$platform" "/usr/lib/grub/$platform"; do
        [ -f "$dir/$module.mod" ] && return 0
    done
    return 1
}

pz_boot_resolve_file_identity() {
    local path="${1:-}" real source uuid fstype grub_path module
    [ -f "$path" ] || { pz_error "file not found: $path"; return 1; }
    real="$(realpath -e -- "$path")"
    source="$(findmnt -no SOURCE -T "$real" 2>/dev/null | head -1 || true)"
    uuid="$(findmnt -no UUID -T "$real" 2>/dev/null | head -1 || true)"
    fstype="$(findmnt -no FSTYPE -T "$real" 2>/dev/null | head -1 || true)"
    if [ -z "$source" ] || [ -z "$uuid" ] || [ -z "$fstype" ]; then
        pz_error "could not resolve filesystem identity for: $real"
        return 1
    fi
    case "$fstype" in
        overlay|squashfs|fuse.*|nfs|nfs4|cifs|sshfs)
            pz_error "filesystem unavailable to GRUB: $fstype ($real)"
            return 1
            ;;
    esac
    module="$(pz_boot_fs_module_for_fstype "$fstype" 2>/dev/null || true)"
    [ -n "$module" ] || { pz_error "unsupported GRUB filesystem: $fstype"; return 1; }
    pz_boot_grub_module_available "$module" || {
        pz_error "GRUB module missing: $module.mod for $fstype"
        return 1
    }
    grub_path="$(grub-mkrelpath "$real" 2>/dev/null || true)"
    [ -n "$grub_path" ] || { pz_error "grub-mkrelpath failed: $real"; return 1; }
    jq -n \
        --arg hostPath "$real" \
        --arg source "$source" \
        --arg fsUuid "$uuid" \
        --arg fsType "$fstype" \
        --arg fsModule "$module" \
        --arg grubPath "$grub_path" \
        '{hostPath:$hostPath,source:$source,fsUuid:$fsUuid,fsType:$fsType,fsModule:$fsModule,grubPath:$grubPath}'
}

pz_boot_secure_boot_state() {
    local var byte
    if command -v mokutil >/dev/null 2>&1; then
        case "$(mokutil --sb-state 2>/dev/null || true)" in
            *enabled*) echo enabled; return 0 ;;
            *disabled*) echo disabled; return 0 ;;
        esac
    fi
    var="$(find /sys/firmware/efi/efivars -maxdepth 1 -type f -name 'SecureBoot-*' 2>/dev/null | head -1 || true)"
    if [ -r "$var" ]; then
        byte="$(od -An -t u1 -j 4 -N 1 "$var" 2>/dev/null | tr -d ' ' || true)"
        [ "$byte" = "1" ] && { echo enabled; return 0; }
        [ "$byte" = "0" ] && { echo disabled; return 0; }
    fi
    echo unknown
}

pz_boot_atomic_install() {
    local source="${1:-}" target="${2:-}" mode="${3:-0644}" dir tmp
    [ -f "$source" ] || { pz_error "atomic install source missing: $source"; return 1; }
    dir="$(dirname "$target")"
    install -d "$dir"
    tmp="$(mktemp "$dir/.phasezero.XXXXXX")"
    install -m "$mode" "$source" "$tmp"
    sync -f "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$target"
}

pz_boot_efi_has_dangerous_prefix() {
    local path="$1"
    [ -f "$path" ] || return 2
    strings -a "$path" |
        grep -Eq 'hd6,gpt2|\(,gpt[0-9]+\)/@/boot/grub|\(hd[0-9]+,gpt[0-9]+\)/@/boot/grub'
}

pz_boot_validate_efi_safe() {
    local path="$1"
    [ -f "$path" ] || { pz_error "missing EFI binary: $path"; return 1; }
    if pz_boot_efi_has_dangerous_prefix "$path"; then
        pz_error "dangerous disk-order GRUB prefix detected in $path"
        return 1
    fi
}

pz_boot_active_efi_path() {
    local esp boot_current line efi_rel candidate
    esp="$(pz_boot_esp_dir)"
    if command -v efibootmgr >/dev/null 2>&1; then
        boot_current="$(efibootmgr 2>/dev/null | awk '$1 == "BootCurrent:" {print $2; exit}' || true)"
        if [ -n "$boot_current" ]; then
            line="$(efibootmgr -v 2>/dev/null | awk -v entry="Boot${boot_current}" '$1 ~ "^" entry {print; exit}' || true)"
            if [[ "$line" =~ (\\EFI\\[^[:space:]]+\.efi) ]]; then
                efi_rel="${BASH_REMATCH[1]//\\//}"
                printf '%s/%s\n' "${esp%/}" "${efi_rel#/}"
                return 0
            fi
        fi
    fi
    for candidate in "$esp/EFI/BigLinux/grubx64.efi" "$esp/EFI/boot/bootx64.efi" "$esp/EFI/Boot/bootx64.efi"; do
        [ -e "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

pz_boot_efi_prefix_state() {
    local path="$1" state
    state="$(pz_boot_file_state "$path")"
    case "$state" in
        present)
            if pz_boot_efi_has_dangerous_prefix "$path"; then
                echo dangerous
            else
                echo safe
            fi
            ;;
        *) echo "$state" ;;
    esac
}

pz_boot_validate_active_efi_safe() {
    local path state
    path="$(pz_boot_active_efi_path 2>/dev/null || true)"
    if [ -z "$path" ]; then
        pz_warn "active EFI loader path not detected; skipping prefix validation"
        return 0
    fi
    state="$(pz_boot_efi_prefix_state "$path")"
    case "$state" in
        safe) return 0 ;;
        permission-denied)
            pz_warn "active EFI loader requires root/permission for prefix validation: $path"
            return 0
            ;;
        missing)
            pz_warn "active EFI loader path missing: $path"
            return 0
            ;;
        dangerous)
            pz_error "active EFI loader has dangerous disk-order GRUB prefix: $path"
            return 1
            ;;
        *)
            pz_warn "active EFI loader validation inconclusive: $state $path"
            return 0
            ;;
    esac
}

pz_rollback_register() {
    local action="$1" target="$2" backup="$3"
    local entry
    entry=$(jq -n \
        --arg action "$action" \
        --arg target "$target" \
        --arg backup "$backup" \
        --arg ts "$(date -Iseconds)" \
        '{action: $action, target: $target, backup: $backup, timestamp: $ts}')
    pz_state_init
    mkdir -p "$(dirname "$PZ_MANIFEST")"
    if [ -f "$PZ_MANIFEST" ]; then
        jq ". += [$entry]" "$PZ_MANIFEST" > "${PZ_MANIFEST}.tmp" && mv "${PZ_MANIFEST}.tmp" "$PZ_MANIFEST"
    else
        echo "[$entry]" > "$PZ_MANIFEST"
    fi

    # espelha no ledger unificado (o manifesto por operação continua sendo a
    # fonte do `pz_rollback` legado; o ledger é a fonte do wipe/uninstall)
    case "$action" in
        package)
            ledger_record --module "${PZ_MODULE:-common}" --action install-package \
                --package "pacman:$target" --scope system --reversible true \
                --rollback-cmd "pacman -Rns --noconfirm $(printf '%q' "$target")" ;;
        flatpak-package)
            ledger_record --module "${PZ_MODULE:-common}" --action install-package \
                --package "flatpak:$target" --scope user --reversible true \
                --rollback-cmd "flatpak --user uninstall -y $(printf '%q' "$target")" ;;
        flatpak-remote)
            ledger_record --module "${PZ_MODULE:-common}" --action add-flatpak-remote \
                --created "flatpak-remote:$target" --scope user --reversible true \
                --rollback-cmd "flatpak remote-delete $(printf '%q' "$target")" ;;
        service)
            ledger_record --module "${PZ_MODULE:-common}" --action enable-service \
                --service "system:$target" --scope system --reversible true \
                --rollback-cmd "systemctl disable --now $(printf '%q' "$target")" ;;
        file)
            ledger_record --module "${PZ_MODULE:-common}" --action modify-file \
                --modified "$target" ${backup:+--backup "$backup"} --scope user --reversible true ;;
    esac
}

pz_rollback() {
    if [ ! -f "$PZ_MANIFEST" ]; then
        pz_info "nothing to rollback"
        return 0
    fi
    local entries
    entries=$(jq -c 'reverse | .[]' "$PZ_MANIFEST")
    echo "$entries" | while read -r entry; do
        local action target backup
        action=$(echo "$entry" | jq -r '.action')
        target=$(echo "$entry" | jq -r '.target')
        backup=$(echo "$entry" | jq -r '.backup')
        case "$action" in
            file) cp "$backup" "$target" && pz_info "restored $target from $backup" ;;
            package) pz_info "rollback package $target: manual reinstall may be needed" ;;
            flatpak-package) flatpak --user uninstall -y "$target" 2>/dev/null || true ;;
            service) systemctl disable --now "$target" 2>/dev/null || true ;;
            flatpak-remote)
                if command -v flatpak >/dev/null 2>&1; then
                    flatpak remote-delete "$target" 2>/dev/null || true
                fi
                ;;
        esac
    done
    rm -f "$PZ_MANIFEST"
    pz_info "rollback complete"
}

pz_run_profile() {
    local profile_file="$1"
    local profile_real profile_dir profile_name parent parent_file call_depth active_before
    if [ ! -f "$profile_file" ]; then
        pz_error "profile not found: $profile_file"
        return 1
    fi
    command -v jq >/dev/null 2>&1 || { pz_error "jq is required to read profiles"; return 69; }
    if ! jq -e 'type == "object" and (.name | type == "string" and length > 0)' "$profile_file" >/dev/null 2>&1; then
        pz_error "invalid profile JSON or missing name: $profile_file"
        return 2
    fi
    if ! jq -e '
        ((.extends // []) | type == "array") and
        ((.packages.linux.pacman // []) | type == "array") and
        ((.packages.linux.archRepos // []) | type == "array") and
        ((.packages.linux.yay // []) | type == "array") and
        ((.packages.linux.optionalPacman // []) | type == "array") and
        ((.packages.linux.optionalYay // []) | type == "array") and
        (((.packages.linux.flatpak // []) | type) as $t | $t == "array" or $t == "object") and
        ((.scripts.linux // []) | type == "array") and
        ((.docker_compose // {}) | type == "object") and
        (((.docker_compose.core // "") | type) as $t | $t == "string") and
        (((.docker_compose.extras // "") | type) as $t | $t == "string") and
        (((.docker_compose.with_extras // false) | type) as $t | $t == "boolean") and
        ((.systemd.linux.enable // []) | type == "array") and
        ((.systemd.linux.user // []) | type == "array") and
        ((.tuning.linux.sysctl // {}) | type == "object") and
        (((.packages.linux.pacman // []) + (.packages.linux.yay // [])) as $all |
            ($all | length) == ($all | unique | length))
    ' "$profile_file" >/dev/null 2>&1; then
        pz_error "invalid Linux profile field type: $profile_file"
        return 2
    fi
    if ! jq -e '(.os // ["linux"]) | type == "array" and index("linux") != null' "$profile_file" >/dev/null 2>&1; then
        pz_error "profile does not support Linux: $profile_file"
        return 2
    fi

    profile_real="$(realpath -e "$profile_file" 2>/dev/null || printf '%s' "$profile_file")"
    profile_dir="$(dirname "$profile_real")"
    profile_name="$(jq -r '.name' "$profile_file")"
    call_depth="${PZ_PROFILE_CALL_DEPTH:-0}"
    if [ "$call_depth" -eq 0 ]; then
        PZ_PROFILE_VISITED='|'
        PZ_PROFILE_ACTIVE='|'
    fi
    active_before="${PZ_PROFILE_ACTIVE:-|}"
    case "$active_before" in
        *"|$profile_real|"*)
            pz_error "profile inheritance cycle detected at: $profile_name"
            return 2
            ;;
    esac
    case "${PZ_PROFILE_VISITED:-|}" in
        *"|$profile_real|"*)
            pz_info "profile already applied in composition: $profile_name"
            return 0
            ;;
    esac
    PZ_PROFILE_VISITED="${PZ_PROFILE_VISITED:-|}${profile_real}|"
    PZ_PROFILE_ACTIVE="${active_before}${profile_real}|"
    PZ_PROFILE_CALL_DEPTH=$((call_depth + 1))

    while IFS= read -r parent; do
        [ -n "$parent" ] || continue
        if [[ ! "$parent" =~ ^[A-Za-z0-9._-]+$ ]]; then
            pz_error "invalid parent profile name in $profile_name: $parent"
            PZ_PROFILE_CALL_DEPTH="$call_depth"
            PZ_PROFILE_ACTIVE="$active_before"
            return 2
        fi
        parent_file="$profile_dir/$parent.json"
        if [ ! -f "$parent_file" ]; then
            pz_error "parent profile not found: $parent_file"
            PZ_PROFILE_CALL_DEPTH="$call_depth"
            PZ_PROFILE_ACTIVE="$active_before"
            return 1
        fi
        pz_info "profile $profile_name extends $parent"
        pz_run_profile "$parent_file" || {
            PZ_PROFILE_CALL_DEPTH="$call_depth"
            PZ_PROFILE_ACTIVE="$active_before"
            return 1
        }
    done < <(jq -er '(.extends // []) | if type == "array" then .[] else error("extends must be an array") end' "$profile_file")

    local dry_run="${PZ_DRY_RUN:-0}"
    local arch_repos
    arch_repos=$(jq -r '.packages.linux.archRepos // [] | .[]' "$profile_file" 2>/dev/null || true)
    if [ -n "$arch_repos" ]; then
        # PZ-AUD-027: clean Arch ships [multilib] commented out; lib32/steam
        # packages cannot resolve without it. Enabling a repo is explicit,
        # admin-gated and dry-run visible — never silent.
        local repo
        while IFS= read -r repo; do
            [ -z "$repo" ] && continue
            case "$repo" in
                multilib) ;;
                *) pz_error "unsupported arch repo: $repo"; return 2 ;;
            esac
            if grep -Eq '^\[multilib\]' /etc/pacman.conf 2>/dev/null; then
                [ "$dry_run" = "1" ] && pz_info "repo [$repo] already enabled"
                continue
            fi
            if [ "$dry_run" = "1" ]; then
                pz_info "would enable [$repo] in /etc/pacman.conf and refresh databases"
                continue
            fi
            pz_info "enabling [$repo] repository..."
            if grep -Eq '^#\[multilib\]' /etc/pacman.conf 2>/dev/null; then
                pz_admin_run sed -i '/^#\[multilib\]/,/^#Include/s/^#//' /etc/pacman.conf || {
                    pz_error "could not enable [$repo] (admin bridge needed)"
                    return "$PZ_RC_NO_ADMIN"
                }
            else
                # Minimal images ship no [multilib] block at all: append it.
                pz_admin_run bash -c 'printf "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" >> /etc/pacman.conf' || {
                    pz_error "could not enable [$repo] (admin bridge needed)"
                    return "$PZ_RC_NO_ADMIN"
                }
            fi
            grep -Eq '^\[multilib\]' /etc/pacman.conf || {
                pz_error "[$repo] section still disabled after edit"
                return 1
            }
            pz_admin_run pacman -Sy || {
                pz_error "database refresh failed after enabling [$repo]"
                return 1
            }
        done <<< "$arch_repos"
    fi
    local packages
    packages=$(jq -r '.packages.linux.pacman // [] | .[]' "$profile_file" 2>/dev/null || true)
    local yay_pkgs
    yay_pkgs=$(jq -r '.packages.linux.yay // [] | .[]' "$profile_file" 2>/dev/null || true)
    local opt_pacman opt_yay
    opt_pacman=$(jq -r '.packages.linux.optionalPacman // [] | .[]' "$profile_file" 2>/dev/null || true)
    opt_yay=$(jq -r '.packages.linux.optionalYay // [] | .[]' "$profile_file" 2>/dev/null || true)
    local flatpak_pkgs
    flatpak_pkgs=$(jq -r '
      if .packages.linux.flatpak | type == "object"
      then .packages.linux.flatpak.packages // [] | .[]
      else .packages.linux.flatpak // [] | .[]
      end
    ' "$profile_file" 2>/dev/null || true)
    local flatpak_raw
    flatpak_raw=$(jq -r '.packages.linux.flatpak // empty' "$profile_file" 2>/dev/null || true)
    local flatpak_is_object=false
    if [ -n "$flatpak_raw" ]; then
        echo "$flatpak_raw" | jq -e '. | type == "object"' >/dev/null 2>&1 && flatpak_is_object=true
    fi
    local scripts
    scripts=$(jq -r '.scripts.linux // [] | .[]' "$profile_file" 2>/dev/null || true)
    local compose_core compose_extras compose_with_extras
    compose_core=$(jq -r '.docker_compose.core // empty' "$profile_file" 2>/dev/null || true)
    compose_extras=$(jq -r '.docker_compose.extras // empty' "$profile_file" 2>/dev/null || true)
    compose_with_extras=$(jq -r '.docker_compose.with_extras // false' "$profile_file" 2>/dev/null || true)
    local system_services
    system_services=$(jq -r '.systemd.linux.enable // [] | .[]' "$profile_file" 2>/dev/null || true)
    local user_services
    user_services=$(jq -r '.systemd.linux.user // [] | .[]' "$profile_file" 2>/dev/null || true)
    local sysctl_entries
    sysctl_entries=$(jq -r '.tuning.linux.sysctl // {} | to_entries[] | "\(.key)=\(.value)"' "$profile_file" 2>/dev/null || true)

    if [ "$dry_run" != "1" ] && { [ -n "$packages" ] || [ -n "$yay_pkgs" ] || [ -n "$system_services" ] || [ -n "$sysctl_entries" ]; }; then
        if [ "$EUID" -ne 0 ] && ! pz_admin_available; then
            pz_error "profile '$profile_name' needs privileged steps but no admin bridge is ready"
            pz_admin_howtofix
            return "$PZ_RC_NO_ADMIN"
        fi
    fi
    if [ "$dry_run" != "1" ]; then
        command -v pacman >/dev/null 2>&1 || {
            pz_error "legacy profile '$profile_name' requires an Arch/pacman host; use 'pz capabilities' on other distributions"
            return 69
        }
        local missing_packages=() pkg
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            pacman -Q "$pkg" >/dev/null 2>&1 || pacman -Si "$pkg" >/dev/null 2>&1 || missing_packages+=("pacman:$pkg")
        done <<< "$packages"
        if [ -n "$yay_pkgs" ]; then
            command -v yay >/dev/null 2>&1 || missing_packages+=("tool:yay")
            if command -v yay >/dev/null 2>&1; then
                while IFS= read -r pkg; do
                    [ -z "$pkg" ] && continue
                    pacman -Q "$pkg" >/dev/null 2>&1 || yay -Si "$pkg" >/dev/null 2>&1 || missing_packages+=("yay:$pkg")
                done <<< "$yay_pkgs"
            fi
        fi
        if [ "${#missing_packages[@]}" -gt 0 ]; then
            pz_error "profile preflight failed before mutation: ${missing_packages[*]}"
            return 69
        fi
        if [ -n "$opt_pacman" ]; then
            local opt_pkg
            while IFS= read -r opt_pkg; do
                [ -z "$opt_pkg" ] && continue
                pacman -Q "$opt_pkg" >/dev/null 2>&1 || pacman -Si "$opt_pkg" >/dev/null 2>&1 ||                     pz_warn "optional package unavailable, will skip: $opt_pkg"
            done <<< "$opt_pacman"
        fi
    fi

    if [ -n "$packages" ]; then
        if [ "$dry_run" = "1" ]; then
            pz_info "planning pacman packages..."
        else
            pz_info "installing pacman packages..."
        fi
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would install pacman package: $pkg"
                continue
            fi
            local package_preexisting=0
            pacman -Q "$pkg" >/dev/null 2>&1 && package_preexisting=1
            pz_admin_run pacman -S --needed --noconfirm "$pkg"
            [ "$package_preexisting" = "1" ] || pz_rollback_register package "$pkg" ""
        done <<< "$packages"
    fi

    if [ -n "$yay_pkgs" ]; then
        if [ "$dry_run" = "1" ]; then
            pz_info "planning AUR packages..."
        else
            pz_info "installing AUR packages..."
        fi
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would install AUR package: $pkg"
                continue
            fi
            local package_preexisting=0
            pacman -Q "$pkg" >/dev/null 2>&1 && package_preexisting=1
            yay -S --needed --noconfirm "$pkg"
            [ "$package_preexisting" = "1" ] || pz_rollback_register package "$pkg" ""
        done <<< "$yay_pkgs"
    fi

    if [ -n "$opt_pacman" ] || [ -n "$opt_yay" ]; then
        if [ "$dry_run" = "1" ]; then
            pz_info "planning optional packages (best effort)..."
        else
            pz_info "installing optional packages (best effort)..."
        fi
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would try optional pacman package: $pkg"
                continue
            fi
            if ! pacman -Q "$pkg" >/dev/null 2>&1 && ! pacman -Si "$pkg" >/dev/null 2>&1; then
                pz_warn "optional package unavailable, skipped: $pkg"
                continue
            fi
            pz_admin_run pacman -S --needed --noconfirm "$pkg" ||                 pz_warn "optional package failed, skipped: $pkg"
        done <<< "$opt_pacman"
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would try optional AUR package: $pkg"
                continue
            fi
            if ! command -v yay >/dev/null 2>&1; then
                pz_warn "yay unavailable, optional AUR package skipped: $pkg"
                continue
            fi
            if ! pacman -Q "$pkg" >/dev/null 2>&1 && ! yay -Si "$pkg" >/dev/null 2>&1; then
                pz_warn "optional AUR package unavailable, skipped: $pkg"
                continue
            fi
            yay -S --needed --noconfirm "$pkg" ||                 pz_warn "optional AUR package failed, skipped: $pkg"
        done <<< "$opt_yay"
    fi

    if [ "$flatpak_is_object" = true ]; then
        source "$PZ_ROOT/linux/lib/flatpak.sh"
        PZ_DRY_RUN="$dry_run" pz_flatpak_setup_from_profile "$profile_file"
    fi

    if [ -n "$flatpak_pkgs" ]; then
        if [ "$dry_run" = "1" ]; then
            pz_info "planning flatpak packages..."
        else
            pz_info "installing flatpak packages..."
        fi
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would install flatpak package: $pkg"
                continue
            fi
            local remote_name="flathub"
            if [ "$flatpak_is_object" = true ]; then
                remote_name=$(jq -r '.packages.linux.flatpak.remotes[0].name // "flathub"' "$profile_file" 2>/dev/null || echo "flathub")
            fi
            local flatpak_preexisting=0
            flatpak --user info "$pkg" >/dev/null 2>&1 && flatpak_preexisting=1
            flatpak --user install -y "$remote_name" "$pkg"
            [ "$flatpak_preexisting" = "1" ] || pz_rollback_register flatpak-package "$pkg" ""
        done <<< "$flatpak_pkgs"
    fi

    if [ -n "$system_services" ]; then
        if [ "$dry_run" = "1" ]; then
            pz_info "planning system services..."
        else
            pz_info "enabling system services..."
        fi
        while IFS= read -r service; do
            [ -z "$service" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would enable system service: $service"
                continue
            fi
            pz_admin_run systemctl enable --now "$service" || {
                pz_error "failed to enable system service: $service"
                PZ_PROFILE_CALL_DEPTH="$call_depth"
                PZ_PROFILE_ACTIVE="$active_before"
                return 1
            }
            systemctl is-active --quiet "$service" || {
                pz_error "system service not active after enable: $service"
                PZ_PROFILE_CALL_DEPTH="$call_depth"
                PZ_PROFILE_ACTIVE="$active_before"
                return 1
            }
        done <<< "$system_services"
    fi

    if [ -n "$user_services" ]; then
        if [ "$dry_run" = "1" ]; then
            pz_info "planning user services..."
        else
            pz_info "enabling user services..."
        fi
        while IFS= read -r service; do
            [ -z "$service" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would enable user service: $service"
                continue
            fi
            systemctl --user enable --now "$service" || {
                pz_error "failed to enable user service: $service"
                PZ_PROFILE_CALL_DEPTH="$call_depth"
                PZ_PROFILE_ACTIVE="$active_before"
                return 1
            }
        done <<< "$user_services"
    fi

    if [ -n "$sysctl_entries" ]; then
        if [ "$dry_run" = "1" ]; then
            pz_info "planning sysctl tuning..."
        else
            pz_info "applying sysctl tuning..."
        fi
        while IFS= read -r entry; do
            [ -z "$entry" ] && continue
            if [ "$dry_run" = "1" ]; then
                pz_info "would set sysctl: $entry"
                continue
            fi
            pz_admin_run sysctl -w "$entry" || {
                pz_error "failed to apply sysctl: $entry"
                PZ_PROFILE_CALL_DEPTH="$call_depth"
                PZ_PROFILE_ACTIVE="$active_before"
                return 1
            }
        done <<< "$sysctl_entries"
    fi

    if [ -n "$compose_core" ] || [ -n "$compose_extras" ]; then
        # PZ-AUD-004: docker_compose is executable selection, not decoration.
        # Registry present -> reconcile the curated set; otherwise legacy
        # layer up from the declared files (extras only on explicit opt-in).
        if [ -n "$compose_core" ] && [ ! -f "$PZ_ROOT/$compose_core" ]; then
            pz_error "profile declares missing compose core: $compose_core"
            PZ_PROFILE_CALL_DEPTH="$call_depth"
            PZ_PROFILE_ACTIVE="$active_before"
            return 1
        fi
        local -a compose_args=()
        if [ -f "${PZ_HOMELAB_STATE:-$PZ_STATE/homelab}/apps.enabled.json" ]; then
            compose_args=(reconcile)
        elif [ "$compose_with_extras" = "true" ]; then
            compose_args=(up --extras)
        else
            compose_args=(up)
        fi
        if [ "$dry_run" = "1" ]; then
            pz_info "would converge declared compose: ${compose_args[*]} (core=$compose_core extras=$compose_extras)"
        else
            pz_info "converging declared compose: ${compose_args[*]}"
            bash "$PZ_ROOT/linux/server/homelab-stack.sh" "${compose_args[@]}" || {
                pz_error "declared compose failed to converge for profile: $profile_name"
                PZ_PROFILE_CALL_DEPTH="$call_depth"
                PZ_PROFILE_ACTIVE="$active_before"
                return 1
            }
        fi
    fi

    if [ -n "$scripts" ]; then
        if [ "$dry_run" = "1" ]; then
            pz_info "planning setup scripts..."
        else
            pz_info "running setup scripts..."
        fi
        while IFS= read -r script; do
            [ -z "$script" ] && continue
            if [[ "$script" = /* || "/$script/" = *"/../"* ]]; then
                pz_error "unsafe profile script path rejected: $script"
                PZ_PROFILE_CALL_DEPTH="$call_depth"
                PZ_PROFILE_ACTIVE="$active_before"
                return 2
            fi
            local script_path
            script_path="$(realpath -m "$PZ_ROOT/$script" 2>/dev/null || printf '%s/%s' "$PZ_ROOT" "$script")"
            case "$script_path" in
                "$PZ_ROOT"/*) ;;
                *)
                    pz_error "profile script escapes project root: $script"
                    PZ_PROFILE_CALL_DEPTH="$call_depth"
                    PZ_PROFILE_ACTIVE="$active_before"
                    return 2
                    ;;
            esac
            if [ -f "$script_path" ]; then
                if [ "$dry_run" = "1" ]; then
                    pz_info "would execute $script_path"
                    continue
                fi
                pz_info "executing $script_path"
                bash "$script_path" || {
                    pz_error "profile script failed: $script"
                    PZ_PROFILE_CALL_DEPTH="$call_depth"
                    PZ_PROFILE_ACTIVE="$active_before"
                    return 1
                }
            else
                pz_error "profile script missing: $script_path"
                PZ_PROFILE_CALL_DEPTH="$call_depth"
                PZ_PROFILE_ACTIVE="$active_before"
                return 1
            fi
        done <<< "$scripts"
    fi

    pz_info "profile $profile_file complete"
    PZ_PROFILE_CALL_DEPTH="$call_depth"
    PZ_PROFILE_ACTIVE="$active_before"
}

# Lançadores .desktop: agrupamento no menu + anti-duplicação. Carregado no
# FIM porque depende de pz_write_managed_file/pz_state_init acima.
# shellcheck source=linux/lib/desktop.sh
source "$PZ_ROOT/linux/lib/desktop.sh"

pz_boot_detect_loader() {
    local esp
    if [ -d /sys/firmware/efi ]; then
        if command -v bootctl >/dev/null 2>&1 && bootctl status 2>/dev/null | grep -q 'systemd-boot'; then
            echo systemd-boot
            return 0
        fi
        if [ -d "$(pz_boot_esp_dir)/EFI/refind" ] || [ -d "$(pz_boot_esp_dir)/EFI/REFIND" ]; then
            echo refind
            return 0
        fi
        if [ -f /boot/EFI/refind/refind_x64.efi ] || [ -f /efi/EFI/refind/refind_x64.efi ]; then
            echo refind
            return 0
        fi
        if [ -x /sbin/grub-mkconfig ] || [ -d /etc/grub.d ]; then
            echo grub-efi
            return 0
        fi
        echo efi-stub
        return 0
    fi
    if [ -x /sbin/grub-mkconfig ] || [ -d /etc/grub.d ]; then
        echo grub-bios
        return 0
    fi
    echo unknown
}

pz_boot_systemd_boot_oneshot_entry() {
    local entry_id="${1:-}" kernel="${2:-}" initrd="${3:-}" cmdline="${4:-}" esp loader_dir
    esp="$(pz_boot_esp_dir)"
    loader_dir="$esp/loader/entries"
    install -d "$loader_dir"
    {
        printf 'title PhaseZero Windows VM\n'
        printf 'sort-key phasezero-windows-vm\n'
        printf 'linux /%s\n' "${kernel#/}"
        printf 'initrd /%s\n' "${initrd#/}"
        printf 'options %s\n' "$cmdline phasezero.windowsvm=1"
    } > "$loader_dir/$entry_id.conf"
    printf '%s\n' "$loader_dir/$entry_id.conf"
}

pz_boot_systemd_boot_set_oneshot() {
    local entry_id="${1:-}" esp conf
    esp="$(pz_boot_esp_dir)"
    pz_boot_atomic_install "$esp/loader/entries/$entry_id.conf" "$esp/loader/entries/$entry_id.conf"
    if command -v bootctl >/dev/null 2>&1; then
        bootctl set-oneshot "$entry_id" 2>/dev/null || bootctl set-oneshot "$entry_id.conf" 2>/dev/null || pz_warn "bootctl set-oneshot failed for $entry_id"
    elif command -v efibootmgr >/dev/null 2>&1; then
        pz_warn "bootctl not available; cannot set systemd-boot oneshot via bootctl"
    fi
    pz_info "systemd-boot oneshot entry: $entry_id"
}

pz_boot_systemd_boot_remove_entry() {
    local entry_id="${1:-}" esp
    esp="$(pz_boot_esp_dir)"
    rm -f "$esp/loader/entries/$entry_id.conf" 2>/dev/null || true
    pz_info "systemd-boot entry removed: $entry_id"
}

pz_boot_refind_install_stanza() {
    local entry_id="${1:-}" kernel="${2:-}" initrd="${3:-}" cmdline="${4:-}" esp refind_entries conf
    esp="$(pz_boot_esp_dir)"
    refind_entries="$esp/EFI/refind/entries"
    install -d "$refind_entries" 2>/dev/null || refind_entries="/boot/EFI/refind/entries"
    install -d "$refind_entries"
    conf="$refind_entries/$entry_id.conf"
    {
        printf 'menuentry "PhaseZero Windows VM" {\n'
        printf '    icon /EFI/refind/icons/os_linux.png\n'
        printf '    volume %s\n' "$(findmnt -no UUID -T "$(pz_boot_target_root)" 2>/dev/null | head -1)"
        printf '    loader /%s\n' "${kernel#/}"
        printf '    initrd /%s\n' "${initrd#/}"
        printf '    options "%s phasezero.windowsvm=1"\n' "$cmdline"
        printf '}\n'
    } > "$conf"
    pz_info "rEFInd stanza written: $conf"
}

pz_boot_refind_remove_stanza() {
    local entry_id="${1:-}" esp
    for d in "$esp/EFI/refind/entries" "/boot/EFI/refind/entries"; do
        rm -f "$d/$entry_id.conf" 2>/dev/null || true
    done
    pz_info "rEFInd stanza removed: $entry_id"
}

pz_boot_efi_stub_entry() {
    local entry_id="${1:-}" kernel="${2:-}" initrd="${3:-}" cmdline="${4:-}" esp label
    esp="$(pz_boot_esp_dir)"
    label="PhaseZero Windows VM"
    if command -v efibootmgr >/dev/null 2>&1; then
        efibootmgr -c \
            -L "$label" \
            -l "\\EFI\\$(basename "$(dirname "$kernel")")\\$(basename "$kernel")" \
            -u "initrd=\\$(basename "$initrd") $cmdline phasezero.windowsvm=1" \
            2>/dev/null || pz_warn "efibootmgr failed to create NVRAM entry for $entry_id (SecureBoot may block this)"
        return
    fi
    pz_warn "efibootmgr not available; cannot create EFI stub NVRAM entry for $entry_id"
}

pz_boot_efi_stub_remove() {
    local entry_id="${1:-}"
    if command -v efibootmgr >/dev/null 2>&1; then
        efibootmgr -B -L "PhaseZero Windows VM" 2>/dev/null || true
    fi
    pz_info "EFI stub NVRAM entry removed"
}

# pz_path_resolve <name> [paths...]
# Retorna primeiro path (arquivo ou diretório) existente, ou vazio.
# Exemplo:
#   OVMF_CODE="$(pz_path_resolve ovmf_code \
#       /usr/share/edk2/x64/OVMF_CODE.4m.fd \
#       /usr/share/edk2-ovmf/OVMF_CODE.fd \
#       /usr/share/OVMF/OVMF_CODE.fd)" || true
pz_path_resolve() {
    local name="$1" p
    shift
    [ $# -eq 0 ] && { pz_warn "pz_path_resolve($name): no paths given"; return 1; }
    for p in "$@"; do
        [ -e "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

# Resolve o usuário humano alvo sem nome fixo no código (CCS-038).
# Ordem: variável explícita -> SUDO_USER -> logname -> UID 1000 -> $USER.
pz_resolve_target_user() {
    local candidate="${1:-}"
    if [ -z "$candidate" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        candidate="$SUDO_USER"
    fi
    if [ -z "$candidate" ] || [ "$candidate" = "root" ]; then
        local login_user
        login_user="$(logname 2>/dev/null || true)"
        if [ -n "$login_user" ] && [ "$login_user" != "root" ]; then
            candidate="$login_user"
        fi
    fi
    if [ -z "$candidate" ] || [ "$candidate" = "root" ]; then
        candidate="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
    fi
    if [ -z "$candidate" ]; then
        candidate="${USER:-}"
    fi
    [ "$candidate" != "root" ] && printf '%s\n' "$candidate" || printf '%s\n' ""
}
