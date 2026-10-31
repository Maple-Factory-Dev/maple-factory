// Per-repo secrets, kept in OrgHub's SQLite and encrypted at rest. Apps can only write them: they see
// names, who changed them and when, never a value. Runners get a repo's values for a task assigned to
// them, or for their owner's own checkout (machine-hub.ts asks, engine.ts decides).
//
// Each value is sealed with AES-GCM under a key derived (HKDF-SHA256) from SECRETS_KEY: a Worker
// secret, or one this factory generates into D1's settings the first time it needs one. A fresh IV
// per value, and `repo\nname` as additional data, so a row copied onto another name won't open.
// Losing SECRETS_KEY loses every value; see server/README.md for backing it up and rotating it.

import type { Env } from "./env.ts";
import type { RepoSecret } from "./wire.ts";
import { applySettings } from "./settings.ts";
import { b64url } from "./util.ts";

export const SECRET_NAME = /^[A-Z_][A-Z0-9_]*$/;
export const MAX_SECRET_BYTES = 32 * 1024;
export const MAX_SECRETS_PER_REPO = 100;

const enc = new TextEncoder();
const dec = new TextDecoder();

/** SECRETS_KEY, made and kept in D1's settings when the factory has none. Never replaced once set:
 *  another key would make every stored value unreadable. */
export async function secretsKey(env: Env): Promise<string> {
  if (env.SECRETS_KEY) return env.SECRETS_KEY;
  await env.DB.prepare("INSERT INTO settings (key, value, updated_at) VALUES ('SECRETS_KEY', ?, ?) ON CONFLICT (key) DO NOTHING")
    .bind(`mfk_${b64url(crypto.getRandomValues(new Uint8Array(32)))}`, Date.now())
    .run();
  await applySettings(env, true);
  if (!env.SECRETS_KEY) throw new Error("The factory couldn't make its secrets key.");
  return env.SECRETS_KEY;
}

/** The AES-GCM key SECRETS_KEY derives for one use (`info`), so each kind of stored value has its own. */
export async function aesKey(secret: string, info = "repo-secrets v1"): Promise<CryptoKey> {
  const base = await crypto.subtle.importKey("raw", enc.encode(secret), "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: enc.encode("maple-factory"), info: enc.encode(info) },
    base,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

const aad = (repo: string, name: string) => enc.encode(`${repo.toLowerCase()}\n${name}`);

export class Secrets {
  private sql: SqlStorage;
  private env: Env;
  private key: { secret: string; key: CryptoKey } | null = null;

  constructor(sql: SqlStorage, env: Env) {
    this.sql = sql;
    this.env = env;
    sql.exec(`
      CREATE TABLE IF NOT EXISTS secrets (
        repo TEXT NOT NULL COLLATE NOCASE, name TEXT NOT NULL, iv BLOB NOT NULL, ciphertext BLOB NOT NULL,
        updated_by TEXT NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY (repo, name)
      );
    `);
  }

  private async cipher(): Promise<CryptoKey> {
    const secret = await secretsKey(this.env);
    if (this.key?.secret !== secret) this.key = { secret, key: await aesKey(secret) };
    return this.key.key;
  }

  /** Names and metadata only, every repo's (or one's). */
  list(repo?: string): RepoSecret[] {
    const rows = repo
      ? this.sql.exec("SELECT repo, name, updated_by, updated_at FROM secrets WHERE repo = ? ORDER BY name", repo)
      : this.sql.exec("SELECT repo, name, updated_by, updated_at FROM secrets ORDER BY repo, name");
    return [...rows].map((r) => ({ repo: r.repo as string, name: r.name as string, updatedBy: r.updated_by as string, updatedAt: r.updated_at as number }));
  }

  /** Throws with a message for the person when the name or value won't do. */
  /** `repo` as the org's repo list spells it. */
  async set(repo: string, name: string, value: string, by: string): Promise<void> {
    if (!SECRET_NAME.test(name)) throw new Error(`${name || "That"} isn't a usable name: capital letters, digits and _, not starting with a digit.`);
    const bytes = enc.encode(value);
    if (!bytes.length) throw new Error("A secret needs a value.");
    if (bytes.length > MAX_SECRET_BYTES) throw new Error("A secret's value can be at most 32 KB.");
    const exists = [...this.sql.exec("SELECT 1 FROM secrets WHERE repo = ? AND name = ?", repo, name)].length > 0;
    if (!exists && this.list(repo).length >= MAX_SECRETS_PER_REPO) throw new Error(`A repo can have at most ${MAX_SECRETS_PER_REPO} secrets.`);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: aad(repo, name) }, await this.cipher(), bytes);
    this.sql.exec(
      `INSERT INTO secrets (repo, name, iv, ciphertext, updated_by, updated_at) VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (repo, name) DO UPDATE SET iv = excluded.iv, ciphertext = excluded.ciphertext, updated_by = excluded.updated_by, updated_at = excluded.updated_at`,
      repo, name, iv.buffer, sealed, by, Date.now(),
    );
  }

  /** Whether there was one to delete. */
  delete(repo: string, name: string): boolean {
    return this.sql.exec("DELETE FROM secrets WHERE repo = ? AND name = ? RETURNING name", repo, name).toArray().length > 0;
  }

  /** A repo's values, by name. Only for a machine engine.ts has decided may have them. */
  async values(repo: string): Promise<Record<string, string>> {
    const rows = [...this.sql.exec("SELECT name, iv, ciphertext FROM secrets WHERE repo = ?", repo)];
    if (!rows.length) return {};
    const key = await this.cipher();
    const out: Record<string, string> = {};
    for (const r of rows) {
      const name = r.name as string;
      const plain = await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: new Uint8Array(r.iv as ArrayBuffer), additionalData: aad(repo, name) },
        key,
        r.ciphertext as ArrayBuffer,
      );
      out[name] = dec.decode(plain);
    }
    return out;
  }
}
