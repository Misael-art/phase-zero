#!/usr/bin/env python3
"""Generate PhaseZero category SVG icons under assets/icons/hicolor/scalable/apps/"""

from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "assets/icons/hicolor/scalable/apps"
OUT.mkdir(parents=True, exist_ok=True)

ACCENT = "#6366f1"
BG = "#1e1b4b"
FG = "#e0e7ff"
MUTED = "#a5b4fc"

SVG = '''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
  <rect x="2" y="2" width="20" height="20" rx="4" fill="{bg}"/>
{body}
</svg>'''

def icon(body: str, accent=ACCENT, muted=MUTED, bg=BG) -> str:
    return SVG.format(bg=bg, body=body.format(accent=accent, muted=muted, bg=bg))

icons = {
    # ── PhaseZero application family ──
    "phasezero-port-steam": (
        '<path d="M5 8.5a7 7 0 1 1 2 9.7" fill="none" stroke="{muted}" stroke-width="2" stroke-linecap="round"/>'
        '\n  <circle cx="15.5" cy="8.5" r="2.5" fill="{accent}"/>'
        '\n  <path d="m8 15 5-3 3 2-5 3Z" fill="{accent}"/>'
        '\n  <circle cx="7" cy="17" r="2" fill="{muted}"/>'
    ),
    "phasezero-9router": (
        '<circle cx="12" cy="5" r="2.2" fill="{accent}"/>'
        '\n  <circle cx="6" cy="18" r="2.2" fill="{muted}"/>'
        '\n  <circle cx="18" cy="18" r="2.2" fill="{muted}"/>'
        '\n  <path d="M12 7v4m0 0-6 5m6-5 6 5" fill="none" stroke="{accent}" stroke-width="1.8" stroke-linecap="round"/>'
    ),
    "phasezero-windows-vm": (
        '<rect x="3.5" y="4" width="17" height="12" rx="2" fill="{muted}"/>'
        '\n  <path d="M7 7h4v3H7Zm6 0h4v3h-4Zm-6 5h4v3H7Zm6 0h4v3h-4Z" fill="{accent}"/>'
        '\n  <path d="M9 20h6m-4-4v4m2-4v4" stroke="{accent}" stroke-width="1.4" stroke-linecap="round"/>'
    ),
    "phasezero-windows-reboot": (
        '<path d="M12 4V2l4 3-4 3V6a6 6 0 1 0 5.7 8h2.1A8 8 0 1 1 12 4Z" fill="{muted}"/>'
        '\n  <path d="M9 9h3v3H9Zm4 0h3v3h-3Zm-4 4h3v3H9Zm4 0h3v3h-3Z" fill="{accent}"/>'
    ),
    "phasezero-deck-handheld": (
        '<rect x="3" y="6" width="18" height="12" rx="4" fill="{muted}"/>'
        '\n  <rect x="8" y="8" width="8" height="8" rx="1" fill="{bg}"/>'
        '\n  <path d="M5.5 12h3m-1.5-1.5v3" stroke="{accent}" stroke-width="1.3" stroke-linecap="round"/>'
        '\n  <circle cx="18" cy="11" r="1" fill="{accent}"/><circle cx="17" cy="14" r="1" fill="{accent}"/>'
    ),
    "phasezero-deck-monitor": (
        '<rect x="3" y="4" width="18" height="11" rx="2" fill="{muted}"/>'
        '\n  <rect x="5" y="6" width="14" height="7" rx="1" fill="{accent}"/>'
        '\n  <path d="M9 19h6m-4-4v4m2-4v4" stroke="{muted}" stroke-width="1.5" stroke-linecap="round"/>'
        '\n  <circle cx="6.5" cy="9.5" r="1.5" fill="{bg}"/>'
    ),
    "phasezero-deck-tv": (
        '<rect x="3" y="5" width="18" height="13" rx="2" fill="{muted}"/>'
        '\n  <path d="M7 2.5 12 6l5-3.5" fill="none" stroke="{accent}" stroke-width="1.4" stroke-linecap="round"/>'
        '\n  <path d="M7 9h6v5H7Z" fill="{accent}"/><circle cx="17" cy="10" r="1" fill="{accent}"/><circle cx="17" cy="14" r="1" fill="{accent}"/>'
    ),
    "phasezero-deck-desktop": (
        '<rect x="3" y="4" width="18" height="12" rx="2" fill="{muted}"/>'
        '\n  <path d="M6 7h7v6H6Zm9 0h3v2h-3Zm0 4h3v2h-3Z" fill="{accent}"/>'
        '\n  <path d="M8 20h8m-5-4v4m2-4v4" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>'
    ),
    "phasezero-steam-gamepad": (
        '<path d="M7 7h10a4 4 0 0 1 3.7 5.5l-1.5 4a2 2 0 0 1-3.2.8L14.5 16h-5L8 17.3a2 2 0 0 1-3.2-.8l-1.5-4A4 4 0 0 1 7 7Z" fill="{muted}"/>'
        '\n  <path d="M8 10v4m-2-2h4" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>'
        '\n  <circle cx="16" cy="11" r="1" fill="{accent}"/><circle cx="18" cy="13" r="1" fill="{accent}"/>'
    ),
    "phasezero-keyboard": (
        '<rect x="3" y="6" width="18" height="12" rx="2" fill="{muted}"/>'
        '\n  <path d="M6 9h2m2 0h2m2 0h2m2 0h1M6 12h2m2 0h2m2 0h2m2 0h1M7 15h10" stroke="{accent}" stroke-width="1.2" stroke-linecap="round"/>'
    ),
    "phasezero-voice": (
        '<rect x="9" y="3" width="6" height="11" rx="3" fill="{accent}"/>'
        '\n  <path d="M6 11a6 6 0 0 0 12 0M12 17v4m-3 0h6" fill="none" stroke="{muted}" stroke-width="1.7" stroke-linecap="round"/>'
    ),
    "phasezero-shortcuts": (
        '<rect x="3" y="5" width="18" height="14" rx="2" fill="{muted}"/>'
        '\n  <path d="M6 9h3v3H6Zm5 0h3v3h-3Zm5 0h2v3h-2ZM7 14h10" fill="none" stroke="{accent}" stroke-width="1.4" stroke-linecap="round"/>'
    ),
    "phasezero-odysseus": (
        '<path d="M6 18c4-1 7-5 7-10 3 1 5 4 5 7 0 4-3 7-7 7-2 0-4-1-5-4Z" fill="{muted}"/>'
        '\n  <path d="M5 18c5 0 9-4 9-10M11 12l4-1m-7 5 4 2" fill="none" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>'
    ),
    "phasezero-hermes": (
        '<path d="M12 4c3 0 5 2 5 5 0 4-3 5-5 8-2-3-5-4-5-8 0-3 2-5 5-5Z" fill="{muted}"/>'
        '\n  <path d="M7 9 3 7l2 5m12-3 4-2-2 5M9 20h6" fill="none" stroke="{accent}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>'
        '\n  <circle cx="10" cy="9" r="1" fill="{accent}"/><circle cx="14" cy="9" r="1" fill="{accent}"/>'
    ),
    "phasezero-ollama": (
        '<path d="M8 6V3m8 3V3M7 8c0-2 2-3 5-3s5 1 5 3v9c0 3-2 4-5 4s-5-1-5-4Z" fill="{muted}"/>'
        '\n  <circle cx="10" cy="11" r="1" fill="{accent}"/><circle cx="14" cy="11" r="1" fill="{accent}"/>'
        '\n  <path d="M10 16h4" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>'
    ),
    "phasezero-proxy-kimi": (
        '<path d="M6 18V6h3v5l5-5h4l-6 6 6 6h-4l-5-5v5Z" fill="{accent}"/>'
    ),
    "phasezero-proxy-qwen": (
        '<circle cx="12" cy="12" r="7" fill="none" stroke="{muted}" stroke-width="2"/>'
        '\n  <path d="M12 8a4 4 0 1 0 3 6.5L18 18" fill="none" stroke="{accent}" stroke-width="2" stroke-linecap="round"/>'
    ),
    "phasezero-proxy-deepseek": (
        '<path d="M4 13c3-5 7-7 13-5l3-2-1 4c1 5-3 9-8 9-3 0-5-2-7-6Z" fill="{muted}"/>'
        '\n  <circle cx="15" cy="11" r="1" fill="{accent}"/><path d="M6 15c3 1 6 0 8-2" fill="none" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>'
    ),
    "phasezero-proxy-mimo": (
        '<path d="M4 18V7l4 5 4-5 4 5 4-5v11" fill="none" stroke="{muted}" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"/>'
        '\n  <circle cx="12" cy="17" r="2" fill="{accent}"/>'
    ),
    "phasezero-proxy-generic": (
        '<path d="M5 8h6v4H5Zm8 4h6v4h-6Z" fill="{muted}"/>'
        '\n  <path d="M11 10h4v4h-2m-5 0h5" fill="none" stroke="{accent}" stroke-width="1.7" stroke-linecap="round"/>'
    ),
    # ── Dashboard ──
    "go-home": '<path d="M4 21V9l8-6 8 6v12H14v-7h-4v7H4Z" fill="{accent}"/>',
    # ── Overview ──
    "view-dashboard": (
        '<rect x="4" y="4" width="7" height="7" rx="1" fill="{accent}"/>\n'
        '  <rect x="13" y="4" width="7" height="7" rx="1" fill="{muted}"/>\n'
        '  <rect x="4" y="13" width="7" height="7" rx="1" fill="{muted}"/>\n'
        '  <rect x="13" y="13" width="7" height="7" rx="1" fill="{accent}"/>'
    ),
    # ── Profiles ──
    "package-x-generic": (
        '<path d="M5 3h14a2 2 0 0 1 2 2v3H3V5a2 2 0 0 1 2-2Z" fill="{accent}"/>\n'
        '  <rect x="3" y="8" width="18" height="12" rx="1" fill="{muted}"/>\n'
        '  <path d="M7 11h10v2H7Z" fill="{accent}"/>\n'
        '  <path d="M7 14h6v2H7Z" fill="{accent}"/>'
    ),
    # ── Steam Deck ──
    "input-gaming": (
        '<rect x="3" y="6" width="18" height="12" rx="3" fill="{muted}"/>\n'
        '  <circle cx="7" cy="12" r="2" fill="{accent}"/>\n'
        '  <circle cx="17" cy="12" r="2" fill="{accent}"/>\n'
        '  <path d="M10 12h4M12 10v4" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>'
    ),
    # ── Windows VM ──
    "computer": (
        '<rect x="3" y="4" width="18" height="12" rx="2" fill="{muted}"/>\n'
        '  <path d="M8 16v3M16 16v3M6 19h12" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>'
    ),
    # ── Waydroid / Phone ──
    "phone": (
        '<rect x="7" y="2" width="10" height="20" rx="2" fill="{muted}"/>\n'
        '  <rect x="9" y="4" width="6" height="12" rx="1" fill="{accent}"/>\n'
        '  <circle cx="12" cy="18" r="1" fill="{muted}"/>'
    ),
    # ── Server ──
    "network-server": (
        '<rect x="4" y="3" width="16" height="4" rx="1" fill="{accent}"/>\n'
        '  <rect x="4" y="10" width="16" height="4" rx="1" fill="{muted}"/>\n'
        '  <rect x="4" y="17" width="16" height="4" rx="1" fill="{accent}"/>'
    ),
    # ── Emulation / Games ──
    "applications-games": (
        '<rect x="3" y="5" width="18" height="14" rx="3" fill="{muted}"/>\n'
        '  <circle cx="9" cy="12" r="3" fill="{accent}"/>\n'
        '  <rect x="14" y="10" width="5" height="1.5" rx="0.75" fill="{accent}"/>\n'
        '  <rect x="16" y="8" width="1.5" height="5.5" rx="0.75" fill="{accent}"/>'
    ),
    # ── Boot / Reboot ──
    "system-reboot": '<path d="M12 4V2l4 3-4 3V6a6 6 0 1 0 6 6h2a8 8 0 1 1-8-8Z" fill="{accent}"/>',
    # ── Flatpak / Install ──
    "system-software-install": (
        '<path d="M12 2 2 7l10 5 10-5-10-5Z" fill="{muted}"/>\n'
        '  <path d="M2 17 12 22l10-5" fill="none" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>\n'
        '  <path d="M2 12 12 17 22 12" fill="none" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>'
    ),
    # ── Features / Plugin ──
    "preferences-plugin": (
        '<rect x="4" y="4" width="16" height="16" rx="3" fill="{muted}"/>\n'
        '  <circle cx="12" cy="12" r="3" fill="{accent}"/>\n'
        '  <path d="M12 6v2M12 16v2M6 12h2M16 12h2" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>'
    ),
    # ── AI & Dev ──
    "applications-development": (
        '<path d="M10 20 14 4" stroke="{muted}" stroke-width="1.5" stroke-linecap="round"/>\n'
        '  <path d="M5 8 9 12 5 16" fill="none" stroke="{accent}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>\n'
        '  <path d="M19 8 15 12 19 16" fill="none" stroke="{accent}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>'
    ),
    # ── Apps / Other ──
    "applications-other": (
        '<rect x="4" y="3" width="7" height="7" rx="1" fill="{accent}"/>\n'
        '  <rect x="13" y="3" width="7" height="7" rx="1" fill="{muted}"/>\n'
        '  <rect x="4" y="14" width="7" height="7" rx="1" fill="{muted}"/>\n'
        '  <rect x="13" y="14" width="7" height="7" rx="1" fill="{accent}"/>'
    ),
    # ── Settings ──
    "preferences-system": (
        '<circle cx="12" cy="12" r="3" fill="{accent}"/>\n'
        '  <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" fill="none" stroke="{muted}" stroke-width="1.5"/>'
    ),
    # ── Logs / Results ──
    "text-x-log": (
        '<rect x="4" y="3" width="16" height="18" rx="2" fill="{muted}"/>\n'
        '  <path d="M7 7h10M7 12h10M7 17h6" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>'
    ),
    # ── XDG menu extras ──
    "applications-internet": (
        '<circle cx="12" cy="12" r="9" fill="none" stroke="{muted}" stroke-width="1.5"/>\n'
        '  <ellipse cx="12" cy="12" rx="4" ry="9" fill="none" stroke="{accent}" stroke-width="1.5"/>\n'
        '  <path d="M3 12h18" stroke="{muted}" stroke-width="1.5"/>'
    ),
    "applications-multimedia": (
        '<circle cx="10" cy="12" r="5" fill="{accent}"/>\n'
        '  <path d="M15 8v9l5-4.5Z" fill="{muted}"/>'
    ),
    "applications-science": (
        '<path d="M5 21h14M12 3v12M9 21a3 3 0 0 1 3-3 3 3 0 0 1 3 3" fill="none" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>\n'
        '  <path d="M8 7 12 3 16 7" fill="none" stroke="{muted}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>'
    ),
    "folder-remote": (
        '<path d="M4 20h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7l-2-2H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2Z" fill="{muted}"/>\n'
        '  <circle cx="12" cy="13" r="1.5" fill="{accent}"/>\n'
        '  <path d="M8 10a5 5 0 0 1 8 0M15 16a5 5 0 0 1-6 0" fill="none" stroke="{accent}" stroke-width="1" stroke-linecap="round"/>'
    ),
    "office-applications": (
        '<rect x="4" y="3" width="16" height="18" rx="2" fill="{muted}"/>\n'
        '  <path d="M8 7h8M8 12h8M8 17h4" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>'
    ),
    # ── Missing from system themes ──
    "appointment-missed": (
        '<circle cx="12" cy="12" r="9" fill="none" stroke="{muted}" stroke-width="1.5"/>\n'
        '  <path d="M8 12h8" stroke="{accent}" stroke-width="2" stroke-linecap="round"/>\n'
        '  <path d="M8 8l8 8" stroke="{muted}" stroke-width="1" stroke-linecap="round"/>'
    ),
    "edit-unlink": (
        '<path d="M10 14l-1.5 1.5a3 3 0 0 1-4-4L7 9" fill="none" stroke="{muted}" stroke-width="1.5" stroke-linecap="round"/>\n'
        '  <path d="M14 10l1.5-1.5a3 3 0 0 1 4 4L17 15" fill="none" stroke="{muted}" stroke-width="1.5" stroke-linecap="round"/>\n'
        '  <path d="M9 15l-2 3M15 9l2-3" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>'
    ),
    "network-transmit-receive": (
        '<path d="M4 12h6M14 12h6" stroke="{muted}" stroke-width="1.5" stroke-linecap="round"/>\n'
        '  <path d="M7 9l3 3-3 3" fill="none" stroke="{accent}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>\n'
        '  <path d="M17 9l-3 3 3 3" fill="none" stroke="{accent}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>'
    ),
    "preferences-desktop-keyboard-shortcuts": (
        '<rect x="3" y="4" width="18" height="16" rx="2" fill="{muted}"/>\n'
        '  <path d="M5 8h2M9 8h2M13 8h2M17 8h2" stroke="{accent}" stroke-width="1" stroke-linecap="round"/>\n'
        '  <path d="M7 12h2M11 12h2M15 12h2M5 16h2M9 16h2" stroke="{accent}" stroke-width="1" stroke-linecap="round"/>\n'
        '  <path d="M17 16 19 14" stroke="{muted}" stroke-width="1.5" stroke-linecap="round"/>'
    ),
    "preferences-system-gaming": (
        '<rect x="3" y="5" width="18" height="14" rx="3" fill="{muted}"/>\n'
        '  <path d="M8 10v4M10 12H6" stroke="{accent}" stroke-width="1.5" stroke-linecap="round"/>\n'
        '  <circle cx="16" cy="12" r="1.5" fill="{accent}"/>'
    ),
}

for name, body in sorted(icons.items()):
    path = OUT / f"{name}.svg"
    svg = icon(body)
    path.write_text(svg)
    print(f"  {path.name}")

print(f"\n{len(icons)} icons written to {OUT}")
