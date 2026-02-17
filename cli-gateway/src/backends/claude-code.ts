import * as pty from "node-pty";
import { which } from "../util/which.ts";
import type {
  BackendConfig,
  ChatChunk,
  CliBackend,
  CliHandle,
  ModelInfo,
  SpawnRequest,
} from "../types.ts";

// Strip ANSI escape sequences from PTY output
function stripAnsi(str: string): string {
  // eslint-disable-next-line no-control-regex
  return str.replace(/\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\x07]*\x07|\][^\x1B]*\x1B\\)/g, "");
}

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

    run(req: SpawnRequest): CliHandle {
      const args = [
        "-p",
        "--verbose",
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
      } else {
        args.push("--dangerously-skip-permissions");
      }

      // Extract the last user message as the prompt
      const lastUserMsg = [...req.messages]
        .reverse()
        .find((m) => m.role === "user");
      const prompt = lastUserMsg?.content ?? "";

      // Use -- to separate options from the prompt positional argument
      // This prevents variadic flags (--tools, --allowedTools) from consuming the prompt
      args.push("--", prompt);

      const ptyProcess = pty.spawn(command, args, {
        name: "xterm-256color",
        cols: 200,
        rows: 50,
        cwd: process.cwd(),
        env: process.env as Record<string, string>,
      });

      // Buffer for incomplete lines from PTY
      let lineBuf = "";
      let killed = false;

      // Queue of parsed chunks + resolve/reject for the async iterator
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

      // Handle PTY data
      ptyProcess.onData((data: string) => {
        // Strip ANSI escape sequences
        const cleaned = stripAnsi(data);
        lineBuf += cleaned;

        // Process complete lines
        const lines = lineBuf.split("\n");
        // Keep the last incomplete segment in the buffer
        lineBuf = lines.pop() ?? "";

        for (const line of lines) {
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
                  enqueue({ type: "content", content: block.text });
                }
              }
            }
          } else if (type === "result") {
            const subtype = event.subtype as string;
            const usage = event.usage as Record<string, number> | undefined;
            const sessionId = event.session_id as string | undefined;

            if (subtype === "success") {
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
            } else {
              enqueue({
                type: "error",
                error: (event.result as string) ?? "Unknown error from CLI",
              });
            }
          }
          // system events (init, hook_started, hook_response) — skip
        }
      });

      // Handle PTY exit
      ptyProcess.onExit(({ exitCode }) => {
        // Process any remaining data in the buffer
        if (lineBuf.trim()) {
          try {
            const event = JSON.parse(lineBuf.trim()) as Record<string, unknown>;
            if (event.type === "result") {
              const subtype = event.subtype as string;
              const usage = event.usage as Record<string, number> | undefined;
              const sessionId = event.session_id as string | undefined;
              if (subtype === "success") {
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
              }
            }
          } catch {
            // ignore unparseable remainder
          }
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
          ptyProcess.kill();
          finish();
        };
        if (req.signal.aborted) {
          onAbort();
        } else {
          req.signal.addEventListener("abort", onAbort, { once: true });
        }
      }

      // Create async iterable from the event-driven PTY
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
                  return { value: undefined as unknown as ChatChunk, done: true };
                }
                // Wait for more data
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
          ptyProcess.kill();
        },
      };
    },
  };
}
