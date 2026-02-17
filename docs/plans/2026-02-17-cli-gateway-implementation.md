# cli-gateway Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a standalone OpenAI-compatible HTTP proxy that translates `/v1/chat/completions` requests into CLI subprocess calls (`claude -p`), enabling subscription-based CLI tools to serve as LLM endpoints.

**Architecture:** Zero-dependency Node.js HTTP server. Pluggable backend interface — each CLI tool (claude, codex, gemini) is a backend module. Stateful sessions where Claude Code owns conversation history via `--resume`. Streaming via NDJSON-to-SSE translation.

**Tech Stack:** Node.js 22+ with `--experimental-strip-types` (native TypeScript, no build step), zero npm dependencies, pure `node:http`, `node:child_process`, `node:crypto`.

---

### Task 1: Project Scaffolding

**Files:**
- Create: `cli-gateway/package.json`
- Create: `cli-gateway/tsconfig.json`
- Create: `cli-gateway/config.json`
- Create: `cli-gateway/.gitignore`

**Step 1: Create package.json**

```json
{
  "name": "cli-gateway",
  "version": "0.1.0",
  "description": "OpenAI-compatible proxy that translates API requests to CLI subprocess calls",
  "type": "module",
  "engines": { "node": ">=22" },
  "scripts": {
    "start": "node --experimental-strip-types src/server.ts",
    "dev": "node --experimental-strip-types --watch src/server.ts"
  },
  "license": "MIT"
}
```

**Step 2: Create tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ES2024",
    "module": "nodenext",
    "moduleResolution": "nodenext",
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true,
    "isolatedModules": true,
    "verbatimModuleSyntax": true,
    "erasableSyntaxOnly": true
  },
  "include": ["src"]
}
```

Note: `erasableSyntaxOnly` is required for `--experimental-strip-types` — it disallows `enum` and `namespace` which need compilation.

**Step 3: Create config.json**

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

**Step 4: Create .gitignore**

```
node_modules/
*.log
```

**Step 5: Commit**

```bash
git add cli-gateway/package.json cli-gateway/tsconfig.json cli-gateway/config.json cli-gateway/.gitignore
git commit -m "feat: scaffold cli-gateway project"
```

---

### Task 2: Types

**Files:**
- Create: `cli-gateway/src/types.ts`

**Step 1: Write all shared types**

This file defines:
- `CliBackend` interface (the backend contract)
- `SpawnRequest` (what a backend receives to spawn a process)
- `ChatChunk` (parsed output from a CLI process)
- `OpenAIMessage`, `OpenAIChatRequest`, `OpenAIChatChunkResponse` (OpenAI wire types)
- `GatewayConfig`, `BackendConfig` (config file shape)
- `SessionEntry` (session map entry)

```typescript
import type { ChildProcess } from "node:child_process";

// --- Backend contract ---

export interface CliBackend {
  id: string;
  displayName: string;
  detect(): Promise<boolean>;
  listModels(): ModelInfo[];
  spawn(request: SpawnRequest): ChildProcess;
  parseOutput(stdout: NodeJS.ReadableStream): AsyncIterable<ChatChunk>;
}

export interface SpawnRequest {
  model: string;
  messages: OpenAIMessage[];
  systemPrompt: string | undefined;
  temperature: number | undefined;
  maxTokens: number | undefined;
  sessionId: string;
  isNewConversation: boolean;
  tools: boolean;
  signal: AbortSignal;
}

export interface ModelInfo {
  id: string;
  name: string;
  owned_by: string;
}

// --- Parsed output from CLI ---

export interface ChatChunk {
  type: "content" | "done" | "error";
  content?: string;
  finishReason?: string;
  usage?: UsageInfo;
  error?: string;
  sessionId?: string;
}

export interface UsageInfo {
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
}

// --- OpenAI wire types ---

export interface OpenAIMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  name?: string;
}

export interface OpenAIChatRequest {
  model: string;
  messages: OpenAIMessage[];
  stream?: boolean;
  temperature?: number;
  max_tokens?: number;
}

