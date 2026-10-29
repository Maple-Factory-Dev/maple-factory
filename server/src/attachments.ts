// Attachments: screenshots and files pasted or dropped into a brief or a Scratchpad note. They're kept
// in the factory's bucket (RELEASES, which every factory already has) under attachments/<id>/<name>,
// and a note links to them as /attachments/<id>/<name>. Members fetch them there; runners fetch them
// with their own token at /runner/attachments/<id>/<name>, into a cache folder for their agents.

import type { Env } from "./env.ts";
import { authenticateRunner, MACHINE_ID } from "./machines.ts";
import type { Member } from "./wire.ts";
import { audit, text } from "./util.ts";

export const MAX_ATTACHMENT = 25 * 1024 * 1024;

/** `<uuid>/<name>`: what follows /attachments/ in a link. */
const LINK = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/([\w.\-]{1,120})$/;

/** Shown in the browser rather than downloaded; anything else (HTML, SVG, scripts) is a download. */
const INLINE = /^(image\/(png|jpeg|gif|webp|heic)|text\/plain|application\/pdf|video\/(mp4|quicktime|webm))$/;

/** A file's name as it's stored: no folders or `..` (refused), other odd characters become dashes. */
export function storedName(raw: string): string | null {
  const name = raw.trim();
  if (!name || /[\/\\\0]/.test(name) || name.includes("..")) return null;
  const clean = name.replace(/[^\w.\-]+/g, "-").replace(/^[.\-]+/, "").slice(-120);
  return clean && !clean.includes("..") ? clean : null;
}

/** POST /api/attachments?name=<file name>: the body is the file, with its content type. */
export async function upload(request: Request, env: Env, me: Member): Promise<Response> {
  const name = storedName(new URL(request.url).searchParams.get("name") ?? "");
  if (!name) return text("Give the file a name without folders or '..'.", 400);
  const said = Number(request.headers.get("content-length") ?? "0");
  if (said > MAX_ATTACHMENT) return text(`Attachments can be up to ${MAX_ATTACHMENT / 1024 / 1024} MB.`, 413);
  const body = await request.arrayBuffer();
  if (body.byteLength > MAX_ATTACHMENT) return text(`Attachments can be up to ${MAX_ATTACHMENT / 1024 / 1024} MB.`, 413);
  if (!body.byteLength) return text("The file is empty.", 400);
  const mime = (request.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase() || "application/octet-stream";
  const id = crypto.randomUUID();
  await env.RELEASES.put(`attachments/${id}/${name}`, body, { httpMetadata: { contentType: mime }, customMetadata: { by: me.login } });
  await audit(env, me.login, "attachment.upload", `${id}/${name}`, { size: body.byteLength, mime });
  return Response.json({ id, name, mime, size: body.byteLength, path: `/attachments/${id}/${name}` }, { status: 201 });
}

/** GET /attachments/<id>/<name> (members) and /runner/attachments/<id>/<name> (runners): the file. */
export async function serve(env: Env, rest: string): Promise<Response> {
  const m = LINK.exec(rest);
  if (!m) return text("Not an attachment.", 400);
  const object = await env.RELEASES.get(`attachments/${m[1]}/${m[2]}`);
  if (!object) return text("Not found.", 404);
  const mime = object.httpMetadata?.contentType ?? "application/octet-stream";
  return new Response(object.body, {
    headers: {
      "content-type": mime,
      "content-length": String(object.size),
      "content-disposition": `${INLINE.test(mime) ? "inline" : "attachment"}; filename="${m[2]}"`,
      // Served from the factory's own origin: never let a file run anything there.
      "content-security-policy": "sandbox; default-src 'none'; img-src 'self'; media-src 'self'",
      "x-content-type-options": "nosniff",
      "cache-control": "private, max-age=31536000, immutable",
      etag: object.httpEtag,
    },
  });
}

/** /runner/attachments/…?runner=<machine>, with that machine's token. */
export async function serveRunner(request: Request, env: Env, rest: string): Promise<Response> {
  const id = new URL(request.url).searchParams.get("runner") ?? "";
  if (!MACHINE_ID.test(id) || !(await authenticateRunner(env, id, request))) return text("Unknown machine or bad token.", 401);
  return serve(env, rest);
}
