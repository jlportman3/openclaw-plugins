# ============================================================
# cli-gateway Makefile
# Non-interactive deployment, service management, OpenClaw setup
# ============================================================

SHELL          := /bin/bash
.DEFAULT_GOAL  := help

# --- Paths ---
INSTALL_DIR    := /opt/cli-gateway
SERVICE_NAME   := cli-gateway
GATEWAY_PORT   := 4090
SCRIPT_DIR     := $(shell cd "$(dir $(lastword $(MAKEFILE_LIST)))" && pwd)
GATEWAY_SRC    := $(SCRIPT_DIR)/cli-gateway
SERVICE_FILE   := /etc/systemd/system/$(SERVICE_NAME).service
ENV_FILE       := /etc/default/$(SERVICE_NAME)
OPENCLAW_REPO  := https://github.com/nicobailon/openclaw.git
OPENCLAW_DIR   := $(INSTALL_DIR)/openclaw

# --- User (set by setup.sh, defaults to current user) ---
INSTALL_USER      ?= $(shell whoami)
INSTALL_USER_HOME ?= $(shell eval echo ~$(INSTALL_USER))
NODE_BIN          := $(shell which node 2>/dev/null)

# --- Backend selection (set by setup.sh or auto-detected) ---
INSTALL_CLAUDE ?= $(shell command -v claude >/dev/null 2>&1 && echo true || echo false)
INSTALL_CODEX  ?= $(shell command -v codex  >/dev/null 2>&1 && echo true || echo false)
INSTALL_GEMINI ?= $(shell command -v gemini >/dev/null 2>&1 && echo true || echo false)

# ============================================================
# Python scripts (define/export preserves newlines)
# ============================================================

define GENERATE_GATEWAY_CONFIG
import json
config = {"port": $(GATEWAY_PORT), "backends": {}}
if "$(INSTALL_CLAUDE)" == "true":
    config["backends"]["claude-code"] = {"enabled": True, "command": "claude", "defaultModel": "sonnet", "tools": False, "sessionContinuity": True}
if "$(INSTALL_CODEX)" == "true":
    config["backends"]["codex"] = {"enabled": True, "command": "codex", "defaultModel": "o4-mini", "tools": False, "sessionContinuity": True}
if "$(INSTALL_GEMINI)" == "true":
    config["backends"]["gemini"] = {"enabled": True, "command": "gemini", "defaultModel": "auto", "tools": False, "sessionContinuity": True}
