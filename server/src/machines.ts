// Machines: one-time enrollment codes, per-machine runner tokens, and the list in D1.

import type { Env } from "./env.ts";
import { revoked } from "./auth.ts";
import type { Machine, MachineSettings, Member } from "./wire.ts";
import { audit, machineHub, orgHub, publicOrigin, randomCode, randomToken, sameText, sha256, text } from "./util.ts";

export const MACHINE_ID = /^[a-z0-9][a-z0-9-]{0,62}$/;
const CODE_TTL = 15 * 60 * 1000;

export interface MachineRow {
  id: string;
  name: string | null;
  owner: string;
  token_hash: string;
  hostname: string | null;
  os: string | null;
  arch: string | null;
  version: string | null;
  created_at: number;
  last_seen: number | null;
  capabilities?: string | null;
}

/** The capability tags stored in a machine row's JSON column; none for a row from before they were reported. */
export function parseCapabilities(column: string | null | undefined): string[] | null {
  if (!column) return null;
  try {
    const tags = JSON.parse(column);
    return Array.isArray(tags) ? tags.filter((t): t is string => typeof t === "string") : null;
  } catch {
    return null;
  }
}

/** The tags the apps show: what was detected minus what the owner hid, plus what they added; sorted, once each. */
export function effectiveTags(capabilities: string[] | null | undefined, settings: Pick<MachineSettings, "extraTags" | "hiddenTags"> | null | undefined): string[] {
  const hidden = new Set(settings?.hiddenTags ?? []);
  const tags = new Set((capabilities ?? []).filter((t) => !hidden.has(t)));
  for (const t of settings?.extraTags ?? []) tags.add(t);
  return [...tags].sort();
}

const TAG = /^[a-z0-9][a-z0-9-]*$/;
const MAX_TAGS = 20;
const MAX_TAG_LENGTH = 32;

/** An owner's tags tidied (trimmed, lowercase, once each), or why they're refused. */
export function cleanTags(tags: unknown, what: string): { tags: string[] } | { error: string } {
  if (tags == null) return { tags: [] };
  if (!Array.isArray(tags)) return { error: `${what} must be a list of tags.` };
  const out = new Set<string>();
  for (const raw of tags) {
    const tag = String(raw ?? "").trim().toLowerCase();
    if (!tag) continue;
    if (tag.length > MAX_TAG_LENGTH) return { error: `“${tag}” is too long: tags are at most ${MAX_TAG_LENGTH} characters.` };
    if (!TAG.test(tag)) return { error: `“${tag}” isn't a tag: use lowercase letters, digits and dashes, e.g. gpu or big-disk.` };
    out.add(tag);
  }
  if (out.size > MAX_TAGS) return { error: `A machine takes at most ${MAX_TAGS} ${what.toLowerCase()}.` };
  return { tags: [...out] };
}

/** A machine as the apps see it when its hub has nothing live to add. */
export function offlineMachine(row: MachineRow): Machine {
  return {
    id: row.id,
    name: row.name ?? row.id,
    owner: row.owner,
    online: false,
    lastSeen: row.last_seen,
    version: row.version,
    os: row.os,
    health: null,
    sessions: [],
    usage: [],
    capabilities: parseCapabilities(row.capabilities),
  };
}

export async function machineRows(env: Env): Promise<MachineRow[]> {
  const { results } = await env.DB.prepare("SELECT * FROM machines ORDER BY owner, id").all<MachineRow>();
  return results;
}

export async function machineRow(env: Env, id: string) {
  return env.DB.prepare("SELECT * FROM machines WHERE id = ?").bind(id).first<MachineRow>();
}

/** POST /api/machines/enroll: a one-time code for adding a machine, owned by whoever asked. */
export async function createEnrollment(request: Request, env: Env, me: Member): Promise<Response> {
  const code = randomCode();
  const now = Date.now();
  await env.DB.prepare("INSERT INTO enroll_codes (code_hash, owner, created_at, expires_at) VALUES (?, ?, ?, ?)")
    .bind(await sha256(code), me.login, now, now + CODE_TTL).run();
  await audit(env, me.login, "machine.enrollment_created");
  const origin = publicOrigin(request, env);
  return Response.json({
    code,
    expiresAt: now + CODE_TTL,
    commands: [`curl -fsSL ${origin}/install.sh | sh -s -- ${code}`],
  });
}

