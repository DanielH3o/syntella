import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const helperPath = path.join(__dirname, "tasks_db.py");

const TASK_STATUSES = ["backlog", "in_progress", "review", "done"] as const;
const TASK_ACTIONS = [
  "list",
  "list_mine",
  "get",
  "create",
  "update_status",
  "update_description",
] as const;

type ToolArgs = {
  action: typeof TASK_ACTIONS[number];
  task_id?: number;
  title?: string;
  description?: string;
  assignee?: string;
  priority?: "low" | "medium" | "high";
  status?: typeof TASK_STATUSES[number];
  limit?: number;
  agent_id?: string;
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
    return "Task tool completed.";
  }
  if (result.error) {
    return `Task tool failed: ${result.error}`;
  }
  if (Array.isArray(result.tasks)) {
    const count = result.tasks.length;
    const scope = result.scope ? ` (${result.scope})` : "";
    return `Fetched ${count} task${count === 1 ? "" : "s"}${scope}.`;
  }
  if (result.task) {
    const task = result.task;
    return `Task ${task.id}: ${task.title} [${task.status}]`;
  }
  return "Task tool completed.";
}

function runTaskDb(args: ToolArgs) {
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

export default function register(api: any) {
  api.registerTool(
    {
      name: "tasks",
      description:
        "Create, inspect, and update Syntella tasks in the shared workspace task system.",
      parameters: {
        type: "object",
        additionalProperties: false,
        required: ["action"],
        properties: {
          action: {
            type: "string",
            enum: [...TASK_ACTIONS],
            description: "The task operation to perform.",
          },
          task_id: {
            type: "integer",
            description: "Task ID for get or update actions.",
          },
          title: {
            type: "string",
            description: "Task title for create.",
          },
          description: {
            type: "string",
            description: "Task description or updated notes.",
          },
          assignee: {
            type: "string",
            description: "Assignee agent ID. Omit on list_mine to use the current agent.",
          },
          priority: {
            type: "string",
            enum: ["low", "medium", "high"],
            description: "Priority for create.",
          },
          status: {
            type: "string",
            enum: [...TASK_STATUSES],
            description: "New task status for create or update_status.",
          },
          limit: {
            type: "integer",
            minimum: 1,
            maximum: 100,
            description: "Maximum number of tasks to return for list actions.",
          },
          agent_id: {
            type: "string",
            description: "Explicit agent ID to use when needed.",
          },
        },
      },
      execute(_callId: string, args: ToolArgs) {
        const result = runTaskDb(args);
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
