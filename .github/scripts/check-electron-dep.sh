#!/usr/bin/env bash
# Verify that the electronXX dependency declared in PKGBUILD matches the
# Electron major version actually shipped by the upstream deb.
#
# Fails the pipeline on mismatch so a human bumps the dependency BEFORE a
# broken PKGBUILD reaches AUR.
#
# Self-gating: no-op for PKGBUILDs without an electronXX dependency, so it
# is safe to call from the shared update-aur workflow for any package.
#
# Usage: check-electron-dep.sh <pkgdir>

set -euo pipefail

PKGDIR="${1:-.}"
PKGBUILD="$PKGDIR/PKGBUILD"

if [[ ! -f "$PKGBUILD" ]]; then
    echo "Error: PKGBUILD not found at $PKGBUILD" >&2
    exit 1
fi

# Pre-declare everything we read so sourcing doesn't trip under set -u.
declare -a depends=() source=() sha256sums=()
_apt_base="" _apt_pool="" _upstream_ver="" _debfile=""

# shellcheck source=/dev/null
source "$PKGBUILD"

# Only check packages that declare a system-electron dependency.
_electron_dep=$(printf '%s\n' "${depends[@]}" | grep -oE 'electron[0-9]+' | head -1 || true)
if [[ -z "$_electron_dep" ]]; then
    echo "No electronXX dependency; skipping Electron version check."
    exit 0
fi

_deb_url="${_apt_base}/${_apt_pool}/${_debfile}"
echo "Checking Electron version against: ${_deb_url}"

_tmpdir=$(mktemp -d)
trap 'rm -rf "$_tmpdir"' EXIT

curl -fsSL -o "$_tmpdir/dev.deb" "$_deb_url"

cd "$_tmpdir"
ar x dev.deb

mkdir -p data
for _archive in data.tar.xz data.tar.zst data.tar.gz; do
    if [[ -f "$_archive" ]]; then
        tar -xf "$_archive" -C data --wildcards --no-anchored 'resources/app/package.json'
        break
    fi
done

_pkgjson=$(find data -name package.json -path '*/resources/app/*' | head -1)
if [[ -z "$_pkgjson" ]]; then
    echo "Error: could not find resources/app/package.json in the deb" >&2
    exit 1
fi

# --- TEMPORARY DIAGNOSTIC (always exits 1 below) ----------------------
# Runs before the Commit/Release/AUR steps in update-aur.yml, so this
# branch can never publish anything. Remove once 3.12 packaging is mapped.
echo "--- DIAG: package.json bytes ---"
wc -c < "$_pkgjson"
echo "--- DIAG: electron-ish lines in package.json ---"
grep -in 'electron' "$_pkgjson" | head -20 || echo "(none)"
echo "--- DIAG: package.json head ---"
head -c 1500 "$_pkgjson"
echo; echo
_tar_archive=""
for _a in data.tar.xz data.tar.zst data.tar.gz; do
    if [[ -f "$_a" ]]; then _tar_archive="$_a"; break; fi
done
echo "--- DIAG: top-level tar layout ---"
tar -tf "$_tar_archive" 2>/dev/null | cut -d/ -f1-4 | sort -u | head -30 || true
echo "--- DIAG: resources/ siblings (first 40) ---"
tar -tf "$_tar_archive" --wildcards 'usr/share/devin-desktop*/resources/*' 2>/dev/null | head -40 || true
echo "--- DIAG: Electron/ string in main binary ---"
tar -xf "$_tar_archive" -C data --wildcards --no-anchored '*/devin-desktop' 2>/dev/null || true
_bin=$(find data -type f -name devin-desktop | head -1)
if [[ -n "$_bin" ]]; then
    strings "$_bin" | grep -E 'Electron/[0-9]+\.[0-9]' | sort -u | head -5 || echo "(no Electron/ strings)"
else
    echo "(main binary not found in deb)"
fi
echo "--- END DIAGNOSTIC — exiting 1 by design ---"
exit 1
# ----------------------------------------------------------------------

# Same regex as the PKGBUILD's build() detection.
_electron_major=$(sed -n '/"electron":/s/.*"electron": *"\{0,1\} *\([0-9]\+\).*/\1/p' "$_pkgjson" | head -1)
if [[ -z "$_electron_major" ]]; then
    echo "Error: could not detect Electron version from package.json" >&2
    exit 1
fi

_detected="electron${_electron_major}"
if [[ "$_detected" != "$_electron_dep" ]]; then
    echo "Error: upstream ships Electron ${_electron_major} (${_detected})" >&2
    echo "       but PKGBUILD depends on ${_electron_dep}." >&2
    echo "       Bump the electron entry in ${PKGBUILD} depends and re-run." >&2
    exit 1
fi

echo "OK: PKGBUILD declares ${_electron_dep}, upstream ships Electron ${_electron_major}."
