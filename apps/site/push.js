// maplefactory.dev's push relay (MF-231): the only thing that talks to Apple (APNs) and Google (FCM) for
// every factory that turns on Settings › General's mobile notifications (server/src/push.ts).
//
//   POST /push/enroll  issues a factory id and secret; only a hash of the secret is kept (KV PUSH).
//   POST /push/revoke  signed by the factory: forgets it, so its sends stop at once.
//   POST /push/send    signed: { factory, token, platform, environment, ref, reason } and nothing else.
//                      At most 5 minutes old, 600 a factory an hour. 410 when the provider says the token
//                      is gone (APNs 410, FCM UNREGISTERED), so the factory deletes the device.
//
// Signatures are hex HMAC-SHA256 over `${timestamp}.${body}` under the factory's secret, in
// x-maple-signature, with x-maple-factory and x-maple-timestamp (seconds). The relay keeps
// SHA-256(secret) and checks the HMAC with it as the key: the factory signs with the same derived key.
// So the stored value IS the signing key, not a one-way check: anyone who can read KV PUSH can forge a
// factory's sends and revokes (never read its secret back, or anything in it). Keeping the raw secret
// out of KV only means it can't be reused elsewhere. Treat the namespace as secret; the worst a forger
// gets is fixed-text pushes ("MF-12 · Needs a hand") to tokens they already hold, within the limits.
//
// Limits: enroll is capped per IP by the PUSH_ENROLL_LIMIT Rate Limiting binding (when it's bound).
// The hourly send count lives in KV, so it's approximate: KV is eventually consistent across colos and
// allows about one write a second to a key. A write it refuses is let through (fail open) rather than
// dropping someone's push; the count only has to stop runaway factories, not meter exact use.
//
// Keys are Worker secrets: APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC (the app's bundle id) and
// FCM_SERVICE_ACCOUNT (the service account's JSON). Until they're set, sends answer 503.

export const MAX_AGE_S = 5 * 60;
export const PER_HOUR = 600;

const enc = new TextEncoder();
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const b64url = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64urlText = (s) => b64url(enc.encode(s));
const json = (body, status = 200) => Response.json(body, { status });
const plain = (text, status) => new Response(text, { status, headers: { "content-type": "text/plain; charset=utf-8" } });

export async function sha256Hex(text) {
  return hex(await crypto.subtle.digest("SHA-256", enc.encode(text)));
}

export async function hmacHex(key, message) {
  const k = await crypto.subtle.importKey("raw", enc.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", k, enc.encode(message)));
}

function safeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const REASON_TEXT = {
  hand: "Needs a hand",
  question: "Asked you a question",
  approval: "Plan ready to approve",
  review: "Ready for your review",
  mention: "You were mentioned",
};

/** Checks a signed request; the body (parsed) and the factory's record, or a Response saying why not. */
async function verify(request, env, nowS) {
  const id = request.headers.get("x-maple-factory") ?? "";
  const ts = Number(request.headers.get("x-maple-timestamp"));
  const sig = request.headers.get("x-maple-signature") ?? "";
  const raw = await request.text();
  if (!/^pf_[\w-]{8,64}$/.test(id) || !Number.isInteger(ts) || !/^[0-9a-f]{64}$/.test(sig)) return plain("A push request has to be signed.", 401);
  if (Math.abs(nowS - ts) > MAX_AGE_S) return plain("That request is too old (or from the future).", 401);
  const record = await env.PUSH.get(`f:${id}`, "json");
  if (!record) return plain("That factory isn't enrolled (or was revoked).", 401);
  if (!safeEqual(await hmacHex(record.key, `${ts}.${raw}`), sig)) return plain("That signature doesn't match.", 401);
  let body;
  try { body = JSON.parse(raw); } catch { return plain("Send JSON.", 400); }
  if (body?.factory !== undefined && body.factory !== id) return plain("That body is for another factory.", 400);
  return { id, body };
}

// APNs: an ES256 provider JWT from the .p8, reused for 50 minutes (Apple wants 20 to 60).

let apnsJwt = null;
function pemBytes(pem) {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

export async function apnsToken(env, nowS) {
  if (apnsJwt && apnsJwt.key === env.APNS_KEY_ID && nowS - apnsJwt.at < 50 * 60) return apnsJwt.jwt;
  const key = await crypto.subtle.importKey("pkcs8", pemBytes(env.APNS_KEY_P8), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64urlText(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const claims = b64urlText(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: nowS }));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${head}.${claims}`));
  apnsJwt = { key: env.APNS_KEY_ID, at: nowS, jwt: `${head}.${claims}.${b64url(sig)}` };
  return apnsJwt.jwt;
}

async function sendApns(env, msg, nowS) {
  const host = msg.environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  const res = await fetch(`${host}/3/device/${encodeURIComponent(msg.token)}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await apnsToken(env, nowS)}`,
      "apns-topic": env.APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-collapse-id": `${msg.factory}/${msg.ref}`.slice(0, 64),
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: { alert: { title: msg.ref, body: REASON_TEXT[msg.reason] }, sound: "default", "mutable-content": 1, "thread-id": msg.ref },
      factory: msg.factory, ref: msg.ref, reason: msg.reason,
    }),
  });
  if (res.ok) return { ok: true };
  const reason = (await res.json().catch(() => ({}))).reason ?? "";
  const gone = res.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered";
  return { ok: false, gone, status: res.status, detail: reason };
}

// FCM HTTP v1: a service-account JWT (RS256) exchanged for an OAuth token, cached until near expiry.

let fcmAuth = null;
export async function fcmAccessToken(env, nowS) {
  const sa = JSON.parse(env.FCM_SERVICE_ACCOUNT);
  if (fcmAuth && fcmAuth.email === sa.client_email && nowS < fcmAuth.expires - 60) return { token: fcmAuth.token, project: sa.project_id };
  const key = await crypto.subtle.importKey("pkcs8", pemBytes(sa.private_key), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const head = b64urlText(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const tokenUri = sa.token_uri || "https://oauth2.googleapis.com/token";
  const claims = b64urlText(JSON.stringify({ iss: sa.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging", aud: tokenUri, iat: nowS, exp: nowS + 3600 }));
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, enc.encode(`${head}.${claims}`));
  const res = await fetch(tokenUri, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${head}.${claims}.${b64url(sig)}` }),
  });
  if (!res.ok) throw new Error(`Google refused the service account (${res.status})`);
  const got = await res.json();
  fcmAuth = { email: sa.client_email, token: got.access_token, expires: nowS + (got.expires_in ?? 3600) };
  return { token: fcmAuth.token, project: sa.project_id };
}

