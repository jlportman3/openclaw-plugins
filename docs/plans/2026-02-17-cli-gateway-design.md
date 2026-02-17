# cli-gateway Design

> A standalone OpenAI-compatible proxy that translates API requests into CLI subprocess calls, enabling any CLI LLM tool to serve as an OpenAI-compatible endpoint.

**Date:** 2026-02-17
**Status:** Approved

---

## Motivation

OpenClaw (and many other tools) speak the OpenAI `/v1/chat/completions` API. Meanwhile, powerful LLM CLI tools like Claude Code, Codex, and Gemini CLI exist as subscription-based products with no per-token billing. cli-gateway bridges these two worlds — any CLI tool that accepts a prompt and returns text becomes an OpenAI-compatible endpoint.

**Primary use case:** Use a Claude Max subscription ($200/mo) as the LLM backend for OpenClaw, avoiding per-token API costs while leveraging Claude Code's session management, compaction, and (optionally) built-in tools.

**Future use cases:** Codex CLI, Gemini CLI, or any future CLI-based LLM tool.

---

## Architecture

```
┌─────────────────────────────────────────────┐
│              OpenClaw / Any Client           │
│    (speaks OpenAI /v1/chat/completions)      │
└──────────────────┬──────────────────────────┘
                   │ HTTP (SSE streaming)
                   v
┌─────────────────────────────────────────────┐
│             cli-gateway                      │
│  Lightweight HTTP server (Node.js)           │
│                                              │
│  ┌─────────────┐  ┌──────────────────────┐  │
│  │ OpenAI API  │  │  Backend Registry     │  │
│  │ /v1/chat/   │  │                       │  │
│  │ /v1/models  │  │  claude-code backend  │  │
│  │             │->│  codex backend        │  │
│  │             │  │  gemini backend       │  │
│  │             │  │  (any CLI backend)    │  │
│  └─────────────┘  └──────────────────────┘  │
└──────────────────┬──────────────────────────┘
                   │ subprocess (spawn)
                   v
        ┌──────────────────┐
        │  claude -p ...   │
        │  codex ...       │
        │  gemini ...      │
        └──────────────────┘
```

---

## API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/models` | GET | List all models from all detected backends |
| `/v1/chat/completions` | POST | Chat completion (streaming & non-streaming) |
| `/health` | GET | Readiness check, backend availability |

### Model Naming

Format: `backend-id/model-name`

Examples:
- `claude-code/opus` — Claude Opus via Claude Code CLI
- `claude-code/sonnet` — Claude Sonnet via Claude Code CLI
- `codex/o3` — O3 via Codex CLI (future)
- `gemini/2.5-pro` — Gemini 2.5 Pro via Gemini CLI (future)

The server splits on the first `/` to route to the correct backend.

### Streaming

Responses use standard OpenAI SSE format:

```
data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant","content":"Hello"},"index":0}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"delta":{"content":" there"},"index":0}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"delta":{},"finish_reason":"stop","index":0}]}

data: [DONE]
```

Non-streaming: accumulates full response, returns single JSON object.

### Error Mapping

| CLI condition | HTTP response |
|--------------|---------------|
| CLI not found | 503 Service Unavailable |
| Auth failure | 401 Unauthorized |
| Rate limited | 429 Too Many Requests |
| Timeout | 504 Gateway Timeout |
| Other errors | 500 Internal Server Error |

---

## Backend Interface

Each CLI tool implements this contract:

```typescript
interface CliBackend {
  id: string;                     // "claude-code", "codex", "gemini"
  displayName: string;            // "Claude Code", "OpenAI Codex CLI"

  detect(): Promise<boolean>;     // Is CLI installed and authenticated?
  listModels(): Model[];          // What models does this backend expose?

  spawn(request: SpawnRequest): ChildProcess;
  parseOutput(stream: ReadableStream): AsyncIterable<ChatChunk>;
}

interface SpawnRequest {
  model: string;                  // Model portion after the slash
  messages: OpenAIMessage[];      // Full conversation (for first-turn extraction)
  systemPrompt?: string;          // From messages[0] if role=system
  temperature?: number;
  maxTokens?: number;
  sessionId?: string;             // For session continuity
  tools?: boolean;                // Enable CLI's built-in tools
  signal: AbortSignal;            // For cancellation
}
```

---

## Session Management

**Claude Code owns the conversation state.** The proxy does not track message history or perform compaction — Claude Code handles all of that internally.

### Flow

