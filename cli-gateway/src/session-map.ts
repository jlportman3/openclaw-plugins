import { createHash } from "node:crypto";
import { join } from "node:path";
import Database from "better-sqlite3";

const SESSION_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours

// --- SQLite session store ---

const DB_PATH = join(
  process.env.CLI_GATEWAY_STATE_DIR || process.cwd(),
  "sessions.db",
);

const db = new Database(DB_PATH);
db.pragma("journal_mode = WAL");
db.pragma("busy_timeout = 3000");

db.exec(`
  CREATE TABLE IF NOT EXISTS sessions (
    session_id  TEXT PRIMARY KEY,
    backend_id  TEXT NOT NULL,
    created_at  INTEGER NOT NULL,
    last_used   INTEGER NOT NULL,
    msg_count   INTEGER NOT NULL
  )
`);

const stmtUpsert = db.prepare(`
  INSERT INTO sessions (session_id, backend_id, created_at, last_used, msg_count)
  VALUES (?, ?, ?, ?, ?)
  ON CONFLICT(session_id) DO UPDATE SET
    last_used = excluded.last_used,
    msg_count = excluded.msg_count
`);

const stmtExists = db.prepare(
  `SELECT 1 FROM sessions WHERE session_id = ? AND last_used > ?`,
);

const stmtPrune = db.prepare(`DELETE FROM sessions WHERE last_used <= ?`);

console.log(`[sessions] SQLite store: ${DB_PATH}`);

// --- Public API ---

// Extract text from OpenAI message content (string or content parts array)
function extractContentText(
  content: string | Array<Record<string, unknown>> | undefined,
): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter((p) => p.type === "text")
      .map((p) => p.text as string)
      .join("\n");
  }
  return "";
}

export function resolveSessionId(
  headerSessionId: string | undefined,
  systemPrompt: string | undefined,
  firstUserContent: string | Array<Record<string, unknown>> | undefined,
): string {
  if (headerSessionId) return headerSessionId;

  const firstUserText = extractContentText(firstUserContent);

  // Derive deterministic session ID from content
  const seed = `${systemPrompt ?? ""}::${firstUserText}`;
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

export function isNewConversation(sessionId: string): boolean {
  const cutoff = Date.now() - SESSION_TTL_MS;
  const row = stmtExists.get(sessionId, cutoff);
  return !row;
}

export function trackSession(
  sessionId: string,
  backendId: string,
  messageCount: number,
): void {
  const now = Date.now();
  stmtUpsert.run(sessionId, backendId, now, now, messageCount);
}

export function pruneExpiredSessions(): void {
  const cutoff = Date.now() - SESSION_TTL_MS;
  const result = stmtPrune.run(cutoff);
  if (result.changes > 0) {
    console.log(`[sessions] Pruned ${result.changes} expired sessions`);
  }
}

// Run pruning every hour
setInterval(pruneExpiredSessions, 60 * 60 * 1000).unref();
