# openclaw-plugins

> [!CAUTION]
> ## USE AT YOUR OWN RISK
>
> This software is provided **"AS IS"**, without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and noninfringement.
>
> **This tool spawns CLI subprocesses with the ability to execute arbitrary code on your machine.** If you enable `tools: true`, it passes `--dangerously-skip-permissions` to the CLI, which means **it can read, write, and delete files, run shell commands, and generally do whatever it wants to your system without asking.**
>
> If this software **nukes your system**, **eats your homework**, **maxes out your API bill**, **deletes your production database**, **emails your browser history to your boss**, or **achieves sentience and orders 10,000 rubber ducks to your house** — that is entirely on you. Do not come crying to us. You were warned.
>
> **NO WARRANTY. NO LIABILITY. NO REFUNDS. NO SYMPATHY.**
>
> By using this software you acknowledge that you have read this disclaimer, understood the risks, and have accepted that the consequences of running autonomous AI agents with filesystem access are **your problem and yours alone.**

---

Plugins and tools for [OpenClaw](https://github.com/nicobailon/openclaw).

## cli-gateway

OpenAI-compatible proxy that translates `/v1/chat/completions` requests into CLI subprocess calls. Use your Claude Code, Codex, or Gemini CLI subscription as an LLM endpoint for OpenClaw or any OpenAI-compatible client.

### How It Works

```
OpenClaw / any OpenAI client
        |
        v
   cli-gateway (localhost:4090)
   /v1/chat/completions
        |
   +---------+---------+
   |         |         |
   v         v         v
 Claude    Codex     Gemini
  Code      CLI       CLI
 (PTY)   (spawn)   (spawn)
   |         |         |
   v         v         v
   NDJSON -> OpenAI SSE translation
```

The gateway spawns CLI processes, parses their NDJSON output, and translates it to OpenAI-compatible SSE streams. Session state is owned by the CLI tool — only the latest user message is sent on each turn, with `--resume` for continuity.

### Supported Backends

| Backend | Command | Models | Spawn Method |
|---------|---------|--------|-------------|
| **Claude Code** | `claude` | `claude-code/sonnet`, `claude-code/opus`, `claude-code/haiku` | PTY (node-pty) |
| **Codex CLI** | `codex` | `codex/gpt-5.3-codex`, `codex/o3`, `codex/o4-mini` | child_process |
| **Gemini CLI** | `gemini` | `gemini/auto`, `gemini/gemini-2.5-pro`, `gemini/gemini-2.5-flash` | child_process |

Backends are auto-detected at startup. If a CLI tool isn't installed, that backend is silently skipped.

### Quick Start

One line, fresh Ubuntu 22.04+ server:

```bash
curl -fsSL https://raw.githubusercontent.com/jlportman3/openclaw-plugins/main/install.sh | sudo bash
```

This installs all system dependencies, lets you pick which CLI tools to install (Claude Code, Codex, Gemini), walks you through authentication, and deploys cli-gateway as a systemd service.

### Manual Start

```bash
cd cli-gateway
npm install        # first time only (installs node-pty)
node --experimental-strip-types src/server.ts
```

### API

- `GET /health` — Backend availability and model counts
- `GET /v1/models` — List all available models across backends
- `POST /v1/chat/completions` — Chat completion (streaming & non-streaming)

### Model Names

Format: `backend/model` — the backend prefix routes to the right CLI tool.

```
claude-code/sonnet       -> claude -p --model sonnet
codex/gpt-5.3-codex     -> codex exec --json -m gpt-5.3-codex
gemini/auto              -> gemini -p --model auto
```

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
    },
    "codex": {
      "enabled": true,
      "command": "codex",
      "defaultModel": "o4-mini",
      "tools": false,
      "sessionContinuity": true
    },
    "gemini": {
      "enabled": true,
      "command": "gemini",
      "defaultModel": "auto",
      "tools": false,
      "sessionContinuity": true
    }
  }
}
```

Set `tools: true` to enable tool use. This passes permission-bypass flags to the CLI (`--dangerously-skip-permissions` for Claude, `--yolo` for Codex/Gemini) — **use with extreme caution**.

### Environment Security

The gateway scrubs the environment before spawning subprocesses. Only whitelisted system variables (`PATH`, `HOME`, `TERM`, etc.) and backend-specific auth keys are passed through. No `.env` secrets or stray API keys leak into child processes.

### Session Continuity

Sessions are managed by the CLI tool. The proxy derives a session ID from the conversation's system prompt and first user message (SHA-256 hash). Pass `X-Session-Id` header for explicit session control.

On the first request, a new session is started. Subsequent requests use `--resume` to continue the existing session, sending only the latest user message to conserve tokens.

### Dependencies

- **Node.js 22+** — native TypeScript execution via `--experimental-strip-types`
- **node-pty** — PTY support for Claude Code (installed via `npm install`)
- At least one CLI tool:
  - **Claude Code** — `npm install -g @anthropic-ai/claude-code`
  - **Codex CLI** — `npm install -g @openai/codex`
  - **Gemini CLI** — `npm install -g @google/gemini-cli`

### Adding New Backends

Create a new file in `cli-gateway/src/backends/` implementing the `CliBackend` interface, register it in `backends/index.ts`, and add auth keys to `util/clean-env.ts`. See `codex.ts` for the simplest reference.

### Design

See [docs/plans/2026-02-17-cli-gateway-design.md](docs/plans/2026-02-17-cli-gateway-design.md).
