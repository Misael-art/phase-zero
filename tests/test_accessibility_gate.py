"""UX-011 — piso de acessibilidade verificável a cada entrega.

Este arquivo é o gate mecânico: contraste dos dois temas, nome acessível
em todo controle de toda página real, alcance por teclado e ausência de
overflow horizontal em 150% e 200%.

O que ele NÃO é: sessão de usabilidade. Nenhum teste aqui prova que uma
pessoa leiga conclui a jornada — isso continua pendente e só se mede com
participantes.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QAbstractButton, QApplication, QButtonGroup, QComboBox, QLineEdit,
    QPlainTextEdit, QWidget,
)
from PySide6.QtTest import QTest

from linux.ui_native.a11y import (
    AA_LARGE, AA_TEXT, accessible_label, contrast_failures, contrast_ratio,
    contrast_report, relative_luminance,
)
from linux.ui_native.catalog import CATEGORIES, DASHBOARD
from linux.ui_native.tokens import DARK, LIGHT

ROOT = Path(__file__).resolve().parents[1]
INTERACTIVE = (QAbstractButton, QComboBox, QLineEdit)


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def window(qapp, tmp_path, monkeypatch):
    from linux.ui_native.main_window import MainWindow

    home = tmp_path / "home"
    config = home / ".config"
    data = home / ".local" / "share"
    state = home / ".local" / "state"
    for path in (home, config, data, state):
        path.mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(config))
    monkeypatch.setenv("XDG_DATA_HOME", str(data))
    monkeypatch.setenv("XDG_STATE_HOME", str(state))

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch"
    ), patch(
        # Homelab has its own QProcess path, outside StatusLoader. These
        # geometry/name checks need the real page widgets, not live host
        # inventory or service probes.
        "linux.ui_native.pages.homelab.HomelabPage._spawn",
        lambda *_args, **_kwargs: None,
    ):
        win = MainWindow(ROOT)
        yield win
        win.close()


# ------------------------------------------------------------------ contraste
def test_luminance_and_ratio_match_the_wcag_reference():
    # Âncoras conhecidas: preto/branco = 21:1; cor contra ela mesma = 1:1.
    assert round(contrast_ratio("#000000", "#ffffff"), 2) == 21.0
    assert round(contrast_ratio("#7c4dff", "#7c4dff"), 2) == 1.0
    assert relative_luminance("#ffffff") == pytest.approx(1.0)
    assert relative_luminance("#000000") == pytest.approx(0.0)
    # Forma curta e maiúsculas são a mesma cor.
    assert contrast_ratio("#FFF", "#000000") == contrast_ratio("#ffffff", "#000")


@pytest.mark.parametrize("theme_name,tokens", [("dark", DARK), ("light", LIGHT)])
def test_every_readable_pair_meets_wcag_aa(theme_name, tokens):
    failures = contrast_failures(tokens)
    assert not failures, "\n".join(
        f"{theme_name}: {desc} = {ratio:.2f}:1, mínimo {minimum}:1"
        for desc, ratio, minimum in failures
    )


@pytest.mark.parametrize("tokens", [DARK, LIGHT], ids=["dark", "light"])
def test_focus_ring_is_perceivable_on_every_surface(tokens):
    """O anel de foco é o que diz onde o teclado está — 3:1 em toda superfície."""
    focus_pairs = [entry for entry in contrast_report(tokens) if entry[0].startswith("foco")]
    assert len(focus_pairs) >= 4
    for description, ratio, _minimum in focus_pairs:
        assert ratio >= AA_LARGE, f"{description}: {ratio:.2f}:1"


def test_the_gate_would_catch_a_regression():
    """Um gate que nunca reprova não é gate."""
    from dataclasses import replace

    broken = replace(DARK, text_dim="#3a3a44")  # cinza escuro sobre fundo escuro
    failures = contrast_failures(broken)
    assert failures, "contraste ilegível passou pelo gate"
    assert any("secundário" in desc for desc, _r, _m in failures)


# ------------------------------------------------------- nomes acessíveis/foco
def _children(page, types) -> list:
    found: list = []
    for kind in types:
        found.extend(page.findChildren(kind))
    return found


def _interactive(page) -> list:
    # Widgets internos do Qt (nome com prefixo "qt_", como o botão de canto
    # do QTableView) não são controles do produto: não os escrevemos, não
    # os rotulamos e o usuário não os opera.
    return [
        widget for widget in _children(page, INTERACTIVE)
        if (widget.isVisible() or widget.isVisibleTo(page))
        and not widget.objectName().startswith("qt_")
    ]


CATEGORY_IDS = [DASHBOARD[0]] + [row[0] for row in CATEGORIES]


@pytest.mark.parametrize("category", CATEGORY_IDS)
def test_every_control_announces_itself(window, qapp, category):
    """Nenhum controle mudo: leitor de tela sempre tem o que anunciar."""
    window.show_category(category)
    qapp.processEvents()
    page = window.registry.page_for(window.current_category)
    if page is None:
        pytest.skip(f"categoria sem página construída: {category}")
    mute = [
        widget.objectName() or widget.__class__.__name__
        for widget in _interactive(page)
        if not accessible_label(widget)
    ]
    assert not mute, f"{category}: controles sem nome acessível: {mute}"


@pytest.mark.parametrize("category", CATEGORY_IDS)
def test_controls_are_reachable_by_keyboard(window, qapp, category):
    """Todo controle habilitado aceita foco por Tab — sem becos só de mouse."""
    window.show_category(category)
    qapp.processEvents()
    page = window.registry.page_for(window.current_category)
    if page is None:
        pytest.skip(f"categoria sem página construída: {category}")
    unreachable = [
        widget.objectName() or accessible_label(widget)
        for widget in _interactive(page)
        if widget.isEnabled() and widget.focusPolicy() == Qt.NoFocus
    ]
    assert not unreachable, f"{category}: fora do alcance do teclado: {unreachable}"


@pytest.mark.parametrize("category", CATEGORY_IDS)
def test_enabled_controls_are_reached_by_actual_tab_navigation(window, qapp, category):
    """Exercise Qt's real Tab chain; focus policy alone can hide a broken chain."""
    window.resize(1280, 800)
    window.show()
    window.show_category(category)
    qapp.processEvents()
    page = window.registry.page_for(window.current_category)
    if page is None:
        pytest.skip(f"categoria sem página construída: {category}")

    expected = [
        widget for widget in _interactive(page)
        if widget.isEnabled() and widget.focusPolicy() & Qt.TabFocus
    ]
    if not expected:
        return

    exclusive_groups = []
    grouped_controls = set()
    representatives = set()
    for group in page.findChildren(QButtonGroup):
        if not group.exclusive():
            continue
        members = [button for button in group.buttons() if button in expected]
        if not members:
            continue
        representative = group.checkedButton()
        if representative not in members:
            representative = members[0]
        exclusive_groups.append((members, representative))
        grouped_controls.update(members)
        representatives.add(representative)

    tab_stops = [widget for widget in expected if widget not in grouped_controls]
    tab_stops.extend(representatives)

    first = tab_stops[0]
    first.setFocus(Qt.TabFocusReason)
    qapp.processEvents()
    assert window.focusWidget() is first, (
        f"{category}: primeiro controle não aceita foco por teclado: "
        f"{first.objectName() or accessible_label(first)}"
    )

    visited = set()
    current = first
    # Bound traversal by the real window focus chain, including controls outside
    # this page such as search and sidebar navigation.
    limit = max(16, len(window.findChildren(QWidget)) + 2)
    for _ in range(limit):
        if current is first and visited:
            break
        visited.add(current)
        QTest.keyClick(current, Qt.Key_Tab)
        qapp.processEvents()
        current = window.focusWidget()
        if current is None:
            break

    missing = [
        widget.objectName() or accessible_label(widget)
        for widget in tab_stops if widget not in visited
    ]
    visited_names = [widget.objectName() or accessible_label(widget) for widget in visited]
    assert not missing, (
        f"{category}: Tab pula controles habilitados: {missing}; "
        f"controles percorridos: {visited_names}"
    )

    for members, representative in exclusive_groups:
        if len(members) < 2:
            continue
        reached = set()
        for key in (Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down):
            representative.setFocus(Qt.TabFocusReason)
            qapp.processEvents()
            current = window.focusWidget()
            if current is representative:
                reached = {representative}
            for _ in range(len(members) + 1):
                if current is None:
                    break
                QTest.keyClick(current, key)
                qapp.processEvents()
                current = window.focusWidget()
                if current in members:
                    reached.add(current)
            if len(reached) == len(members):
                break
        missing_group_members = [
            button.objectName() or accessible_label(button)
            for button in members if button not in reached
        ]
        assert not missing_group_members, (
            f"{category}: opções do grupo exclusivo inacessíveis por setas: "
            f"{missing_group_members}"
        )