/** POST /runner/enroll: swaps a one-time code for a long-lived runner token. */
export async function enroll(request: Request, env: Env): Promise<Response> {
  const body = (await request.json().catch(() => null)) as {
    code?: string; runnerId?: string; hostname?: string; os?: string; arch?: string; version?: string;
  } | null;
  if (!body?.code) return text("Missing enrollment code.", 400);
  const id = String(body.runnerId ?? "");
  if (!MACHINE_ID.test(id)) return text("Machine names use lowercase letters, digits and dashes, starting with a letter or digit.", 400);

  const now = Date.now();
  // Claim the code in one statement so two machines can't both use it.
  const claimed = await env.DB.prepare(
    "UPDATE enroll_codes SET used_at = ?, machine_id = ? WHERE code_hash = ? AND used_at IS NULL AND expires_at > ? RETURNING owner",
  ).bind(now, id, await sha256(body.code.trim().toUpperCase()), now).first<{ owner: string }>();
  if (!claimed) return text("That code is wrong, expired or already used. Get a new one from Add machine.", 403);

  const existing = await machineRow(env, id);
  if (existing && existing.owner !== claimed.owner) {
    return text(`${id} already belongs to ${existing.owner}. Enroll with another --runner-id, or ask them to remove it.`, 409);
  }
  const token = randomToken("mfr");
  await env.DB.prepare(
    `INSERT INTO machines (id, owner, token_hash, hostname, os, arch, version, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
     ON CONFLICT (id) DO UPDATE SET token_hash = ?3, hostname = ?4, os = ?5, arch = ?6, version = ?7`,
  ).bind(id, claimed.owner, await sha256(token), body.hostname ?? null, body.os ?? null, body.arch ?? null, body.version ?? null, now).run();
  await audit(env, claimed.owner, existing ? "machine.reenrolled" : "machine.enrolled", id, { hostname: body.hostname });
  // A re-enrolled machine's old connection, and old token, stop working now.
  if (existing) await machineHub(env, id).fetch("https://hub/disconnect", { method: "POST" });
  return Response.json({ runnerId: id, token });
}

/** The machine's token, and an owner who still has access: a revoked owner's machines stay offline until they sign in again. */
export async function authenticateRunner(env: Env, id: string, request: Request): Promise<boolean> {
  const token = /^Bearer (\S+)$/.exec(request.headers.get("authorization") ?? "")?.[1];
  if (!token) return false;
  const row = await env.DB.prepare(
    "SELECT t.token_hash, m.revoked_at, m.last_seen FROM machines t LEFT JOIN members m ON m.login = t.owner WHERE t.id = ?",
  ).bind(id).first<{ token_hash: string; revoked_at: number | null; last_seen: number | null }>();
  return !!row && sameText(row.token_hash, await sha256(token)) && !revoked(row);
}

/** DELETE /api/machines/:id: forgets a machine and cuts it off. Its owner or an admin. */
export async function removeMachine(env: Env, me: Member, id: string): Promise<Response> {
  const row = await machineRow(env, id);
  if (!row) return text("No such machine.", 404);
  if (row.owner !== me.login && me.role !== "admin") return text(`Only ${row.owner} or an admin can remove ${id}.`, 403);
  await forgetMachine(env, id, me.login, "machine.removed");
  return new Response(null, { status: 204 });
}

/** POST /runner/unenroll: a machine forgets itself with its own token, e.g. `maple-runner unenroll`. */
export async function unenroll(request: Request, env: Env): Promise<Response> {
  const body = (await request.json().catch(() => null)) as { runnerId?: string } | null;
  const id = String(body?.runnerId ?? new URL(request.url).searchParams.get("runner") ?? "");
  if (!MACHINE_ID.test(id) || !(await authenticateRunner(env, id, request))) return text("Unknown machine or bad token.", 401);
  const row = await machineRow(env, id);
  if (!row) return text("Unknown machine or bad token.", 401);
  await forgetMachine(env, id, row.owner, "machine.unenrolled");
  return new Response(null, { status: 204 });
}

/** Deletes the machine row (its token with it), drops its hub's connection and tells the apps. */
async function forgetMachine(env: Env, id: string, actor: string, action: string): Promise<void> {
  await env.DB.prepare("DELETE FROM machines WHERE id = ?").bind(id).run();
  await machineHub(env, id).fetch("https://hub/disconnect", { method: "POST", body: "forget" });
  await orgHub(env).fetch("https://org/removed", { method: "POST", body: id });
  await audit(env, actor, action, id);
}
