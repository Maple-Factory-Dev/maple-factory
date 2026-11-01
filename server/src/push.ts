// Mobile push (MF-231): Settings › General's opt-in relay for APNs and FCM. Off by default. Turning it on
// enrolls the factory with the push relay at maplefactory.dev (apps/site/push.js), which holds Apple's and
// Google's keys and is the only thing that talks to them. Members' phones register device tokens here
// (push_devices in OrgHub's SQLite, factory/store.ts); when a task newly needs someone, the factory sends
// the relay a signed request holding only the device token, the task key, the reason and the factory id.
// The app loads everything else from the factory. Turning it off revokes the credential at once.
//
// The relay credential ({ id, secret }) is sealed with AES-GCM under SECRETS_KEY (secrets.ts) and kept in
// D1's settings as PUSH_CREDENTIAL. A Worker var PUSH_RELAY=off locks it off; PUSH_RELAY_URL points it at
// another relay (tests use a fake one).

import type { Env } from "./env.ts";
import type { Member, Task } from "./wire.ts";
import type { PushDeviceRow, Store } from "./factory/store.ts";
import { aesKey, secretsKey } from "./secrets.ts";
import { inQuietHours } from "./quiet-hours.ts";
import { audit, b64url, fromB64url, sha256, text } from "./util.ts";

export type PushReason = "hand" | "question" | "approval" | "review" | "mention";
export interface Credential { id: string; secret: string }

const enc = new TextEncoder();
const dec = new TextDecoder();
const KEY = "PUSH_CREDENTIAL";
const INFO = "push-relay v1";
const DEFAULT_RELAY = "https://maplefactory.dev";

export const relayUrl = (env: Env) => (env.PUSH_RELAY_URL || DEFAULT_RELAY).replace(/\/+$/, "");
export const locked = (env: Env) => env.PUSH_RELAY === "off";

// The credential, sealed at rest.

export async function seal(secretsKeyValue: string, cred: Credential): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: enc.encode(KEY) }, await aesKey(secretsKeyValue, INFO), enc.encode(JSON.stringify(cred)));
  return `v1.${b64url(iv)}.${b64url(sealed)}`;
}

export async function unseal(secretsKeyValue: string, value: string): Promise<Credential> {
  const [v, iv, ct] = value.split(".");
  if (v !== "v1" || !iv || !ct) throw new Error("push: an unreadable credential");
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromB64url(iv), additionalData: enc.encode(KEY) }, await aesKey(secretsKeyValue, INFO), fromB64url(ct));
  return JSON.parse(dec.decode(plain)) as Credential;
}

export async function credential(env: Env): Promise<Credential | null> {
  const row = await env.DB.prepare("SELECT value FROM settings WHERE key = ?").bind(KEY).first<{ value: string }>();
  if (!row) return null;
  return unseal(await secretsKey(env), row.value);
}

async function saveCredential(env: Env, cred: Credential) {
  const value = await seal(await secretsKey(env), cred);
  await env.DB.prepare("INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at")
    .bind(KEY, value, Date.now()).run();
}

async function deleteCredential(env: Env) {
  await env.DB.prepare("DELETE FROM settings WHERE key = ?").bind(KEY).run();
}

// Signing: hex HMAC-SHA256 over `${timestamp}.${body}`, keyed with SHA-256(secret) in hex: the relay
// keeps only that hash, never the secret itself (apps/site/push.js).

export async function sign(secret: string, timestamp: number, body: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(await sha256(secret)), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`${timestamp}.${body}`));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** What goes to the relay for one device: nothing but these fields. No titles, comments, code or repo names. */
export function payload(factory: string, device: Pick<PushDeviceRow, "token" | "platform" | "environment">, ref: string, reason: PushReason) {
  return { factory, token: device.token, platform: device.platform, environment: device.environment, ref, reason };
}

/** A device's id in the apps: a hash of its token, so the token itself never goes back out. */
export const deviceId = async (token: string) => (await sha256(`push-device\n${token}`)).slice(0, 16);

// Who a task newly needs, for the reasons the Mac Notifier uses (FactoryClient.notify, LiveAdapter.needsYou).

function needs(t: Task, login: string): PushReason | null {
  if (t.hand?.assignee === login) return "hand";
  if (t.question && t.owner === login) return "question";
  if (t.state === "awaitingApproval" && !t.approvals.includes(login)) return "approval";
  const round = t.autoReview?.rounds.at(-1);
  if (t.state === "reviewing" && round?.verdict === "passed" && t.reviews.length < t.reviewsNeeded && !t.reviews.includes(login)) return "review";
  return null;
}

/** Each person this save newly needs, and why. Nothing for a new task's first save beyond what it needs. */
export function pushReasons(old: Task | null, task: Task, logins: string[]): Array<{ login: string; reason: PushReason }> {
  const out: Array<{ login: string; reason: PushReason }> = [];
  const seen = new Set(old?.comments.map((c) => c.id) ?? []);
  const mentioned = new Set<string>();
  for (const c of task.comments) {
    if (seen.has(c.id)) continue;
    for (const m of c.mentions ?? []) if (m.toLowerCase() !== c.author.toLowerCase()) mentioned.add(m.toLowerCase());
  }
  // Newly requested reviewers: needs() already counts everyone for an approval, so a request alone wouldn't push.
  const wasRequested = new Set((old?.requested ?? []).map((l) => l.toLowerCase()));
  const requested = new Set((task.requested ?? []).map((l) => l.toLowerCase()).filter((l) => !wasRequested.has(l)));
  const requestReason: PushReason = task.state === "awaitingApproval" ? "approval" : task.state === "reviewing" ? "review" : "mention";
  for (const login of logins) {
    if (mentioned.has(login.toLowerCase())) out.push({ login, reason: "mention" });
    const now = needs(task, login);
    const before = old ? needs(old, login) : null;
    const handRaised = !old?.hand && task.hand?.assignee === login;
    if (now && (!before || handRaised)) out.push({ login, reason: now });
    else if (requested.has(login.toLowerCase()) && !(requestReason === "mention" && mentioned.has(login.toLowerCase()))) out.push({ login, reason: requestReason });
  }
  return out;
}

