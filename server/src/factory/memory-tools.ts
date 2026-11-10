// Agents' memory tools (MF-392): recall, remember and forget, for task sessions and personal sessions alike, on
// MF-391's Memories. An agent only says how widely a memory applies ("org" | "repo" | "goal"); the scope's key
// comes from the session (its task's repo and goal, or the org repo a personal session's folder is a checkout
// of), so a session reads and writes only its own scopes. A near-duplicate isn't written twice, a session writes
// at most MAX_WRITES times (remember and forget together), and forget archives: nothing here deletes a memory.
import { MemoryKindValues, MemoryScopeKindValues } from "../wire.ts";
import type { Memory, MemoryKind, MemoryScope, MemoryScopeKind, OrgRepo } from "../wire.ts";
import type { Memories } from "./memories.ts";
import type { Store } from "./store.ts";

export const MAX_WRITES = 10;
export const DUPLICATE_AT = 0.85;
const RECALL_DEFAULT = 10;
const RECALL_MAX = 50;
const MAX_REASON = 300;

export class MemoryToolFailure extends Error {}
const fail = (message: string): never => { throw new MemoryToolFailure(message); };

/** Who's calling. `by` is the person the agent works for; `repo` and `goal` are the keys its scopes get. */
export interface MemoryCaller {
  session: string;
  by: string;
  task?: string | null;
  role?: string | null;
  agent: string;
  machine?: string | null;
  repo?: string | null;
  goal?: string | null;
}

/** Text as dedupe compares it: lowercase, punctuation gone, whitespace collapsed. */
export function normalizeText(text: string): string {
  return text.toLowerCase().replace(/[^\p{L}\p{N}\s]+/gu, " ").replace(/\s+/g, " ").trim();
}

/** How alike two normalised texts are: the Jaccard index of their word sets (1 when identical). */
export function similarity(a: string, b: string): number {
  if (a === b) return 1;
  const x = new Set(a.split(" ").filter(Boolean)), y = new Set(b.split(" ").filter(Boolean));
  if (!x.size || !y.size) return 0;
  let both = 0;
  for (const w of x) if (y.has(w)) both++;
  return both / (x.size + y.size - both);
}

/** The org repo a folder is a checkout of, from its path alone: …/owner/name/… or …/owner/.worktrees/name/…
 *  first, else the one repo whose name is a path segment (the deepest segment wins; two repos with that name,
 *  or none, is null). Case-insensitive. */
export function repoFromCwd(cwd: string | null | undefined, repos: Pick<OrgRepo, "name">[]): string | null {
  if (!cwd) return null;
  const segments = cwd.split(/[\\/]+/).filter(Boolean).map((s) => s.toLowerCase());
  const split = repos.map((r) => ({ name: r.name, owner: r.name.split("/")[0]?.toLowerCase() ?? "", repo: r.name.split("/")[1]?.toLowerCase() ?? "" })).filter((r) => r.owner && r.repo);
  for (let i = segments.length - 1; i >= 1; i--) {
    const before = segments[i - 1] === ".worktrees" && i >= 2 ? segments[i - 2] : segments[i - 1];
    const hit = split.find((r) => r.repo === segments[i] && r.owner === before);
    if (hit) return hit.name;
  }
  for (let i = segments.length - 1; i >= 0; i--) {
    const named = split.filter((r) => r.repo === segments[i]);
    if (named.length === 1) return named[0].name;
    if (named.length > 1) return null;
  }
  return null;
}

const view = (m: Memory) => ({ id: m.id, kind: m.kind, scope: m.scope.kind, text: m.text, tags: m.tags });

export class MemoryTools {
  constructor(private store: Store, private memories: Memories) {}

  /** The caller's repo as the org spells it. */
  private repo(ctx: MemoryCaller): string | null {
    if (!ctx.repo) return null;
    return this.store.repos().find((r) => r.name.toLowerCase() === ctx.repo!.toLowerCase())?.name ?? ctx.repo;
  }

  /** The scope `kind` means for this session, or a refusal saying why it has none. */
  private scope(ctx: MemoryCaller, kind: unknown): MemoryScope {
    if (typeof kind !== "string" || !(MemoryScopeKindValues as readonly string[]).includes(kind)) fail("scope is \"org\", \"repo\" or \"goal\".");
    if (kind === "org") return { kind: "org", key: null };
    if (kind === "repo") {
      const repo = this.repo(ctx);
      if (!repo) fail(ctx.task ? "This task has no repo, so there are no repo memories here; use scope \"goal\" or \"org\"." : "This folder isn't one of the org's repos, so there are no repo memories here; use scope \"org\".");
      return { kind: "repo", key: repo };
    }
    if (!ctx.goal) fail("A session that isn't on a factory task has no goal; use scope \"repo\" or \"org\".");
    return { kind: "goal", key: ctx.goal! };
  }

