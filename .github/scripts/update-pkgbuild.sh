#!/usr/bin/env bash
# Update volatile fields in a package's PKGBUILD, in place.
#
# When pkgver changes, pkgrel is reset to 1. The first sha256sums entry (the
# downloaded artifact) and, if needed, _apt_pool are also rewritten. The rest
# of the PKGBUILD — depends, package(), desktop-file references — is left
# untouched, so hand-edits survive.
#
# Usage: update-pkgbuild.sh <pkgdir> <arch_version> <sha256> [apt_filename]
#   pkgdir        directory containing PKGBUILD (relative to repo root)
#   arch_version  version in Arch format (e.g. 3.1.1005_next.296eca6010)
#   sha256        SHA256 of the new deb/tarball
#   apt_filename  optional path from the APT Packages file (e.g.
#                 pool/main/d/devin-desktop-next/Devin-linux-x64-3.1.1005+next.x.deb);
#                 used to detect and follow pool directory changes.

set -euo pipefail

PKGDIR="$1"
NEW_VERSION="$2"
NEW_SHA256="$3"
NEW_FILENAME="${4:-}"

if [[ ! "$NEW_VERSION" =~ ^[a-zA-Z0-9._]+$ ]]; then
    echo "Error: Invalid version format: $NEW_VERSION" >&2
    exit 1
fi
if [[ ! "$NEW_SHA256" =~ ^[a-f0-9]{64}$ ]]; then
    echo "Error: Invalid SHA256 format: $NEW_SHA256" >&2
    exit 1
fi

PKGBUILD="$PKGDIR/PKGBUILD"
if [[ ! -f "$PKGBUILD" ]]; then
    echo "Error: PKGBUILD not found at $PKGBUILD" >&2
    exit 1
fi

# Validate the fields we rely on without sourcing untrusted shell code.
grep -qE '^sha256sums=\(' "$PKGBUILD" || {
    echo "Error: PKGBUILD must define a sha256sums=( array" >&2
    exit 1
}
grep -qE '^pkgrel=[0-9]+$' "$PKGBUILD" || {
    echo "Error: PKGBUILD must define a numeric pkgrel" >&2
    exit 1
}

echo "Updating $PKGBUILD -> $NEW_VERSION"

# 1) pkgver=. A new upstream version begins a new Arch package release series,
# so reset pkgrel to 1. Preserve pkgrel when only the artifact metadata changes.
old_version="$(grep -E '^pkgver=' "$PKGBUILD" | head -1 | cut -d= -f2-)"
if [[ -z "$old_version" ]]; then
    echo "Error: PKGBUILD must define pkgver" >&2
    exit 1
fi
if [[ "$old_version" != "$NEW_VERSION" ]]; then
    sed -i -E "s|^pkgver=.*|pkgver=$NEW_VERSION|" "$PKGBUILD"
    sed -i -E 's|^pkgrel=.*|pkgrel=1|' "$PKGBUILD"
    echo "Version changed: reset pkgrel to 1"
fi

# 2) first sha256sums entry (the downloaded artifact is always source[0])
awk -v new="$NEW_SHA256" '
    /^sha256sums=\(/ { in_sha = 1; print; next }
    in_sha && !done && match($0, /[0-9a-f]{64}/) {
        sub(/[0-9a-f]{64}/, new); done = 1
    }
    in_sha && /^\)/ { in_sha = 0 }
    { print }
' "$PKGBUILD" > "$PKGBUILD.tmp" && mv "$PKGBUILD.tmp" "$PKGBUILD"

# 3) follow pool directory changes if the APT Packages file moved the deb
if [[ -n "$NEW_FILENAME" ]]; then
    new_pool="$(dirname "$NEW_FILENAME")"
    old_pool="$(grep -E '^_apt_pool=' "$PKGBUILD" | head -1 | sed -E 's/^_apt_pool="(.*)"$/\1/')"
    if [[ -n "$old_pool" && "$old_pool" != "$new_pool" ]]; then
        echo "Pool changed: $old_pool -> $new_pool"
        sed -i -E "s|^_apt_pool=.*|_apt_pool=\"$new_pool\"|" "$PKGBUILD"
    fi
fi

echo "Done."
