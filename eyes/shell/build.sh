#!/bin/zsh
# Build the Neo shell and assemble eyes/Neo.app (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=../Neo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp .build/release/NeoShell "$APP/Contents/MacOS/Neo"
cp ../web/index.html "$APP/Contents/Resources/web/index.html"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Neo</string>
  <key>CFBundleDisplayName</key><string>Neo</string>
  <key>CFBundleIdentifier</key><string>com.nickfarina.neo</string>
  <key>CFBundleExecutable</key><string>Neo</string>
  <key>CFBundleVersion</key><string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Neo listens for the wake phrase "Hey Neo".</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Neo uses on-device speech recognition to hear "Hey Neo".</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"
