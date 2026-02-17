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
  // If client sends >2 messages (system+user+assistant+user...), this is
  // clearly a continuation — use --resume regardless of in-memory state.
  // This survives service restarts since Claude stores sessions on disk.
  if (messageCount > 2) return false;
  // For 1-2 messages, check if we've seen this session before
  return !sessions.has(sessionId);
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
