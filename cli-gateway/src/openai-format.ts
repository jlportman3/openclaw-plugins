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
