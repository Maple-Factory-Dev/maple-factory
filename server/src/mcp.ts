// The factory as a remote MCP server: streamable HTTP at POST /mcp (JSON responses, no SSE stream yet), so a
// member's Claude Desktop, claude.ai, Claude Code or Cursor can work on the org's shared docs, goals and tasks as
// them. The tools are the runner's doc tools (factory/tools.ts DOC_TOOLS) and the outside-only task tools
// (MCP_TASK_TOOLS), filtered by the token's scopes, and run in the org hub (DocTools, engine.mcpTool) as the member
// with a "<client> via MCP" badge. Auth: src/mcp-auth.ts.

import type { Env } from "./env.ts";
import { mcpCaller, unauthorized } from "./mcp-auth.ts";
import { TOOL_SCOPES, toolAllowed, toolsForScopes } from "./mcp-tools.ts";
import { orgHub, readCapped } from "./util.ts";
import { SERVER_VERSION } from "./version.ts";

const MAX_BODY = 256 * 1024;
const PROTOCOLS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

type Id = string | number | null;
const reply = (id: Id, result: unknown) => Response.json({ jsonrpc: "2.0", id, result });
const rpcError = (id: Id, code: number, message: string, status = 200) => Response.json({ jsonrpc: "2.0", id, error: { code, message } }, { status });

const INSTRUCTIONS = "Maple Factory's shared planning docs, goals and tasks; which tools you have depends on the scopes you were given. You act as the member who connected you; anything you write shows as them with a 'via MCP' badge. Docs: you can't edit a doc's text: comment, suggest edits a person accepts, or propose decisions a person decides. Start with list_docs, then read_doc for block ids and threads. Tasks: search first with list_goals `q` and list_tasks `q` (plus its goal, state, owner, priority and effort filters) rather than listing everything, then get_task for one task's brief, plan and comments. propose_tasks only makes drafts a person sends to planning, and comment_on_task comments as the member; you can't approve, steer, merge or cancel a task."

export async function handleMcp(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return new Response("POST JSON-RPC here; there's no event stream.", { status: 405, headers: { allow: "POST" } });
  // DNS rebinding: a browser page may only talk to us from our own origin. Desktop clients send no Origin.
  const origin = request.headers.get("origin");
  if (origin && origin !== new URL(request.url).origin) return rpcError(null, -32600, "Bad origin.", 403);
  const auth = request.headers.get("authorization");
  const caller = await mcpCaller(request, env);
  if (!caller) return unauthorized(request, env, Boolean(auth));
  const body = await readCapped(request, MAX_BODY);
  if (!body) return rpcError(null, -32600, `At most ${MAX_BODY} bytes.`, 413);
  let msg: { jsonrpc?: string; id?: Id; method?: string; params?: Record<string, unknown> };
  try {
    msg = JSON.parse(new TextDecoder().decode(body));
  } catch {
    return rpcError(null, -32700, "Parse error.", 400);
  }
  if (!msg || typeof msg !== "object" || Array.isArray(msg) || msg.jsonrpc !== "2.0" || typeof msg.method !== "string") {
    return rpcError(null, -32600, "Expected one JSON-RPC 2.0 request.", 400);
  }
  // Notifications (and responses to anything we'd ask) get no answer.
  if (msg.id === undefined) return new Response(null, { status: 202 });
  const id = msg.id;
  const params = msg.params ?? {};
  switch (msg.method) {
    case "initialize": {
      const asked = typeof params.protocolVersion === "string" ? params.protocolVersion : "";
      return reply(id, {
        protocolVersion: PROTOCOLS.includes(asked) ? asked : PROTOCOLS[1],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "maple-factory", title: "Maple Factory", version: SERVER_VERSION },
        instructions: INSTRUCTIONS,
      });
    }
    case "ping":
      return reply(id, {});
    case "tools/list":
      return reply(id, { tools: toolsForScopes(caller.scopes) });
    case "tools/call": {
      const name = typeof params.name === "string" ? params.name : "";
      const args = params.arguments && typeof params.arguments === "object" && !Array.isArray(params.arguments) ? params.arguments : {};
      if (!Object.hasOwn(TOOL_SCOPES, name)) return rpcError(id, -32602, `Unknown tool: ${name}.`);
      // Checked here whatever tools/list showed: a read-only token can't call a write tool it was never shown.
      if (!toolAllowed(caller.scopes, name)) {
        return reply(id, { isError: true, content: [{ type: "text", text: `This connection can't ${name.replace(/_/g, " ")}: it needs the ${TOOL_SCOPES[name]} scope, and has ${caller.scopes.join(", ")}.` }] });
      }
      const res = await orgHub(env).fetch("https://org/mcp/call", {
        method: "POST",
        body: JSON.stringify({ login: caller.member.login, client: caller.client, name, args }),
      });
      const out = (await res.json()) as { summary?: string; data?: unknown; error?: string };
      if (out.error !== undefined) return reply(id, { isError: true, content: [{ type: "text", text: out.error }] });
      const textOut = out.data === undefined ? out.summary ?? "" : `${out.summary ?? ""}\n\n${typeof out.data === "string" ? out.data : JSON.stringify(out.data, null, 2)}`;
      return reply(id, { content: [{ type: "text", text: textOut }] });
    }
    default:
      return rpcError(id, -32601, `Method not found: ${msg.method}.`);
  }
}
