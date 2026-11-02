#!/usr/bin/env bash
# Hermetic persist-on/off/status for the two Deck desktop services.
# The fake systemctl is the only systemctl the scripts may see. The live
# user units are read with /usr/bin/systemctl before and after, and the test
# fails if those values change.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"

live_snapshot() {
    /usr/bin/systemctl --user show phasezero-controller-desktop.service \
        -p MainPID -p NRestarts -p ActiveState --no-pager
    echo "---"
    /usr/bin/systemctl --user show phasezero-terminal-keyboard.service \
        -p MainPID -p NRestarts -p ActiveState --no-pager
}

BEFORE="$(live_snapshot)"
cleanup() {
    local ec=$?
    local after
    after="$(live_snapshot)"
    rm -rf "$TMP_ROOT"
    if [ "$BEFORE" != "$after" ]; then
        echo "FAIL: live user units changed" >&2
        echo "BEFORE:" >&2
        printf '%s\n' "$BEFORE" >&2
        echo "AFTER:" >&2
        printf '%s\n' "$after" >&2
        exit 1
    fi
    exit "$ec"
}
trap cleanup EXIT

export HOME="$TMP_ROOT/home"
export XDG_CACHE_HOME="$TMP_ROOT/cache"
export XDG_STATE_HOME="$TMP_ROOT/state"
export XDG_CONFIG_HOME="$TMP_ROOT/config"
export PZ_SCC_CONFIG_DIR="$TMP_ROOT/scc"
export PZ_SYSTEMD_USER_DIR="$TMP_ROOT/systemd"
export PZ_CONTROLLER_SYSFS_ROOT="$TMP_ROOT/sysfs"
export PZ_INPUT_PROC_ROOT="$TMP_ROOT/proc"
export PZ_CONTROLLER_PERSIST_SETTLE=0
export PZ_FAKE_SYSTEMCTL_LOG="$TMP_ROOT/systemctl.log"
export PZ_FAKE_SYSTEMD_STATE="$TMP_ROOT/systemd-state"
export PZ_FAKE_PGREP_LOG="$TMP_ROOT/pgrep.log"
export PZ_FAKE_SCC_LOG="$TMP_ROOT/scc.log"
export PZ_FAKE_PGREP_HIT=0
export PZ_SCC_DAEMON_BIN="$TMP_ROOT/bin/scc-daemon"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$PZ_SCC_CONFIG_DIR/profiles" \
    "$PZ_SYSTEMD_USER_DIR" "$PZ_CONTROLLER_SYSFS_ROOT" "$PZ_INPUT_PROC_ROOT" "$PZ_FAKE_SYSTEMD_STATE" "$TMP_ROOT/bin" "$TMP_ROOT/nosys"
: >"$PZ_FAKE_SYSTEMCTL_LOG"
: >"$PZ_FAKE_SCC_LOG"

dev="$PZ_CONTROLLER_SYSFS_ROOT/3-3"
mkdir -p "$dev"
printf '28de\n' >"$dev/idVendor"
printf '1205\n' >"$dev/idProduct"

cat >"$TMP_ROOT/bin/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$PZ_FAKE_SYSTEMCTL_LOG"
if [ "${1:-}" != "--user" ]; then
    echo "fake-systemctl: expected --user, got $*" >&2
    exit 1
fi
shift
verb="${1:-}"
shift || true
name=""
now=0
quiet=0
prop=""
for arg in "$@"; do
    case "$arg" in
        --now) now=1 ;;
        --quiet) quiet=1 ;;
        --property=*) prop="${arg#--property=}" ;;
        --value|--no-pager) ;;
        -p) ;;
        -*) ;;
        *) name="$arg" ;;
    esac
