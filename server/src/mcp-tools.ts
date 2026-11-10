// Which doc tools an MCP token's scopes allow (src/mcp.ts): the runner's DOC_TOOLS, one scope each.

import { DOC_TOOLS } from "./factory/tools.ts";
import type { Scope } from "./mcp-auth.ts";

/** The scope each doc tool needs. */
export const TOOL_SCOPES: Record<string, Scope> = {
  list_docs: "docs:read",
  read_doc: "docs:read",
  comment_on_doc: "docs:write",
  reply_to_doc_thread: "docs:write",
  resolve_doc_thread: "docs:write",
  suggest_doc_edit: "docs:write",
  propose_decision: "docs:write",
};

/** Whether a token with `scopes` may call `tool`. */
export const toolAllowed = (scopes: readonly Scope[], tool: string) => Object.hasOwn(TOOL_SCOPES, tool) && scopes.includes(TOOL_SCOPES[tool]);

/** The doc tools a token with `scopes` sees in tools/list. */
export const toolsForScopes = (scopes: readonly Scope[]) => DOC_TOOLS.filter((t) => toolAllowed(scopes, t.name));