async function sendFcm(env, msg, nowS) {
  const { token, project } = await fcmAccessToken(env, nowS);
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${project}/messages:send`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({
      message: {
        token: msg.token,
        notification: { title: msg.ref, body: REASON_TEXT[msg.reason] },
        data: { factory: msg.factory, ref: msg.ref, reason: msg.reason },
        android: { priority: "high", collapse_key: msg.ref },
      },
    }),
  });
  if (res.ok) return { ok: true };
  const err = (await res.json().catch(() => ({}))).error ?? {};
  const codes = (err.details ?? []).map((d) => d.errorCode);
  const gone = codes.includes("UNREGISTERED") || err.status === "NOT_FOUND";
  return { ok: false, gone, status: res.status, detail: codes[0] ?? err.status ?? "" };
}

const configured = {
  apns: (env) => Boolean(env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_TOPIC),
  fcm: (env) => Boolean(env.FCM_SERVICE_ACCOUNT),
};

/** One hour's sends for a factory, counted in KV; false once it's over the limit. */
async function underLimit(env, id, nowS) {
  const key = `r:${id}:${Math.floor(nowS / 3600)}`;
  const n = Number((await env.PUSH.get(key).catch(() => 0)) ?? 0);
  if (n >= PER_HOUR) return false;
  // KV refuses (429) a second write to one key within a second, as a burst of sends does: fail open.
  await env.PUSH.put(key, String(n + 1), { expirationTtl: 7200 }).catch(() => {});
  return true;
}

/** Handles /push/*; null for any other path. `nowS` is for tests. */
export async function handlePush(request, env, nowS = Math.floor(Date.now() / 1000)) {
  const path = new URL(request.url).pathname;
  if (!path.startsWith("/push/")) return null;
  if (request.method !== "POST") return plain("Method not allowed.", 405);
  if (!env.PUSH) return plain("push isn't configured yet", 503);

  if (path === "/push/enroll") {
    if (env.PUSH_ENROLL_LIMIT) {
      const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
      const { success } = await env.PUSH_ENROLL_LIMIT.limit({ key: ip });
      if (!success) return plain("Too many enrollments from here; try again in a minute.", 429);
    }
    const id = `pf_${b64url(crypto.getRandomValues(new Uint8Array(12)))}`;
    const secret = `pfs_${b64url(crypto.getRandomValues(new Uint8Array(32)))}`;
    await env.PUSH.put(`f:${id}`, JSON.stringify({ key: await sha256Hex(secret), at: nowS }));
    return json({ id, secret });
  }

  const checked = await verify(request, env, nowS);
  if (checked instanceof Response) return checked;
  const { id, body } = checked;

  if (path === "/push/revoke") {
    await env.PUSH.delete(`f:${id}`);
    return new Response(null, { status: 204 });
  }

  if (path === "/push/send") {
    const { token, platform, environment, ref, reason } = body ?? {};
    if (platform !== "apns" && platform !== "fcm") return plain("platform is apns or fcm.", 400);
    if (typeof token !== "string" || !token || token.length > 4096) return plain("Send a device token.", 400);
    if (typeof ref !== "string" || !/^[\w-]{1,40}$/.test(ref)) return plain("ref is a task key, like MF-12.", 400);
    if (!(reason in REASON_TEXT)) return plain("That isn't a reason.", 400);
    if (platform === "apns" && environment !== "sandbox" && environment !== "production") return plain("environment is sandbox or production.", 400);
    if (!configured[platform](env)) return plain("push isn't configured yet", 503);
    if (!(await underLimit(env, id, nowS))) return plain(`Over ${PER_HOUR} pushes this hour.`, 429);
    const msg = { factory: id, token, platform, environment, ref, reason };
    let result;
    try {
      result = platform === "apns" ? await sendApns(env, msg, nowS) : await sendFcm(env, msg, nowS);
    } catch (e) {
      // Apple or Google unreachable, a bad FCM_SERVICE_ACCOUNT, or Google refusing it: say so, not a bare 500.
      return json({ sent: false, status: 0, detail: String(e?.message ?? e).slice(0, 200) }, 502);
    }
    if (result.ok) return json({ sent: true });
    if (result.gone) return json({ sent: false, gone: true }, 410);
    return json({ sent: false, status: result.status, detail: result.detail }, 502);
  }
  return plain("Not found.", 404);
}

/** For tests: forget cached provider tokens. */
export function resetCaches() {
  apnsJwt = null;
  fcmAuth = null;
}
