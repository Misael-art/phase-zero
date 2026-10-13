"""Regenerate the checked-in PXA-001 action migration map."""

from __future__ import annotations

from pathlib import Path

from linux.ui_native.product_inventory import inventory_manifest, render_inventory_manifest


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "linux" / "ui_native" / "product_inventory.json"


def main() -> None:
    payload = inventory_manifest(ROOT)
    OUTPUT.write_text(render_inventory_manifest(payload), encoding="utf-8")
    print(f"{OUTPUT}: {payload['actionCount']} actions, {len(payload['products'])} products")


if __name__ == "__main__":
    main()
