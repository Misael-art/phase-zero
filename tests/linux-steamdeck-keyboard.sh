#!/usr/bin/env bash
# Hermetic KDE virtual-keyboard selection, status, and fallback tests.
# Nothing here talks to the live compositor or the operator's onboard.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$TMP/state"
export XDG_RUNTIME_DIR="$TMP/run"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$TMP/bin" "$TMP/apps" "$TMP/kwin"

export PATH="$TMP/bin:/usr/bin:/bin"
export PZ_KWINRC_FORCE_TEXT=1
export PZ_KWINRC_SKIP_NOTIFY=1
export PZ_VKBD_DESKTOP_ROOT="$TMP/apps"
export PZ_VKBD_START_DELAY=0.05
export PZ_VKBD_AVAILABLE_POLLS=1
export PZ_VKBD_AVAILABLE_DELAY=0
export PZ_VKBD_VISIBLE_DELAY=0
export PZ_VKBD_WAYLAND=1
export PZ_QDBUS6="$TMP/bin/qdbus6"
export PZ_QDBUS_LOG="$TMP/qdbus.log"
export PZ_VKBD_PROCESS_CMD="$TMP/bin/vkbd-proc"
export PZ_VKBD_PROC_STATE="$TMP/proc-state"
export PZ_VKBD_PROC_LOG="$TMP/proc.log"
export PZ_STEAM_LOG="$TMP/steam.log"
: > "$PZ_QDBUS_LOG"
: > "$PZ_VKBD_PROC_STATE"
: > "$PZ_VKBD_PROC_LOG"
: > "$PZ_STEAM_LOG"
: > "$TMP/pids"

PLASMA="$TMP/apps/org.kde.plasma.keyboard.desktop"
MALIIT="$TMP/apps/com.github.maliit.keyboard.desktop"
OTHER="$TMP/apps/org.example.keyboard.desktop"

write_im() {
    local path="$1" exec_name="${2:-plasma-keyboard}"
    cat >"$path" <<EOF
[Desktop Entry]
Name=Keyboard
Exec=$exec_name
X-KDE-Wayland-VirtualKeyboard=true
EOF
}
write_im "$PLASMA" plasma-keyboard
write_im "$MALIIT" maliit-keyboard
write_im "$OTHER" example-keyboard

cat > "$TMP/bin/qdbus6" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PZ_QDBUS_LOG"
for arg in "$@"; do
    if [ "$arg" = "enabled" ]; then
        printf 'queried missing property enabled\n' >> "$PZ_QDBUS_LOG"
        exit 99
    fi
done
if [ "$#" -eq 2 ]; then
    if [ "${PZ_DBUS_SUPPORTED:-1}" = 1 ]; then
        printf '/VirtualKeyboard\n'
        exit 0
    fi
    exit 1
fi
joined="$*"
if [[ "$joined" == *"forceActivate"* ]]; then
    printf 'forceActivate\n' >> "$PZ_QDBUS_LOG"
    exit 0
fi
if [[ "$joined" == *"willShowOnActive"* ]]; then
    printf '%s\n' "${PZ_DBUS_WILL:-false}"
    exit 0
fi
if [[ "$joined" == *"Properties.Set"* ]]; then
    printf 'set %s\n' "$joined" >> "$PZ_QDBUS_LOG"
    exit 0
fi
if [[ "$joined" == *"Properties.Get"* ]]; then
    prop="${*: -1}"
    case "$prop" in
        available) printf '%s\n' "${PZ_DBUS_AVAILABLE:-false}" ;;
        visible) printf '%s\n' "${PZ_DBUS_VISIBLE:-false}" ;;
        active) printf '%s\n' "${PZ_DBUS_ACTIVE:-false}" ;;
        activeClientSupportsTextInput) printf '%s\n' "${PZ_DBUS_TEXT:-true}" ;;
        mode) printf '%s\n' "${PZ_DBUS_MODE:-1}" ;;
        *) exit 1 ;;
    esac
    exit 0
fi
exit 1
EOF

