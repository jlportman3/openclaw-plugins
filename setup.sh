#!/usr/bin/env bash
set -euo pipefail

# Show exactly where the script dies
trap 'echo ""; echo "FATAL: setup.sh died at line $LINENO (exit code $?)" >&2' ERR

# Set CLI_GATEWAY_DEBUG=1 to trace every command
if [ "${CLI_GATEWAY_DEBUG:-}" = "1" ]; then
    set -x
fi

# ============================================================
# cli-gateway Production Setup
# Interactive installer for Ubuntu 22.04+
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/cli-gateway"
GATEWAY_PORT=4090
MIN_NODE_MAJOR=22

# --- Colors & UI ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; exit 1; }
info() { echo -e "  ${CYAN}ℹ${NC} $1"; }
step() { echo -e "\n${BOLD}${CYAN}==> $1${NC}"; }

# Track what we selected
INSTALL_CLAUDE=false
INSTALL_CODEX=false
INSTALL_GEMINI=false

# ============================================================
# Phase 1: OS Detection
# ============================================================
detect_os() {
    step "Phase 1: Detecting operating system"

    if [[ ! -f /etc/os-release ]]; then
        fail "Cannot detect OS. /etc/os-release not found."
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
        fail "Unsupported OS: ${ID:-unknown}. This installer requires Ubuntu or Debian."
    fi

    if [[ "${ID:-}" == "ubuntu" ]]; then
        local ver="${VERSION_ID%%.*}"
        if [[ "$ver" -lt 22 ]]; then
            fail "Ubuntu 22.04 or higher required (found ${VERSION_ID})"
        fi
    fi

    ok "OS: ${PRETTY_NAME:-$ID}"
}

# ============================================================
# Phase 2: System Dependencies
# ============================================================
install_system_deps() {
    step "Phase 2: Installing system dependencies"

    local -a required_pkgs=(
        build-essential    # gcc/g++/make — node-pty native compilation (node-gyp)
        python3            # Required by node-gyp for native module builds
        curl               # NodeSource install script, health checks
        git                # Clone OpenClaw repository
        lsof               # Port conflict detection
        xdg-utils          # xdg-open — browser launch for CLI OAuth flows
        ca-certificates    # HTTPS certificate trust for npm registry + NodeSource
    )

    # CLI tools use xdg-open for OAuth — need a real browser
    if ! command -v xdg-open &>/dev/null || ! xdg-settings get default-web-browser &>/dev/null 2>&1; then
        info "No browser detected — installing Firefox for OAuth flows"
        required_pkgs+=(firefox)
    fi

    local -a missing=()
    for pkg in "${required_pkgs[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing missing packages: ${missing[*]}"
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    fi

    ok "System dependencies: build-essential, python3, curl, git, lsof, xdg-utils, ca-certificates"
}

# ============================================================
# Phase 3: Node.js 22+
# ============================================================
install_nodejs() {
    step "Phase 3: Checking Node.js"

    if command -v node &>/dev/null; then
        local ver
        ver=$(node -v | tr -d 'v' | cut -d. -f1)
        if [[ "$ver" -ge "$MIN_NODE_MAJOR" ]]; then
            ok "Node.js $(node -v) already installed"
            return
        fi
        warn "Node.js $(node -v) is too old (need ${MIN_NODE_MAJOR}+), upgrading..."
    else
        info "Node.js not found, installing..."
    fi

    info "Installing Node.js ${MIN_NODE_MAJOR} via NodeSource..."
    curl -fsSL "https://deb.nodesource.com/setup_${MIN_NODE_MAJOR}.x" | sudo -E bash -
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs

    ok "Node.js $(node -v) installed"
}

# ============================================================
# Phase 4: pnpm (for OpenClaw build)
# ============================================================
install_pnpm() {
    step "Phase 4: Checking pnpm"

    if command -v pnpm &>/dev/null; then
        ok "pnpm $(pnpm --version) already installed"
        return
    fi

    info "Installing pnpm..."
    sudo npm install -g pnpm
    ok "pnpm $(pnpm --version) installed"
}