```
Request 1: messages = [system, user1]
  -> claude -p --session-id <sid> --system-prompt "..." "user1"
  -> Claude Code creates session

Request 2: messages = [system, user1, assistant1, user2]
  -> claude -p --resume <sid> "user2"
  -> Claude Code has history, handles compaction

Request N:
  -> claude -p --resume <sid> "latest user message"
```

### Session ID Derivation

- If client sends `X-Session-Id` header -> use directly
- Otherwise -> derive from hashing first system prompt + first user message
- Maps 1:1 to Claude Code's `--session-id` / `--resume` flags

### New Conversation Detection

If `messages.length <= 2` (system + one user message) and no `X-Session-Id` header, treat as a fresh conversation with a new session ID.

### Compaction

Deferred to v2. Claude Code handles its own compaction internally. Future work: detect compaction via `context_management` field in stream-json output and signal back to OpenClaw.

---

## Claude Code Backend Details

```typescript
spawn(req: SpawnRequest): ChildProcess {
  const args = [
    "-p",
    "--output-format", "stream-json",
    "--model", req.model,
  ];

  if (req.systemPrompt) {
    args.push("--system-prompt", req.systemPrompt);
  }

  if (req.sessionId && !req.isNewConversation) {
    args.push("--resume", req.sessionId);
  } else if (req.sessionId) {
    args.push("--session-id", req.sessionId);
  }

  if (!req.tools) {
    args.push("--tools", "");
  }

  args.push(extractLastUserMessage(req.messages));

  return spawn("claude", args, { signal: req.signal });
}
```

### Output Parsing

Claude Code `--output-format stream-json` emits NDJSON with these event types:

| type | subtype | Description |
|------|---------|-------------|
| `system` | `init` | Session config, model, tools |
| `system` | `hook_started` | Hook execution started |
| `system` | `hook_response` | Hook execution completed |
| `assistant` | — | Model response with content, usage, context_management |
| `result` | `success`/error | Final summary with total usage and cost |

We convert:
- `assistant` events -> OpenAI SSE `chat.completion.chunk` deltas
- `result` event -> final SSE chunk with `finish_reason: "stop"` + usage
- `system` events -> ignored (or logged)

---

## Configuration

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
      "enabled": false,
      "command": "codex",
      "defaultModel": "o3"
    }
  }
}
```

---

## OpenClaw Integration

Add to OpenClaw config (`models.providers`):

```yaml
models:
  providers:
    claude-code:
      baseUrl: "http://localhost:4090/v1"
      api: "openai-responses"
      models:
        - id: "claude-code/opus"
          name: "Claude Opus (via CLI)"
          reasoning: true
          input: ["text", "image"]
          contextWindow: 200000
          maxTokens: 16384
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
        - id: "claude-code/sonnet"
          name: "Claude Sonnet (via CLI)"
          reasoning: true
          input: ["text", "image"]
          contextWindow: 200000
          maxTokens: 16384
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
```

---

## Project Structure

```
cli-gateway/
├── package.json
├── tsconfig.json
├── config.json
├── src/
│   ├── server.ts             # HTTP server, route handlers
│   ├── types.ts              # OpenAI types, backend interface
│   ├── session-map.ts        # Session ID derivation & tracking
│   ├── openai-format.ts      # OpenAI SSE chunk formatting
│   ├── backends/
│   │   ├── index.ts          # Backend registry, auto-detection
│   │   └── claude-code.ts    # Claude Code backend
│   └── util/
│       ├── spawn.ts          # Subprocess management
│       └── which.ts          # CLI detection
├── bin/
│   └── cli-gateway.sh        # Start script
└── setup.sh                  # One-command onboarding
```

**Dependencies:** Zero npm dependencies. Pure Node.js built-ins (`http`, `child_process`, `crypto`).

---

## Onboarding

Prerequisites:
1. Claude Code installed and authenticated (Claude Max subscription recommended)
2. Node.js 22+

```bash
curl -sSL https://raw.githubusercontent.com/.../setup.sh | bash
```

The setup script:
1. Checks prerequisites (claude, node, pnpm)
2. Verifies Claude Code authentication
3. Clones OpenClaw if needed
4. Clones/sets up cli-gateway
5. Writes default config
6. Configures OpenClaw provider
7. Starts cli-gateway + OpenClaw

---

## Future Work

- **Compaction signaling:** Detect `context_management` in stream-json, signal to OpenClaw
- **Codex backend:** ~50-80 lines implementing CliBackend for Codex CLI
- **Gemini backend:** Same pattern for Gemini CLI
- **Tool passthrough:** Configurable option to let CLI tools use their own tools
- **Connection pooling:** Keep warm CLI processes for reduced latency
- **Rate limit awareness:** Parse CLI error output to detect hourly/daily limits