with open("$(INSTALL_DIR)/config.json", "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
names = list(config["backends"].keys())
print("  Backends: " + (", ".join(names) if names else "none"))
endef
export GENERATE_GATEWAY_CONFIG

define GENERATE_OPENCLAW_CONFIG
import json
base = "http://localhost:$(GATEWAY_PORT)/v1"
cost = {"input":0,"output":0,"cacheRead":0,"cacheWrite":0}
config = {"models": {"mode": "merge", "providers": {}}, "agents": {"defaults": {"model": {}, "models": {}}}}
providers = config["models"]["providers"]
aliases = config["agents"]["defaults"]["models"]
first = None
fallbacks = []
if "$(INSTALL_CLAUDE)" == "true":
    providers["claude-code"] = {"baseUrl": base, "api": "openai-completions", "apiKey": "not-needed", "models": [
        {"id":"claude-code/sonnet","name":"Claude Sonnet (via CLI)","reasoning":True,"input":["text"],"cost":cost,"contextWindow":200000,"maxTokens":16384},
        {"id":"claude-code/opus","name":"Claude Opus (via CLI)","reasoning":True,"input":["text"],"cost":cost,"contextWindow":200000,"maxTokens":16384},
        {"id":"claude-code/haiku","name":"Claude Haiku (via CLI)","reasoning":False,"input":["text"],"cost":cost,"contextWindow":200000,"maxTokens":16384}
    ]}
    aliases["claude-code/claude-code/sonnet"] = {"alias":"sonnet"}
    aliases["claude-code/claude-code/opus"] = {"alias":"opus"}
    aliases["claude-code/claude-code/haiku"] = {"alias":"haiku"}
    first = first or "claude-code/claude-code/sonnet"
    fallbacks.append("claude-code/claude-code/opus")
if "$(INSTALL_CODEX)" == "true":
    providers["codex"] = {"baseUrl": base, "api": "openai-completions", "apiKey": "not-needed", "models": [
        {"id":"codex/gpt-5.3-codex","name":"GPT-5.3 Codex (via CLI)","reasoning":True,"input":["text"],"cost":cost,"contextWindow":200000,"maxTokens":16384},
        {"id":"codex/o4-mini","name":"O4 Mini (via CLI)","reasoning":True,"input":["text"],"cost":cost,"contextWindow":200000,"maxTokens":16384}
    ]}
    aliases["codex/codex/gpt-5.3-codex"] = {"alias":"codex"}
    aliases["codex/codex/o4-mini"] = {"alias":"o4-mini"}
    if not first:
        first = "codex/codex/gpt-5.3-codex"
    else:
        fallbacks.append("codex/codex/gpt-5.3-codex")
if "$(INSTALL_GEMINI)" == "true":
    providers["gemini"] = {"baseUrl": base, "api": "openai-completions", "apiKey": "not-needed", "models": [
        {"id":"gemini/auto","name":"Gemini Auto (via CLI)","reasoning":True,"input":["text"],"cost":cost,"contextWindow":1000000,"maxTokens":16384},
        {"id":"gemini/gemini-2.5-pro","name":"Gemini 2.5 Pro (via CLI)","reasoning":True,"input":["text"],"cost":cost,"contextWindow":1000000,"maxTokens":16384},
        {"id":"gemini/gemini-2.5-flash","name":"Gemini 2.5 Flash (via CLI)","reasoning":True,"input":["text"],"cost":cost,"contextWindow":1000000,"maxTokens":16384}
    ]}
    aliases["gemini/gemini/auto"] = {"alias":"gemini"}
    aliases["gemini/gemini/gemini-2.5-pro"] = {"alias":"gemini-pro"}
    aliases["gemini/gemini/gemini-2.5-flash"] = {"alias":"gemini-flash"}
    if not first:
        first = "gemini/gemini/auto"
    else:
        fallbacks.append("gemini/gemini/auto")
config["agents"]["defaults"]["model"]["primary"] = first or ""
config["agents"]["defaults"]["model"]["fallbacks"] = fallbacks[:3]
path = "$(INSTALL_USER_HOME)/.openclaw/openclaw.json"
with open(path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
print("  Config: " + path)
print("  Primary: " + (first or "none"))
print("  Providers: " + ", ".join(providers.keys()))
endef
export GENERATE_OPENCLAW_CONFIG

# ============================================================
# install — Full production deployment (requires sudo)
# ============================================================
.PHONY: install
install: _check-root _check-node _copy-files _npm-install _generate-config _install-env _install-service _start-service
	@echo ""
	@echo "  ✓ cli-gateway installed and running on port $(GATEWAY_PORT)"
	@echo "  ✓ Service: $(SERVICE_NAME)"
	@echo "  ✓ User: $(INSTALL_USER)"
	@echo ""

.PHONY: _check-root
_check-root:
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "Error: 'make install' requires sudo."; \
		echo "Usage: sudo make install INSTALL_USER=$$(whoami) INSTALL_USER_HOME=$$HOME"; \
		exit 1; \
	fi

.PHONY: _check-node
_check-node:
	@if [ -z "$(NODE_BIN)" ]; then \
		echo "Error: Node.js not found. Run setup.sh first."; \
		exit 1; \
	fi
	@echo "==> Node.js: $(NODE_BIN) ($$($(NODE_BIN) -v))"

.PHONY: _copy-files
_copy-files:
	@echo "==> Copying files to $(INSTALL_DIR)"
	@mkdir -p $(INSTALL_DIR)/src/backends $(INSTALL_DIR)/src/util
	@cp $(GATEWAY_SRC)/src/*.ts $(INSTALL_DIR)/src/
	@cp $(GATEWAY_SRC)/src/backends/*.ts $(INSTALL_DIR)/src/backends/
	@cp $(GATEWAY_SRC)/src/util/*.ts $(INSTALL_DIR)/src/util/
	@cp $(GATEWAY_SRC)/package.json $(INSTALL_DIR)/
	@cp $(GATEWAY_SRC)/package-lock.json $(INSTALL_DIR)/ 2>/dev/null || true
	@cp $(GATEWAY_SRC)/tsconfig.json $(INSTALL_DIR)/ 2>/dev/null || true
	@chown -R $(INSTALL_USER):$(INSTALL_USER) $(INSTALL_DIR)

.PHONY: _npm-install
_npm-install:
	@echo "==> Installing dependencies (node-pty native build)"
	@cd $(INSTALL_DIR) && sudo -u $(INSTALL_USER) npm install --omit=dev 2>&1 | tail -5
	@echo "  ✓ node-pty compiled"

.PHONY: _generate-config
_generate-config:
	@echo "==> Generating config.json"
	@echo "$$GENERATE_GATEWAY_CONFIG" | python3
	@chown $(INSTALL_USER):$(INSTALL_USER) $(INSTALL_DIR)/config.json

.PHONY: _install-env
_install-env:
	@echo "==> Writing environment file $(ENV_FILE)"
	@printf '%s\n' \
		'# cli-gateway environment — loaded by systemd EnvironmentFile=' \
		'# Edit this file to override settings or add API keys.' \
		'' \
		'# PATH must include dirs where CLI tools are installed.' \
		'# claude may be in ~/.local/bin; codex/gemini in /usr/bin or /usr/local/bin.' \
		'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$(INSTALL_USER_HOME)/.local/bin' \
		'' \
		'# Uncomment to use API keys instead of (or alongside) OAuth:' \
		'# ANTHROPIC_API_KEY=' \
		'# OPENAI_API_KEY=' \
		'# GEMINI_API_KEY=' \
		> $(ENV_FILE)
	@chmod 640 $(ENV_FILE)

.PHONY: _install-service
_install-service:
	@echo "==> Installing systemd service"
	@printf '%s\n' \
		'[Unit]' \
		'Description=cli-gateway — OpenAI-compatible CLI proxy' \
		'Documentation=https://github.com/jlportman3/openclaw-plugins' \
		'After=network.target' \
		'Wants=network-online.target' \
		'' \
		'[Service]' \
		'Type=simple' \
		'User=$(INSTALL_USER)' \
		'Group=$(INSTALL_USER)' \
		'WorkingDirectory=$(INSTALL_DIR)' \
		'ExecStart=$(NODE_BIN) --experimental-strip-types src/server.ts' \
		'Restart=on-failure' \
		'RestartSec=5' \
		'StartLimitIntervalSec=60' \
		'StartLimitBurst=3' \
		'' \
		'# Environment' \
		'EnvironmentFile=-$(ENV_FILE)' \
		'Environment=HOME=$(INSTALL_USER_HOME)' \
		'Environment=NODE_ENV=production' \
		'' \
		'# Security hardening' \
		'NoNewPrivileges=true' \
		'ProtectSystem=strict' \
		'ReadWritePaths=$(INSTALL_DIR)' \
		'PrivateTmp=true' \
		'' \
		'# Resource limits' \
		'LimitNOFILE=65536' \
		'' \
		'# Logging' \
		'StandardOutput=journal' \
		'StandardError=journal' \
		'SyslogIdentifier=$(SERVICE_NAME)' \
		'' \
		'[Install]' \
		'WantedBy=multi-user.target' \
		> $(SERVICE_FILE)
	@systemctl daemon-reload
	@systemctl enable $(SERVICE_NAME) --quiet
	@echo "  ✓ Service enabled"

.PHONY: _start-service
_start-service:
	@echo "==> Starting $(SERVICE_NAME)"
	@systemctl start $(SERVICE_NAME)
	@sleep 2
	@if systemctl is-active --quiet $(SERVICE_NAME); then \
		echo "  ✓ Service running"; \
		sleep 1; \
		if curl -sf http://localhost:$(GATEWAY_PORT)/health >/dev/null 2>&1; then \
			echo "  ✓ Health check passed"; \
		else \
			echo "  ⚠ Health check pending (service may still be starting)"; \
		fi; \
	else \
		echo "  ✗ Service failed to start. Check: journalctl -u $(SERVICE_NAME) --no-pager -n 30"; \
		exit 1; \
	fi

# ============================================================
# Service management
# ============================================================
.PHONY: start
start:
	sudo systemctl start $(SERVICE_NAME)
	@echo "  ✓ Started"

.PHONY: stop
stop:
	sudo systemctl stop $(SERVICE_NAME)
	@echo "  ✓ Stopped"

.PHONY: restart
restart:
	sudo systemctl restart $(SERVICE_NAME)
	@sleep 2
	@if systemctl is-active --quiet $(SERVICE_NAME); then \
		echo "  ✓ Restarted"; \
	else \
		echo "  ✗ Failed to restart"; \
	fi

.PHONY: status
status:
	@echo "==> Service Status"
	@systemctl status $(SERVICE_NAME) --no-pager 2>/dev/null || echo "  Service not found"
	@echo ""
	@echo "==> Health Check"
	@curl -sf http://localhost:$(GATEWAY_PORT)/health 2>/dev/null \
		| python3 -m json.tool 2>/dev/null \
		|| echo "  Health endpoint not responding (is the service running?)"

.PHONY: logs
logs:
	sudo journalctl -fu $(SERVICE_NAME)

# ============================================================
# Smoke tests
# ============================================================
.PHONY: test
test:
	@echo "==> Smoke Tests (port $(GATEWAY_PORT))"
	@echo ""
	@echo -n "  Health:  "
	@curl -sf http://localhost:$(GATEWAY_PORT)/health 2>/dev/null \
		| python3 -c "import sys,json; d=json.load(sys.stdin); print('OK — ' + ', '.join(d.get('backends',{}).keys()))" \
		2>/dev/null || echo "FAIL — not responding"
	@echo -n "  Models:  "
	@curl -sf http://localhost:$(GATEWAY_PORT)/v1/models 2>/dev/null \
		| python3 -c "import sys,json; d=json.load(sys.stdin); print('OK — ' + str(len(d.get('data',[]))) + ' models')" \
		2>/dev/null || echo "FAIL — not responding"
	@echo ""
	@echo "  To test a chat completion:"
	@echo "    curl -X POST http://localhost:$(GATEWAY_PORT)/v1/chat/completions \\"
	@echo "      -H 'Content-Type: application/json' \\"
	@echo "      -d '{\"model\":\"claude-code/sonnet\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"

# ============================================================
# Uninstall
# ============================================================
.PHONY: uninstall
uninstall:
	@echo "==> Uninstalling $(SERVICE_NAME)"
	-@sudo systemctl stop $(SERVICE_NAME) 2>/dev/null
	-@sudo systemctl disable $(SERVICE_NAME) 2>/dev/null
	-@sudo rm -f $(SERVICE_FILE)
	-@sudo rm -f $(ENV_FILE)
	@sudo systemctl daemon-reload
	@echo ""
	@echo -n "  Remove $(INSTALL_DIR)? [y/N] "
	@read -r answer; \
	if [ "$$answer" = "y" ] || [ "$$answer" = "Y" ]; then \
		sudo rm -rf $(INSTALL_DIR); \
		echo "  ✓ Removed $(INSTALL_DIR)"; \
	else \
		echo "  Kept $(INSTALL_DIR)"; \
	fi
	@echo "  ✓ cli-gateway uninstalled"

# ============================================================
# OpenClaw integration
# ============================================================
.PHONY: openclaw-install
openclaw-install: _openclaw-clone _openclaw-build _openclaw-config
	@echo ""
	@echo "  ✓ OpenClaw installed and configured"
	@echo "  Start with: make openclaw-start"
	@echo ""

.PHONY: _openclaw-clone
_openclaw-clone:
	@if [ -d "$(OPENCLAW_DIR)" ] && [ -f "$(OPENCLAW_DIR)/package.json" ]; then \
		echo "==> OpenClaw already cloned at $(OPENCLAW_DIR)"; \
	else \
		echo "==> Cloning OpenClaw"; \
		git clone $(OPENCLAW_REPO) $(OPENCLAW_DIR); \
	fi

.PHONY: _openclaw-build
_openclaw-build:
	@echo "==> Installing OpenClaw dependencies (pnpm)"
	@cd $(OPENCLAW_DIR) && pnpm install --frozen-lockfile 2>/dev/null || cd $(OPENCLAW_DIR) && pnpm install
	@echo "==> Building OpenClaw"
	@cd $(OPENCLAW_DIR) && pnpm build

.PHONY: _openclaw-config
_openclaw-config:
	@echo "==> Generating OpenClaw config"
	@mkdir -p $(INSTALL_USER_HOME)/.openclaw
	@echo "$$GENERATE_OPENCLAW_CONFIG" | python3

.PHONY: openclaw-start
openclaw-start:
	@echo "==> Starting OpenClaw"
	@if [ ! -d "$(OPENCLAW_DIR)/dist" ]; then \
		echo "  Error: OpenClaw not built. Run 'make openclaw-install' first."; \
		exit 1; \
	fi
	@cd $(OPENCLAW_DIR) && pnpm start

# ============================================================
# Cleanup
# ============================================================
.PHONY: clean
clean:
	@echo "==> Cleaning local build artifacts"
	-rm -rf $(SCRIPT_DIR)/cli-gateway/node_modules
	-rm -f $(SCRIPT_DIR)/.setup-state
	@echo "  ✓ Done"

# ============================================================
# Help
# ============================================================
.PHONY: help
help:
	@echo ""
	@echo "  cli-gateway — Makefile targets"
	@echo ""
	@echo "  Setup:"
	@echo "    install          Deploy as systemd service (requires sudo)"
	@echo "    uninstall        Remove service and optionally delete files"
	@echo ""
	@echo "  Service:"
	@echo "    start            Start the service"
	@echo "    stop             Stop the service"
	@echo "    restart          Restart the service"
	@echo "    status           Service status + health check"
	@echo "    logs             Follow service logs (journalctl)"
	@echo "    test             Smoke tests against running service"
	@echo ""
	@echo "  OpenClaw:"
	@echo "    openclaw-install Clone, build, and configure OpenClaw"
	@echo "    openclaw-start   Start OpenClaw"
	@echo ""
	@echo "  Other:"
	@echo "    clean            Remove local build artifacts"
	@echo "    help             Show this help"
	@echo ""