cat > "$TMP/bin/vkbd-proc" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-}" name="${2:-}"
case "$cmd" in
    running)
        grep -qx "$name" "$PZ_VKBD_PROC_STATE" 2>/dev/null
        ;;
    stop)
        if grep -qx "$name" "$PZ_VKBD_PROC_STATE" 2>/dev/null; then
            grep -vx "$name" "$PZ_VKBD_PROC_STATE" > "$PZ_VKBD_PROC_STATE.tmp" || true
            mv "$PZ_VKBD_PROC_STATE.tmp" "$PZ_VKBD_PROC_STATE"
            printf 'stopped %s\n' "$name" >> "$PZ_VKBD_PROC_LOG"
            exit 0
        fi
        exit 1
        ;;
    *) exit 2 ;;
esac
EOF

cat > "$TMP/bin/steam" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PZ_STEAM_LOG"
exit 1
EOF

cat > "$TMP/bin/wvkbd-mobintl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$PZ_VKBD_PIDS"
exit 0
EOF
cat > "$TMP/bin/wvkbd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$PZ_VKBD_PIDS"
exit 0
EOF
cat > "$TMP/bin/onboard" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$PZ_VKBD_PIDS"
sleep 30
EOF
chmod +x "$TMP/bin/"*

export PZ_VKBD_PIDS="$TMP/pids"

# shellcheck disable=SC1091
source "$REPO_ROOT/linux/steamdeck/input-actions.sh"
# common.sh replaces EXIT. Keep its cleanup and still stop fixture processes.
trap 'if [ -f "$TMP/pids" ]; then while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$TMP/pids"; fi; pz_cleanup_temp || true; rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

assert_eq() {
    [ "$1" = "$2" ] || fail "$3: expected [$2] got [$1]"
}

plain_input_method_lines() {
    grep -c '^InputMethod=' "$1" || true
}

qualified_line() {
    # shellcheck disable=SC2016
    grep -c '^InputMethod\[\$e\]=' "$1" || true
}

reset_case() {
    export PZ_KWINRC="$TMP/kwin/$(date +%s%N).kwinrc"
    export PZ_DRY_RUN=0
    export PZ_DBUS_SUPPORTED=1
    export PZ_DBUS_AVAILABLE=false
    export PZ_DBUS_VISIBLE=false
    export PZ_DBUS_ACTIVE=false
    export PZ_VKBD_WAYLAND=1
    export PZ_KWINRC_SKIP_NOTIFY=1
    unset PZ_VKBD_USABLE_PROBE || true
    : > "$PZ_VKBD_PROC_STATE"
    : > "$PZ_QDBUS_LOG"
    : > "$PZ_VKBD_PROC_LOG"
    rm -f "$(steamdeck_vkbd_state_file)"
}

backup_count() {
    local root="${PZ_BACKUP_ROOT:-$XDG_STATE_HOME/phasezero/backups}"
    if [ ! -d "$root" ]; then
        printf '0\n'
        return 0
    fi
    find "$root" -type f -name '*.bak.*' 2>/dev/null | wc -l || true
}

reset_case
cat > "$PZ_KWINRC" <<EOF
[General]
foo=bar

[Wayland]
InputMethod=$MALIIT
VirtualKeyboardEnabled=true
Other=keep

[Windows]
x=y
EOF
before_backups="$(backup_count)"
steamdeck_configure_virtual_keyboard >/dev/null
assert_eq "$(qualified_line "$PZ_KWINRC")" 1 "migrate writes InputMethod[\$e]"
assert_eq "$(plain_input_method_lines "$PZ_KWINRC")" 0 "migrate removes plain InputMethod"
grep -q "^InputMethod\[\$e\]=$PLASMA$" "$PZ_KWINRC" || fail "plasma path missing"
grep -q '^VirtualKeyboardEnabled=true$' "$PZ_KWINRC" || fail "enabled flag dropped"
grep -q '^foo=bar$' "$PZ_KWINRC" || fail "other group dropped"
grep -q '^Other=keep$' "$PZ_KWINRC" || fail "wayland sibling dropped"
sum1="$(sha256sum "$PZ_KWINRC" | awk '{print $1}')"
after_first="$(backup_count)"
[ "$after_first" -gt "$before_backups" ] || fail "migration did not keep a backup"
steamdeck_configure_virtual_keyboard >/dev/null
sum2="$(sha256sum "$PZ_KWINRC" | awk '{print $1}')"
assert_eq "$sum2" "$sum1" "second configure rewrote kwinrc"
assert_eq "$(backup_count)" "$after_first" "second configure took another backup"
state_action="$(jq -r '.action' "$(steamdeck_vkbd_state_file)")"
assert_eq "$state_action" "migrate" "recorded action"
cp -p "$PZ_KWINRC" "$TMP/migrated.kwinrc"
steamdeck_revert_virtual_keyboard >/dev/null
grep -q "^InputMethod=$MALIIT$" "$PZ_KWINRC" || fail "revert did not restore maliit"
grep -q '^foo=bar$' "$PZ_KWINRC" || fail "revert dropped unrelated keys"
# shellcheck disable=SC2016
if grep -q '^InputMethod\[\$e\]=' "$PZ_KWINRC"; then
    fail "revert left the migrated key"
