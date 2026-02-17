# OpenClaw Architecture Reference

> Reference document for developing patches against OpenClaw without modifying the upstream repo.

## Overview

OpenClaw (v2026.2.16) is a multi-channel AI gateway/personal assistant written in TypeScript (ESM, Node 22+). It routes messages from WhatsApp, Telegram, Slack, Discord, Signal, iMessage, and web clients to LLM providers (Anthropic, OpenAI, Google, Ollama, GitHub Copilot, Qwen, etc.) and returns responses.

**Core SDK:** `@mariozechner/pi-agent-core`, `@mariozechner/pi-ai`, `@mariozechner/pi-coding-agent` (v0.52.12)

---

## Directory Structure

```
src/
├── entry.ts                    # CLI entry point → cli/run-main.js → runCli()
├── index.ts                    # Main module exports, dotenv, Commander program
├── runtime.ts                  # Runtime environment detection
├── cli/                        # CLI wiring
├── commands/                   # CLI commands
├── agents/                     # Core agent layer (THE key directory)
│   ├── system-prompt.ts        # buildAgentSystemPrompt() — 696 lines
│   ├── system-prompt-params.ts # Runtime params (OS, arch, model, timezone, etc.)
│   ├── pi-tools.ts             # createOpenClawCodingTools() — all agent tools
│   ├── models-config.ts        # Model configuration management
│   ├── model-auth.ts           # API key resolution
│   ├── pi-embedded-runner.ts   # Re-export barrel
│   ├── pi-embedded-runner/
│   │   ├── run.ts              # runEmbeddedPiAgent() — main execution loop (1059 lines)
│   │   ├── run/
│   │   │   ├── attempt.ts      # runEmbeddedAttempt() — single LLM call (1266 lines)
│   │   │   ├── payloads.ts     # Response payload construction
│   │   │   ├── params.ts       # Parameter definitions
│   │   │   ├── images.ts       # Image handling for vision models
│   │   │   └── compaction-timeout.ts
│   │   ├── system-prompt.ts    # buildEmbeddedSystemPrompt(), createSystemPromptOverride()
│   │   ├── model.ts            # resolveModel()
│   │   ├── compact.ts          # Context compaction
│   │   ├── history.ts          # Message history limiting
│   │   ├── tool-split.ts       # SDK vs custom tool separation
│   │   ├── extra-params.ts     # Extra provider params
│   │   └── google.ts           # Google-specific handling
│   ├── pi-embedded-subscribe.ts           # LLM response subscription (600+ lines)
│   ├── pi-embedded-subscribe.handlers.ts  # Event routing
│   ├── pi-embedded-subscribe.handlers.lifecycle.js
│   ├── pi-embedded-subscribe.handlers.messages.js
│   ├── pi-embedded-subscribe.handlers.tools.js
│   ├── pi-embedded-helpers/    # Error detection, turn handling, thinking, images
│   ├── pi-embedded-utils.ts    # Text extraction, thinking tag stripping
│   ├── auth-profiles/          # Auth profile handling
│   └── tools/                  # Individual tool implementations
├── auto-reply/                 # Inbound message processing
│   ├── dispatch.ts             # dispatchInboundMessage() — entry point
│   ├── reply.ts                # Barrel re-exports
│   ├── reply/
│   │   ├── get-reply.ts        # getReplyFromConfig() — main reply orchestration (342 lines)
│   │   ├── agent-runner.ts     # runReplyAgent() — agent execution coordinator
│   │   ├── agent-runner-execution.ts  # runAgentTurnWithFallback()
│   │   ├── commands-system-prompt.ts  # resolveCommandsSystemPromptBundle()
│   │   ├── session.ts          # Session initialization (483 lines)
│   │   └── model-selection.ts  # Fuzzy model matching (592 lines)
│   ├── model.ts                # /model directive parsing
│   ├── thinking.ts             # ThinkLevel, ReasoningLevel definitions
│   └── templating.ts           # MsgContext / TemplateContext
├── gateway/                    # WebSocket + HTTP server
│   ├── openai-http.ts          # OpenAI-compatible /v1/chat/completions (360+ lines)
│   ├── agent-prompt.ts         # Builds agent message from conversation entries
│   ├── chat-sanitize.ts        # Message sanitization
│   ├── server/
│   │   └── ws-connection.ts    # WebSocket connection handling
│   └── server-methods/
│       ├── chat.ts             # chat.send, chat.history, chat.abort, chat.inject
│       ├── send.ts             # Outbound message delivery
│       └── types.ts            # GatewayRequestContext
├── routing/                    # Multi-tier agent/session routing
│   ├── resolve-route.ts        # Tier-based binding resolution
│   └── session-key.ts          # Session key format/scoping
├── channels/                   # Channel plugins
│   ├── registry.ts             # Channel registry
│   ├── plugins/                # Per-channel normalize/outbound/status/actions
│   └── session.ts              # Inbound session recording
├── providers/                  # LLM provider auth
│   ├── github-copilot-auth.ts  # GitHub Copilot device auth
│   ├── github-copilot-token.ts # Copilot token exchange/caching
│   ├── github-copilot-models.ts
│   └── qwen-portal-oauth.ts   # Qwen Portal OAuth refresh
├── infra/
│   ├── provider-usage.auth.ts  # Credential resolution for all providers
│   ├── provider-usage.fetch.claude.ts  # Anthropic usage tracking
│   └── provider-usage.types.ts # UsageProviderId type
├── memory/
│   └── manager.ts              # Vector + BM25 hybrid memory search
├── sessions/
│   ├── transcript-events.ts    # Session update listeners
│   └── input-provenance.ts     # Message origin tracking
├── telegram/                   # Telegram channel
├── discord/                    # Discord channel
├── slack/                      # Slack channel
├── signal/                     # Signal channel
├── imessage/                   # iMessage channel
├── web/                        # Web channel
├── plugins/
│   └── hooks.ts                # Plugin hook system
├── config/
│   └── sessions.ts             # Session metadata
└── extensions/                 # External extensions (msteams, matrix, zalo, voice-call, etc.)
```

