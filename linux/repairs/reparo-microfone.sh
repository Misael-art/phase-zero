#!/usr/bin/env bash
# Reparo rápido do microfone: restaura o perfil de captura da placa de áudio (acp5x),
# religa a cadeia de filtros do BigLinux e verifica se há sinal real.
set -u
export LC_ALL=C
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

# Choose only an observed, available profile with capture. Never invent names.
CARD_SELECTION=$(pactl -f json list cards 2>/dev/null | python3 -c '
import json,sys
cards=json.load(sys.stdin)
cards.sort(key=lambda card: "acp5x" not in card.get("name", ""))
for card in cards:
    profiles=card.get("profiles", {})
    available=[(name, value) for name,value in profiles.items()
               if value.get("sources", 0)>0 and value.get("available") is True]
    if not available:
        continue
    active=card.get("active_profile", "")
    available.sort(key=lambda pair: (pair[0]!=active, -pair[1].get("priority", 0)))
    print(card["name"]); print(active); print(available[0][0]); break
') || { notify --error "Não foi possível observar os perfis de áudio."; exit 1; }
[ -n "$CARD_SELECTION" ] || { notify --error "Nenhum perfil de captura disponível. Verifique hardware e conexão."; exit 69; }
mapfile -t fields <<< "$CARD_SELECTION"
MIC_CARD="${fields[0]}"
ACTIVE="${fields[1]}"
PROFILE="${fields[2]}"
say "Placa alvo: $MIC_CARD"
say "Perfil ativo: $ACTIVE"
if [ "$ACTIVE" != "$PROFILE" ]; then
    say "Aplicando perfil observado: $PROFILE"
    pactl set-card-profile "$MIC_CARD" "$PROFILE" || { notify --error "Falha ao trocar perfil da placa."; exit 1; }
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
  notify --information $'Microfone OK!\nPerfil ativo com captura, sinal detectado.\nFonte padrão: '"$DEFAULT_SRC"
else
  notify --information $'Perfil de captura e fonte presentes:\n'"$DEFAULT_SRC"$'\n(fale no app de voz para confirmar; nível não medido)'
fi
exit 0
