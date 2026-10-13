#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${1:-$ROOT/dist}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="${PZ_DEB_WORK:-${TMPDIR:-/tmp}/phasezero-deb-build}"
VERSION="$(jq -er '.version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+([+-][0-9A-Za-z.-]+)?$"))' "$ROOT/version.json")"
PKG="$WORK/phasezero-control-center_${VERSION}_all"
SOURCE="$WORK/source"

rm -rf -- "$PKG" "$SOURCE"
mkdir -p "$SOURCE"
bash "$ROOT/packaging/linux/export-source.sh" "$SOURCE"
mkdir -p "$PKG/DEBIAN" "$PKG/usr/lib/phasezero" "$PKG/usr/bin" \
    "$PKG/usr/share/applications" "$PKG/usr/share/metainfo" \
    "$PKG/usr/share/icons/hicolor/scalable/apps"
cp "$SOURCE/packaging/linux/deb/control" "$PKG/DEBIAN/control"
# The tracked control file's Version field is documentation, not the build input;
# always stamp the copy with version.json so a shipped .deb never reports a stale
# version if the tracked file falls out of sync.
sed -i "s/^Version:.*/Version: $VERSION/" "$PKG/DEBIAN/control"
# No package manager owns /usr/local/lib/phasezero, so an upgrade leaves the
# Windows VM GRUB boot runtime on the previous release with nothing to say so.
# The notice only warns; re-running `boot install` rewrites grub.cfg and must
# never happen inside a package transaction.
cat > "$PKG/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = configure ] && [ -r /usr/lib/phasezero/linux/windows-vm/boot-runtime-notice.sh ]; then
    bash /usr/lib/phasezero/linux/windows-vm/boot-runtime-notice.sh || true
fi
exit 0
POSTINST
chmod 0755 "$PKG/DEBIAN/postinst"
cp -a "$SOURCE/linux" "$SOURCE/profiles" "$SOURCE/assets" "$SOURCE/version.json" "$PKG/usr/lib/phasezero/"
find "$PKG/usr/lib/phasezero" -type d -name __pycache__ -exec rm -rf {} +
install -m755 "$SOURCE/packaging/linux/phasezero-control-center" "$PKG/usr/bin/"
# PZ-AUD-001: ship `pz` on PATH (SSH bridge calls it remotely).
install -m755 "$SOURCE/packaging/linux/pz" "$PKG/usr/bin/"
install -m644 "$SOURCE/packaging/linux/io.phasezero.ControlCenter.desktop" "$PKG/usr/share/applications/"
install -m644 "$SOURCE/packaging/linux/io.phasezero.ControlCenter.metainfo.xml" "$PKG/usr/share/metainfo/"
install -m644 "$SOURCE/packaging/linux/io.phasezero.ControlCenter.svg" "$PKG/usr/share/icons/hicolor/scalable/apps/"
# Install category/Menu SVG icons for XDG menu and Qt theme fallback
install -m644 "$SOURCE/assets/icons/hicolor/scalable/apps/"*.svg "$PKG/usr/share/icons/hicolor/scalable/apps/"
if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb --root-owner-group --build "$PKG" "$OUT/"
else
    command -v ar >/dev/null || { echo "dpkg-deb/ar missing" >&2; exit 69; }
    MANUAL="$WORK/manual"
    rm -rf -- "$MANUAL"
    mkdir -p "$MANUAL/control" "$MANUAL/data"
    cp "$PKG/DEBIAN/control" "$MANUAL/control/control"
    cp "$PKG/DEBIAN/postinst" "$MANUAL/control/postinst"
    chmod 0755 "$MANUAL/control/postinst"
    cp -a "$PKG/usr" "$MANUAL/data/"
    printf '2.0\n' > "$MANUAL/debian-binary"
    tar --owner=0 --group=0 -C "$MANUAL/control" -czf "$MANUAL/control.tar.gz" .
    tar --owner=0 --group=0 -C "$MANUAL/data" -czf "$MANUAL/data.tar.gz" .
    (
        cd "$MANUAL"
        rm -f -- "$OUT/phasezero-control-center_${VERSION}_all.deb"
        ar r "$OUT/phasezero-control-center_${VERSION}_all.deb" \
            debian-binary control.tar.gz data.tar.gz
    )
fi
