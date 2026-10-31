// The web Machines page's rules (web/app/machines.js): each status a machine can be in and the order
// they win in, caps from settings or an agent's own, usage rows and their reset text, meters, and sort order.
import { test } from "node:test";
import assert from "node:assert/strict";
import { capacityOf, capsFor, machineStatus, meters, resetText, since, sortMachines, span, usageRows, windowLabel } from "../web/app/machines.js";

const NOW = Date.UTC(2026, 9, 31, 12);
const MIN = 60_000;
const H = 60 * MIN;
const GB = 1024 ** 3;

const session = (id: string, taskId?: string, state = "working") => ({
  session: { id, agent: "claude", cwd: `/Users/a/wt/${taskId ?? "scratch"}`, startedAt: NOW - H, taskId },
  activity: { state, step: "Step 2", at: NOW },
});
const settings = (over: Record<string, unknown> = {}) => ({ teamSlots: 0, lendIdle: false, loadCap: 0.8, paused: false, ...over });
const usage = (agent: string, five: number, week: number, extra: Record<string, unknown>[] = []) => ({
  agent,
  plan: "max",
  observedAt: NOW - MIN,
  source: "statusline",
  windows: [
    { label: "5h", usedPercent: five, resetsAt: NOW + 2 * H + 5 * MIN },
    { label: "7d", usedPercent: week, resetsAt: NOW + 3 * 24 * H + 4 * H },
    ...extra,
  ],
});
function machine(over: Record<string, unknown> = {}) {
  return {
    id: "m1", name: "Studio", owner: "andrea", online: true, lastSeen: NOW, version: "0.40.0", os: "macOS 26",
    health: { cpu: 37.4, cores: 10, load1: 3.2, memUsed: 12 * GB, memTotal: 32 * GB, diskUsed: 400 * GB, diskTotal: 1000 * GB, uptime: 1000, agents: [] },
    sessions: [], settings: settings(), capacity: 2, usage: [], ...over,
  };
}
const status = (m: Record<string, unknown>) => machineStatus(m, NOW, { time: () => "Sat 2:00 PM" });

test("offline wins over everything, with when it was last seen", () => {
  const m = machine({ online: false, lastSeen: NOW - 5 * MIN, settings: settings({ paused: true }), update: { state: "installing", at: NOW } });
  assert.deepEqual(status(m), { kind: "offline", label: "Offline", detail: "last seen 5m ago" });
  assert.equal(status(machine({ online: false, lastSeen: NOW - 10_000 })).detail, "last seen just now");
  assert.equal(status(machine({ online: false, lastSeen: null })).detail, "never connected");
});

test("updating while a runner update is in progress; a finished one doesn't count", () => {
  assert.deepEqual(status(machine({ update: { state: "installing", target: "0.41.0", at: NOW } })), { kind: "updating", label: "Updating", detail: "to 0.41.0" });
  assert.equal(status(machine({ update: { state: "checking", at: NOW } })).detail, "checking for a release");
  assert.equal(status(machine({ update: { state: "updated", target: "0.41.0", at: NOW } })).kind, "idle");
  assert.equal(status(machine({ update: { state: "failed", message: "no", at: NOW } })).kind, "idle");
});

test("paused, until a time or until resumed, still saying what's running", () => {
  assert.deepEqual(status(machine({ settings: settings({ paused: true, pausedUntil: NOW + H }) })), { kind: "paused", label: "Paused", detail: "until Sat 2:00 PM" });
  assert.equal(status(machine({ settings: settings({ paused: true }) })).detail, "until resumed");
  // A pausedUntil already past reads as until resumed rather than a time gone by.
  assert.equal(status(machine({ settings: settings({ paused: true, pausedUntil: NOW - H }) })).detail, "until resumed");
  assert.equal(status(machine({ settings: settings({ paused: true }), sessions: [session("s1", "MF-1")] })).detail, "until resumed · 1 of 2 working");
});