export interface OpenAIChatChunkResponse {
  id: string;
  object: "chat.completion.chunk";
  created: number;
  model: string;
  choices: Array<{
    index: number;
    delta: {
      role?: string;
      content?: string;
    };
    finish_reason: string | null;
  }>;
  usage?: UsageInfo;
}

export interface OpenAIChatResponse {
  id: string;
  object: "chat.completion";
  created: number;
  model: string;
  choices: Array<{
    index: number;
    message: {
      role: string;
      content: string;
    };
    finish_reason: string;
  }>;
  usage: UsageInfo;
}

// --- Config ---

export interface GatewayConfig {
  port: number;
  backends: Record<string, BackendConfig>;
}

export interface BackendConfig {
  enabled: boolean;
  command: string;
  defaultModel: string;
  tools: boolean;
  sessionContinuity: boolean;
}

// --- Session map ---

export interface SessionEntry {
  sessionId: string;
  backendId: string;
  createdAt: number;
  lastUsedAt: number;
  messageCount: number;
}
```

**Step 2: Verify TypeScript compiles**

Run: `cd cli-gateway && npx tsc --noEmit`
Expected: No errors

**Step 3: Commit**

```bash
git add cli-gateway/src/types.ts
git commit -m "feat: add shared type definitions"
```

---

### Task 3: Utility — CLI Detection

**Files:**
- Create: `cli-gateway/src/util/which.ts`

**Step 1: Write the which utility**

Uses `child_process.execFileSync` to check if a command exists in PATH.

```typescript
import { execFileSync } from "node:child_process";

