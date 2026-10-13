#!/usr/bin/env bash
# AISR-002: a proxy unit that keeps crashing is "active" for `systemctl
# is-active` between restarts. Status must report crash-loop, not running.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

eval "$(awk '/^port_open\(\) \{/{on=1} on{print} on&&/^}/{exit}' "$ROOT/linux/ai/proxy-suite.sh")"
eval "$(awk '/^unit_service_state\(\) \{/{on=1} on{print} on&&/^}/{exit}' "$ROOT/linux/ai/proxy-suite.sh")"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *is-active*) printf '%s\n' "$PZ_TEST_STATE" ;;
    *NRestarts*) printf '%s\n' "$PZ_TEST_RESTARTS" ;;
esac
STUB
chmod +x "$WORK/bin/systemctl"
PATH="$WORK/bin:$PATH"

# A port nothing listens on.
closed=$((20000 + RANDOM % 20000))
while port_open "$closed"; do closed=$((closed + 1)); done

check() {
    local expected="$1" got
    got="$(PZ_TEST_STATE="$2" PZ_TEST_RESTARTS="$3" unit_service_state qwenproxy "$4")"
    [ "$got" = "$expected" ] || { echo "FAIL: state=$2 restarts=$3 port=$4 -> $got (want $expected)" >&2; exit 1; }
}

check crash-loop active 81 "$closed"
check crash-loop activating 5 "$closed"
check active active 0 "$closed"        # fresh start still warming up
check inactive inactive 81 "$closed"
check failed failed 3 "$closed"

# Listener present: restarts in the past do not make it a crash-loop.
python3 -c 'import socket,time,sys; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); print(s.getsockname()[1], flush=True); time.sleep(30)' > "$WORK/port" &
listener=$!
for _ in $(seq 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
check active active 81 "$(cat "$WORK/port")"
kill "$listener" 2>/dev/null || true

# shellcheck disable=SC2016 # Match literal shell source.
grep -c 'service="$(unit_service_state "$id" "$port")"' "$ROOT/linux/ai/proxy-suite.sh" | grep -qx 3
# shellcheck disable=SC2016 # Match literal shell source.
if grep -q 'service="$(systemctl --user is-active' "$ROOT/linux/ai/proxy-suite.sh"; then exit 1; fi

echo "PASS: crash-looping proxy reported as crash-loop"
