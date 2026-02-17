#!/usr/bin/env bash
set -euo pipefail

echo "=== cli-gateway + OpenClaw Setup ==="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# 1. Check Node.js
if ! command -v node &>/dev/null; then
  fail "Node.js not found. Install Node.js 22+ first."
fi
NODE_MAJOR=$(node -v | cut -d. -f1 | tr -d v)
if [ "$NODE_MAJOR" -lt 22 ]; then
  fail "Node.js 22+ required (found $(node -v))"
fi
ok "Node.js $(node -v)"

# 2. Check Claude Code
if ! command -v claude &>/dev/null; then
  fail "Claude Code not found. Install: npm install -g @anthropic-ai/claude-code"
fi
ok "Claude Code $(claude --version 2>/dev/null | head -1)"

# 3. Verify Claude Code authentication
echo -n "Verifying Claude Code auth... "
if claude -p --output-format json "ping" >/dev/null 2>&1; then
  ok "Authenticated"
else
  fail "Claude Code not authenticated. Run 'claude' interactively to log in."
fi

# 4. Check pnpm (for OpenClaw)
if ! command -v pnpm &>/dev/null; then
  warn "pnpm not found. Installing..."
  npm install -g pnpm
  ok "pnpm installed"
else
  ok "pnpm $(pnpm --version)"
fi

# 5. Install dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/cli-gateway"

if [ ! -d "node_modules" ]; then
  echo "Installing dependencies..."
  npm install
  ok "Dependencies installed"
else
  ok "Dependencies already installed"
fi

# 6. Start cli-gateway
echo ""
echo "Starting cli-gateway..."
node --experimental-strip-types src/server.ts &
GATEWAY_PID=$!
sleep 3

if kill -0 $GATEWAY_PID 2>/dev/null; then
  ok "cli-gateway running on http://localhost:4090 (PID: $GATEWAY_PID)"
else
  fail "cli-gateway failed to start"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "cli-gateway is running at http://localhost:4090"
echo ""
echo "To use with OpenClaw, add this to your OpenClaw config:"
echo ""
echo '  models:'
echo '    providers:'
echo '      claude-code:'
echo '        baseUrl: "http://localhost:4090/v1"'
echo '        api: "openai-responses"'
echo '        models:'
echo '          - id: "claude-code/sonnet"'
echo '            name: "Claude Sonnet (via CLI)"'
echo '            reasoning: true'
echo '            input: ["text"]'
echo '            contextWindow: 200000'
echo '            maxTokens: 16384'
echo ""
echo "To stop: kill $GATEWAY_PID"
