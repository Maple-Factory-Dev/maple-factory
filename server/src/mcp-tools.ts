// Which tools an MCP token's scopes allow (src/mcp.ts): the runner's DOC_TOOLS and the outside-only
// MCP_TASK_TOOLS, one scope each. Nothing else in factory/tools.ts is ever reachable from /mcp.

import { DOC_TOOLS, MCP_TASK_TOOLS } from "./factory/tools.ts";
import type { Scope } from "./mcp-auth.ts";

/** The scope each tool needs. */
export const TOOL_SCOPES: Record<string, Scope> = {
  list_docs: "docs:read",
  read_doc: "docs:read",
  comment_on_doc: "docs:write",
  reply_to_doc_thread: "docs:write",
  resolve_doc_thread: "docs:write",
  suggest_doc_edit: "docs:write",
  propose_decision: "docs:write",
  list_goals: "tasks:read",
  list_tasks: "tasks:read",
  get_task: "tasks:read",
  propose_tasks: "tasks:write",
  comment_on_task: "tasks:write",
};

/** Whether a token with `scopes` may call `tool`. */
export const toolAllowed = (scopes: readonly Scope[], tool: string) => Object.hasOwn(TOOL_SCOPES, tool) && scopes.includes(TOOL_SCOPES[tool]);

/** The tools a token with `scopes` sees in tools/list. */
export const toolsForScopes = (scopes: readonly Scope[]) => [...DOC_TOOLS, ...MCP_TASK_TOOLS].filter((t) => toolAllowed(scopes, t.name));
