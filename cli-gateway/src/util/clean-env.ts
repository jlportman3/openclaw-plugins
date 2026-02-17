// Whitelist of environment variables safe to pass to CLI subprocesses.
// Everything else (API keys, .env secrets, tokens) is stripped.
const ALLOWED_KEYS = new Set([
  // Essential system
  "PATH",
  "HOME",
  "USER",
  "LOGNAME",
  "SHELL",
  "TERM",
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
  "TMPDIR",
  "TMP",
  "TEMP",
  "XDG_CONFIG_HOME",
  "XDG_DATA_HOME",
  "XDG_CACHE_HOME",
  "XDG_RUNTIME_DIR",

  // Node.js
  "NODE_PATH",
  "NODE_ENV",
  "NODE_OPTIONS",
  "NODE_EXTRA_CA_CERTS",
  "NPM_CONFIG_PREFIX",

  // Display (needed for PTY)
  "DISPLAY",
  "COLORTERM",
  "TERM_PROGRAM",

  // Hostname/network identity
  "HOSTNAME",
  "SSH_AUTH_SOCK",
]);

// Additional per-backend keys that the CLI tools need for auth
const BACKEND_KEYS: Record<string, string[]> = {
  "claude-code": [
    "ANTHROPIC_API_KEY",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
  ],
  "codex": [
    "CODEX_API_KEY",
    "OPENAI_API_KEY",
    "OPENAI_ORG_ID",
  ],
  "gemini": [
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "GOOGLE_CLOUD_PROJECT",
  ],
};

/**
 * Build a minimal environment for a CLI subprocess.
 * Only whitelisted system keys + backend-specific auth keys are included.
 * All values are guaranteed to be strings (safe for node-pty).
 */
export function cleanEnv(backendId: string): Record<string, string> {
  const env: Record<string, string> = {};
  const extra = BACKEND_KEYS[backendId] ?? [];

  for (const [k, v] of Object.entries(process.env)) {
    if (v === undefined) continue;
    if (ALLOWED_KEYS.has(k) || extra.includes(k)) {
      env[k] = v;
    }
  }

  return env;
}