fi

reset_case
cat > "$PZ_KWINRC" <<EOF
[Wayland]
InputMethod[\$e]=$MALIIT
VirtualKeyboardEnabled=true
EOF
sum1="$(sha256sum "$PZ_KWINRC" | awk '{print $1}')"
backups_before="$(backup_count)"
steamdeck_configure_virtual_keyboard >/dev/null
sum2="$(sha256sum "$PZ_KWINRC" | awk '{print $1}')"
assert_eq "$sum2" "$sum1" "explicit maliit InputMethod[\$e] was rewritten"
assert_eq "$(backup_count)" "$backups_before" "explicit choice created a backup"

reset_case
cat > "$PZ_KWINRC" <<EOF
[Wayland]
InputMethod=$OTHER
VirtualKeyboardEnabled=false
EOF
sum1="$(sha256sum "$PZ_KWINRC" | awk '{print $1}')"
steamdeck_configure_virtual_keyboard >/dev/null
sum2="$(sha256sum "$PZ_KWINRC" | awk '{print $1}')"
assert_eq "$sum2" "$sum1" "explicit non-maliit InputMethod was rewritten"

reset_case
cat > "$PZ_KWINRC" <<EOF
[Wayland]
InputMethod[\$e]=$OTHER
InputMethod=$MALIIT
VirtualKeyboardEnabled=false
EOF
steamdeck_configure_virtual_keyboard >/dev/null
assert_eq "$(qualified_line "$PZ_KWINRC")" 1 "cleanup kept explicit key"
grep -q "^InputMethod\[\$e\]=$OTHER$" "$PZ_KWINRC" || fail "cleanup changed the explicit desktop"
assert_eq "$(plain_input_method_lines "$PZ_KWINRC")" 0 "cleanup left plain maliit"
grep -q '^VirtualKeyboardEnabled=false$' "$PZ_KWINRC" || fail "cleanup flipped enabled=false"
sum1="$(sha256sum "$PZ_KWINRC" | awk '{print $1}')"
steamdeck_configure_virtual_keyboard >/dev/null
sum2="$(sha256sum "$PZ_KWINRC" | awk '{print $1}')"
assert_eq "$sum2" "$sum1" "cleanup was not idempotent"

reset_case
cat > "$PZ_KWINRC" <<EOF
[Wayland]
InputMethod=$MALIIT
VirtualKeyboardEnabled=false
EOF
steamdeck_configure_virtual_keyboard >/dev/null
grep -q "^InputMethod\[\$e\]=$PLASMA$" "$PZ_KWINRC" || fail "migrate ignored plasma"
grep -q '^VirtualKeyboardEnabled=false$' "$PZ_KWINRC" || fail "migrate forced enabled=true"

reset_case
cat > "$PZ_KWINRC" <<EOF
[Wayland]
InputMethod=$MALIIT
EOF
cp -p "$PZ_KWINRC" "$TMP/dry.kwinrc"
export PZ_DRY_RUN=1
steamdeck_configure_virtual_keyboard >/dev/null
cmp -s "$PZ_KWINRC" "$TMP/dry.kwinrc" || fail "dry-run wrote kwinrc"
export PZ_DRY_RUN=0

