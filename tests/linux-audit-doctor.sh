#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Ignore caller XDG config; cases set their own temporary override when needed.
unset XDG_CONFIG_HOME
REPO="$(cd "$HERE/.." && pwd)"
TEST_SCRATCH="$(mktemp -d "$HERE/.audit-doctor.XXXXXX")"
printf '  scratch: %s\n' "$TEST_SCRATCH"
MOCK_BIN="$TEST_SCRATCH/bin"
MOCK_HOME="$TEST_SCRATCH/home"
DOCTOR="$REPO/linux/audit/doctor.sh"
PASS=0 FAIL=0
STUBBED_FILES=()

mock_cleanup() {
    for f in "${STUBBED_FILES[@]}"; do
        if [ -f "$f.bak" ]; then
            mv "$f.bak" "$f" 2>/dev/null
        fi
    done
    STUBBED_FILES=()
    rm -rf "$TEST_SCRATCH"
}
trap mock_cleanup EXIT

stub_repo_file() {
    local path="$1" content="$2"
    [ -f "$REPO/$path" ] && cp "$REPO/$path" "$REPO/$path.bak"
    printf '%s\n' "$content" > "$REPO/$path"
    chmod +x "$REPO/$path" 2>/dev/null || true
    STUBBED_FILES+=("$REPO/$path")
}

mock_install() {
    local name="$1" body="$2"
    mkdir -p "$MOCK_BIN"
    printf '%s\n' "$body" > "$MOCK_BIN/$name"
    chmod +x "$MOCK_BIN/$name"
}
mock_install_df() { mock_install df "$1"; }
mock_install_free() { mock_install free "$1"; }

mock_run() {
    local output rc
    mkdir -p "$MOCK_HOME"
    # Never turn a timeout or an interrupted run into empty, successful output.
    if output=$(
        HOME="$MOCK_HOME" \
        XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$MOCK_HOME/.config}" \
        XDG_DATA_HOME="$MOCK_HOME/.local/share" \
        XDG_STATE_HOME="$MOCK_HOME/.local/state" \
        XDG_CACHE_HOME="$MOCK_HOME/.cache" \
        PZ_DOCTOR_CMD_TIMEOUT=2 \
        PATH="$MOCK_BIN:/usr/bin:/bin" \
            timeout 90 bash "$DOCTOR" 2>/dev/null
    ); then
        rc=0
    else
        rc=$?
    fi
    if [[ "$rc" -eq 124 ]] || ! grep -Fq '=== Summary ===' <<< "$output"; then
        echo "FAIL: doctor did not reach summary (exit $rc)" >&2
        return 1
    fi
    printf '%s\n' "$output"
}

DF_BASIC() {
    cat << 'SCRIPT'
#!/usr/bin/env bash
case "$1" in
    --output=source) echo "Filesystem"; echo "/dev/sda1"; exit 0 ;;
    --output=fstype) echo "Type"; echo "ext4"; exit 0 ;;
esac
case "$*" in
    *--output=source,target,size,used,pcent*)
        echo "Filesystem      Mounted on   Size  Used Use%"
        echo "/dev/sda1       /            50G   25G  50%"
        exit 0 ;;
esac
echo "Filesystem      Size  Used Avail Use% Mounted on"
echo "/dev/sda1       50G   25G   25G  50% /"
SCRIPT
}

FREE_VALID() {
    cat << 'SCRIPT'
#!/usr/bin/env bash
cat <<EOF
              total        used        free      shared  buff/cache   available
Mem:          16000        4000        8000        1000        4000       12000
Swap:          8000           0        8000
EOF
SCRIPT
}

# Stub every doctor.sh sub-script that gets called via $PZ_ROOT to return fast
stub_all_subscripts() {
    local stub='#!/usr/bin/env bash
echo "{}"
'
    local fail_stub='#!/usr/bin/env bash
exit 1
'
    for sub in \
        linux/windows-vm/windows-vm.sh \
        linux/windows-vm/graphics.sh \
        linux/windows-vm/container-frontends.sh \
        linux/waydroid/waydroid.sh \
        linux/ai/status.sh \
        linux/ai/setup-opencode.sh \
        linux/ai/setup-omo.sh \
        linux/ai/9router-manager.sh \
        linux/ai/odysseus-manager.sh \
        linux/ai/setup-codexbar.sh \
        linux/steamdeck/input-actions.sh \
        linux/steamdeck/plugins.sh \
        linux/emulation/emudeck.sh \
        linux/emulation/srm.sh \
        linux/emulation/ps3.sh \
        linux/emulation/shortcuts.sh \
        linux/emulation/performance.sh \
        linux/boot/recovery.sh \
        linux/boot/iso-boot.sh \
        linux/steamdeck/install-steamos-boot.sh; do
        stub_repo_file "$sub" "$stub"
    done
    # Host service, network, and user-session probes must stay deterministic.
    for tool in systemctl ping lspci ip qdbus6 docker flatpak tailscale btrfs; do
        mock_install "$tool" "$fail_stub"
    done
}

