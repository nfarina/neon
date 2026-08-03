#!/bin/zsh
# Build the Neon shell and assemble eyes/Neon.app (no Xcode required).
#
#   shell/build.sh              development build, signed with a local identity
#   shell/build.sh --release    hardened runtime + Developer ID, ready to notarize
#
# The development path is what runs in the kitchen and what you want almost
# always. --release exists for tools/release.sh and asks for things a kitchen
# build has no use for: a Developer ID certificate, the hardened runtime, and
# the entitlements that go with it.
set -euo pipefail
cd "$(dirname "$0")"

RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1

# Version, in one place. CFBundleVersion has to increase forever for Sparkle to
# recognise a newer build, and the commit count does that on its own — no file
# to remember to bump, no way for two releases to claim the same number.
VERSION="${NEON_VERSION:-$(cat ../VERSION 2>/dev/null || echo 0.1)}"
BUILD="${NEON_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# Sparkle's feed lives here when the project has been set up to publish. Absent
# (a fresh clone, anyone building from source), the keys are left out of the
# Info.plist entirely and the settings panel reports that this build doesn't do
# updates — better than a Check for Updates button that can only fail.
SPARKLE_FEED_URL=""
SPARKLE_PUBLIC_KEY=""
[[ -f ../../tools/sparkle-config.sh ]] && source ../../tools/sparkle-config.sh

swift build -c release

APP=../Neon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web" "$APP/Contents/Frameworks"
cp .build/release/NeonShell "$APP/Contents/MacOS/Neon"
cp ../web/index.html "$APP/Contents/Resources/web/index.html"
# Seed for ~/Code/neon-agent/CLAUDE.md, written on the first task and owned by
# the agent afterwards. Only reachable with the tasks plugin switched on.
cp ../../agent/CLAUDE.md "$APP/Contents/Resources/agent-CLAUDE.md"

# Wake models ship in the bundle — see wake/README.md. Only .onnx: the .tflite
# export exists for other runtimes, and ONNX Runtime is what the shell loads.
mkdir -p "$APP/Contents/Resources/oww"
cp ../../wake/models/*.onnx "$APP/Contents/Resources/oww/"

# Sparkle is the one dynamic dependency (onnxruntime links statically), so it
# has to travel inside the bundle. ditto rather than cp: a framework is a tree
# of symlinks into Versions/, and flattening them breaks the signature.
SPARKLE_SRC=$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' | head -1)
if [[ -z "$SPARKLE_SRC" ]]; then
  echo "error: Sparkle.framework not found under .build/artifacts — run swift build first" >&2
  exit 1
fi
ditto "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Neon</string>
  <key>CFBundleDisplayName</key><string>Neon</string>
  <key>CFBundleIdentifier</key><string>com.nickfarina.neon</string>
  <key>CFBundleExecutable</key><string>Neon</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Neon listens for the wake phrase "Hey Neon".</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Neon uses on-device speech recognition to hear "Hey Neon".</string>
  <key>NSCameraUsageDescription</key>
  <string>Neon can see the kitchen through the camera during conversations.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Neon uses your location for local answers like weather and sunset times.</string>
  <!-- macOS honours the plain key; the WhenInUse one alone can leave the
       authorization prompt un-raised. Ship both. -->
  <key>NSLocationUsageDescription</key>
  <string>Neon uses your location for local answers like weather and sunset times.</string>
  <!-- Reading the household's calendars (CalendarBridge.swift), asked for by
       the Calendar plugin when somebody switches it on in settings. Both keys
       for the same reason as location: 14+ wants the FullAccess one, the plain
       key is what older releases look for. Read-only — there is no write path
       in the code. -->
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Neon reads the family calendars to answer questions about the day.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Neon reads the family calendars to answer questions about the day.</string>
$(if [[ -n "$SPARKLE_FEED_URL" && -n "$SPARKLE_PUBLIC_KEY" ]]; then cat <<PLIST
  <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableInstallerLauncherService</key><false/>
PLIST
fi)
</dict>
</plist>
EOF

# Sign with a stable identity so TCC grants survive rebuilds; ad-hoc signing
# gives each build a new identity, so macOS resets microphone permission every
# time. "Neon Dev" is the self-signed cert on the kitchen Mac; a machine signed
# into Xcode has an Apple Development cert, which is equally stable and needs
# no setup, so prefer that over falling back to ad-hoc.
IDENTITIES=$(security find-identity -v -p codesigning)
if (( RELEASE )); then
  SIGN_ID="${NEON_SIGNING_IDENTITY:-$(grep -o '"Developer ID Application: [^"]*"' <<< "$IDENTITIES" | head -1 | tr -d '"')}"
  if [[ -z "$SIGN_ID" ]]; then
    echo "error: --release needs a Developer ID Application certificate" >&2
    exit 1
  fi
  # Hardened runtime is required for notarization, and with it the resource
  # entitlements stop being optional: without them macOS denies the microphone
  # and camera outright rather than asking. Development builds deliberately
  # skip all of this — the kitchen Mac's grants are already in place and
  # changing how it is signed would reset them.
  ENTITLEMENTS=$(mktemp -t neon-entitlements).plist
  cat > "$ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.device.camera</key><true/>
  <key>com.apple.security.personal-information.location</key><true/>
  <key>com.apple.security.personal-information.calendars</key><true/>
</dict>
</plist>
EOF
  SIGN_FLAGS=(--options runtime --timestamp)
  APP_SIGN_FLAGS=("${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS")
elif grep -q "Neon Dev" <<< "$IDENTITIES"; then
  SIGN_ID="Neon Dev"
  SIGN_FLAGS=()
  APP_SIGN_FLAGS=()
elif grep -q "Apple Development" <<< "$IDENTITIES"; then
  SIGN_ID=$(grep -o '"Apple Development: [^"]*"' <<< "$IDENTITIES" | head -1 | tr -d '"')
  SIGN_FLAGS=()
  APP_SIGN_FLAGS=()
else
  echo "warning: no stable signing identity ('Neon Dev' or Apple Development); ad-hoc signing (mic permission will reset)" >&2
  SIGN_ID="-"
  SIGN_FLAGS=()
  APP_SIGN_FLAGS=()
fi

# Sparkle ships signed by the Sparkle project. Re-signing the app with a
# different identity leaves those nested signatures mismatched, so they are
# replaced too — inside out, because each enclosing bundle's signature has to
# cover the inner ones as they finally are.
FW="$APP/Contents/Frameworks/Sparkle.framework"
FWV="$FW/Versions/B"
for nested in \
    "$FWV/Autoupdate" \
    "$FWV/XPCServices/Downloader.xpc" \
    "$FWV/XPCServices/Installer.xpc" \
    "$FWV/Updater.app" \
    "$FWV" "$FW"; do
  [[ -e "$nested" ]] || continue
  codesign --force ${SIGN_FLAGS[@]:-} --sign "$SIGN_ID" "$nested" >/dev/null
done

codesign --force ${APP_SIGN_FLAGS[@]:-} --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP — ${VERSION} (build ${BUILD}), signed with: $SIGN_ID"
if (( RELEASE )); then
  rm -f "$ENTITLEMENTS"
  echo "Hardened runtime on; ready for notarization."
fi
