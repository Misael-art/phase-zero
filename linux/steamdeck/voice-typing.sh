#!/usr/bin/env bash
# voice-typing.sh - speak-to-type for keyboard-less hosts (Steam Deck).
# Records the default mic (PipeWire), transcribes locally with whisper.cpp in
# the host language and types the text into the focused window via ydotool
# (uinput works on any compositor, including KWin Wayland where the
# virtual-keyboard protocol is unavailable). Falls back to the clipboard.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PZ_ROOT="$(cd "$DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"
# shellcheck source=./osd.sh
source "$DIR/osd.sh"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/phasezero"
RECORD_PIDFILE="$STATE_DIR/voice-record.pid"
RECORD_WAV="$STATE_DIR/voice-record.wav"
MODEL_DIR="$DATA_DIR/whisper"
MODEL_NAME="${PZ_WHISPER_MODEL:-base}"
MODEL_FILE="$MODEL_DIR/ggml-${MODEL_NAME}.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL_NAME}.bin"
YDOTOOL_SOCKET="${YDOTOOL_SOCKET:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/phasezero-ydotool.sock}"
UDEV_RULE="/etc/udev/rules.d/99-phasezero-uinput.rules"

admin_run() {
    if pz_can_sudo_noninteractive; then
        sudo -n "$@"
    elif command -v phasezero-admin >/dev/null 2>&1; then
        phasezero-admin "$@"
    else
        return 127
    fi
}

whisper_bin() {
    local candidate
    for candidate in whisper-cli whisper-cpp whisper.cpp; do
        if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    if [ -x "$LOCAL_BIN/whisper-cli" ]; then
        printf '%s\n' "$LOCAL_BIN/whisper-cli"
        return 0
    fi
    return 1
}

install_whisper_user_fallback() {
    # The Arch whisper.cpp package ships /usr/bin/stream, which collides with
    # imagemagick. Extract only whisper-cli (+ its lib) into the user prefix
    # and install the conflict-free dependencies system-wide.
    local pkg dest stage archive previous=""
    admin_run pacman -S --needed --noconfirm ggml-git openblas ||
        pz_warn "could not install whisper dependencies (ggml-git, openblas)"
    admin_run pacman -Sw --noconfirm whisper.cpp || true

    pkg=""
    for _pkg_candidate in /var/cache/pacman/pkg/whisper.cpp-*.pkg.tar.*; do
        [ -f "$_pkg_candidate" ] || continue
        case "$_pkg_candidate" in *.sig) continue ;; esac
        pkg="$_pkg_candidate"
    done
    if [ -z "$pkg" ]; then
        pz_warn "whisper.cpp package not found in pacman cache"
        return 1
    fi

    mkdir -p "$DATA_DIR"
    stage="$(mktemp -d "$DATA_DIR/.whisper-cpp-stage.XXXXXX")"
    archive="$stage/package.tar"
    if [ -r "$pkg" ]; then
        cp -- "$pkg" "$archive"
    elif ! admin_run cat "$pkg" > "$archive"; then
        rm -rf "$stage"
        pz_warn "could not read root-owned whisper.cpp package: $pkg"
        return 1
    fi
    chmod 0600 "$archive"
    if ! tar -C "$stage" -xf "$archive" --wildcards 'usr/bin/whisper-cli' 'usr/lib/libwhisper*'; then
        rm -rf "$stage"
        pz_warn "failed to extract whisper-cli from $pkg"
        return 1
    fi
    rm -f "$archive"
    [ -x "$stage/usr/bin/whisper-cli" ] || {
        rm -rf "$stage"
        pz_warn "whisper-cli missing from verified package"
        return 1
    }

    dest="$DATA_DIR/whisper-cpp"
    if [ -e "$dest" ]; then
        previous="$DATA_DIR/.whisper-cpp-previous.$$"
        mv "$dest" "$previous"
    fi
    if ! mv "$stage" "$dest"; then
        [ -z "$previous" ] || mv "$previous" "$dest"
        pz_warn "failed to activate user-local whisper-cli"
        return 1
    fi
    mkdir -p "$LOCAL_BIN"
    if ! pz_write_managed_file "$LOCAL_BIN/whisper-cli" <<EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="$dest/usr/lib:\${LD_LIBRARY_PATH:-}"
