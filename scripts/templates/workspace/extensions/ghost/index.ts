import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const helperPath = path.join(__dirname, "status.py");

function runStatus() {
  const stdout = execFileSync("python3", [helperPath, "syntella-ghost"], {
    env: process.env,
    maxBuffer: 1024 * 1024,
    encoding: "utf-8",
  });
  return JSON.parse(stdout || "{}");
}

export default function register(api: any) {
  api.registerTool(
    {
      name: "ghost",
      description: "Inspect whether the Ghost CMS integration is configured and enabled for this workspace.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {},
      },
      execute() {
        const result = runStatus();
        return {
          content: [
            {
              type: "text",
              text: result.ok
                ? `Ghost integration is ${result.enabled ? "enabled" : "disabled"} and ${result.configured ? "configured" : "missing configuration"}.`
                : `Ghost integration check failed: ${result.error || "Unknown error"}`,
            },
          ],
          structuredContent: result,
        };
      },
    },
    { optional: true },
  );
}
