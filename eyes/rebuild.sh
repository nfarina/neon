#!/bin/zsh
# Rebuild Neon.app.
#
#   ./eyes/rebuild.sh          build only — leaves whatever is running alone
#   ./eyes/rebuild.sh --run    build, then restart Neon
#
# Build-only is the default because relaunching steals focus: Neon activates
# itself and takes over the screen on launch, which is exactly wrong while
# someone is working on something else. Anyone who wants the new build running
# can say so, or press the quit chord and reopen it themselves.
#
# Both the Swift shell and web/index.html are baked into the bundle, so any
# change to either needs this, not just a relaunch.
set -euo pipefail
cd "$(dirname "$0")"

shell/build.sh

RUN=0
[[ "${1:-}" == "--run" || "${1:-}" == "--restart" ]] && RUN=1

if (( RUN )); then
    pkill -f "Neon.app/Contents/MacOS/Neon" 2>/dev/null || true
    sleep 1
    open -a "$PWD/Neon.app"
    echo "Neon restarted"
elif pgrep -f "Neon.app/Contents/MacOS/Neon" >/dev/null; then
    echo "Neon is still running the previous build."
    echo "  restart when you're ready:  ./eyes/rebuild.sh --run"
fi
