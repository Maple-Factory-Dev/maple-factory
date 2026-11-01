// The Machines page's rules, apart from the DOM so they can be tested: what state each machine is in,
// its health as meters, its agents' plan usage as rows against their caps, and the order the cards go in.
// Every function takes `now` (ms) so the tests can pin the clock.

const AGENT_TITLE = { claude: "Claude Code", codex: "Codex", shell: "Shell" };
export const agentName = (agent) => AGENT_TITLE[agent] ?? (agent ? agent[0].toUpperCase() + agent.slice(1) : "");

/** Runner update states that mean the machine is in the middle of one. */
const UPDATING = new Set(["checking", "installing", "restarting"]);

/** "just now", "4m ago", "3h ago", "2d ago". */
export function since(ms, now) {
  const s = Math.max(0, (now - ms) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

/** A span of time, coarsely: "45s", "14m", "2h 5m", "3d 4h". */
export function span(ms) {
  const m = Math.floor(Math.max(0, ms) / 60_000);
  if (m < 1) return `${Math.max(0, Math.round(ms / 1000))}s`;
  if (m < 60) return `${m}m`;
  if (m < 1440) return m % 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m / 60}h`;
  const h = Math.floor(m / 60);
  return h % 24 ? `${Math.floor(h / 24)}d ${h % 24}h` : `${h / 24}d`;
}

/** "resets in 2h 5m"; "reset" once the window is over (the next request starts a new one); "" when unknown. */
export function resetText(resetsAt, now) {
  if (resetsAt == null) return "";
  return resetsAt <= now ? "reset" : `resets in ${span(resetsAt - now)}`;
}

/** The factory sessions a machine takes now: the server's figure, else its setting, else from its cores (as the engine does). */
export function capacityOf(m) {
  if (m.capacity != null) return m.capacity;
  if (m.settings?.capacity != null) return m.settings.capacity;
  const cores = m.health?.cores ?? 4;
  return Math.max(1, Math.min(4, Math.floor(cores / 4)));
}

/** An agent's caps on a machine (0–1, or null): its own `agentCaps` entry replaces the machine-wide ones. */
export function capsFor(settings, agent) {
  const own = settings?.agentCaps?.find((c) => c.agent === agent);
  return own ? { session: own.session ?? null, weekly: own.weekly ?? null } : { session: settings?.sessionCap ?? null, weekly: settings?.weeklyCap ?? null };
}

/** The cap (0–1) that applies to one window: 5h gets the session cap, the plain weekly window the weekly one. */
const capOf = (caps, w) => (w.label === "5h" ? caps.session : isWeek(w) && !w.name ? caps.weekly : null);

/** A weekly window: plain "7d", or a model's own one like "7d:fable". */
const isWeek = (w) => w.label.startsWith("7d");

/** A window's name for people: "5h", "Week", "Fable week", "Spend". */
export function windowLabel(w) {
  const base = isWeek(w) ? "Week" : w.label === "spend" ? "Spend" : w.label;
  return w.name ? `${w.name} ${base === "Week" ? "week" : base}` : base;
}

/** One agent's plan usage as rows to draw: each window's use, when it resets, and its cap. */
export function usageRows(m, now) {
  return (m.usage ?? []).map((u) => {
    const caps = capsFor(m.settings, u.agent);
    return {
      agent: u.agent,
      title: agentName(u.agent),
      plan: u.plan ?? null,
      observedAt: u.observedAt,
      rows: u.windows.map((w) => {
        const cap = capOf(caps, w);
        const used = Math.max(0, Math.min(100, w.usedPercent));
        return {
          label: windowLabel(w),
          used,
          usedText: `${Math.round(w.usedPercent)}%`,
          resets: resetText(w.resetsAt, now),
          // Shown as a percentage on the bar's scale.
          cap: cap == null ? null : Math.round(cap * 100),
          over: cap != null && w.usedPercent >= cap * 100,
        };
      }),
    };
  });
}

/** The first window over its cap, if any: why no new work starts here. */
function overCap(m, now) {
  for (const u of usageRows(m, now)) {
    const row = u.rows.find((r) => r.over);
    if (row) return `${u.title} ${row.label} at ${row.usedText} (cap ${row.cap}%)`;
  }
  return null;
}

const clock = (ms) => new Date(ms).toLocaleString([], { weekday: "short", hour: "numeric", minute: "2-digit" });

/**
 * What a machine is doing, in order: Offline, Updating, Paused, At usage limit, Working, Idle.
 * `kind` picks the pill's color; `label` is the pill; `detail` says more.
 */
export function machineStatus(m, now, { time = clock } = {}) {
  const factory = (m.sessions ?? []).filter((s) => s.session.taskId).length;
  const capacity = capacityOf(m);
  const working = factory ? `${factory} of ${capacity} working` : null;
  if (!m.online) return { kind: "offline", label: "Offline", detail: m.lastSeen ? `last seen ${since(m.lastSeen, now)}` : "never connected" };
  if (m.update && UPDATING.has(m.update.state)) {
    return { kind: "updating", label: "Updating", detail: m.update.target ? `to ${m.update.target}` : m.update.state === "restarting" ? "restarting" : "checking for a release" };
  }
  if (m.settings?.paused) {
    const until = m.settings.pausedUntil;
    const newOnly = !!m.settings.pauseNew;
    return {
      kind: "paused",
      label: newOnly ? "Paused for new work" : "Paused",
      detail: [until && until > now ? `until ${time(until)}` : "until resumed", newOnly ? "tasks already here keep going" : null, working].filter(Boolean).join(" · "),
    };
  }
  const capped = overCap(m, now);
  if (capped) return { kind: "limit", label: "At usage limit", detail: [capped, m.settings?.capsTeamOnly ? "teammates' work" : null, working].filter(Boolean).join(" · ") };
  if (factory) return { kind: "working", label: `Working ${factory} of ${capacity}`, detail: factory >= capacity ? "full" : `${capacity - factory} free` };
  const open = (m.sessions ?? []).length;
  return { kind: "idle", label: "Idle", detail: open ? `${open} personal session${open === 1 ? "" : "s"}` : `${capacity} free` };
}

const GB = 1024 ** 3;
const gb = (n) => (n / GB >= 100 ? Math.round(n / GB) : (n / GB).toFixed(1));

/** Health as meters (`value` is 0–1, `cap` too when there is one): CPU load per core, memory, disk, battery. */
export function meters(m) {
  const hl = m.health;
  if (!hl) return [];
  const cores = Math.max(1, hl.cores);
  const out = [
    { key: "cpu", label: "CPU", value: Math.min(1, hl.load1 / cores), text: `load ${hl.load1.toFixed(1)} / ${cores} cores · ${Math.round(hl.cpu)}%`, cap: m.settings?.loadCap ?? null },
  ];
  if (hl.memTotal) out.push({ key: "mem", label: "Memory", value: hl.memUsed / hl.memTotal, text: `${gb(hl.memUsed)} of ${gb(hl.memTotal)} GB`, cap: null });
  if (hl.diskTotal) out.push({ key: "disk", label: "Disk", value: hl.diskUsed / hl.diskTotal, text: `${gb(hl.diskUsed)} of ${gb(hl.diskTotal)} GB`, cap: null });
  if (hl.battery) out.push({ key: "battery", label: "Battery", value: hl.battery.percent / 100, text: `${Math.round(hl.battery.percent)}%${hl.battery.charging ? " · charging" : ""}`, cap: null });
  return out;
}

/** Yours first, then online before offline, then by name. */
export function sortMachines(machines, me) {
  return [...machines].sort((a, b) =>
    (b.owner === me) - (a.owner === me) || b.online - a.online || a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));
}

// ---- pausing ----

/** Whether `me` (the snapshot's member) can change this machine's settings: its owner, or an admin. */
export const canManage = (m, me) => !!me && (m.owner === me.login || me.role === "admin");

/** When a pause of this length ends (ms), as the apps work it out: "hour" an hour on, "tomorrow" 8am next, "resume" none. */
export function pauseUntil(length, now) {
  if (length === "hour") return now + 3600_000;
  if (length === "tomorrow") {
    const d = new Date(now);
    d.setHours(8, 0, 0, 0);
    if (d.getTime() <= now) d.setDate(d.getDate() + 1);
    return d.getTime();
  }
  return null;
}

/** The server's defaults for a machine with no settings yet. */
const DEFAULTS = { teamSlots: 0, lendIdle: false, loadCap: 0.85 };

/** A whole MachineSettings: the machine's own (slots, caps and all), with the pause fields given. */
const withPause = (m, pause) => ({ ...DEFAULTS, paused: false, ...(m.settings ?? {}), ...pause });

/** The settings that pause it: `scope` "new" holds back new tasks only, "all" everything; `until` ms or null. */
export const pauseSettings = (m, { scope, until }) => withPause(m, { paused: true, pausedUntil: until ?? null, pauseNew: scope === "new" });

/** The settings that resume it. */
export const resumeSettings = (m) => withPause(m, { paused: false, pausedUntil: null, pauseNew: false });

/** Teammates' tasks working on this machine (not reviewers): what a full pause can hand off. */
export const teammatesTasks = (m, tasks) => [...tasks].filter((t) => t.worker?.machine === m.id && t.worker?.role !== "reviewer" && t.owner !== m.owner);
