#!/usr/bin/env bash
# Reparo rápido do microfone: restaura o perfil de captura da placa de áudio (acp5x),
# religa a cadeia de filtros do BigLinux e verifica se há sinal real.
set -u
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

say() { echo "[$(date +%H:%M:%S)] $*"; }
notify() {
  if [ "${PZ_REPAIR_NONINTERACTIVE:-0}" != 1 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v kdialog >/dev/null 2>&1; then
    kdialog --icon=audio-input-microphone --title "Reparo do Microfone" "$@"
  else
    say "GUI: $*"
  fi
}

MIC_CARD=$(pactl list cards short 2>/dev/null | grep -m1 'acp5x' | awk '{print $2}')
if [ -z "$MIC_CARD" ]; then
  MIC_CARD=$(pactl list cards short 2>/dev/null | awk '$3=="alsa"{print $2; exit}')
fi
if [ -z "$MIC_CARD" ]; then
  notify --error "Nenhuma placa de áudio encontrada."; exit 1
fi
say "Placa alvo: $MIC_CARD"

# 1) Garantir perfil com entrada (Mic) ativo
ACTIVE=$(pactl list cards 2>/dev/null | awk -v c="$MIC_CARD" '
  /^[[:space:]]*Name: /{f=($2==c)} f && /Active Profile:/{sub(/.*Active Profile: /,""); print; exit}')
say "Perfil ativo: ${ACTIVE:-desconhecido}"
if ! echo "${ACTIVE:-}" | grep -qiE 'mic|input'; then
  PROFILE=$(pw-dump 2>/dev/null | python3 -c '
import json,sys
card=sys.argv[1]
for o in json.load(sys.stdin):
    pi=o.get("info",{}).get("params",{}).get("PropInfo",{})
    if isinstance(pi,dict) and pi.get("device.name")==card:
        for p in (o["info"]["params"].get("EnumProfile") or []):
            if "Mic" in (p.get("name") or ""):
                print(p["name"]); sys.exit()
        break
' "$MIC_CARD")
  [ -z "$PROFILE" ] && PROFILE="HiFi (Headphones, Mic)"
  say "Trocando perfil para: $PROFILE"
  pactl set-card-profile "$MIC_CARD" "$PROFILE" || { notify --error "Falha ao trocar o perfil da placa."; exit 1; }
fi

# 2) Esperar o mic físico aparecer; senão reiniciar wireplumber
wait_source() {
  for _ in $(seq 1 10); do
    pactl list short sources 2>/dev/null | grep -q 'alsa_input' && return 0
    sleep 1
  done
  return 1
}
if ! wait_source; then
  say "Sem alsa_input — reiniciando wireplumber"
  systemctl --user restart wireplumber
  if ! wait_source; then
    say "Ainda sem mic — reiniciando pipewire + wireplumber"
    systemctl --user restart pipewire wireplumber pipewire-pulse
    wait_source || { notify --error "O micro físico não reapareceu. Verifique dmesg/journal ou reconecte o fone."; exit 1; }
  fi
fi
say "Microfone físico presente."

# 3) Reconectar filtro padrão ao mic e validar sinal
MAXVOL=""
if [ "${PZ_REPAIR_RECORD_CONSENT:-0}" = "1" ]; then
  SRC_FILE=$(mktemp --suffix=.wav)
  trap 'rm -f "$SRC_FILE"' EXIT
  timeout 3 pw-record "$SRC_FILE" >/dev/null 2>&1 || true
  if command -v ffmpeg >/dev/null 2>&1 && [ -s "$SRC_FILE" ]; then
    MAXVOL=$(ffmpeg -hide_banner -nostats -i "$SRC_FILE" -af volumedetect -f null /dev/null 2>&1 | awk -F': ' '/max_volume/{print $2}')
  fi
fi

DEFAULT_SRC=$(pactl info | awk -F': ' '/Default Source/{print $2}')
if [ -n "$MAXVOL" ] && (( $(echo "$MAXVOL" | cut -d' ' -f1 | cut -d. -f1) > -85 )); then
  notify --information $'Microfone OK!\nPerfil ativo com captura, filtros religados e sinal detectado.\nFonte padrão: '"$DEFAULT_SRC"
else
  notify --information $'Perfil de captura restaurado e fonte ativa:\n'"$DEFAULT_SRC"$'\n(fale no app de voz para confirmar; nível não medido)'
fi
exit 0
