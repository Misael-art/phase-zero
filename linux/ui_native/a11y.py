"""Acessibilidade verificável (UX-011).

Funções puras — sem Qt, sem I/O — para que a suíte exerça exatamente o que
a interface usa: contraste dos tokens de tema e cobertura de nome acessível
nos controles.

O que estas funções NÃO fazem: substituir sessão com participantes reais.
Elas garantem o piso mecânico (contraste, nome, foco); a parte humana do
gate de UX-011 continua sendo medida com gente.
"""

from __future__ import annotations

# WCAG 2.1: 4.5:1 para texto normal, 3:1 para texto grande e para
# elementos de interface (bordas, ícones, indicadores de estado).
AA_TEXT = 4.5
AA_LARGE = 3.0


def _channel(value: float) -> float:
    return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4


def parse_hex(color: str) -> tuple[float, float, float]:
    raw = color.strip().lstrip("#")
    if len(raw) == 3:
        raw = "".join(ch * 2 for ch in raw)
    if len(raw) != 6:
        raise ValueError(f"cor hex inválida: {color}")
    return tuple(int(raw[i:i + 2], 16) / 255 for i in (0, 2, 4))  # type: ignore[return-value]


def relative_luminance(color: str) -> float:
    red, green, blue = (_channel(component) for component in parse_hex(color))
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def contrast_ratio(foreground: str, background: str) -> float:
    light = relative_luminance(foreground)
    dark = relative_luminance(background)
    if light < dark:
        light, dark = dark, light
    return (light + 0.05) / (dark + 0.05)


# Pares que o usuário realmente lê ou precisa distinguir. ``minimum`` é o
# piso WCAG aplicável: texto normal x elemento de interface.
CONTRAST_PAIRS: tuple[tuple[str, str, str, float], ...] = (
    ("texto sobre fundo", "text", "bg", AA_TEXT),
    ("texto sobre superfície", "text", "surface", AA_TEXT),
    ("texto sobre superfície alternativa", "text", "surface_alt", AA_TEXT),
    ("texto sobre cabeçalho", "text", "surface_header", AA_TEXT),
    ("texto sobre campo de entrada", "text", "surface_input", AA_TEXT),
    ("texto secundário sobre fundo", "text_dim", "bg", AA_TEXT),
    ("texto secundário sobre superfície", "text_dim", "surface", AA_TEXT),
    ("log sobre superfície embutida", "text_log", "surface_inset", AA_TEXT),
    ("texto sobre destaque", "on_accent", "accent", AA_TEXT),
    ("sucesso sobre seu fundo", "success", "success_bg", AA_TEXT),
    ("aviso sobre seu fundo", "warning", "warning_bg", AA_TEXT),
    ("erro sobre seu fundo", "error", "error_bg", AA_TEXT),
    # LUX-010: navegação lateral (item ativo, hover e rótulos de seção).
    ("item ativo da navegação", "sidebar_active_text", "surface_selected", AA_TEXT),
    ("item da navegação sob o ponteiro", "sidebar_hover_text", "surface_alt", AA_TEXT),
    ("rótulo de seção da navegação", "section_label", "surface_inset", AA_TEXT),
    # WCAG 1.4.11 vale para o que identifica um controle — o anel de foco,
    # que precisa ser visível sobre cada superfície onde um controle vive.
    # A borda decorativa de card não entra: as superfícies já se distinguem
    # entre si, e ela não é o que diz onde está o foco.
    ("foco sobre superfície", "focus_ring", "surface", AA_LARGE),
    ("foco sobre fundo", "focus_ring", "bg", AA_LARGE),
    ("foco sobre campo de entrada", "focus_ring", "surface_input", AA_LARGE),
    ("foco sobre superfície alternativa", "focus_ring", "surface_alt", AA_LARGE),
)


def contrast_report(tokens) -> tuple[tuple[str, float, float], ...]:
    """``(descrição, razão, piso)`` para cada par legível do tema."""
    report = []
    for description, foreground, background, minimum in CONTRAST_PAIRS:
        ratio = contrast_ratio(getattr(tokens, foreground), getattr(tokens, background))
        report.append((description, ratio, minimum))
    return tuple(report)


def contrast_failures(tokens) -> tuple[tuple[str, float, float], ...]:
    return tuple(entry for entry in contrast_report(tokens) if entry[1] < entry[2])


def accessible_label(widget) -> str:
    """Nome que um leitor de tela anunciaria para o controle.

    Ordem: nome acessível explícito, texto visível, texto do item atual
    (combos), placeholder, tooltip. Vazio significa controle mudo.
    """
    for getter in ("accessibleName", "text", "currentText", "placeholderText", "toolTip"):
        method = getattr(widget, getter, None)
        if method is None:
            continue
        try:
            value = str(method() or "").strip()
        except (TypeError, RuntimeError):
            continue
        if value:
            return value
    return ""
