// githubstatus.com's summary.json reduced to the notice the apps show: a degraded summary keeps its
// unresolved incidents and non-operational components, an operational one is no notice, and a
// response that can't be read is null (the last known status stands).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { fetchGitHubStatus, notice, reduceSummary } from "../src/github-status.ts";

const degraded = {
  page: { id: "kctbh9vrtdwd", name: "GitHub" },
  status: { indicator: "minor", description: "Partial System Outage" },
  components: [
    { id: "a", name: "Git Operations", status: "operational", group: false },
    { id: "b", name: "Actions", status: "degraded_performance", group: false },
    { id: "c", name: "Pull Requests", status: "partial_outage", group: false },
    { id: "d", name: "Visit www.githubstatus.com for more information", status: "operational", group: false },
  ],
  incidents: [
    { id: "old1", name: "Earlier trouble", status: "resolved", created_at: "2026-10-30T08:00:00Z" },
    { id: "inc1", name: "Disruption with some GitHub services", status: "investigating", shortlink: "https://stspg.io/x", created_at: "2026-10-30T10:00:00Z" },
    { id: "inc2", name: "Incident with Actions", status: "identified", created_at: "2026-10-30T11:00:00Z" },
  ],
};

const operational = {
  status: { indicator: "none", description: "All Systems Operational" },
  components: [{ name: "Git Operations", status: "operational" }],
  incidents: [],
};

test("a degraded summary keeps unresolved incidents, newest first, and the components in trouble", () => {
  const s = reduceSummary(degraded, 42);
  assert.deepEqual(s, {
    indicator: "minor",
    description: "Partial System Outage",
    incidents: [
      { name: "Incident with Actions", status: "identified", url: "https://www.githubstatus.com/incidents/inc2" },
      { name: "Disruption with some GitHub services", status: "investigating", url: "https://www.githubstatus.com/incidents/inc1" },
    ],
    components: ["Actions", "Pull Requests"],
    checkedAt: 42,
  });
  assert.equal(notice(s), s);
});

test("an operational summary is no notice", () => {
  const s = reduceSummary(operational, 1);
  assert.equal(s.indicator, "none");
  assert.equal(notice(s), null);
});

test("a component in trouble is a notice even while the indicator says none", () => {
  const s = reduceSummary({ ...operational, components: [{ name: "Codespaces", status: "major_outage" }] }, 1);
  assert.deepEqual(notice(s)?.components, ["Codespaces"]);
});

test("anything that isn't a Statuspage summary throws", () => {
  assert.throws(() => reduceSummary({} as never));
  assert.throws(() => reduceSummary({ status: { indicator: "on fire" } }));
});

test("a fetch that fails or can't be parsed is null", async () => {
  const server = createServer((req, res) => {
    if (req.url === "/ok") res.end(JSON.stringify(degraded));
    else if (req.url === "/html") res.end("<html>maintenance</html>");
    else { res.statusCode = 503; res.end(); }
  });
  await new Promise<void>((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
  try {
    assert.equal((await fetchGitHubStatus(`${base}/ok`))?.incidents.length, 2);
    assert.equal(await fetchGitHubStatus(`${base}/html`), null);
    assert.equal(await fetchGitHubStatus(`${base}/down`), null);
    assert.equal(await fetchGitHubStatus("http://127.0.0.1:1/"), null);
  } finally {
    server.close();
  }
});
