// The factory's display name: what an admin calls it ("Andrea's Factory"), shown in the apps in place of
// the GitHub org. The org hub keeps it and tells the apps (`name` in the snapshot, `name.updated`).

import type { Env } from "./env.ts";
import type { Member } from "./wire.ts";
import { audit, orgHub, text } from "./util.ts";

export const MAX_NAME = 60;

async function save(env: Env, name: string | null) {
  await orgHub(env).fetch("https://org/name", { method: "POST", body: JSON.stringify({ name }) });
}

/** PUT /api/name: admins only; the body is `{ name }`, trimmed, up to 60 characters. Blank clears it. */
export async function set(request: Request, env: Env, me: Member): Promise<Response> {
  if (me.role !== "admin") return text("Only admins can rename the factory.", 403);
  const body = (await request.json().catch(() => null)) as { name?: unknown } | null;
  if (typeof body?.name !== "string") return text("Send the factory's name as { name }.", 400);
  const name = body.name.trim().replace(/\s+/g, " ");
  if ([...name].length > MAX_NAME) return text(`The name can be up to ${MAX_NAME} characters.`, 400);
  await save(env, name || null);
  await audit(env, me.login, name ? "name.set" : "name.removed", name || null);
  return Response.json({ name: name || null });
}

/** DELETE /api/name: admins only; back to the GitHub org. */
export async function remove(env: Env, me: Member): Promise<Response> {
  if (me.role !== "admin") return text("Only admins can rename the factory.", 403);
  await save(env, null);
  await audit(env, me.login, "name.removed", null);
  return Response.json({ name: null });
}