export function which(command: string): string | null {
  try {
    const result = execFileSync("which", [command], {
      encoding: "utf-8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    return result.trim() || null;
  } catch {
    return null;
  }
}
```

**Step 2: Test manually**

Run: `node --experimental-strip-types -e "import { which } from './cli-gateway/src/util/which.ts'; console.log('claude:', which('claude')); console.log('nonexistent:', which('nonexistent'));"`
Expected: claude path printed, nonexistent shows null

**Step 3: Commit**

```bash
git add cli-gateway/src/util/which.ts
git commit -m "feat: add CLI detection utility"
```

---

### Task 4: OpenAI Format Helpers

**Files:**
- Create: `cli-gateway/src/openai-format.ts`

**Step 1: Write OpenAI response formatting functions**

```typescript
import { randomUUID } from "node:crypto";
import type { OpenAIChatChunkResponse, OpenAIChatResponse, UsageInfo } from "./types.ts";

export function createChunkId(): string {
  return `chatcmpl-${randomUUID().replace(/-/g, "").slice(0, 24)}`;
}

export function formatSSEChunk(
  id: string,
  model: string,
  content: string,
  finishReason: string | null = null,
  usage?: UsageInfo,
): string {
  const chunk: OpenAIChatChunkResponse = {
    id,
    object: "chat.completion.chunk",
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [
      {
        index: 0,
        delta: finishReason ? {} : { content },
        finish_reason: finishReason,
      },
    ],
    ...(usage ? { usage } : {}),
  };
  return `data: ${JSON.stringify(chunk)}\n\n`;
}

export function formatSSERoleChunk(id: string, model: string): string {
  const chunk: OpenAIChatChunkResponse = {
    id,
    object: "chat.completion.chunk",
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{ index: 0, delta: { role: "assistant" }, finish_reason: null }],
  };
  return `data: ${JSON.stringify(chunk)}\n\n`;
}

export function formatSSEDone(): string {
  return "data: [DONE]\n\n";
}

export function formatNonStreamingResponse(
  id: string,
  model: string,
  content: string,
  usage: UsageInfo,
): OpenAIChatResponse {
  return {
    id,
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [
      {
        index: 0,
        message: { role: "assistant", content },
        finish_reason: "stop",
      },
    ],
    usage,
  };
}
```

**Step 2: Commit**

```bash
git add cli-gateway/src/openai-format.ts
git commit -m "feat: add OpenAI SSE response formatting"
```

---

### Task 5: Session Map

**Files:**
- Create: `cli-gateway/src/session-map.ts`

**Step 1: Write session ID derivation and tracking**

```typescript
import { createHash, randomUUID } from "node:crypto";
import type { SessionEntry } from "./types.ts";

const sessions = new Map<string, SessionEntry>();
const SESSION_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours

export function resolveSessionId(
  headerSessionId: string | undefined,
  systemPrompt: string | undefined,
  firstUserMessage: string | undefined,
): string {
  if (headerSessionId) return headerSessionId;

  // Derive deterministic session ID from content
  const seed = `${systemPrompt ?? ""}::${firstUserMessage ?? ""}`;
  const hash = createHash("sha256").update(seed).digest("hex").slice(0, 32);
  // Format as UUID for claude --session-id compatibility
  return [
    hash.slice(0, 8),
    hash.slice(8, 12),
    hash.slice(12, 16),
    hash.slice(16, 20),
    hash.slice(20, 32),
  ].join("-");
}

export function isNewConversation(
  sessionId: string,
  messageCount: number,
): boolean {
  const entry = sessions.get(sessionId);
  if (!entry) return true;
  // If client sends fewer messages than we've seen, assume fresh start
  if (messageCount <= 2) return !sessions.has(sessionId);
  return false;
}

export function trackSession(
  sessionId: string,
  backendId: string,
  messageCount: number,
): void {
  const existing = sessions.get(sessionId);
  sessions.set(sessionId, {
    sessionId,
    backendId,
    createdAt: existing?.createdAt ?? Date.now(),
    lastUsedAt: Date.now(),
    messageCount,
  });
}

export function pruneExpiredSessions(): void {
  const now = Date.now();
  for (const [id, entry] of sessions) {
    if (now - entry.lastUsedAt > SESSION_TTL_MS) {
      sessions.delete(id);
    }
  }
}

// Run pruning every hour
setInterval(pruneExpiredSessions, 60 * 60 * 1000).unref();
```

**Step 2: Commit**

```bash
git add cli-gateway/src/session-map.ts
git commit -m "feat: add session ID derivation and tracking"
```

---

### Task 6: Claude Code Backend

**Files:**
- Create: `cli-gateway/src/backends/claude-code.ts`

**Step 1: Write the Claude Code backend**

This is the core file — it spawns `claude -p` and parses `stream-json` output into `ChatChunk` events.

```typescript
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { which } from "../util/which.ts";
import type {
  BackendConfig,
  ChatChunk,
  CliBackend,
  ModelInfo,
  SpawnRequest,
} from "../types.ts";

export function createClaudeCodeBackend(config: BackendConfig): CliBackend {
  const command = config.command || "claude";

  return {
    id: "claude-code",
    displayName: "Claude Code",

    async detect(): Promise<boolean> {
      return which(command) !== null;
    },

    listModels(): ModelInfo[] {
      return [
        {
          id: "claude-code/opus",
          name: "Claude Opus (via Claude Code)",
          owned_by: "anthropic",
        },
        {
          id: "claude-code/sonnet",
          name: "Claude Sonnet (via Claude Code)",
          owned_by: "anthropic",
        },
        {
          id: "claude-code/haiku",
          name: "Claude Haiku (via Claude Code)",
          owned_by: "anthropic",
        },
      ];
    },

    spawn(req: SpawnRequest) {
      const args = [
        "-p",
        "--output-format",
        "stream-json",
        "--model",
        req.model,
      ];

      if (req.systemPrompt) {
        args.push("--system-prompt", req.systemPrompt);
      }

      if (req.isNewConversation) {
        args.push("--session-id", req.sessionId);
      } else {
        args.push("--resume", req.sessionId);
      }

      if (!req.tools) {
        args.push("--tools", "");
      }

      // Extract the last user message as the prompt
      const lastUserMsg = [...req.messages]
        .reverse()
        .find((m) => m.role === "user");
      const prompt = lastUserMsg?.content ?? "";

      args.push(prompt);

      return spawn(command, args, {
        stdio: ["ignore", "pipe", "pipe"],
        signal: req.signal,
      });
    },

    async *parseOutput(stdout: NodeJS.ReadableStream): AsyncIterable<ChatChunk> {
      const rl = createInterface({ input: stdout, crlfDelay: Infinity });

      for await (const line of rl) {
        const trimmed = line.trim();
        if (!trimmed) continue;

        let event: Record<string, unknown>;
        try {
          event = JSON.parse(trimmed);
        } catch {
          continue; // skip unparseable lines
        }

        const type = event.type as string;

        if (type === "assistant") {
          // Extract text content from the assistant message
          const message = event.message as Record<string, unknown>;
          const content = message?.content as Array<Record<string, unknown>>;
          if (Array.isArray(content)) {
            for (const block of content) {
              if (block.type === "text" && typeof block.text === "string") {
                yield { type: "content", content: block.text };
              }
            }
          }
        } else if (type === "result") {
          const subtype = event.subtype as string;
          const usage = event.usage as Record<string, number> | undefined;
          const sessionId = event.session_id as string | undefined;

          if (subtype === "success") {
            yield {
              type: "done",
              finishReason: "stop",
              sessionId,
              usage: usage
                ? {
                    prompt_tokens: usage.input_tokens ?? 0,
                    completion_tokens: usage.output_tokens ?? 0,
                    total_tokens:
                      (usage.input_tokens ?? 0) + (usage.output_tokens ?? 0),
                  }
                : undefined,
            };
          } else {
            yield {
              type: "error",
              error: (event.result as string) ?? "Unknown error from CLI",
            };
          }
        }
        // system events (init, hook_started, hook_response) — skip
      }
    },
  };
}
```

**Step 2: Commit**

```bash
git add cli-gateway/src/backends/claude-code.ts
git commit -m "feat: add Claude Code backend (spawn + stream-json parsing)"
```

---

### Task 7: Backend Registry

**Files:**
- Create: `cli-gateway/src/backends/index.ts`

**Step 1: Write the backend registry**

```typescript
import type { CliBackend, GatewayConfig } from "../types.ts";
import { createClaudeCodeBackend } from "./claude-code.ts";

const backendFactories: Record<
  string,
  (config: GatewayConfig["backends"][string]) => CliBackend
> = {
  "claude-code": createClaudeCodeBackend,
};

const activeBackends = new Map<string, CliBackend>();

export async function initBackends(
  config: GatewayConfig,
): Promise<Map<string, CliBackend>> {
  activeBackends.clear();

  for (const [id, backendConfig] of Object.entries(config.backends)) {
    if (!backendConfig.enabled) continue;

    const factory = backendFactories[id];
    if (!factory) {
      console.warn(`Unknown backend: ${id}, skipping`);
      continue;
    }

    const backend = factory(backendConfig);
    const detected = await backend.detect();

    if (detected) {
      activeBackends.set(id, backend);
      console.log(`Backend '${backend.displayName}' detected and enabled`);
    } else {
      console.warn(
        `Backend '${backend.displayName}' not detected (CLI not found), skipping`,
      );
    }
  }

  return activeBackends;
}

export function getBackend(backendId: string): CliBackend | undefined {
  return activeBackends.get(backendId);
}

export function getAllBackends(): Map<string, CliBackend> {
  return activeBackends;
}

export function parseModelId(model: string): {
  backendId: string;
  modelName: string;
} {
  const slashIndex = model.indexOf("/");
  if (slashIndex === -1) {
    return { backendId: model, modelName: "" };
  }
  return {
    backendId: model.slice(0, slashIndex),
    modelName: model.slice(slashIndex + 1),
  };
}
```

**Step 2: Commit**

```bash
git add cli-gateway/src/backends/index.ts
git commit -m "feat: add backend registry with auto-detection"
```

---

### Task 8: HTTP Server

**Files:**
- Create: `cli-gateway/src/server.ts`

**Step 1: Write the HTTP server with all three endpoints**

This is the main entry point. Handles `/v1/models`, `/v1/chat/completions`, and `/health`.

```typescript
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  GatewayConfig,
  OpenAIChatRequest,
  OpenAIMessage,
} from "./types.ts";
import {
  createChunkId,
  formatSSEChunk,
  formatSSERoleChunk,
  formatSSEDone,
  formatNonStreamingResponse,
} from "./openai-format.ts";
import {
  resolveSessionId,
  isNewConversation,
  trackSession,
} from "./session-map.ts";
import {
  initBackends,
  getBackend,
  getAllBackends,
  parseModelId,
} from "./backends/index.ts";