reset_case
cat > "$PZ_KWINRC" <<EOF
[Wayland]
InputMethod=$MALIIT
VirtualKeyboardEnabled=true
EOF
printf 'onboard\n' > "$PZ_VKBD_PROC_STATE"
export PZ_DBUS_SUPPORTED=1
export PZ_DBUS_AVAILABLE=false
export PZ_DBUS_VISIBLE=false
status="$(steamdeck_virtual_keyboard_status)"
jq -e . >/dev/null <<<"$status" || fail "status is not JSON"
assert_eq "$(jq -r '.provider' <<<"$status")" "maliit" "provider"
assert_eq "$(jq -r '.configured.origin' <<<"$status")" "phasezero-legacy" "origin"
assert_eq "$(jq -r '.configured.action' <<<"$status")" "migrate" "action"
assert_eq "$(jq -r '.configured.enabled' <<<"$status")" "true" "configured.enabled"
assert_eq "$(jq -r '.dbus.supported' <<<"$status")" "true" "dbus.supported"
assert_eq "$(jq -r '.dbus.available' <<<"$status")" "false" "dbus.available"
assert_eq "$(jq -r '.kde.available' <<<"$status")" "false" "kde.available"
assert_eq "$(jq -r '.kde.enabled' <<<"$status")" "true" "kde.enabled is the config flag"
assert_eq "$(jq -r '.open.effective' <<<"$status")" "false" "open.effective"
assert_eq "$(jq -r '.open.reason' <<<"$status")" "kwin-command-missing" "open.reason"
assert_eq "$(jq -r '.fallback.candidate' <<<"$status")" "onboard" "fallback candidate"
assert_eq "$(jq -r '.fallback.state' <<<"$status")" "alive-unusable-on-wayland" "fallback state"
assert_eq "$(jq -r '.migration.legacyPresent' <<<"$status")" "true" "legacy present"
if grep -q 'queried missing property enabled' "$PZ_QDBUS_LOG"; then
    fail "status queried the missing enabled property"
fi
health="$(printf '%s\n' "$status" | steamdeck_virtual_keyboard_health_from_json)"
case "$health" in
    WARN*) ;;
    *) fail "expected WARN health, got $health" ;;
esac

reset_case
export PZ_DBUS_SUPPORTED=0
cat > "$PZ_KWINRC" <<EOF
[Wayland]
InputMethod[\$e]=$PLASMA
VirtualKeyboardEnabled=true
EOF
status="$(steamdeck_virtual_keyboard_status)"
jq -e . >/dev/null <<<"$status" || fail "status without dbus is not JSON"
assert_eq "$(jq -r '.dbus.supported' <<<"$status")" "false" "dbus.supported without object"
assert_eq "$(jq -r '.dbus.available' <<<"$status")" "null" "dbus.available is null, not false"
assert_eq "$(jq -r '.configured.inputMethod' <<<"$status")" "$PLASMA" "config survives missing dbus"
assert_eq "$(jq -r '.provider' <<<"$status")" "plasma-keyboard" "provider from config"
assert_eq "$(jq -r '.open.effective' <<<"$status")" "false" "not open without dbus"
assert_eq "$(jq -r '.open.reason' <<<"$status")" "dbus-unavailable" "reason dbus-unavailable"
assert_eq "$(jq -r '.kde.available' <<<"$status")" "false" "kde.available stays boolean"

export PZ_QDBUS6="/no/such/qdbus6"
status="$(steamdeck_virtual_keyboard_status)"
jq -e '.dbus.supported == false and .configured.inputMethod != ""' >/dev/null <<<"$status" || fail "missing qdbus6 binary dropped config"
export PZ_QDBUS6="$TMP/bin/qdbus6"

reset_case
export PZ_DBUS_SUPPORTED=0
export PZ_VKBD_WAYLAND=1
: > "$PZ_VKBD_PROC_STATE"
set +e
steamdeck_open_virtual_keyboard >"$TMP/open.out" 2>"$TMP/open.err"
open_rc=$?
set -e
[ "$open_rc" -ne 0 ] || fail "wayland fallback reported success"
if grep -q 'started virtual keyboard' "$TMP/open.out" "$TMP/open.err"; then
    fail "dead or unusable fallback was reported as started"
fi
cat "$TMP/open.out" "$TMP/open.err" | grep -q 'not a keyboard' || fail "open did not report fallback failure"
if grep -q '^stopped onboard$' "$PZ_VKBD_PROC_LOG"; then
    fail "open stopped a keyboard it did not start"
fi
# The sleeper we started must have been stopped by pid. The seam never
# listed onboard, so this is the process this test launched.
if [ -s "$TMP/pids" ]; then
    while read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            fail "unusable fallback pid $pid was left running"
        fi
    done < "$TMP/pids"
