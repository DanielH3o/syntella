import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const helperPath = path.join(__dirname, "reports_db.py");

const REPORT_ACTIONS = [
  "list_recent",
  "list_mine",
  "get",
  "create",
] as const;

type ToolArgs = {
  action: typeof REPORT_ACTIONS[number];
  report_id?: number;
  title?: string;
  summary?: string;
  body?: string;
  status?: string;
  report_type?: string;
  limit?: number;
  agent_id?: string;
  routine_id?: number;
  routine_run_id?: number;
  task_id?: number;
};

function deriveAgentId(): string {
  const cwd = process.cwd().replace(/\\/g, "/");
  const match = cwd.match(/\/workspace\/([^/]+)(?:\/|$)/);
  if (match?.[1]) {
    return match[1] === "syntella" ? "main" : match[1];
  }
  return process.env.OPENCLAW_AGENT_ID || process.env.USER || "unknown";
}

function summarize(result: any): string {
  if (!result || typeof result !== "object") {
    return "Reports tool completed.";
  }
  if (result.error) {
    return `Reports tool failed: ${result.error}`;
  }
  if (Array.isArray(result.reports)) {
    const count = result.reports.length;
    const scope = result.scope ? ` (${result.scope})` : "";
    return `Fetched ${count} report${count === 1 ? "" : "s"}${scope}.`;
  }
  if (result.report) {
    const report = result.report;
    return `Report ${report.id}: ${report.title} [${report.status}]`;
  }
  return "Reports tool completed.";
}

async function runReportsDb(args: ToolArgs) {
  const payload = {
    ...args,
    __agent_id: deriveAgentId(),
  };
  const stdout = execFileSync("python3", [helperPath], {
    env: process.env,
    maxBuffer: 1024 * 1024,
    input: JSON.stringify(payload),
    encoding: "utf-8",
  });
  return JSON.parse(stdout || "{}");
}

export default async function register(api: any) {
  api.registerTool(
    {
      name: "reports",
      description:
        "Create and inspect durable Syntella reports in the shared workspace report system.",
      parameters: {
        type: "object",
        additionalProperties: false,
        required: ["action"],
        properties: {
          action: {
            type: "string",
            enum: [...REPORT_ACTIONS],
            description: "The report operation to perform.",
          },
          report_id: {
            type: "integer",
            description: "Report ID for get.",
          },
          title: {
            type: "string",
            description: "Report title for create.",
          },
          summary: {
            type: "string",
            description: "Short durable summary for create.",
          },
          body: {
            type: "string",
            description: "Full report body for create.",
          },
          status: {
            type: "string",
            description: "Report status for create. Defaults to published.",
          },
          report_type: {
            type: "string",
            description: "Report type such as routine, analysis, audit, or review.",
          },
          limit: {
            type: "integer",
            minimum: 1,
            maximum: 100,
            description: "Maximum number of reports to return for list actions.",
          },
          agent_id: {
            type: "string",
            description: "Explicit agent ID to use when needed.",
          },
          routine_id: {
            type: "integer",
            description: "Optional routine ID to link this report to.",
          },
          routine_run_id: {
            type: "integer",
            description: "Optional routine run ID to link this report to.",
          },
          task_id: {
            type: "integer",
            description: "Optional task ID if the report relates to a tracked task.",
          },
        },
      },
      async execute(_callId: string, args: ToolArgs) {
        const result = await runReportsDb(args);
        return {
          content: [
            {
              type: "text",
              text: summarize(result),
            },
          ],
          structuredContent: result,
        };
      },
    },
    { optional: true },
  );
}
