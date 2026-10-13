"""Temas e acessibilidade: página com hero e 7 abas.

Abas: Perfis, Aparência, Acessibilidade, Wallpapers, Game Mode, Catálogo
avaliado e Histórico. Toggles seguem o padrão otimista de
`cancel_pending_action`; toda alteração passa por plan/preview/apply com
bindings `{plan_id}`/`{confirm}` do catálogo.
"""
from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QFrame, QGridLayout, QHBoxLayout, QLabel, QPushButton, QScrollArea,
    QTabWidget, QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import SectionHeader, SwitchControl
from .base import BasePage

FEATURE_TITLES: dict[str, str] = {
    "theme.phasezero": "Tema PhaseZero",
    "theme.kde": "Tema global KDE",
    "theme.colorscheme": "Esquema de cores",
    "theme.icons": "Ícones",
    "theme.cursor": "Cursor",
    "theme.accent": "Cor de destaque",
    "theme.auto-dark": "Alternância claro/escuro",
    "theme.night-color": "Night Color",
    "access.text-size": "Texto maior",
    "access.reduce-motion": "Movimento reduzido",
    "access.locate-cursor": "Localizar cursor",
    "access.zoom": "Zoom",
    "access.colorblind": "Filtro de daltonismo",
    "access.visual-alert": "Alerta visual",
    "access.screen-reader": "Leitor de tela",
    "access.sticky-keys": "Teclas aderentes",
    "access.slow-keys": "Teclas lentas",
    "access.bounce-keys": "Teclas de repercussão",
    "power.adaptive": "Animações adaptativas",
    "power.pause-on-game": "Pausar em jogos",
}

APPEARANCE = (
    "theme.phasezero", "theme.kde", "theme.colorscheme", "theme.icons",
    "theme.cursor", "theme.accent", "theme.auto-dark", "theme.night-color",
)
ACCESSIBILITY = (
    "access.text-size", "access.reduce-motion", "access.locate-cursor",
    "access.zoom", "access.colorblind", "access.visual-alert",
    "access.screen-reader", "access.sticky-keys", "access.slow-keys",
    "access.bounce-keys",
)
POWER = ("power.adaptive", "power.pause-on-game")

PROFILES = (
    ("essencial", "Perfil Essencial"),
    ("steam-deck", "Perfil Steam Deck"),
    ("gamer", "Perfil Gamer"),
    ("desenvolvedor", "Perfil Desenvolvedor"),
)

WALLPAPERS = (
    ("pz.geo-dark", "PhaseZero Geo (escuro)"),
    ("pz.aurora", "PhaseZero Aurora"),
    ("pz.solid-charcoal", "PhaseZero Carvão (sólido)"),
)


