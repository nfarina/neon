#!/usr/bin/env bash
set -euo pipefail

# One-time setup for publishing updates. Run once, ever, on the machine that
# will cut releases.
#
# Generates the EdDSA key pair Sparkle uses to sign updates. The private half
# goes into the login keychain and must never leave it — losing it means no
# existing installation will accept another update, and there is no recovery
# beyond asking everyone to download a fresh copy. The public half is printed
# and belongs in tools/sparkle-config.sh, committed, published, harmless.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/sparkle-config.sh"

TOOLS_DIR="$("${SCRIPT_DIR}/sparkle-tools.sh")"

if [ -n "${SPARKLE_PUBLIC_KEY}" ]; then
  echo "sparkle-config.sh already has a public key:"
  echo "  ${SPARKLE_PUBLIC_KEY}"
  echo
  echo "Generating another would orphan every installed copy. Nothing to do."
  exit 0
fi

echo "Generating a signing key for account '${SPARKLE_KEY_ACCOUNT}'…"
echo
"${TOOLS_DIR}/bin/generate_keys" --account "${SPARKLE_KEY_ACCOUNT}"

echo
echo "Next:"
echo "  1. Copy the public key printed above into tools/sparkle-config.sh"
echo "     as SPARKLE_PUBLIC_KEY, and commit it."
echo "  2. Store a notarization credential once:"
echo "       xcrun notarytool store-credentials ${NOTARY_PROFILE} \\"
echo "         --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>"
echo "  3. On GitHub: Settings › Pages › Deploy from branch › main /docs."
echo "  4. Cut a release:  tools/release.sh 0.3"
