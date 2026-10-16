#!/usr/bin/env bash
# Single trusted source for the virtio-win ISO the product installs from.
#
# preflight used to follow the floating stable-virtio link while provision
# required a pinned SHA-256 written out separately, so --auto-fix could only
# ever hand provisioning an ISO it would refuse: the host cache ended up as one
# hash while the installer demanded another. Version, URL and hash now live
# here, derived from the version, and every consumer reads them from here too.
#
# Overriding the version is the only knob a caller needs; the URL follows.
PZ_VIRTIO_WIN_VERSION="${PZ_WINDOWS_VM_VIRTIO_VERSION:-0.1.285}"
PZ_VIRTIO_WIN_URL="${PZ_WINDOWS_VM_VIRTIO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-${PZ_VIRTIO_WIN_VERSION}-1/virtio-win-${PZ_VIRTIO_WIN_VERSION}.iso}"
PZ_VIRTIO_WIN_SHA256="${PZ_WINDOWS_VM_VIRTIO_SHA256:-e14cf2b94492c3e925f0070ba7fdfedeb2048c91eea9c5a5afb30232a3976331}"

# A file is trusted only when its hash equals the hash above. Never treat a
# cached or freshly downloaded ISO as ready just because it exists.
virtio_win_sha_matches() {
    local path="$1"
    local expected="${PZ_VIRTIO_WIN_SHA256,,}"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    [ -f "$path" ] && [ -r "$path" ] || return 1
    [ "$(sha256sum "$path" | cut -d' ' -f1)" = "$expected" ]
}
