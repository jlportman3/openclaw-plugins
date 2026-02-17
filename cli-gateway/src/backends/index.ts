import type { CliBackend, GatewayConfig } from "../types.ts";
import { createClaudeCodeBackend } from "./claude-code.ts";

const backendFactories: Record<
  string,
  (config: GatewayConfig["backends"][string]) => CliBackend
> = {
  "claude-code": createClaudeCodeBackend,
};

const activeBackends = new Map<string, CliBackend>();

export async function initBackends(
  config: GatewayConfig,
): Promise<Map<string, CliBackend>> {
  activeBackends.clear();

  for (const [id, backendConfig] of Object.entries(config.backends)) {
    if (!backendConfig.enabled) continue;

    const factory = backendFactories[id];
    if (!factory) {
      console.warn(`Unknown backend: ${id}, skipping`);
      continue;
    }

    const backend = factory(backendConfig);
    const detected = await backend.detect();

    if (detected) {
      activeBackends.set(id, backend);
      console.log(`Backend '${backend.displayName}' detected and enabled`);
    } else {
      console.warn(
        `Backend '${backend.displayName}' not detected (CLI not found), skipping`,
      );
    }
  }

  return activeBackends;
}

export function getBackend(backendId: string): CliBackend | undefined {
  return activeBackends.get(backendId);
}

export function getAllBackends(): Map<string, CliBackend> {
  return activeBackends;
}

export function parseModelId(model: string): {
  backendId: string;
  modelName: string;
} {
  const slashIndex = model.indexOf("/");
  if (slashIndex === -1) {
    return { backendId: model, modelName: "" };
  }
  return {
    backendId: model.slice(0, slashIndex),
    modelName: model.slice(slashIndex + 1),
  };
}