const __dirname = dirname(fileURLToPath(import.meta.url));
const configPath = resolve(__dirname, "..", "config.json");
const config: GatewayConfig = JSON.parse(readFileSync(configPath, "utf-8"));

function readBody(req: import("node:http").IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf-8")));
    req.on("error", reject);
  });
}

function jsonResponse(
  res: import("node:http").ServerResponse,
  status: number,
  body: unknown,
): void {
  const json = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(json),
  });
  res.end(json);
}

function errorResponse(
  res: import("node:http").ServerResponse,
  status: number,
  message: string,
  type = "invalid_request_error",
): void {
  jsonResponse(res, status, {
    error: { message, type, code: status },
  });
}

// --- Route: GET /health ---

function handleHealth(
  _req: import("node:http").IncomingMessage,
  res: import("node:http").ServerResponse,
): void {
  const backends = Object.fromEntries(
    [...getAllBackends()].map(([id, b]) => [
      id,
      { displayName: b.displayName, models: b.listModels().length },
    ]),
  );
  jsonResponse(res, 200, { status: "ok", backends });
}

// --- Route: GET /v1/models ---

function handleModels(
  _req: import("node:http").IncomingMessage,
  res: import("node:http").ServerResponse,
): void {
  const models = [...getAllBackends().values()].flatMap((b) =>
    b.listModels().map((m) => ({
      id: m.id,
      object: "model" as const,
      created: Math.floor(Date.now() / 1000),
      owned_by: m.owned_by,
    })),
  );
  jsonResponse(res, 200, { object: "list", data: models });
}

