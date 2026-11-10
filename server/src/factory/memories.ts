// Shared agent memory (MF-391; design in the MF-385 report): short notes the factory's agents keep between tasks,
// scoped to the org, a repo or a goal. This is the one place that validates a memory and tells members about a
// change, so agent tools and the apps (later tasks) call here rather than the store. `normalize` is pure;
// `Memories` saves through Store (which keeps the FTS index and the append-only log in step) and broadcasts
// `memory.updated` for every save and `memory.removed` for a hard delete. Archiving is a status change.
import { MemoryKindValues, MemoryScopeKindValues, MemoryStatusValues } from "../wire.ts";
import type { Memory, MemoryKind, MemoryScope, MemorySource, MemoryStatus, ServerToClient } from "../wire.ts";
import type { Store } from "./store.ts";

export const MAX_TEXT = 600;
export const MAX_TAGS = 8;
export const MAX_TAG = 32;
const MAX_SCOPE_KEY = 200;
const MAX_SOURCE_FIELD = 200;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export type MemoryContent = { scope: MemoryScope; kind: MemoryKind; text: string; tags?: string[] | null };
export type MemoryInput = MemoryContent & { status?: MemoryStatus | null; source: MemorySource; supersedes?: string | null };
export type Clean = { scope: MemoryScope; kind: MemoryKind; text: string; tags: string[] };
export type Refusal = { error: string };

const has = (values: readonly string[], v: unknown): boolean => typeof v === "string" && values.includes(v);

/** A memory's content, tidied (text trimmed, tags lowercased and deduped, an org scope with no key), or why it
 *  won't do. */
export function normalize(input: MemoryContent): Clean | Refusal {
  if (!input || typeof input !== "object") return { error: "That isn't a memory." };
  const text = typeof input.text === "string" ? input.text.trim() : "";
  if (!text) return { error: "A memory needs some text." };
  if (text.length > MAX_TEXT) return { error: `A memory is at most ${MAX_TEXT} characters.` };
  if (!has(MemoryKindValues, input.kind)) return { error: "A memory is a fact, a convention, a gotcha or a preference." };
  const scope = input.scope;
  if (!scope || typeof scope !== "object" || !has(MemoryScopeKindValues, scope.kind)) return { error: "A memory's scope is the org, a repo or a goal." };
  const key = typeof scope.key === "string" ? scope.key.trim() : scope.key == null ? "" : null;
  if (key === null || key.length > MAX_SCOPE_KEY) return { error: "That scope's key won't do." };
  if (scope.kind === "org" && key) return { error: "An org-wide memory has no scope key." };
  if (scope.kind === "repo" && !/^[^/\s]+\/[^/\s]+$/.test(key)) return { error: "A repo memory needs its repo as owner/name." };
  if (scope.kind === "goal" && !key) return { error: "A goal memory needs its goal's id." };
  if (input.tags != null && !Array.isArray(input.tags)) return { error: "Tags are a list of words." };
  const tags: string[] = [];
  for (const raw of input.tags ?? []) {
    if (typeof raw !== "string") return { error: "Tags are a list of words." };
    const tag = raw.trim().toLowerCase().replace(/\s+/g, "-");
    if (!tag || tags.includes(tag)) continue;
    if (tag.length > MAX_TAG) return { error: `A tag is at most ${MAX_TAG} characters.` };
    tags.push(tag);
  }
  if (tags.length > MAX_TAGS) return { error: `A memory has at most ${MAX_TAGS} tags.` };
  return { scope: { kind: scope.kind, key: key || null }, kind: input.kind, text, tags };
}

function cleanSource(source: MemorySource): MemorySource | Refusal {
  if (!source || typeof source !== "object" || typeof source.by !== "string" || !source.by.trim()) return { error: "A memory needs who it came from." };
  const out: MemorySource = { by: source.by.trim(), task: null, role: null, agent: null, machine: null, decision: null };
  for (const field of ["task", "role", "agent", "machine", "decision"] as const) {
    const v = source[field];
    if (v == null) continue;
    if (typeof v !== "string" || v.length > MAX_SOURCE_FIELD) return { error: `That memory's ${field} won't do.` };
    out[field] = v.trim() || null;
  }
  if (out.by.length > MAX_SOURCE_FIELD) return { error: "That memory's author won't do." };
  if (out.decision) {
    out.decision = out.decision.toLowerCase();
    if (!UUID.test(out.decision)) return { error: "That memory's decision isn't an id." };
  }
  return out;
}

