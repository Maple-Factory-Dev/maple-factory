// Attachments: screenshots and files pasted or dropped into a brief or a Scratchpad note. They're kept
// in the factory's bucket (RELEASES, which every factory already has) under attachments/<id>/<name>,
// and a note links to them as /attachments/<id>/<name>. Members fetch them there; runners fetch them
// with their own token at /runner/attachments/<id>/<name>, into a cache folder for their agents.

import type { Env } from "./env.ts";
import { authenticateRunner, MACHINE_ID } from "./machines.ts";
import type { Member } from "./wire.ts";
import { audit, readCapped, text } from "./util.ts";

export const MAX_ATTACHMENT = 25 * 1024 * 1024;

/** `<uuid>/<name>`: what follows /attachments/ in a link. */
const LINK = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/([\w.\-]{1,120})$/;

/** Shown in the browser rather than downloaded; anything else (HTML, SVG, scripts) is a download. */
const INLINE = /^(image\/(png|jpeg|gif|webp|heic)|text\/plain|application\/pdf|video\/(mp4|quicktime|webm))$/;

/** A file's name as it's stored: no folders or `..` (refused), other odd characters become dashes, and no
 * trailing dots (a link's name ends before a sentence's full stop, so the runner couldn't ask for it). */
export function storedName(raw: string): string | null {
  const name = raw.trim();
  if (!name || /[\/\\\0]/.test(name) || name.includes("..")) return null;
  const clean = name.replace(/[^\w.\-]+/g, "-").replace(/^[.\-]+/, "").slice(-120).replace(/\.+$/, "");
  return clean && !clean.includes("..") ? clean : null;
}

/** POST /api/attachments?name=<file name>: the body is the file, with its content type. */
export async function upload(request: Request, env: Env, me: Member): Promise<Response> {
  const name = storedName(new URL(request.url).searchParams.get("name") ?? "");
  if (!name) return text("Give the file a name without folders or '..'.", 400);
  const body = await readCapped(request, MAX_ATTACHMENT);
  if (!body) return text(`Attachments can be up to ${MAX_ATTACHMENT / 1024 / 1024} MB.`, 413);
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

/** A proof file's limit: a screenshot or text capture, or a screen recording. */
export const MAX_PROOF_IMAGE = 5 * 1024 * 1024;
export const MAX_PROOF_VIDEO = 25 * 1024 * 1024;

/** What a proof file is from its first bytes, as the runner decides it (`sniff` in runner/src/proof.rs). */
export function sniffProof(b: Uint8Array): string | null {
  const at = (i: number, s: string) => [...s].every((c, j) => b[i + j] === c.charCodeAt(0));
  if (b[0] === 0x89 && at(1, "PNG")) return "image/png";
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (at(0, "RIFF") && at(8, "WEBP")) return "image/webp";
  if (at(4, "ftyp")) return at(8, "qt  ") ? "video/quicktime" : /^M4[ABP] $/.test(String.fromCharCode(...b.slice(8, 12))) ? null : "video/mp4";
  if (b[0] === 0x1a && b[1] === 0x45 && b[2] === 0xdf && b[3] === 0xa3) return "video/webm";
  if (!b.includes(0)) {
    try {
      new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(b);
      return "text/plain";
    } catch {}
  }
  return null;
}

/** The task ids `PUT /runner/proof/<task>` takes. */
const TASK_ID = /^[A-Z][A-Z0-9]{0,9}-\d+$/;

/** PUT /runner/proof/<task>?runner=<machine>&name=<file name>, with that machine's token: a `prove` call's
 *  file (runner/src/proof.rs `upload`). It's kept like an attachment, so members fetch it at the key. */
export async function uploadProof(request: Request, env: Env, task: string): Promise<Response> {
  const url = new URL(request.url);
  const runner = url.searchParams.get("runner") ?? "";
  if (!MACHINE_ID.test(runner) || !(await authenticateRunner(env, runner, request))) return text("Unknown machine or bad token.", 401);
  if (!TASK_ID.test(task)) return text("Not a task.", 400);
  const name = storedName(url.searchParams.get("name") ?? "");
  if (!name) return text("Give the file a name without folders or '..'.", 400);
  const body = await readCapped(request, MAX_PROOF_VIDEO);
  if (!body) return text(`A proof file is at most ${MAX_PROOF_VIDEO / 1024 / 1024} MB.`, 413);
  if (!body.byteLength) return text("The file is empty.", 400);
  const mime = sniffProof(body);
  if (!mime) return text("A proof file is PNG, JPEG, WebP, MP4, MOV, WebM or text.", 415);
  const max = mime.startsWith("video/") ? MAX_PROOF_VIDEO : MAX_PROOF_IMAGE;
  if (body.byteLength > max) return text(`A ${mime.startsWith("video/") ? "video" : "file"} proof is at most ${max / 1024 / 1024} MB.`, 413);
  const id = crypto.randomUUID();
  await env.RELEASES.put(`attachments/${id}/${name}`, body, { httpMetadata: { contentType: mime }, customMetadata: { task, runner } });
  await audit(env, `runner:${runner}`, "proof.upload", `${id}/${name}`, { task, size: body.byteLength, mime });
  return Response.json({ key: `/attachments/${id}/${name}`, type: mime, bytes: body.byteLength }, { status: 201 });
}

/** Whether `key` is a stored attachment's link, `/attachments/<uuid>/<name>`. */
export const isAttachmentKey = (key: unknown): key is string => typeof key === "string" && key.startsWith("/attachments/") && LINK.test(key.slice("/attachments/".length));
