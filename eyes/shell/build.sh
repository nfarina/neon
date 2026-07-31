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
</dict>
</plist>
EOF

# Sign with the stable "Neon Dev" certificate so TCC grants survive rebuilds;
# ad-hoc signing resets microphone permission on every build.
if security find-identity -v -p codesigning | grep -q "Neon Dev"; then
  codesign --force --sign "Neon Dev" "$APP"
else
  echo "warning: 'Neon Dev' identity not found; ad-hoc signing (mic permission will reset)" >&2
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
