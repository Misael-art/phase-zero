#!/usr/bin/env bash
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-plan}"
shift || true
INCLUDE_CREDENTIALS=false
PASSPHRASE_STDIN=false
BUNDLE=""
OUTPUT=""
CONFIRM=""
PLAN=false
AI_MEMORY_BIN="${AI_MEMORY_BIN:-$(command -v ai-memory 2>/dev/null || true)}"
AI_MEMORY_DATA_DIR="${AI_MEMORY_DATA_DIR:-$HOME/.local/share/ai-memory}"
AI_MEMORY_CONFIG="${AI_MEMORY_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ai-memory/config.toml}"
BACKUP_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/ai-portability"
DEFAULT_OUTPUT="${XDG_DOCUMENTS_DIR:-$HOME/Documents}/PhaseZero/Backups/phasezero-ai-$(date +%Y%m%d-%H%M%S).tar.gz.gpg"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --include-credentials) INCLUDE_CREDENTIALS=true ;;
        --passphrase-stdin) PASSPHRASE_STDIN=true ;;
        --bundle) shift; BUNDLE="${1:-}" ;;
        --output) shift; OUTPUT="${1:-}" ;;
        --confirm) shift; CONFIRM="${1:-}" ;;
        --plan) PLAN=true ;;
        *) pz_error "unknown option: $1"; exit 2 ;;
    esac
    shift
done

credential_candidates() {
    local file dir
    dir="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai-proxies"
    if [ -d "$dir" ]; then
        while IFS= read -r -d '' file; do printf '%s\0' "$file"; done \
            < <(find "$dir" -maxdepth 1 -type f -name '*.env' -print0 | sort -z)
    fi
    for file in \
        "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai-providers/mimo/api-key" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai/hermes.env" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json" \
        "$HOME/.codex/auth.json" \
        "$HOME/.claude/.credentials.json" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/ai.z.zcode/store.json"; do
        [ -f "$file" ] && [ ! -L "$file" ] && printf '%s\0' "$file"
    done
}

read_passphrase() {
    $PASSPHRASE_STDIN || { pz_error "--passphrase-stdin required"; return 2; }
    IFS= read -r PASSPHRASE || true
    [ "${#PASSPHRASE}" -ge 12 ] || { pz_error "passphrase must have at least 12 characters"; return 2; }
}

