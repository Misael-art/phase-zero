#!/usr/bin/env bash
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

default_ram_mb() {
    local total reserve ram
    total="$(awk '/MemTotal:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo 8192)"
    reserve=2048
    ram=$(( total * 70 / 100 ))
    [ "$ram" -gt $(( total - reserve )) ] && ram=$(( total - reserve ))
    [ "$ram" -lt 4096 ] && ram=$(( total / 2 ))
    [ "$ram" -lt 2048 ] && ram=2048
    echo "$ram"
}

default_cpus() {
    local total cpus
    total="$(nproc 2>/dev/null || echo 2)"
    cpus="$total"
    [ "$total" -gt 4 ] && cpus=$(( total - 1 ))
    [ "$total" -gt 8 ] && cpus=$(( total - 2 ))
    [ "$cpus" -lt 2 ] && cpus=2
    echo "$cpus"
}

PROVISION_DIR="${PZ_STATE}/windows-vm/provision"
OPERATIONS_DIR="${PZ_STATE}/operations"
GRAPHICS_CONTRACT="${PZ_WINDOWS_VM_GRAPHICS_CONTRACT:-$PZ_ROOT/linux/windows-vm/graphics-profiles.json}"

graphics_contract_validate() {
    jq -e '
        .schemaVersion == "windows-vm-graphics/v1"
        and (.profiles | type == "array")
        and ([.profiles[].id] | length == (unique | length))
        and all(.profiles[];
            (.id | type == "string" and length > 0)
            and (.provisionSupported | type == "boolean")
            and (.applySupported | type == "boolean")
            and (.planSupported | type == "boolean")
            and (.mode | type == "string" and length > 0)
        )
    ' "$GRAPHICS_CONTRACT" >/dev/null 2>&1
}

provision_graphics_supported() {
    local profile="$1"
    graphics_contract_validate || {
        pz_error "Windows VM graphics contract is missing or invalid: $GRAPHICS_CONTRACT"
        return 1
    }
    jq -e --arg profile "$profile" \
        '.profiles[] | select(.id == $profile and .provisionSupported == true)' \
        "$GRAPHICS_CONTRACT" >/dev/null 2>&1
}

provision_graphics_rejection() {
    local profile="$1"
    if ! graphics_contract_validate; then
        printf 'Windows VM graphics contract is missing or invalid: %s' "$GRAPHICS_CONTRACT"
        return 0
    fi
    if jq -e --arg profile "$profile" \
        '.profiles[] | select(.id == $profile and .planSupported == true and .provisionSupported == false)' \
        "$GRAPHICS_CONTRACT" >/dev/null 2>&1; then
        printf 'graphics profile %s is plan-only and cannot be used by automated provisioning' "$profile"
    else
        printf 'unknown or unsupported provisioning graphics profile: %s (valid: compat, virtio-gl)' "$profile"
    fi
}

# The install-target guard inside WinPE compares this against the serial QEMU
# stamped on the disk and aborts Setup when they differ. The provisioning VM
# used a hardcoded 'pzvm' while the answer file demanded PZWINVM0, so the guard
# refused every disk. windows-vm.sh must resolve the same value.
DISK_SERIAL="${PZ_WINDOWS_VM_DISK_SERIAL:-PZWINVM0}"

# Windows 11 refuses to install without TPM 2.0 and Secure Boot. Planning
# already fails outright when swtpm is missing, calling it "required for
# Windows 11", but no provisioning phase ever attached one: Setup died at
# 0x80070057 with an empty disk while the preflight reported everything green.
#
# Each operation gets its own swtpm instance and state directory so a rerun
# never inherits PCR values from a half-finished install. The caller appends
# the emitted arguments to its own QEMU array.
PROVISION_TPM_PID_FILE=""

provision_tpm_args() {
    local vm_dir="$1" op="$2" sock state_dir i
    if ! command -v swtpm >/dev/null 2>&1; then
        log_operation "$op" "swtpm missing; Windows 11 setup will refuse to install"
        return 1
    fi
    state_dir="$vm_dir/tpm"
    sock="$vm_dir/swtpm.sock"
    PROVISION_TPM_PID_FILE="$vm_dir/swtpm.pid"
    install -d -m 0700 "$state_dir"
    rm -f "$sock" "$PROVISION_TPM_PID_FILE"
    local -a swtpm_args=(socket --tpm2
        --tpmstate "dir=$state_dir"
        --ctrl "type=unixio,path=$sock,terminate"
        --pid "file=$PROVISION_TPM_PID_FILE"
        --log "file=$vm_dir/swtpm.log,level=20"
        --daemon)
    local swtpm_rc=0
    if [ "$LOCK_FD" -ge 0 ] 2>/dev/null; then
        swtpm "${swtpm_args[@]}" {LOCK_FD}>&- || swtpm_rc=$?
    else
        swtpm "${swtpm_args[@]}" || swtpm_rc=$?
    fi
    if [ "$swtpm_rc" -ne 0 ]; then
        log_operation "$op" "swtpm failed to start"
        return 1
    fi
    for ((i = 0; i < 100; i++)); do
        [ -S "$sock" ] && break
        sleep 0.05
    done
    [ -S "$sock" ] || { log_operation "$op" "swtpm socket never appeared"; return 1; }
    printf '%s\n' \
        "-chardev" "socket,id=chrtpm,path=$sock" \
        "-tpmdev" "emulator,id=tpm0,chardev=chrtpm" \
        "-device" "tpm-tis,tpmdev=tpm0"
}

provision_tpm_stop() {
    [ -n "$PROVISION_TPM_PID_FILE" ] && [ -f "$PROVISION_TPM_PID_FILE" ] || return 0
    local pid
    pid="$(cat "$PROVISION_TPM_PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
    PROVISION_TPM_PID_FILE=""
}

# Secure Boot is a Windows 11 install requirement, so the firmware that carries
# it must be preferred over the plain build rather than listed after it.
provision_ovmf_code() {
    printf '%s' "${PZ_WINDOWS_VM_OVMF_CODE:-$(pz_path_resolve ovmf_code \
        /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
        /usr/share/OVMF/OVMF_CODE.secboot.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/OVMF/OVMF_CODE.fd || true)}"
}

PLAN_ENDPOINT="${PZ_WINDOWS_VM_PLAN:-$PROVISION_DIR/plans}"
ACTIVE_LOCK="$PROVISION_DIR/active.lock"

PROVISION_CHECKPOINTS=("validate" "assets" "answer-media" "disk" "setup" "drivers" "tweaks" "verify" "snapshot" "relaunch")
CP_WEIGHTS=(5 10 5 30 15 10 5 5 10 5)

checkpoint_progress_start() {
    local current="$1" total=0
    for ((i=0; i<${#PROVISION_CHECKPOINTS[@]}; i++)); do
        [ "${PROVISION_CHECKPOINTS[$i]}" = "$current" ] && break
        total=$((total + CP_WEIGHTS[i]))
    done
    [ "$total" -gt 100 ] && total=100
    echo $total
}

checkpoint_progress_end() {
    local current="$1" total=0
    for ((i=0; i<${#PROVISION_CHECKPOINTS[@]}; i++)); do
        total=$((total + CP_WEIGHTS[i]))
        [ "${PROVISION_CHECKPOINTS[$i]}" = "$current" ] && break
    done
    [ "$total" -gt 100 ] && total=100
    echo $total
}

checkpoint_label() {
    case "$1" in
        validate)    echo "Validando ISO e pré-requisitos" ;;
        assets)      echo "Baixando assets (virtio-win)" ;;
        answer-media) echo "Preparando mídia de resposta" ;;
        disk)        echo "Criando disco virtual (256G)" ;;
        setup)       echo "Instalando Windows" ;;
        drivers)     echo "Instalando drivers virtio" ;;
        tweaks)      echo "Aplicando ajustes pós-instalação" ;;
        verify)      echo "Verificando integridade" ;;
        snapshot)    echo "Criando snapshot de restauração" ;;
        relaunch)    echo "Preparando relaunch com display" ;;
        *)           echo "$1" ;;
    esac
}

provision_plan() {
    local iso="" ram="" cpus="" disk_size="256G" lang="pt-BR" keyboard="pt-BR" timezone="America/Sao_Paulo"
    local user="phasezero" product_key="" tpm_bypass=0 graphics="compat" guest_login="auto" appx_deny="default"
    local image_index=1
    local JSON_OUT=0 DRY_RUN=0 AUTO_FIX=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --iso) iso="${2:-}"; shift 2 ;; --iso=*) iso="${1#*=}"; shift ;;
            --ram) ram="${2:-}"; shift 2 ;; --ram=*) ram="${1#*=}"; shift ;;
            --cpus) cpus="${2:-}"; shift 2 ;; --cpus=*) cpus="${1#*=}"; shift ;;
            --disk-size) disk_size="${2:-}"; shift 2 ;; --disk-size=*) disk_size="${1#*=}"; shift ;;
            --image-index) image_index="${2:-1}"; shift 2 ;;
            --image-index=*) image_index="${1#*=}"; shift ;;
            --lang) lang="${2:-}"; shift 2 ;; --lang=*) lang="${1#*=}"; shift ;;
            --keyboard) keyboard="${2:-}"; shift 2 ;; --keyboard=*) keyboard="${1#*=}"; shift ;;
            --timezone) timezone="${2:-}"; shift 2 ;; --timezone=*) timezone="${1#*=}"; shift ;;
            --user) user="${2:-}"; shift 2 ;; --user=*) user="${1#*=}"; shift ;;
            --product-key) product_key="${2:-}"; shift 2 ;; --product-key=*) product_key="${1#*=}"; shift ;;
            --tpm-bypass) tpm_bypass=1; shift ;;
            --graphics) graphics="${2:-}"; shift 2 ;; --graphics=*) graphics="${1#*=}"; shift ;;
            --guest-login) guest_login="${2:-}"; shift 2 ;; --guest-login=*) guest_login="${1#*=}"; shift ;;
            --json) JSON_OUT=1; shift ;;
            --auto-fix) AUTO_FIX=1; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            *) pz_error "unknown plan option: $1"; return 1 ;;
        esac
    done

    [ -n "$iso" ] || { pz_error "--iso required"; return 1; }
    if ! [[ "$image_index" =~ ^[0-9]+$ ]] || [ "$image_index" -lt 1 ] || [ "$image_index" -gt 10 ]; then
        pz_error "--image-index must be an integer from 1 to 10"
        return 1
    fi
    case "$guest_login" in auto|password) ;; *) pz_error "--guest-login must be auto or password"; return 1 ;; esac
    if ! provision_graphics_supported "$graphics"; then
        pz_error "$(provision_graphics_rejection "$graphics")"
        return 1
    fi

    if [ "$AUTO_FIX" = "1" ]; then
        pz_info "running preflight with auto-fix..."
        bash "$PZ_ROOT/linux/windows-vm/preflight.sh" --auto-fix 2>&1 || pz_warn "preflight auto-fix encountered errors"
    fi

    local iso_ok=1 iso_sha="" iso_arch="x64" iso_uefi=1 iso_errors="[]"
    if [ ! -f "$iso" ]; then iso_ok=0; iso_errors="[\"ISO not found\"]"; fi
    if [ "$iso_ok" = "1" ]; then
        iso_sha="$(sha256sum "$iso" | cut -d' ' -f1)"
    fi

    local json_ram json_cpus
    json_ram="${ram:-$(default_ram_mb)}"
    json_cpus="${cpus:-$(default_cpus)}"

    local plan_id confirm_token timestamp
    plan_id="plan-$(date +%Y%m%d-%H%M%S)-${RANDOM}"
    confirm_token="$(openssl rand -hex 32 2>/dev/null || echo "confirm-${RANDOM}-${RANDOM}")"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local virtio_source="auto"
    local virtio_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"
    local virtio_sha_expected="e14cf2b94492c3e925f0070ba7fdfedeb2048c91eea9c5a5afb30232a3976331"

    local preflight_json preflight_status preflight_stderr
    if [ "${PZ_TEST_MODE:-0}" = "1" ] && [ -n "${PZ_PREFLIGHT_JSON:-}" ]; then
        # Hermetic override — honored ONLY with the PZ_TEST_MODE=1 sentinel, so
        # production always runs the real preflight. The fixture must match the
        # schema the plan consumes (status in pass/warn/fail, swtpm and virtio
        # objects); an invalid override is rejected loudly instead of falling
        # back to host probing.
        if preflight_json="$(printf '%s' "$PZ_PREFLIGHT_JSON" | jq -e -c '(.status == "pass" or .status == "warn" or .status == "fail") and (.swtpm | type == "object") and (.virtio | type == "object")' 2>/dev/null)"; then
            preflight_json="$(printf '%s' "$PZ_PREFLIGHT_JSON" | jq -c --arg profile "$graphics" '
                .graphics = ((.graphics // {supported: true, fallback: "compat", failures: []}) + {profile: $profile})
            ')"
        else
            pz_error "PZ_PREFLIGHT_JSON override rejected: fixture does not match preflight schema (status/swtpm/virtio)"
            return 1
        fi
    else
        # shellcheck disable=SC2119
        preflight_stderr="$(pz_tempfile)" || true
        preflight_json="$(bash "$PZ_ROOT/linux/windows-vm/preflight.sh" --graphics "$graphics" --json 2>"${preflight_stderr:-/dev/null}" || {
            pz_warn "preflight check failed — see diagnostics above"
            echo '{"status":"fail"}'
        })"
        if [ -s "${preflight_stderr:-/dev/null}" ]; then
            pz_warn "preflight diagnostics:"
            sed 's/^/  /' "$preflight_stderr" >&2
        fi
        rm -f "${preflight_stderr:-}"
    fi
    preflight_status="$(echo "$preflight_json" | jq -r '.status // "fail"')"

    local blockers="[]"
    if [ "$iso_ok" != "1" ]; then
        blockers="[\"ISO file not found or unreadable\"]"
    fi
    if [ "$preflight_status" = "fail" ]; then
        local swtpm_missing
        swtpm_missing=$(echo "$preflight_json" | jq -r '.swtpm.binary == false' 2>/dev/null)
        if [ "$swtpm_missing" = "true" ]; then
            local fail_msg="swtpm binary not found — TPM 2.0 required for Windows 11"
            blockers="$(echo "$blockers" | jq --arg m "$fail_msg" '. + [$m]')"
        fi
    fi
    if [ "$(echo "$preflight_json" | jq -r '.graphics.supported // false' 2>/dev/null)" != "true" ]; then
        local graphics_msg="Este host não atende aos requisitos do virtio-gl. Selecione Compatibilidade para continuar."
        blockers="$(echo "$blockers" | jq --arg m "$graphics_msg" '. + [$m]')"
    fi

    local warnings="[]"
    if [ "$preflight_status" = "warn" ]; then
        local swtpm_not_running virtio_outdated
        swtpm_not_running=$(echo "$preflight_json" | jq -r '.swtpm.running == false' 2>/dev/null)
        virtio_outdated=$(echo "$preflight_json" | jq -r '.virtio.outdated' 2>/dev/null)
        [ "$swtpm_not_running" = "true" ] && warnings="$(echo "$warnings" | jq '. + ["swtpm daemon not running — VM may fail to boot with TPM error"]')"
        [ "$virtio_outdated" = "true" ] && warnings="$(echo "$warnings" | jq '. + ["virtio-win outdated — latest may improve driver compatibility"]')"
    fi

    local destructive_ops="[]"
    if [ "$appx_deny" = "default" ]; then
        destructive_ops="[\"remove consumer AppX packages\"]"
    fi

    mkdir -p "$PLAN_ENDPOINT"
    local plan_file="$PLAN_ENDPOINT/$plan_id.json"
    jq -n \
        --arg id "$plan_id" \
        --arg confirmToken "$confirm_token" \
        --arg iso "$iso" \
        --arg isoSha256 "$iso_sha" \
        --arg isoArch "$iso_arch" \
        --argjson isoUefi "$iso_uefi" \
        --argjson isoValid "$iso_ok" \
        --argjson blockers "$blockers" \
        --argjson preflight "$preflight_json" \
        --argjson warnings "$warnings" \
        --arg ram "$json_ram" \
        --arg cpus "$json_cpus" \
        --arg diskSize "$disk_size" \
        --argjson imageIndex "$image_index" \
        --arg lang "$lang" \
        --arg keyboard "$keyboard" \
        --arg timezone "$timezone" \
        --arg user "$user" \
        --arg graphics "$graphics" \
        --arg guestLogin "$guest_login" \
        --arg virtioSource "$virtio_source" \
        --arg virtioUrl "$virtio_url" \
        --arg virtioSha256 "$virtio_sha_expected" \
        --argjson tpmBypass "$([ "$tpm_bypass" = "1" ] && echo true || echo false)" \
        --argjson destructiveOps "$destructive_ops" \
        --arg createdAt "$timestamp" \
        '{
            id: $id,
            confirmToken: $confirmToken,
            iso: {path: $iso, sha256: $isoSha256, arch: $isoArch, uefi: $isoUefi, valid: $isoValid},
            resources: {
                ramMb: ($ram|tonumber),
                cpus: ($cpus|tonumber),
                diskSize: $diskSize
            },
            imageIndex: $imageIndex,
            locale: {lang: $lang, keyboard: $keyboard, timezone: $timezone},
            user: $user,
            graphics: $graphics,
            guestLogin: $guestLogin,
            virtio: {source: $virtioSource, url: $virtioUrl, sha256: $virtioSha256},
            tpmBypass: $tpmBypass,
            profile: "performance-safe",
            destructiveOps: $destructiveOps,
            preflight: $preflight,
            warnings: $warnings,
            blockers: $blockers,
            createdAt: $createdAt
        }' > "$plan_file"
    chmod 0600 "$plan_file"

    if [ "${JSON_OUT:-0}" = "1" ]; then
        cat "$plan_file"
    else
        pz_info "plan created: $plan_id"
        pz_info "confirm token: ${confirm_token:0:16}... (use --confirm <full-token> to execute)"
        if [ "$(echo "$blockers" | jq '. | length')" -gt 0 ]; then
            pz_warn "plan has blockers:"
            echo "$blockers" | jq -r '.[]' | while IFS= read -r b; do echo "  - $b"; done
        fi
        if [ "$(echo "$warnings" | jq '. | length')" -gt 0 ]; then
            pz_warn "preflight warnings:"
            echo "$warnings" | jq -r '.[]' | while IFS= read -r w; do echo "  - $w"; done
            pz_info "run with --auto-fix to start swtpm and download latest virtio-win"
        fi
    fi
}

