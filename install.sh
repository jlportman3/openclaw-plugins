#!/usr/bin/env bash
set -euo pipefail
# Bootstrap: clone repo and run interactive setup.
# Usage: curl -fsSL https://raw.githubusercontent.com/jlportman3/openclaw-plugins/main/install.sh | bash

REPO="https://github.com/jlportman3/openclaw-plugins.git"
DEST="${HOME}/openclaw-plugins"

echo "==> cli-gateway bootstrap"

# Minimal deps to clone
if ! command -v git &>/dev/null || ! command -v curl &>/dev/null; then
    echo "  Installing git and curl..."
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl
fi

# Clone or update
if [ -d "$DEST/.git" ]; then
    echo "  Updating existing clone at $DEST"
    git -C "$DEST" pull --ff-only
else
    echo "  Cloning to $DEST"
    git clone "$REPO" "$DEST"
fi

# Hand off to interactive setup
echo "  Launching setup.sh..."
echo ""
exec "$DEST/setup.sh" </dev/tty
