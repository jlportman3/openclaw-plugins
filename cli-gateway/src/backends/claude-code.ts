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