---

## LLM Prompt Pipeline (Complete Flow)

```
1. Message arrives via channel (Telegram/WhatsApp/etc.) or gateway WebSocket/HTTP
       │
2. dispatchInboundMessage()              — src/auto-reply/dispatch.ts
       │
3. getReplyFromConfig()                  — src/auto-reply/reply/get-reply.ts
   │  (media understanding, session init, directive resolution, model selection)
       │
4. runReplyAgent()                       — src/auto-reply/reply/agent-runner.ts
   │  (streaming setup, typing indicators, memory flush)
       │
5. runAgentTurnWithFallback()            — src/auto-reply/reply/agent-runner-execution.ts
   │  (model fallback chain)
       │
6. runEmbeddedPiAgent()                  — src/agents/pi-embedded-runner/run.ts
   │  (auth profile rotation, context overflow recovery, compaction retries)
   │  - Resolves provider/model via resolveModel()
   │  - Gets API key via getApiKeyForModel() with profile rotation
   │  - Runs before_model_resolve and before_agent_start hooks
   │  - Main loop: attempts runEmbeddedAttempt(), handles errors
       │
7. runEmbeddedAttempt()                  — src/agents/pi-embedded-runner/run/attempt.ts
   │  - Creates tools via createOpenClawCodingTools()
   │  - Builds system prompt via buildEmbeddedSystemPrompt() → buildAgentSystemPrompt()
   │  - Creates agent session via createAgentSession() from pi-coding-agent
   │  - Applies system prompt override: applySystemPromptOverrideToSession()
   │  - Assigns stream function: streamSimple (or createOllamaStreamFn for Ollama)
   │  - Sanitizes session history, validates turns, limits history
   │  - Detects/loads images for vision models
   │  - Runs hooks: before_prompt_build, llm_input
       │
8. activeSession.prompt(effectivePrompt, { images })    ← THE ACTUAL LLM CALL
   │  via streamSimple() from @mariozechner/pi-ai
       │
9. Response streamed via subscribeEmbeddedPiSession()
   │  - message_start/update/end events
   │  - tool_execution_start/update/end events
   │  - auto_compaction_start/end events
       │
10. Text extracted via extractAssistantText()
    │  - stripMinimaxToolCallXml()
    │  - stripDowngradedToolCallText()
    │  - stripThinkingTagsFromText()
       │
11. Payloads built via buildEmbeddedRunPayloads()
    │  - Deduplication, directive parsing, media URL handling
       │
12. Response delivered back to channel
```

