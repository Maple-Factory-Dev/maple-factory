// Integrations' registry and store on a node:sqlite store (as factory.test.ts does): a save is checked
// against its definition, a blank secret keeps the stored one, env vars fill in what isn't stored, and a
// sealed value only opens as the integration and field it was sealed for.
import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { Integrations } from "../src/integrations/store.ts";
import { definition, merged } from "../src/integrations/registry.ts";
import type { Env } from "../src/env.ts";

function sqlStorage() {
  const db = new DatabaseSync(":memory:");
  const storage = {
    db,
    exec(query: string, ...bindings: unknown[]) {
      const rows = db.prepare(query).all(...(bindings as never[]));
      return { toArray: () => rows, one: () => rows[0] };
    },
  };
  return storage as unknown as SqlStorage & { db: DatabaseSync };
}

const SECRETS_KEY = "mfk_test-key-for-integrations";
const store = (env: Partial<Env> = {}) => {
  const sql = sqlStorage();
  return { sql, integrations: new Integrations(sql, { SECRETS_KEY, ...env } as Env) };
};

test("a save is checked against its definition", () => {
  const linear = definition("linear")!;
  const jira = definition("jira")!;
  assert.match(merged(linear, true, {}, {}, {}) as string, /needs its webhook signing secret/);
  assert.match(merged(linear, true, { nope: "x" }, {}, {}) as string, /no setting called nope/);
  assert.deepEqual(merged(linear, false, {}, {}, {}), {}, "a disabled one needn't be complete");
  assert.deepEqual(merged(linear, true, { webhookSecret: "s", label: " Factory " }, {}, {}), { webhookSecret: "s", label: "factory" });
  assert.match(merged(linear, true, { webhookSecret: "s", label: "two words" }, {}, {}) as string, /spaces/);
  assert.match(merged(jira, true, { webhookSecret: "s", site: "http://acme.atlassian.net" }, {}, {}) as string, /https/);
  assert.deepEqual(merged(jira, true, { webhookSecret: "s", site: "https://acme.atlassian.net/" }, {}, {}), { webhookSecret: "s", site: "https://acme.atlassian.net" });
  assert.deepEqual(merged(linear, true, {}, {}, { webhookSecret: "from-env" }), {}, "an env var counts for a required field");
});

test("a blank secret keeps the stored one; a blank plain field clears it", async () => {
  const { integrations } = store();
  await integrations.save("linear", true, { webhookSecret: "whsec", apiKey: "lin_api", label: "triage" }, "ada");
  await integrations.save("linear", true, { webhookSecret: "", apiKey: "", label: "" }, "ada");
  assert.deepEqual(await integrations.config("linear"), { webhookSecret: "whsec", apiKey: "lin_api" });
  await integrations.save("linear", true, { webhookSecret: "rotated" }, "ada");
  assert.equal((await integrations.config("linear"))?.webhookSecret, "rotated");
});

test("the redacted list never carries a secret", async () => {
  const { integrations } = store();
  await integrations.save("linear", true, { webhookSecret: "whsec-very-secret", apiKey: "lin_api_secret", label: "maple" }, "ada");
  const list = await integrations.list();
  assert.deepEqual(list.map((i) => i.kind), ["slack", "linear", "jira"]);
  const linear = list.find((i) => i.kind === "linear")!;
  assert.deepEqual(linear.values, { webhookSecret: "", apiKey: "", label: "maple" });
  assert.equal(linear.enabled, true);
  assert.equal(linear.updatedBy, "ada");
  assert.equal(linear.webhookUrl, "/integrations/linear");
  const shown = JSON.stringify(list);
  assert.ok(!shown.includes("whsec-very-secret") && !shown.includes("lin_api_secret"));
});

test("env vars work with nothing stored, and stored values win field by field", async () => {
  const { integrations } = store({ LINEAR_WEBHOOK_SECRET: "env-secret", LINEAR_LABEL: "envlabel", PUBLIC_URL: "https://factory.example/" });
  assert.deepEqual(await integrations.config("linear"), { webhookSecret: "env-secret", label: "envlabel" });
  assert.equal(await integrations.config("slack"), null, "nothing set up");
  let linear = (await integrations.list()).find((i) => i.kind === "linear")!;
  assert.equal(linear.enabled, true);
  assert.deepEqual(linear.fromEnv, ["webhookSecret", "label"]);
  assert.equal(linear.webhookUrl, "https://factory.example/integrations/linear");
  await integrations.save("linear", true, { label: "stored" }, "ada");
  assert.deepEqual(await integrations.config("linear"), { webhookSecret: "env-secret", label: "stored" });
  linear = (await integrations.list()).find((i) => i.kind === "linear")!;
  assert.deepEqual(linear.fromEnv, ["webhookSecret"]);
  await integrations.save("linear", false, {}, "ada");
  assert.equal(await integrations.config("linear"), null, "turned off in Settings, even with env vars");
});

test("status: an event clears the last error", async () => {
  const { integrations } = store({ SLACK_SIGNING_SECRET: "x" });
  integrations.noteError("slack", "Bad signature.");
  let slack = (await integrations.list()).find((i) => i.kind === "slack")!;
  assert.equal(slack.lastError, "Bad signature.");
  assert.equal(slack.enabled, true, "a status row doesn't count as a save");
  integrations.noteEvent("slack");
  slack = (await integrations.list()).find((i) => i.kind === "slack")!;
  assert.equal(slack.lastError, null);
  assert.ok(slack.lastEventAt && Date.now() - slack.lastEventAt < 5000);
});

test("a sealed value won't open as another integration or field", async () => {
  const { sql, integrations } = store();
  await integrations.save("linear", true, { webhookSecret: "whsec", apiKey: "lin_api" }, "ada");
  const row = sql.db.prepare("SELECT sealed FROM integrations WHERE kind = 'linear'").get() as { sealed: string };
  assert.ok(!row.sealed.includes("whsec"), "stored sealed, not in the clear");
  const boxes = JSON.parse(row.sealed);
  // The webhook secret's box filed under apiKey…
  sql.db.prepare("UPDATE integrations SET sealed = ? WHERE kind = 'linear'").run(JSON.stringify({ apiKey: boxes.webhookSecret }));
  await assert.rejects(integrations.config("linear"));
  // …or moved to Slack's row as its signing secret.
  sql.db.prepare("INSERT INTO integrations (kind, enabled, sealed, updated_by, updated_at) VALUES ('slack', 1, ?, 'ada', 1)").run(JSON.stringify({ signingSecret: boxes.webhookSecret }));
  await assert.rejects(integrations.config("slack"));
});
