import { spawn, type ChildProcess } from "node:child_process";
import { which } from "../util/which.ts";
import { cleanEnv } from "../util/clean-env.ts";
import type {
  BackendConfig,
  ChatChunk,
  CliBackend,
  CliHandle,
  ModelInfo,
  SpawnRequest,
} from "../types.ts";

// Map gateway sessionId -> codex thread_id for session resume
const sessionMapping = new Map<string, string>();

const MAX_RETRIES = 2; // up to 3 total attempts

/**
 * Spawn codex once and return an async iterable of ChatChunks.
 * Captures stderr for logging. Self-contained — each call is independent.
 */
function spawnCodex(
  command: string,
  args: string[],
  sessionId: string,
): { output: AsyncIterable<ChatChunk>; child: ChildProcess } {
  const child = spawn(command, args, {
    cwd: process.cwd(),
    env: cleanEnv("codex"),
    stdio: ["ignore", "pipe", "pipe"],
  });

  let lineBuf = "";

  const chunkQueue: ChatChunk[] = [];
  let done = false;
  let waitResolve: (() => void) | null = null;

  function enqueue(chunk: ChatChunk): void {
    chunkQueue.push(chunk);
    if (waitResolve) {
      const r = waitResolve;
      waitResolve = null;
      r();
    }
  }

  function finish(): void {
    done = true;
    if (waitResolve) {
      const r = waitResolve;
      waitResolve = null;
      r();
    }
  }

  function processLine(trimmed: string): void {
    let event: Record<string, unknown>;
    try {
      event = JSON.parse(trimmed);
    } catch {
      return;
    }

    const type = event.type as string;

    if (type === "thread.started") {
      const threadId = event.thread_id as string;
      if (threadId) {
        sessionMapping.set(sessionId, threadId);
      }
    } else if (type === "item.completed") {
      const item = event.item as Record<string, unknown>;
      if (
        item?.type === "agent_message" &&
        typeof item.text === "string"
      ) {
        // Strip Codex conversation markers like [[reply_to_current]]
        const text = item.text.replace(/\[\[[\w_]+\]\]\s*/g, "").trim();
        if (text) enqueue({ type: "content", content: text });
      }
    } else if (type === "turn.completed") {
      const usage = event.usage as Record<string, number> | undefined;
      enqueue({
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
      });
    } else if (type === "turn.failed") {
      const error = event.error as
        | Record<string, string>
        | string
        | undefined;
      const message =
        typeof error === "string"
          ? error
          : error?.message ?? "Turn failed";
      enqueue({ type: "error", error: message });
    } else if (type === "error") {
      enqueue({
        type: "error",
        error: (event.message as string) ?? "Unknown codex error",
      });
    }
  }

  // Log stderr (Codex prints "Reconnecting..." messages here)
  child.stderr?.on("data", (data: Buffer) => {
    for (const line of data.toString("utf-8").split("\n")) {
      const trimmed = line.trim();
      if (trimmed) console.log(`[codex:stderr] ${trimmed}`);
    }
  });

  child.stdout!.on("data", (data: Buffer) => {
    lineBuf += data.toString("utf-8");
    const lines = lineBuf.split("\n");
    lineBuf = lines.pop() ?? "";
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed) processLine(trimmed);
    }
  });

  child.on("close", (exitCode) => {
    if (lineBuf.trim()) {
      processLine(lineBuf.trim());
      lineBuf = "";
    }
    if (exitCode !== 0) {
      enqueue({
        type: "error",
        error: `CLI exited with code ${exitCode}`,
      });
    }
    finish();
  });

  const output: AsyncIterable<ChatChunk> = {
    [Symbol.asyncIterator]() {
      return {
        async next(): Promise<IteratorResult<ChatChunk>> {
          while (true) {
            if (chunkQueue.length > 0) {
              return { value: chunkQueue.shift()!, done: false };
            }
            if (done) {
              return {
                value: undefined as unknown as ChatChunk,
                done: true,
              };
            }
            await new Promise<void>((resolve) => {
              waitResolve = resolve;
            });
          }
        },
      };
    },
  };

  return { output, child };
}

