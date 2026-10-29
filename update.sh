#!/usr/bin/env bash
#
# update.sh - Automated maintenance script for nextendo-citron-bin
# Queries upstream GitHub releases, extracts nightly assets, updates PKGBUILD and .SRCINFO.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Defaults & Flags
CHECK_ONLY=false
DRY_RUN=false
FORCE=false

usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -c, --check     Check if an update is available without modifying files.
                  Returns exit code 0 if up-to-date, 1 if update available.
  -n, --dry-run   Show detected upstream version and computed details without writing.
  -f, --force     Force update even if the package is already at the latest version.
  -h, --help      Display this help message and exit.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--check)
      CHECK_ONLY=true
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

if [[ ! -f "PKGBUILD" ]]; then
  echo "Error: PKGBUILD not found in ${SCRIPT_DIR}" >&2
  exit 1
fi

# Extract repository and tag from PKGBUILD or environment variables
REPO="${UPSTREAM_REPO:-$(grep -E '^_repo=' PKGBUILD | head -n1 | cut -d= -f2- | tr -d "'\"")}"
REPO="${REPO:-NextendoNetwork/citron-nextendo}"
RELEASE_TAG="${UPSTREAM_RELEASE_TAG:-$(grep -E '^_release_tag=' PKGBUILD | head -n1 | cut -d= -f2- | tr -d "'\"")}"
RELEASE_TAG="${RELEASE_TAG:-nightly-linux}"

# Extract current commit and pkgver from PKGBUILD
CURRENT_COMMIT="$(grep -E '^_commit=' PKGBUILD | head -n1 | cut -d= -f2- | tr -d "'\"")"
CURRENT_PKGVER_RAW="$(grep -E '^pkgver=' PKGBUILD | head -n1 | cut -d= -f2- | tr -d "'\"")"
CURRENT_PKGVER="${CURRENT_PKGVER_RAW//\$\{_commit\}/$CURRENT_COMMIT}"
CURRENT_PKGVER="${CURRENT_PKGVER//\$_commit/$CURRENT_COMMIT}"

echo "==> Current PKGBUILD version: ${CURRENT_PKGVER} (commit: ${CURRENT_COMMIT})"
echo "==> Checking upstream: ${REPO} (tag: ${RELEASE_TAG})..."

# Set up GitHub API authentication header if token exists
CURL_AUTH=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  CURL_AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

API_URL="https://api.github.com/repos/${REPO}/releases/tags/${RELEASE_TAG}"
RELEASE_PAYLOAD=$(curl -sSfL "${CURL_AUTH[@]}" -H "Accept: application/vnd.github+json" "${API_URL}" 2>/dev/null || true)

if [[ -z "${RELEASE_PAYLOAD}" ]]; then
  echo "Error: Failed to fetch release information from GitHub API: ${API_URL}" >&2
  exit 1
fi