provision_start() {
    local plan_id="" confirm_token="" json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --plan-id) plan_id="${2:-}"; shift 2 ;;
            --plan-id=*) plan_id="${1#*=}"; shift ;;
            --confirm) confirm_token="${2:-}"; shift 2 ;;
            --confirm=*) confirm_token="${1#*=}"; shift ;;
            --json) json=1; shift ;;
            *) pz_error "unknown start option: $1"; return 1 ;;
        esac
    done

    [ -n "$plan_id" ] || { pz_error "--plan-id required"; return 1; }
    [ -n "$confirm_token" ] || { pz_error "--confirm required"; return 1; }

    local plan_file="$PLAN_ENDPOINT/$plan_id.json"
    [ -f "$plan_file" ] || { pz_error "plan not found: $plan_id"; return 1; }

    local plan_graphics
    plan_graphics="$(jq -r '.graphics // ""' "$plan_file" 2>/dev/null || true)"
    if ! provision_graphics_supported "$plan_graphics"; then
        pz_error "refusing stale plan: $(provision_graphics_rejection "$plan_graphics")"
        return 1
    fi

    local expected_token
    expected_token="$(jq -r '.confirmToken' "$plan_file")"
    [ "$confirm_token" = "$expected_token" ] || { pz_error "confirm token mismatch"; return 1; }

    local blockers
    blockers="$(jq -r '.blockers | length' "$plan_file")"
    [ "$blockers" = "0" ] || { pz_error "plan has unresolved blockers"; return 1; }

    mkdir -p "$OPERATIONS_DIR"
    local operation_id="op-$(date +%Y%m%d-%H%M%S)-${RANDOM}"
    if ! provision_lock_acquire "$operation_id"; then
        return 1
    fi
    local op_dir="$OPERATIONS_DIR/$operation_id"
    mkdir -p "$op_dir"
    chmod 0700 "$op_dir"

    cp "$plan_file" "$op_dir/plan.json"

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local initial_label
    initial_label="$(checkpoint_label "validate")"
    jq -n \
        --arg id "$operation_id" \
        --arg planId "$plan_id" \
        --arg state "running" \
        --arg checkpoint "validate" \
        --arg currentLabel "$initial_label" \
        --arg createdAt "$timestamp" \
        '{
            id: $id, planId: $planId, state: $state,
            checkpoint: $checkpoint, currentLabel: $currentLabel,
            progress: 0,
            createdAt: $createdAt, updatedAt: $createdAt,
            checkpoints: {},
            log: []
        }' > "$op_dir/operation.json"
    chmod 0600 "$op_dir/operation.json"

    # Persist a short handoff grace before releasing the lock. A reader that
    # observes the tiny gap before the detached worker takes flock must not
    # misclassify a newly started install as dead.
    jq --argjson epoch "$(date +%s)" \
        '.workerSpawnedEpoch = $epoch' "$op_dir/operation.json" > "$op_dir/operation.tmp" &&
        mv "$op_dir/operation.tmp" "$op_dir/operation.json"

    if [ "$json" = "1" ]; then
        jq -n \
            --arg id "$operation_id" \
            --arg state "running" \
            --arg checkpoint "validate" \
            --arg currentLabel "$initial_label" \
            --arg activeLock "$ACTIVE_LOCK" \
            '{operationId: $id, state: $state, checkpoint: $checkpoint, currentLabel: $currentLabel, progress: 0, activeLockPath: $activeLock}'
    else
        pz_info "provision started: $operation_id"
        echo "$operation_id"
    fi

    # Do not let the worker inherit the parent's flock FD: an inherited open
    # file description keeps the lock alive and makes the worker deadlock on
    # its own re-acquire loop. ACTIVE_LOCK keeps the operation-id handoff.
    provision_lock_release
    setsid nohup bash "$PZ_ROOT/linux/windows-vm/provision.sh" run --operation-id "$operation_id" \
        </dev/null > "$op_dir/worker.log" 2>&1 &
    disown
}

provision_run() {
    local operation_id=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done
    [ -n "$operation_id" ] || { pz_error "--operation-id required"; return 1; }

    local op_dir="$OPERATIONS_DIR/$operation_id"
    local plan_file="$op_dir/plan.json"
    [ -f "$plan_file" ] || { pz_error "plan not found for operation $operation_id"; return 1; }

    provision_worker_identity_write "$operation_id"

    # The parent (start/resume) holds the lock only until spawn; the worker
    # re-acquires it for the whole run so a second start/resume is blocked
    # while this operation is live. Retry briefly to bridge the handoff.
    local acquired=0 attempt=0
    while [ "$attempt" -lt 100 ]; do
        if provision_lock_acquire "$operation_id"; then
            acquired=1
            break
        fi
        attempt=$((attempt + 1))
        sleep 0.1
    done
    if [ "$acquired" != "1" ]; then
        pz_error "could not acquire provision lock for $operation_id"
        return 1
    fi
    trap 'provision_lock_release' RETURN

    for cp in "${PROVISION_CHECKPOINTS[@]}"; do
        local current_state
        current_state="$(jq -r '.state // "running"' "$op_dir/operation.json")"
        [ "$current_state" = "running" ] || { pz_info "operation state changed to $current_state; stopping"; return 0; }

        # checkpoint done → skip on resume
        local cp_status
        cp_status="$(jq -r --arg cp "$cp" '.checkpoints[$cp] // ""' "$op_dir/operation.json")"
        [ "$cp_status" = "done" ] && continue

        local start_progress end_progress pre_label
        start_progress="$(checkpoint_progress_start "$cp")"
        end_progress="$(checkpoint_progress_end "$cp")"
        pre_label="$(checkpoint_label "$cp")"
        local pre_ts; pre_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        jq \
            --arg p "$start_progress" \
            --arg l "$pre_label" \
            --arg cp "$cp" \
            --arg ts "$pre_ts" \
            '.checkpoint = $cp | .currentLabel = $l | .progress = ($p|tonumber) | .updatedAt = $ts' \
            "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"

        case "$cp" in
            validate)    run_validate "$operation_id" || { fail_operation "$operation_id" "validate"; return 1; } ;;
            assets)      run_assets "$operation_id" || { fail_operation "$operation_id" "assets"; return 1; } ;;
            answer-media) run_answer_media "$operation_id" || { fail_operation "$operation_id" "answer-media"; return 1; } ;;
            disk)        run_disk "$operation_id" || { fail_operation "$operation_id" "disk"; return 1; } ;;
            setup)       run_setup "$operation_id" || { fail_operation "$operation_id" "setup"; return 1; } ;;
            drivers)     run_drivers "$operation_id" || { fail_operation "$operation_id" "drivers"; return 1; } ;;
            tweaks)      run_tweaks "$operation_id" || { fail_operation "$operation_id" "tweaks"; return 1; } ;;
            verify)      run_verify "$operation_id" || { fail_operation "$operation_id" "verify"; return 1; } ;;
            snapshot)    run_snapshot "$operation_id" || { fail_operation "$operation_id" "snapshot"; return 1; } ;;
            relaunch)    run_relaunch "$operation_id" || { fail_operation "$operation_id" "relaunch"; return 1; } ;;
        esac

        update_checkpoint "$operation_id" "$cp" "done"

        local post_ts; post_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        jq \
            --arg p "$end_progress" \
            --arg ts "$post_ts" \
            '.progress = ($p|tonumber) | .updatedAt = $ts' \
            "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
    done

    local done_ts; done_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg ts "$done_ts" '.state = "completed" | .progress = 100 | .updatedAt = $ts' \
        "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
    rm -f -- "$op_dir/worker.identity.json" "$op_dir/worker.pid"
    provision_lock_clear "$operation_id"
    pz_info "provision completed: $operation_id"
}

update_checkpoint() {
    local op="$1" cp="$2" status="$3"
    local op_dir="$OPERATIONS_DIR/$op"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg cp "$cp" --arg status "$status" --arg ts "$ts" \
        '.checkpoints[$cp] = $status | .updatedAt = $ts' \
        "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
}

fail_operation() {
    local op="$1" cp="$2"
    local op_dir="$OPERATIONS_DIR/$op"
    # A user cancel must never be downgraded to failed by the dying worker.
    local cur
    cur="$(jq -r '.state // "running"' "$op_dir/operation.json" 2>/dev/null || true)"
    [ "$cur" = "cancelled" ] && return 0
    update_checkpoint "$op" "$cp" "failed"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg ts "$ts" '.state = "failed" | .updatedAt = $ts' "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
    rm -f -- "$op_dir/worker.identity.json" "$op_dir/worker.pid"
}

# Worker identity binds PID to this boot and kernel process start tick, so PID
# reuse cannot turn an unrelated process into proof that an install is alive.
provision_worker_identity_write() {
    local op="$1" pid="$$" stat rest ticks boot_id op_dir tmp
    op_dir="$OPERATIONS_DIR/$op"
    [ -r "/proc/$pid/stat" ] || return 1
    stat="$(cat "/proc/$pid/stat" 2>/dev/null || true)"
    rest="${stat##*) }"
    local -a fields=()
    read -r -a fields <<< "$rest"
    ticks="${fields[19]:-}"
    boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    [[ "$ticks" =~ ^[0-9]+$ && "$boot_id" =~ ^[0-9a-f-]+$ ]] || return 1
    tmp="$(mktemp "$op_dir/.worker.XXXXXX")" || return 1
    jq -n --argjson pid "$pid" --arg bootId "$boot_id" --arg startTicks "$ticks" \
        '{pid:$pid,bootId:$bootId,startTicks:$startTicks}' > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$op_dir/worker.identity.json"
    printf '%s\n' "$pid" > "$op_dir/worker.pid"
}

provision_worker_alive() {
    local op="$1" op_dir="$OPERATIONS_DIR/$1" pid boot_id ticks stat rest cmdline
    [ -f "$op_dir/worker.identity.json" ] || return 1
    pid="$(jq -r '.pid // 0' "$op_dir/worker.identity.json" 2>/dev/null || echo 0)"
    boot_id="$(jq -r '.bootId // ""' "$op_dir/worker.identity.json" 2>/dev/null || true)"
    ticks="$(jq -r '.startTicks // ""' "$op_dir/worker.identity.json" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
    [ -r "/proc/$pid/stat" ] && [ -r "/proc/$pid/cmdline" ] || return 1
    [ "$boot_id" = "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)" ] || return 1
    stat="$(cat "/proc/$pid/stat" 2>/dev/null || true)"
    rest="${stat##*) }"
    local -a fields=()
    read -r -a fields <<< "$rest"
    [ "${fields[19]:-}" = "$ticks" ] || return 1
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ "$cmdline" == *"$PZ_ROOT/linux/windows-vm/provision.sh run --operation-id $op"* ]]
}

provision_active_lock_held() {
    if [ -d "$ACTIVE_LOCK.d" ]; then
        local holder_pid=""
        [ -f "$ACTIVE_LOCK.d/pid" ] && holder_pid="$(cat "$ACTIVE_LOCK.d/pid" 2>/dev/null || true)"
        [[ "$holder_pid" =~ ^[0-9]+$ ]] && kill -0 "$holder_pid" 2>/dev/null
        return
    fi
    [ -f "$ACTIVE_LOCK" ] || return 1
    if command -v flock >/dev/null 2>&1 && [ "${PZ_LOCK_FORCE_MKDIR:-0}" != "1" ]; then
        flock -n "$ACTIVE_LOCK" -c true >/dev/null 2>&1 && return 1
        return 0
    fi
    return 1
}

provision_spawn_grace_active() {
    local op="$1" spawned now
    spawned="$(jq -r '.workerSpawnedEpoch // 0' "$OPERATIONS_DIR/$op/operation.json" 2>/dev/null || echo 0)"
    [[ "$spawned" =~ ^[0-9]+$ ]] || return 1
    [ "$spawned" -gt 0 ] || return 1
    now="$(date +%s)"
    [ "$((now - spawned))" -lt 15 ]
}

provision_worker_effectively_alive() {
    local op="$1"
    provision_worker_alive "$op" || provision_active_lock_held || provision_spawn_grace_active "$op"
}

provision_supervisor_alive() {
    local op="$1"
    provision_worker_alive "$op" || provision_spawn_grace_active "$op"
}

provision_effective_state() {
    local op="$1" state
    state="$(jq -r '.state // "unknown"' "$OPERATIONS_DIR/$op/operation.json" 2>/dev/null || echo unknown)"
    if [ "$state" = "running" ] && ! provision_worker_effectively_alive "$op"; then
        printf 'interrupted\n'
    else
        printf '%s\n' "$state"
    fi
}

# Caller must own the provision lock. Never resume or replace a supervisor
# while its QEMU child still has the staging disk open.
provision_mark_interrupted_locked() {
    local op="$1" op_dir="$OPERATIONS_DIR/$1" vm_dir="" reason ts
    if provision_supervisor_alive "$op"; then
        pz_error "operation $op still has a live worker or is starting"
        return 1
    fi
    vm_dir="$(resolve_vm_staging_dir "$op" 2>/dev/null || true)"
    if [ -n "$vm_dir" ] && [ -d "$vm_dir" ] && operation_vm_running "$vm_dir"; then
        reason="worker ended; QEMU remains active for this installation"
    else
        reason="worker ended without recording a terminal state"
    fi
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg ts "$ts" --arg reason "$reason" \
        '.state="interrupted" | .updatedAt=$ts | .interruptionReason=$reason | .recoveryAction="resume-or-remove"' \
        "$op_dir/operation.json" > "$op_dir/operation.tmp" && mv "$op_dir/operation.tmp" "$op_dir/operation.json"
    rm -f -- "$op_dir/worker.identity.json" "$op_dir/worker.pid"
    [ "$reason" = "worker ended without recording a terminal state" ] || {
        pz_error "operation $op still has a QEMU process; shut it down before resuming or removing"
        return 2
    }
    pz_warn "operation $op was interrupted; its staging files are preserved"
}

# ── Provision lock ──
# Single-writer lock across start/resume/cancel. Uses flock(1) when available
# (atomic, auto-released on process death); falls back to mkdir+pidfile with
# staleness check. The lock file content is the authoritative operation id;
    # a lock whose recorded operation is terminal/interrupted is recoverable,
# a running operation blocks a new one, and inconsistent state (lock references
# a missing/corrupt operation) produces a diagnostic instead of silent overwrite.
LOCK_FD=-1
LOCK_DIR_MODE="mkdir"

provision_lock_init() {
    mkdir -p "$PROVISION_DIR"
    # PZ_LOCK_FORCE_MKDIR=1 selects the mkdir+pidfile fallback even when flock
    # is present, so the fallback path is exercisable in tests and on hosts
    # where flock misbehaves (sandboxes, containers with seccomp filtering).
    if [ "${PZ_LOCK_FORCE_MKDIR:-0}" != "1" ] && command -v flock >/dev/null 2>&1; then
        LOCK_DIR_MODE="flock"
    else
        LOCK_DIR_MODE="mkdir"
    fi
}

provision_lock_acquire() {
    local new_op="$1"
    local prev="" prev_state=""
    provision_lock_init
    if [ "$LOCK_DIR_MODE" = "flock" ]; then
        [ "$LOCK_FD" -ge 0 ] 2>/dev/null || LOCK_FD=-1
        if [ "$LOCK_FD" -lt 0 ]; then
            # <> opens read-write without truncating, so the recorded
            # operation id survives across processes.
            exec {LOCK_FD}<>"$ACTIVE_LOCK"
        fi
        if ! flock -n "$LOCK_FD"; then
            prev="$(cat "$ACTIVE_LOCK" 2>/dev/null || true)"
            pz_error "provision lock held by: ${prev:-unknown operation}"
            return 1
        fi
    else
        if ! mkdir "$ACTIVE_LOCK.d" 2>/dev/null; then
            prev="$(cat "$ACTIVE_LOCK" 2>/dev/null || true)"
            local holder_pid=""
            [ -f "$ACTIVE_LOCK.d/pid" ] && holder_pid="$(cat "$ACTIVE_LOCK.d/pid" 2>/dev/null || true)"
            if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null; then
                pz_error "provision lock held by: ${prev:-unknown operation} (pid $holder_pid)"
                return 1
            fi
            pz_warn "stale mkdir lock detected (holder pid ${holder_pid:-unknown} not alive); recovering"
            rm -rf "$ACTIVE_LOCK.d"
            mkdir "$ACTIVE_LOCK.d" 2>/dev/null || { pz_error "provision lock contention"; return 1; }
        fi
        printf '%s\n' "$$" > "$ACTIVE_LOCK.d/pid"
    fi

    prev="$(cat "$ACTIVE_LOCK" 2>/dev/null || true)"
    if [ -n "$prev" ] && [ "$prev" != "$new_op" ]; then
        local prev_op="$OPERATIONS_DIR/$prev"
        if [ -f "$prev_op/operation.json" ]; then
            prev_state="$(jq -r '.state // ""' "$prev_op/operation.json" 2>/dev/null || true)"
            case "$prev_state" in
                running)
                    if provision_mark_interrupted_locked "$prev"; then
                        prev_state="interrupted"
                    else
                        provision_lock_release
                        return 1
                    fi
                    ;;
                interrupted)
                    local prev_vm_dir
                    prev_vm_dir="$(resolve_vm_staging_dir "$prev" 2>/dev/null || true)"
                    if [ -n "$prev_vm_dir" ] && [ -d "$prev_vm_dir" ] && operation_vm_running "$prev_vm_dir"; then
                        pz_error "interrupted operation $prev still has a QEMU process; shut it down before starting another install"
                        provision_lock_release
                        return 1
                    fi
                    ;;
                completed|failed|cancelled)
                    pz_warn "recovering provision lock from operation $prev (state: $prev_state)"
                    ;;
                "")
                    pz_error "lock references operation $prev with unreadable/corrupt state — refusing to overwrite"
                    provision_lock_release
                    return 1
                    ;;
                *)
                    pz_error "lock references operation $prev in inconsistent state ($prev_state) — refusing to overwrite"
                    provision_lock_release
                    return 1
                    ;;
            esac
        else
            pz_error "lock references missing operation $prev — refusing to overwrite"
            provision_lock_release
            return 1
        fi
    fi
    printf '%s\n' "$new_op" > "$ACTIVE_LOCK"
    return 0
}

provision_lock_release() {
    if [ "$LOCK_DIR_MODE" = "flock" ]; then
        if [ "$LOCK_FD" -ge 0 ] 2>/dev/null; then
            flock -u "$LOCK_FD" 2>/dev/null || true
            exec {LOCK_FD}>&- 2>/dev/null || true
            LOCK_FD=-1
        fi
    else
        rm -rf "$ACTIVE_LOCK.d"
    fi
}

# Remove the recorded operation id from ACTIVE_LOCK only if it still names
# the given operation (the worker finishing must never clear a lock that a
# newer operation already took over). Truncates in place — never unlinks —
# so the inode stays permanent: a racer re-opening the path between this
# clear and the later release contends on the very flock we still hold.
# Always returns 0: a mismatch is a no-op, never a failure under set -e.
provision_lock_clear() {
    local op="$1"
    local current=""
    current="$(cat "$ACTIVE_LOCK" 2>/dev/null || true)"
    if [ "$current" = "$op" ]; then
        : > "$ACTIVE_LOCK" 2>/dev/null || true
    fi
    return 0
}

