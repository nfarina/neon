#!/usr/bin/env bash
# Shared release configuration. Sourced by eyes/shell/build.sh (to stamp the
# feed into Info.plist) and by the scripts in this directory.
#
# Override anything here by exporting it first. The one value that is a secret
# is the *private* EdDSA key, which never appears in this repo — Sparkle keeps
# it in the login keychain under SPARKLE_KEY_ACCOUNT. The public key below is
# meant to be published; it is what lets every installed copy of Neon verify
# that an update really came from Nick.
#
# First-time setup is in docs/release.md.

# Empty until `tools/release-setup.sh` has been run. build.sh leaves the
# Sparkle keys out of Info.plist while these are blank, and the settings panel
# then reports that this build doesn't do updates — which is the truth, and
# better than a button that can only fail.
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"

SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.1}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.nickfarina.neon}"

# GitHub Pages, served from main/docs. docs/.nojekyll keeps Pages from trying
# to build the implementation notes in that folder into a website — the only
# file there anybody is meant to fetch is appcast.xml.
SPARKLE_SITE_URL="${SPARKLE_SITE_URL:-https://nfarina.github.io/neon}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-${SPARKLE_SITE_URL%/}/appcast.xml}"

SPARKLE_RELEASES_URL="${SPARKLE_RELEASES_URL:-https://github.com/nfarina/neon/releases}"
SPARKLE_RELEASE_DOWNLOAD_BASE_URL="${SPARKLE_RELEASE_DOWNLOAD_BASE_URL:-https://github.com/nfarina/neon/releases/download}"

SPARKLE_TOOLS_REPO="${SPARKLE_TOOLS_REPO:-sparkle-project/Sparkle}"
SPARKLE_TOOLS_ARCHIVE="${SPARKLE_TOOLS_ARCHIVE:-Sparkle-${SPARKLE_VERSION}.tar.xz}"
SPARKLE_TOOLS_CACHE_DIR="${SPARKLE_TOOLS_CACHE_DIR:-build/sparkle-tools/${SPARKLE_VERSION}}"

# Notarization. `xcrun notarytool store-credentials neon-notary` once, then
# this profile name is all the scripts need.
NOTARY_PROFILE="${NOTARY_PROFILE:-neon-notary}"
