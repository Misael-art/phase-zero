#!/usr/bin/env bash
# Register entry points for development tools and IA & Dev agent cards.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
source "$PZ_ROOT/linux/lib/desktop.sh"

launcher="${1:-$(command -v phasezero-control-center || true)}"
if [[ "$launcher" != /* || ! -x "$launcher" || "$launcher" =~ [[:cntrl:]] ]]; then
    pz_error "PhaseZero Central de Controle indisponível para registrar atalhos"
    exit 1
fi
case "$launcher" in
    *'"'*|*\\*|*'$'*|*'`'*|*'%'*) pz_error "Caminho do launcher incompatível com atalhos"; exit 1 ;;
esac

for agent in deepseek-harness grok-build vibe-code; do
    target="$PZ_APPLICATIONS_DIR/phasezero-$agent.desktop"
    if [ -L "$target" ] || { [ -e "$target" ] && ! grep -qx 'X-PhaseZero-Managed=true' "$target"; }; then
        pz_error "Atalho existente preservado: $target"
        exit 1
    fi
done

write_shortcut() {
    local agent="$1" label="$2" description="$3" icon="$4" launcher_args="$5" group="$6" content target
    target="$PZ_APPLICATIONS_DIR/phasezero-$agent.desktop"
    content="$(cat <<EOF
[Desktop Entry]
Type=Application
Name=$label
Comment=$description
Exec="$launcher" $launcher_args
Icon=$icon
Terminal=false
Categories=X-PhaseZero;
StartupNotify=true
EOF
)"
    if [ -f "$target" ] && [ "$(cat "$target")" = "$(printf '%s\nX-PhaseZero-Managed=true\nX-PhaseZero-MenuGroup=%s' "$content" "$group")" ]; then
        return
    fi
    printf '%s\n' "$content" | pz_desktop_write_entry "$target" "$group"
}

write_shortcut deepseek-harness 'DeepSeek Harness' 'Conectar ou abrir o Harness no navegador' internet-web-browser '--journey deepseek-harness' web.ai
write_shortcut grok-build 'Grok Build' 'Abrir um projeto no agente de terminal' utilities-terminal '--journey grok-build' web.ai
write_shortcut vibe-code 'Vibe Code' 'Abrir ou retomar uma pasta de projeto' applications-development '--vibe-code' system.tools
python3 "$PZ_ROOT/linux/ui/menu.py" sync