HAVE_SOCAT=0
command -v socat >/dev/null 2>&1 && HAVE_SOCAT=1
QGA_CHANNEL_SOCK=""
QGA_CHANNEL_PID=""
QGA_READ_FD=""
QGA_WRITE_FD=""
QGA_RESPONSE=""
QGA_REQUEST_SEQ=0

qga_channel_close() {
    if [[ "$QGA_READ_FD" =~ ^[0-9]+$ ]]; then
        eval "exec ${QGA_READ_FD}<&-"
    fi
    if [[ "$QGA_WRITE_FD" =~ ^[0-9]+$ ]]; then
        eval "exec ${QGA_WRITE_FD}>&-"
    fi
    if [[ "$QGA_CHANNEL_PID" =~ ^[0-9]+$ ]]; then
        kill "$QGA_CHANNEL_PID" 2>/dev/null || true
        wait "$QGA_CHANNEL_PID" 2>/dev/null || true
    fi
    QGA_CHANNEL_SOCK=""
    QGA_CHANNEL_PID=""
    QGA_READ_FD=""
    QGA_WRITE_FD=""
}

qga_channel_open() {
    local sock="$1"
    [ "$HAVE_SOCAT" = "1" ] || return 1
    [ -S "$sock" ] || return 1
    if [ "$QGA_CHANNEL_SOCK" = "$sock" ] &&
       [[ "$QGA_CHANNEL_PID" =~ ^[0-9]+$ ]] &&
       kill -0 "$QGA_CHANNEL_PID" 2>/dev/null; then
        return 0
    fi
    qga_channel_close
    coproc PZ_QGA_SOCAT { socat STDIO UNIX-CONNECT:"$sock" 2>/dev/null; }
    local read_fd="${PZ_QGA_SOCAT[0]}" write_fd="${PZ_QGA_SOCAT[1]}"
    QGA_CHANNEL_PID="$PZ_QGA_SOCAT_PID"
    exec {QGA_READ_FD}<&"$read_fd"
    exec {QGA_WRITE_FD}>&"$write_fd"
    eval "exec ${read_fd}<&-"
    eval "exec ${write_fd}>&-"
    QGA_CHANNEL_SOCK="$sock"
}

qga_request() {
    local sock="$1" cmd="$2" response="" request="" request_id deadline
    QGA_RESPONSE=""
    qga_channel_open "$sock" || return 1
    QGA_REQUEST_SEQ=$((QGA_REQUEST_SEQ + 1))
    request_id="$QGA_REQUEST_SEQ"
    request="$(printf '%s\n' "$cmd" | jq -c --argjson id "$request_id" '.id = $id' 2>/dev/null)"
    [ -n "$request" ] || return 1
    printf '%s\n' "$request" >&"$QGA_WRITE_FD" || return 1
    deadline=$((SECONDS + 5))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if IFS= read -r -t 1 response <&"$QGA_READ_FD"; then
            response="${response//$'\377'/}"
            if printf '%s\n' "$response" |
                jq -e --argjson id "$request_id" '.id == $id and (has("return") or has("error"))' >/dev/null 2>&1; then
                QGA_RESPONSE="$response"
                return 0
            fi
        fi
    done
    return 1
}

qga_ping() {
    local sock="$1"
    [ "$HAVE_SOCAT" != "1" ] && return 1
    qga_request "$sock" '{"execute":"guest-ping"}' || return 1
    printf '%s\n' "$QGA_RESPONSE" | jq -e '.return' >/dev/null 2>&1
}

qga_exec() {
    local sock="$1" cmd="$2"
    if [ "$HAVE_SOCAT" != "1" ]; then
        QGA_RESPONSE='{"return":{"pid":0}}'
        return 1
    fi
    local response=""
    qga_request "$sock" "$cmd" || true
    response="$QGA_RESPONSE"
    response="$(printf '%s\n' "$response" | jq -c 'select(has("return") or has("error"))' 2>/dev/null | tail -n 1)"
    if [ -n "$response" ]; then
        QGA_RESPONSE="$response"
    else
        QGA_RESPONSE='{"return":{"pid":0}}'
    fi
}

qga_shutdown() {
    local sock="$1"
    [ "$HAVE_SOCAT" != "1" ] && return 1
    qga_channel_open "$sock" || return 1
    printf '%s\n' '{"execute":"guest-shutdown"}' >&"$QGA_WRITE_FD" || true
}

graphics_preflight() {
    local op="$1" graphics="$2"
    local kvm_path="${PZ_GFX_KVM_PATH:-/dev/kvm}"
    local qemu_bin="${PZ_GFX_QEMU_BIN:-qemu-system-x86_64}"
    case "$graphics" in
        compat) return 0 ;;
        virtio-gl)
            local failures=()
            [ -e "$kvm_path" ] || failures+=("$kvm_path not accessible")
            local render_node="${PZ_GFX_RENDER_NODE:-}"
            if [ -z "$render_node" ]; then
                for node in /dev/dri/renderD*; do [ -r "$node" ] && [ -w "$node" ] && { render_node="$node"; break; }; done
            fi
            [ -n "$render_node" ] || failures+=("no accessible render node (need mesa/virgl)")
            local has_virtio_vga_gl=0
            if command -v "$qemu_bin" >/dev/null 2>&1; then
                "$qemu_bin" -device help 2>/dev/null | grep 'virtio-vga-gl' >/dev/null && has_virtio_vga_gl=1
            fi
            local qemu_has_virtio_vga_gl="${PZ_GFX_QEMU_VIRTIO_VGA_GL:-}"
            if [ -n "$qemu_has_virtio_vga_gl" ]; then
                [ "$qemu_has_virtio_vga_gl" = "1" ] && has_virtio_vga_gl=1 || has_virtio_vga_gl=0
            fi
            [ "$has_virtio_vga_gl" = "1" ] || failures+=("QEMU lacks virtio-vga-gl device")
            local has_virgl=0
            if [ -n "${PZ_GFX_VIRGL_PRESENT:-}" ]; then
                [ "$PZ_GFX_VIRGL_PRESENT" = "1" ] && has_virgl=1
            else
                ldconfig -p 2>/dev/null | grep 'virglrenderer' >/dev/null && has_virgl=1
            fi
            [ "$has_virgl" = "1" ] || failures+=("virglrenderer library not found")
            if [ -z "${PZ_GFX_AMDGPU_BOUND:-}" ]; then
                local has_amdgpu=0
                for card in /sys/class/drm/card*/device/driver; do
                    [ -L "$card" ] && [ "$(readlink "$card")" = "amdgpu" ] && has_amdgpu=1
                done
                [ "$has_amdgpu" = "0" ] && log_operation "$op" "WARN: no AMDGPU driver bound (VM may lack device memory for virgl)"
            fi
            if [ "${#failures[@]}" -gt 0 ]; then
                for f in "${failures[@]}"; do log_operation "$op" "virtio-gl preflight FAIL: $f"; done
                log_operation "$op" "fallback: --graphics compat (non-accelerated QXL)"
                return 1
            fi
            log_operation "$op" "virtio-gl preflight: KVM OK, render node OK, QEMU OK, virgl OK"
            return 0
            ;;
        *)
            log_operation "$op" "FAIL: unknown graphics profile: $graphics (valid: compat, virtio-gl)"
            return 1
            ;;
    esac
}

resolve_graphics_qemu_args() {
    local op="$1" graphics="$2"
    GRAPHICS_VGA="" GRAPHICS_DISPLAY="" GRAPHICS_ACCEL_LOG=""
    case "$graphics" in
        compat)
            GRAPHICS_VGA="-vga qxl"
            GRAPHICS_DISPLAY="-display gtk"
            GRAPHICS_ACCEL_LOG="GPU acceleration: NONE (QXL)"
            ;;
        virtio-gl)
            GRAPHICS_VGA="-device virtio-vga-gl"
            GRAPHICS_DISPLAY="-display gtk,gl=on"
            GRAPHICS_ACCEL_LOG="GPU acceleration: virgl (OpenGL only; no Vulkan/D3D)"
            ;;
        *)
            log_operation "$op" "FAIL: unknown graphics profile: $graphics"
            return 1
            ;;
    esac
    local op_dir="$OPERATIONS_DIR/$op"
    jq --arg resolved "$graphics" --arg vga "$GRAPHICS_VGA" --arg display "$GRAPHICS_DISPLAY" --arg accelLog "$GRAPHICS_ACCEL_LOG" \
        '.graphicsResolved = {profile: $resolved, vgaDevice: $vga, displayArg: $display, accelLog: $accelLog}' \
        "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
    return 0
}

log_operation() {
    local op="$1" msg="$2"
    local op_dir="$OPERATIONS_DIR/$op"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg msg "$msg" --arg ts "$ts" \
        '.log += [$ts + " " + $msg]' \
        "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"
    pz_info "[$op] $msg"
}

run_validate() {
    local op="$1"
    log_operation "$op" "validating ISO and host requirements"
    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    local iso
    iso="$(jq -r '.iso.path' "$plan_file")"
    [ -f "$iso" ] || { log_operation "$op" "FAIL: ISO not found"; return 1; }
    [ -e /dev/kvm ] || { log_operation "$op" "FAIL: KVM not available"; return 1; }
    command -v qemu-system-x86_64 >/dev/null 2>&1 || { log_operation "$op" "FAIL: qemu-system-x86_64 missing"; return 1; }
    command -v qemu-img >/dev/null 2>&1 || { log_operation "$op" "FAIL: qemu-img missing"; return 1; }
    local ovmf
    ovmf="$(jq -r '.iso.arch' "$plan_file")"
    [ "$ovmf" = "x64" ] || { log_operation "$op" "FAIL: unsupported architecture"; return 1; }

    local graphics
    graphics="$(jq -r '.graphics // "compat"' "$plan_file")"
    graphics_preflight "$op" "$graphics" || { log_operation "$op" "FAIL: graphics preflight"; return 1; }
    resolve_graphics_qemu_args "$op" "$graphics" || { log_operation "$op" "FAIL: graphics resolution"; return 1; }

    log_operation "$op" "$GRAPHICS_ACCEL_LOG"
    log_operation "$op" "validation passed"
    return 0
}

run_assets() {
    local op="$1"
    log_operation "$op" "preparing assets"

    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    local vm_dir="${PZ_STATE}/windows-vm/vms/${op}"
    local disk_path="$vm_dir/disk.qcow2"
    local disk_size
    disk_size="$(jq -r '.resources.diskSize // "256G"' "$plan_file")"

    mkdir -p "$vm_dir"
    echo "$vm_dir" > "$OPERATIONS_DIR/$op/vm_dir"

    log_operation "$op" "VM directory: $vm_dir"

    local virtio_url virtio_expected
    virtio_url="$(jq -r '.virtio.url // ""' "$plan_file")"
    virtio_expected="$(jq -r '.virtio.sha256 // ""' "$plan_file")"

    if [ -n "$virtio_url" ] && [ ! -f "$vm_dir/virtio-win.iso" ]; then
        local preflight_cache="${PZ_STATE}/windows-vm/vm/virtio-win.iso"
        if [ -f "$preflight_cache" ]; then
            local cache_sha
            cache_sha="$(sha256sum "$preflight_cache" 2>/dev/null | cut -d' ' -f1 || true)"
            if [ -z "$virtio_expected" ] || [ "$cache_sha" = "$virtio_expected" ]; then
                log_operation "$op" "reusing preflight-cached virtio-win.iso"
                ln -f "$preflight_cache" "$vm_dir/virtio-win.iso"
            else
                log_operation "$op" "preflight cache SHA mismatch (expected=$virtio_expected cached=$cache_sha) — downloading fresh"
            fi
        fi
        if [ ! -f "$vm_dir/virtio-win.iso" ]; then
            log_operation "$op" "downloading VirtIO drivers from $virtio_url"
            local download_ok=0
            if command -v curl >/dev/null 2>&1; then
                if curl -L -o "$vm_dir/virtio-win.iso" "$virtio_url"; then
                    download_ok=1
                fi
            elif command -v wget >/dev/null 2>&1; then
                if wget -O "$vm_dir/virtio-win.iso" "$virtio_url"; then
                    download_ok=1
                fi
            fi
            if [ "$download_ok" = "1" ] && [ -n "$virtio_expected" ]; then
                local actual
                actual="$(sha256sum "$vm_dir/virtio-win.iso" | cut -d' ' -f1)"
                if [ "$actual" != "$virtio_expected" ]; then
                    log_operation "$op" "FAIL: VirtIO SHA-256 mismatch (expected=$virtio_expected actual=$actual)"
                    return 1
                fi
            elif [ "$download_ok" != "1" ]; then
                log_operation "$op" "FAIL: VirtIO download failed"
                return 1
            fi
        fi
    fi

    log_operation "$op" "assets ready"
    return 0
}

run_answer_media() {
    local op="$1"
    log_operation "$op" "generating answer file"
    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    # Must match the serial stamped on the QEMU disk device, or the
    # install-target guard refuses every disk and Setup aborts. A per-operation
    # value looked safer but matched nothing, so the guard was never enforced.
    local disk_serial="$DISK_SERIAL"

    local answer_dir="$vm_dir/oemdrv"
    mkdir -p "$answer_dir"

    local image_index lang keyboard tz user password_xml product_key tpm_bypass guest_login
    image_index="$(jq -r '.imageIndex // 1' "$plan_file")"
    lang="$(jq -r '.locale.lang // "pt-BR"' "$plan_file")"
    keyboard="$(jq -r '.locale.keyboard // "pt-BR"' "$plan_file")"
    tz="$(jq -r '.locale.timezone // "America/Sao_Paulo"' "$plan_file")"
    user="$(jq -r '.user // "phasezero"' "$plan_file")"
    guest_login="$(jq -r '.guestLogin // "auto"' "$plan_file")"
    password_xml="$(openssl rand -base64 24 2>/dev/null || echo "PhaseZero.Install.$(date +%s)")"
    product_key="$(jq -r '.productKey // ""' "$plan_file")"
    tpm_bypass="$(jq -r '.tpmBypass // false' "$plan_file")"

    echo "$password_xml" > "$OPERATIONS_DIR/$op/bootstrap_secret"
    chmod 0600 "$OPERATIONS_DIR/$op/bootstrap_secret"

    local autounattend_args=(
        --wim-index "$image_index"
        --lang "$lang"
        --keyboard "$keyboard"
        --timezone "$tz"
        --user "$user"
        --password "$password_xml"
        --disk-serial "$disk_serial"
        --output-dir "$answer_dir"
    )
    [ -n "$product_key" ] && autounattend_args+=(--product-key "$product_key")
    case "$tpm_bypass" in
        true|1) autounattend_args+=(--tpm-bypass) ;;
    esac
    bash "$PZ_ROOT/linux/windows-vm/autounattend.sh" generate \
        "${autounattend_args[@]}" >/dev/null

    install -m 0600 "$PZ_ROOT/linux/windows-vm/guest-login.ps1" "$answer_dir/guest-login.ps1"
    # The bootstrap secret already exists in autounattend.xml on this
    # short-lived OEM media. Keep it off argv/logs and delete the whole staging
    # tree after provisioning.
    printf '%s\n%s\n' "$user" "$password_xml" | jq -R -s --arg mode "$guest_login" \
        'split("\n") | {username:.[0],password:.[1],mode:$mode}' > "$answer_dir/guest-login.json"
    chmod 0600 "$answer_dir/guest-login.json"

    local iso_file="$answer_dir/autounattend.xml"
    [ -f "$iso_file" ] || { log_operation "$op" "FAIL: autounattend.xml not generated"; return 1; }

    local inject_script="$answer_dir/setup.ps1"
    cat > "$inject_script" << 'PSEOF'
# PhaseZero post-install setup script
Start-Transcript -Path "$env:SystemRoot\Temp\phasezero-setup.log"
$ErrorActionPreference = "Stop"

Write-Host "PhaseZero: post-install setup starting"

try {
    $virtioRoot = $null
    foreach ($code in 68..90) {
        $candidateRoot = ([char]$code) + ':\'
        if (Test-Path (Join-Path $candidateRoot 'vioserial')) {
            $virtioRoot = $candidateRoot
            break
        }
    }
    if (-not $virtioRoot) { throw "virtio-win media not found on D: through Z:" }

    $qgaMsi = Join-Path $virtioRoot 'guest-agent\qemu-ga-x86_64.msi'

    $vioserialInf = Get-ChildItem (Join-Path $virtioRoot 'vioserial') -Filter 'vioser.inf' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object { if ($_.FullName -match '\\w11\\amd64\\') { 0 } else { 1 } } |
        Select-Object -First 1
    if ($vioserialInf) {
        Write-Host "PhaseZero: installing VirtIO serial driver"
        & pnputil.exe /add-driver $vioserialInf.FullName /install | Out-Host
    } else {
        throw "VirtIO serial driver not found"
    }

    if (-not (Get-Service qemu-ga -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path $qgaMsi)) { throw "QEMU Guest Agent MSI not found" }
        Write-Host "PhaseZero: installing QEMU Guest Agent"
        $qgaInstall = Start-Process msiexec.exe -ArgumentList '/i', $qgaMsi, '/qn', '/norestart' -PassThru -NoNewWindow
        if (-not $qgaInstall.WaitForExit(300000)) {
            Stop-Process -Id $qgaInstall.Id -Force -ErrorAction SilentlyContinue
            throw "QEMU Guest Agent installer timed out"
        }
        # The timeout overload of WaitForExit returns a bool without refreshing
        # the cached process state, so ExitCode reads back as $null on Windows
        # PowerShell 5.1. $null -notin @(0, 3010) is true, which aborted the
        # whole guest setup on installs that had actually succeeded.
        $qgaInstall.WaitForExit()
        $qgaExit = $qgaInstall.ExitCode
        # The service existing is the outcome that matters. Only trust the exit
        # code to condemn the install when the service is genuinely absent.
        Start-Sleep -Seconds 2
        $qgaPresent = [bool](Get-Service qemu-ga -ErrorAction SilentlyContinue)
        if (-not $qgaPresent -and $qgaExit -notin @(0, 3010)) {
            throw "QEMU Guest Agent installer failed with exit code '$qgaExit' and no qemu-ga service"
        }
    }
    & sc.exe config qemu-ga start= delayed-auto depend= / | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Unable to configure QGA delayed start: $LASTEXITCODE" }
    & sc.exe failure qemu-ga reset= 0 actions= restart/5000/restart/10000/restart/30000 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Unable to configure QGA recovery actions: $LASTEXITCODE" }
    # Setup has no persistent host QGA client yet. Restarting here can leave
    # qemu-ga in START_PENDING; delayed auto-start binds on the next boot after
    # the provisioner has opened its persistent channel.

    # QEMU's slirp SMB bridge is isolated to this VM and exposes only the
    # exchange directory. Windows 11 24H2 blocks guest SMB by default, so scope
    # the compatibility exception to the workstation client and retry mapping
    # at login after the policy becomes active.
    $workstationPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation'
    $workstationParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'
    New-Item -Path $workstationPolicy -Force | Out-Null
    New-Item -Path $workstationParams -Force | Out-Null
    Set-ItemProperty -Path $workstationPolicy -Name AllowInsecureGuestAuth -Value 1 -Type DWord
    Set-ItemProperty -Path $workstationPolicy -Name RequireSecuritySignature -Value 0 -Type DWord
    Set-ItemProperty -Path $workstationParams -Name AllowInsecureGuestAuth -Value 1 -Type DWord

    $phaseZeroDir = Join-Path $env:ProgramData 'PhaseZero'
    $mapScriptPath = Join-Path $phaseZeroDir 'map-exchange.ps1'
    New-Item -Path $phaseZeroDir -ItemType Directory -Force | Out-Null
    @'
