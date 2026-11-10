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

# --- TEMPORARY DIAGNOSTIC ROUND 2 (always exits 1 below) --------------
# Runs before the Commit/Release/AUR steps in update-aur.yml, so this
# branch can never publish anything. Remove once 3.12 packaging is mapped.
echo "--- DIAG2: FULL package.json ---"
cat "$_pkgjson"
_tar_archive=""
for _a in data.tar.xz data.tar.zst data.tar.gz; do
    if [[ -f "$_a" ]]; then _tar_archive="$_a"; break; fi
done
echo "--- DIAG2: deb control Depends ---"
ar x dev.deb control.tar.zst 2>/dev/null || ar x dev.deb control.tar.xz 2>/dev/null || ar x dev.deb control.tar.gz 2>/dev/null || true
for _c in control.tar.zst control.tar.xz control.tar.gz; do
    if [[ -f "$_c" ]]; then
        tar -xOf "$_c" ./control 2>/dev/null | sed -n '/^Package:/p;/^Version:/p;/^Depends:/p'
        break
    fi
done
echo "--- DIAG2: usr/share/devin-desktop top level ---"
tar -tf "$_tar_archive" --no-anchored 'usr/share/devin-desktop/*' 2>/dev/null \
    | sed -E 's|.*usr/share/devin-desktop/([^/]+).*|\1|' | sort -u | head -50 || true
echo "--- DIAG2: resources/app top level ---"
tar -tf "$_tar_archive" --no-anchored 'usr/share/devin-desktop/resources/app/*' 2>/dev/null \
    | sed -E 's|.*resources/app/([^/]+).*|\1|' | sort -u | head -60 || true
echo "--- DIAG2: extract both devin-desktop files, pick the biggest ---"
rm -rf data2 && mkdir data2
tar -xf "$_tar_archive" -C data2 --wildcards --no-anchored \
    'usr/bin/devin-desktop' 'usr/share/devin-desktop/devin-desktop' 2>/dev/null || true
find data2 -type f -name devin-desktop -exec ls -la {} \; || true
_bin=$(find data2 -type f -name devin-desktop -exec du -b {} \; 2>/dev/null | sort -rn | head -1 | awk '{print $2}')
echo "--- DIAG2: version strings in: ${_bin:-<none>} ---"
if [[ -n "${_bin:-}" ]]; then
    strings "$_bin" | grep -E '^(Electron|Chrome|Node\.js)/[0-9]+\.' | sort -u | head -10 || echo "(none)"
fi
echo "--- DIAG2: electron pin candidates under resources/app ---"
tar -tf "$_tar_archive" --no-anchored 'usr/share/devin-desktop/resources/app/build/*' 2>/dev/null | head -20 || true
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
