#!/bin/zsh
# Build the development shell and install it over the running /Applications
# copy — the loop riot's "deploy" task drives.
#
# Quit, replace, relaunch, in that order: replacing the bundle while it's
# still running would let it keep executing the old binary until the next
# restart anyway, so there is no gain in skipping the quit. Safe to run
# whether or not Neon is currently up.
set -euo pipefail
cd "$(dirname "$0")"

shell/build.sh

TARGET=/Applications/Neon.app

if pgrep -f "$TARGET/Contents/MacOS/Neon" >/dev/null; then
  pkill -f "$TARGET/Contents/MacOS/Neon"
  # Give it a moment to actually exit before we start overwriting its bundle.
  for _ in $(seq 1 20); do
    pgrep -f "$TARGET/Contents/MacOS/Neon" >/dev/null || break
    sleep 0.5
  done
fi

rm -rf "$TARGET"
# ditto, not cp -R: Sparkle.framework inside is a tree of symlinks into
# Versions/, and cp -R silently flattens them into copies, which breaks the
# framework's own signature (same reason build.sh uses ditto to embed it).
ditto Neon.app "$TARGET"

open "$TARGET"
echo "Installed and relaunched $TARGET"