---

## System Prompt Construction

`buildAgentSystemPrompt()` in `src/agents/system-prompt.ts` (lines 185-656) assembles these sections:

| # | Section | Condition |
|---|---------|-----------|
| 1 | Identity | Always ("You are a personal assistant running inside OpenClaw.") |
| 2 | Tooling | Always (tool names + one-line summaries) |
| 3 | Tool Call Style | Always |
| 4 | Safety | Always (anti-power-seeking guardrails) |
| 5 | CLI Reference | Always |
| 6 | Skills | promptMode="full" + skills available |
| 7 | Memory Recall | promptMode="full" + memory tools available |
| 8 | Self-Update | promptMode="full" |
| 9 | Model Aliases | promptMode="full" + aliases configured |
| 10 | Workspace | Always |
| 11 | Documentation | Always |
| 12 | Sandbox | If sandboxed |
| 13 | User Identity | promptMode="full" + owner numbers |
| 14 | Time | If timezone known |
| 15 | Reply Tags | promptMode="full" |
| 16 | Messaging | promptMode="full" |
| 17 | Voice/TTS | If TTS hint provided |
| 18 | llms.txt Discovery | Always |
| 19 | Project Context | Bootstrap files (AGENTS.md, SOUL.md, TOOLS.md, etc.) |
| 20 | Silent Replies | Always |
| 21 | Heartbeats | Always |
| 22 | Reasoning Format | If model supports reasoning tags |
| 23 | Runtime | Always (host, OS, node, model, capabilities, thinking level) |

**Prompt Modes:**
- `"full"` — All sections (main agent)
- `"minimal"` — Omits Skills, Memory, Self-Update, Model Aliases, User Identity, Reply Tags, Messaging, Silent Replies, Heartbeats (subagents)
- `"none"` — Single identity line only

**Bootstrap File Injection:**
Files like AGENTS.md, SOUL.md, TOOLS.md, IDENTITY.md, USER.md, MEMORY.md are injected into the system prompt under "Project Context". Truncated at `bootstrapMaxChars` (default 20K per file) and `bootstrapTotalMaxChars` (default 150K total).

---

## Key Architectural Patterns

### Auth Profile Rotation
Multiple API key profiles per provider. Auto-rotates on rate limit/auth errors. Cooldown tracking per profile. Configured in `agents.auth`.

### Context Overflow Recovery
Up to 3 auto-compaction attempts → tool result truncation → user-facing error. Compaction summarizes conversation history, reducing tokens by 30-50%.

### Model Fallback
`FailoverError` triggers next model in the configured fallback chain. Thinking level downgrades when a model doesn't support the requested level.

### Session Persistence
JSONL transcript files. Format:
```jsonl
{"type": "session", "version": 4, "id": "...", "timestamp": "...", "cwd": "..."}
{"role": "user", "content": "..."}
{"role": "assistant", "content": [...]}
{"tool_use": {"id": "...", "name": "bash", "input": {...}}}
{"tool_result": {"tool_use_id": "...", "content": "..."}}
```

### Memory System
Vector + BM25 hybrid search via `memory_search`/`memory_get` tools. Multi-provider embeddings (OpenAI, Gemini, Voyage, Local LLM). Temporal decay scoring. MMR reranking.