  /** Every scope this session reads and writes: the org's, its repo's, its goal's. */
  private scopes(ctx: MemoryCaller): MemoryScope[] {
    const out: MemoryScope[] = [{ kind: "org", key: null }];
    const repo = this.repo(ctx);
    if (repo) out.push({ kind: "repo", key: repo });
    if (ctx.goal) out.push({ kind: "goal", key: ctx.goal });
    return out;
  }

  /** The memory `id`, when it's in one of this session's scopes. */
  private mine(ctx: MemoryCaller, id: unknown, what: string): Memory {
    const memory = typeof id === "string" && id.trim() ? this.store.memory(id.trim().toLowerCase()) : fail(`${what} is a memory's id, from recall.`);
    const inScope = memory && this.scopes(ctx).some((s) => s.kind === memory.scope.kind && (s.key ?? "").toLowerCase() === (memory.scope.key ?? "").toLowerCase());
    if (!memory || !inScope) fail(`There's no memory ${String(id)} in this session's scopes; recall lists the ones there are.`);
    return memory!;
  }

  private checkCap(ctx: MemoryCaller) {
    if (this.store.memoryWrites(ctx.session).n >= MAX_WRITES) {
      fail(`This session has already made ${MAX_WRITES} memory writes, which is the limit. Keep only what matters: a memory should be something a later agent couldn't work out from the code.`);
    }
  }

  /** Runs one memory tool; throws MemoryToolFailure (the agent sees its message) when it's refused. `wrote` is
   *  set when a memory was saved or archived. */
  run(ctx: MemoryCaller, name: string, a: Record<string, unknown>, at = Date.now()): { summary: string; data?: unknown; wrote?: "remembered" | "archived"; memory?: Memory; reason?: string } {
    switch (name) {
      case "recall": {
        const scopes = a.scope == null ? this.scopes(ctx) : [this.scope(ctx, a.scope)];
        const limit = Math.max(1, Math.min(typeof a.limit === "number" && Number.isFinite(a.limit) ? Math.floor(a.limit) : RECALL_DEFAULT, RECALL_MAX));
        const q = typeof a.q === "string" ? a.q : "";
        const found = this.store.searchMemories({ scopes, query: q, status: "active", limit, any: true });
        this.store.touchMemories(found.map((m) => m.id), at);
        return { summary: found.length ? `${found.length} ${found.length === 1 ? "memory" : "memories"}.` : q.trim() ? "Nothing remembered matches that." : "Nothing remembered here yet.", data: found.map(view) };
      }
      case "remember": {
        const text = typeof a.text === "string" && a.text.trim() ? a.text.trim() : fail("text is required: the thing to remember.");
        if (typeof a.kind !== "string" || !(MemoryKindValues as readonly string[]).includes(a.kind)) fail("kind is \"fact\", \"convention\", \"gotcha\" or \"preference\".");
        const scope = this.scope(ctx, a.scope);
        const supersedes = a.supersedes == null || a.supersedes === "" ? null : this.mine(ctx, a.supersedes, "supersedes");
        const wanted = normalizeText(text);
        const twin = this.store.memories({ scope, status: "active" }).find((m) => m.id !== supersedes?.id && similarity(wanted, normalizeText(m.text)) >= DUPLICATE_AT);
        if (twin) return { summary: `Already remembered (${twin.id}); nothing new was saved.`, data: { id: twin.id, already: true } };
        this.checkCap(ctx);
        const made = this.memories.create(crypto.randomUUID(), {
          scope, kind: a.kind as MemoryKind, text, tags: a.tags as string[] | null | undefined,
          source: { by: ctx.by, task: ctx.task ?? null, role: ctx.role ?? null, agent: ctx.agent, machine: ctx.machine ?? null, decision: null },
          supersedes: supersedes?.id ?? null,
        }, { at });
        if ("error" in made) fail(made.error);
        const memory = made as Memory;
        const left = MAX_WRITES - this.store.bumpMemoryWrites(ctx.session, at, true).n;
        const where = scope.kind === "org" ? "the org" : scope.kind === "repo" ? scope.key : "this goal";
        return {
          summary: `Remembered for ${where}${supersedes ? `, replacing ${supersedes.id}` : ""}. ${left} more memory ${left === 1 ? "write" : "writes"} left in this session.`,
          data: { id: memory.id, scope: memory.scope.kind as MemoryScopeKind, already: false }, wrote: "remembered", memory,
        };
      }
      case "forget": {
        const reason = typeof a.reason === "string" && a.reason.trim() ? a.reason.trim().slice(0, MAX_REASON) : fail("reason is required: why it no longer holds.");
        const memory = this.mine(ctx, a.id, "id");
        if (memory.status === "archived") return { summary: "That memory is already archived.", data: { id: memory.id, status: "archived" } };
        this.checkCap(ctx);
        const archived = this.memories.setStatus(memory.id, "archived", ctx.by, { at });
        if ("error" in archived) fail(archived.error);
        this.store.bumpMemoryWrites(ctx.session, at);
        return { summary: "Archived. A person can still see it and bring it back.", data: { id: memory.id, status: "archived" }, wrote: "archived", memory: archived as Memory, reason };
      }
    }
    return fail(`${name} isn't a memory tool.`);
  }
}
