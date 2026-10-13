#!/usr/bin/env bash
# homelab-hosts.sh — admin-side host registry + SSH bridge (--host).
#
# Lives on the admin/consumer machine. Never stores private keys, passwords
# or app tokens. JSON on stdout, logs on stderr.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=linux/lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

SCHEMA_VERSION="1"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
REG_DIR="${PZ_HOMELAB_HOSTS_DIR:-$CONFIG_HOME/phasezero}"
REG_FILE="${PZ_HOMELAB_HOSTS_FILE:-$REG_DIR/homelab-hosts.json}"
LOCK_FILE="${PZ_HOMELAB_HOSTS_LOCK:-$REG_DIR/homelab-hosts.lock}"
SSH_BIN="${PZ_HOMELAB_SSH_BIN:-ssh}"
SSH_TIMEOUT="${PZ_HOMELAB_SSH_TIMEOUT:-8}"
# Floor, not "equal to this checkout". A 1.18 admin must still talk to a
# 1.17.4 appliance. Override with PZ_HOMELAB_REMOTE_MIN_VERSION for tests.
MIN_VERSION="${PZ_HOMELAB_REMOTE_MIN_VERSION:-1.17.4}"

SUB="${1:-list}"
shift 2>/dev/null || true

JSON_OUTPUT=0
ALIAS=""
TARGET=""
PAIR_GENERATE=0
PAIR_KEY=""
# UX-008: first contact may be completed from the interface. The password is
# read from stdin only — never an argument, never an environment variable,
# never written to the registry or to a log.
PAIR_PASSWORD_STDIN=0
PAIR_TIMEOUT="${PZ_HOMELAB_PAIR_TIMEOUT:-60}"
SSH_COPY_ID_BIN="${PZ_HOMELAB_SSH_COPY_ID_BIN:-ssh-copy-id}"
POSITIONAL=()

usage() {
    cat <<EOF
Usage:
  homelab-hosts.sh add <alias> <user@host[:port]> [--json]
  homelab-hosts.sh list [--json]
  homelab-hosts.sh remove <alias> [--json]
  homelab-hosts.sh ping <alias> [--json]
  homelab-hosts.sh pair <alias> [--generate] [--key PATH] [--password-stdin]
                                [--timeout SECONDS] [--json]
  homelab-hosts.sh exec <alias> -- <homelab-args...>
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --json) JSON_OUTPUT=1 ;;
        --generate) PAIR_GENERATE=1 ;;
        --password-stdin) PAIR_PASSWORD_STDIN=1 ;;
        --timeout)
            [ "${2:-}" ] || { pz_error "--timeout requires seconds"; exit 2; }
            PAIR_TIMEOUT="$2"
            shift
            ;;
        --timeout=*) PAIR_TIMEOUT="${1#--timeout=}" ;;
        --key)
            [ "${2:-}" ] || { pz_error "--key requires a path"; exit 2; }
            PAIR_KEY="$2"
            shift
            ;;
        --key=*) PAIR_KEY="${1#--key=}" ;;
        --help|-h) usage; exit 0 ;;
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*)
            pz_error "unexpected flag: $1"
            exit 2
            ;;
        *)
            POSITIONAL+=("$1")
            ;;
    esac
    shift
done

empty_registry() {
    jq -cn --argjson schemaVersion 1 --arg tool "homelab-hosts" \
        '{schemaVersion:$schemaVersion, tool:$tool, hosts:[]}'
}

read_registry() {
    if [ ! -f "$REG_FILE" ]; then
        empty_registry
        return 0
    fi
    local raw
    raw="$(cat "$REG_FILE" 2>/dev/null || true)"
    if ! jq -e '.schemaVersion == 1 and .tool == "homelab-hosts" and (.hosts | type == "array")' \
        <<< "$raw" >/dev/null 2>&1; then
        pz_error "hosts registry corrupt: $REG_FILE"
        return 1
    fi
    if jq -e '
        .hosts[]
        | select(
            (.privateKey != null) or (.password != null) or (.token != null)
            or (.identityFile != null) or (.secret != null)
          )
    ' <<< "$raw" >/dev/null 2>&1; then
        pz_error "hosts registry contains private material: $REG_FILE"
        return 1
    fi
    printf '%s\n' "$raw"
}

