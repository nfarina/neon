#!/usr/bin/env bash
set -euo pipefail

# Cut a release, end to end:
#
#   tools/release.sh 0.3 [--notes notes.md]
#
#   1. stamp eyes/VERSION and build with --release (hardened runtime,
#      Developer ID, Sparkle's nested components re-signed)
#   2. zip it, notarize, staple the ticket
#   3. tag, create the GitHub release, attach the zip
#   4. regenerate docs/appcast.xml with an EdDSA signature and push it
#
# Everything it needs is set up by tools/release-setup.sh. Any step can be run
# on its own if something goes wrong halfway — this script is a sequence, not a
# state machine.

if [ $# -lt 1 ]; then
  echo "Usage: $0 <version> [--notes path/to/notes.md]" >&2
  exit 1
fi

VERSION="${1#v}"
shift || true
NOTES_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) [[ -n "${2:-}" ]] || { echo "--notes needs a path" >&2; exit 1; }
             NOTES_FILE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/sparkle-config.sh"
cd "${SCRIPT_DIR}/.."

if [ -z "${SPARKLE_PUBLIC_KEY}" ]; then
  echo "No SPARKLE_PUBLIC_KEY in tools/sparkle-config.sh — run tools/release-setup.sh first." >&2
  exit 1
fi
command -v gh >/dev/null 2>&1 || { echo "gh CLI required. brew install gh" >&2; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit or stash before releasing." >&2
  exit 1
fi

TAG="v${VERSION}"
ZIP="dist/Neon-${VERSION}-macos.zip"
APP="eyes/Neon.app"

# ------------------------------------------------------------------ 1. build
echo "==> Building ${VERSION}"
echo "${VERSION}" > eyes/VERSION
# Committed before the build so the commit count baked into CFBundleVersion
# matches the commit the release is actually cut from.
git add eyes/VERSION
git commit -m "Neon ${VERSION}" --allow-empty >/dev/null
eyes/shell/build.sh --release

# ------------------------------------------------- 2. notarize and staple
echo "==> Packaging"
mkdir -p dist
rm -f "${ZIP}"
# ditto -c -k --keepParent: the archive format notarytool expects, and the one
# that preserves the symlinks inside Sparkle.framework.
ditto -c -k --keepParent "${APP}" "${ZIP}"

echo "==> Notarizing (this takes a few minutes)"
xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait

echo "==> Stapling"
xcrun stapler staple "${APP}"
# Re-zip: the ticket is stapled into the .app, so the archive people download
# has to be made again afterwards or it arrives unstapled and Gatekeeper has to
# phone home to launch it.
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"
xcrun stapler validate "${APP}"

# --------------------------------------------------------- 3. GitHub release
echo "==> Publishing ${TAG}"
git tag -a "${TAG}" -m "Neon ${VERSION}"
git push origin HEAD --tags

GH_ARGS=(release create "${TAG}" "${ZIP}" --title "Neon ${VERSION}")
if [ -n "${NOTES_FILE}" ]; then
  [ -f "${NOTES_FILE}" ] || { echo "Notes file not found: ${NOTES_FILE}" >&2; exit 1; }
  GH_ARGS+=(--notes-file "${NOTES_FILE}")
else
  GH_ARGS+=(--generate-notes)
fi
gh "${GH_ARGS[@]}"

# ---------------------------------------------------------------- 4. appcast
echo "==> Updating the appcast"
TOOLS_DIR="$("${SCRIPT_DIR}/sparkle-tools.sh")"
STAGING="$(mktemp -d -t neon-appcast)"
trap 'rm -rf "${STAGING}"' EXIT

cp "${ZIP}" "${STAGING}/"
# generate_appcast looks for <zipname>.md/.html beside each archive and embeds
# it as the release notes shown in Sparkle's update window.
[ -n "${NOTES_FILE}" ] && cp "${NOTES_FILE}" "${STAGING}/Neon-${VERSION}-macos.md"
# Seed with the current feed so previous entries survive the regeneration.
[ -f docs/appcast.xml ] && cp docs/appcast.xml "${STAGING}/appcast.xml"

"${TOOLS_DIR}/bin/generate_appcast" \
  "${STAGING}" \
  --account "${SPARKLE_KEY_ACCOUNT}" \
  --download-url-prefix "${SPARKLE_RELEASE_DOWNLOAD_BASE_URL}/${TAG}/" \
  --link "${SPARKLE_SITE_URL}" \
  --full-release-notes-url "${SPARKLE_RELEASES_URL}/tag/${TAG}" \
  --embed-release-notes \
  --maximum-deltas 0

cp "${STAGING}/appcast.xml" docs/appcast.xml
grep -q 'sparkle:edSignature' docs/appcast.xml || {
  echo "appcast has no EdDSA signature — is the private key in the keychain under '${SPARKLE_KEY_ACCOUNT}'?" >&2
  exit 1
}
touch docs/.nojekyll
git add docs/appcast.xml docs/.nojekyll
git commit -m "Appcast for ${VERSION}" >/dev/null
git push origin HEAD

echo
echo "Released ${VERSION}."
echo "  download: ${SPARKLE_RELEASES_URL}/tag/${TAG}"
echo "  feed:     ${SPARKLE_FEED_URL}"
