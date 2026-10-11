#!/usr/bin/env bash
# export-deck-shortcuts.sh - turn PhaseZero-Desktop.sccprofile into the
# panel widget's shortcut map. The profile is the only source.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${PZ_DECK_PROFILE:-$DIR/profiles/PhaseZero-Desktop.sccprofile}"
OUT="${1:-}"

python3 - "$PROFILE" "$OUT" <<'PY'
import json
import re
import sys
from pathlib import Path

profile_path, out_path = sys.argv[1], sys.argv[2]
data = json.loads(Path(profile_path).read_text(encoding="utf-8"))

LABELS = {
    "A": "A",
    "B": "B",
    "X": "X",
    "Y": "Y",
    "LB": "L1",
    "RB": "R1",
    "LGRIP": "L4",
    "RGRIP": "R4",
    "LGRIP2": "L5",
    "RGRIP2": "R5",
    "BACK": "View",
    "START": "Menu",
    "DOTS": "…",
    "RPAD": "Trackpad direito",
    "dpad": "Direcional",
    "lstick": "Analógico esquerdo",
    "rstick": "Analógico direito",
    "pad_left": "Trackpad esquerdo",
    "pad_right": "Trackpad direito",
    "trigger_left": "L2",
    "trigger_right": "R2",
}

KEY_NAMES = {
    "KEY_ENTER": "Enter",
    "KEY_ESC": "Esc",
    "KEY_BACKSPACE": "Backspace",
    "KEY_SPACE": "Espaço",
    "KEY_LEFTCTRL": "Ctrl",
    "KEY_RIGHTCTRL": "Ctrl",
    "KEY_LEFTSHIFT": "Shift",
    "KEY_RIGHTSHIFT": "Shift",
    "KEY_LEFTALT": "Alt",
    "KEY_RIGHTALT": "Alt",
    "KEY_LEFTMETA": "Meta",
    "KEY_RIGHTMETA": "Meta",
    "KEY_TAB": "Tab",
    "KEY_W": "W",
    "KEY_C": "C",
    "KEY_V": "V",
    "KEY_SYSRQ": "Print",
    "KEY_UP": "Cima",
    "KEY_DOWN": "Baixo",
    "KEY_LEFT": "Esquerda",
    "KEY_RIGHT": "Direita",
}

GROUPS = [
    ("face", "Face", ["A", "B", "X", "Y"]),
    ("shoulders", "Ombros", ["LB", "RB"]),
    ("back", "Traseiros", ["LGRIP", "RGRIP", "LGRIP2", "RGRIP2"]),
    ("system", "Sistema", ["BACK", "START", "DOTS"]),
    ("pointing", "Cursores", ["dpad", "lstick", "rstick", "pad_left", "pad_right", "RPAD", "trigger_left", "trigger_right"]),
]

CHORD_ORDER = ["X", "Y", "B", "A"]


def node(key):
    buttons = data.get("buttons") or {}
    if key in buttons and isinstance(buttons[key], dict):
        return buttons[key]
    value = data.get(key)
    if isinstance(value, dict) and "action" in value:
        return value
    return None


def keys_of(action):
    text = action or ""
    if "hotkey-actions.sh keyboard" in text:
        return "abre ou fecha"
    if text.startswith("dpad("):
        return "Setas"
    if "REL_WHEEL" in text:
        return "Rolagem"
    if "mouse()" in text:
        return "Cursor"
    if "BTN_RIGHT" in text:
        return "Clique direito"
    if "BTN_LEFT" in text or "BTN_MOUSE" in text:
        return "Clique esquerdo"
    names = re.findall(r"Keys\.([A-Z0-9_]+)", text)
    if not names:
        return ""
    return "+".join(KEY_NAMES.get(name, name) for name in names)


def item(key, spec, label):
    action = spec.get("action") or ""
    if not action or action == "NoAction":
        return None
    return {
        "id": key,
        "label": label,
        "name": spec.get("name") or label,
        "keys": keys_of(action),
    }


groups = []
for group_id, title, keys in GROUPS:
    items = []
    for key in keys:
        spec = node(key)
        if spec is None:
            continue
        built = item(key, spec, LABELS.get(key, key))
        if built is not None:
            items.append(built)
    if items:
        groups.append({"id": group_id, "title": title, "items": items})

chord_keys = []
seen = set()
buttons = data.get("buttons") or {}
for key in CHORD_ORDER:
    if key in buttons:
        chord_keys.append(key)
        seen.add(key)
for key in buttons:
    if key not in seen:
        chord_keys.append(key)

chords = []
for key in chord_keys:
    spec = buttons.get(key) or {}
    mode = (spec.get("modes") or {}).get("C")
    if not isinstance(mode, dict):
        continue
    built = item(key, mode, "Steam + " + LABELS.get(key, key))
    if built is not None:
        chords.append(built)
if chords:
    groups.append({"id": "chords", "title": "Steam", "items": chords})

payload = {
    "note": (
        "No Ashyterm, Ctrl+C vai para o shell e interrompe o comando. "
        "A cópia de lá é Ctrl+Shift+C e a cola é Ctrl+Shift+V."
    ),
    "groups": groups,
}
text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
if out_path:
    destination = Path(out_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text, encoding="utf-8")
else:
    sys.stdout.write(text)
PY
