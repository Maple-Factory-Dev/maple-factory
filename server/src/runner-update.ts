// A runner update someone asked for, as the apps see it on its Machine: checking, installing and
// restarting while it runs, then updated, up to date or failed for a few minutes. The org hub keeps
// one per machine (storage `u:<id>`) so a restart of the hub doesn't lose it mid-update.

import type { Machine, MachineUpdate } from "./wire.ts";

/** How long an update that ended stays on the card, and how long one may run before it reads as failed. */
export const UPDATE_SHOWN_MS = 10 * 60_000;

const RUNNING = new Set<MachineUpdate["state"]>(["checking", "installing", "restarting"]);

/** A runner's `update.status` notice, onto the update it moves along; `running` is the version the machine is on. */
export function fromNotice(prev: MachineUpdate | undefined, msg: { state?: string; version?: string | null; message?: string | null }, running: string | null, at = Date.now()): MachineUpdate | null {
  // A timed update (nobody asked) starts its own; one that's already over doesn't carry on.
  if (prev && !RUNNING.has(prev.state)) prev = undefined;
  const target = msg.version ?? prev?.target ?? null;
  const from = prev?.from ?? running;
  switch (msg.state) {
    case "checking": return { state: "checking", target: prev?.target ?? null, from, message: null, at };
    case "installing": return { state: "installing", target, from, message: null, at };
    case "updating": return { state: "restarting", target, from, message: null, at };
    case "up_to_date": return { state: "upToDate", target, from, message: null, at };
    case "failed": return { state: "failed", target, from, message: msg.message ?? null, at };
  }
  return null;
}

/** The update once the machine reports in again: updated when it's back on the version it went for. */
export function onReport(prev: MachineUpdate | undefined, machine: Machine, at = Date.now()): MachineUpdate | null {
  if (!prev || !RUNNING.has(prev.state) || !machine.online || !machine.version) return null;
  if (prev.state === "restarting" && prev.target && machine.version === prev.target) return { ...prev, state: "updated", message: null, at };
  return null;
}

/** What the apps are shown: nothing once it's old, and failed if it ran too long without coming back. */
export function shown(update: MachineUpdate | undefined, now = Date.now()): MachineUpdate | null {
  if (!update) return null;
  if (RUNNING.has(update.state)) {
    if (now - update.at < UPDATE_SHOWN_MS) return update;
    const message = update.state === "restarting"
      ? `It didn't come back on ${update.target ?? "the new runner"}; check the runner's log.`
      : "The machine stopped answering partway through the update.";
    return now - update.at < 2 * UPDATE_SHOWN_MS ? { ...update, state: "failed", message } : null;
  }
  return now - update.at < UPDATE_SHOWN_MS ? update : null;
}

/** Compares release numbers only ("0.2.0" < "0.10.1"); a prerelease counts as its release. */
export function olderThan(a: string, b: string): boolean {
  const parts = (v: string) => v.split("-")[0].split(".").map((n) => Number(n) || 0);
  const [x, y] = [parts(a), parts(b)];
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const [p, q] = [x[i] ?? 0, y[i] ?? 0];
    if (p !== q) return p < q;
  }
  return false;
}
