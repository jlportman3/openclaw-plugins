#!/usr/bin/env bash
set -euo pipefail
# Bootstrap: clone repo, configure sudoers, run interactive setup.
# Usage: curl -fsSL https://raw.githubusercontent.com/jlportman3/openclaw-plugins/main/install.sh | sudo bash

REPO="https://github.com/jlportman3/openclaw-plugins.git"

echo ""
echo "==> cli-gateway bootstrap"

# --- Must run as root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "  Error: This script must be run as root."
    echo "  Usage: curl -fsSL https://raw.githubusercontent.com/jlportman3/openclaw-plugins/main/install.sh | sudo bash"
    exit 1
fi

# --- Resolve the real user (not root) ---
TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "  Error: Run via sudo so we can detect your username."
    echo "  Usage: curl ... | sudo bash"
    exit 1
fi
TARGET_HOME="$(eval echo ~"$TARGET_USER")"
DEST="${TARGET_HOME}/openclaw-plugins"

echo "  User: $TARGET_USER"
echo "  Home: $TARGET_HOME"

# --- Passwordless sudo ---
SUDOERS_FILE="/etc/sudoers.d/${TARGET_USER}"
if [ -f "$SUDOERS_FILE" ]; then
    echo "  Sudoers entry already exists: $SUDOERS_FILE"
else
    echo "  Configuring passwordless sudo for $TARGET_USER"
    echo "${TARGET_USER} ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    # Validate — remove if broken
    if ! visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
        rm -f "$SUDOERS_FILE"
        echo "  Error: sudoers validation failed. Removed $SUDOERS_FILE."
        exit 1
    fi
fi
echo "  ✓ Passwordless sudo configured"

# --- Minimal deps to clone ---
if ! command -v git &>/dev/null || ! command -v curl &>/dev/null; then
    echo "  Installing git and curl..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl
fi

# --- Clone or update (as the user, not root) ---
if [ -d "$DEST/.git" ]; then
    echo "  Updating existing clone at $DEST"
    sudo -u "$TARGET_USER" git -C "$DEST" pull --ff-only
else
    echo "  Cloning to $DEST"
    sudo -u "$TARGET_USER" git clone "$REPO" "$DEST"
fi

# --- Hand off to setup.sh as the user ---
echo "  Launching setup.sh as $TARGET_USER..."
echo ""
exec su - "$TARGET_USER" -c "$DEST/setup.sh" </dev/tty >/dev/tty 2>&1