### Routing
Multi-tier binding resolution (priority order): peer → peer.parent → guild+roles → guild → team → account → channel → default. Session key format: `agent:[agentId]:[scope]`.

### Gateway
WebSocket + HTTP server. OpenAI-compatible `/v1/chat/completions` endpoint. Protocol negotiation, device signature verification, nonce validation.

### Plugin Hooks
Plugins intercept and modify behavior via hooks:
- `before_model_resolve` — Override provider/model selection
- `before_prompt_build` — Inject context before prompt construction
- `before_agent_start` — Legacy context injection
- `llm_input` — Fire-and-forget, receives full payload (system prompt, prompt, history)
- `llm_output` — Receives LLM response
- `agent_end` — Post-processing
- `agent:bootstrap` — Mutate bootstrap files before injection

### Tools
Created by `createOpenClawCodingTools()` in `src/agents/pi-tools.ts`:
- File ops: read, write, edit, apply_patch, grep, find, ls
- Execution: exec, process
- Web: web_search, web_fetch, browser, canvas
- Scheduling: cron
- Messaging: message, sessions_send, subagents
- Memory: memory_search, memory_get
- Media: image

Tool access controlled by per-channel/per-agent/per-group policy pipeline.

### Provider Configuration
Auth resolved in priority order: env vars → config file → auth profile store → legacy auth.json. Supported providers defined in `UsageProviderId`: anthropic, github-copilot, google-gemini-cli, google-antigravity, minimax, openai-codex, xiaomi, zai.

### Thinking/Reasoning
ThinkLevel: off | minimal | low | medium | high | xhigh
ReasoningLevel: off | on | stream
VerboseLevel: off | on | full
Provider-specific: Z.AI uses binary off/on only. XHIGH limited to OpenAI GPT-5.x.

---

## Extension Points for Patches

These are the most promising hook points for adding capabilities without modifying upstream:

1. **Plugin Hooks** (`src/plugins/hooks.ts`) — The official extension mechanism. Hooks can intercept model resolution, prompt construction, LLM input/output, and bootstrap file injection.

2. **Bootstrap Files** — Files like SOUL.md, TOOLS.md, AGENTS.md in the workspace are automatically injected into every system prompt. Adding/modifying these changes agent behavior.

3. **Extensions Directory** — `extensions/*` contains external extensions (msteams, matrix, zalo, voice-call). New extensions can be added here.

4. **Custom Tools** — Tools can be provided via `customTools` parameter to `createAgentSession()`.

5. **Config Overrides** — `~/.openclaw/config.json` controls model selection, tool policies, routing bindings, memory settings.

6. **Models.json** — `~/.openclaw/models.json` defines available models. Custom providers can be added with `mode: "merge"`.

---

## Supported Providers

| Provider | API Type | Auth Method |
|----------|----------|-------------|
| Anthropic | anthropic | API key / OAuth |
| OpenAI | openai-responses | API key |
| Google Gemini | google | API key / OAuth |
| Ollama | ollama | None (local) |
| GitHub Copilot | openai-responses | Device OAuth → token exchange |
| Qwen Portal | openai | OAuth refresh |
| Z.AI | zai | API key |
| Minimax | minimax | API key |
| Xiaomi | xiaomi | API key |
| AWS Bedrock | bedrock | AWS credentials |
| Custom | any | Configurable |

---

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `@mariozechner/pi-agent-core` | Core agent types, session management |
| `@mariozechner/pi-ai` | LLM API communication (`streamSimple()`) |
| `@mariozechner/pi-coding-agent` | Agent session creation, tool execution |
| `@mariozechner/pi-tui` | Terminal UI |
| grammy | Telegram bot framework |
| @slack/bolt | Slack app framework |
| @whiskeysockets/baileys | WhatsApp Web API |
| discord-api-types | Discord API |
| express | HTTP server |
| ws | WebSocket server |
| playwright-core | Browser automation |
| sharp | Image processing |

---

*Generated from codebase analysis on 2026-02-17*
