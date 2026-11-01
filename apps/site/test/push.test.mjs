// The push relay (push.js): signatures, replay, revocation, rate limits, and the APNs and FCM requests
// it builds, against mocked providers. node --test apps/site/test/
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { handlePush, hmacHex, sha256Hex, resetCaches, PER_HOUR } from "../push.js";

class KV {
  map = new Map();
  async get(k, type) { const v = this.map.get(k); return v == null ? null : type === "json" ? JSON.parse(v) : v; }
  async put(k, v) { this.map.set(k, v); }
  async delete(k) { this.map.delete(k); }
}

const NOW = 1_800_000_000;
const ec = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const rsa = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
const pem = async (key, label) => `-----BEGIN ${label}-----\n${Buffer.from(await crypto.subtle.exportKey("pkcs8", key)).toString("base64")}\n-----END ${label}-----\n`;
const KEYS = {
  APNS_KEY_P8: await pem(ec.privateKey, "PRIVATE KEY"), APNS_KEY_ID: "KEY1234567", APNS_TEAM_ID: "TEAM123456", APNS_TOPIC: "dev.maplefactory.ios",
  FCM_SERVICE_ACCOUNT: JSON.stringify({ client_email: "relay@maple.iam.gserviceaccount.com", private_key: await pem(rsa.privateKey, "PRIVATE KEY"), project_id: "maple-push" }),
};

let env, calls, provider;
beforeEach(() => {
  resetCaches();
  env = { PUSH: new KV(), ...KEYS };
  calls = [];
  provider = () => new Response(null, { status: 200 });
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    if (String(url) === "https://oauth2.googleapis.com/token") return Response.json({ access_token: "ya29.test", expires_in: 3600 });
    return provider(String(url), init);
  };
});

const post = (path, body = "{}", headers = {}) => new Request(`https://maplefactory.dev${path}`, { method: "POST", body, headers });
async function enroll() { return (await handlePush(post("/push/enroll"), env, NOW)).json(); }
async function signed(path, cred, body, ts = NOW, tamper = false) {
  const raw = JSON.stringify(body);
  let sig = await hmacHex(await sha256Hex(cred.secret), `${ts}.${raw}`);
  if (tamper) sig = sig.replace(/^./, (c) => (c === "0" ? "1" : "0"));
  return handlePush(post(path, raw, { "x-maple-factory": cred.id, "x-maple-timestamp": String(ts), "x-maple-signature": sig }), env, NOW);
}
const msg = (cred, over = {}) => ({ factory: cred.id, token: "a1b2c3d4e5f6", platform: "apns", environment: "sandbox", ref: "MF-12", reason: "hand", ...over });
const b64json = (s) => JSON.parse(Buffer.from(s, "base64url").toString());

test("enroll keeps only a hash of the secret", async () => {
  const cred = await enroll();
  assert.match(cred.id, /^pf_/);
  assert.match(cred.secret, /^pfs_/);
  const stored = JSON.stringify([...env.PUSH.map.values()]);
  assert.ok(!stored.includes(cred.secret));
  assert.ok(stored.includes(await sha256Hex(cred.secret)));
});

test("a bad signature is rejected", async () => {
  const cred = await enroll();
  const res = await signed("/push/send", cred, msg(cred), NOW, true);
  assert.equal(res.status, 401);
  assert.equal(calls.length, 0);
});

test("a request over 5 minutes old is rejected", async () => {
  const cred = await enroll();
  assert.equal((await signed("/push/send", cred, msg(cred), NOW - 301)).status, 401);
  assert.equal((await signed("/push/send", cred, msg(cred), NOW - 299)).status, 200);
});

test("a revoked factory is rejected", async () => {
  const cred = await enroll();
  assert.equal((await signed("/push/revoke", cred, { factory: cred.id })).status, 204);
  const res = await signed("/push/send", cred, msg(cred));
  assert.equal(res.status, 401);
  assert.match(await res.text(), /revoked/);
});