$ErrorActionPreference = 'SilentlyContinue'
$shareCandidates = @('\\10.0.2.4\qemu', '\\10.0.2.2\PZExchange')
$selectedPath = Join-Path $env:ProgramData 'PhaseZero\exchange-path.txt'
function Invoke-NetUse([string[]]$NetArgs) {
    $process = Start-Process net.exe -ArgumentList $NetArgs -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit(15000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        return 1460
    }
    return $process.ExitCode
}
Remove-Item -LiteralPath $selectedPath -Force -ErrorAction SilentlyContinue
if (Get-PSDrive -Name P -ErrorAction SilentlyContinue) {
    [void](Invoke-NetUse @('use', 'P:', '/delete', '/y'))
}
foreach ($share in $shareCandidates) {
    $mapResult = Invoke-NetUse @('use', 'P:', $share, '/persistent:yes')
    if ($mapResult -eq 0 -and (Test-Path 'P:\')) {
        Set-Content -LiteralPath $selectedPath -Value $share -Encoding ASCII
        exit 0
    }
    [void](Invoke-NetUse @('use', 'P:', '/delete', '/y'))
}
exit 1
'@ | Set-Content -Path $mapScriptPath -Encoding UTF8
    $runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    $mapCommand = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mapScriptPath`""
    Set-ItemProperty -Path $runKey -Name PhaseZeroMapExchange -Value $mapCommand -Type String
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mapScriptPath
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "PhaseZero exchange mapping deferred until next login"
    }

    powercfg.exe /setactive SCHEME_MIN | Out-Host
    powercfg.exe /change standby-timeout-ac 0 | Out-Host
    powercfg.exe /change hibernate-timeout-ac 0 | Out-Host
    powercfg.exe /hibernate off | Out-Host

    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -Value 1 -Type DWord
    Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue

    $guestLoginPayload = Join-Path $PSScriptRoot 'guest-login.json'
    $guestLoginScript = Join-Path $PSScriptRoot 'guest-login.ps1'
    $guestLoginConfig = Get-Content -LiteralPath $guestLoginPayload -Raw | ConvertFrom-Json
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $guestLoginScript `
        -Mode $guestLoginConfig.mode -UserName $guestLoginConfig.username -InputPath $guestLoginPayload
    if ($LASTEXITCODE -ne 0) { throw "PhaseZero guest login policy failed" }
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $guestLoginScript `
        -Mode touch-input -UserName $guestLoginConfig.username
    if ($LASTEXITCODE -ne 0) { throw "PhaseZero touch-input policy failed" }
    Write-Host "PhaseZero: guest login policy applied without registry plaintext password"

    $selectedExchange = Get-Content (Join-Path $phaseZeroDir 'exchange-path.txt') -ErrorAction SilentlyContinue | Select-Object -First 1

    @{
        success = $true
        completedAt = (Get-Date).ToUniversalTime().ToString('o')
        qgaService = [bool](Get-Service qemu-ga -ErrorAction SilentlyContinue)
        exchangePath = $selectedExchange
    } | ConvertTo-Json | Set-Content -Path (Join-Path $phaseZeroDir 'provisioning-complete.json') -Encoding UTF8
} catch {
    # Write-Error is itself a terminating error while ErrorActionPreference is
    # Stop, so it aborted the rest of this handler: the guest never powered off
    # and the host burned the full two hour setup timeout on every failure,
    # while the autologin teardown below silently never ran either.
    $ErrorActionPreference = 'Continue'
    Write-Host "PhaseZero guest setup failed: $($_.Exception.Message)"
    $failureDir = Join-Path $env:ProgramData 'PhaseZero'
    New-Item -Path $failureDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    $_.Exception.Message | Set-Content -Path (Join-Path $failureDir 'provisioning-failed.txt') -Encoding UTF8 -ErrorAction SilentlyContinue
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
    Stop-Transcript
    shutdown.exe /s /t 10 /c "PhaseZero unattended setup failed"
    exit 1
}

Write-Host "PhaseZero: post-install setup complete"
Stop-Transcript
shutdown.exe /s /t 10 /c "PhaseZero unattended setup complete"
PSEOF
    chmod 0600 "$inject_script"

    local oemdrv_iso="$vm_dir/oemdrv.iso"
    if command -v genisoimage >/dev/null 2>&1; then
        genisoimage -J -R -V OEMDRV -o "$oemdrv_iso" "$answer_dir" 2>/dev/null || \
            { log_operation "$op" "FAIL: genisoimage failed to create OEMDRV ISO"; return 1; }
    elif command -v xorriso >/dev/null 2>&1; then
        xorriso -as mkisofs -J -R -V OEMDRV -o "$oemdrv_iso" "$answer_dir" 2>/dev/null || \
            { log_operation "$op" "FAIL: xorriso failed to create OEMDRV ISO"; return 1; }
    else
        log_operation "$op" "FAIL: no ISO creation tool (genisoimage or xorriso)"
        return 1
    fi
    [ -f "$oemdrv_iso" ] || { log_operation "$op" "FAIL: OEMDRV ISO not created"; return 1; }

    log_operation "$op" "answer file generated, OEMDRV ISO created"
    return 0
}

# windows-vm.sh marks the VM directory nodatacow before it creates an image,
# because QEMU opens the disk with cache=none and a copy-on-write, checksummed
# btrfs file fails its own checksum on readback under O_DIRECT and returns EIO
# to the guest mid-write. This path creates images too and never did it, so a
# VM provisioned here got none of that protection - the guard existed and
# simply was not on this road. The log line matters: the previous version
# warned into a void, so a failed chattr looked identical to a successful one.
provision_mark_nodatacow() {
    local op="$1" vm_dir="$2" fstype
    [ -d "$vm_dir" ] || return 0
    command -v chattr >/dev/null 2>&1 || {
        log_operation "$op" "nodatacow skipped: chattr unavailable"
        return 0
    }
    fstype="$(stat -f -c %T "$vm_dir" 2>/dev/null || true)"
    [ "$fstype" = "btrfs" ] || return 0
    if chattr +C "$vm_dir" 2>/dev/null; then
        log_operation "$op" "btrfs: $vm_dir marked nodatacow before disk creation"
    else
        log_operation "$op" "WARNING: could not set nodatacow on $vm_dir; image stays copy-on-write and may hit EIO under O_DIRECT"
    fi
}

run_disk() {
    local op="$1"
    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local disk_path="$vm_dir/disk.qcow2"
    if [ -f "$disk_path" ]; then
        log_operation "$op" "disk already exists; skipping creation"
        return 0
    fi
    local disk_size
    disk_size="$(jq -r '.resources.diskSize // "256G"' "$plan_file")"
    log_operation "$op" "creating disk: $disk_path ($disk_size)"
    provision_mark_nodatacow "$op" "$vm_dir"
    qemu-img create -f qcow2 "$disk_path" "$disk_size"
    log_operation "$op" "disk created"
    return 0
}

run_setup() {
    local op="$1"
    log_operation "$op" "starting Windows setup"
    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local disk_path="$vm_dir/disk.qcow2"
    local oemdrv_iso="$vm_dir/oemdrv.iso"
    local iso
    iso="$(jq -r '.iso.path' "$plan_file")"
    local ram cpus exchange_dir netdev_arg
    ram="$(jq -r '.resources.ramMb // 8192' "$plan_file")"
    cpus="$(jq -r '.resources.cpus // 4' "$plan_file")"
    exchange_dir="${PZ_WINDOWS_VM_EXCHANGE_DIR:-$HOME/Shared/WindowsVM}"
    mkdir -p "$exchange_dir"
    netdev_arg="user,id=net0"
    command -v smbd >/dev/null 2>&1 && netdev_arg="$netdev_arg,smb=$exchange_dir"

    local ovmf_code ovmf_vars
    ovmf_code="$(provision_ovmf_code)"
    ovmf_vars="$vm_dir/OVMF_VARS.fd"
    if [ ! -f "$ovmf_vars" ]; then
        local vars_template
        vars_template="$(pz_path_resolve ovmf_vars_template \
            /usr/share/edk2/x64/OVMF_VARS.4m.fd \
            /usr/share/OVMF/OVMF_VARS.fd 2>/dev/null || true)"
        [ -n "$vars_template" ] && cp "$vars_template" "$ovmf_vars"
    fi

    [ -f "$ovmf_code" ] || { log_operation "$op" "OVMF code not found"; return 1; }
    [ -f "$oemdrv_iso" ] || { log_operation "$op" "OEMDRV ISO not found"; return 1; }

    local -a tpm_args=()
    mapfile -t tpm_args < <(provision_tpm_args "$vm_dir" "$op") || {
        log_operation "$op" "FAIL: TPM 2.0 unavailable; Windows 11 setup cannot proceed"
        return 1
    }

    # shellcheck disable=SC2054
    local qemu_args=(
        -machine q35,accel=kvm
        -cpu host
        -smp "$cpus"
        -m "$ram"
        -drive file="$ovmf_code",if=pflash,format=raw,readonly=on
        -drive file="$ovmf_vars",if=pflash,format=raw
        -boot once=d
        -drive file="$disk_path",format=qcow2,if=none,id=drive0
        -device "nvme,serial=$DISK_SERIAL,drive=drive0"
        -drive file="$iso",format=raw,if=none,id=isoboot,readonly=on
        -device ide-cd,bus=ide.0,drive=isoboot
        -drive file="$oemdrv_iso",format=raw,if=none,id=oemdrv,readonly=on
        -device ide-cd,bus=ide.1,drive=oemdrv
        -netdev "$netdev_arg"
        -device e1000e,netdev=net0
        -device virtio-serial-pci,id=virtio-serial0
        -vga qxl
        -display none
        -nographic
        -serial file:"$vm_dir/setup-serial.log"
        -qmp "unix:$vm_dir/setup-qmp.sock,server=on,wait=off"
        -chardev socket,path="$vm_dir/qga.sock",server=on,wait=off,id=qga0
        -device virtserialport,bus=virtio-serial0.0,nr=1,chardev=qga0,name=org.qemu.guest_agent.0
    )

    if [ -f "$vm_dir/virtio-win.iso" ]; then
        # shellcheck disable=SC2054
        qemu_args+=(-drive file="$vm_dir/virtio-win.iso",format=raw,if=none,id=virtio)
        # shellcheck disable=SC2054
        qemu_args+=(-device ide-cd,bus=ide.2,drive=virtio)
    fi

    qemu_args+=("${tpm_args[@]}")

    log_operation "$op" "launching QEMU for Windows setup (TPM 2.0 + Secure Boot firmware)"
    mkdir -p "$vm_dir"
    rm -f "$vm_dir/qga.sock" "$vm_dir/setup-qmp.sock"
    if [ "$LOCK_FD" -ge 0 ] 2>/dev/null; then
        qemu-system-x86_64 "${qemu_args[@]}" {LOCK_FD}>&- &
    else
        qemu-system-x86_64 "${qemu_args[@]}" &
    fi
    local qemu_pid=$!
    echo "$qemu_pid" > "$vm_dir/qemu-pid"

    # Microsoft install media prompts for a key before booting from CD. The
    # unattended answer file cannot run until that prompt is accepted. The
    # helper presses the key across the whole prompt window: a fixed burst of
    # three presses missed it on real hardware (BdsDxe started the DVD entry,
    # timed out untouched, and the install stalled in a boot-manager loop).
    if command -v python3 >/dev/null 2>&1; then
        local monitor_sock="$vm_dir/setup-qmp.sock" monitor_try
        for monitor_try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
            [ -S "$monitor_sock" ] && break
            sleep 0.1
        done
        if [ -S "$monitor_sock" ]; then
            if python3 "$PZ_ROOT/linux/windows-vm/setup-boot-prompt.py" "$monitor_sock"; then
                log_operation "$op" "Windows ISO boot prompt acknowledged"
            else
                log_operation "$op" "WARN: could not acknowledge Windows ISO boot prompt"
            fi
        else
            log_operation "$op" "WARN: setup monitor socket unavailable; ISO boot prompt may require manual input"
        fi
    fi

    local timeout=7200 interval=30 elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        kill -0 "$qemu_pid" 2>/dev/null || { log_operation "$op" "QEMU exited after ${elapsed}s"; break; }
        sleep "$interval"
        elapsed=$((elapsed + interval))
        if [ $((elapsed % 300)) -eq 0 ]; then
            log_operation "$op" "setup running for ${elapsed}s ($((elapsed / 60))min)"
        fi
    done

    if kill -0 "$qemu_pid" 2>/dev/null; then
        log_operation "$op" "setup timeout reached (${timeout}s); killing QEMU"
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi

    rm -f "$vm_dir/qemu-pid"
    # swtpm is --daemon and outlives QEMU; leaving it holding the state
    # directory makes the next phase inherit a live TPM it did not create.
    provision_tpm_stop
    local installed_bytes=0
    installed_bytes="$(qemu-img info --output=json "$disk_path" 2>/dev/null | jq -r '."actual-size" // 0' 2>/dev/null || echo 0)"
    if [ "${installed_bytes:-0}" -lt $((1024 * 1024 * 1024)) ]; then
        log_operation "$op" "FAIL: Windows setup exited without installed payload (${installed_bytes:-0} bytes allocated)"
        return 1
    fi
    log_operation "$op" "Windows setup phase complete"
    return 0
}

run_drivers() {
    local op="$1"
    log_operation "$op" "installing VirtIO drivers via QEMU Guest Agent"
    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local disk_path="$vm_dir/disk.qcow2"
    local qga_sock="$vm_dir/qga.sock"
    local qmp_sock="$vm_dir/drivers-qmp.sock"

    if [ ! -f "$vm_dir/virtio-win.iso" ]; then
        log_operation "$op" "no VirtIO ISO; skipping driver injection"
        return 0
    fi

    local ram cpus exchange_dir netdev_arg
    ram="$(jq -r '.resources.ramMb // 8192' "$plan_file")"
    cpus="$(jq -r '.resources.cpus // 4' "$plan_file")"
    exchange_dir="${PZ_WINDOWS_VM_EXCHANGE_DIR:-$HOME/Shared/WindowsVM}"
    mkdir -p "$exchange_dir"
    netdev_arg="user,id=net0"
    command -v smbd >/dev/null 2>&1 && netdev_arg="$netdev_arg,smb=$exchange_dir"
    local ovmf_code="$(provision_ovmf_code)"
    local ovmf_vars="$vm_dir/OVMF_VARS.fd"
    [ -f "$ovmf_code" ] || { log_operation "$op" "OVMF code not found"; return 1; }

    rm -f "$qga_sock" "$qmp_sock"

    # shellcheck disable=SC2054
    local qemu_args=(
        -machine q35,accel=kvm -cpu host -smp "$cpus" -m "$ram"
        -drive file="$ovmf_code",if=pflash,format=raw,readonly=on
        -drive file="$ovmf_vars",if=pflash,format=raw
        -drive file="$disk_path",format=qcow2,if=none,id=drive0
        -device "nvme,serial=$DISK_SERIAL,drive=drive0"
        -drive file="$vm_dir/virtio-win.iso",format=raw,if=none,id=virtio,readonly=on
        -device ide-cd,drive=virtio
        -netdev "$netdev_arg" -device e1000e,netdev=net0
        -device virtio-serial-pci,id=virtio-serial0
        -vga qxl -display none -nographic
        -serial file:"$vm_dir/drivers-serial.log"
        -qmp unix:"$qmp_sock",server=on,wait=off
        -chardev socket,path="$qga_sock",server=on,wait=off,id=qga0
        -device virtserialport,bus=virtio-serial0.0,nr=1,chardev=qga0,name=org.qemu.guest_agent.0
    )

    log_operation "$op" "launching QEMU for driver installation"
    if [ "$LOCK_FD" -ge 0 ] 2>/dev/null; then
        qemu-system-x86_64 "${qemu_args[@]}" {LOCK_FD}>&- &
    else
        qemu-system-x86_64 "${qemu_args[@]}" &
    fi
    local qemu_pid=$!
    echo "$qemu_pid" > "$vm_dir/drivers-qemu-pid"

    local qga_ok=0
    local timeout=300 interval=5 elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        kill -0 "$qemu_pid" 2>/dev/null || break
        if [ -S "$qga_sock" ] && qga_ping "$qga_sock"; then
            qga_ok=1
            log_operation "$op" "QEMU Guest Agent ready after ${elapsed}s"
            break
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    if [ "$qga_ok" = "1" ]; then
        local ps_script
        ps_script=$(cat << 'PSEOF'
$ErrorActionPreference = 'Stop'
$d = $null
foreach ($code in 68..90) {
    $candidate = ([char]$code) + ':'
    if (Test-Path "$candidate\vioserial") { $d = $candidate; break }
}
if (-not $d) { throw 'VirtIO media not mounted on D: through Z:' }
$driverPaths = @(
    'NetKVM\w11\amd64\netkvm.inf',
    'viogpudo\w11\amd64\viogpudo.inf',
    'Balloon\w11\amd64\balloon.inf',
    'viorng\w11\amd64\viorng.inf',
    'vioscsi\w11\amd64\vioscsi.inf',
    'vioinput\w11\amd64\vioinput.inf',
    'vioserial\w11\amd64\vioser.inf'
)
Write-Host "Installing targeted Windows 11 AMD64 VirtIO INF packages from $d"
foreach ($relativeDriver in $driverPaths) {
    $driverPath = Join-Path $d $relativeDriver
    if (-not (Test-Path $driverPath)) { throw "Required VirtIO driver missing: $relativeDriver" }
    & pnputil.exe /add-driver $driverPath /install
    if ($LASTEXITCODE -notin @(0, 259)) { throw "VirtIO driver failed ($LASTEXITCODE): $relativeDriver" }
}
$qga = Get-Service qemu-ga -ErrorAction SilentlyContinue
if (-not $qga) { throw 'QEMU Guest Agent service missing after driver installation' }
& sc.exe config qemu-ga start= auto depend= / | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Unable to promote QGA automatic start: $LASTEXITCODE" }
& sc.exe failure qemu-ga reset= 0 actions= restart/5000/restart/10000/restart/30000 | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Unable to configure QGA recovery actions: $LASTEXITCODE" }
if ($qga.Status -ne 'Running') { Start-Service qemu-ga }
Write-Host 'VirtIO INF installation complete; QGA service verified'
PSEOF
)
        local qga_json
        qga_json=$(jq -n --arg ps "$ps_script" '{
            "execute": "guest-exec",
            "arguments": {
                "path": "powershell.exe",
                "arg": ["-Command", $ps],
                "capture-output": true
            }
        }')
        local exec_result
        qga_exec "$qga_sock" "$qga_json" || true
        exec_result="$QGA_RESPONSE"
        local pid
        pid="$(echo "$exec_result" | jq -r '.return.pid // 0')"
        local driver_ok=0
        if [ "$pid" -gt 0 ]; then
            log_operation "$op" "driver install guest-exec PID: $pid"
            local wait_timeout=600 wait_started=$SECONDS wait_deadline=$((SECONDS + 600))
            while [ "$SECONDS" -lt "$wait_deadline" ]; do
                local status_result
                qga_exec "$qga_sock" '{"execute":"guest-exec-status","arguments":{"pid":'"$pid"'}}' || true
                status_result="$QGA_RESPONSE"
                local exited
                exited="$(echo "$status_result" | jq -r '.return.exited // false')"
                if [ "$exited" = "true" ]; then
                    local exitcode
                    exitcode="$(echo "$status_result" | jq -r '.return.exitcode // -1')"
                    log_operation "$op" "driver install exit code: $exitcode"
                    local driver_stdout driver_stderr
                    driver_stdout="$(echo "$status_result" | jq -r '.["return"]["out-data"] // ""' | base64 -d 2>/dev/null || true)"
                    driver_stderr="$(echo "$status_result" | jq -r '.["return"]["err-data"] // ""' | base64 -d 2>/dev/null || true)"
                    [ -n "$driver_stdout" ] && log_operation "$op" "driver install output: $(printf '%s' "$driver_stdout" | tr '\n\r' '  ')"
                    [ -n "$driver_stderr" ] && log_operation "$op" "driver install error: $(printf '%s' "$driver_stderr" | tr '\n\r' '  ')"
                    [ "$exitcode" = "0" ] && driver_ok=1
                    break
                fi
                sleep 5
            done
            local wait_elapsed=$((SECONDS - wait_started))
            [ "$driver_ok" = "1" ] || log_operation "$op" "FAIL: VirtIO INF installation failed or timed out after ${wait_timeout}s"
        else
            # The rejection reason lives in the QGA response and was being
            # discarded, leaving only a generic failure line to debug from.
            log_operation "$op" "FAIL: QGA rejected driver installation command: $(printf '%s' "${exec_result:-<empty response>}" | tr '\n\r' '  ' | cut -c1-400)"
        fi

        if [ "$driver_ok" != "1" ]; then
            qga_channel_close
            kill "$qemu_pid" 2>/dev/null || true
            wait "$qemu_pid" 2>/dev/null || true
            rm -f "$vm_dir/drivers-qemu-pid"
            return 1
        fi

        # Post-driver display adapter check
        local check_qga
        check_qga=$(jq -n '{
            "execute": "guest-exec",
            "arguments": {
                "path": "powershell.exe",
                "arg": ["-Command", "(Get-PnpDevice -Class Display).Name"],
                "capture-output": true
            }
        }')
        local check_result
        qga_exec "$qga_sock" "$check_qga" || true
        check_result="$QGA_RESPONSE"
        local check_pid
        check_pid="$(echo "$check_result" | jq -r '.return.pid // 0')"
        if [ "$check_pid" -gt 0 ]; then
            sleep 5
            local check_status
            qga_exec "$qga_sock" '{"execute":"guest-exec-status","arguments":{"pid":'"$check_pid"'}}' || true
            check_status="$QGA_RESPONSE"
            local check_exited
            check_exited="$(echo "$check_status" | jq -r '.return.exited // false')"
            if [ "$check_exited" = "true" ]; then
                local check_stdout
                check_stdout="$(echo "$check_status" | jq -r '.["return"]["out-data"] // ""' | base64 -d 2>/dev/null || true)"
                if echo "$check_stdout" | grep -i "Microsoft Basic Display" >/dev/null; then
                    log_operation "$op" "WARN: guest still on Microsoft Basic Display Adapter after driver install"
                else
                    log_operation "$op" "guest display adapter: $(echo "$check_stdout" | tr -d '\n\r')"
                fi
            fi
        fi

        qga_shutdown "$qga_sock"
        sleep 2
        qga_channel_close
        sleep 8
    else
        local reason="QGA not available after ${timeout}s"
        [ "$HAVE_SOCAT" != "1" ] && reason="socat not installed (needed for QGA communication)"
        log_operation "$op" "FAIL: $reason; unattended guest setup incomplete"
        qga_channel_close
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        rm -f "$vm_dir/drivers-qemu-pid"
        return 1
    fi

    qga_channel_close
    wait "$qemu_pid" 2>/dev/null || true
    rm -f "$vm_dir/drivers-qemu-pid"
    log_operation "$op" "driver installation phase complete"
    return 0
}

run_tweaks() {
    local op="$1"
    log_operation "$op" "applying performance-safe tweaks via QEMU Guest Agent"
    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local disk_path="$vm_dir/disk.qcow2"
    local qga_sock="$vm_dir/qga.sock"
    local qmp_sock="$vm_dir/tweaks-qmp.sock"

    local ram cpus exchange_dir netdev_arg
    ram="$(jq -r '.resources.ramMb // 8192' "$plan_file")"
    cpus="$(jq -r '.resources.cpus // 4' "$plan_file")"
    exchange_dir="${PZ_WINDOWS_VM_EXCHANGE_DIR:-$HOME/Shared/WindowsVM}"
    mkdir -p "$exchange_dir"
    netdev_arg="user,id=net0"
    command -v smbd >/dev/null 2>&1 && netdev_arg="$netdev_arg,smb=$exchange_dir"
    local ovmf_code="$(provision_ovmf_code)"
    local ovmf_vars="$vm_dir/OVMF_VARS.fd"
    [ -f "$ovmf_code" ] || { log_operation "$op" "OVMF code not found"; return 1; }

    rm -f "$qga_sock" "$qmp_sock"

    # shellcheck disable=SC2054
    local qemu_args=(
        -machine q35,accel=kvm -cpu host -smp "$cpus" -m "$ram"
        -drive file="$ovmf_code",if=pflash,format=raw,readonly=on
        -drive file="$ovmf_vars",if=pflash,format=raw
        -drive file="$disk_path",format=qcow2,if=none,id=drive0
        -device "nvme,serial=$DISK_SERIAL,drive=drive0"
        -netdev "$netdev_arg" -device e1000e,netdev=net0
        -device virtio-serial-pci,id=virtio-serial0
        -vga qxl -display none -nographic
        -serial file:"$vm_dir/tweaks-serial.log"
        -qmp unix:"$qmp_sock",server=on,wait=off
        -chardev socket,path="$qga_sock",server=on,wait=off,id=qga0
        -device virtserialport,bus=virtio-serial0.0,nr=1,chardev=qga0,name=org.qemu.guest_agent.0
    )

    log_operation "$op" "launching QEMU for tweaks"
    if [ "$LOCK_FD" -ge 0 ] 2>/dev/null; then
        qemu-system-x86_64 "${qemu_args[@]}" {LOCK_FD}>&- &
    else
        qemu-system-x86_64 "${qemu_args[@]}" &
    fi
    local qemu_pid=$!
    echo "$qemu_pid" > "$vm_dir/tweaks-qemu-pid"

    local qga_ok=0
    local timeout=300 interval=5 elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        kill -0 "$qemu_pid" 2>/dev/null || break
        if [ -S "$qga_sock" ] && qga_ping "$qga_sock"; then
            qga_ok=1
            log_operation "$op" "QEMU Guest Agent ready after ${elapsed}s"
            break
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    if [ "$qga_ok" = "1" ]; then
        local tweaks_json
        tweaks_json="$(bash "$PZ_ROOT/linux/windows-vm/tweaks.sh" apply 2>/dev/null || echo '[]')"
        echo "$tweaks_json" > "$vm_dir/tweaks-manifest.json"

        local tweaks_script
        tweaks_script=$(cat << 'PSEOF'
$ErrorActionPreference = 'Stop'
$optionalWarnings = [System.Collections.Generic.List[string]]::new()
& sc.exe config qemu-ga start= auto depend= / | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Unable to promote QGA automatic start: $LASTEXITCODE" }
Get-AppxPackage -AllUsers -Name '*Xbox*' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop
    } catch {
        $optionalWarnings.Add("Xbox package retained: $($_.Exception.Message)")
    }
}
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /h off
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name EnableLUA -Value 1 -Type DWord
Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
$lanman = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'
New-Item -Path $lanman -Force | Out-Null
New-ItemProperty -Path $lanman -Name AllowInsecureGuestAuth -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $lanman -Name RequireSecuritySignature -PropertyType DWord -Value 0 -Force | Out-Null
$workstationDll = (Get-ItemProperty -Path $lanman -Name ServiceDll -ErrorAction SilentlyContinue).ServiceDll
if (-not $workstationDll -or -not (Test-Path ([Environment]::ExpandEnvironmentVariables($workstationDll)))) {
    New-ItemProperty -Path $lanman -Name ServiceDll -PropertyType ExpandString -Value '%SystemRoot%\System32\wkssvc.dll' -Force | Out-Null
    New-ItemProperty -Path $lanman -Name ServiceDllUnloadOnStop -PropertyType DWord -Value 1 -Force | Out-Null
    $optionalWarnings.Add('LanmanWorkstation ServiceDll registry repaired')
}
$workstation = Get-Service LanmanWorkstation -ErrorAction Stop
if ($workstation.Status -ne 'Running') {
    Start-Service LanmanWorkstation -ErrorAction Stop
}
Start-Sleep -Seconds 2
$phaseZeroDir = Join-Path $env:ProgramData 'PhaseZero'
New-Item -ItemType Directory -Path $phaseZeroDir -Force | Out-Null
$mapScript = Join-Path $phaseZeroDir 'map-exchange.ps1'
@'
$ErrorActionPreference = 'SilentlyContinue'
$shareCandidates = @('\\10.0.2.4\qemu', '\\10.0.2.2\PZExchange')
$selectedPath = Join-Path $env:ProgramData 'PhaseZero\exchange-path.txt'
function Invoke-NetUse([string[]]$NetArgs) {
    $process = Start-Process net.exe -ArgumentList $NetArgs -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit(15000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        return 1460
    }
    return $process.ExitCode
}
Remove-Item -LiteralPath $selectedPath -Force -ErrorAction SilentlyContinue
if (Get-PSDrive -Name P -ErrorAction SilentlyContinue) {
    [void](Invoke-NetUse @('use', 'P:', '/delete', '/y'))
}
foreach ($share in $shareCandidates) {
    $mapResult = Invoke-NetUse @('use', 'P:', $share, '/persistent:yes')
    if ($mapResult -eq 0 -and (Test-Path 'P:\')) {
        Set-Content -LiteralPath $selectedPath -Value $share -Encoding ASCII
        exit 0
    }
    [void](Invoke-NetUse @('use', 'P:', '/delete', '/y'))
}
exit 1
'@ | Set-Content -Path $mapScript -Encoding UTF8
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name PhaseZeroMapExchange -PropertyType String -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$mapScript`"" -Force | Out-Null
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mapScript
$exchangePath = [string](Get-Content (Join-Path $phaseZeroDir 'exchange-path.txt') -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $exchangePath -or -not (Test-Path 'P:\')) { throw 'PhaseZero exchange share unavailable on built-in and host SMB endpoints' }
$exchangeHost = ($exchangePath -split '\\')[2]
if (-not (Test-NetConnection $exchangeHost -Port 445 -InformationLevel Quiet)) { throw "SMB endpoint $exchangeHost`:445 unreachable" }
$adapter = Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1
if (-not $adapter) { throw 'No active Windows network adapter' }
$display = (Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FriendlyName)
$marker = [ordered]@{
    completedAt = (Get-Date).ToUniversalTime().ToString('o')
    networkAdapter = $adapter.Name
    exchangePath = $exchangePath
    exchangeDrive = 'P:'
    displayAdapters = @($display)
    qgaService = (Get-Service qemu-ga -ErrorAction Stop).Status.ToString()
    optionalWarnings = @($optionalWarnings)
}
$marker | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $phaseZeroDir 'provisioning-complete.json') -Encoding UTF8
PSEOF
)

        local tweaks_qga
        tweaks_qga=$(jq -n --arg ps "$tweaks_script" '{
            "execute": "guest-exec",
            "arguments": {
                "path": "powershell.exe",
                "arg": ["-Command", $ps],
                "capture-output": true
            }
        }')
        local exec_result
        qga_exec "$qga_sock" "$tweaks_qga" || true
        exec_result="$QGA_RESPONSE"
        local pid
        pid="$(echo "$exec_result" | jq -r '.return.pid // 0')"
        local tweaks_ok=0
        if [ "$pid" -gt 0 ]; then
            log_operation "$op" "tweaks guest-exec PID: $pid"
            local wait_timeout=300 wait_started=$SECONDS wait_deadline=$((SECONDS + 300))
            while [ "$SECONDS" -lt "$wait_deadline" ]; do
                local status_result
                qga_exec "$qga_sock" '{"execute":"guest-exec-status","arguments":{"pid":'"$pid"'}}' || true
                status_result="$QGA_RESPONSE"
                local exited
                exited="$(echo "$status_result" | jq -r '.return.exited // false')"
                if [ "$exited" = "true" ]; then
                    local exitcode
                    exitcode="$(echo "$status_result" | jq -r '.return.exitcode // -1')"
                    log_operation "$op" "tweaks exit code: $exitcode"
                    local tweaks_stdout tweaks_stderr
                    tweaks_stdout="$(echo "$status_result" | jq -r '.["return"]["out-data"] // ""' | base64 -d 2>/dev/null || true)"
                    tweaks_stderr="$(echo "$status_result" | jq -r '.["return"]["err-data"] // ""' | base64 -d 2>/dev/null || true)"
                    [ -n "$tweaks_stdout" ] && log_operation "$op" "tweaks output: $(printf '%s' "$tweaks_stdout" | tr '\n\r' '  ')"
                    [ -n "$tweaks_stderr" ] && log_operation "$op" "tweaks error: $(printf '%s' "$tweaks_stderr" | tr '\n\r' '  ')"
                    [ "$exitcode" = "0" ] && tweaks_ok=1
                    break
                fi
                sleep 5
            done
        else
            log_operation "$op" "FAIL: QGA rejected tweaks command"
        fi
        if [ "$tweaks_ok" != "1" ]; then
            log_operation "$op" "FAIL: Windows optimization/share verification failed or timed out"
            qga_channel_close
            kill "$qemu_pid" 2>/dev/null || true
            wait "$qemu_pid" 2>/dev/null || true
            rm -f "$vm_dir/tweaks-qemu-pid"
            return 1
        fi
        qga_shutdown "$qga_sock"
        sleep 2
        qga_channel_close
        sleep 8
    else
        local reason="QGA not available after ${timeout}s"
        [ "$HAVE_SOCAT" != "1" ] && reason="socat not installed (needed for QGA communication)"
        log_operation "$op" "FAIL: $reason; performance-safe tweaks not verified"
        qga_channel_close
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        rm -f "$vm_dir/tweaks-qemu-pid"
        return 1
    fi

    qga_channel_close
    wait "$qemu_pid" 2>/dev/null || true
    rm -f "$vm_dir/tweaks-qemu-pid"
    log_operation "$op" "tweaks phase complete"
    return 0
}

