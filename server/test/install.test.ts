// GET /cloud-init.yaml: user-data that brings a new Linux server up already in the factory.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cloudInitConfig } from "../src/install.ts";

const ORIGIN = "https://factory.example";

// Parse with whatever YAML parser the machine has (Ruby's Psych ships with Ruby; PyYAML often
// doesn't), as JSON back. Null when there's none, so the structural checks still run.
function parseYaml(text: string): any {
  const tries: [string, string[]][] = [
    ["ruby", ["-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.safe_load(STDIN.read))"]],
    ["python3", ["-c", "import sys, json, yaml; print(json.dumps(yaml.safe_load(sys.stdin)))"]],
  ];
  for (const [cmd, args] of tries) {
    const run = spawnSync(cmd, args, { input: text, encoding: "utf8" });
    if (run.status === 0) return JSON.parse(run.stdout);
  }
  return null;
}

test("cloud-init.yaml fills in the origin and code and parses as cloud-config", async () => {
  const res = cloudInitConfig(ORIGIN, "abcd-efgh");
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type")!, /^text\/cloud-config/);
  assert.equal(res.headers.get("cache-control"), "no-store");
  const body = await res.text();
  assert.ok(body.startsWith("#cloud-config\n"));
  assert.match(body, /runs out 15 minutes after/);
  assert.match(body, /codex login --device-auth/);

  const config = parseYaml(body);
  const script: string = config ? config.runcmd.join("\n") : body;
  if (config) {
    assert.deepEqual(config.users.map((u: any) => (typeof u === "string" ? u : u.name)), ["default", "maple"]);
    assert.deepEqual(config.packages, ["git", "tmux", "curl", "ca-certificates"]);
  }
  assert.match(script, /deb\.nodesource\.com\/setup_lts\.x/);
  assert.match(script, /npm install -g @anthropic-ai\/claude-code @openai\/codex/);
  const linger = script.indexOf("loginctl enable-linger maple");
  const install = script.indexOf(`sudo -iu maple env XDG_RUNTIME_DIR="/run/user/$uid" sh -c 'curl -fsSL ${ORIGIN}/install.sh | sh -s -- ABCD-EFGH'`);
  assert.ok(linger > 0, "turns lingering on");
  assert.ok(install > linger, "runs install.sh as maple after lingering is on");
});

test("cloud-init.yaml refuses a missing or malformed code", async () => {
  for (const code of [null, "", "ABCD", "ABCD-EFGHI", "AB'D-EFGH", "ABCD-EF\nH", "ABCD-EFGH'; rm -rf /'", "ABCD EFGH"]) {
    const res = cloudInitConfig(ORIGIN, code);
    assert.equal(res.status, 400, JSON.stringify(code));
    assert.doesNotMatch(await res.text(), /cloud-config/);
  }
});