/** Sends pushes for one OrgHub: devices from its store, quiet hours from its store, the credential from D1. */
export class Push {
  private cache: { at: number; cred: Credential | null } | null = null;
  constructor(private env: Env, private store: Store) {}

  forget() { this.cache = null; }

  /** The credential while the relay is on, else null. Read again every 30 s, or after forget(). */
  async on(): Promise<Credential | null> {
    if (locked(this.env)) return null;
    if (!this.cache || Date.now() - this.cache.at > 30_000) {
      let cred: Credential | null = null;
      try { cred = await credential(this.env); } catch (e) { console.error("push: credential", e); }
      this.cache = { at: Date.now(), cred };
    }
    return this.cache.cred;
  }

  /** A task was saved: push to whoever it newly needs. Nothing at all while the relay is off. */
  async taskSaved(old: Task | null, task: Task, members: () => Promise<Member[]>): Promise<void> {
    const cred = await this.on();
    if (!cred) return;
    const logins = (await members()).map((m) => m.login);
    for (const { login, reason } of pushReasons(old, task, logins)) await this.send(login, { ref: task.id, reason }, cred);
  }

  /** One push to each of `login`'s devices. Skipped while the relay is off or they're in quiet hours. */
  async send(login: string, what: { ref: string; reason: PushReason }, cred?: Credential | null): Promise<number> {
    cred ??= await this.on();
    if (!cred) return 0;
    if (inQuietHours(this.store.quietHours(login), Date.now())) return 0;
    let sent = 0;
    for (const device of this.store.pushDevices(login)) {
      const body = JSON.stringify(payload(cred.id, device, what.ref, what.reason));
      const ts = Math.floor(Date.now() / 1000);
      try {
        const res = await fetch(`${relayUrl(this.env)}/push/send`, {
          method: "POST",
          headers: { "content-type": "application/json", "x-maple-factory": cred.id, "x-maple-timestamp": String(ts), "x-maple-signature": await sign(cred.secret, ts, body) },
          body,
        });
        // The relay says APNs answered 410 or FCM UNREGISTERED: the app was removed, so is the device.
        if (res.status === 410) this.store.removePushDevice(device.token);
        else if (res.ok) sent++;
        else console.error(`push: the relay answered ${res.status}`, await res.text().catch(() => ""));
      } catch (e) {
        console.error("push: couldn't reach the relay", e);
      }
    }
    return sent;
  }
}

// Settings › General: GET/PUT /api/push.

async function state(env: Env, devices: number) {
  let enrolled = false;
  try { enrolled = (await credential(env)) !== null; } catch { enrolled = false; }
  return { on: enrolled && !locked(env), locked: locked(env), enrolled, devices };
}

/** GET /api/push: { on, locked, enrolled, devices }. `devices` counts every member's. */
export async function get(env: Env, devices: number): Promise<Response> {
  return Response.json(await state(env, devices));
}

/** PUT /api/push: admins only; the body is `{ on }`. On enrolls with the relay; off revokes there and forgets the credential. */
export async function set(request: Request, env: Env, me: Member, devices: () => Promise<number>, changed: () => Promise<void>): Promise<Response> {
  if (me.role !== "admin") return text("Only admins can change the factory's mobile notifications.", 403);
  const body = (await request.json().catch(() => null)) as { on?: unknown } | null;
  if (typeof body?.on !== "boolean") return text("Send whether mobile notifications are on as { on }.", 400);
  if (locked(env)) return text("The Worker's PUSH_RELAY=off turns this off; change it there.", 409);
  const current = await credential(env).catch(() => null);
  if (body.on && !current) {
    let res: Response;
    try {
      res = await fetch(`${relayUrl(env)}/push/enroll`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
    } catch {
      return text("Couldn't reach the push relay at maplefactory.dev. Try again in a minute.", 502);
    }
    const cred = (await res.json().catch(() => null)) as Partial<Credential> | null;
    if (!res.ok || typeof cred?.id !== "string" || typeof cred?.secret !== "string") return text(`The push relay refused to enroll this factory (${res.status}).`, 502);
    await saveCredential(env, { id: cred.id, secret: cred.secret });
    await audit(env, me.login, "push.relay.on", null, { factory: cred.id });
  } else if (!body.on && current) {
    // Forget it here first: sends stop now, whether or not the relay hears the revoke.
    await deleteCredential(env);
    const ts = Math.floor(Date.now() / 1000);
    const revoke = JSON.stringify({ factory: current.id });
    await fetch(`${relayUrl(env)}/push/revoke`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-maple-factory": current.id, "x-maple-timestamp": String(ts), "x-maple-signature": await sign(current.secret, ts, revoke) },
      body: revoke,
    }).catch((e) => console.error("push: revoke didn't reach the relay", e));
    await audit(env, me.login, "push.relay.off", null, { factory: current.id });
  }
  await changed();
  return Response.json(await state(env, await devices()));
}