run_verify() {
    local op="$1"
    log_operation "$op" "verifying installation"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local disk_path="$vm_dir/disk.qcow2"

    if [ ! -f "$disk_path" ]; then
        log_operation "$op" "FAIL: disk not found at $disk_path"
        return 1
    fi

    local disk_size
    disk_size="$(stat -c%s "$disk_path" 2>/dev/null || echo 0)"
    if [ "$disk_size" -lt 104857600 ]; then
        log_operation "$op" "FAIL: disk too small (${disk_size}B), likely empty"
        return 1
    fi

    log_operation "$op" "disk verified: $(numfmt --to=iec "$disk_size" 2>/dev/null || echo "${disk_size}B")"
    return 0
}

run_snapshot() {
    local op="$1"
    log_operation "$op" "creating golden-clean snapshot (backing-chain)"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local disk_path="$vm_dir/disk.qcow2"
    local snapshot_path="$vm_dir/golden-clean.qcow2"

    [ -f "$disk_path" ] || { log_operation "$op" "FAIL: installed disk not found"; return 1; }

    rm -f "$snapshot_path"
    qemu-img create -f qcow2 -b "$disk_path" -F qcow2 "$snapshot_path"
    [ -f "$snapshot_path" ] || { log_operation "$op" "FAIL: snapshot not created"; return 1; }

    qemu-img check "$snapshot_path" >/dev/null 2>&1 || \
        { log_operation "$op" "FAIL: snapshot verification failed"; return 1; }

    echo "$snapshot_path" > "$OPERATIONS_DIR/$op/snapshot_path"
    log_operation "$op" "golden-clean snapshot: $snapshot_path (backed by installed disk)"
    return 0
}

