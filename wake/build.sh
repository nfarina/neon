#!/usr/bin/env bash
# Build the linux/arm64 training image with Apple Container.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec container build -t hey-neon-train "$DIR"