hosts_lock() {
    mkdir -p "$REG_DIR"
    chmod 0700 "$REG_DIR" 2>/dev/null || true
    exec 8>"$LOCK_FILE"
    if ! flock -w 10 8; then
        pz_error "another homelab hosts operation is running"
        return 1
    fi
}

hosts_unlock() {
    flock -u 8 2>/dev/null || true
}

write_registry() {
    local json="$1" tmp
    mkdir -p "$REG_DIR"
    chmod 0700 "$REG_DIR" 2>/dev/null || true
    if ! jq -e '.schemaVersion == 1 and (.hosts | type == "array")' <<< "$json" >/dev/null 2>&1; then
        pz_error "refusing to write invalid hosts registry"
        return 1
    fi
    tmp="$(pz_tempfile)"
    printf '%s\n' "$json" > "$tmp"
    install -m 0600 "$tmp" "$REG_FILE"
    rm -f "$tmp"
}

local_version() {
    printf '%s\n' "$MIN_VERSION"
}

version_ge() {
    local have="$1" need="$2" first
    first="$(printf '%s\n%s\n' "$have" "$need" | sort -V | head -1)"
    [ "$first" = "$need" ]
}

parse_target() {
    local spec="$1" user host port=22 rest
    case "$spec" in
        */*|*[[:space:]]*|*'|'*)
            pz_error "invalid host target (path or whitespace not allowed)"
            return 2
            ;;
    esac
    case "$spec" in
        *@*) ;;
        *)
            pz_error "target must be user@host[:port]"
            return 2
            ;;
    esac
    user="${spec%%@*}"
    rest="${spec#*@}"
    case "$rest" in
        *:*)
            host="${rest%:*}"
            port="${rest##*:}"
            ;;
        *) host="$rest" ;;
    esac
    if ! [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then
        pz_error "invalid user"
        return 2
    fi
    if ! [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]]; then
        pz_error "invalid host"
        return 2
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        pz_error "invalid port"
        return 2
    fi
    printf '%s %s %s\n' "$user" "$host" "$port"
}

valid_alias() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

valid_product_status_target() {
    case "$1" in
        ai-memory|usagebar|claude-desktop|codex-desktop|qwen-code-desktop) return 0 ;;
        *) return 1 ;;
    esac
}

host_record() {
    local alias="$1" reg
    reg="$(read_registry)" || return $?
    jq -c --arg a "$alias" '.hosts[] | select(.alias == $a)' <<< "$reg" | head -1
}

make_id() {
    local alias="$1"
    printf 'hlh-%s\n' "$(printf '%s' "$alias" | sha256sum | awk '{print substr($1,1,12)}')"
}

ssh_base_args() {
    local port="$1"
    printf '%s\n' \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=no \
        -p "$port"
}

run_ssh() {
    local user="$1" host="$2" port="$3"
    shift 3
    local -a opts=()
    mapfile -t opts < <(ssh_base_args "$port")
    "$SSH_BIN" "${opts[@]}" "$user@$host" "$@"
}

remote_pz_bin() {
    # PZ-AUD-001: `pz` is on PATH for packaged installs; fall back to the
    # payload path for manual checkouts. PZ_REMOTE_PZ_BIN wins when set.
    if [ -n "${PZ_REMOTE_PZ_BIN:-}" ]; then
        printf '%s\n' "$PZ_REMOTE_PZ_BIN"
        return 0
    fi
    printf '%s\n' "pz"
    return 0
}

remote_pz_fallback_bin() {
    if [ -n "${PZ_REMOTE_PZ_BIN:-}" ]; then
        return 1
    fi
    printf '%s\n' "/usr/lib/phasezero/linux/pz"
    return 0
}

run_remote_pz() {
    # Run `pz ...` on the remote host, retrying once via the payload path
    # when `pz` is not on the remote PATH.
    local user="$1" host="$2" port="$3"
    shift 3
    local bin fallback out rc=0
    bin="$(remote_pz_bin)"
    set +e
    out="$(run_ssh "$user" "$host" "$port" "$bin" "$@" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ] && fallback="$(remote_pz_fallback_bin)" && [ "$bin" != "$fallback" ]; then
        set +e
        out="$(run_ssh "$user" "$host" "$port" "$fallback" "$@" 2>&1)"
        rc=$?
        set -e
    fi
    printf '%s' "$out"
    return "$rc"
}

cmd_list() {
    local reg
    reg="$(read_registry)" || return $?
    local payload
    payload="$(jq -c --arg schemaVersion "$SCHEMA_VERSION" \
        '. + {schemaVersion:$schemaVersion, action:"list"}' <<< "$reg")"
    if [ "$JSON_OUTPUT" = "1" ]; then
        printf '%s\n' "$payload"
        return 0
    fi
    echo "$payload" | jq -r '
        "PhaseZero Homelab hosts",
        (if (.hosts|length)==0 then "  (none)" else (.hosts[] | "  - \(.alias)\t\(.user)@\(.host):\(.port)") end)
    '
}

cmd_add() {
    local alias="${POSITIONAL[0]:-}" spec="${POSITIONAL[1]:-}"
    if [ -z "$alias" ] || [ -z "$spec" ]; then
        pz_error "usage: hosts add <alias> <user@host[:port]>"
        return 2
    fi
    valid_alias "$alias" || { pz_error "invalid alias"; return 2; }
    local user host port
    read -r user host port < <(parse_target "$spec") || return $?
    hosts_lock || return 1
    local reg rec id
    reg="$(read_registry)" || { hosts_unlock; return 1; }
    rec="$(jq -c --arg a "$alias" '.hosts[] | select(.alias == $a)' <<< "$reg" | head -1 || true)"
    id="$(make_id "$alias")"
    if [ -n "$rec" ]; then
        if ! jq -e --arg u "$user" --arg h "$host" --argjson p "$port" \
            '.user == $u and .host == $h and .port == $p' <<< "$rec" >/dev/null 2>&1; then
            hosts_unlock
            pz_error "alias $alias already registered to a different target"
            return 1
        fi
        hosts_unlock
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
            --arg action "add" --argjson ok true --argjson already true --argjson host "$rec" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, ok:$ok, already:$already, host:$host}'
        return 0
    fi
    local now new_host new_reg
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    new_host="$(jq -cn --arg id "$id" --arg alias "$alias" --arg user "$user" \
        --arg host "$host" --argjson port "$port" --arg addedAt "$now" \
        '{id:$id, alias:$alias, user:$user, host:$host, port:$port, addedAt:$addedAt}')"
    new_reg="$(jq -c --argjson h "$new_host" '.hosts += [$h]' <<< "$reg")"
    write_registry "$new_reg" || { hosts_unlock; return 1; }
    hosts_unlock
    jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
        --arg action "add" --argjson ok true --argjson already false --argjson host "$new_host" \
        '{schemaVersion:$schemaVersion, tool:$tool, action:$action, ok:$ok, already:$already, host:$host}'
}

cmd_remove() {
    local alias="${POSITIONAL[0]:-}"
    [ -n "$alias" ] || { pz_error "usage: hosts remove <alias>"; return 2; }
    hosts_lock || return 1
    local reg rec
    reg="$(read_registry)" || { hosts_unlock; return 1; }
    rec="$(jq -c --arg a "$alias" '.hosts[] | select(.alias == $a)' <<< "$reg" | head -1 || true)"
    if [ -z "$rec" ]; then
        hosts_unlock
        pz_error "unknown host alias: $alias"
        return 2
    fi
    write_registry "$(jq -c --arg a "$alias" '.hosts |= map(select(.alias != $a))' <<< "$reg")" \
        || { hosts_unlock; return 1; }
    hosts_unlock
    jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
        --arg action "remove" --argjson ok true --arg alias "$alias" \
        '{schemaVersion:$schemaVersion, tool:$tool, action:$action, ok:$ok, alias:$alias}'
}

extract_version() {
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

cmd_ping() {
    local alias="${POSITIONAL[0]:-}" rec
    [ -n "$alias" ] || { pz_error "usage: hosts ping <alias>"; return 2; }
    rec="$(host_record "$alias")" || return $?
    if [ -z "$rec" ]; then
        pz_error "unknown host alias: $alias"
        return 2
    fi
    local user host port out rc=0 ver="" err=""
    user="$(jq -r '.user' <<< "$rec")"
    host="$(jq -r '.host' <<< "$rec")"
    port="$(jq -r '.port' <<< "$rec")"
    local errf
    errf="$(pz_tempfile)"
    set +e
    out="$(run_remote_pz "$user" "$host" "$port" --version 2>"$errf")"
    rc=$?
    set -e
    err="$(tr -d '\0' < "$errf" 2>/dev/null | tail -1 || true)"
    rm -f "$errf"
    ver="$(printf '%s' "$out" | extract_version || true)"
    if [ "$rc" -ne 0 ]; then
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
            --arg action "ping" --arg hostAlias "$alias" --argjson ok false \
            --argjson reachable false --argjson rc "$rc" --arg error "${err:-host unreachable}" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
              ok:$ok, reachable:$reachable, rc:$rc, error:$error, remoteVersion:null}'
        return 1
    fi
    jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
        --arg action "ping" --arg hostAlias "$alias" --argjson ok true \
        --argjson reachable true --arg remoteVersion "$ver" \
        '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
          ok:$ok, reachable:$reachable, rc:0, error:null, remoteVersion:$remoteVersion}'
}

cmd_exec() {
    local alias="${POSITIONAL[0]:-}"
    [ -n "$alias" ] || { pz_error "usage: hosts exec <alias> -- <args>"; return 2; }
    local rec
    rec="$(host_record "$alias")" || return $?
    if [ -z "$rec" ]; then
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
            --arg action "exec" --arg hostAlias "$alias" --argjson rc 2 \
            --arg error "unknown host alias: $alias" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
              rc:$rc, payload:null, error:$error}'
        return 2
    fi
    local -a inner=("${POSITIONAL[@]:1}") remote_args=()
    if [ "${inner[0]:-}" = "product-status" ]; then
        if [ "${#inner[@]}" -eq 3 ] && [ "${inner[2]}" = "--json" ]; then
            inner=("${inner[@]:0:2}")
        fi
        if [ "${#inner[@]}" -ne 2 ] || ! valid_product_status_target "${inner[1]:-}"; then
            pz_error "unsupported remote product status target"
            return 2
        fi
        # PXA-003: this one status-only route calls a fixed read-only adapter.
        # All other host operations remain under `server homelab` allowlisting.
        remote_args=(ai product-status "${inner[1]}")
    else
        remote_args=(server homelab "${inner[@]}")
    fi
    local user host port
    user="$(jq -r '.user' <<< "$rec")"
    host="$(jq -r '.host' <<< "$rec")"
    port="$(jq -r '.port' <<< "$rec")"
    local need ver out rc=0 err="" payload="null"
    need="$(local_version)"
    local errf
    errf="$(pz_tempfile)"
    set +e
    out="$(run_remote_pz "$user" "$host" "$port" --version 2>"$errf")"
    rc=$?
    set -e
    err="$(tr -d '\0' < "$errf" 2>/dev/null | tail -1 || true)"
    rm -f "$errf"
    if [ "$rc" -ne 0 ]; then
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
            --arg action "exec" --arg hostAlias "$alias" --argjson rc "$rc" \
            --arg error "${err:-host unreachable (ssh fail-closed)}" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
              rc:$rc, payload:null, error:$error}'
        return 1
    fi
    ver="$(printf '%s' "$out" | extract_version || true)"
    if [ -z "$ver" ] || ! version_ge "$ver" "$need"; then
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
            --arg action "exec" --arg hostAlias "$alias" --argjson rc 69 \
            --arg error "remote PhaseZero $ver is older than required $need" \
            --arg remoteVersion "$ver" --arg required "$need" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
              rc:$rc, payload:null, error:$error, remoteVersion:$remoteVersion, requiredVersion:$required}'
        return 69
    fi
    if [ "${#inner[@]}" -eq 0 ]; then
        inner=(status --json)
        remote_args=(server homelab "${inner[@]}")
    fi
    local stdout rc2=0 errf2
    errf2="$(pz_tempfile)"
    set +e
    stdout="$(run_remote_pz "$user" "$host" "$port" "${remote_args[@]}" 2>"$errf2")"
    rc2=$?
    set -e
    err="$(tr '\n' ' ' < "$errf2" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
    rm -f "$errf2"
    if printf '%s' "$stdout" | jq -e . >/dev/null 2>&1; then
        payload="$(printf '%s' "$stdout" | jq -c .)"
    elif [ -n "$stdout" ]; then
        err="${err:-remote stdout was not JSON}"
    fi
    jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
        --arg action "exec" --arg hostAlias "$alias" --argjson rc "$rc2" \
        --argjson payload "$payload" --arg error "$err" --arg remoteVersion "$ver" \
        '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
          rc:$rc, payload:$payload, error:(if $error == "" then null else $error end),
          remoteVersion:$remoteVersion}'
    [ "$rc2" -eq 0 ]
}

pair_key_path() {
    # PZ-AUD-014: explicit --key wins; otherwise existing ed25519, then rsa.
    # Prints the .pub path or nothing.
    if [ -n "$PAIR_KEY" ]; then
        case "$PAIR_KEY" in
            *.pub) [ -f "$PAIR_KEY" ] && printf '%s\n' "$PAIR_KEY" ;;
            *) [ -f "$PAIR_KEY.pub" ] && printf '%s\n' "$PAIR_KEY.pub" ;;
        esac
        return 0
    fi
    local ssh_dir="${HOME}/.ssh"
    if [ -f "$ssh_dir/id_ed25519.pub" ]; then
        printf '%s\n' "$ssh_dir/id_ed25519.pub"
    elif [ -f "$ssh_dir/id_rsa.pub" ]; then
        printf '%s\n' "$ssh_dir/id_rsa.pub"
    fi
    return 0
}

pair_generate_key() {
    # PZ-AUD-014: create an automation keypair only on explicit --generate.
    # No passphrase (automation), 0600, refuses to overwrite. The operator
    # invoked pairing deliberately; the key type and path are reported.
    local priv="${HOME}/.ssh/id_ed25519"
    [ -e "$priv" ] || [ -e "$priv.pub" ] || {
        mkdir -p "${HOME}/.ssh"
        chmod 0700 "${HOME}/.ssh"
        ssh-keygen -t ed25519 -N "" -C "phasezero-homelab" -f "$priv" >/dev/null 2>&1 || return 1
        chmod 0600 "$priv" "$priv.pub"
        printf '%s\n' "$priv.pub"
        return 0
    }
    return 1
}

pair_first_contact() {
    # UX-008: complete the very first pairing without an external terminal.
    #
    # The password arrives on stdin and never leaves this function: it is
    # handed to ssh through an askpass helper reading a 0600 file inside a
    # 0700 private directory, both destroyed on every exit path. It is never
    # an argument (visible in /proc and in `ps`), never an environment
    # variable, and never echoed to stdout/stderr. `timeout` bounds the wait
    # so a host that never answers cannot hang the interface, and killing
    # this process is a safe cancel.
    local user="$1" host="$2" port="$3" pub="$4"
    local password="" dir="" rc=0 err=""

    IFS= read -r password || true
    if [ -z "$password" ]; then
        printf 'empty-password\n'
        return 2
    fi

    dir="$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/pz-pair.XXXXXX")"
    chmod 700 "$dir"
    # shellcheck disable=SC2064 # expand $dir now: it is what must be removed
    trap "rm -rf -- '$dir'" RETURN
    (umask 077; printf '%s' "$password" > "$dir/secret")
    password=""
    {
        printf '#!/usr/bin/env bash\n'
        printf 'cat -- %q\n' "$dir/secret"
    } > "$dir/askpass"
    chmod 700 "$dir/askpass"

    local errf
    errf="$dir/stderr"
    set +e
    SSH_ASKPASS="$dir/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" \
        setsid -w timeout "$PAIR_TIMEOUT" "$SSH_COPY_ID_BIN" \
            -o StrictHostKeyChecking=accept-new \
            -o PreferredAuthentications=password,keyboard-interactive \
            -o NumberOfPasswordPrompts=1 \
            -o ConnectTimeout="$SSH_TIMEOUT" \
            -i "$pub" -p "$port" "$user@$host" </dev/null 2>"$errf"
    rc=$?
    set -e
    err="$(tr -d '\0' < "$errf" 2>/dev/null | tail -1 || true)"

    if [ "$rc" -eq 0 ]; then
        printf 'paired\n'
        return 0
    fi
    if [ "$rc" -eq 124 ]; then
        printf 'timeout\n'
        return 1
    fi
    case "${err,,}" in
        *"permission denied"*|*"authentication fail"*)
            printf 'auth-failed\n' ;;
        *"could not resolve"*|*"connection refused"*|*"no route to host"*|*"connection timed out"*)
            printf 'unreachable\n' ;;
        *) printf 'first-contact-failed\n' ;;
    esac
    return 1
}

cmd_pair() {
    local alias="${POSITIONAL[0]:-}" rec
    [ -n "$alias" ] || { pz_error "usage: hosts pair <alias> [--generate] [--key PATH]"; return 2; }
    rec="$(host_record "$alias")" || return $?
    if [ -z "$rec" ]; then
        pz_error "unknown host alias: $alias"
        return 2
    fi
    local user host port pub generated=false guidance=""
    user="$(jq -r '.user' <<< "$rec")"
    host="$(jq -r '.host' <<< "$rec")"
    port="$(jq -r '.port' <<< "$rec")"
    pub="$(pair_key_path)"
    if [ -z "$pub" ] && [ "$PAIR_GENERATE" = "1" ]; then
        if pub="$(pair_generate_key)"; then
            generated=true
        fi
    fi
    if [ -z "$pub" ]; then
        guidance="no SSH key found; re-run with --generate or create one: ssh-keygen -t ed25519"
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
            --arg action "pair" --arg hostAlias "$alias" --arg guidance "$guidance" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
              ok:false, paired:false, state:"missing-key", keyPath:null, generated:false, guidance:$guidance}'
        return 1
    fi
    local errf rc=0
    errf="$(pz_tempfile)"
    set +e
    # PZ-AUD-014: the registry port is always honored (-p). BatchMode keeps
    # this non-interactive: first contact needs a terminal login, reported
    # below with the exact command (port included), never attempted blind.
    if command -v ssh-copy-id >/dev/null 2>&1; then
        ssh-copy-id -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
            -o StrictHostKeyChecking=accept-new -i "$pub" -p "$port" "$user@$host" 2>"$errf"
        rc=$?
    else
        echo "ssh-copy-id not found" >"$errf"
        rc=127
    fi
    set -e
    local err
    err="$(tr -d '\0' < "$errf" 2>/dev/null | tail -1 || true)"
    rm -f "$errf"
    if [ "$rc" -eq 0 ]; then
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
            --arg action "pair" --arg hostAlias "$alias" --arg keyPath "$pub" \
            --argjson generated "$generated" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
              ok:true, paired:true, state:"paired", keyPath:$keyPath, generated:$generated, guidance:null}'
        return 0
    fi
    # UX-008: with a password on stdin, first contact is completed here
    # instead of being handed back as a terminal command to copy.
    if [ "$PAIR_PASSWORD_STDIN" = "1" ]; then
        local contact_state
        contact_state="$(pair_first_contact "$user" "$host" "$port" "$pub")" || true
        if [ "$contact_state" = "paired" ]; then
            jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
                --arg action "pair" --arg hostAlias "$alias" --arg keyPath "$pub" \
                --argjson generated "$generated" \
                '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
                  ok:true, paired:true, state:"paired", keyPath:$keyPath,
                  generated:$generated, firstContact:true, guidance:null}'
            return 0
        fi
        guidance="$(
            case "$contact_state" in
                auth-failed) printf 'senha recusada pelo servidor; confira usuário e senha e tente de novo' ;;
                empty-password) printf 'nenhuma senha informada' ;;
                timeout) printf 'o servidor não respondeu a tempo (%ss); confira se ele está ligado e acessível' "$PAIR_TIMEOUT" ;;
                unreachable) printf 'não foi possível alcançar o servidor; confira endereço, porta e rede' ;;
                *) printf 'primeiro acesso não pôde ser concluído' ;;
            esac
        )"
        jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
            --arg action "pair" --arg hostAlias "$alias" --arg keyPath "$pub" \
            --argjson generated "$generated" --arg state "$contact_state" \
            --arg guidance "$guidance" \
            '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
              ok:false, paired:false, state:$state, keyPath:$keyPath,
              generated:$generated, firstContact:true, guidance:$guidance}'
        return 1
    fi
    guidance="first contact needs one terminal login (port $port honored): ssh-copy-id -i $pub -p $port $user@$host — then re-run pair"
    jq -cn --arg schemaVersion "$SCHEMA_VERSION" --arg tool "homelab-hosts" \
        --arg action "pair" --arg hostAlias "$alias" --arg keyPath "$pub" \
        --argjson generated "$generated" --arg reason "${err:-exit $rc}" --arg guidance "$guidance" \
        '{schemaVersion:$schemaVersion, tool:$tool, action:$action, hostAlias:$hostAlias,
          ok:false, paired:false, state:"needs-first-contact", keyPath:$keyPath,
          generated:$generated, reason:$reason, guidance:$guidance}'
    return 1
}

case "$SUB" in
    list) cmd_list ;;
    add) cmd_add ;;
    remove) cmd_remove ;;
    ping) cmd_ping ;;
    pair) cmd_pair ;;
    exec) cmd_exec ;;
    *)
        usage >&2
        exit 2
        ;;
esac