class ThemesPage(BasePage):
    """Página de Temas e acessibilidade do PhaseZero."""

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self._pending_toggles: dict[str, tuple[SwitchControl, bool, QLabel, str]] = {}
        self._controls: list[tuple[str, SwitchControl, QLabel]] = []
        self._hero_labels: dict[str, QLabel] = {}
        self._catalog_loaded = False
        self._history_loaded = False
        self.status_loader.status_ready.connect(self._on_status_ready)
        self.status_loader.status_failed.connect(self._on_status_failed)

    # ------------------------------------------------------------------ build

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        layout.addWidget(SectionHeader(
            "Temas e acessibilidade",
            "Aparência, conforto visual e acessibilidade do Plasma.",
        ))

        layout.addWidget(self._build_hero())
        layout.addWidget(self._build_tabs())
        layout.addStretch()

        scroll.setWidget(inner)
        self._layout.addWidget(scroll)

    def _hero_label(self, key: str, text: str) -> QLabel:
        label = QLabel(text)
        label.setObjectName("settingValue")
        label.setWordWrap(True)
        self._hero_labels[key] = label
        return label

    def _build_hero(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        layout = QGridLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(10)

        layout.addWidget(QLabel("Perfil ativo"), 0, 0)
        layout.addWidget(self._hero_label("profile", "Verificando…"), 0, 1)
        layout.addWidget(QLabel("Plasma"), 1, 0)
        layout.addWidget(self._hero_label("plasma", "—"), 1, 1)
        layout.addWidget(QLabel("Sessão / KWin"), 2, 0)
        layout.addWidget(self._hero_label("session", "—"), 2, 1)
        layout.addWidget(QLabel("SteamOS"), 3, 0)
        layout.addWidget(self._hero_label("steamos", "—"), 3, 1)
        layout.addWidget(QLabel("Wallpaper atual"), 4, 0)
        layout.addWidget(self._hero_label("wallpaper", "—"), 4, 1)
        layout.addWidget(QLabel("Energia"), 5, 0)
        layout.addWidget(self._hero_label("battery", "—"), 5, 1)

        buttons = QHBoxLayout()
        self.undo_button = QPushButton("Desfazer última alteração")
        self.undo_button.setObjectName("secondaryButton")
        self.undo_button.setMinimumHeight(40)
        self.undo_button.clicked.connect(self._request_undo)
        self.rescue_button = QPushButton("Restaurar wallpaper (crash)")
        self.rescue_button.setObjectName("secondaryButton")
        self.rescue_button.setMinimumHeight(40)
        self.rescue_button.clicked.connect(self._request_rescue)
        buttons.addWidget(self.undo_button)
        buttons.addWidget(self.rescue_button)
        buttons.addStretch()
        layout.addLayout(buttons, 6, 0, 1, 2)
        return card

    def _build_tabs(self) -> QTabWidget:
        tabs = QTabWidget()
        tabs.setObjectName("themesTabs")
        tabs.setAccessibleName("Seções de temas")

        self.profiles_tab = self._build_profiles_tab()
        self.appearance_tab = self._build_features_tab("Aparência", APPEARANCE)
        self.accessibility_tab = self._build_features_tab("Acessibilidade", ACCESSIBILITY)
        self.wallpapers_tab = self._build_wallpapers_tab()
        self.gamemode_tab = self._build_gamemode_tab()
        self.catalog_tab = self._build_catalog_tab()
        self.history_tab = self._build_history_tab()

        for widget, title in (
            (self.profiles_tab, "Perfis"),
            (self.appearance_tab, "Aparência"),
            (self.accessibility_tab, "Acessibilidade"),
            (self.wallpapers_tab, "Wallpapers"),
            (self.gamemode_tab, "Game Mode"),
            (self.catalog_tab, "Catálogo avaliado"),
            (self.history_tab, "Histórico"),
        ):
            tabs.addTab(widget, title)
        tabs.currentChanged.connect(self._on_tab_changed)
        return tabs

    def _build_profiles_tab(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setSpacing(10)
        layout.addWidget(SectionHeader("Perfis", "Planos prontos de aparência e acessibilidade."))
        grid = QGridLayout()
        grid.setVerticalSpacing(10)
        grid.setHorizontalSpacing(10)
        for index, (profile_id, label) in enumerate(PROFILES):
            action = self.by_id.get(f"themes.profile.{profile_id}")
            if action is None:
                continue
            self.mark_represented(action)
            button = QPushButton(label)
            button.setObjectName("primaryButton")
            button.setMinimumHeight(44)
            button.clicked.connect(lambda _checked=False, item=action: self.request_action(item))
            grid.addWidget(button, index // 2, index % 2)
        layout.addLayout(grid)
        layout.addStretch()
        return page

    def _build_features_tab(self, title: str, feature_ids: tuple[str, ...]) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader(title, "Alternância otimista com confirmação segura."))
        for feature_id in feature_ids:
            row, toggle, detail = self._feature_switch(feature_id)
            index = len(self._controls)
            self._controls.append((feature_id, toggle, detail))
            toggle.toggled.connect(
                lambda checked, feature_index=index: self._feature_toggle_requested(feature_index, checked)
            )
            layout.addWidget(row)
        layout.addStretch()
        return page

    def _feature_switch(self, feature_id: str) -> tuple[QWidget, SwitchControl, QLabel]:
        row = QWidget()
        row_layout = QHBoxLayout(row)
        row_layout.setContentsMargins(0, 3, 0, 3)
        copy = QVBoxLayout()
        name = QLabel(FEATURE_TITLES.get(feature_id, feature_id))
        name.setObjectName("settingValue")
        detail = QLabel("Verificando…")
        detail.setObjectName("cardDescription")
        detail.setWordWrap(True)
        toggle = SwitchControl()
        toggle.setEnabled(False)
        toggle.setAccessibleName(name.text())
        copy.addWidget(name)
        copy.addWidget(detail)
        row_layout.addLayout(copy, 1)
        row_layout.addWidget(toggle)
        return row, toggle, detail

    def _build_wallpapers_tab(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setSpacing(10)
        layout.addWidget(SectionHeader("Wallpapers", "Pré-visualização de 15 s com expiração e rollback."))
        for wallpaper_id, label in WALLPAPERS:
            action = self.by_id.get(f"themes.wallpaper.{wallpaper_id}")
            if action is None:
                continue
            self.mark_represented(action)
            row = QWidget()
            row_layout = QHBoxLayout(row)
            row_layout.setContentsMargins(0, 2, 0, 2)
            copy = QVBoxLayout()
            name = QLabel(label)
            name.setObjectName("settingValue")
            detail = QLabel(action.description)
            detail.setObjectName("cardDescription")
            detail.setWordWrap(True)
            copy.addWidget(name)
            copy.addWidget(detail)
            row_layout.addLayout(copy, 1)
            apply = QPushButton("Pré-visualizar e aplicar")
            apply.setObjectName("secondaryButton")
            apply.setMinimumHeight(44)
            apply.clicked.connect(lambda _checked=False, item=action: self.request_action(item))
            row_layout.addWidget(apply)
            layout.addWidget(row)
        layout.addStretch()
        return page

    def _build_gamemode_tab(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader(
            "Game Mode",
            "Steam Gaming Mode: pausa de animações durante partidas.",
        ))
        self.gamemode_label = QLabel("Verificando…")
        self.gamemode_label.setObjectName("cardDescription")
        self.gamemode_label.setWordWrap(True)
        layout.addWidget(self.gamemode_label)
        for feature_id in POWER:
            row, toggle, detail = self._feature_switch(feature_id)
            index = len(self._controls)
            self._controls.append((feature_id, toggle, detail))
            toggle.toggled.connect(
                lambda checked, feature_index=index: self._feature_toggle_requested(feature_index, checked)
            )
            layout.addWidget(row)
        layout.addStretch()
        return page

    def _build_catalog_tab(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setSpacing(10)
        layout.addWidget(SectionHeader(
            "Catálogo avaliado",
            "Extensões KDE curadas: incluídas, adiadas e recusadas.",
        ))
        self.extensions_table = QTableWidget(0, 3)
        self.extensions_table.setHorizontalHeaderLabels(("Extensão", "Status", "Motivo"))
        self.extensions_table.setAlternatingRowColors(True)
        self.extensions_table.horizontalHeader().setStretchLastSection(True)
        self.extensions_table.setMinimumHeight(220)
        layout.addWidget(self.extensions_table)
        self.catalog_hint = QLabel("Carregando catálogo…")
        self.catalog_hint.setObjectName("cardDescription")
        self.catalog_hint.setWordWrap(True)
        layout.addWidget(self.catalog_hint)
        layout.addStretch()
        return page

    def _build_history_tab(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setSpacing(10)
        layout.addWidget(SectionHeader("Histórico", "Operações aplicadas com snapshot."))
        self.history_table = QTableWidget(0, 4)
        self.history_table.setHorizontalHeaderLabels(("Operação", "Quando", "Status", "Recursos"))
        self.history_table.setAlternatingRowColors(True)
        self.history_table.horizontalHeader().setStretchLastSection(True)
        self.history_table.setMinimumHeight(220)
        layout.addWidget(self.history_table)
        self.history_hint = QLabel("Carregando histórico…")
        self.history_hint.setObjectName("cardDescription")
        layout.addWidget(self.history_hint)
        layout.addStretch()
        return page

    # ------------------------------------------------------------ data loading

    def reload(self) -> None:
        action = self.by_id.get("themes.status")
        if action is None or self.status_loader.running(action.id):
            return
        self.status_loader.fetch_action(action)

    def _on_status_ready(self, action_id: str, stdout: str, parsed: object) -> None:
        if action_id == "themes.status":
            self._apply_status(parsed)
        elif action_id == "themes.catalog":
            self._apply_catalog(parsed)
        elif action_id == "themes.history":
            self._apply_history(parsed)

    def _on_status_failed(self, action_id: str, message: str) -> None:
        # Sem handler, a página ficava presa em "Verificando…"/"Carregando…"
        # para sempre na primeira falha de leitura.
        if action_id == "themes.status":
            self._set_hero("profile", "Indisponível agora")
            for _fid, toggle, detail in self._controls:
                detail.setText("Não foi possível verificar. Clique em Atualizar.")
                with QtSignalBlockerGuard(toggle):
                    toggle.set_pending(False)
                    toggle.setEnabled(False)
            if self.gamemode_label is not None:
                self.gamemode_label.setText("Leitura falhou; nenhuma configuração foi alterada. Tente Atualizar.")
        elif action_id == "themes.catalog":
            self.catalog_hint.setText("Catálogo indisponível agora — clique em Atualizar para tentar de novo.")
        elif action_id == "themes.history":
            self.history_hint.setText("Histórico indisponível agora — clique em Atualizar para tentar de novo.")

    def _apply_status(self, parsed: object) -> None:
        if not isinstance(parsed, dict):
            return
        host = parsed.get("host", {}) if isinstance(parsed.get("host"), dict) else {}
        plasma = parsed.get("plasma", {}) if isinstance(parsed.get("plasma"), dict) else {}
        hero = parsed.get("hero", {}) if isinstance(parsed.get("hero"), dict) else {}
        profile = parsed.get("profile", {}) if isinstance(parsed.get("profile"), dict) else {}

        self._set_hero("profile", profile.get("title", "Personalizado"))
        major = plasma.get("major")
        self._set_hero("plasma", f"{major if major is not None else '—'} · {'compatível' if plasma.get('compatible') else plasma.get('reason', 'incompatível')}")
        self._set_hero("session", f"{plasma.get('session', '—')} · KWin {'sim' if plasma.get('kwin') else 'não'}")
        self._set_hero("steamos", "sim" if plasma.get("steamOs") else "não")
        wallpaper = hero.get("wallpaper") if isinstance(hero.get("wallpaper"), dict) else {}
        # O motor emite {state, screens:[{screen, plugin, mode}]}; as chaves
        # file/color que a UI lia nunca existem e o herói ficava em "—".
        label = str(wallpaper.get("file", "") or wallpaper.get("color", "") or "")
        screens = wallpaper.get("screens") if isinstance(wallpaper.get("screens"), list) else []
        if not label and screens:
            label = f"{len(screens)} tela(s) · {screens[0].get('plugin', '—')}"
        self._set_hero("wallpaper", label or "—")
        battery = hero.get("battery") if isinstance(hero.get("battery"), dict) else {}
        percent = battery.get("percent")
        self._set_hero(
            "battery",
            f"{'bateria' if battery.get('onBattery') else 'tomada'}{f' ({percent}%)' if percent is not None else ''}",
        )

        if self.gamemode_label is not None:
            self.gamemode_label.setText(
                f"SteamOS: {'sim' if plasma.get('steamOs') else 'não'} · "
                f"Game Mode: {'ativo' if plasma.get('gameMode') else 'inativo'} · "
                f"Decky: {'instalado' if hero.get('decky') else 'ausente'}"
            )

        features = parsed.get("features", {}) if isinstance(parsed.get("features"), dict) else {}
        for feature_id, toggle, detail in self._controls:
            entry = features.get(feature_id, {}) if isinstance(features, dict) else {}
            state = str(entry.get("state", "indisponivel"))
            reason = str(entry.get("reason", "") or "")
            detail.setText(reason or self._state_label(state))
            checked = state in ("ligado", "pausado-bateria", "pausado-jogo", "aplicando")
            supported = state != "indisponivel"
            with QtSignalBlockerGuard(toggle):
                toggle.setChecked(checked)
                toggle.setProperty("applied", checked)
                toggle.setProperty("supported", supported)
                toggle.set_pending(False)
                toggle.setEnabled(supported)

    @staticmethod
    def _state_label(state: str) -> str:
        labels = {
            "ligado": "Ativo",
            "desligado": "Desativado",
            "pausado-bateria": "Ativo (pausado em bateria)",
            "pausado-jogo": "Ativo (pausado em jogos)",
            "degradado": "Estado parcial",
            "indisponivel": "Indisponível",
            "reinicio-pendente": "Reinício pendente",
        }
        return labels.get(state, state)

    def _apply_catalog(self, parsed: object) -> None:
        if not isinstance(parsed, dict):
            return
        self._catalog_loaded = True
        extensions = parsed.get("kdeExtensions", [])
        if isinstance(extensions, list):
            self.extensions_table.setRowCount(len(extensions))
            for row, entry in enumerate(extensions):
                if not isinstance(entry, dict):
                    continue
                self.extensions_table.setItem(row, 0, QTableWidgetItem(str(entry.get("title", entry.get("storeId", "")))))
                self.extensions_table.setItem(row, 1, QTableWidgetItem(str(entry.get("status", ""))))
                self.extensions_table.setItem(row, 2, QTableWidgetItem(str(entry.get("reason", ""))))
            self.extensions_table.resizeColumnsToContents()
        wallpapers = parsed.get("wallpapers", [])
        if isinstance(wallpapers, list):
            # O motor serializa a tupla (bool, reason) como array JSON;
            # truthiness de lista contava wallpaper ausente como disponível.
            def _is_available(item: object) -> bool:
                if not isinstance(item, dict):
                    return False
                flag = item.get("available")
                if isinstance(flag, list):
                    return bool(flag) and flag[0] is True
                return flag is True

            available = sum(1 for item in wallpapers if _is_available(item))
            self.catalog_hint.setText(
                f"{len(wallpapers)} wallpapers curados · {available} disponíveis · "
                f"{len(extensions) if isinstance(extensions, list) else 0} extensões KDE avaliadas"
            )

    def _apply_history(self, parsed: object) -> None:
        if not isinstance(parsed, dict):
            return
        self._history_loaded = True
        operations = parsed.get("operations", [])
        if not isinstance(operations, list):
            return
        self.history_table.setRowCount(len(operations))
        import time as _time

        for row, entry in enumerate(operations):
            if not isinstance(entry, dict):
                continue
            created = entry.get("createdAt", 0)
            when = _time.strftime("%Y-%m-%d %H:%M", _time.localtime(int(created))) if created else "—"
            self.history_table.setItem(row, 0, QTableWidgetItem(str(entry.get("operationId", ""))))
            self.history_table.setItem(row, 1, QTableWidgetItem(when))
            status = str(entry.get("status", ""))
            if entry.get("restored"):
                status += " (revertido)"
            self.history_table.setItem(row, 2, QTableWidgetItem(status))
            self.history_table.setItem(row, 3, QTableWidgetItem(", ".join(entry.get("features", []) or [])))
        self.history_table.resizeColumnsToContents()
        self.history_hint.setText(f"{len(operations)} operações registradas" if operations else "Nenhuma operação ainda.")

    def _set_hero(self, key: str, text: str) -> None:
        label = self._hero_labels.get(key)
        if label is not None:
            label.setText(text)

    def _on_tab_changed(self, index: int) -> None:
        widget = self.sender() if hasattr(self, "sender") else None
        if widget is None or not isinstance(widget, QTabWidget):
            return
        current = widget.widget(index)
        if current is self.catalog_tab and not self._catalog_loaded:
            action = self.by_id.get("themes.catalog")
            if action is not None and not self.status_loader.running(action.id):
                self.status_loader.fetch_action(action)
        elif current is self.history_tab and not self._history_loaded:
            action = self.by_id.get("themes.history")
            if action is not None and not self.status_loader.running(action.id):
                self.status_loader.fetch_action(action)

    # ------------------------------------------------------------ toggle flows

    def _feature_toggle_requested(self, index: int, checked: bool) -> None:
        feature_id, toggle, detail = self._controls[index]
        applied = bool(toggle.property("applied"))
        if checked == applied:
            return
        state = "on" if checked else "off"
        action = self.by_id.get(f"themes.feature.{feature_id}.{state}")
        if action is None:
            with QtSignalBlockerGuard(toggle):
                toggle.setChecked(applied)
            return
        previous_detail = detail.text()
        toggle.set_pending(True)
        toggle.setEnabled(False)
        detail.setText("Aguardando confirmação…")
        self._pending_toggles[action.id] = (toggle, applied, detail, previous_detail)
        # run_action espera action_id (str); passar o ActionSpec devolvia
        # None do by_id.get() e nenhum toggle disparava operação.
        self.request_action(action)

    def cancel_pending_action(self, action_id: str) -> None:
        pending = self._pending_toggles.pop(action_id, None)
        if pending is None:
            return
        toggle, applied, detail, previous_detail = pending
        with QtSignalBlockerGuard(toggle):
            toggle.setChecked(applied)
        toggle.set_pending(False)
        toggle.setEnabled(bool(toggle.property("supported")))
        detail.setText(previous_detail)

    def _request_undo(self) -> None:
        action = self.by_id.get("themes.undo")
        if action is not None:
            self.request_action(action)

    def _request_rescue(self) -> None:
        action = self.by_id.get("themes.rescue-wallpaper")
        if action is not None:
            self.request_action(action)

    def block_while_running(self, running: bool) -> None:
        tabs = self.findChild(QTabWidget)
        if tabs is not None:
            tabs.setEnabled(not running)
        self.undo_button.setEnabled(not running)
        self.rescue_button.setEnabled(not running)


class QtSignalBlockerGuard:
    """Contexto de bloqueio de sinais para toggles."""

    def __init__(self, widget: QWidget) -> None:
        self._widget = widget
        self._blocked = widget.blockSignals(True)

    def __enter__(self):
        return self

    def __exit__(self, *_exc) -> None:
        self._widget.blockSignals(self._blocked)