run_relaunch() {
    local op="$1"
    local vm_dir vm_dir_file="$OPERATIONS_DIR/$op/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local snapshot_path="$vm_dir/golden-clean.qcow2"
    local disk_path="$vm_dir/disk.qcow2"
    local boot_disk="$disk_path"
    [ -f "$snapshot_path" ] && boot_disk="$snapshot_path"

    local ram cpus exchange_dir netdev_arg
    local plan_file="$OPERATIONS_DIR/$op/plan.json"
    ram="$(jq -r '.resources.ramMb // 8192' "$plan_file")"
    cpus="$(jq -r '.resources.cpus // 4' "$plan_file")"
    exchange_dir="${PZ_WINDOWS_VM_EXCHANGE_DIR:-$HOME/Shared/WindowsVM}"
    mkdir -p "$exchange_dir"
    netdev_arg="user,id=net0"
    command -v smbd >/dev/null 2>&1 && netdev_arg="$netdev_arg,smb=$exchange_dir"
    local graphics
    graphics="${PZ_RELAUNCH_GRAPHICS_OVERRIDE:-$(jq -r '.graphics // "compat"' "$plan_file")}"

    local ovmf_code ovmf_vars
    ovmf_code="$(provision_ovmf_code)"
    ovmf_vars="$vm_dir/OVMF_VARS.fd"

    [ -f "$ovmf_code" ] || { log_operation "$op" "OVMF code not found for relaunch"; return 1; }
    [ -f "$boot_disk" ] || { log_operation "$op" "boot disk not found for relaunch"; return 1; }

    local -a graphics_vga_args=() graphics_display_args=()
    GRAPHICS_VGA=""; GRAPHICS_DISPLAY=""; GRAPHICS_ACCEL_LOG=""
    case "$graphics" in
        compat)
            GRAPHICS_VGA="-vga qxl"
            GRAPHICS_DISPLAY="-display gtk"
            graphics_vga_args=(-vga qxl)
            graphics_display_args=(-display gtk)
            GRAPHICS_ACCEL_LOG="GPU acceleration: NONE (QXL)"
            ;;
        virtio-gl)
            GRAPHICS_VGA="-device virtio-vga-gl"
            GRAPHICS_DISPLAY="-display gtk,gl=on"
            graphics_vga_args=(-device virtio-vga-gl)
            # shellcheck disable=SC2054 # gtk,gl=on is one QEMU argument, not array syntax
            graphics_display_args=(-display gtk,gl=on)
            GRAPHICS_ACCEL_LOG="GPU acceleration: virgl (OpenGL only; no Vulkan/D3D)"
            ;;
        *)
            log_operation "$op" "FAIL: unknown graphics profile: $graphics"
            return 1
            ;;
    esac
    resolve_graphics_qemu_args "$op" "$graphics" || return 1

    # shellcheck disable=SC2054
    local qemu_args=(
        -machine q35,accel=kvm
        -cpu host
        -smp "$cpus"
        -m "$ram"
        -drive file="$ovmf_code",if=pflash,format=raw,readonly=on
        -drive file="$ovmf_vars",if=pflash,format=raw
        -drive file="$boot_disk",format=qcow2,if=none,id=drive0
        -device "nvme,serial=$DISK_SERIAL,drive=drive0"
        -netdev "$netdev_arg"
        -device virtio-net-pci,netdev=net0
        -device virtio-serial-pci,id=virtio-serial0
        -device ich9-usb-ehci1
        -device ich9-usb-uhci1
        -device usb-tablet
        -device usb-kbd
        -serial file:"$vm_dir/relaunch-serial.log"
        -qmp unix:"$vm_dir/relaunch-qmp.sock",server=on,wait=off
    )

    qemu_args+=("${graphics_vga_args[@]}")
    qemu_args+=("${graphics_display_args[@]}")
    if [ "$graphics" = "compat" ]; then
        # shellcheck disable=SC2054
        qemu_args+=(-chardev spicevmc,id=vdagent,name=vdagent)
        # shellcheck disable=SC2054
        qemu_args+=(-device virtserialport,bus=virtio-serial0.0,nr=2,chardev=vdagent,name=com.redhat.spice.0)
        # shellcheck disable=SC2054
        qemu_args+=(-spice port=5930,addr=127.0.0.1,disable-ticketing=on)
    else
        log_operation "$op" "SPICE disabled for virtio-gl: QEMU GL context uses GTK directly"
    fi
    # shellcheck disable=SC2054
    qemu_args+=(-chardev socket,path="$vm_dir/qga.sock",server=on,wait=off,id=qga0)
    # shellcheck disable=SC2054
    qemu_args+=(-device virtserialport,bus=virtio-serial0.0,nr=1,chardev=qga0,name=org.qemu.guest_agent.0)

    log_operation "$op" "$GRAPHICS_ACCEL_LOG"
    log_operation "$op" "relaunching with display (disk=$boot_disk, graphics=$graphics)"
    rm -f "$vm_dir/qga.sock" "$vm_dir/relaunch-qmp.sock"
    # The player/worker exits after validation. Keep the desktop VM independent
    # from its terminal so shell teardown cannot SIGHUP a healthy guest.
    if [ "$LOCK_FD" -ge 0 ] 2>/dev/null; then
        nohup setsid qemu-system-x86_64 "${qemu_args[@]}" {LOCK_FD}>&- </dev/null >>"$vm_dir/relaunch-qemu.log" 2>&1 &
    else
        nohup setsid qemu-system-x86_64 "${qemu_args[@]}" </dev/null >>"$vm_dir/relaunch-qemu.log" 2>&1 &
    fi
    local qemu_pid=$!
    echo "$qemu_pid" > "$vm_dir/qemu-pid"

    local qga_ready=0 qga_started=$SECONDS qga_deadline=$((SECONDS + 180)) qga_elapsed=0
    while [ "$SECONDS" -lt "$qga_deadline" ]; do
        kill -0 "$qemu_pid" 2>/dev/null || break
        if [ -S "$vm_dir/qga.sock" ] && qga_ping "$vm_dir/qga.sock"; then
            qga_ready=1
            log_operation "$op" "relaunched QGA ready after ${qga_elapsed}s"
            break
        fi
        sleep 5
        qga_elapsed=$((SECONDS - qga_started))
    done
    if [ "$qga_ready" != "1" ]; then
        log_operation "$op" "FAIL: relaunched VM did not expose QGA within 180s"
        qga_channel_close
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        rm -f "$vm_dir/qemu-pid"
        if [ "$graphics" = "virtio-gl" ] && [ "${PZ_RELAUNCH_FALLBACK_ACTIVE:-0}" != "1" ]; then
            log_operation "$op" "virtio-gl readiness failed; retrying once with compatible QXL display"
            PZ_RELAUNCH_FALLBACK_ACTIVE=1 PZ_RELAUNCH_GRAPHICS_OVERRIDE=compat run_relaunch "$op"
            return $?
        fi
        return 1
    fi

    local validation_os validation_network marker_open marker_handle marker_read marker_json validation_ok=0
    qga_exec "$vm_dir/qga.sock" '{"execute":"guest-get-osinfo"}' || true
    validation_os="$QGA_RESPONSE"
    local network_deadline=$((SECONDS + 60))
    while [ "$SECONDS" -lt "$network_deadline" ]; do
        qga_exec "$vm_dir/qga.sock" '{"execute":"guest-network-get-interfaces"}' || true
        validation_network="$QGA_RESPONSE"
        if printf '%s\n' "$validation_network" | jq -e '[.return[]? | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4" and (.["ip-address"] | startswith("127.") | not))] | length > 0' >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    local marker_path='C:\ProgramData\PhaseZero\provisioning-complete.json'
    marker_open="$(jq -nc --arg path "$marker_path" '{execute:"guest-file-open",arguments:{path:$path,mode:"r"}}')"
    qga_exec "$vm_dir/qga.sock" "$marker_open" || true
    marker_handle="$(printf '%s\n' "$QGA_RESPONSE" | jq -r '.return // -1')"
    if [[ "$marker_handle" =~ ^[0-9]+$ ]]; then
        qga_exec "$vm_dir/qga.sock" '{"execute":"guest-file-read","arguments":{"handle":'"$marker_handle"',"count":65536}}' || true
        marker_read="$QGA_RESPONSE"
        # Windows QGA may return a fixed-size buffer padded with NUL bytes.
        # Strip padding before handing the UTF-8 JSON marker to jq.
        marker_json="$(printf '%s\n' "$marker_read" | jq -r '.return["buf-b64"] // ""' | base64 -d 2>/dev/null | tr -d '\000' || true)"
        qga_exec "$vm_dir/qga.sock" '{"execute":"guest-file-close","arguments":{"handle":'"$marker_handle"'}}' || true
    fi

    if printf '%s\n' "$validation_os" | jq -e '.return | type == "object"' >/dev/null 2>&1 &&
       printf '%s\n' "$validation_network" | jq -e '[.return[]? | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4" and (.["ip-address"] | startswith("127.") | not))] | length > 0' >/dev/null 2>&1 &&
       printf '%s\n' "$marker_json" | jq -e '.completedAt and .exchangePath' >/dev/null 2>&1; then
        validation_ok=1
        log_operation "$op" "relaunch validation: QGA OS=$(printf '%s\n' "$validation_os" | jq -r '.return["pretty-name"] // .return.name // "Windows"')"
    fi
    if [ "$validation_ok" != "1" ]; then
        local validation_ipv4_count marker_bytes marker_prefix
        validation_ipv4_count="$(printf '%s\n' "$validation_network" | jq '[.return[]? | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4" and (.["ip-address"] | startswith("127.") | not))] | length' 2>/dev/null || echo 0)"
        marker_bytes="$(printf '%s' "$marker_json" | wc -c)"
        marker_prefix="$(printf '%s' "$marker_json" | head -c 256 | base64 -w0 2>/dev/null || true)"
        log_operation "$op" "relaunch diagnostics: os=$(printf '%s\n' "$validation_os" | jq -c '.return // .error // null' 2>/dev/null || echo invalid) ipv4=$validation_ipv4_count markerHandle=$marker_handle markerBytes=$marker_bytes markerPrefixB64=$marker_prefix"
        log_operation "$op" "FAIL: relaunched VM failed guest readiness validation"
        qga_shutdown "$vm_dir/qga.sock" || true
        sleep 2
        qga_channel_close
        local shutdown_wait=0
        while kill -0 "$qemu_pid" 2>/dev/null && [ "$shutdown_wait" -lt 30 ]; do
            sleep 1
            shutdown_wait=$((shutdown_wait + 1))
        done
        if kill -0 "$qemu_pid" 2>/dev/null; then
            kill "$qemu_pid" 2>/dev/null || true
        fi
        wait "$qemu_pid" 2>/dev/null || true
        rm -f "$vm_dir/qemu-pid"
        return 1
    fi
    log_operation "$op" "relaunch verified: QGA, network and completion marker ready (SMB verified during tweaks)"
    qga_channel_close
    echo "$qemu_pid"
}

find_qemu_pid_for_disk() {
    local disk="$1" proc pid cmdline canonical_disk
    [ -n "$disk" ] && [ -f "$disk" ] || return 1
    canonical_disk="$(readlink -f -- "$disk" 2>/dev/null || true)"
    [ -n "$canonical_disk" ] || return 1
    for proc in /proc/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue
        pid="${proc##*/}"
        cmdline="$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)"
        case "$cmdline" in
            *qemu-system*"$canonical_disk"*|*qemu-kvm*"$canonical_disk"*) printf '%s\n' "$pid"; return 0 ;;
        esac
    done
    return 1
}

provision_status() {
    local operation_id="" json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            --json) json=1; shift ;;
            *) pz_error "unknown status option: $1"; return 1 ;;
        esac
    done
    [ -n "$operation_id" ] || { pz_error "--operation-id required"; return 1; }

    local op_dir="$OPERATIONS_DIR/$operation_id"
    [ -d "$op_dir" ] || { pz_error "operation not found: $operation_id"; return 1; }
    [ -f "$op_dir/operation.json" ] || { pz_error "operation metadata missing"; return 1; }

    local vm_dir="" snapshot_path="" qemu_pid_raw="" qemu_pid_num=0 staging_qemu_pid=0 adopted_disk="" adopted_qemu_pid=0
    local effective_state worker_alive=false interruption_reason=""
    effective_state="$(provision_effective_state "$operation_id")"
    provision_worker_effectively_alive "$operation_id" && worker_alive=true
    interruption_reason="$(jq -r '.interruptionReason // ""' "$op_dir/operation.json" 2>/dev/null || true)"
    if [ "$effective_state" = "interrupted" ] && [ -z "$interruption_reason" ]; then
        interruption_reason="worker process is gone; staging files are preserved"
    fi
    local vm_dir_file="$OPERATIONS_DIR/$operation_id/vm_dir"
    [ -f "$vm_dir_file" ] && vm_dir="$(cat "$vm_dir_file")"
    local snap_path_file="$OPERATIONS_DIR/$operation_id/snapshot_path"
    [ -f "$snap_path_file" ] && snapshot_path="$(cat "$snap_path_file")"
    adopted_disk="$(jq -r '.adoptedDisk // ""' "$op_dir/operation.json")"
    if [ -n "$vm_dir" ] && [ -f "$vm_dir/qemu-pid" ]; then
        # Only trust qemu-pid from a vm_dir that resolves to canonical staging;
        # a corrupt/hostile vm_dir record must never drive a read from an
        # arbitrary path.
        if resolve_vm_staging_dir "$operation_id" >/dev/null 2>&1; then
            qemu_pid_raw="$(cat "$vm_dir/qemu-pid")"
        else
            pz_warn "vm_dir fails staging validation; qemu-pid not read: $vm_dir"
            vm_dir=""
        fi
    fi
    [[ "$qemu_pid_raw" =~ ^[0-9]+$ ]] && qemu_pid_num="$qemu_pid_raw"
    staging_qemu_pid="$qemu_pid_num"
    local qemu_running="false"
    if [ "$qemu_pid_num" -gt 0 ]; then
        if kill -0 "$qemu_pid_num" 2>/dev/null; then
            local cmdline=""
            [ -r "/proc/${qemu_pid_num}/cmdline" ] && cmdline="$(tr '\0' ' ' < "/proc/${qemu_pid_num}/cmdline")"
            case "$cmdline" in
                *qemu-system*|*qemu-kvm*) qemu_running="true" ;;
            esac
        fi
    fi
    if [ -n "$adopted_disk" ]; then
        adopted_qemu_pid="$(find_qemu_pid_for_disk "$adopted_disk" 2>/dev/null || echo 0)"
        [[ "$adopted_qemu_pid" =~ ^[0-9]+$ ]] || adopted_qemu_pid=0
        if [ "$adopted_qemu_pid" -gt 0 ]; then
            qemu_pid_num="$adopted_qemu_pid"
            qemu_running="true"
        fi
    fi
    local snapshot_exists="false"
    [ -n "$snapshot_path" ] && [ -f "$snapshot_path" ] && snapshot_exists="true"
    local libvirt_running="false"
    if command -v virsh >/dev/null 2>&1; then
        local dom_state
        dom_state="$(virsh domstate phasezero-windows-vm 2>/dev/null || true)"
        case "$dom_state" in
            running|paused|idle) libvirt_running="true" ;;
        esac
    fi

    if [ "$json" = "1" ]; then
        jq -n \
            --argjson op "$(cat "$op_dir/operation.json")" \
            --arg state "$effective_state" \
            --arg interruptionReason "$interruption_reason" \
            --argjson workerAlive "$worker_alive" \
            --arg vmDir "$vm_dir" \
            --arg snapshotPath "$snapshot_path" \
            --argjson snapshotExists "$snapshot_exists" \
            --argjson qemuPid "$qemu_pid_num" \
            --argjson stagingQemuPid "$staging_qemu_pid" \
            --argjson qemuRunning "$qemu_running" \
            --arg adoptedDisk "$adopted_disk" \
            --argjson adoptedDiskExists "$([ -n "$adopted_disk" ] && [ -f "$adopted_disk" ] && echo true || echo false)" \
            --argjson adoptedQemuPid "$adopted_qemu_pid" \
            --argjson libvirtRunning "$libvirt_running" \
            '$op + {state:$state, persistedState:$op.state, workerAlive:$workerAlive, interruptionReason:$interruptionReason, recoveryAction:(if $state == "interrupted" then "resume-or-remove" else "" end), vmDir: $vmDir, snapshotPath: $snapshotPath, snapshotExists: $snapshotExists, qemuPid: $qemuPid, stagingQemuPid: $stagingQemuPid, qemuRunning: $qemuRunning, adoptedDisk: $adoptedDisk, adoptedDiskExists: $adoptedDiskExists, adoptedQemuPid: $adoptedQemuPid, libvirtRunning: $libvirtRunning}'
    else
        local state checkpoint progress
        state="$effective_state"
        checkpoint="$(jq -r '.checkpoint' "$op_dir/operation.json")"
        progress="$(jq -r '.progress' "$op_dir/operation.json")"
        echo "Operation: $operation_id"
        echo "State: $state"
        echo "Checkpoint: $checkpoint"
        echo "Progress: ${progress}%"
        if [ "$state" = "interrupted" ]; then
            echo "Recovery: retome a operação ou remova os arquivos temporários"
            [ -z "$interruption_reason" ] || echo "Reason: $interruption_reason"
        fi
        jq -r '.log[]' "$op_dir/operation.json" 2>/dev/null || true
    fi
}

provision_watch() {
    local operation_id=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done
    [ -n "$operation_id" ] || { pz_error "--operation-id required"; return 1; }

    local op_dir="$OPERATIONS_DIR/$operation_id"
    [ -d "$op_dir" ] || { pz_error "operation not found: $operation_id"; return 1; }

    local last_log_lines=0
    while true; do
        [ -f "$op_dir/operation.json" ] || break
        local state
        state="$(provision_effective_state "$operation_id")"
        local checkpoint progress
        checkpoint="$(jq -r '.checkpoint // ""' "$op_dir/operation.json")"
        progress="$(jq -r '.progress // 0' "$op_dir/operation.json")"

        printf "\r[%-20s] %3d%% | %s" \
            "$(printf '%0.s#' $(seq 1 $((progress / 5))))" \
            "$progress" "$checkpoint"
        if [ "$state" != "running" ]; then
            printf " [%s]\n" "$state"
            if [ "$state" = "interrupted" ]; then
                echo "A instalação foi interrompida; os arquivos foram preservados. Retome ou remova pelo inventário."
            fi
            if [ -f "$op_dir/worker.log" ]; then
                echo "--- worker log ---"
                tail -20 "$op_dir/worker.log" 2>/dev/null || true
            fi
            break
        fi
        sleep 2
    done
}

provision_resume() {
    local operation_id=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            *) shift ;;
        esac
    done
    [ -n "$operation_id" ] || { pz_error "--operation-id required"; return 1; }

    local op_dir="$OPERATIONS_DIR/$operation_id"
    [ -d "$op_dir" ] || { pz_error "operation not found: $operation_id"; return 1; }

    local state checkpoint
    state="$(jq -r '.state' "$op_dir/operation.json")"
    checkpoint="$(jq -r '.checkpoint' "$op_dir/operation.json")"

    if ! provision_lock_acquire "$operation_id"; then
        return 1
    fi

    state="$(jq -r '.state // "unknown"' "$op_dir/operation.json")"
    if [ "$state" = "running" ]; then
        provision_mark_interrupted_locked "$operation_id" || {
            provision_lock_release
            return 1
        }
    elif [ "$state" != "interrupted" ] && [ "$state" != "failed" ] && [ "$state" != "cancelled" ]; then
        pz_error "operation cannot be resumed from state: $state"
        provision_lock_release
        return 1
    fi
    local vm_dir
    vm_dir="$(resolve_vm_staging_dir "$operation_id" 2>/dev/null || true)"
    if [ -n "$vm_dir" ] && [ -d "$vm_dir" ] && operation_vm_running "$vm_dir"; then
        pz_error "QEMU still has this install's disk open; shut it down before resuming"
        provision_lock_release
        return 1
    fi

    local resume_ts; resume_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg ts "$resume_ts" --argjson epoch "$(date +%s)" \
        '.state = "running" | .updatedAt = $ts | .workerSpawnedEpoch=$epoch | del(.interruptionReason,.recoveryAction)' \
        "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"

    # Close the parent lock FD before spawning; otherwise nohup inherits it
    # and the worker blocks on its own lock for the full handoff retry window.
    provision_lock_release
    setsid nohup bash "$PZ_ROOT/linux/windows-vm/provision.sh" run --operation-id "$operation_id" \
        </dev/null > "$op_dir/worker.log" 2>&1 &
    disown

    pz_info "operation resumed: $operation_id (from checkpoint: $checkpoint)"
}