exec "$dest/usr/bin/whisper-cli" "\$@"
EOF
    then
        rm -rf "$dest"
        [ -z "$previous" ] || mv "$previous" "$dest"
        return 1
    fi
    chmod +x "$LOCAL_BIN/whisper-cli"
    "$LOCAL_BIN/whisper-cli" --help >/dev/null 2>&1 || {
        rm -rf "$dest"
        if [ -n "$previous" ]; then
            mv "$previous" "$dest"
        else
            rm -f "$LOCAL_BIN/whisper-cli"
        fi
        pz_warn "user-local whisper-cli failed its execution probe"
        return 1
    }
    [ -z "$previous" ] || rm -rf "$previous"
    pz_info "whisper-cli installed for the user: $LOCAL_BIN/whisper-cli"
}

whisper_system_package_conflicts() {
    local owner
    [ -e /usr/bin/stream ] || return 1
    command -v pacman >/dev/null 2>&1 || return 1
    owner="$(pacman -Qqo /usr/bin/stream 2>/dev/null || true)"
    [ -n "$owner" ] && [ "$owner" != "whisper.cpp" ]
}

voice_lang() {
    if [ -n "${PZ_VOICE_LANG:-}" ]; then
        printf '%s\n' "$PZ_VOICE_LANG"
        return 0
    fi
    case "${LANG:-}" in
        C|C.*|POSIX|"") printf 'auto\n' ;;
        *) printf '%s\n' "${LANG%%_*}" ;;
    esac
}

recording_pid() {
    local pid
    [ -f "$RECORD_PIDFILE" ] || return 1
    pid="$(cat "$RECORD_PIDFILE" 2>/dev/null)" || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid"
}

VOICE_SOURCE_FILE="$STATE_DIR/voice-source"

voice_source() {
    if [ -n "${PZ_VOICE_SOURCE:-}" ]; then
        printf '%s\n' "$PZ_VOICE_SOURCE"
        return 0
    fi
    [ -s "$VOICE_SOURCE_FILE" ] && cat "$VOICE_SOURCE_FILE" && return 0
    printf 'default\n'
}

record_cmd() {
    local source="$1" wav="$2" seconds="${3:-}"
    local cmd=(pw-record --rate 16000 --channels 1)
    [ "$source" != "default" ] && cmd+=(--target "$source")
    if [ -n "$seconds" ]; then
        timeout "$seconds" "${cmd[@]}" "$wav" 2>/dev/null || true
    else
        "${cmd[@]}" "$wav"
    fi
}

wav_has_signal() {
    local wav="$1" max
    command -v ffmpeg >/dev/null 2>&1 || return 0
    max="$(ffmpeg -i "$wav" -af volumedetect -f null - 2>&1 |
        grep -o 'max_volume: [-0-9.]*' | grep -o '[-0-9.]*' | head -1)"
    [ -n "$max" ] || return 1
    awk -v m="$max" 'BEGIN { exit (m > -60) ? 0 : 1 }'
}

probe_voice_source() {
    # Some hosts (Steam Deck DMIC) expose a default mic that only delivers
    # digital silence; the usable capture lives behind a filter source like
    # echo-cancel. Probe candidates and persist the first one with signal.
    local candidate wav="$STATE_DIR/voice-probe.wav"
    mkdir -p "$STATE_DIR"
    for candidate in default echo-cancel-source mic-biglinux; do
        [ "$candidate" = "default" ] ||
            pactl list sources short 2>/dev/null | grep -q "$candidate" || continue
        rm -f "$wav"
        record_cmd "$candidate" "$wav" 2
        [ -s "$wav" ] || continue
        if wav_has_signal "$wav"; then
            printf '%s\n' "$candidate" > "$VOICE_SOURCE_FILE"
            pz_info "voice capture source: $candidate"
            rm -f "$wav"
            return 0
        fi
    done
    rm -f "$wav"
    pz_warn "no mic candidate produced signal; keeping 'default' (set PZ_VOICE_SOURCE to override)"
    printf 'default\n' > "$VOICE_SOURCE_FILE"
}