done
mkdir -p "$PZ_FAKE_SYSTEMD_STATE"
case "$verb" in
    daemon-reload) exit 0 ;;
    show)
        [ -n "$prop" ] && exit 0
        printf '0\n'
        exit 0
        ;;
    enable)
        [ -n "$name" ] || exit 1
        printf 'enabled\n' >"$PZ_FAKE_SYSTEMD_STATE/$name.enabled"
        [ "$now" = 1 ] && printf 'active\n' >"$PZ_FAKE_SYSTEMD_STATE/$name.active"
        exit 0
        ;;
    disable)
        [ -n "$name" ] || exit 1
        printf 'disabled\n' >"$PZ_FAKE_SYSTEMD_STATE/$name.enabled"
        [ "$now" = 1 ] && printf 'inactive\n' >"$PZ_FAKE_SYSTEMD_STATE/$name.active"
        exit 0
        ;;
    stop)
        [ -n "$name" ] || exit 1
        printf 'inactive\n' >"$PZ_FAKE_SYSTEMD_STATE/$name.active"
        exit 0
        ;;
    is-enabled)
        [ -n "$name" ] || exit 1
        if [ ! -f "$PZ_FAKE_SYSTEMD_STATE/$name.enabled" ]; then
            [ "$quiet" = 1 ] || printf 'not-found\n'
            exit 1
        fi
        value="$(cat "$PZ_FAKE_SYSTEMD_STATE/$name.enabled")"
        [ "$quiet" = 1 ] || printf '%s\n' "$value"
        [ "$value" = "enabled" ]
        ;;
    is-active)
        [ -n "$name" ] || exit 1
        if [ ! -f "$PZ_FAKE_SYSTEMD_STATE/$name.active" ]; then
            [ "$quiet" = 1 ] || printf 'inactive\n'
            exit 3
        fi
        value="$(cat "$PZ_FAKE_SYSTEMD_STATE/$name.active")"
        [ "$quiet" = 1 ] || printf '%s\n' "$value"
        [ "$value" = "active" ]
        ;;
    *)
        echo "fake-systemctl: unknown $verb" >&2
        exit 1
        ;;
esac
EOF

cat >"$TMP_ROOT/bin/pgrep" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$PZ_FAKE_PGREP_LOG"
if [ "${PZ_FAKE_PGREP_HIT:-0}" = 1 ]; then
    exit 0
fi
exit 1
EOF

cat >"$TMP_ROOT/bin/scc-daemon" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$PZ_FAKE_SCC_LOG"
exit 99
EOF
chmod 755 "$TMP_ROOT/bin/systemctl" "$TMP_ROOT/bin/pgrep" "$TMP_ROOT/bin/scc-daemon"

export PATH="$TMP_ROOT/bin:/usr/bin:/bin"

CTRL="$REPO_ROOT/linux/steamdeck/controller-desktop.sh"
TERM_KBD="$REPO_ROOT/linux/steamdeck/terminal-keyboard.sh"
PROFILE="$PZ_SCC_CONFIG_DIR/profiles/PhaseZero-Desktop.sccprofile"
DESKTOP_UNIT="phasezero-controller-desktop.service"
KEYBOARD_UNIT="phasezero-terminal-keyboard.service"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

printf 'MARKER-KEEP\n' >"$PROFILE"

echo "=== persist-status sem unit é desligado, padrão ligado ==="
out="$(bash "$CTRL" persist-status)"
grep -q '^state=desligado$' <<<"$out" || fail "status inicial: $out"
grep -q 'ainda não está nesta sessão' <<<"$out" || fail "motivo inicial: $out"

echo "=== persist-on não reescreve perfil, não arma timer, não liga apps ==="
out="$(bash "$CTRL" persist-on)"
grep -q '^state=ligado$' <<<"$out" || fail "persist-on: $out"
grep -q '^mutated=1$' <<<"$out" || fail "persist-on mutated: $out"
grep -q 'MARKER-KEEP' "$PROFILE" || fail "perfil existente foi reescrito"
test ! -f "$PZ_SCC_CONFIG_DIR/phasezero-revert.pid" || fail "timer de reversão armado"
test ! -s "$PZ_FAKE_SCC_LOG" || fail "scc-daemon foi executado"
grep -q 'phasezero-controller-apps' "$PZ_FAKE_SYSTEMCTL_LOG" && fail "apps unit recebeu systemctl"
grep -q "enable --now $DESKTOP_UNIT" "$PZ_FAKE_SYSTEMCTL_LOG" || fail "desktop unit não foi habilitada"
echo "  persist-on ok"

