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
pkgname=""

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

# Same regex as the PKGBUILD's build() detection.
_electron_major=$(sed -n '/"electron":/s/.*"electron": *"\{0,1\} *\([0-9]\+\).*/\1/p' "$_pkgjson" | head -1)

# 3.12+ ships the unpruned VS Code-fork source package.json, which has no
# runtime electron pin (only an npm script alias and build-tooling
# devDependencies). Fall back to the version string baked into the bundled
# Electron binary — the same fallback the PKGBUILD's build() uses. The
# binary is named after pkgname (devin-desktop, devin-desktop-next) but the
# /usr/share dir may differ (legacy windsurf-*); usr/bin/<pkgname> is a
# wrapper without a version string, so the probe must stay under usr/share.
if [[ -z "$_electron_major" ]]; then
    _tar_archive=""
    for _a in data.tar.xz data.tar.zst data.tar.gz; do
        if [[ -f "$_a" ]]; then _tar_archive="$_a"; break; fi
    done
    rm -rf bin-extract && mkdir bin-extract
    tar -xf "$_tar_archive" -C bin-extract --wildcards --no-anchored \
        "usr/share/*/${pkgname}" 2>/dev/null || true
    _binfile=$(find bin-extract -type f -name "$pkgname" \
        -exec du -b {} \; 2>/dev/null | sort -rn | head -1 | awk '{print $2}')
    if [[ -n "$_binfile" ]]; then
        _electron_major=$(strings "$_binfile" | sed -n 's|.*Electron/\([0-9]\+\).*|\1|p' | head -1)
    fi
fi

# --- TEMPORARY DIAG3 (always exits 1 below) — ground truth for the NEXT
# channel deb (3.12.1043). update-aur.yml runs nothing after this step,
# so this branch can never publish. Remove after the probe run. ---------
echo "--- DIAG3: pkgname=${pkgname} declared=${_electron_dep} detected=${_electron_major:-<none>}"
if [[ -z "${_tar_archive:-}" ]]; then
    for _a in data.tar.xz data.tar.zst data.tar.gz; do
        if [[ -f "$_a" ]]; then _tar_archive="$_a"; break; fi
    done
fi
if [[ -n "${_tar_archive:-}" ]]; then
    echo "--- DIAG3: usr/share top-level entries:"
    tar -tf "$_tar_archive" 2>/dev/null | grep 'usr/share/' \
        | sed -E 's|.*usr/share/([^/]+).*|\1|' | sort -u | head -20 || true
fi
if [[ -n "${_binfile:-}" ]]; then
    echo "--- DIAG3: probed binary: $_binfile"
    strings "$_binfile" | grep -E '^(Electron|Chrome|Node\.js)/[0-9]+\.' | sort -u | head -10 || true
else
    echo "--- DIAG3: no binary probed"
fi
echo "--- END DIAG3 — exiting 1 by design ---"
exit 1
# ----------------------------------------------------------------------

if [[ -z "$_electron_major" ]]; then
    echo "Error: could not detect Electron version from package.json or bundled binary" >&2
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