test("a factory over 600 sends an hour is rejected", async () => {
  const cred = await enroll();
  env.PUSH.map.set(`r:${cred.id}:${Math.floor(NOW / 3600)}`, String(PER_HOUR - 1));
  assert.equal((await signed("/push/send", cred, msg(cred))).status, 200);
  assert.equal((await signed("/push/send", cred, msg(cred))).status, 429);
});

test("builds an APNs request with an ES256 provider JWT", async () => {
  const cred = await enroll();
  assert.equal((await signed("/push/send", cred, msg(cred))).status, 200);
  const [call] = calls;
  assert.equal(call.url, "https://api.sandbox.push.apple.com/3/device/a1b2c3d4e5f6");
  assert.equal(call.init.headers["apns-topic"], "dev.maplefactory.ios");
  assert.equal(call.init.headers["apns-push-type"], "alert");
  const [h, c, s] = call.init.headers.authorization.replace("bearer ", "").split(".");
  assert.deepEqual(b64json(h), { alg: "ES256", kid: "KEY1234567" });
  assert.deepEqual(b64json(c), { iss: "TEAM123456", iat: NOW });
  assert.ok(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, ec.publicKey, Buffer.from(s, "base64url"), new TextEncoder().encode(`${h}.${c}`)));
  const body = JSON.parse(call.init.body);
  assert.deepEqual(body, { aps: { alert: { title: "MF-12", body: "Needs a hand" }, sound: "default", "mutable-content": 1, "thread-id": "MF-12" }, factory: cred.id, ref: "MF-12", reason: "hand" });
  await signed("/push/send", cred, msg(cred, { environment: "production" }));
  assert.equal(calls[1].url, "https://api.push.apple.com/3/device/a1b2c3d4e5f6");
});

test("builds an FCM v1 request with a cached OAuth token from the service account", async () => {
  const cred = await enroll();
  assert.equal((await signed("/push/send", cred, msg(cred, { platform: "fcm", environment: "production" }))).status, 200);
  assert.equal((await signed("/push/send", cred, msg(cred, { platform: "fcm", environment: "production", reason: "review" }))).status, 200);
  const tokenCalls = calls.filter((c) => c.url.startsWith("https://oauth2"));
  assert.equal(tokenCalls.length, 1, "the OAuth token is cached");
  const form = new URLSearchParams(tokenCalls[0].init.body.toString());
  assert.equal(form.get("grant_type"), "urn:ietf:params:oauth:grant-type:jwt-bearer");
  const [h, c, s] = form.get("assertion").split(".");
  assert.deepEqual(b64json(h), { alg: "RS256", typ: "JWT" });
  assert.equal(b64json(c).scope, "https://www.googleapis.com/auth/firebase.messaging");
  assert.ok(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", rsa.publicKey, Buffer.from(s, "base64url"), new TextEncoder().encode(`${h}.${c}`)));
  const send = calls.find((c) => c.url.startsWith("https://fcm"));
  assert.equal(send.url, "https://fcm.googleapis.com/v1/projects/maple-push/messages:send");
  assert.equal(send.init.headers.authorization, "Bearer ya29.test");
  assert.deepEqual(JSON.parse(send.init.body).message.data, { factory: cred.id, ref: "MF-12", reason: "hand" });
});

test("a gone token answers 410 (APNs 410, FCM UNREGISTERED)", async () => {
  const cred = await enroll();
  provider = () => Response.json({ reason: "Unregistered" }, { status: 410 });
  assert.equal((await signed("/push/send", cred, msg(cred))).status, 410);
  provider = () => Response.json({ error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }, { status: 404 });
  assert.equal((await signed("/push/send", cred, msg(cred, { platform: "fcm" }))).status, 410);
});

test("503 until the provider keys are set", async () => {
  const cred = await enroll();
  for (const k of Object.keys(KEYS)) delete env[k];
  const res = await signed("/push/send", cred, msg(cred));
  assert.equal(res.status, 503);
  assert.equal(await res.text(), "push isn't configured yet");
  assert.equal((await signed("/push/send", cred, msg(cred, { platform: "fcm" }))).status, 503);
  assert.equal(calls.length, 0);
});