# ── Safe staging removal ──
# Cancel --remove-staging deletes the VM staging directory. The path comes
# from mutable operation state, so it must be validated before any recursive
# deletion: canonical path, exact containment under the official staging
# layout, operation-id agreement, no symlink escapes, no external roots.
pz_staging_base() {
    printf '%s\n' "${PZ_STATE}/windows-vm/vms"
}

resolve_vm_staging_dir() {
    local op="$1" vm_dir="" canonical="" base="" canonical_base=""
    local op_dir="$OPERATIONS_DIR/$op"
    local vm_dir_file="$op_dir/vm_dir"

    [ -n "$op" ] || { pz_error "resolve_vm_staging_dir: empty operation id"; return 1; }
    case "$op" in
        */*|*..*) pz_error "resolve_vm_staging_dir: invalid operation id: $op"; return 1 ;;
    esac
    [ -d "$op_dir" ] || { pz_error "operation not found: $op"; return 1; }
    [ -f "$op_dir/operation.json" ] || { pz_error "operation metadata missing: $op"; return 1; }
    if ! jq -e '.id and .state' "$op_dir/operation.json" >/dev/null 2>&1; then
        pz_error "operation metadata corrupt for $op; refusing to remove staging"
        return 1
    fi
    local op_id_in_meta
    op_id_in_meta="$(jq -r '.id // ""' "$op_dir/operation.json" 2>/dev/null || true)"
    [ "$op_id_in_meta" = "$op" ] || {
        pz_error "operation metadata id ($op_id_in_meta) does not match $op; refusing to remove staging"
        return 1
    }

    [ -f "$vm_dir_file" ] || { pz_error "no staging record for operation $op"; return 1; }
    vm_dir="$(cat "$vm_dir_file" 2>/dev/null || true)"
    [ -n "$vm_dir" ] || { pz_error "empty staging path for operation $op"; return 1; }

    case "$vm_dir" in
        *..*)
            pz_error "refusing staging path containing '..': $vm_dir"
            return 1
            ;;
    esac
    [ "$vm_dir" = "/" ] && { pz_error "refusing to remove root"; return 1; }
    [ "$vm_dir" = "$HOME" ] && { pz_error "refusing to remove HOME"; return 1; }
    [ "$vm_dir" = "$PZ_STATE" ] && { pz_error "refusing to remove PZ_STATE"; return 1; }

    base="$(pz_staging_base)"
    [ -n "$base" ] || { pz_error "staging base undefined"; return 1; }
    canonical_base="$(cd -P "$base" 2>/dev/null && pwd -P || echo "")"
    [ -n "$canonical_base" ] || { pz_error "staging base does not exist: $base"; return 1; }

    if [ -L "$vm_dir" ] || [ -L "$vm_dir_file" ]; then
        pz_error "refusing to follow symlink in staging path: $vm_dir"
        return 1
    fi

    # Resolve the deepest existing ancestor so containment is checked on real
    # paths even when the leaf does not exist yet (or was partially removed).
    local probe="$vm_dir" ancestor=""
    while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do
        probe="$(dirname "$probe")"
    done
    if [ -L "$probe" ] || [ -L "$(dirname "$probe" 2>/dev/null)" ]; then
        pz_error "refusing to follow symlink on path to staging: $vm_dir"
        return 1
    fi
    canonical="$(cd -P "$probe" 2>/dev/null && pwd -P || echo "")"
    [ -n "$canonical" ] || { pz_error "cannot resolve staging path: $vm_dir"; return 1; }

    case "$canonical/" in
        "$canonical_base/"*)
            ;;
        *)
            pz_error "staging path escapes official layout: $vm_dir (resolved $canonical, base $canonical_base)"
            return 1
            ;;
    esac

    local expected="$canonical_base/$op"
    [ "$canonical" = "$expected" ] || [ "$canonical/" = "$expected/" ] || {
        pz_error "staging path does not match operation $op: $vm_dir (expected under $expected)"
        return 1
    }
    printf '%s\n' "$vm_dir"
    return 0
}

# Validate a QEMU pid before killing: numeric, alive, and its cmdline must
# reference the operation's staging dir or disk (which embeds the operation
# id). Guards against pid reuse.
validate_qemu_pid() {
    local pid="$1" vm_dir="$2" op="$3"
    case "$pid" in
        ''|*[!0-9]*) pz_error "invalid qemu pid: ${pid:-empty}"; return 1 ;;
    esac
    [ "$pid" -gt 1 ] 2>/dev/null || { pz_error "invalid qemu pid: $pid"; return 1; }
    [ -d "/proc/$pid" ] || { pz_error "qemu pid $pid is not alive; refusing kill"; return 1; }
    local cmdline=""
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    case "$cmdline" in
        *qemu-system*)
            ;;
        *)
            pz_error "pid $pid is not a qemu process; refusing kill"
            return 1
            ;;
    esac
    [ -n "$op" ] || { pz_error "validate_qemu_pid: empty operation id"; return 1; }
    case "$cmdline" in
        *"$op"*)
            ;;
        *)
            pz_error "pid $pid cmdline does not reference operation $op; refusing kill"
            return 1
            ;;
    esac
    if [ -n "$vm_dir" ]; then
        case "$cmdline" in
            *"$vm_dir"*)
                ;;
            *)
                pz_error "pid $pid cmdline does not reference staging $vm_dir; refusing kill"
                return 1
                ;;
        esac
    fi
    return 0
}

provision_cancel() {
    local operation_id="" remove_staging=0 json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            --remove-staging) remove_staging=1; shift ;;
            --json) json=1; shift ;;
            *) pz_error "unknown cancel option: $1"; return 1 ;;
        esac
    done
    [ -n "$operation_id" ] || { pz_error "--operation-id required"; return 1; }

    local op_dir="$OPERATIONS_DIR/$operation_id"
    if [ ! -d "$op_dir" ] || [ ! -f "$op_dir/operation.json" ]; then
        if [ "$json" = "1" ]; then
            jq -n --arg operationId "$operation_id" \
                '{success: false, cancelled: false, removalRequested: false, removalSucceeded: false, preservedPath: "", error: "operation not found", operationId: $operationId}'
        fi
        pz_error "operation not found: $operation_id"
        return 1
    fi

    # Cancel intentionally does NOT take the provision lock: it is the one
    # supervisory action that must be able to interrupt a running worker that
    # holds the lock. The worker notices the state change at the next
    # checkpoint and exits, releasing the lock on process death.

    local state
    state="$(jq -r '.state' "$op_dir/operation.json")"

    # The vm_dir record is only trusted after canonical-staging validation; a
    # corrupt/hostile record must never drive a qemu-pid read or a removal, and
    # a validation failure is reported (never silently treated as success).
    local vm_dir="" raw_vm_dir="" vm_dir_file="$OPERATIONS_DIR/$operation_id/vm_dir"
    local staging_valid=0
    [ -f "$vm_dir_file" ] && raw_vm_dir="$(cat "$vm_dir_file")"
    if [ -n "$raw_vm_dir" ]; then
        if resolve_vm_staging_dir "$operation_id" >/dev/null 2>&1; then
            staging_valid=1
            vm_dir="$raw_vm_dir"
        else
            pz_warn "staging validation failed for $operation_id; refusing to touch $raw_vm_dir"
        fi
    fi

    if [ "$staging_valid" = "1" ] && [ -f "$vm_dir/qemu-pid" ]; then
        local qemu_pid
        qemu_pid="$(cat "$vm_dir/qemu-pid")"
        if validate_qemu_pid "$qemu_pid" "$vm_dir" "$operation_id"; then
            kill "$qemu_pid" 2>/dev/null || true
            rm -f "$vm_dir/qemu-pid"
        else
            pz_warn "qemu pid validation failed ($qemu_pid); leaving qemu-pid record"
        fi
    fi

    local cancel_ts; cancel_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg ts "$cancel_ts" '.state = "cancelled" | .updatedAt = $ts' "$op_dir/operation.json" > "${op_dir}/operation.tmp" && mv "${op_dir}/operation.tmp" "$op_dir/operation.json"

    local removal_requested=0 removal_succeeded=0 preserved_path=""
    local op_state
    op_state="$(jq -r '.checkpoint' "$op_dir/operation.json")"
    if [ "$remove_staging" = "1" ] || [ "$op_state" = "validate" ] || [ "$op_state" = "assets" ]; then
        removal_requested=1
        if [ "$staging_valid" = "1" ] && [ -d "$vm_dir" ]; then
            if resolve_vm_staging_dir "$operation_id" >/dev/null 2>&1; then
                rm -rf -- "$vm_dir"
                if [ "$json" = "1" ]; then
                    echo >&2 "INFO:  removed staging directory: $vm_dir"
                else
                    pz_info "removed staging directory: $vm_dir"
                fi
                removal_succeeded=1
            else
                pz_error "staging validation refused; preserving $vm_dir"
                preserved_path="$vm_dir"
            fi
        elif [ "$staging_valid" = "1" ]; then
            # Nothing left to remove (already gone or never created).
            removal_succeeded=1
        elif [ -z "$raw_vm_dir" ]; then
            # The operation never recorded a staging directory: it stopped at
            # an early checkpoint (validate/assets), before any disk existed.
            # There is nothing on disk to preserve, so the discard is complete
            # instead of reporting a removal failure with an empty path.
            removal_succeeded=1
        else
            pz_error "staging validation failed; preserving $raw_vm_dir"
            preserved_path="$raw_vm_dir"
        fi
    else
        if [ "$json" = "1" ]; then
            echo >&2 "INFO:  disk preserved for resume/diagnosis: ${vm_dir:-$raw_vm_dir}"
        else
            pz_info "disk preserved for resume/diagnosis: ${vm_dir:-$raw_vm_dir}"
        fi
        [ -n "$raw_vm_dir" ] && preserved_path="$raw_vm_dir"
    fi

    local success=1 error=""
    if [ -n "$raw_vm_dir" ] && [ "$staging_valid" = "0" ]; then
        success=0
        error="staging validation failed; operation untouched: $raw_vm_dir"
    elif [ "$removal_requested" = "1" ] && [ "$removal_succeeded" = "0" ]; then
        success=0
        error="staging removal failed; preserved: $preserved_path"
    fi

    if [ "$json" = "1" ]; then
        jq -n \
            --arg operationId "$operation_id" \
            --argjson success "$([ "$success" = "1" ] && echo true || echo false)" \
            --argjson cancelled true \
            --argjson removalRequested "$([ "$removal_requested" = "1" ] && echo true || echo false)" \
            --argjson removalSucceeded "$([ "$removal_succeeded" = "1" ] && echo true || echo false)" \
            --arg preservedPath "$preserved_path" \
            --arg error "$error" \
            '{success: $success, cancelled: $cancelled, removalRequested: $removalRequested, removalSucceeded: $removalSucceeded, preservedPath: $preservedPath, error: $error, operationId: $operationId}'
    fi
    if [ "$json" = "1" ]; then
        echo >&2 "INFO:  operation cancelled: $operation_id"
    else
        pz_info "operation cancelled: $operation_id"
    fi
    [ "$success" = "1" ]
}

# ── Provisioned and interrupted VM inventory and removal ──
# Inventory includes completed guests and recoverable partial staging so disk
# use never disappears merely because a worker failed before completion.
# Operations are keyed by ID; callers never supply a removal path.

operation_allocated_bytes() {
    local path="$1" blocks=""
    blocks="$(du -sk -- "$path" 2>/dev/null | awk '{print $1}' || true)"
    [[ "$blocks" =~ ^[0-9]+$ ]] || blocks=0
    printf '%s\n' "$((blocks * 1024))"
}

operation_vm_running() {
    local vm_dir="$1" disk
    while IFS= read -r disk; do
        [ -f "$disk" ] || continue
        if find_qemu_pid_for_disk "$disk" >/dev/null 2>&1; then
            return 0
        fi
    done < <(find "$vm_dir" -maxdepth 1 -type f -name '*.qcow2' -print 2>/dev/null)
    return 1
}

provision_inventory() {
    local json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=1; shift ;;
            *) pz_error "unknown inventory option: $1"; return 1 ;;
        esac
    done

    local instances='[]' total=0 operation_file op op_dir state removed_at persisted_state worker_alive
    local vm_dir allocated image_index created_at updated_at adopted_disk kind running
    shopt -s nullglob
    for operation_file in "$OPERATIONS_DIR"/op-*/operation.json; do
        if [ ! -f "$operation_file" ] || [ -L "$operation_file" ]; then
            continue
        fi
        op_dir="$(dirname -- "$operation_file")"
        op="$(basename -- "$op_dir")"
        case "$op" in */*|*..*|*[!A-Za-z0-9._-]*) continue ;; esac
        persisted_state="$(jq -r '.state // ""' "$operation_file" 2>/dev/null || true)"
        state="$(provision_effective_state "$op")"
        case "$state" in completed|interrupted|failed|cancelled) ;; *) continue ;; esac
        removed_at="$(jq -r '.vmRemovedAt // ""' "$operation_file" 2>/dev/null || true)"
        [ -z "$removed_at" ] || continue
        vm_dir="$(resolve_vm_staging_dir "$op" 2>/dev/null || true)"
        if [ -z "$vm_dir" ] || [ ! -d "$vm_dir" ]; then
            continue
        fi

        allocated="$(operation_allocated_bytes "$vm_dir")"
        total=$((total + allocated))
        image_index="$(jq -r '.imageIndex // 0' "$op_dir/plan.json" 2>/dev/null || echo 0)"
        [[ "$image_index" =~ ^[0-9]+$ ]] || image_index=0
        created_at="$(jq -r '.createdAt // ""' "$operation_file" 2>/dev/null || true)"
        updated_at="$(jq -r '.updatedAt // ""' "$operation_file" 2>/dev/null || true)"
        adopted_disk="$(jq -r '.adoptedDisk // ""' "$operation_file" 2>/dev/null || true)"
        kind="installed"
        if [ "$state" != "completed" ]; then
            kind="partial-installation"
        elif [ -n "$adopted_disk" ]; then
            kind="installation-files"
        fi
        running=false
        if operation_vm_running "$vm_dir"; then
            running=true
        fi
        worker_alive=false
        [ "$state" != "running" ] || { provision_worker_effectively_alive "$op" && worker_alive=true; }

        instances="$(jq -c \
            --arg id "$op" \
            --arg vmDir "$vm_dir" \
            --arg createdAt "$created_at" \
            --arg updatedAt "$updated_at" \
            --arg state "$state" \
            --arg adoptedDisk "$adopted_disk" \
            --arg kind "$kind" \
            --argjson imageIndex "$image_index" \
            --argjson allocatedBytes "$allocated" \
            --argjson running "$running" \
            --argjson workerAlive "$worker_alive" \
            '. + [{id:$id, state:$state, kind:$kind, vmDir:$vmDir,
                    imageIndex:$imageIndex, allocatedBytes:$allocatedBytes,
                    createdAt:$createdAt, updatedAt:$updatedAt,
                    adoptedDisk:$adoptedDisk, running:$running, workerAlive:$workerAlive,
                    removable:($running|not)}]' <<< "$instances")"
    done
    shopt -u nullglob

    if [ "$json" = "1" ]; then
        jq -n --argjson instances "$instances" --argjson total "$total" \
            '{schemaVersion:1, operation:"windows-vm-inventory",
              instances:$instances, count:($instances|length),
              totalAllocatedBytes:$total}'
    else
        if [ "$(jq 'length' <<< "$instances")" = "0" ]; then
            echo "Nenhuma instalação Windows ocupa espaço no staging do PhaseZero."
            return 0
        fi
        jq -r '.[] | "\(.id)  edição \(.imageIndex)  \(.allocatedBytes) bytes  \(.vmDir)"' \
            <<< "$instances"
    fi
}

mark_operation_vm_removed() {
    local operation_file="$1" mode="$2" path="$3" bytes="$4" timestamp tmp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp="$(mktemp "$(dirname -- "$operation_file")/.operation.remove.XXXXXX")" || return 1
    if ! jq --arg ts "$timestamp" --arg mode "$mode" --arg path "$path" \
        --argjson bytes "$bytes" \
        '.vmRemovedAt=$ts | .vmRemovalMode=$mode | .vmRemovedPath=$path |
         .vmRemovedBytes=$bytes | .updatedAt=$ts' \
        "$operation_file" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 0600 "$tmp"
    mv -- "$tmp" "$operation_file"
}

purge_operation_vm_dir() {
    local operation_id="$1" vm_dir="$2" base quarantine
    base="$(pz_staging_base)"
    quarantine="$base/.phasezero-removing-${operation_id}-$$"
    [ ! -e "$quarantine" ] || { pz_error "temporary removal path already exists"; return 1; }
    mv -- "$vm_dir" "$quarantine" || { pz_error "could not isolate VM before removal"; return 1; }
    if ! find "$quarantine" -xdev -depth -delete; then
        if [ -e "$quarantine" ] && [ ! -e "$vm_dir" ]; then
            mv -- "$quarantine" "$vm_dir" 2>/dev/null || true
        fi
        pz_error "permanent removal failed; remaining files were preserved"
        return 1
    fi
    [ ! -e "$quarantine" ] || { pz_error "permanent removal left files behind"; return 1; }
}

provision_remove() {
    local operation_id="" dry_run=0 confirmed=0 purge=0 confirm_operation="" json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            --dry-run|-n) dry_run=1; shift ;;
            --yes) confirmed=1; shift ;;
            --purge) purge=1; shift ;;
            --trash) purge=0; shift ;;
            --confirm-operation) confirm_operation="${2:-}"; shift 2 ;;
            --confirm-operation=*) confirm_operation="${1#*=}"; shift ;;
            --json) json=1; shift ;;
            *) pz_error "unknown remove option: $1"; return 1 ;;
        esac
    done

    local -a blockers=()
    local op_dir="$OPERATIONS_DIR/$operation_id" operation_file=""
    operation_file="$op_dir/operation.json"
    local vm_dir="" state="" persisted_state="" allocated=0 mode="trash" blockers_json='[]' running=false
    case "$operation_id" in
        op-* ) ;;
        *) blockers+=("identificador da instalação inválido") ;;
    esac
    case "$operation_id" in */*|*..*|*[!A-Za-z0-9._-]*) blockers+=("identificador da instalação inseguro") ;; esac
    if [ "${#blockers[@]}" -eq 0 ]; then
        [ -d "$op_dir" ] && [ ! -L "$op_dir" ] || blockers+=("instalação não encontrada")
        [ -f "$operation_file" ] && [ ! -L "$operation_file" ] || blockers+=("registro da instalação ausente ou inseguro")
    fi
    if [ "${#blockers[@]}" -eq 0 ]; then
        persisted_state="$(jq -r '.state // ""' "$operation_file" 2>/dev/null || true)"
        state="$(provision_effective_state "$operation_id")"
        case "$state" in
            completed|interrupted|failed|cancelled) ;;
            running) blockers+=("instalação ainda está ativa; aguarde ou cancele antes de remover") ;;
            *) blockers+=("estado da instalação não permite remoção segura: $state") ;;
        esac
        [ "$(jq -r '.vmRemovedAt // ""' "$operation_file" 2>/dev/null || true)" = "" ] || blockers+=("esta VM já foi removida")
        vm_dir="$(resolve_vm_staging_dir "$operation_id" 2>/dev/null || true)"
        [ -n "$vm_dir" ] && [ -d "$vm_dir" ] || blockers+=("diretório gerenciado da VM não foi encontrado ou é inseguro")
    fi
    if [ -n "$vm_dir" ] && [ -d "$vm_dir" ]; then
        allocated="$(operation_allocated_bytes "$vm_dir")"
        if operation_vm_running "$vm_dir"; then
            running=true
        fi
        [ "$running" = false ] || blockers+=("desligue esta VM antes de removê-la")
        if [ "$persisted_state" = "running" ] && [ "$state" = "interrupted" ] && provision_worker_effectively_alive "$operation_id"; then
            blockers+=("o supervisor ainda está iniciando; tente novamente em alguns segundos")
        fi
    fi
    if [ "$purge" = "1" ]; then
        mode="purge"
        if [ "$dry_run" != "1" ] && [ "$confirm_operation" != "$operation_id" ]; then
            blockers+=("confirmação permanente não corresponde à instalação selecionada")
        fi
        command -v find >/dev/null 2>&1 || blockers+=("find não está disponível para remoção permanente segura")
    else
        command -v gio >/dev/null 2>&1 || blockers+=("gio não está disponível para mover a VM à lixeira")
    fi
    if [ "${#blockers[@]}" -gt 0 ]; then
        blockers_json="$(printf '%s\n' "${blockers[@]}" | jq -R . | jq -s .)"
    fi

    if [ "$json" = "1" ]; then
        jq -n \
            --arg operationId "$operation_id" --arg vmDir "$vm_dir" --arg mode "$mode" \
            --argjson allocatedBytes "$allocated" --argjson blockers "$blockers_json" \
            --argjson confirmed "$([ "$confirmed" = 1 ] && echo true || echo false)" \
            --argjson freesImmediately "$([ "$purge" = 1 ] && echo true || echo false)" \
            '{schemaVersion:1, operation:"windows-vm-provision-remove",
              target:{operationId:$operationId,vmDir:$vmDir,allocatedBytes:$allocatedBytes},
              removalMode:$mode, freesSpaceImmediately:$freesImmediately,
              blockers:$blockers, ready:($blockers|length == 0), confirmed:$confirmed,
              recovery:(if $mode == "trash" then "Restaure a pasta pela lixeira enquanto ela não for esvaziada." else "Remoção permanente; não há recuperação pelo PhaseZero." end)}'
    elif [ "${#blockers[@]}" -eq 0 ]; then
        printf 'Instalação: %s\nEspaço ocupado: %s bytes\nModo: %s\n' "$operation_id" "$allocated" "$mode"
    else
        printf 'Bloqueios:\n%s\n' "$(printf -- '- %s\n' "${blockers[@]}")"
    fi
    [ "${#blockers[@]}" -eq 0 ] || return 1
    [ "$dry_run" = "1" ] && return 0
    [ "$confirmed" = "1" ] || { pz_error "remoção requer --yes após a prévia"; return 1; }

    if ! provision_lock_acquire "$operation_id"; then
        return 1
    fi
    trap 'provision_lock_clear "$operation_id"; provision_lock_release' RETURN
    # Revalidate after taking the lock. Prevents target substitution between
    # preview and execution and blocks a new provisioning run from racing us.
    local locked_vm_dir
    locked_vm_dir="$(resolve_vm_staging_dir "$operation_id")" || return 1
    [ "$locked_vm_dir" = "$vm_dir" ] || { pz_error "VM target changed after preview"; return 1; }
    [ -d "$locked_vm_dir" ] || { pz_error "VM target disappeared after preview"; return 1; }
    if [ "$(jq -r '.state // ""' "$operation_file" 2>/dev/null || true)" = "running" ]; then
        provision_mark_interrupted_locked "$operation_id" || return 1
    fi
    local locked_state
    locked_state="$(provision_effective_state "$operation_id")"
    case "$locked_state" in completed|interrupted|failed|cancelled) ;; *)
        pz_error "operation changed state before removal: $locked_state"
        return 1
        ;;
    esac
    if operation_vm_running "$locked_vm_dir"; then
        pz_error "QEMU started after preview; refusing to remove an open disk"
        return 1
    fi

    if [ "$purge" = "1" ]; then
        purge_operation_vm_dir "$operation_id" "$locked_vm_dir" || return 1
    else
        gio trash -- "$locked_vm_dir" || { pz_error "não foi possível mover a VM para a lixeira"; return 1; }
        [ ! -e "$locked_vm_dir" ] || { pz_error "a VM ainda existe após a operação de lixeira"; return 1; }
    fi
    mark_operation_vm_removed "$operation_file" "$mode" "$locked_vm_dir" "$allocated" || {
        pz_error "VM removida, mas registro da operação não pôde ser atualizado"
        return 1
    }
    if [ "$json" = "1" ]; then
        jq -n --arg operationId "$operation_id" --arg mode "$mode" \
            --argjson bytes "$allocated" \
            '{schemaVersion:1, operation:"windows-vm-provision-remove", success:true,
              operationId:$operationId, removalMode:$mode, releasedBytes:$bytes,
              indexReleased:true}'
    else
        pz_info "VM $operation_id removida; edição liberada para nova instalação"
    fi
}