// --- Route: POST /v1/chat/completions ---

async function handleChatCompletions(
  req: import("node:http").IncomingMessage,
  res: import("node:http").ServerResponse,
): Promise<void> {
  let body: OpenAIChatRequest;
  try {
    body = JSON.parse(await readBody(req));
  } catch {
    return errorResponse(res, 400, "Invalid JSON body");
  }

  if (!body.model) {
    return errorResponse(res, 400, "Missing required field: model");
  }
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return errorResponse(res, 400, "Missing required field: messages");
  }

  const { backendId, modelName } = parseModelId(body.model);
  const backend = getBackend(backendId);

  if (!backend) {
    return errorResponse(
      res,
      404,
      `Backend '${backendId}' not found. Available: ${[...getAllBackends().keys()].join(", ")}`,
    );
  }

  // Extract system prompt from messages
  const systemMessages = body.messages.filter(
    (m: OpenAIMessage) => m.role === "system",
  );
  const systemPrompt = systemMessages.length
    ? systemMessages.map((m: OpenAIMessage) => m.content).join("\n")
    : undefined;

  // Session management
  const headerSessionId = req.headers["x-session-id"] as string | undefined;
  const firstUserMsg = body.messages.find(
    (m: OpenAIMessage) => m.role === "user",
  );
  const sessionId = resolveSessionId(
    headerSessionId,
    systemPrompt,
    firstUserMsg?.content,
  );
  const isNew = isNewConversation(sessionId, body.messages.length);

  // Abort controller for cancellation
  const ac = new AbortController();
  req.on("close", () => ac.abort());

  // Spawn CLI process
  const child = backend.spawn({
    model: modelName || config.backends[backendId]?.defaultModel || "",
    messages: body.messages,
    systemPrompt,
    temperature: body.temperature,
    maxTokens: body.max_tokens,
    sessionId,
    isNewConversation: isNew,
    tools: config.backends[backendId]?.tools ?? false,
    signal: ac.signal,
  });

  // Collect stderr for error reporting
  let stderr = "";
  child.stderr?.on("data", (chunk: Buffer) => {
    stderr += chunk.toString();
  });

  if (!child.stdout) {
    return errorResponse(res, 500, "Failed to spawn CLI process");
  }

  const chunkId = createChunkId();
  const modelStr = body.model;

  if (body.stream) {
    // --- Streaming mode ---
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
      "X-Session-Id": sessionId,
    });

    // Send role chunk first
    res.write(formatSSERoleChunk(chunkId, modelStr));

    try {
      for await (const chunk of backend.parseOutput(child.stdout)) {
        if (chunk.type === "content" && chunk.content) {
          res.write(formatSSEChunk(chunkId, modelStr, chunk.content));
        } else if (chunk.type === "done") {
          trackSession(sessionId, backendId, body.messages.length);
          res.write(
            formatSSEChunk(chunkId, modelStr, "", "stop", chunk.usage),
          );
          res.write(formatSSEDone());
        } else if (chunk.type === "error") {
          res.write(
            `data: ${JSON.stringify({ error: { message: chunk.error, type: "server_error" } })}\n\n`,
          );
        }
      }
    } catch (err) {
      if (!ac.signal.aborted) {
        res.write(
          `data: ${JSON.stringify({ error: { message: String(err), type: "server_error" } })}\n\n`,
        );
      }
    }
    res.end();
  } else {
    // --- Non-streaming mode ---
    let fullContent = "";
    let finalUsage = { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 };

    try {
      for await (const chunk of backend.parseOutput(child.stdout)) {
        if (chunk.type === "content" && chunk.content) {
          fullContent += chunk.content;
        } else if (chunk.type === "done") {
          trackSession(sessionId, backendId, body.messages.length);
          if (chunk.usage) finalUsage = chunk.usage;
        } else if (chunk.type === "error") {
          return errorResponse(res, 500, chunk.error ?? "CLI error");
        }
      }
    } catch (err) {
      return errorResponse(res, 500, String(err));
    }

    const response = formatNonStreamingResponse(
      chunkId,
      modelStr,
      fullContent,
      finalUsage,
    );
    (response as Record<string, unknown>)["x_session_id"] = sessionId;
    jsonResponse(res, 200, response);
  }
}

