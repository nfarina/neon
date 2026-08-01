#!/bin/zsh
# Rebuild Neon.app and restart it — the whole edit/see-it loop in one command.
# Both the Swift shell and web/index.html are baked into the bundle, so any
# change to either needs this, not just a relaunch.
set -euo pipefail
cd "$(dirname "$0")"

shell/build.sh

# Quit a running copy first; the bundle it's executing is about to be replaced.
pkill -f "Neon.app/Contents/MacOS/Neon" 2>/dev/null || true
sleep 1
open -a "$PWD/Neon.app"
echo "Neon restarted"