echo "=== segunda ligação não muta de novo ==="
enables_before="$(grep -c 'enable --now' "$PZ_FAKE_SYSTEMCTL_LOG" || true)"
out="$(bash "$CTRL" persist-on)"
grep -q '^mutated=0$' <<<"$out" || fail "segunda ligação: $out"
enables_after="$(grep -c 'enable --now' "$PZ_FAKE_SYSTEMCTL_LOG" || true)"
[ "$enables_before" = "$enables_after" ] || fail "segunda ligação habilitou de novo"

echo "=== status ligado ==="
out="$(bash "$CTRL" persist-status)"
grep -q '^state=ligado$' <<<"$out" || fail "status ligado: $out"

echo "=== Steam no ar recusa sem chamar enable ==="
printf 'disabled\n' >"$PZ_FAKE_SYSTEMD_STATE/$DESKTOP_UNIT.enabled"
printf 'inactive\n' >"$PZ_FAKE_SYSTEMD_STATE/$DESKTOP_UNIT.active"
: >"$PZ_FAKE_SYSTEMCTL_LOG"
export PZ_FAKE_PGREP_HIT=1
set +e
out="$(bash "$CTRL" persist-on)"
rc=$?
set -e
export PZ_FAKE_PGREP_HIT=0
[ "$rc" -ne 0 ] || fail "persist-on com Steam deveria falhar: $out"
grep -q '^state=indisponivel$' <<<"$out" || fail "steam state: $out"
grep -q 'steam está ativo' <<<"$out" || fail "steam reason: $out"
grep -q 'enable --now' "$PZ_FAKE_SYSTEMCTL_LOG" && fail "Steam chegou no enable"
grep -q 'MARKER-KEEP' "$PROFILE" || fail "Steam reescreveu o perfil"
test ! -f "$PZ_SCC_CONFIG_DIR/phasezero-revert.pid" || fail "Steam armou timer"
echo "  recusa Steam ok"

echo "=== persist-off só desliga a unit do mapa ==="
printf 'enabled\n' >"$PZ_FAKE_SYSTEMD_STATE/$DESKTOP_UNIT.enabled"
printf 'active\n' >"$PZ_FAKE_SYSTEMD_STATE/$DESKTOP_UNIT.active"
printf 'enabled\n' >"$PZ_FAKE_SYSTEMD_STATE/phasezero-controller-apps.service.enabled"
: >"$PZ_FAKE_SYSTEMCTL_LOG"
out="$(bash "$CTRL" persist-off)"
grep -q '^state=desligado$' <<<"$out" || fail "persist-off: $out"
grep -q '^mutated=1$' <<<"$out" || fail "persist-off mutated: $out"
grep -q "disable --now $DESKTOP_UNIT" "$PZ_FAKE_SYSTEMCTL_LOG" || fail "disable ausente"
grep -q 'phasezero-controller-apps' "$PZ_FAKE_SYSTEMCTL_LOG" && fail "persist-off tocou apps"
[ "$(cat "$PZ_FAKE_SYSTEMD_STATE/phasezero-controller-apps.service.enabled")" = "enabled" ] || fail "apps foi desabilitado"
grep -q 'MARKER-KEEP' "$PROFILE" || fail "persist-off reescreveu o perfil"
echo "  persist-off ok"

