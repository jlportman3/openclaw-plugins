import { spawn } from "node:child_process";
import { writeFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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

// Map gateway sessionId -> gemini session_id for resume
const sessionMapping = new Map<string, string>();

export function createGeminiBackend(config: BackendConfig): CliBackend {
  const command = config.command || "gemini";

  return {
    id: "gemini",
    displayName: "Gemini CLI",

    async detect(): Promise<boolean> {
      return which(command) !== null;
    },

    listModels(): ModelInfo[] {
      return [
        {
          id: "gemini/auto",
          name: "Gemini Auto (via Gemini CLI)",
          owned_by: "google",
        },
        {
          id: "gemini/gemini-2.5-pro",
          name: "Gemini 2.5 Pro (via Gemini CLI)",
          owned_by: "google",
        },
        {
          id: "gemini/gemini-2.5-flash",
          name: "Gemini 2.5 Flash (via Gemini CLI)",
          owned_by: "google",
        },
      ];
    },

    run(req: SpawnRequest): CliHandle {
      const geminiSessionId = sessionMapping.get(req.sessionId);
      const isResume = !req.isNewConversation && geminiSessionId;

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

      const args: string[] = [];

      // -p takes the prompt as its value (not a separate positional arg)
      args.push("-p", prompt);

      // Output format
      args.push("--output-format", "stream-json");

      // Model selection
      if (req.model) {
        args.push("--model", req.model);
      }

      // Session resume
      if (isResume) {
        args.push("--resume", geminiSessionId);
      }

      // Permissions — yolo auto-approves all tool use; default mode
      // prompts for approval (which blocks in headless, effectively disabling tools)
      if (req.tools) {
        args.push("--yolo");
      }

      // Build environment — system prompt via temp file + GEMINI_SYSTEM_MD env var
      const env = cleanEnv("gemini");
      let systemPromptFile: string | null = null;

      if (req.systemPrompt) {
        systemPromptFile = join(
          tmpdir(),
          `gemini-sysprompt-${req.sessionId.slice(0, 8)}.md`,
        );
        writeFileSync(systemPromptFile, req.systemPrompt, "utf-8");
        env["GEMINI_SYSTEM_MD"] = systemPromptFile;
      }

      const child = spawn(command, args, {
        cwd: process.cwd(),
        env,
        stdio: ["pipe", "pipe", "pipe"],
      });

      // CRITICAL: Close stdin immediately to prevent Gemini from hanging
      // in non-TTY environments (GitHub issue #6715)
      child.stdin!.end();

      // Buffer for incomplete lines
      let lineBuf = "";
      let killed = false;
      let capturedSessionId = "";

      // Queue of parsed chunks + resolve for the async iterator
      const chunkQueue: ChatChunk[] = [];
      let done = false;
      let waitResolve: (() => void) | null = null;
      let iterError: Error | null = null;

      function cleanup(): void {
        if (systemPromptFile) {
          try {
            unlinkSync(systemPromptFile);
          } catch {
            // ignore
          }
          systemPromptFile = null;
        }
      }

      function enqueue(chunk: ChatChunk): void {
        chunkQueue.push(chunk);
        if (waitResolve) {
          const r = waitResolve;
          waitResolve = null;
          r();
        }
      }

      function finish(): void {
        cleanup();
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

        if (type === "init") {
          const sid = event.session_id as string;
          if (sid) {
            capturedSessionId = sid;
            sessionMapping.set(req.sessionId, sid);
          }
        } else if (type === "message") {
          const role = event.role as string;
          const content = event.content as string;
          if (role === "assistant" && content) {
            enqueue({ type: "content", content });
          }
          // Skip user messages
        } else if (type === "result") {
          const status = event.status as string;
          const stats = event.stats as Record<string, number> | undefined;
          if (status === "success") {
            enqueue({
              type: "done",
              finishReason: "stop",
              sessionId: req.sessionId,
              usage: stats
                ? {
                    prompt_tokens: stats.input_tokens ?? stats.input ?? 0,
                    completion_tokens:
                      stats.output_tokens ?? stats.output ?? 0,
                    total_tokens: stats.total_tokens ?? 0,
                  }
                : undefined,
            });
          } else {
            enqueue({
              type: "error",
              error: `Gemini result status: ${status}`,
            });
          }
        } else if (type === "error") {
          enqueue({
            type: "error",
            error: (event.message as string) ?? "Unknown gemini error",
          });
        }
        // Skip: tool_use, tool_result, other event types
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
          cleanup();
        },
      };
    },
  };
}