def test_the_sidebar_is_operable_without_a_mouse(window, qapp):
    for name, button in window.sidebar_buttons.items():
        assert button.focusPolicy() != Qt.NoFocus, f"{name} não recebe foco"
        assert accessible_label(button), f"{name} não se anuncia"


# ------------------------------------------------------------------- escalas
@pytest.mark.parametrize("scale,width,height", [
    (1.5, 1280, 800), (1.5, 800, 600), (2.0, 1280, 800), (2.0, 800, 600),
])
@pytest.mark.parametrize("category", ["Início", "Homelab", "Windows VM"])
def test_no_horizontal_overflow_at_150_and_200_percent(window, qapp, scale, width, height, category):
    """150% e 200%: nada escapa pela lateral, em janela larga e estreita.

    A escala é aplicada às fontes — é o que muda tamanho de controle e
    quebra layout —, e o conteúdo é medido contra a largura do viewport.
    """
    font = qapp.font()
    original = font.pointSizeF()
    if original <= 0:
        pytest.skip("fonte sem tamanho em pontos neste ambiente")
    scaled = qapp.font()
    scaled.setPointSizeF(original * scale)
    qapp.setFont(scaled)
    try:
        window.show()
        window.resize(width, height)
        window.show_category(category)
        qapp.processEvents()
        page = window.registry.page_for(window.current_category)
        if page is None:
            pytest.skip(f"categoria sem página construída: {category}")
        qapp.processEvents()
        limit = window.width()
        overflow = [
            (widget.objectName() or widget.__class__.__name__, widget.mapTo(window, widget.rect().topRight()).x())
            for widget in _children(page, INTERACTIVE + (QPlainTextEdit,))
            if widget.isVisible()
            and widget.mapTo(window, widget.rect().topRight()).x() > limit
        ]
        assert not overflow, (
            f"{category} @ {scale:.0%} {width}x{height}: sai do viewport ({limit}px): {overflow[:4]}"
        )
    finally:
        restored = qapp.font()
        restored.setPointSizeF(original)
        qapp.setFont(restored)
        qapp.processEvents()
