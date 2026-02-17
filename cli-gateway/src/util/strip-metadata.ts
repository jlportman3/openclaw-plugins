import type { OpenAIMessage } from "../types.ts";

// OpenClaw wraps user messages with metadata like:
//
//   Conversation info (untrusted metadata):
//
//   {
//     "sender": "openclaw-control-ui"
//   }
//   [Tue 2026-02-17 21:30 UTC] actual message here
//
// Strip this so backends only see the real user text.

const METADATA_RE =
  /^Conversation info \(untrusted metadata\):[\s\S]*?\n\[.*?\]\s*/;

function stripText(text: string): string {
  return text.replace(METADATA_RE, "").trim();
}

function stripContent(
  content: string | Array<Record<string, unknown>>,
): string | Array<Record<string, unknown>> {
  if (typeof content === "string") {
    return stripText(content);
  }
  if (Array.isArray(content)) {
    return content.map((part) => {
      if (part.type === "text" && typeof part.text === "string") {
        return { ...part, text: stripText(part.text) };
      }
      return part;
    });
  }
  return content;
}

export function stripMetadata(messages: OpenAIMessage[]): OpenAIMessage[] {
  return messages.map((msg) => {
    if (msg.role === "user") {
      return { ...msg, content: stripContent(msg.content) };
    }
    return msg;
  });
}