# ============================================================
# Phase 5: Backend Selection Menu
# ============================================================
select_backends() {
    step "Phase 5: Select CLI backends"

    echo ""
    echo "  Choose which AI CLI tools to install and configure."
    echo "  Each requires a subscription and browser-based login."
    echo ""

    # Show install status
    local cs="" xs="" gs=""
    command -v claude &>/dev/null && cs=" ${GREEN}(installed)${NC}"
    command -v codex  &>/dev/null && xs=" ${GREEN}(installed)${NC}"
    command -v gemini &>/dev/null && gs=" ${GREEN}(installed)${NC}"

    echo -e "  ${BOLD}1)${NC} Claude Code  — Anthropic (claude)${cs}"
    echo -e "  ${BOLD}2)${NC} Codex CLI    — OpenAI   (codex)${xs}"
    echo -e "  ${BOLD}3)${NC} Gemini CLI   — Google   (gemini)${gs}"
    echo ""
    echo "  Enter numbers separated by spaces (e.g. '1 2 3' for all)."
    echo -n "  Selection [1]: "

    local input
    read -r input
    input="${input:-1}"

    for num in $input; do
        case "$num" in
            1) INSTALL_CLAUDE=true ;;
            2) INSTALL_CODEX=true  ;;
            3) INSTALL_GEMINI=true ;;
            *) warn "Unknown option '$num', skipping" ;;
        esac
    done

    if ! $INSTALL_CLAUDE && ! $INSTALL_CODEX && ! $INSTALL_GEMINI; then
        fail "At least one backend must be selected."
    fi

    echo ""
    if $INSTALL_CLAUDE; then ok "Selected: Claude Code"; fi
    if $INSTALL_CODEX;  then ok "Selected: Codex CLI";  fi
    if $INSTALL_GEMINI; then ok "Selected: Gemini CLI"; fi
}

# ============================================================
# Phase 6: Install Selected CLI Tools
# ============================================================
install_cli_tools() {
    step "Phase 6: Installing CLI tools"

    if $INSTALL_CLAUDE; then
        if command -v claude &>/dev/null; then
            ok "Claude Code already installed ($(claude --version 2>/dev/null | head -1))"
        else
            info "Installing Claude Code — this may take a few minutes..."
            sudo npm install -g @anthropic-ai/claude-code --loglevel notice
            ok "Claude Code installed"
        fi
    fi

    if $INSTALL_CODEX; then
        if command -v codex &>/dev/null; then
            ok "Codex CLI already installed"
        else
            info "Installing Codex CLI..."
            sudo npm install -g @openai/codex --loglevel notice
            ok "Codex CLI installed"
        fi
    fi

    if $INSTALL_GEMINI; then
        if command -v gemini &>/dev/null; then
            ok "Gemini CLI already installed"
        else
            info "Installing Gemini CLI..."
            sudo npm install -g @google/gemini-cli --loglevel notice
            ok "Gemini CLI installed"
        fi
    fi
}

