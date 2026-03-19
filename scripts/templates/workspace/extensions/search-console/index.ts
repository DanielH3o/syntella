import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const helperPath = path.join(__dirname, "search_console.py");

const SEARCH_CONSOLE_ACTIONS = [
  "inspect",
  "query_opportunities",
  "page_opportunities",
  "declining_pages",
] as const;
const SEARCH_TYPES = ["web", "image", "video", "news", "discover", "googleNews"] as const;

type ToolArgs = {
  action: typeof SEARCH_CONSOLE_ACTIONS[number];
  site?: string;
  days?: number;
  compare_days?: number;
  min_impressions?: number;
  position_min?: number;
  position_max?: number;
  limit?: number;
  supporting_query_limit?: number;
  search_type?: typeof SEARCH_TYPES[number];
};

function runSearchConsole(args: ToolArgs) {
  const stdout = execFileSync("python3", [helperPath], {
    env: process.env,
    maxBuffer: 1024 * 1024,
    input: JSON.stringify(args),
    encoding: "utf-8",
  });
  return JSON.parse(stdout || "{}");
}

function formatPercent(value: number | undefined) {
  return `${(((value || 0) as number) * 100).toFixed(1)}%`;
}

function formatNumber(value: number | undefined) {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 }).format(value || 0);
}

function shortenUrl(value: string | undefined) {
  if (!value) return "unknown";
  if (value.length <= 72) return value;
  return `${value.slice(0, 69)}...`;
}

function summarize(result: any) {
  if (!result || typeof result !== "object") {
    return "Search Console tool completed.";
  }
  if (result.error) {
    return `Search Console tool failed: ${result.error}`;
  }
  if (result.action === "inspect") {
    const configuredSites = Array.isArray(result.configuredSites) ? result.configuredSites : [];
    const lines = configuredSites.map((item: any) => {
      const permission = item.permissionLevel || "not accessible";
      return `${item.site}: ${item.property} (${permission})`;
    });
    return `Search Console integration is ${result.enabled ? "enabled" : "disabled"} and ${result.configured ? "configured" : "missing configuration"}.${
      lines.length ? `\n${lines.join("\n")}` : ""
    }`;
  }
  if (Array.isArray(result.opportunities)) {
    if (!result.opportunities.length) {
      return `No ${result.action === "page_opportunities" ? "page" : "query"} opportunities found for ${result.site || "the selected site"} in ${result.dateWindow?.days || "the selected"} days.`;
    }
    const label = result.action === "page_opportunities" ? "page" : "query";
    const lines = result.opportunities.slice(0, 10).map((item: any) => {
      const key = label === "page" ? shortenUrl(item.page) : item.query;
      const extra =
        label === "page" && Array.isArray(item.supportingQueries) && item.supportingQueries.length
          ? ` | support: ${item.supportingQueries.slice(0, 2).map((query: any) => query.query).join(", ")}`
          : "";
      return `${key} | ${formatNumber(item.impressions)} impressions | ${formatNumber(item.clicks)} clicks | ${formatPercent(item.ctr)} CTR | pos ${Number(item.position || 0).toFixed(1)}${extra}`;
    });
    return `Found ${result.opportunities.length} ${label} opportunities for ${result.site} over ${result.dateWindow?.days || "?"} days:\n${lines.join("\n")}`;
  }
  if (Array.isArray(result.declines)) {
    if (!result.declines.length) {
      return `No declining pages found for ${result.site || "the selected site"} across the comparison windows.`;
    }
    const lines = result.declines.slice(0, 10).map((item: any) => {
      return `${shortenUrl(item.page)} | clicks ${item.clickDelta} | impressions ${item.impressionDelta} | position ${item.positionDelta}`;
    });
    return `Found ${result.declines.length} declining pages for ${result.site}:\n${lines.join("\n")}`;
  }
  return "Search Console tool completed.";
}

export default function register(api: any) {
  api.registerTool(
    {
      name: "search_console",
      description: "Inspect Search Console setup and retrieve search query/page opportunity data for configured sites.",
      parameters: {
        type: "object",
        additionalProperties: false,
        required: ["action"],
        properties: {
          action: {
            type: "string",
            enum: [...SEARCH_CONSOLE_ACTIONS],
            description: "The Search Console operation to perform.",
          },
          site: {
            type: "string",
            description: "Configured site alias such as `wonderful` or `asima`.",
          },
          days: {
            type: "integer",
            minimum: 1,
            maximum: 365,
            description: "Number of days to look back for opportunity queries.",
          },
          compare_days: {
            type: "integer",
            minimum: 1,
            maximum: 120,
            description: "Window size for declining_pages comparisons.",
          },
          min_impressions: {
            type: "number",
            minimum: 0,
            description: "Minimum impressions required before returning a query or page.",
          },
          position_min: {
            type: "number",
            minimum: 0,
            description: "Minimum average position to include in opportunity results.",
          },
          position_max: {
            type: "number",
            minimum: 0,
            description: "Maximum average position to include in opportunity results.",
          },
          limit: {
            type: "integer",
            minimum: 1,
            maximum: 50,
            description: "Maximum number of rows to return.",
          },
          supporting_query_limit: {
            type: "integer",
            minimum: 1,
            maximum: 10,
            description: "Number of supporting queries to fetch per page opportunity.",
          },
          search_type: {
            type: "string",
            enum: [...SEARCH_TYPES],
            description: "Search result type to query. Defaults to `web`.",
          },
        },
      },
      execute(_callId: string, args: ToolArgs) {
        const result = runSearchConsole(args);
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
