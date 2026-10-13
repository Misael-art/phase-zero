#!/usr/bin/env bash
# release.sh - bump version.json, commit, tag and (optionally) push a new
# PhaseZero release. Pushing the tag triggers .github/workflows/release.yml,
# which builds every Linux package and publishes the GitHub Release.
#
# Usage:
#   packaging/release.sh 1.7.3                 # bump + commit + tag (local)
#   packaging/release.sh 1.7.3 --push          # also push branch + tag
#   packaging/release.sh 1.7.3 --channel beta  # set channel (default: stable)
#   packaging/release.sh --current             # print current version and exit
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VJSON="$ROOT/version.json"
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

current() { jq -r '.version' "$VJSON"; }

NEW=""
PUSH=0
CHANNEL=""
for arg in "$@"; do
    case "$arg" in
        --current) current; exit 0 ;;
        --push) PUSH=1 ;;
        --channel=*) CHANNEL="${arg#*=}" ;;
        --channel) : ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -12; exit 0 ;;
        stable|beta|nightly) [ -n "$CHANNEL" ] || CHANNEL="$arg" ;;
        [0-9]*) NEW="$arg" ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

[ -n "$NEW" ] || { echo "usage: packaging/release.sh <version> [--push] [--channel stable|beta|nightly]" >&2; exit 2; }
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || { echo "invalid semver: $NEW" >&2; exit 2; }
[ -z "$CHANNEL" ] && CHANNEL="$(jq -r '.channel // "stable"' "$VJSON")"

# Refuse to release on a dirty tree (avoid tagging half-finished work).
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
    echo "working tree has uncommitted changes; commit or stash before releasing" >&2
    exit 1
fi

TAG="v$NEW"
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "tag already exists: $TAG" >&2; exit 1
fi

BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RELEASE_DATE="${BUILT_AT%%T*}"
tmp="$(mktemp)"
jq --arg v "$NEW" --arg ch "$CHANNEL" --arg tag "release-$TAG" --arg at "$BUILT_AT" \
    '.version=$v | .channel=$ch | .commit=$tag | .builtAt=$at' "$VJSON" > "$tmp"
mv "$tmp" "$VJSON"

sed -i -E "s/^Version: [^[:space:]]+/Version: $NEW/" "$ROOT/packaging/linux/deb/control"
sed -i -E "s/^Version:[[:space:]]+[^[:space:]]+/Version:        $NEW/" "$ROOT/packaging/linux/rpm/phasezero-control-center.spec"
sed -i -E "s/^pkgver=.*/pkgver=$NEW/" "$ROOT/packaging/linux/aur/PKGBUILD"
sed -i -E \
    -e "s/^([[:space:]]*pkgver[[:space:]]*=[[:space:]]*).*/\\1$NEW/" \
    -e "s#^([[:space:]]*source = ).*#\\1PhaseZero-$NEW.tar.gz#" \
    -e "s#^([[:space:]]*sha256sums = ).*#\\1SKIP#" \
    "$ROOT/packaging/linux/aur/.SRCINFO"
sed -i -E "s/^([[:space:]]*tag:[[:space:]]*)v.*/\\1v$NEW/" "$ROOT/packaging/linux/flatpak/io.phasezero.ControlCenter.yml"
if ! grep -Fq "<release version=\"$NEW\"" "$ROOT/packaging/linux/io.phasezero.ControlCenter.metainfo.xml"; then
    sed -i "/<releases>/a\\    <release version=\"$NEW\" date=\"$RELEASE_DATE\"/>" \
        "$ROOT/packaging/linux/io.phasezero.ControlCenter.metainfo.xml"
fi

git -C "$ROOT" add \
    version.json \
    packaging/linux/deb/control \
    packaging/linux/rpm/phasezero-control-center.spec \
    packaging/linux/aur/PKGBUILD \
    packaging/linux/aur/.SRCINFO \
    packaging/linux/flatpak/io.phasezero.ControlCenter.yml \
    packaging/linux/io.phasezero.ControlCenter.metainfo.xml
git -C "$ROOT" commit -q -m "release: $TAG"
git -C "$ROOT" tag -a "$TAG" -m "PhaseZero $TAG"
echo "prepared $TAG (channel=$CHANNEL, builtAt=$BUILT_AT)"

if [ "$PUSH" = 1 ]; then
    branch="$(git -C "$ROOT" branch --show-current)"
    git -C "$ROOT" push origin "$branch"
    git -C "$ROOT" push origin "$TAG"
    echo "pushed $branch and $TAG; release workflow will build and publish."
else
    echo "review, then: git push origin \$(git branch --show-current) && git push origin $TAG"
fi
