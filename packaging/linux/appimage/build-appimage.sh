#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${1:-$ROOT/dist}"
PYTHON="${PYTHON:-python3}"
APPIMAGETOOL="${APPIMAGETOOL:-$(command -v appimagetool || true)}"
PYTHON_BIN="$(command -v "$PYTHON" 2>/dev/null || true)"
# continuous changes without a new hash and failed the v1.22.3 package job
# (downloaded 14.39 MiB, checksum mismatch). 1.9.1 is the latest numbered
# release and stays at this digest.
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage"
APPIMAGETOOL_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"

# The AppDir must NOT live on a FUSE-backed filesystem (NTFS-3g, sshfs, ...):
# appimagetool's parallel mksquashfs can silently drop files under I/O pressure
# there (observed on an NTFS-3g SD-card checkout: ~80 stdlib files including
# encodings/ vanished with no error, producing an AppImage that failed at
# startup with "Fatal Python error: Failed to import encodings module"). Default
# to a fresh dir under /tmp (tmpfs on most distros); do not inherit TMPDIR:
# desktop launchers commonly put it in a small per-user runtime tmpfs. Pass
# PZ_APPIMAGE_WORK to override, but keep it off FUSE/network mounts.
WORK="${PZ_APPIMAGE_WORK:-}"
CLEANUP_WORK=0
SMOKE_DIR=""
TOOL_TEMP=""
if [ -z "$WORK" ]; then
    WORK="$(mktemp -d "/tmp/pz-appimage-build.XXXXXX")"
    CLEANUP_WORK=1
fi
case "$WORK" in
    ""|/|"$HOME"|"$ROOT") echo "unsafe AppImage work path: ${WORK:-<empty>}" >&2; exit 64 ;;
esac
APPDIR="$WORK/PhaseZero.AppDir"
SOURCE="$WORK/source"

cleanup() {
    [ -z "$TOOL_TEMP" ] || [ ! -f "$TOOL_TEMP" ] || rm -f -- "$TOOL_TEMP"
    [ -z "$SMOKE_DIR" ] || [ ! -d "$SMOKE_DIR" ] || rm -rf -- "$SMOKE_DIR"
    if [ "$CLEANUP_WORK" = 1 ] && [ -n "$WORK" ] && [ -d "$WORK" ]; then
        rm -rf -- "$WORK"
    fi
}
trap cleanup EXIT

if [ -z "$APPIMAGETOOL" ]; then
    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) echo "appimagetool auto-download supports x86_64 only" >&2; exit 69 ;;
    esac
    command -v curl >/dev/null || { echo "curl missing for verified appimagetool download" >&2; exit 69; }
    command -v sha256sum >/dev/null || { echo "sha256sum missing" >&2; exit 69; }
    tool_cache="${XDG_CACHE_HOME:-$HOME/.cache}/phasezero/build-tools"
    APPIMAGETOOL="$tool_cache/appimagetool-${APPIMAGETOOL_SHA256}.AppImage"
    if [ ! -f "$APPIMAGETOOL" ]; then
        mkdir -p "$tool_cache"
        temporary="$APPIMAGETOOL.download.$$"
        TOOL_TEMP="$temporary"
        curl --fail --location --retry 3 --retry-delay 2 \
            --output "$temporary" "$APPIMAGETOOL_URL"
        printf '%s  %s\n' "$APPIMAGETOOL_SHA256" "$temporary" | sha256sum -c -
        chmod 0755 "$temporary"
        mv "$temporary" "$APPIMAGETOOL"
        temporary=""
        TOOL_TEMP=""
    fi
    printf '%s  %s\n' "$APPIMAGETOOL_SHA256" "$APPIMAGETOOL" | sha256sum -c -
fi
if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
    echo "python executable missing: $PYTHON" >&2
    exit 69
fi
command -v jq >/dev/null 2>&1 || { echo "jq missing" >&2; exit 69; }
"$PYTHON_BIN" -m pip --version >/dev/null 2>&1 || { echo "python pip missing" >&2; exit 69; }

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

rm -rf -- "$APPDIR" "$SOURCE"
mkdir -p "$SOURCE"
bash "$ROOT/packaging/linux/export-source.sh" "$SOURCE"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib/phasezero" \
    "$APPDIR/usr/lib/python3/site-packages" "$APPDIR/usr/share/applications" \
    "$APPDIR/usr/share/metainfo"

cp -a "$SOURCE/linux" "$SOURCE/profiles" "$SOURCE/assets" "$SOURCE/version.json" "$APPDIR/usr/lib/phasezero/"
find "$APPDIR/usr/lib/phasezero" -type d -name __pycache__ -exec rm -rf {} +
cp "$SOURCE/packaging/linux/appimage/AppRun" "$APPDIR/AppRun"
cp "$SOURCE/packaging/linux/io.phasezero.ControlCenter.desktop" \
    "$APPDIR/io.phasezero.ControlCenter.desktop"
cp "$SOURCE/packaging/linux/io.phasezero.ControlCenter.desktop" \
    "$APPDIR/usr/share/applications/"
cp "$SOURCE/packaging/linux/io.phasezero.ControlCenter.metainfo.xml" \
    "$APPDIR/usr/share/metainfo/io.phasezero.ControlCenter.appdata.xml"
cp "$PYTHON_BIN" "$APPDIR/usr/bin/python3"
PY_VER="$("$PYTHON_BIN" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
STDLIB="$("$PYTHON_BIN" -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"
LIBPYTHON_PATH="$("$PYTHON_BIN" - <<'PY'
import os
import sysconfig
name = sysconfig.get_config_var("LDLIBRARY") or ""
libdir = sysconfig.get_config_var("LIBDIR") or ""
path = os.path.join(libdir, name) if name and libdir else ""
print(path if os.path.isfile(path) else "")
PY
)"
[ -d "$STDLIB" ] || { echo "python stdlib missing: $STDLIB" >&2; exit 1; }
cp -a "$STDLIB" "$APPDIR/usr/lib/python$PY_VER"
rm -rf -- "$APPDIR/usr/lib/python$PY_VER/site-packages"
if [ -n "$LIBPYTHON_PATH" ]; then
    cp -a "$LIBPYTHON_PATH" "$APPDIR/usr/lib/"
fi

"$PYTHON_BIN" -m pip install --disable-pip-version-check --no-compile \
    --target "$APPDIR/usr/lib/python3/site-packages" \
    "PySide6_Essentials==6.11.1" "shiboken6==6.11.1"

cp "$SOURCE/packaging/linux/io.phasezero.ControlCenter.svg" \
    "$APPDIR/io.phasezero.ControlCenter.svg"
ln -s "io.phasezero.ControlCenter.svg" "$APPDIR/.DirIcon"
chmod +x "$APPDIR/AppRun" "$APPDIR/usr/lib/phasezero/linux/pz" \
    "$APPDIR/usr/lib/phasezero/linux/ui/native.sh"

# Bundle sanity: the AppDir must run standalone from any cwd before packaging.
SMOKE_DIR="$(mktemp -d "/tmp/pz-appimage-smoke.XXXXXX")"
(cd "$SMOKE_DIR" && QT_QPA_PLATFORM=offscreen "$APPDIR/AppRun" --smoke-test)
rm -rf -- "$SMOKE_DIR"
SMOKE_DIR=""

VERSION="$(jq -er '.version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+([+-][0-9A-Za-z.-]+)?$"))' "$ROOT/version.json")"
ARCH="${ARCH:-$(uname -m)}"
export ARCH
"$APPIMAGETOOL" "$APPDIR" "$OUT/PhaseZero-$VERSION-$ARCH.AppImage"
