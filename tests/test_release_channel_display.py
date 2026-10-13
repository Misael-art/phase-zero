from linux.ui_native import _display_version


def test_stable_channel_keeps_plain_version():
    assert _display_version("1.22.0", "stable") == "1.22.0"


def test_preview_channels_are_visible_in_ui_version():
    assert _display_version("1.22.0", "beta") == "1.22.0 (beta)"
    assert _display_version("1.22.0", "nightly") == "1.22.0 (nightly)"


def test_unknown_channel_does_not_claim_preview_or_stable():
    assert _display_version("1.22.0", None) == "1.22.0"
