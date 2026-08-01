#!/bin/zsh
# Build the Neon shell and assemble eyes/Neon.app (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=../Neon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp .build/release/NeonShell "$APP/Contents/MacOS/Neon"
cp ../web/index.html "$APP/Contents/Resources/web/index.html"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Neon</string>
  <key>CFBundleDisplayName</key><string>Neon</string>
  <key>CFBundleIdentifier</key><string>com.nickfarina.neon</string>
  <key>CFBundleExecutable</key><string>Neon</string>
  <key>CFBundleVersion</key><string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Neon listens for the wake phrase "Hey Neon".</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Neon uses on-device speech recognition to hear "Hey Neon".</string>
  <key>NSCameraUsageDescription</key>
  <string>Neon can see the kitchen through the camera during conversations.</string>
</dict>
</plist>
EOF

# Sign with a stable identity so TCC grants survive rebuilds; ad-hoc signing
# gives each build a new identity, so macOS resets microphone permission every
# time. "Neon Dev" is the self-signed cert on the kitchen Mac; a machine signed
# into Xcode has an Apple Development cert, which is equally stable and needs
# no setup, so prefer that over falling back to ad-hoc.
IDENTITIES=$(security find-identity -v -p codesigning)
if grep -q "Neon Dev" <<< "$IDENTITIES"; then
  SIGN_ID="Neon Dev"
elif grep -q "Apple Development" <<< "$IDENTITIES"; then
  SIGN_ID=$(grep -o '"Apple Development: [^"]*"' <<< "$IDENTITIES" | head -1 | tr -d '"')
fi

if [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force --sign "$SIGN_ID" "$APP"
  echo "Signed with: $SIGN_ID"
else
  echo "warning: no stable signing identity ('Neon Dev' or Apple Development); ad-hoc signing (mic permission will reset)" >&2
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
