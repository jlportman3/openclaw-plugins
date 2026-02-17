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
// The actual message follows the [timestamp] bracket.

function stripText(text: string): string {
  // Find the [Day YYYY-MM-DD HH:MM TZ] timestamp line — everything after it is the real message
  const tsMatch = text.match(/\[[A-Z][a-z]{2}\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s+\w+\]\s*/);
  if (tsMatch && tsMatch.index !== undefined) {
    const afterTs = text.slice(tsMatch.index + tsMatch[0].length).trim();
    if (afterTs) return afterTs;
  }

  // Fallback: try to strip "Conversation info..." header generically
  const ciIdx = text.indexOf("Conversation info (untrusted metadata):");
  if (ciIdx >= 0) {
    // Find the closing } of the JSON block, then take everything after
    const braceOpen = text.indexOf("{", ciIdx);
    if (braceOpen >= 0) {
      const braceClose = text.indexOf("}", braceOpen);
      if (braceClose >= 0) {
        const rest = text.slice(braceClose + 1).trim();
        if (rest) return rest;
      }
    }
  }

  return text;
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
      const cleaned = { ...msg, content: stripContent(msg.content) };
      // Log first stripping for debugging
      const origText = typeof msg.content === "string" ? msg.content : JSON.stringify(msg.content);
      const cleanText = typeof cleaned.content === "string" ? cleaned.content : JSON.stringify(cleaned.content);
      if (origText !== cleanText) {
        console.log(`[strip-metadata] "${origText.slice(0, 80)}..." → "${cleanText.slice(0, 80)}..."`);
      }
      return cleaned;
    }
    return msg;
  });
}
