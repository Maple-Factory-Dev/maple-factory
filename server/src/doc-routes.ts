// The shared docs' sync socket (docs/planning-docs.md): authed like the client feed, then on to the doc's DocHub.

import type { Env } from "./env.ts";
import { sameOrigin } from "./auth.ts";
import { orgHub, text } from "./util.ts";
import type { Doc, Member } from "./wire.ts";

export const DOC_SYNC = /^\/docs\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/sync$/;

export function docHub(env: Env, id: string) {
  return env.DOC.get(env.DOC.idFromName(id));
}

/** `GET /docs/<id>/sync` for `me` (null: not signed in, or revoked). */
export async function docSync(request: Request, env: Env, id: string, me: Member | null): Promise<Response> {
  if (!me) return text("Sign in first.", 401);
  if (!sameOrigin(request)) return text("Bad origin.", 403);
  if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return text("Expected a WebSocket.", 426);
  const res = await orgHub(env).fetch(`https://org/docs/${id}`);
  if (res.status === 404) return text("No such doc.", 404);
  if (!res.ok) return text("Couldn't look up that doc.", 502);
  const doc = (await res.json()) as Doc;
  if (doc.archived) return text("That doc is archived.", 403);
  const forward = new Request("https://doc/sync", request);
  forward.headers.set("x-member-login", me.login);
  forward.headers.set("x-doc-id", id);
  return docHub(env, id).fetch(forward);
}