uinput_writable() {
    [ -w /dev/uinput ]
}

ensure_ydotoold() {
    command -v ydotoold >/dev/null 2>&1 || return 1
    [ -S "$YDOTOOL_SOCKET" ] && return 0
    uinput_writable || return 1

    nohup ydotoold --socket-path "$YDOTOOL_SOCKET" \
        --socket-own "$(id -u):$(id -g)" >/dev/null 2>&1 &
    disown 2>/dev/null || true

    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -S "$YDOTOOL_SOCKET" ] && return 0
        sleep 0.3
    done
    return 1
}

type_text() {
    local text="$1"
    if ensure_ydotoold; then
        if YDOTOOL_SOCKET="$YDOTOOL_SOCKET" ydotool type --key-delay 4 -- "$text" >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

voice_setup() {
    if ! whisper_bin >/dev/null; then
        if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
            pz_info "dry-run: would install whisper.cpp"
        else
            pz_info "installing whisper.cpp (local speech-to-text)"
            if whisper_system_package_conflicts; then
                pz_info "/usr/bin/stream belongs to another package; using user-prefix whisper-cli"
                install_whisper_user_fallback ||
                    pz_warn "could not install whisper-cli; voice typing stays disabled"
            elif ! admin_run pacman -S --needed --noconfirm whisper.cpp; then
                pz_warn "system whisper.cpp install failed (likely /usr/bin/stream conflict); using user-prefix fallback"
                install_whisper_user_fallback ||
                    pz_warn "could not install whisper-cli; voice typing stays disabled"
            fi
        fi
    fi

    if ! uinput_writable; then
        if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
            pz_info "dry-run: would grant /dev/uinput access (udev rule + acl)"
        else
            pz_info "granting /dev/uinput access for typing injection"
            if ! printf '%s\n' 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' |
                admin_run tee "$UDEV_RULE" >/dev/null; then
                pz_warn "could not write $UDEV_RULE"
            fi
            admin_run usermod -aG input "$USER" 2>/dev/null ||
                pz_warn "could not add $USER to input group"
            admin_run udevadm control --reload 2>/dev/null || true
            admin_run udevadm trigger /dev/uinput 2>/dev/null || true
            # immediate access without re-login
            admin_run setfacl -m "u:$USER:rw" /dev/uinput 2>/dev/null ||
                pz_warn "could not grant immediate /dev/uinput access; re-login required"
        fi
    fi

    if [ ! -f "$MODEL_FILE" ]; then
        if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
            pz_info "dry-run: would download whisper model $MODEL_NAME to $MODEL_FILE"
        else
            mkdir -p "$MODEL_DIR"
            pz_info "downloading whisper model '$MODEL_NAME' (this can take a while)"
            if curl -L --fail --progress-bar -o "${MODEL_FILE}.part" "$MODEL_URL"; then
                mv "${MODEL_FILE}.part" "$MODEL_FILE"
                pz_info "model saved: $MODEL_FILE"
            else
                rm -f "${MODEL_FILE}.part"
                pz_warn "model download failed: $MODEL_URL"
            fi
        fi
    fi

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would probe mic sources for real signal"
    elif command -v pw-record >/dev/null 2>&1; then
        probe_voice_source
    fi

    pz_info "voice typing setup done (lang: $(voice_lang), source: $(voice_source))"
}

voice_ready() {
    whisper_bin >/dev/null && [ -f "$MODEL_FILE" ] && command -v pw-record >/dev/null 2>&1
}

voice_start() {
    if ! voice_ready; then
        pz_osd_show "audio-input-microphone-muted" "Ditado não configurado — rode: pz steamdeck hotkeys install"
        pz_error "voice typing not ready; run: voice-typing.sh setup"
        return 1
    fi
    if recording_pid >/dev/null; then
        pz_info "already recording"
        return 0
    fi
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would start voice recording"
        return 0
    fi

    mkdir -p "$STATE_DIR"
    rm -f "$RECORD_WAV"
    local source
    source="$(voice_source)"
    if [ "$source" = "default" ]; then
        nohup pw-record --rate 16000 --channels 1 "$RECORD_WAV" >/dev/null 2>&1 &
    else
        nohup pw-record --target "$source" --rate 16000 --channels 1 "$RECORD_WAV" >/dev/null 2>&1 &
    fi
    echo "$!" > "$RECORD_PIDFILE"
    disown 2>/dev/null || true
    pz_osd_show "audio-input-microphone" "🎤 Gravando… Meta+Shift+F8 para parar e digitar"
    pz_info "recording started (pid $(cat "$RECORD_PIDFILE"))"
}

voice_stop() {
    local pid text lang bin txt_base
    pid="$(recording_pid || true)"
    if [ -z "$pid" ]; then
        rm -f "$RECORD_PIDFILE"
        pz_info "no recording in progress"
        return 0
    fi

    kill -INT "$pid" 2>/dev/null || true
    rm -f "$RECORD_PIDFILE"
    local i
    for i in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    kill -9 "$pid" 2>/dev/null || true

    if [ ! -s "$RECORD_WAV" ]; then
        pz_osd_show "audio-input-microphone-muted" "Nada gravado"
        return 0
    fi

    pz_osd_show "view-refresh" "Transcrevendo…"
    bin="$(whisper_bin)"
    lang="$(voice_lang)"
    txt_base="$STATE_DIR/voice-transcript"
    rm -f "${txt_base}.txt"
    "$bin" -m "$MODEL_FILE" -f "$RECORD_WAV" -l "$lang" -t "$(nproc)" -np -otxt -of "$txt_base" >/dev/null 2>&1 || {
        pz_osd_show "dialog-error" "Falha na transcrição"
        return 1
    }

    # drop whisper's non-speech annotations: [MÚSICA], (aplausos), *ruído*
    text="$(tr '\n' ' ' < "${txt_base}.txt" 2>/dev/null |
        sed 's/\[[^][]*\]//g; s/([^()]*)//g; s/\*[^**]*\*//g' |
        tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -z "$text" ]; then
        pz_osd_show "audio-input-microphone-muted" "Transcrição vazia"
        return 0
    fi

    if type_text "$text"; then
        pz_osd_show "input-keyboard" "✓ Texto digitado"
    elif command -v wl-copy >/dev/null 2>&1 && printf '%s' "$text" | wl-copy; then
        pz_osd_show "edit-paste" "Transcrito para o clipboard — cole com Ctrl+Shift+V"
    else
        pz_error "transcribed but could not deliver text: $text"
        return 1
    fi
}