export function createCodexBackend(config: BackendConfig): CliBackend {
  const command = config.command || "codex";

  return {
    id: "codex",
    displayName: "Codex CLI",

    async detect(): Promise<boolean> {
      return which(command) !== null;
    },

    listModels(): ModelInfo[] {
      return [
        {
          id: "codex/gpt-5.3-codex",
          name: "GPT-5.3 Codex (via Codex CLI)",
          owned_by: "openai",
        },
        {
          id: "codex/o3",
          name: "O3 (via Codex CLI)",
          owned_by: "openai",
        },
        {
          id: "codex/o4-mini",
          name: "O4 Mini (via Codex CLI)",
          owned_by: "openai",
        },
      ];
    },

    run(req: SpawnRequest): CliHandle {
      // Build args once — shared across retries
      const codexThreadId = sessionMapping.get(req.sessionId);
      const isResume = !req.isNewConversation && codexThreadId;

      const args: string[] = [];

      if (isResume) {
        args.push("exec", "resume");
      } else {
        args.push("exec");
      }

      args.push("--json", "--color", "never", "--skip-git-repo-check");

      if (req.model) {
        args.push("-m", req.model);
      }

      if (req.systemPrompt) {
        const escaped = req.systemPrompt
          .replace(/\\/g, "\\\\")
          .replace(/"/g, '\\"');
        args.push("-c", `developer_instructions="${escaped}"`);
      }

      if (req.tools) {
        args.push("--dangerously-bypass-approvals-and-sandbox");
      } else {
        args.push("--sandbox", "read-only");
      }

      args.push("-C", process.cwd());

      const lastUserMsg = [...req.messages]
        .reverse()
        .find((m) => m.role === "user");
      const rawContent = lastUserMsg?.content;
      const prompt =
        typeof rawContent === "string"
          ? rawContent
          : Array.isArray(rawContent)
            ? rawContent
                .filter(
                  (p: unknown) =>
                    (p as Record<string, unknown>)?.type === "text",
                )
                .map((p: unknown) => (p as Record<string, string>).text)
                .join("\n")
            : "";

      if (isResume) {
        args.push("--", codexThreadId, prompt);
      } else {
        args.push("--", prompt);
      }

      // Retry state
      let killed = false;
      let currentChild: ChildProcess | null = null;

      // Outer async iterable with transparent retry
      const output: AsyncIterable<ChatChunk> = {
        [Symbol.asyncIterator]() {
          let attempt = 0;
          let gotContent = false;
          let inner: AsyncIterator<ChatChunk> | null = null;

          return {
            async next(): Promise<IteratorResult<ChatChunk>> {
              while (true) {
                if (killed) {
                  return {
                    value: undefined as unknown as ChatChunk,
                    done: true,
                  };
                }

                // Spawn on first call or after retry
                if (!inner) {
                  const label =
                    attempt === 0
                      ? `attempt 1/${MAX_RETRIES + 1}`
                      : `retry ${attempt}/${MAX_RETRIES}`;
                  console.log(`[codex] Spawning (${label})`);
                  const spawned = spawnCodex(command, args, req.sessionId);
                  currentChild = spawned.child;
                  inner = spawned.output[Symbol.asyncIterator]();

                  // Wire abort signal to current child
                  if (req.signal) {
                    if (req.signal.aborted) {
                      killed = true;
                      currentChild.kill("SIGTERM");
                      return {
                        value: undefined as unknown as ChatChunk,
                        done: true,
                      };
                    }
                    const child = currentChild;
                    req.signal.addEventListener(
                      "abort",
                      () => {
                        killed = true;
                        child.kill("SIGTERM");
                      },
                      { once: true },
                    );
                  }
                }

                const result = await inner.next();

                // Inner iterable exhausted — we're done
                if (result.done) {
                  return result;
                }

                const chunk = result.value;

                // Track whether we've sent any real content
                if (chunk.type === "content") {
                  gotContent = true;
                  return { value: chunk, done: false };
                }

                // Success — pass through
                if (chunk.type === "done") {
                  return { value: chunk, done: false };
                }

                // Error — retry if no content sent yet and retries remain
                if (
                  chunk.type === "error" &&
                  !gotContent &&
                  !killed &&
                  attempt < MAX_RETRIES
                ) {
                  attempt++;
                  const delay = 1000 * attempt;
                  console.log(
                    `[codex] Retry ${attempt}/${MAX_RETRIES} in ${delay}ms: ${chunk.error}`,
                  );
                  currentChild?.kill("SIGTERM");
                  await new Promise((r) => setTimeout(r, delay));
                  inner = null; // will respawn on next loop
                  continue;
                }

                // Non-retryable error or content already sent
                if (chunk.type === "error" && attempt > 0) {
                  chunk.error = `${chunk.error} (after ${attempt + 1} attempts)`;
                }
                return { value: chunk, done: false };
              }
            },
          };
        },
      };

      return {
        output,
        kill() {
          killed = true;
          currentChild?.kill("SIGTERM");
        },
      };
    },
  };
}
