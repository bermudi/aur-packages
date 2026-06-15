#!/usr/bin/env bash
# Generate .SRCINFO for a package by sourcing its PKGBUILD.
# No makepkg required — works on plain Ubuntu runners.
#
# Usage: generate-srcinfo.sh <pkgdir>

set -eo pipefail

PKGDIR="${1:-.}"
PKGBUILD="$PKGDIR/PKGBUILD"

if [[ ! -f "$PKGBUILD" ]]; then
    echo "Error: PKGBUILD not found at $PKGBUILD" >&2
    exit 1
fi

# Pre-declare everything we read so a PKGBUILD that omits an optional field
# (e.g. makedepends, replaces) doesn't trip `set -u` or emit an empty
# `key = ` line. Sourcing the PKGBUILD overwrites these with real values.
pkgbase="" pkgname="" pkgdesc="" pkgver="" pkgrel="" url=""
declare -a arch=() license=() makedepends=() depends=()
declare -a optdepends=() provides=() conflicts=() replaces=() options=()
declare -a source=() sha256sums=()

# shellcheck source=/dev/null
source "$PKGBUILD"

# pkgbase falls back to pkgname when not set (single-package PKGBUILDs)
_pb="${pkgbase:-$pkgname}"

{
    echo "pkgbase = ${_pb}"
    printf '\tpkgdesc = %s\n' "$pkgdesc"
    printf '\tpkgver = %s\n' "$pkgver"
    printf '\tpkgrel = %s\n' "$pkgrel"
    printf '\turl = %s\n' "$url"

    for v in "${arch[@]}";        do printf '\tarch = %s\n'         "$v"; done
    for v in "${license[@]}";     do printf '\tlicense = %s\n'      "$v"; done
    for v in "${makedepends[@]}"; do printf '\tmakedepends = %s\n'  "$v"; done
    for v in "${depends[@]}";     do printf '\tdepends = %s\n'      "$v"; done
    for v in "${optdepends[@]}";  do printf '\toptdepends = %s\n'   "$v"; done
    for v in "${provides[@]}";    do printf '\tprovides = %s\n'     "$v"; done
    for v in "${conflicts[@]}";   do printf '\tconflicts = %s\n'    "$v"; done
    for v in "${replaces[@]}";    do printf '\treplaces = %s\n'     "$v"; done
    for v in "${options[@]}";     do printf '\toptions = %s\n'      "$v"; done
    for v in "${source[@]}";      do printf '\tsource = %s\n'       "$v"; done
    for v in "${sha256sums[@]}";  do printf '\tsha256sums = %s\n'   "$v"; done

    echo ""
    echo "pkgname = ${pkgname}"
} > "$PKGDIR/.SRCINFO"

echo "Generated $PKGDIR/.SRCINFO"