# case 1: snap squashfs mount at 100% → NOT flagged as FAIL
test_snap_not_fail() {
    rm -rf "$MOCK_BIN"
    stub_all_subscripts
    # shellcheck disable=SC2016 # mock df body is a literal script written to MOCK_BIN
    mock_install_df '#!/usr/bin/env bash
case "$1" in
    --output=source) echo "Filesystem"; echo "/dev/sda1"; exit 0 ;;
    --output=fstype) echo "Type"; echo "squashfs"; exit 0 ;;
esac
case "$*" in
    *--output=source,target,size,used,pcent*)
        echo "Filesystem      Mounted on                                          Size  Used Use%"
        echo "/dev/loop0      /var/lib/snapd/snap/bare/5                          100M  100M 100%"
        echo "/dev/sda1       /                                                    50G   25G  50%"
        exit 0 ;;
esac
echo "Filesystem      Size  Used Avail Use% Mounted on"
echo "/dev/sda1       50G   25G   25G  50% /"
'
    mock_install_free "$(FREE_VALID)"
    local output
    output=$(mock_run) || return 1
    if echo "$output" | grep -q 'DISK_var_lib_snapd_snap'; then
        echo "FAIL: case 1 (snap-not-fail) — snap line appeared in output" >&2
        return 1
    fi
    echo "ok"
}

# case 2: localized free → MEM ERROR
test_mem_localized_error() {
    rm -rf "$MOCK_BIN"
    stub_all_subscripts
    mock_install_free '#!/usr/bin/env bash
cat <<EOF
              total   usado   libre  compart  búfer  caché  disponible
Mem:           ?       ?       ?       ?       ?       ?       ?
Swap:          ?       ?       ?
EOF'
    mock_install_df "$(DF_BASIC)"
    local output
    output=$(mock_run) || return 1
    if ! echo "$output" | grep -Eq '(ERROR.*MEM01|MEM01.*ERROR)'; then
        echo "FAIL: case 2 (mem-localized-error) — expected MEM01 ERROR" >&2
        echo "MEM01: $(echo "$output" | grep MEM01 || true)" >&2
        return 1
    fi
    echo "ok"
}

# case 3: valid free → 3 MEM PASS
test_mem_valid_pass() {
    rm -rf "$MOCK_BIN"
    stub_all_subscripts
    mock_install_free "$(FREE_VALID)"
    mock_install_df "$(DF_BASIC)"
    local output
    output=$(mock_run) || return 1
    local passes
    passes=$(echo "$output" | grep -cE '(PASS.*MEM|MEM.*PASS)' || true)
    if [ "$passes" -lt 3 ]; then
        echo "FAIL: case 3 (mem-valid-pass) — expected 3 MEM PASS, got ${passes}" >&2
        return 1
    fi
    echo "ok"
}

# case 4: df pct dash → DISK ERROR
test_pct_malformed_error() {
    rm -rf "$MOCK_BIN"
    stub_all_subscripts
    mock_install_free "$(FREE_VALID)"
    # shellcheck disable=SC2016 # mock df body is a literal script written to MOCK_BIN
    mock_install_df '#!/usr/bin/env bash
case "$1" in
    --output=source) echo "Filesystem"; echo "/dev/sda1"; exit 0 ;;
    --output=fstype) echo "Type"; echo "ext4"; exit 0 ;;
esac
case "$*" in
    *--output=source,target,size,used,pcent*)
        echo "Filesystem      Mounted on  Size  Used Use%"
        echo "/dev/sdb1       /mnt/data   100G  90G  -"
        echo "/dev/sda1       /           50G   25G  50%"
        exit 0 ;;
esac
echo "Filesystem      Size  Used Avail Use% Mounted on"
echo "/dev/sda1       50G   25G   25G  50% /"
'
    local output
    output=$(mock_run) || return 1
    if ! echo "$output" | grep -Eq '(ERROR.*_mnt_data|_mnt_data.*ERROR)'; then
        echo "FAIL: case 4 (pct-malformed-error) — expected DISK_mnt_data ERROR" >&2
        echo "DISK lines: $(echo "$output" | grep 'DISK_' || true)" >&2
        return 1
    fi
    echo "ok"
}

# case 5: stdout contains $id
test_stdout_id() {
    rm -rf "$MOCK_BIN"
    stub_all_subscripts
    mock_install_free "$(FREE_VALID)"
    mock_install_df "$(DF_BASIC)"
    local output
    output=$(mock_run) || return 1
    if ! echo "$output" | grep -q '^\[PASS\] MEM01:'; then
        echo "FAIL: case 5 (stdout-id) — expected '[PASS] MEM01:' pattern" >&2
        echo "MEM01: $(echo "$output" | grep MEM01 || true)" >&2
        return 1
    fi
    echo "ok"
}