voice_toggle() {
    if recording_pid >/dev/null; then
        voice_stop
    else
        voice_start
    fi
}

voice_status() {
    jq -n \
        --arg lang "$(voice_lang)" \
        --arg source "$(voice_source)" \
        --arg model "$MODEL_FILE" \
        --arg whisper "$(whisper_bin || true)" \
        --argjson modelPresent "$([ -f "$MODEL_FILE" ] && echo true || echo false)" \
        --argjson recorder "$(command -v pw-record >/dev/null 2>&1 && echo true || echo false)" \
        --argjson uinput "$(uinput_writable && echo true || echo false)" \
        --argjson ydotoold "$([ -S "$YDOTOOL_SOCKET" ] && echo true || echo false)" \
        --argjson recording "$(recording_pid >/dev/null && echo true || echo false)" \
        '{
            tool: "voice-typing",
            lang: $lang,
            source: $source,
            whisper: (if $whisper == "" then null else $whisper end),
            model: $model,
            modelPresent: $modelPresent,
            recorder: $recorder,
            uinputWritable: $uinput,
            ydotooldSocket: $ydotoold,
            recording: $recording
        }'
}

case "${1:-status}" in
    setup) voice_setup ;;
    start) voice_start ;;
    stop) voice_stop ;;
    toggle) voice_toggle ;;
    status) voice_status ;;
    dry-run) PZ_DRY_RUN=1 voice_setup ;;
    *) pz_error "usage: voice-typing.sh (setup|start|stop|toggle|status|dry-run)"; exit 1 ;;
esac