echo "=== perfil ausente é instalado; o existente não ==="
rm -f "$PROFILE" "$PZ_SCC_CONFIG_DIR/phasezero-revert.pid"
printf 'disabled\n' >"$PZ_FAKE_SYSTEMD_STATE/$DESKTOP_UNIT.enabled"
printf 'inactive\n' >"$PZ_FAKE_SYSTEMD_STATE/$DESKTOP_UNIT.active"
bash "$CTRL" persist-on >/dev/null
test -f "$PROFILE" || fail "perfil ausente não foi instalado"
grep -q 'MARKER-KEEP' "$PROFILE" && fail "instalação manteve o marcador velho"
test ! -f "$PZ_SCC_CONFIG_DIR/phasezero-revert.pid" || fail "instalação armou timer"
echo "  perfil novo ok"

echo "=== teclado no terminal ==="
printf 'enabled\n' >"$PZ_FAKE_SYSTEMD_STATE/$DESKTOP_UNIT.enabled"
printf 'active\n' >"$PZ_FAKE_SYSTEMD_STATE/$DESKTOP_UNIT.active"
: >"$PZ_FAKE_SYSTEMCTL_LOG"
out="$(bash "$TERM_KBD" persist-status)"
grep -q '^state=desligado$' <<<"$out" || fail "teclado status: $out"
out="$(bash "$TERM_KBD" persist-on)"
grep -q '^state=ligado$' <<<"$out" || fail "teclado on: $out"
grep -q '^mutated=1$' <<<"$out" || fail "teclado mutated: $out"
unit="$PZ_SYSTEMD_USER_DIR/$KEYBOARD_UNIT"
grep -q 'terminal-keyboard.sh watch' "$unit" || fail "unit do teclado sem watch"
grep -q "enable --now $KEYBOARD_UNIT" "$PZ_FAKE_SYSTEMCTL_LOG" || fail "teclado não habilitou"
grep -q "$DESKTOP_UNIT" "$PZ_FAKE_SYSTEMCTL_LOG" && fail "teclado tocou o mapa"
out="$(bash "$TERM_KBD" persist-off)"
grep -q '^state=desligado$' <<<"$out" || fail "teclado off: $out"
grep -q "disable --now $KEYBOARD_UNIT" "$PZ_FAKE_SYSTEMCTL_LOG" || fail "teclado não desligou"
[ "$(cat "$PZ_FAKE_SYSTEMD_STATE/$DESKTOP_UNIT.enabled")" = "enabled" ] || fail "teclado desligou o mapa"
[ "$(cat "$PZ_FAKE_SYSTEMD_STATE/$DESKTOP_UNIT.active")" = "active" ] || fail "teclado parou o mapa"

echo "=== habilitado e parado fica degradado ==="
printf 'enabled\n' >"$PZ_FAKE_SYSTEMD_STATE/$KEYBOARD_UNIT.enabled"
printf 'inactive\n' >"$PZ_FAKE_SYSTEMD_STATE/$KEYBOARD_UNIT.active"
out="$(bash "$TERM_KBD" persist-status)"
grep -q '^state=degradado$' <<<"$out" || fail "degradado: $out"
grep -q 'habilitado no login, mas parado agora' <<<"$out" || fail "motivo degradado: $out"

echo "=== sem systemctl é indisponível ==="
for cmd in dirname basename date mkdir cat chmod cp mv rm realpath; do
    src="$(type -P "$cmd")"
    ln -sfn "$src" "$TMP_ROOT/nosys/$cmd"
done
out="$(PATH="$TMP_ROOT/nosys" /bin/bash "$CTRL" persist-status)"
grep -q '^state=indisponivel$' <<<"$out" || fail "sem systemctl mapa: $out"
out="$(PATH="$TMP_ROOT/nosys" /bin/bash "$TERM_KBD" persist-status)"
grep -q '^state=indisponivel$' <<<"$out" || fail "sem systemctl teclado: $out"

echo "live units unchanged:"
printf '%s\n' "$BEFORE"
echo "linux-steamdeck-desktop-services ok"
