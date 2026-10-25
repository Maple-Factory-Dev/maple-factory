import type { Env } from "./env.ts";

const enc = new TextEncoder();

export async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", enc.encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function b64url(bytes: ArrayBuffer | Uint8Array): string {
  const s = btoa(String.fromCharCode(...new Uint8Array(bytes)));
  return s.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromB64url(s: string): Uint8Array {
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

/** A random secret with a recognisable prefix, so a leaked one is easy to spot (and scan for). */
export function randomToken(prefix: string): string {
  return `${prefix}_${b64url(crypto.getRandomValues(new Uint8Array(32)))}`;
}

// No 0/O/1/I/L, so a code read off a screen types correctly.
const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

export function randomCode(): string {
  const chars = [...crypto.getRandomValues(new Uint8Array(8))].map((b) => CODE_ALPHABET[b % CODE_ALPHABET.length]);
  return `${chars.slice(0, 4).join("")}-${chars.slice(4).join("")}`;
}

async function hmacKey(secret: string) {
  return crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

export async function sign(payload: object, secret: string): Promise<string> {
  const body = b64url(enc.encode(JSON.stringify(payload)));
  const mac = await crypto.subtle.sign("HMAC", await hmacKey(secret), enc.encode(body));
  return `${body}.${b64url(mac)}`;
}

export async function verify<T extends { exp: number }>(token: string | undefined, secret: string): Promise<T | null> {
  const [body, mac] = token?.split(".") ?? [];
  if (!body || !mac) return null;
  try {
    const ok = await crypto.subtle.verify("HMAC", await hmacKey(secret), fromB64url(mac), enc.encode(body));
    if (!ok) return null;
    const payload = JSON.parse(new TextDecoder().decode(fromB64url(body))) as T;
    return payload.exp > Date.now() / 1000 ? payload : null;
  } catch {
    return null;
  }
}

export function text(message: string, status = 200) {
  return new Response(message, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
}

export async function audit(env: Env, actor: string, action: string, target?: string | null, detail?: unknown) {
  try {
    await env.DB.prepare("INSERT INTO audit (at, actor, action, target, detail) VALUES (?, ?, ?, ?, ?)")
      .bind(Date.now(), actor, action, target ?? null, detail == null ? null : JSON.stringify(detail))
      .run();
  } catch (e) {
    console.error("audit write failed", e);
  }
}

/** The origin people reach this server at: PUBLIC_URL when set (`wrangler dev` hands the Worker
 *  "http://localhost", port dropped), else the request's. */
export function publicOrigin(request: Request, env: Env) {
  return env.PUBLIC_URL ? env.PUBLIC_URL.replace(/\/+$/, "") : new URL(request.url).origin;
}

export function isLocal(request: Request) {
  const host = new URL(request.url).hostname;
  return host === "localhost" || host === "127.0.0.1";
}

/** The one org's hub. Keep it near home so keystrokes stay snappy. */
export function orgHub(env: Env) {
  return env.ORG.get(env.ORG.idFromName("org"));
}

export function machineHub(env: Env, id: string) {
  return env.MACHINE.get(env.MACHINE.idFromName(id));
}