provision_finalize() {
    local operation_id="" target_dir="" json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            --target-dir) target_dir="${2:-}"; shift 2 ;;
            --target-dir=*) target_dir="${1#*=}"; shift ;;
            --json) json=1; shift ;;
            *) pz_error "unknown finalize option: $1"; return 1 ;;
        esac
    done
    [ -n "$operation_id" ] || { pz_error "--operation-id required"; return 1; }

    local op_dir="$OPERATIONS_DIR/$operation_id" operation_file="$OPERATIONS_DIR/$operation_id/operation.json"
    [ -f "$operation_file" ] || { pz_error "operation not found: $operation_id"; return 1; }
    local state existing_adopted existing_adopted_real existing_adopted_pid=0 managed_vm_base
    managed_vm_base="$(readlink -m -- "$HOME/VirtualMachines/PhaseZero-Windows")"
    state="$(jq -r '.state // ""' "$operation_file")"
    [ "$state" = "completed" ] || { pz_error "operation must be completed before finalize"; return 1; }
    existing_adopted="$(jq -r '.adoptedDisk // ""' "$operation_file")"
    if [ -n "$existing_adopted" ] && [ -f "$existing_adopted" ]; then
        existing_adopted_real="$(readlink -f -- "$existing_adopted" 2>/dev/null || true)"
        case "$existing_adopted_real" in
            "$managed_vm_base"|"$managed_vm_base"-*)
                existing_adopted_pid="$(find_qemu_pid_for_disk "$existing_adopted_real" 2>/dev/null || echo 0)"
                if { [[ "$existing_adopted_pid" =~ ^[0-9]+$ ]] && [ "$existing_adopted_pid" -gt 0 ]; } || qemu-img check "$existing_adopted_real" >/dev/null 2>&1; then
                    if [ "$json" = "1" ]; then
                        jq -n --arg disk "$existing_adopted_real" '{success:true, adoptedDisk:$disk, alreadyFinalized:true}'
                    else
                        pz_info "operation already finalized: $existing_adopted_real"
                    fi
                    return 0
                fi
                ;;
        esac
    fi

    local vm_dir snapshot_path source_pid partial_disk=""
    if ! provision_lock_acquire "$operation_id"; then
        return 1
    fi
    trap '[ -z "$partial_disk" ] || rm -f -- "$partial_disk" || true; provision_lock_clear "$operation_id"; provision_lock_release' RETURN
    vm_dir="$(resolve_vm_staging_dir "$operation_id")" || return 1
    snapshot_path="$(cat "$op_dir/snapshot_path" 2>/dev/null || true)"
    [ -f "$snapshot_path" ] || { pz_error "verified snapshot missing"; return 1; }
    source_pid="$(cat "$vm_dir/qemu-pid" 2>/dev/null || true)"
    if [[ "$source_pid" =~ ^[0-9]+$ ]] && kill -0 "$source_pid" 2>/dev/null; then
        pz_error "VM is running; shut it down before finalize"
        return 1
    fi

    if [ -z "$target_dir" ]; then
        local default_dir="$HOME/VirtualMachines/PhaseZero-Windows"
        if [ ! -e "$default_dir/phasezero-windows.qcow2" ]; then
            target_dir="$default_dir"
        else
            target_dir="$HOME/VirtualMachines/PhaseZero-Windows-${operation_id#op-}"
        fi
    fi
    target_dir="$(readlink -m -- "$target_dir")"
    case "$target_dir" in
        "$managed_vm_base"|"$managed_vm_base"-*) ;;
        *) pz_error "finalize target must be under $HOME/VirtualMachines/PhaseZero-Windows*"; return 1 ;;
    esac

    local target_disk="$target_dir/phasezero-windows.qcow2"
    partial_disk="$target_dir/.phasezero-windows.qcow2.partial.$$"
    [ ! -e "$target_disk" ] || { pz_error "final target already exists: $target_disk"; return 1; }
    install -d -m 700 "$target_dir"
    target_dir="$(readlink -f -- "$target_dir")"
    case "$target_dir" in
        "$managed_vm_base"|"$managed_vm_base"-*) ;;
        *) pz_error "finalize target resolves outside the managed VM directory"; return 1 ;;
    esac
    target_disk="$target_dir/phasezero-windows.qcow2"
    partial_disk="$target_dir/.phasezero-windows.qcow2.partial.$$"
    [ ! -e "$target_disk" ] || { pz_error "final target already exists: $target_disk"; return 1; }
    if ! qemu-img convert -f qcow2 -O qcow2 -o compat=1.1,lazy_refcounts=on -S 4k "$snapshot_path" "$partial_disk"; then
        rm -f -- "$partial_disk"
        pz_error "failed to flatten provisioned snapshot"
        return 1
    fi
    if ! qemu-img check "$partial_disk" >/dev/null 2>&1; then
        rm -f -- "$partial_disk"
        pz_error "final disk verification failed"
        return 1
    fi
    mv -- "$partial_disk" "$target_disk"
    partial_disk=""
    chmod 600 "$target_disk"
    if [ -f "$vm_dir/OVMF_VARS.fd" ]; then
        cp --preserve=mode,timestamps "$vm_dir/OVMF_VARS.fd" "$target_dir/OVMF_VARS.fd"
        chmod 600 "$target_dir/OVMF_VARS.fd"
    fi

    local graphics ovmf_code net_model="virtio-net-pci"
    graphics="$(jq -r '.graphics // "compat"' "$op_dir/plan.json")"
    ovmf_code="$(provision_ovmf_code)"
    # --source provisioned: this disk was built by PhaseZero, not found on the
    # host. `windows-vm remove` uses that distinction to decide whether the VM
    # is PhaseZero's to delete without extra warnings.
    if ! bash "$PZ_ROOT/linux/windows-vm/windows-vm.sh" adopt --disk "$target_disk" --graphics "$graphics" --net-model "$net_model" --ovmf-code "$ovmf_code" --source provisioned; then
        pz_error "disk created but PhaseZero adoption failed: $target_disk"
        return 1
    fi

    local finalized_at
    finalized_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! jq --arg disk "$target_disk" --arg ts "$finalized_at" '.adoptedDisk=$disk | .adoptedAt=$ts' "$operation_file" > "$operation_file.tmp"; then
        rm -f -- "$operation_file.tmp"
        pz_error "disk adopted but operation metadata update failed: $target_disk"
        return 1
    fi
    mv "$operation_file.tmp" "$operation_file"
    if [ "$json" = "1" ]; then
        jq -n --arg disk "$target_disk" '{success:true, adoptedDisk:$disk, alreadyFinalized:false}'
    else
        pz_info "provision finalized: $target_disk"
    fi
}

provision_shutdown() {
    local operation_id="" json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation-id) operation_id="${2:-}"; shift 2 ;;
            --operation-id=*) operation_id="${1#*=}"; shift ;;
            --json) json=1; shift ;;
            *) pz_error "unknown shutdown option: $1"; return 1 ;;
        esac
    done
    [ -n "$operation_id" ] || { pz_error "--operation-id required"; return 1; }

    local vm_dir
    # Validate operation id, metadata and vm_dir through the canonical staging
    # resolver BEFORE touching qga.sock / qemu-pid: an external or corrupt
    # record must never drive a guest-agent or kill action.
    if ! vm_dir="$(resolve_vm_staging_dir "$operation_id" 2>/dev/null)"; then
        if [ "$json" = "1" ]; then
            jq -n --arg operation_id "$operation_id" '{success: false, error: "staging validation failed", operationId: $operation_id}'
        else
            pz_error "staging validation failed for operation $operation_id"
        fi
        return 1
    fi
    if [ ! -d "$vm_dir" ]; then
        if [ "$json" = "1" ]; then
            jq -n --arg operation_id "$operation_id" '{success: false, error: "vm_dir not found", operationId: $operation_id}'
        else
            pz_error "vm_dir not found"
        fi
        return 1
    fi

    local qga_sock="$vm_dir/qga.sock"
    local adopted_disk adopted_pid=""
    adopted_disk="$(jq -r '.adoptedDisk // ""' "$OPERATIONS_DIR/$operation_id/operation.json")"
    if [ -n "$adopted_disk" ]; then
        adopted_pid="$(find_qemu_pid_for_disk "$adopted_disk" 2>/dev/null || true)"
        if [[ "$adopted_pid" =~ ^[0-9]+$ ]] && kill -0 "$adopted_pid" 2>/dev/null; then
            qga_sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/phasezero-windows-vm/qga.sock"
        fi
    fi
    if [ ! -S "$qga_sock" ]; then
        if [ "$json" = "1" ]; then
            jq -n --arg operation_id "$operation_id" '{success: false, error: "QGA socket not found", operationId: $operation_id}'
        else
            pz_error "QGA socket not found"
        fi
        return 1
    fi

    local have_socat=0
    command -v socat >/dev/null 2>&1 && have_socat=1
    if [ "$have_socat" != "1" ]; then
        if [ "$json" = "1" ]; then
            jq -n --arg operation_id "$operation_id" '{success: false, error: "socat required for QGA shutdown", operationId: $operation_id}'
        else
            pz_error "socat required"
        fi
        return 1
    fi

    local qemu_pid=""
    local qemu_pid_file="$vm_dir/qemu-pid"
    [ -f "$qemu_pid_file" ] && qemu_pid="$(cat "$qemu_pid_file")"
    if [[ "$adopted_pid" =~ ^[0-9]+$ ]] && kill -0 "$adopted_pid" 2>/dev/null; then
        qemu_pid="$adopted_pid"
    fi

    printf '%s\n' '{"execute":"guest-shutdown"}' |
        timeout 5 socat -T 2 STDIO,ignoreeof UNIX-CONNECT:"$qga_sock" 2>/dev/null || true

    local timeout=60 waited=0 shutdown_ok=0
    while [ "$waited" -lt "$timeout" ]; do
        # Check QEMU PID disappeared
        local pid_alive=0
        if [ -n "$qemu_pid" ]; then
            [[ "$qemu_pid" =~ ^[0-9]+$ ]] && kill -0 "$qemu_pid" 2>/dev/null && pid_alive=1
        fi

        # Check libvirt domstate
        local libvirt_alive=0
        if command -v virsh >/dev/null 2>&1; then
            local dom_state
            dom_state="$(virsh domstate phasezero-windows-vm 2>/dev/null || true)"
            case "$dom_state" in
                running|paused|idle) libvirt_alive=1 ;;
            esac
        fi

        if [ "$pid_alive" = "0" ] && [ "$libvirt_alive" = "0" ]; then
            shutdown_ok=1
            break
        fi

        if [ "$libvirt_alive" = "1" ] && [ "$pid_alive" = "1" ]; then
            sleep 2
            waited=$((waited + 2))
            continue
        fi

        sleep 2
        waited=$((waited + 2))
    done

    if [ "$shutdown_ok" != "1" ] && [ -n "$qemu_pid" ]; then
        if [[ "$qemu_pid" =~ ^[0-9]+$ ]]; then
            kill "$qemu_pid" 2>/dev/null || true
        fi
    fi

    if [ "$json" = "1" ]; then
        jq -n \
            --argjson success "$([ "$shutdown_ok" = "1" ] && echo true || echo false)" \
            --arg operation_id "$operation_id" \
            --argjson waited "$waited" \
            '{success: $success, operationId: $operation_id, waitedSeconds: $waited}'
    else
        if [ "$shutdown_ok" = "1" ]; then
            pz_info "VM shutdown confirmed after ${waited}s"
        else
            pz_warn "VM did not shut down within ${timeout}s"
        fi
    fi
    return $((1 - shutdown_ok))
}

usage() {
    cat <<EOF
PhaseZero Windows VM Provisioning

Usage:
  provision plan --iso <windows.iso> [options] [--json]
  provision start --plan-id <id> --confirm <token> [--json]
  provision status --operation-id <id> [--json]
  provision finalize --operation-id <id> [--target-dir PATH] [--json]
  provision watch --operation-id <id>
  provision resume --operation-id <id>
  provision cancel --operation-id <id> [--remove-staging]
  provision shutdown --operation-id <id> [--json]
  provision inventory [--json]
  provision remove --operation-id <id> [--trash|--purge --confirm-operation <id>] --yes [--json]

Options:
  --iso PATH       Windows installation ISO
  --ram MB         RAM in MB (default: auto)
  --cpus N         CPU cores (default: auto)
  --disk-size SIZE Disk size (default: 256G)
  --image-index N  Windows image/index (default: 1)
  --lang CODE      Language (default: pt-BR)
  --keyboard CODE  Keyboard layout (default: pt-BR)
  --timezone TZ    Timezone (default: America/Sao_Paulo)
  --user NAME      Local username (default: phasezero)
  --product-key KEY Optional Windows product key
  --tpm-bypass     Bypass TPM/Secure Boot requirements
  --graphics PROFILE Graphics profile (default: compat)
  --guest-login MODE Windows guest login: auto (default) or password
  --json           JSON output
  -n, --dry-run    Dry run (plan only)
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    ACTION="${1:-help}"
    if [ $# -gt 0 ]; then
        shift
    fi

    case "$ACTION" in
        plan|dry-run) provision_plan "$@" ;;
        start|begin) provision_start "$@" ;;
        run) provision_run "$@" ;;
        status) provision_status "$@" ;;
        watch|follow) provision_watch "$@" ;;
        resume|recover) provision_resume "$@" ;;
        cancel|stop) provision_cancel "$@" ;;
        finalize|adopt) provision_finalize "$@" ;;
        shutdown) provision_shutdown "$@" ;;
        inventory|list) provision_inventory "$@" ;;
        remove|delete) provision_remove "$@" ;;
        help|--help|-h|"") usage ;;
        *) pz_error "unknown provision action: $ACTION"; usage; exit 1 ;;
    esac
fi
