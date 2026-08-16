#!/usr/bin/env bash
# Update volatile fields in a package's PKGBUILD, in place.
#
# When pkgver changes, pkgrel is reset to 1. Checksum entries (the downloaded
# artifact) and, if needed, _apt_pool are also rewritten. The rest of the
# PKGBUILD — depends, package(), desktop-file references — is left untouched,
# so hand-edits survive.
#
# Usage: update-pkgbuild.sh <pkgdir> <arch_version> <checksum> [apt_filename] [aarch64_checksum]
#   pkgdir             directory containing PKGBUILD (relative to repo root)
#   arch_version       version in Arch format (e.g. 3.1.1005_next.296eca6010
#                      or 0.0.0_next_17444)
#   checksum           hex sha256 (64 chars) or sha512 (128 chars) of the
#                      primary artifact (source[0] of the flat array, or the
#                      x86_64 entry of an arch-specific array)
#   apt_filename       optional path from the APT Packages file (e.g.
#                      pool/main/d/devin-desktop-next/Devin-linux-x64-3.1.1005+next.x.deb);
#                      used to detect and follow pool directory changes.
#   aarch64_checksum   optional hex checksum for the aarch64 entry of an
#                      arch-specific checksum array (npm-sourced packages)

set -euo pipefail

PKGDIR="$1"
NEW_VERSION="$2"
NEW_CHECKSUM="$3"
NEW_FILENAME="${4:-}"
NEW_AARCH64_CHECKSUM="${5:-}"

if [[ ! "$NEW_VERSION" =~ ^[a-zA-Z0-9._]+$ ]]; then
    echo "Error: Invalid version format: $NEW_VERSION" >&2
    exit 1
fi
validate_checksum() {
    [[ "$1" =~ ^[a-f0-9]{64}$ || "$1" =~ ^[a-f0-9]{128}$ ]]
}
if ! validate_checksum "$NEW_CHECKSUM"; then
    echo "Error: Invalid checksum format: $NEW_CHECKSUM (expected 64-char sha256 or 128-char sha512 hex)" >&2
    exit 1
fi
if [[ -n "$NEW_AARCH64_CHECKSUM" ]] && ! validate_checksum "$NEW_AARCH64_CHECKSUM"; then
    echo "Error: Invalid aarch64 checksum format: $NEW_AARCH64_CHECKSUM" >&2
    exit 1
fi

PKGBUILD="$PKGDIR/PKGBUILD"
if [[ ! -f "$PKGBUILD" ]]; then
    echo "Error: PKGBUILD not found at $PKGBUILD" >&2
    exit 1
fi

# Validate the fields we rely on without sourcing untrusted shell code.
grep -qE '^(sha256sums|sha512sums)(_[a-z0-9]+)?=\(' "$PKGBUILD" || {
    echo "Error: PKGBUILD must define a checksum array (sha256sums=, sha512sums=, or arch-specific)" >&2
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

# 2) checksums. Replace the first entry in each checksum array that matches a
# given declaration. For flat arrays the artifact is always source[0]; for
# arch-specific arrays (npm-sourced packages) each arch gets its own value.
replace_checksum() {
    local array_re="$1" newval="$2"
    awk -v re="$array_re" -v new="$newval" '
        $0 ~ re {
            in_sha = 1
            if (match($0, /[0-9a-f]{64}|[0-9a-f]{128}/)) {
                sub(/[0-9a-f]{64}|[0-9a-f]{128}/, new); done = 1
            }
            # single-line arrays close on the same line; multi-line arrays
            # close on a later "^)" line.
            if ($0 ~ /\)/) in_sha = 0
            print; next
        }
        in_sha && !done && match($0, /[0-9a-f]{64}|[0-9a-f]{128}/) {
            sub(/[0-9a-f]{64}|[0-9a-f]{128}/, new); done = 1
        }
        in_sha && /^\)/ { in_sha = 0 }
        { print }
    ' "$PKGBUILD" > "$PKGBUILD.tmp" && mv "$PKGBUILD.tmp" "$PKGBUILD"
}

if grep -qE '^sha(256|512)sums_(x86_64|aarch64)=\(' "$PKGBUILD"; then
    replace_checksum '^sha(256|512)sums_x86_64=[(]' "$NEW_CHECKSUM"
    if [[ -n "$NEW_AARCH64_CHECKSUM" ]]; then
        replace_checksum '^sha(256|512)sums_aarch64=[(]' "$NEW_AARCH64_CHECKSUM"
    fi
else
    replace_checksum '^sha(256|512)sums=[(]' "$NEW_CHECKSUM"
fi

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