export interface MemoryHooks {
  broadcast(message: ServerToClient): void;
}

export class Memories {
  constructor(private store: Store, private hooks: MemoryHooks) {}

  /** Add a memory (active unless `status` says otherwise). The caller makes the id. */
  create(id: string, input: MemoryInput, opts: { at?: number } = {}): Memory | Refusal {
    id = typeof id === "string" ? id.toLowerCase() : "";
    if (!UUID.test(id)) return { error: "A memory needs an id." };
    if (this.store.memory(id)) return { error: "That memory is already there." };
    const clean = normalize(input);
    if ("error" in clean) return clean;
    const source = cleanSource(input.source);
    if ("error" in source) return source;
    const status = input.status ?? "active";
    if (!has(MemoryStatusValues, status)) return { error: "A memory is active, proposed or archived." };
    let supersedes: string | null = null;
    if (input.supersedes != null) {
      supersedes = typeof input.supersedes === "string" ? input.supersedes.toLowerCase() : "";
      if (supersedes === id) return { error: "A memory can't supersede itself." };
      if (!this.store.memory(supersedes)) return { error: "The memory it supersedes isn't there." };
    }
    const at = opts.at ?? Date.now();
    const memory: Memory = { id, ...clean, status, source, supersedes, createdAt: at, updatedAt: at, lastUsedAt: null, uses: 0 };
    return this.save(memory, source.by, at);
  }

  /** Change a memory's text, tags, kind or scope; what's left out stays. The log keeps the text it replaced. */
  edit(id: string, patch: Partial<MemoryContent>, by: string, opts: { at?: number } = {}): Memory | Refusal {
    const before = this.store.memory(String(id).toLowerCase());
    if (!before) return { error: "That memory isn't there any more." };
    const clean = normalize({
      scope: patch.scope ?? before.scope, kind: patch.kind ?? before.kind, text: patch.text ?? before.text, tags: patch.tags ?? before.tags,
    });
    if ("error" in clean) return clean;
    const after: Memory = { ...before, ...clean };
    if (JSON.stringify(after) === JSON.stringify(before)) return before;
    const at = opts.at ?? Date.now();
    return this.save({ ...after, updatedAt: at }, by, at);
  }

  /** Accept a proposed memory (active), archive one, or bring one back. */
  setStatus(id: string, status: MemoryStatus, by: string, opts: { at?: number } = {}): Memory | Refusal {
    const before = this.store.memory(String(id).toLowerCase());
    if (!before) return { error: "That memory isn't there any more." };
    if (!has(MemoryStatusValues, status)) return { error: "A memory is active, proposed or archived." };
    if (before.status === status) return before;
    const at = opts.at ?? Date.now();
    return this.save({ ...before, status, updatedAt: at }, by, at);
  }

  /** Delete a memory for good (its log stays). Archiving is `setStatus`. */
  remove(id: string, by: string, opts: { at?: number } = {}): { id: string } | Refusal {
    id = String(id).toLowerCase();
    if (!this.store.deleteMemory(id, { by, at: opts.at ?? Date.now() })) return { error: "That memory isn't there any more." };
    this.hooks.broadcast({ type: "memory.removed", id });
    return { id };
  }

  /** Save and tell everyone; a memory that is now active archives the one it supersedes, in the same step. */
  private save(memory: Memory, by: string, at: number): Memory {
    const was = this.store.memory(memory.id);
    this.store.saveMemory(memory, { by, at });
    this.hooks.broadcast({ type: "memory.updated", memory });
    if (memory.status === "active" && was?.status !== "active" && memory.supersedes) {
      const old = this.store.memory(memory.supersedes);
      if (old && old.status !== "archived") {
        const archived: Memory = { ...old, status: "archived", updatedAt: at };
        this.store.saveMemory(archived, { by, at });
        this.hooks.broadcast({ type: "memory.updated", memory: archived });
      }
    }
    return memory;
  }
}