# Parse release metadata and assets via jq
PARSED_INFO=$(echo "${RELEASE_PAYLOAD}" | jq -r '
  . as $rel |
  # Find x86_64 nopgo asset (or fallback to any x86_64 linux tar.zst)
  ([ $rel.assets[] | select(.name | test("^citron_nightly-[0-9a-f]+-linux-x86_64-use-nopgo\\.tar\\.zst$")) ][0] //
   [ $rel.assets[] | select(.name | test("^citron_nightly-[0-9a-f]+-linux-x86_64.*\\.tar\\.zst$")) ][0]) as $x86 |
  # Find aarch64 nopgo asset (or fallback to any aarch64 linux tar.zst)
  ([ $rel.assets[] | select(.name | test("^citron_nightly-[0-9a-f]+-linux-aarch64-use-nopgo\\.tar\\.zst$")) ][0] //
   [ $rel.assets[] | select(.name | test("^citron_nightly-[0-9a-f]+-linux-aarch64.*\\.tar\\.zst$")) ][0]) as $arm |
  if ($x86 == null or $arm == null) then
    error("Required Linux release assets not found in release payload")
  else
    {
      commit: ($x86.name | capture("citron_nightly-(?<c>[0-9a-f]+)-linux").c),
      date: (($rel.published_at // $rel.created_at // $x86.updated_at)[:10] | gsub("-"; "")),
      x86_name: $x86.name,
      x86_url: $x86.browser_download_url,
      arm_name: $arm.name,
      arm_url: $arm.browser_download_url
    }
  end
')

NEW_COMMIT=$(echo "${PARSED_INFO}" | jq -r '.commit')
NEW_DATE=$(echo "${PARSED_INFO}" | jq -r '.date')
NEW_PKGVER="${NEW_DATE}.r${NEW_COMMIT}"
X86_NAME=$(echo "${PARSED_INFO}" | jq -r '.x86_name')
X86_URL=$(echo "${PARSED_INFO}" | jq -r '.x86_url')
ARM_NAME=$(echo "${PARSED_INFO}" | jq -r '.arm_name')
ARM_URL=$(echo "${PARSED_INFO}" | jq -r '.arm_url')

echo "==> Latest upstream release: ${NEW_PKGVER} (commit: ${NEW_COMMIT})"

# Check if already up to date
if [[ "${CURRENT_COMMIT}" == "${NEW_COMMIT}" && "${FORCE}" != "true" ]]; then
  echo "==> Package is already up to date (${CURRENT_PKGVER}). Nothing to do."
  exit 0
fi

if [[ "${CHECK_ONLY}" == "true" ]]; then
  echo "==> Update available: ${CURRENT_PKGVER} -> ${NEW_PKGVER}"
  exit 1
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "==> [DRY RUN] Would update:"
  echo "    _commit:           ${CURRENT_COMMIT} -> ${NEW_COMMIT}"
  echo "    pkgver:            ${CURRENT_PKGVER} -> ${NEW_PKGVER}"
  echo "    x86_64 asset:      ${X86_NAME}"
  echo "    aarch64 asset:     ${ARM_NAME}"
  exit 0
fi

echo "==> Update detected: ${CURRENT_PKGVER} -> ${NEW_PKGVER}"
echo "==> Downloading and calculating SHA256 for x86_64: ${X86_NAME}..."
SHA256_X86_64=$(curl -sSfL "${CURL_AUTH[@]}" "${X86_URL}" | sha256sum | awk '{print $1}')
if [[ ! "${SHA256_X86_64}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Error: Invalid sha256 calculated for x86_64 asset (${SHA256_X86_64})" >&2
  exit 1
fi
echo "    x86_64 sha256: ${SHA256_X86_64}"

echo "==> Downloading and calculating SHA256 for aarch64: ${ARM_NAME}..."
SHA256_AARCH64=$(curl -sSfL "${CURL_AUTH[@]}" "${ARM_URL}" | sha256sum | awk '{print $1}')
if [[ ! "${SHA256_AARCH64}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Error: Invalid sha256 calculated for aarch64 asset (${SHA256_AARCH64})" >&2
  exit 1
fi
echo "    aarch64 sha256: ${SHA256_AARCH64}"

# Update PKGBUILD
echo "==> Updating PKGBUILD..."
sed -i "s|^_commit=.*|_commit=${NEW_COMMIT}|" PKGBUILD
sed -i "s|^pkgver=.*|pkgver=${NEW_DATE}.r\${_commit}|" PKGBUILD
sed -i "s|^pkgrel=.*|pkgrel=1|" PKGBUILD
sed -i "s|^sha256sums_x86_64=(.*)|sha256sums_x86_64=('${SHA256_X86_64}')|" PKGBUILD
sed -i "s|^sha256sums_aarch64=(.*)|sha256sums_aarch64=('${SHA256_AARCH64}')|" PKGBUILD

# Generate .SRCINFO
echo "==> Regenerating .SRCINFO..."
generate_srcinfo() {
  if [[ $EUID -eq 0 ]]; then
    # makepkg does not permit running directly as root
    if ! id -u builder >/dev/null 2>&1; then
      useradd -m -d /tmp/builder builder 2>/dev/null || true
    fi
    chown -R builder:builder "${SCRIPT_DIR}"
    su builder -c "makepkg --printsrcinfo" > .SRCINFO
  else
    makepkg --printsrcinfo > .SRCINFO
  fi
}
generate_srcinfo

# Verify with namcap if available
if command -v namcap >/dev/null 2>&1; then
  echo "==> Running namcap verification on PKGBUILD..."
  namcap PKGBUILD || true
fi

echo "==> Successfully updated nextendo-citron-bin to ${NEW_PKGVER} (commit: ${NEW_COMMIT})"
