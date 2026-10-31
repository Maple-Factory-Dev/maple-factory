// The factory's icon: one square image an admin uploads, shown in place of the letter tile in the apps
// (and as the Mac app's Dock icon) and as the web app's favicon. It's kept in the factory's bucket at
// icon/<uuid>, a new id per upload, so its link `/icon/<uuid>` changes with the image and can be cached
// for good. The org hub keeps the current id and tells the apps (`icon` in the snapshot, `icon.updated`).

import type { Env } from "./env.ts";
import type { Member } from "./wire.ts";
import { audit, orgHub, readCapped, text } from "./util.ts";

export const MAX_ICON = 2 * 1024 * 1024;

const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** What an icon is from its first bytes: PNG, JPEG or WebP only. */
export function sniffIcon(b: Uint8Array): string | null {
  const at = (i: number, s: string) => [...s].every((c, j) => b[i + j] === c.charCodeAt(0));
  if (b[0] === 0x89 && at(1, "PNG")) return "image/png";
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (at(0, "RIFF") && at(8, "WEBP")) return "image/webp";
  return null;
}

/** Tells the org hub the icon's new id (none: removed); it answers with the one it replaced. */
async function swap(env: Env, id: string | null): Promise<string | null> {
  const res = await orgHub(env).fetch("https://org/icon", { method: "POST", body: JSON.stringify({ id }) });
  return ((await res.json()) as { previous: string | null }).previous;
}

/** PUT /api/icon: admins only; the body is a PNG, JPEG or WebP of at most 2 MB. */
export async function upload(request: Request, env: Env, me: Member): Promise<Response> {
  if (me.role !== "admin") return text("Only admins can change the factory's icon.", 403);
  const body = await readCapped(request, MAX_ICON);
  if (!body) return text(`The icon can be up to ${MAX_ICON / 1024 / 1024} MB.`, 413);
  if (!body.byteLength) return text("The image is empty.", 400);
  const mime = sniffIcon(body);
  if (!mime) return text("The icon is a PNG, JPEG or WebP image.", 400);
  const id = crypto.randomUUID();
  await env.RELEASES.put(`icon/${id}`, body, { httpMetadata: { contentType: mime }, customMetadata: { by: me.login } });
  const previous = await swap(env, id);
  if (previous) await env.RELEASES.delete(`icon/${previous}`);
  await audit(env, me.login, "icon.set", id, { size: body.byteLength, mime });
  return Response.json({ icon: `/icon/${id}` });
}

/** DELETE /api/icon: admins only; back to the letter tile. */
export async function remove(env: Env, me: Member): Promise<Response> {
  if (me.role !== "admin") return text("Only admins can change the factory's icon.", 403);
  const previous = await swap(env, null);
  if (previous) await env.RELEASES.delete(`icon/${previous}`);
  await audit(env, me.login, "icon.removed", previous);
  return Response.json({ icon: null });
}

/** GET /icon/<uuid>: public, since a browser asks for a favicon without the app's token; it's a logo, not a secret. */
export async function serve(env: Env, id: string): Promise<Response> {
  if (!ID.test(id)) return text("Not found.", 404);
  const object = await env.RELEASES.get(`icon/${id}`);
  if (!object) return text("Not found.", 404);
  return new Response(object.body, {
    headers: {
      "content-type": object.httpMetadata?.contentType ?? "application/octet-stream",
      "content-length": String(object.size),
      "content-security-policy": "sandbox; default-src 'none'",
      "x-content-type-options": "nosniff",
      // A new image gets a new id, so this one never changes.
      "cache-control": "public, max-age=31536000, immutable",
      etag: object.httpEtag,
    },
  });
}