// --- Main ---

async function main(): Promise<void> {
  await initBackends(config);

  const server = createServer(async (req, res) => {
    const url = req.url ?? "";
    const method = req.method ?? "";

    // CORS headers
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.setHeader(
      "Access-Control-Allow-Headers",
      "Content-Type, Authorization, X-Session-Id",
    );

    if (method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }

    try {
      if (url === "/health" && method === "GET") {
        handleHealth(req, res);
      } else if (url === "/v1/models" && method === "GET") {
        handleModels(req, res);
      } else if (url === "/v1/chat/completions" && method === "POST") {
        await handleChatCompletions(req, res);
      } else {
        errorResponse(res, 404, `Not found: ${method} ${url}`);
      }
    } catch (err) {
      console.error("Unhandled error:", err);
      if (!res.headersSent) {
        errorResponse(res, 500, "Internal server error");
      }
    }
  });

  server.listen(config.port, () => {
    console.log(`cli-gateway listening on http://localhost:${config.port}`);
    console.log(`Backends: ${[...getAllBackends().keys()].join(", ") || "none"}`);
  });
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
```

**Step 2: Run the server**

Run: `cd cli-gateway && node --experimental-strip-types src/server.ts`
Expected: "cli-gateway listening on http://localhost:4090" + backend detection messages

**Step 3: Commit**

```bash
git add cli-gateway/src/server.ts
git commit -m "feat: add HTTP server with /v1/models, /v1/chat/completions, /health"
```

---

### Task 9: Smoke Test

**Files:** None (manual verification)

**Step 1: Start the server**

Run: `cd cli-gateway && node --experimental-strip-types src/server.ts &`

**Step 2: Test /health**

Run: `curl -s http://localhost:4090/health | jq .`
Expected: `{"status":"ok","backends":{"claude-code":{"displayName":"Claude Code","models":3}}}`

**Step 3: Test /v1/models**

Run: `curl -s http://localhost:4090/v1/models | jq .`
Expected: List with claude-code/opus, claude-code/sonnet, claude-code/haiku

**Step 4: Test non-streaming chat completion**

Run: `curl -s http://localhost:4090/v1/chat/completions -H "Content-Type: application/json" -d '{"model":"claude-code/sonnet","messages":[{"role":"user","content":"Say hello in exactly 3 words"}]}' | jq .`
Expected: OpenAI-format response with assistant message

**Step 5: Test streaming chat completion**

Run: `curl -s http://localhost:4090/v1/chat/completions -H "Content-Type: application/json" -d '{"model":"claude-code/sonnet","messages":[{"role":"user","content":"Say hello in exactly 3 words"}],"stream":true}'`
Expected: SSE stream with data: chunks, ending with data: [DONE]

**Step 6: Test session continuity**

Run:
```bash
# First message
curl -s http://localhost:4090/v1/chat/completions -H "Content-Type: application/json" -H "X-Session-Id: test-session-001" -d '{"model":"claude-code/sonnet","messages":[{"role":"user","content":"Remember the word: pineapple"}]}' | jq .result

# Follow-up (should remember)
curl -s http://localhost:4090/v1/chat/completions -H "Content-Type: application/json" -H "X-Session-Id: test-session-001" -d '{"model":"claude-code/sonnet","messages":[{"role":"user","content":"What word did I ask you to remember?"}]}' | jq .result
```
Expected: Second response mentions "pineapple"

**Step 7: Kill test server**

Run: `kill %1`

**Step 8: Commit (no code changes — just verification done)**

No commit needed for this task.

---

### Task 10: Setup Script

**Files:**
- Create: `setup.sh` (in repo root, not cli-gateway/)

**Step 1: Write the bootstrap script**

```bash
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

# 5. Start cli-gateway
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/cli-gateway"

echo ""
echo "Starting cli-gateway..."
node --experimental-strip-types src/server.ts &
GATEWAY_PID=$!
sleep 2

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
```

**Step 2: Make executable**

Run: `chmod +x setup.sh`

**Step 3: Commit**

```bash
git add setup.sh
git commit -m "feat: add onboarding setup script"
```

---

### Task 11: README and Initial Push

**Files:**
- Create: `README.md`

**Step 1: Write README**

```markdown
# openclaw-plugins

Plugins and tools for [OpenClaw](https://github.com/nicobailon/openclaw).

## cli-gateway

OpenAI-compatible proxy that translates `/v1/chat/completions` requests into CLI subprocess calls. Use your Claude Code subscription (or Codex, Gemini CLI) as an LLM endpoint for OpenClaw or any OpenAI-compatible client.

### Quick Start

```bash
# Prerequisites: Node.js 22+, Claude Code installed & authenticated
./setup.sh
```

### Manual Start

```bash
cd cli-gateway
node --experimental-strip-types src/server.ts
```

### API

- `GET /health` — Backend availability
- `GET /v1/models` — List available models
- `POST /v1/chat/completions` — Chat completion (streaming & non-streaming)

### Model Names

Format: `backend/model` — e.g., `claude-code/sonnet`, `claude-code/opus`

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

### Session Continuity

Sessions are managed by Claude Code. Pass `X-Session-Id` header for explicit session control, or let the proxy derive one from the conversation.

### Design

See [docs/plans/2026-02-17-cli-gateway-design.md](docs/plans/2026-02-17-cli-gateway-design.md).
```

**Step 2: Commit everything and push**

```bash
git add README.md
git commit -m "docs: add README"
git push -u origin main
```

---

## Execution Order & Dependencies

```
Task 1  (scaffolding)
   ↓
Task 2  (types)
   ↓
Task 3  (which utility)     Task 4  (openai-format)     Task 5  (session-map)
   ↓                              ↓                           ↓
   └──────────────┬───────────────┘───────────────────────────┘
                  ↓
Task 6  (claude-code backend)
                  ↓
Task 7  (backend registry)
                  ↓
Task 8  (HTTP server)
                  ↓
Task 9  (smoke test)
                  ↓
Task 10 (setup script)
                  ↓
Task 11 (README + push)
```

Tasks 3, 4, 5 are independent and can run in parallel.
