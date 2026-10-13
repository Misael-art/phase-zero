"""Qt accessibility events for dynamic UI status updates."""

from __future__ import annotations

from PySide6.QtWidgets import QWidget


def announce_accessible(widget: QWidget | None, message: str) -> None:
    """Request a polite screen-reader announcement when accessibility is active."""
    if widget is None or not message:
        return
    try:
        from PySide6.QtGui import QAccessible, QAccessibleAnnouncementEvent
    except ImportError:
        return
    if QAccessible.isActive():
        QAccessible.updateAccessibility(QAccessibleAnnouncementEvent(widget, message))
