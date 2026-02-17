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

  // Run CLI process via backend
  const handle = backend.run({
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
      for await (const chunk of handle.output) {
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
      for await (const chunk of handle.output) {
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
