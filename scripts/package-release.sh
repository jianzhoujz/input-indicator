#!/usr/bin/env bash
# Package and release script for input-indicator
# Usage: ./scripts/package-release.sh <version>
#
# This script:
#   1. Builds DMG packages for doubao and wetype variants
#   2. Updates Casks in the homebrew tap with new version + sha256
#
# Run from the input-indicator project root.

set -euo pipefail

VERSION="${1:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TAP_ROOT="$(cd "${PROJECT_ROOT}/../homebrew-tap" 2>/dev/null && pwd || echo '')"
DIST_DIR="${PROJECT_ROOT}/dist"

# Validate
if [[ -z "${TAP_ROOT}" ]]; then
    echo "Error: homebrew tap not found at ../homebrew-tap"
    exit 1
fi

DOUBAO_CASK="${TAP_ROOT}/Casks/doubao-input-indicator.rb"
WETYPE_CASK="${TAP_ROOT}/Casks/wetype-input-indicator.rb"

if [[ ! -f "${DOUBAO_CASK}" || ! -f "${WETYPE_CASK}" ]]; then
    echo "Error: Cask files not found in ${TAP_ROOT}/Casks/"
    exit 1
fi

cd "${PROJECT_ROOT}"

rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

APP_VERSION="${VERSION}" APP_BUILD="${VERSION}" ./package-dmg.sh doubao >/dev/null
APP_VERSION="${VERSION}" APP_BUILD="${VERSION}" ./package-dmg.sh wetype >/dev/null

DOUBAO_DMG="${DIST_DIR}/DoubaoInputIndicator-${VERSION}.dmg"
WETYPE_DMG="${DIST_DIR}/WeTypeInputIndicator-${VERSION}.dmg"
DOUBAO_SHA="$(shasum -a 256 "${DOUBAO_DMG}" | awk '{print $1}')"
WETYPE_SHA="$(shasum -a 256 "${WETYPE_DMG}" | awk '{print $1}')"

export TAP_ROOT VERSION DOUBAO_SHA WETYPE_SHA

ruby <<'RUBY'
replacements = {
  "Casks/doubao-input-indicator.rb" => ENV.fetch("DOUBAO_SHA"),
  "Casks/wetype-input-indicator.rb" => ENV.fetch("WETYPE_SHA"),
}

replacements.each do |relative_path, sha|
  path = File.join(ENV.fetch("TAP_ROOT"), relative_path)
  contents = File.read(path)
  contents = contents.sub(/version "[^"]+"/, %(version "#{ENV.fetch("VERSION")}"))
  contents = contents.sub(/sha256 "[0-9a-f]{64}"/, %(sha256 "#{sha}"))
  contents = contents.sub(/InputIndicator-\#\{version\}\.zip/, 'InputIndicator-#{version}.dmg')
  File.write(path, contents)
end
RUBY

printf '%s  %s\n' "${DOUBAO_SHA}" "${DOUBAO_DMG}"
printf '%s  %s\n' "${WETYPE_SHA}" "${WETYPE_DMG}"
printf '\nUpdated casks in %s\n' "${TAP_ROOT}"

cat <<EOF

Upload with:
gh release create v${VERSION} \\
  "${DOUBAO_DMG}" \\
  "${WETYPE_DMG}" \\
  --repo jianzhoujz/input-indicator \\
  --title v${VERSION}
EOF