fi

reset_case
printf 'onboard\n' > "$PZ_VKBD_PROC_STATE"
export PZ_DBUS_SUPPORTED=0
set +e
steamdeck_open_virtual_keyboard >/dev/null 2>"$TMP/open-existing.err"
open_rc=$?
set -e
[ "$open_rc" -ne 0 ] || fail "preexisting unusable onboard counted as success"
grep -qx 'onboard' "$PZ_VKBD_PROC_STATE" || fail "preexisting onboard was removed"
if grep -q '^stopped onboard$' "$PZ_VKBD_PROC_LOG"; then
    fail "preexisting onboard was stopped"
fi

reset_case
export PZ_DBUS_SUPPORTED=0
export PZ_VKBD_WAYLAND=0
export PZ_VKBD_USABLE_PROBE="$TMP/bin/usable-yes"
cat > "$PZ_VKBD_USABLE_PROBE" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$PZ_VKBD_USABLE_PROBE"
set +e
steamdeck_open_virtual_keyboard >/dev/null 2>"$TMP/open-usable.err"
open_rc=$?
set -e
[ "$open_rc" -eq 0 ] || fail "usable probe was rejected: $(cat "$TMP/open-usable.err")"

reset_case
export PZ_DBUS_SUPPORTED=1
export PZ_DBUS_AVAILABLE=true
export PZ_DBUS_VISIBLE=false
export PZ_DBUS_ACTIVE=true
: > "$PZ_KWINRC"
set +e
steamdeck_kde_open_virtual_keyboard >/dev/null 2>"$TMP/kde-open.err"
kde_rc=$?
set -e
[ "$kde_rc" -ne 0 ] || fail "active-but-hidden KWin keyboard counted as open"
grep -q 'forceActivate' "$PZ_QDBUS_LOG" || fail "forceActivate was not called"
grep -q 'Properties.Set' "$PZ_QDBUS_LOG" || fail "hidden keyboard was not deactivated"
if grep -q 'queried missing property enabled' "$PZ_QDBUS_LOG"; then
    fail "open queried enabled"
fi

reset_case
export PZ_DBUS_SUPPORTED=1
export PZ_DBUS_AVAILABLE=true
export PZ_DBUS_VISIBLE=true
cat > "$PZ_KWINRC" <<EOF
[Wayland]
InputMethod[\$e]=$PLASMA
VirtualKeyboardEnabled=true
EOF
status="$(steamdeck_virtual_keyboard_status)"
assert_eq "$(jq -r '.open.effective' <<<"$status")" "true" "visible is open"
assert_eq "$(jq -r '.open.reason' <<<"$status")" "kwin-visible" "visible reason"
health="$(printf '%s\n' "$status" | steamdeck_virtual_keyboard_health_from_json)"
case "$health" in
    PASS*) ;;
    *) fail "expected PASS health, got $health" ;;
esac

reset_case
export PZ_KWINRC_SKIP_NOTIFY=0
export PZ_KWRITE_LOG="$TMP/kwrite.log"
: > "$PZ_KWRITE_LOG"
cat > "$TMP/bin/kwriteconfig6" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PZ_KWRITE_LOG"
file="" key="" value="" mode="write"
while [ $# -gt 0 ]; do
    case "$1" in
        --notify) shift ;;
        --delete) mode="delete"; shift ;;
        --file) file="$2"; shift 2 ;;
        --group) shift 2 ;;
        --key) key="$2"; shift 2 ;;
        *) value="$1"; shift ;;
    esac
done
[ "$key" = "InputMethod" ] || exit 0
python3 - "$file" "$mode" "$value" <<'PY'
import sys
path, mode, value = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").read().splitlines()
out = []
group = False
inserted = False
names = {"InputMethod", "InputMethod$e", "InputMethod[$e]"}
for line in lines:
    if line.startswith("[") and line.endswith("]"):
        if group and mode == "write" and not inserted:
            out.append(f"InputMethod={value}")
            inserted = True
        group = line == "[Wayland]"
        out.append(line)
        continue
    if group and line.split("=", 1)[0] in names:
        continue
    out.append(line)
