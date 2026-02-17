import { spawn } from "node:child_process";
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
      // Determine if resuming an existing codex session
      const codexThreadId = sessionMapping.get(req.sessionId);
      const isResume = !req.isNewConversation && codexThreadId;

      const args: string[] = [];

      if (isResume) {
        args.push("exec", "resume");
      } else {
        args.push("exec");
      }

      // Always use JSON output, no color, allow running outside git repos
      args.push("--json", "--color", "never", "--skip-git-repo-check");

      // Model selection
      if (req.model) {
        args.push("-m", req.model);
      }

      // System prompt via config override
      if (req.systemPrompt) {
        const escaped = req.systemPrompt
          .replace(/\\/g, "\\\\")
          .replace(/"/g, '\\"');
        args.push("-c", `developer_instructions="${escaped}"`);
      }

      // Permissions
      if (req.tools) {
        args.push("--dangerously-bypass-approvals-and-sandbox");
      } else {
        args.push("--sandbox", "read-only");
      }

      // Working directory
      args.push("-C", process.cwd());

      // Extract the last user message as the prompt
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

      // For resume: thread_id then prompt; otherwise just the prompt
      if (isResume) {
        args.push("--", codexThreadId, prompt);
      } else {
        args.push("--", prompt);
      }

      const child = spawn(command, args, {
        cwd: process.cwd(),
        env: cleanEnv("codex"),
        stdio: ["ignore", "pipe", "pipe"],
      });

      // Buffer for incomplete lines
      let lineBuf = "";
      let killed = false;
      let codexSessionId = "";

      // Queue of parsed chunks + resolve for the async iterator
      const chunkQueue: ChatChunk[] = [];
      let done = false;
      let waitResolve: (() => void) | null = null;
      let iterError: Error | null = null;

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
            codexSessionId = threadId;
            sessionMapping.set(req.sessionId, threadId);
          }
        } else if (type === "item.completed") {
          const item = event.item as Record<string, unknown>;
          if (
            item?.type === "agent_message" &&
            typeof item.text === "string"
          ) {
            enqueue({ type: "content", content: item.text });
          }
          // Skip reasoning, command_execution, file_change, etc.
        } else if (type === "turn.completed") {
          const usage = event.usage as Record<string, number> | undefined;
          enqueue({
            type: "done",
            finishReason: "stop",
            sessionId: req.sessionId,
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
          const error = event.error as Record<string, string> | string | undefined;
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
        // Skip: turn.started, other event types
      }

      // Handle stdout data
      child.stdout!.on("data", (data: Buffer) => {
        lineBuf += data.toString("utf-8");

        const lines = lineBuf.split("\n");
        lineBuf = lines.pop() ?? "";

        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed) continue;
          processLine(trimmed);
        }
      });

      // Handle process exit
      child.on("close", (exitCode) => {
        // Process any remaining data in the buffer
        if (lineBuf.trim()) {
          processLine(lineBuf.trim());
          lineBuf = "";
        }

        if (exitCode !== 0 && !killed) {
          enqueue({
            type: "error",
            error: `CLI exited with code ${exitCode}`,
          });
        }
        finish();
      });

      // Handle abort signal
      if (req.signal) {
        const onAbort = () => {
          killed = true;
          child.kill("SIGTERM");
          finish();
        };
        if (req.signal.aborted) {
          onAbort();
        } else {
          req.signal.addEventListener("abort", onAbort, { once: true });
        }
      }

      // Create async iterable from child process events
      const output: AsyncIterable<ChatChunk> = {
        [Symbol.asyncIterator]() {
          return {
            async next(): Promise<IteratorResult<ChatChunk>> {
              while (true) {
                if (iterError) throw iterError;
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

      return {
        output,
        kill() {
          killed = true;
          child.kill("SIGTERM");
        },
      };
    },
  };
}