test("at usage limit on the session or weekly cap", () => {
  const five = status(machine({ settings: settings({ sessionCap: 0.9 }), usage: [usage("claude", 92, 40)] }));
  assert.deepEqual(five, { kind: "limit", label: "At usage limit", detail: "Claude Code 5h at 92% (cap 90%)" });
  const week = status(machine({ settings: settings({ weeklyCap: 0.75 }), usage: [usage("codex", 10, 80)] }));
  assert.equal(week.kind, "limit");
  assert.equal(week.detail, "Codex Week at 80% (cap 75%)");
  // Under both caps: not at the limit.
  assert.equal(status(machine({ settings: settings({ sessionCap: 0.9, weeklyCap: 0.9 }), usage: [usage("claude", 89, 89)] })).kind, "idle");
  // A model's own weekly limit has no cap.
  assert.equal(status(machine({ settings: settings({ weeklyCap: 0.5 }), usage: [usage("claude", 1, 1, [{ label: "7d", usedPercent: 99, name: "Fable" }])] })).kind, "idle");
  // Caps for teammates only say so.
  assert.match(status(machine({ settings: settings({ sessionCap: 0.5, capsTeamOnly: true }), usage: [usage("claude", 60, 1)] })).detail, /teammates' work/);
});

test("an agent's own caps replace the machine-wide ones", () => {
  const s = settings({ sessionCap: 0.5, weeklyCap: 0.5, agentCaps: [{ agent: "claude", session: 0.95 }] });
  assert.deepEqual(capsFor(s, "claude"), { session: 0.95, weekly: null });
  assert.deepEqual(capsFor(s, "codex"), { session: 0.5, weekly: 0.5 });
  assert.deepEqual(capsFor(undefined, "codex"), { session: null, weekly: null });
  // Claude at 80% of its 5h and 90% of its week: under its own caps, though over the machine's.
  assert.equal(status(machine({ settings: s, usage: [usage("claude", 80, 90)] })).kind, "idle");
  assert.equal(status(machine({ settings: s, usage: [usage("codex", 60, 1)] })).kind, "limit");
});

test("working n of capacity counts factory sessions; idle otherwise", () => {
  assert.deepEqual(status(machine({ sessions: [session("s1", "MF-1"), session("s2")] })), { kind: "working", label: "Working 1 of 2", detail: "1 free" });
  assert.deepEqual(status(machine({ sessions: [session("s1", "MF-1"), session("s2", "MF-2")] })), { kind: "working", label: "Working 2 of 2", detail: "full" });
  assert.deepEqual(status(machine()), { kind: "idle", label: "Idle", detail: "2 free" });
  assert.deepEqual(status(machine({ sessions: [session("s2")] })), { kind: "idle", label: "Idle", detail: "1 personal session" });
});

test("capacity: the server's, else the setting, else from its cores", () => {
  assert.equal(capacityOf(machine({ capacity: 3 })), 3);
  assert.equal(capacityOf(machine({ capacity: null, settings: settings({ capacity: 5 }) })), 5);
  assert.equal(capacityOf(machine({ capacity: null })), 2); // 10 cores
  assert.equal(capacityOf(machine({ capacity: null, health: undefined })), 1);
});

test("usage rows: labels, percentages, reset text and caps", () => {
  const m = machine({ settings: settings({ sessionCap: 0.9, weeklyCap: 0.8 }), usage: [usage("claude", 92.4, 30, [{ label: "7d", usedPercent: 12, name: "Fable", resetsAt: NOW - MIN }]), usage("codex", 5, 6)] });
  const [claude, codex] = usageRows(m, NOW);
  assert.equal(claude.title, "Claude Code");
  assert.equal(claude.plan, "max");
  assert.deepEqual(claude.rows, [
    { label: "5h", used: 92.4, usedText: "92%", resets: "resets in 2h 5m", cap: 90, over: true },
    { label: "Week", used: 30, usedText: "30%", resets: "resets in 3d 4h", cap: 80, over: false },
    { label: "Fable week", used: 12, usedText: "12%", resets: "reset", cap: null, over: false },
  ]);
  assert.equal(codex.title, "Codex");
  assert.deepEqual(usageRows(machine(), NOW), []);
  // Past 100% the bar stays full; the number says how far.
  const [over] = usageRows(machine({ usage: [usage("claude", 104, 1)] }), NOW);
  assert.equal(over.rows[0].used, 100);
  assert.equal(over.rows[0].usedText, "104%");
});

test("reset text and spans", () => {
  assert.equal(resetText(null, NOW), "");
  assert.equal(resetText(NOW, NOW), "reset");
  assert.equal(resetText(NOW + 30_000, NOW), "resets in 30s");
  assert.equal(resetText(NOW + 14 * MIN, NOW), "resets in 14m");
  assert.equal(resetText(NOW + 2 * H, NOW), "resets in 2h");
  assert.equal(span(2 * 24 * H), "2d");
  assert.equal(span(26 * H + 59 * MIN), "1d 2h");
  assert.equal(since(NOW - 3 * H, NOW), "3h ago");
  assert.equal(since(NOW - 2 * 24 * H, NOW), "2d ago");
  assert.equal(windowLabel({ label: "spend" }), "Spend");
});

test("meters: CPU load per core against the load cap, memory, disk, battery", () => {
  const [cpu, mem, disk, battery] = meters(machine({ health: { ...machine().health, battery: { percent: 64.4, charging: true } } }));
  assert.deepEqual(cpu, { key: "cpu", label: "CPU", value: 0.32, text: "load 3.2 / 10 cores · 37%", cap: 0.8 });
  assert.deepEqual(mem, { key: "mem", label: "Memory", value: 0.375, text: "12.0 of 32.0 GB", cap: null });
  assert.deepEqual(disk, { key: "disk", label: "Disk", value: 0.4, text: "400 of 1000 GB", cap: null });
  assert.deepEqual(battery, { key: "battery", label: "Battery", value: 0.644, text: "64% · charging", cap: null });
  assert.equal(meters(machine({ health: { ...machine().health, load1: 30 } }))[0].value, 1);
  assert.deepEqual(meters(machine({ health: undefined })), []);
});

test("sort: yours first, then online, then by name", () => {
  const ms = [
    machine({ id: "a", name: "zeta", owner: "sam", online: true }),
    machine({ id: "b", name: "Alpha", owner: "sam", online: false }),
    machine({ id: "c", name: "beta", owner: "andrea", online: false }),
    machine({ id: "d", name: "alpha", owner: "andrea", online: true }),
    machine({ id: "e", name: "Beta", owner: "sam", online: true }),
  ];
  assert.deepEqual(sortMachines(ms, "andrea").map((m) => m.id), ["d", "c", "e", "a", "b"]);
});
