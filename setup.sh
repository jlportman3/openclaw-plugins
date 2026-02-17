#!/usr/bin/env bash
set -euo pipefail

GATEWAY_PORT=4090
OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
OPENCLAW_REPO="https://github.com/nicobailon/openclaw.git"

echo "============================================="
echo "  OpenClaw + cli-gateway Bootstrap"
echo "============================================="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[!!]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}--- $1 ---${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# Phase 1: Prerequisites
# ============================================================
step "Phase 1: Checking prerequisites"

# Node.js 22+
if ! command -v node &>/dev/null; then
  fail "Node.js not found. Install Node.js 22+ first: https://nodejs.org"
fi
NODE_MAJOR=$(node -v | cut -d. -f1 | tr -d v)
if [ "$NODE_MAJOR" -lt 22 ]; then
  fail "Node.js 22+ required (found $(node -v))"
fi
ok "Node.js $(node -v)"

# pnpm (for OpenClaw build)
if ! command -v pnpm &>/dev/null; then
  warn "pnpm not found. Installing..."
  npm install -g pnpm
fi
ok "pnpm $(pnpm --version)"

# Claude Code
if ! command -v claude &>/dev/null; then
  warn "Claude Code not found. Installing..."
  npm install -g @anthropic-ai/claude-code
fi
ok "Claude Code $(claude --version 2>/dev/null | head -1)"

# Claude Code authentication
echo -n "  Verifying Claude Code auth... "
if claude -p --output-format json "ping" >/dev/null 2>&1; then
  echo -e "${GREEN}OK${NC}"
else
  echo ""
  fail "Claude Code not authenticated. Run 'claude' interactively first to log in."
fi

# ============================================================
# Phase 2: cli-gateway
# ============================================================
step "Phase 2: Setting up cli-gateway"

cd "$SCRIPT_DIR/cli-gateway"

if [ ! -d "node_modules" ]; then
  echo "  Installing dependencies (node-pty)..."
  npm install --loglevel=warn 2>&1 | tail -3
fi
ok "Dependencies installed"

# Kill any existing gateway on this port
if lsof -ti ":${GATEWAY_PORT}" >/dev/null 2>&1; then
  warn "Killing existing process on port ${GATEWAY_PORT}"
  lsof -ti ":${GATEWAY_PORT}" | xargs kill -9 2>/dev/null || true
  sleep 1
fi

echo "  Starting cli-gateway..."
node --experimental-strip-types src/server.ts > /tmp/cli-gateway.log 2>&1 &
GATEWAY_PID=$!
sleep 3

if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
  echo "  Gateway log:"
  cat /tmp/cli-gateway.log 2>/dev/null || true
  fail "cli-gateway failed to start"
fi

if ! curl -sf "http://localhost:${GATEWAY_PORT}/health" >/dev/null 2>&1; then
  fail "Gateway health check failed"
fi
ok "cli-gateway running on http://localhost:${GATEWAY_PORT} (PID: $GATEWAY_PID)"

# ============================================================
# Phase 3: OpenClaw
# ============================================================
step "Phase 3: Setting up OpenClaw"

OPENCLAW_DIR="$SCRIPT_DIR/openclaw"

if [ -d "$OPENCLAW_DIR" ] && [ -f "$OPENCLAW_DIR/package.json" ]; then
  ok "OpenClaw already cloned"
else
  echo "  Cloning OpenClaw..."
  git clone "$OPENCLAW_REPO" "$OPENCLAW_DIR"
  ok "OpenClaw cloned"
fi

cd "$OPENCLAW_DIR"

if [ ! -d "node_modules" ]; then
  echo "  Installing OpenClaw dependencies (this may take a few minutes)..."
  pnpm install --frozen-lockfile 2>/dev/null || pnpm install
fi
ok "OpenClaw dependencies installed"

if [ ! -d "dist" ]; then
  echo "  Building OpenClaw (first time only)..."
  pnpm build
fi
ok "OpenClaw built"

# ============================================================
# Phase 4: Configuration
# ============================================================
step "Phase 4: Configuring OpenClaw"

mkdir -p "$OPENCLAW_STATE_DIR"
CONFIG_FILE="$OPENCLAW_STATE_DIR/openclaw.json"

if [ -f "$CONFIG_FILE" ]; then
  warn "Config exists at $CONFIG_FILE — backing up to openclaw.json.bak"
  cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
fi

cat > "$CONFIG_FILE" << CONFIGEOF
{
  "models": {
    "mode": "merge",
    "providers": {
      "claude-code": {
        "baseUrl": "http://localhost:${GATEWAY_PORT}/v1",
        "api": "openai-completions",
        "apiKey": "not-needed",
        "models": [
          {
            "id": "claude-code/sonnet",
            "name": "Claude Sonnet (via Claude Code CLI)",
            "reasoning": true,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 200000,
            "maxTokens": 16384
          },
          {
            "id": "claude-code/opus",
            "name": "Claude Opus (via Claude Code CLI)",
            "reasoning": true,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 200000,
            "maxTokens": 16384
          },
          {
            "id": "claude-code/haiku",
            "name": "Claude Haiku (via Claude Code CLI)",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 200000,
            "maxTokens": 16384
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "claude-code/claude-code/sonnet",
        "fallbacks": ["claude-code/claude-code/opus"]
      },
      "models": {
        "claude-code/claude-code/sonnet": { "alias": "sonnet" },
        "claude-code/claude-code/opus": { "alias": "opus" },
        "claude-code/claude-code/haiku": { "alias": "haiku" }
      }
    }
  }
}
CONFIGEOF

ok "Config written to $CONFIG_FILE"

# ============================================================
# Summary
# ============================================================
step "Setup Complete!"
echo ""
echo "  cli-gateway:  http://localhost:${GATEWAY_PORT}  (PID: $GATEWAY_PID)"
echo "  OpenClaw dir: $OPENCLAW_DIR"
echo "  Config:       $CONFIG_FILE"
echo ""
echo "  Start OpenClaw:"
echo "    cd $OPENCLAW_DIR && pnpm start"
echo ""
echo "  Or start the gateway daemon separately:"
echo "    cd $SCRIPT_DIR/cli-gateway && node --experimental-strip-types src/server.ts"
echo ""
echo "  Stop gateway:"
echo "    kill $GATEWAY_PID"
echo ""
echo "  Switch models in OpenClaw:"
echo "    /model sonnet"
echo "    /model opus"
echo "    /model haiku"
echo ""
