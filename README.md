# openclaw-plugins

Plugins and tools for [OpenClaw](https://github.com/nicobailon/openclaw).

## cli-gateway

OpenAI-compatible proxy that translates `/v1/chat/completions` requests into CLI subprocess calls. Use your Claude Code subscription (or Codex, Gemini CLI) as an LLM endpoint for OpenClaw or any OpenAI-compatible client.

### How It Works

```
OpenClaw / any OpenAI client
        |
        v
   cli-gateway (localhost:4090)
   /v1/chat/completions
        |
        v
   claude -p --output-format stream-json
   (via PTY subprocess)
        |
        v
   NDJSON -> SSE translation
```

The gateway spawns CLI processes in a pseudo-terminal (PTY), parses their NDJSON output, and translates it to OpenAI-compatible SSE streams. Session state is owned by the CLI tool — only the latest user message is sent on each turn, with `--resume` for continuity.

### Quick Start

```bash
# Prerequisites: Node.js 22+, Claude Code installed & authenticated
./setup.sh
```

### Manual Start

```bash
cd cli-gateway
npm install        # first time only (installs node-pty)
node --experimental-strip-types src/server.ts
```

### API

- `GET /health` — Backend availability
- `GET /v1/models` — List available models
- `POST /v1/chat/completions` — Chat completion (streaming & non-streaming)

### Model Names

Format: `backend/model` — e.g., `claude-code/sonnet`, `claude-code/opus`, `claude-code/haiku`

### Configuration

Edit `cli-gateway/config.json`:

```json
{
  "port": 4090,
  "backends": {
    "claude-code": {
      "enabled": true,
      "command": "claude",
      "defaultModel": "sonnet",
      "tools": false,
      "sessionContinuity": true
    }
  }
}
```

Set `tools: true` to allow Claude Code to use its built-in tools (Bash, Edit, Read, etc.). This passes `--dangerously-skip-permissions` to the CLI — use with caution.

### Session Continuity

Sessions are managed by the CLI tool. The proxy derives a session ID from the conversation's system prompt and first user message (SHA-256 hash). Pass `X-Session-Id` header for explicit session control.

On the first request, `--session-id` starts a new conversation. Subsequent requests use `--resume` to continue the existing session, sending only the latest user message to conserve tokens.

### Dependencies

- **Node.js 22+** — native TypeScript execution via `--experimental-strip-types`
- **Claude Code** — `npm install -g @anthropic-ai/claude-code`
- **node-pty** — PTY support (installed via `npm install`)

### Adding New Backends

Create a new file in `cli-gateway/src/backends/` implementing the `CliBackend` interface, then register it in `backends/index.ts`. See `claude-code.ts` for reference.

### Design

See [docs/plans/2026-02-17-cli-gateway-design.md](docs/plans/2026-02-17-cli-gateway-design.md).