safe_output() {
    local path="$1" parent
    [ -n "$path" ] && [ "$path" != / ] && [ "$path" != "$HOME" ] || return 1
    [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
    parent="$(dirname "$path")"
    install -d -m 700 "$parent"
    [ ! -L "$parent" ] || return 1
}

plan_json() {
    local count=0 path paths='[]'
    if $INCLUDE_CREDENTIALS; then
        while IFS= read -r -d '' path; do
            paths="$(jq -c --arg path "$path" '. + [$path]' <<< "$paths")"
            count=$((count + 1))
        done < <(credential_candidates)
    fi
    jq -nc --arg output "${OUTPUT:-$DEFAULT_OUTPUT}" --argjson credentials "$INCLUDE_CREDENTIALS" \
        --argjson count "$count" --argjson paths "$paths" '
      {schemaVersion:1,ok:true,status:"planned",encrypted:true,cipher:"OpenPGP AES-256",
       memory:{included:true,method:"ai-memory backup"},
       credentials:{included:$credentials,count:$count,paths:$paths},
       exclusions:["browser profiles","cookies","Playwright sessions","unlisted home files"],
       output:$output,next:"Confirme e informe uma senha de pelo menos 12 caracteres. Guarde a senha fora do host."}'
}

add_manifest_item() {
    local rows="$1" source="$2" relative="$3" category="$4"
    jq -nc --arg path "$relative" --arg category "$category" \
        --arg sha256 "$(sha256sum "$source" | awk '{print $1}')" \
        --arg mode "$(stat -c '%a' "$source")" \
        '{path:$path,category:$category,sha256:$sha256,mode:$mode}' >> "$rows"
}

memory_backup_to() {
    "$AI_MEMORY_BIN" backup --data-dir "$AI_MEMORY_DATA_DIR" --config "$AI_MEMORY_CONFIG" --to "$1"
}

memory_restore_from() {
    "$AI_MEMORY_BIN" restore --data-dir "$AI_MEMORY_DATA_DIR" --config "$AI_MEMORY_CONFIG" --from "$1" --force
}

create_bundle() {
    local destination temp stage rows path rel inner
    command -v gpg >/dev/null 2>&1 || { pz_error "gpg missing"; return 1; }
    if [ -z "$AI_MEMORY_BIN" ] || [ ! -x "$AI_MEMORY_BIN" ]; then
        pz_error "ai-memory missing"
        return 1
    fi
    read_passphrase
    destination="${OUTPUT:-$DEFAULT_OUTPUT}"
    safe_output "$destination" || { pz_error "unsafe or existing output path"; return 2; }
    temp="$(mktemp -d)"
    chmod 700 "$temp"
    trap 'rm -rf -- "$temp"; unset PASSPHRASE' RETURN
    stage="$temp/stage"
    rows="$temp/items.jsonl"
    install -d -m 700 "$stage/payload"
    : > "$rows"

    memory_backup_to "$stage/payload/ai-memory.tar.gz" >/dev/null
    [ -s "$stage/payload/ai-memory.tar.gz" ] || { pz_error "ai-memory backup produced no archive"; return 1; }
    add_manifest_item "$rows" "$stage/payload/ai-memory.tar.gz" payload/ai-memory.tar.gz memory

    if $INCLUDE_CREDENTIALS; then
        while IFS= read -r -d '' path; do
            case "$path" in "$HOME"/*) rel="${path#"$HOME"/}" ;; *) pz_error "credential outside HOME refused"; return 2 ;; esac
            [[ "$rel" != *..* ]] || { pz_error "unsafe credential path refused"; return 2; }
            install -d -m 700 "$stage/payload/home/$(dirname "$rel")"
            install -m "$(stat -c '%a' "$path")" "$path" "$stage/payload/home/$rel"
            add_manifest_item "$rows" "$stage/payload/home/$rel" "payload/home/$rel" credential
        done < <(credential_candidates)
    fi

    jq -s --arg createdAt "$(date -Iseconds)" --arg host "$(hostname)" \
        '{schemaVersion:1,format:"phasezero-ai-portability/v1",createdAt:$createdAt,sourceHost:$host,items:.}' \
        "$rows" > "$stage/manifest.json"
    inner="$temp/phasezero-ai.tar.gz"
    tar -C "$stage" -czf "$inner" manifest.json payload
    printf '%s' "$PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
        --symmetric --cipher-algo AES256 --s2k-mode 3 --s2k-digest-algo SHA512 \
        --s2k-count 65011712 --output "$destination" "$inner"
    chmod 600 "$destination"
    unset PASSPHRASE
    trap - RETURN
    rm -rf -- "$temp"
    jq -nc --arg bundle "$destination" --arg sha256 "$(sha256sum "$destination" | awk '{print $1}')" \
        '{schemaVersion:1,ok:true,status:"created",encrypted:true,bundle:$bundle,sha256:$sha256,
          next:"Copie este arquivo para mídia externa e use Verificar backup antes de reinstalar."}'
}

decrypt_and_verify() {
    local bundle="$1" temp="$2" entry expected actual
    local inner="$temp/phasezero-ai.tar.gz"
    if [ ! -f "$bundle" ] || [ -L "$bundle" ]; then
        pz_error "bundle not found or symlink refused"
        return 2
    fi
    printf '%s' "$PASSPHRASE" | gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 0 \
        --decrypt --output "$inner" "$bundle" || { pz_error "wrong passphrase or damaged bundle"; return 3; }
    tar -tzf "$inner" | awk '/^\// || /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' || {
        pz_error "unsafe archive path"; return 4;
    }
    install -d -m 700 "$temp/extracted"
    tar -C "$temp/extracted" -xzf "$inner"
    jq -e '.schemaVersion == 1 and .format == "phasezero-ai-portability/v1" and (.items|type=="array")' \
        "$temp/extracted/manifest.json" >/dev/null || { pz_error "invalid manifest"; return 4; }
    while IFS=$'\t' read -r entry expected; do
        case "$entry" in payload/*) ;; *) pz_error "manifest path refused"; return 4 ;; esac
        [ -f "$temp/extracted/$entry" ] && [ ! -L "$temp/extracted/$entry" ] || return 4
        actual="$(sha256sum "$temp/extracted/$entry" | awk '{print $1}')"
        [ "$actual" = "$expected" ] || { pz_error "checksum mismatch: $entry"; return 4; }
    done < <(jq -r '.items[] | [.path,.sha256] | @tsv' "$temp/extracted/manifest.json")
}

verify_bundle() {
    local temp
    [ -n "$BUNDLE" ] || { pz_error "--bundle required"; return 2; }
    read_passphrase
    temp="$(mktemp -d)"; chmod 700 "$temp"
    trap 'rm -rf -- "$temp"; unset PASSPHRASE' RETURN
    decrypt_and_verify "$BUNDLE" "$temp"
    unset PASSPHRASE
    jq -nc --arg bundle "$BUNDLE" \
        --argjson items "$(jq '.items|length' "$temp/extracted/manifest.json")" \
        '{schemaVersion:1,ok:true,status:"verified",bundle:$bundle,items:$items,next:"O pacote está íntegro. Use Restaurar backup para revisar o plano."}'
}

restore_bundle() {
    local temp manifest path category rel target mode rollback memory_previous="" failed=false
    [ -n "$BUNDLE" ] || { pz_error "--bundle required"; return 2; }
    if [ -z "$AI_MEMORY_BIN" ] || [ ! -x "$AI_MEMORY_BIN" ]; then
        pz_error "ai-memory missing"
        return 1
    fi
    read_passphrase
    temp="$(mktemp -d)"; chmod 700 "$temp"
    trap 'rm -rf -- "$temp"; unset PASSPHRASE' RETURN
    decrypt_and_verify "$BUNDLE" "$temp"
    manifest="$temp/extracted/manifest.json"
    if $PLAN; then
        jq -c --arg home "$HOME" '
          {schemaVersion:1,ok:true,status:"restore-planned",verified:true,
           memory:{action:"restore through ai-memory",preBackup:true},
           files:[.items[] | select(.category=="credential") |
             {source:.path,target:($home + "/" + (.path|sub("^payload/home/";""))),mode:.mode}],
           next:"Confirme a restauração. Arquivos atuais e memória recebem backup antes da aplicação."}
        ' "$manifest"
        return 0
    fi
    [ "$CONFIRM" = RESTORE ] || { pz_error "--confirm RESTORE required"; return 2; }
    rollback="$BACKUP_ROOT/restore-$(date +%Y%m%d-%H%M%S)"
    install -d -m 700 "$rollback/files"
    memory_previous="$rollback/ai-memory-before.tar.gz"
    memory_backup_to "$memory_previous" >/dev/null
    [ -s "$memory_previous" ] || { pz_error "pre-restore memory backup failed"; return 1; }
    memory_restore_from "$temp/extracted/payload/ai-memory.tar.gz" >/dev/null || failed=true
    if ! $failed; then
        while IFS=$'\t' read -r path category mode; do
            [ "$category" = credential ] || continue
            rel="${path#payload/home/}"
            case "$rel" in "$path"|*..*) failed=true; break ;; esac
            target="$HOME/$rel"
            install -d -m 700 "$rollback/files/$(dirname "$rel")" "$(dirname "$target")"
            if [ -e "$target" ]; then
                install -m "$(stat -c '%a' "$target")" "$target" "$rollback/files/$rel"
            else
                : > "$rollback/files/$rel.absent"
            fi
            install -m "$mode" "$temp/extracted/$path" "$target" || { failed=true; break; }
        done < <(jq -r '.items[] | [.path,.category,(.mode|tostring)] | @tsv' "$manifest")
    fi
    if $failed; then
        memory_restore_from "$memory_previous" >/dev/null 2>&1 || true
        while IFS= read -r -d '' path; do
            rel="${path#"$rollback/files/"}"
            case "$rel" in *.absent) rm -f -- "$HOME/${rel%.absent}" ;; *) install -D -m "$(stat -c '%a' "$path")" "$path" "$HOME/$rel" ;; esac
        done < <(find "$rollback/files" -type f -print0)
        pz_error "restore failed; rollback attempted"
        return 1
    fi
    unset PASSPHRASE
    jq -nc --arg rollback "$rollback" \
        '{schemaVersion:1,ok:true,status:"restored",rollback:$rollback,
          next:"Reabra os clientes e execute pz ai doctor. Logins de navegador continuam exigindo autenticação nova."}'
}

case "$ACTION" in
    plan) plan_json ;;
    create|export) create_bundle ;;
    verify) verify_bundle ;;
    restore) restore_bundle ;;
    *) pz_error "usage: backup-manager.sh (plan|create|verify|restore)"; exit 2 ;;
esac
