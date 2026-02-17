import { execFileSync } from "node:child_process";

export function which(command: string): string | null {
  try {
    const result = execFileSync("which", [command], {
      encoding: "utf-8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    return result.trim() || null;
  } catch {
    return null;
  }
}