if mode == "write" and not inserted:
    if not group:
        out.append("[Wayland]")
    out.append(f"InputMethod={value}")
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
EOF
chmod +x "$TMP/bin/kwriteconfig6"
cat > "$PZ_KWINRC" <<EOF
[Wayland]
InputMethod=$MALIIT
VirtualKeyboardEnabled=true
EOF
export PZ_DBUS_SUPPORTED=1
# Maliit already answers available=true. Migration must still reload.
export PZ_DBUS_AVAILABLE=true
steamdeck_configure_virtual_keyboard >/dev/null
notify_lines="$(wc -l < "$PZ_KWRITE_LOG" | tr -d ' ')"
assert_eq "$notify_lines" 2 "migration notify must delete and write"
grep -q -- "--delete" "$PZ_KWRITE_LOG" || fail "notify did not delete the key"
grep -q -- "--notify" "$PZ_KWRITE_LOG" || fail "notify did not pass --notify"
grep -q -- "--key InputMethod " "$PZ_KWRITE_LOG" || fail "notify did not call kwriteconfig6"
grep -q "$PLASMA" "$PZ_KWRITE_LOG" || fail "notify did not pass the plasma desktop"
while IFS= read -r line; do
    case "$line" in
        *--notify*) ;;
        *) fail "kwriteconfig call missing --notify: $line" ;;
    esac
done < "$PZ_KWRITE_LOG"
assert_eq "$(qualified_line "$PZ_KWINRC")" 1 "notify did not restore InputMethod[\$e]"
grep -q "$PLASMA" "$PZ_KWINRC" || fail "notify dropped the plasma path"
assert_eq "$(plain_input_method_lines "$PZ_KWINRC")" 0 "notify left a plain InputMethod"
if grep -q 'enabled' "$PZ_KWRITE_LOG"; then
    fail "notify wrote the missing enabled property"
fi
sum1="$(sha256sum "$PZ_KWINRC" | awk '{print $1}')"
lines_before="$(wc -l < "$PZ_KWRITE_LOG" | tr -d ' ')"
steamdeck_configure_virtual_keyboard >/dev/null
sum2="$(sha256sum "$PZ_KWINRC" | awk '{print $1}')"
lines_after="$(wc -l < "$PZ_KWRITE_LOG" | tr -d ' ')"
assert_eq "$sum2" "$sum1" "keep with available=true rewrote kwinrc"
assert_eq "$lines_after" "$lines_before" "keep with available=true bounced the input method"
export PZ_DBUS_AVAILABLE=false
steamdeck_configure_virtual_keyboard >/dev/null
sum3="$(sha256sum "$PZ_KWINRC" | awk '{print $1}')"
lines_reload="$(wc -l < "$PZ_KWRITE_LOG" | tr -d ' ')"
assert_eq "$sum3" "$sum1" "reload with available=false did not restore InputMethod[\$e]"
assert_eq "$lines_reload" "$((lines_before + 2))" "available=false did not delete and write"
cat > "$PZ_KWINRC" <<EOF
[Wayland]
InputMethod=$OTHER
VirtualKeyboardEnabled=true
EOF
: > "$PZ_KWRITE_LOG"
export PZ_DBUS_AVAILABLE=false
steamdeck_configure_virtual_keyboard >/dev/null
assert_eq "$(qualified_line "$PZ_KWINRC")" 0 "explicit plain choice became InputMethod[\$e]"
assert_eq "$(plain_input_method_lines "$PZ_KWINRC")" 1 "explicit plain choice was dropped"
grep -q "$OTHER" "$PZ_KWINRC" || fail "explicit plain choice lost its desktop"
grep -q -- "--delete" "$PZ_KWRITE_LOG" || fail "explicit plain choice skipped reload"
export PZ_KWINRC_SKIP_NOTIFY=1

if grep -q 'test("maliit")' "$REPO_ROOT/linux/audit/doctor.sh" "$REPO_ROOT/linux/audit/repair-plan.sh"; then
    fail "doctor or repair-plan still requires maliit"
fi
if grep -q 'org.kde.KWin.reconfigure' "$REPO_ROOT/linux/steamdeck/input-actions.sh"; then
    fail "configure still calls KWin.reconfigure"
fi
if grep -q 'VirtualKeyboard enabled' "$REPO_ROOT/linux/steamdeck/input-actions.sh"; then
    fail "code still sets the missing enabled property"
fi

printf 'linux-steamdeck-keyboard ok\n'