# case 6: HOST_PROFILE=steamdeck → WINVM06 INFO not WARN
test_host_profile_deck_winvm06() {
    rm -rf "$MOCK_BIN"
    stub_all_subscripts
    mock_install_free "$(FREE_VALID)"
    mock_install_df "$(DF_BASIC)"
    # Override cat in MOCK_BIN to return Jupiter
    mock_install cat '#!/usr/bin/env bash
if expr "$*" : ".*product_name" >/dev/null; then echo "Jupiter"; exit 0; fi
if expr "$*" : ".*thermal_zone0" >/dev/null; then echo "0"; exit 0; fi
/usr/bin/cat "$@"
'
    local output
    output=$(mock_run) || return 1
    if echo "$output" | grep -Eq '(WARN.*WINVM06|WINVM06.*WARN)'; then
        echo "FAIL: case 6 (host-profile-deck-winvm06) — expected WINVM06 INFO not WARN" >&2
        echo "WINVM06: $(echo "$output" | grep WINVM06 || true)" >&2
        return 1
    fi
    echo "ok"
}

# case 7: subsystem never → WAYDROID all INFO
test_subsystem_never_waydroid() {
    rm -rf "$MOCK_BIN"
    stub_all_subscripts
    mock_install_free "$(FREE_VALID)"
    mock_install_df "$(DF_BASIC)"
    export XDG_CONFIG_HOME="$TEST_SCRATCH/xdg"
    mkdir -p "$XDG_CONFIG_HOME/phasezero"
    printf 'SUBSYSTEM_WAYDROID=never\n' > "$XDG_CONFIG_HOME/phasezero/subsystems.conf"
    local output
    output=$(mock_run) || return 1
    if echo "$output" | grep -Eq '(WARN.*WAYDROID|WAYDROID.*WARN)'; then
        echo "FAIL: case 7 (subsystem-never-waydroid) — expected no WAYDROID WARN" >&2
        echo "WAYDROID WARNs: $(echo "$output" | grep WAYDROID || true)" >&2
        return 1
    fi
    echo "ok"
}

# case 8: subsystem partial → WAYDROID checks run at full severity
test_subsystem_partial_waydroid() {
    rm -rf "$MOCK_BIN"
    stub_all_subscripts
    mock_install_free "$(FREE_VALID)"
    mock_install_df "$(DF_BASIC)"
    export XDG_CONFIG_HOME="$TEST_SCRATCH/xdg"
    mkdir -p "$XDG_CONFIG_HOME/phasezero"
    printf 'SUBSYSTEM_WAYDROID=partial\n' > "$XDG_CONFIG_HOME/phasezero/subsystems.conf"
    local output
    output=$(mock_run) || return 1
    if ! echo "$output" | grep -Eq '(WARN.*WAYDROID|WAYDROID.*WARN)'; then
        echo "FAIL: case 8 (subsystem-partial) — expected some WAYDROID WARN" >&2
        echo "WAYDROID lines: $(echo "$output" | grep WAYDROID || true)" >&2
        return 1
    fi
    echo "ok"
}

# case 9: sem subsystems.conf → subsistema opcional fica em INFO, não em WARN.
# CCS-016 inverteu a regra antiga ("ausência de conf = opted, WARN cheio"):
# host novo não pode virar parede de avisos por subsistema que o usuário nunca
# pediu. Este caso guardava a regra antiga e ninguém percebeu, porque o arquivo
# ficava fora do runner.
test_optional_subsystem_stays_quiet_without_config() {
    rm -rf "$MOCK_BIN"
    stub_all_subscripts
    mock_install_free "$(FREE_VALID)"
    mock_install_df "$(DF_BASIC)"
    export XDG_CONFIG_HOME="$TEST_SCRATCH/xdg_none"
    mkdir -p "$XDG_CONFIG_HOME/phasezero"
    local output
    output=$(mock_run) || return 1
    if ! echo "$output" | grep -Eq '\[INFO\] WAYDROID00.*not opted in'; then
        echo "FAIL: sem config, Waydroid deveria ficar em INFO 'not opted in'" >&2
        echo "WAYDROID lines: $(echo "$output" | grep WAYDROID || true)" >&2
        return 1
    fi
    if echo "$output" | grep -Eq '(WARN.*WAYDROID|WAYDROID.*WARN)'; then
        echo "FAIL: subsistema não solicitado virou WARN num host sem config" >&2
        return 1
    fi
    echo "ok"
}

# Run all
echo "=== audit/doctor.sh engine hardening tests ==="
for case in test_snap_not_fail test_mem_localized_error test_mem_valid_pass \
            test_pct_malformed_error test_stdout_id test_host_profile_deck_winvm06 \
            test_subsystem_never_waydroid test_subsystem_partial_waydroid \
            test_optional_subsystem_stays_quiet_without_config; do
    printf "  case %s: " "${case#test_}"
    mock_cleanup 2>/dev/null || true
    if "$case"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done
mock_cleanup
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