# ============================================================
# Phase 7: Authenticate CLI Tools
# ============================================================
authenticate_backends() {
    step "Phase 7: Authenticating CLI tools"

    echo ""
    echo "  Each tool needs a one-time browser login via xdg-open."
    echo "  A browser window will open for each selected tool."
    echo ""

    # --- Claude Code ---
    if $INSTALL_CLAUDE; then
        echo -e "  ${BOLD}--- Claude Code ---${NC}"
        if claude -p --output-format json "ping" &>/dev/null 2>&1; then
            ok "Claude Code: already authenticated"
        else
            echo ""
            echo "  Claude Code requires interactive login."
            echo "  A browser will open. Log in with your Anthropic account."
            echo "  After logging in, type /exit to return here."
            echo ""
            echo -n "  Press Enter to launch Claude Code..."
            read -r
            echo ""
            claude || true
            echo ""
            if claude -p --output-format json "ping" &>/dev/null 2>&1; then
                ok "Claude Code: authentication verified"
            else
                warn "Claude Code: could not verify authentication"
                warn "  Retry later with: claude"
            fi
        fi
    fi

    # --- Codex CLI ---
    if $INSTALL_CODEX; then
        echo -e "  ${BOLD}--- Codex CLI ---${NC}"
        if codex login status 2>&1 | grep -qi "logged in"; then
            ok "Codex CLI: already authenticated"
        else
            echo ""
            echo "  Codex CLI requires browser login."
            echo "  A browser will open. Log in with your OpenAI account."
            echo ""
            echo -n "  Press Enter to launch Codex login..."
            read -r
            echo ""
            codex login || true
            echo ""
            if codex login status 2>&1 | grep -qi "logged in"; then
                ok "Codex CLI: authentication verified"
            else
                warn "Codex CLI: could not verify authentication"
                warn "  Retry later with: codex login"
            fi
        fi
    fi

    # --- Gemini CLI ---
    if $INSTALL_GEMINI; then
        echo -e "  ${BOLD}--- Gemini CLI ---${NC}"
        if [[ -f "$HOME/.gemini/oauth_creds.json" ]]; then
            ok "Gemini CLI: already authenticated"
        else
            echo ""
            echo "  Gemini CLI requires browser login."
            echo "  A browser will open. Log in with your Google account."
            echo "  After logging in, type /quit to return here."
            echo ""
            echo -n "  Press Enter to launch Gemini CLI..."
            read -r
            echo ""
            gemini || true
            echo ""
            if [[ -f "$HOME/.gemini/oauth_creds.json" ]]; then
                ok "Gemini CLI: authentication verified"
            else
                warn "Gemini CLI: could not verify authentication"
                warn "  Retry later with: gemini"
            fi
        fi
    fi
}

# ============================================================
# Phase 8: Deploy via Makefile
# ============================================================
deploy_service() {
    step "Phase 8: Deploying cli-gateway service"

    sudo make -C "$SCRIPT_DIR" install \
        INSTALL_USER="$(whoami)" \
        INSTALL_USER_HOME="$HOME" \
        INSTALL_CLAUDE="$INSTALL_CLAUDE" \
        INSTALL_CODEX="$INSTALL_CODEX" \
        INSTALL_GEMINI="$INSTALL_GEMINI"
}

# ============================================================
# Summary
# ============================================================
show_summary() {
    step "Setup Complete!"
    echo ""
    echo "  cli-gateway is running as a systemd service on port ${GATEWAY_PORT}."
    echo ""
    echo "  ${BOLD}Service management:${NC}"
    echo "    make -C ${SCRIPT_DIR} status     # service status + health check"
    echo "    make -C ${SCRIPT_DIR} logs       # follow service logs"
    echo "    make -C ${SCRIPT_DIR} restart    # restart the service"
    echo "    make -C ${SCRIPT_DIR} test       # run smoke tests"
    echo ""
    echo "  ${BOLD}Install OpenClaw (optional):${NC}"
    echo "    make -C ${SCRIPT_DIR} openclaw-install"
    echo "    make -C ${SCRIPT_DIR} openclaw-start"
    echo ""
    echo "  ${BOLD}Quick test:${NC}"
    echo "    curl http://localhost:${GATEWAY_PORT}/health"
    echo ""
}

# ============================================================
# Main
# ============================================================
main() {
    echo ""
    echo -e "${BOLD}=============================================${NC}"
    echo -e "${BOLD}  cli-gateway Production Setup${NC}"
    echo -e "${BOLD}  Ubuntu 22.04+ | systemd service${NC}"
    echo -e "${BOLD}=============================================${NC}"

    detect_os
    install_system_deps
    install_nodejs
    install_pnpm
    select_backends
    install_cli_tools
    authenticate_backends
    deploy_service
    show_summary
}

main "$@"
