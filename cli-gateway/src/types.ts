import type { ChildProcess } from "node:child_process";

// --- Backend contract ---

export interface CliBackend {
  id: string;
  displayName: string;
  detect(): Promise<boolean>;
  listModels(): ModelInfo[];
  spawn(request: SpawnRequest): ChildProcess;
  parseOutput(stdout: NodeJS.ReadableStream): AsyncIterable<ChatChunk>;
}

export interface SpawnRequest {
  model: string;
  messages: OpenAIMessage[];
  systemPrompt: string | undefined;
  temperature: number | undefined;
  maxTokens: number | undefined;
  sessionId: string;
  isNewConversation: boolean;
  tools: boolean;
  signal: AbortSignal;
}

export interface ModelInfo {
  id: string;
  name: string;
  owned_by: string;
}

// --- Parsed output from CLI ---

export interface ChatChunk {
  type: "content" | "done" | "error";
  content?: string;
  finishReason?: string;
  usage?: UsageInfo;
  error?: string;
  sessionId?: string;
}

export interface UsageInfo {
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
}

// --- OpenAI wire types ---

export interface OpenAIMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  name?: string;
}

export interface OpenAIChatRequest {
  model: string;
  messages: OpenAIMessage[];
  stream?: boolean;
  temperature?: number;
  max_tokens?: number;
}

export interface OpenAIChatChunkResponse {
  id: string;
  object: "chat.completion.chunk";
  created: number;
  model: string;
  choices: Array<{
    index: number;
    delta: {
      role?: string;
      content?: string;
    };
    finish_reason: string | null;
  }>;
  usage?: UsageInfo;
}

export interface OpenAIChatResponse {
  id: string;
  object: "chat.completion";
  created: number;
  model: string;
  choices: Array<{
    index: number;
    message: {
      role: string;
      content: string;
    };
    finish_reason: string;
  }>;
  usage: UsageInfo;
}

// --- Config ---

export interface GatewayConfig {
  port: number;
  backends: Record<string, BackendConfig>;
}

export interface BackendConfig {
  enabled: boolean;
  command: string;
  defaultModel: string;
  tools: boolean;
  sessionContinuity: boolean;
}

// --- Session map ---

export interface SessionEntry {
  sessionId: string;
  backendId: string;
  createdAt: number;
  lastUsedAt: number;
  messageCount: number;
}
