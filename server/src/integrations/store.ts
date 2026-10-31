// Integrations' settings and status, in OrgHub's SQLite. Each value is sealed with AES-GCM under a key
// SECRETS_KEY derives for integrations, with its integration and field as additional data, so a value
// moved to another row or field won't open. What's stored wins over the Worker's env vars, field by
// field; with nothing stored, an integration runs on its env vars as it did before Settings had it.

import type { Env } from "../env.ts";
import type { Integration, IntegrationKind } from "../wire.ts";
import { aesKey, secretsKey } from "../secrets.ts";
import { INTEGRATIONS, definition, fromEnv, merged, type IntegrationDef } from "./registry.ts";

const enc = new TextEncoder();
const dec = new TextDecoder();
const INFO = "integrations v1";

const aad = (kind: string, field: string) => enc.encode(`${kind}\n${field}`);
const b64 = (bytes: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(bytes)));
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

interface Row {
  kind: string;
  enabled: number | null;
  sealed: string | null;
  last_event_at: number | null;
  last_error: string | null;
  updated_by: string | null;
  updated_at: number | null;
}

export class Integrations {
  private sql: SqlStorage;
  private env: Env;
  private key: { secret: string; key: CryptoKey } | null = null;

  constructor(sql: SqlStorage, env: Env) {
    this.sql = sql;
    this.env = env;
    // A row with no updated_at was only heard from (its status), never saved in Settings.
    sql.exec(`
      CREATE TABLE IF NOT EXISTS integrations (
        kind TEXT PRIMARY KEY, enabled INTEGER, sealed TEXT, last_event_at INTEGER, last_error TEXT,
        updated_by TEXT, updated_at INTEGER
      );
    `);
  }

  private async cipher(): Promise<CryptoKey> {
    const secret = await secretsKey(this.env);
    if (this.key?.secret !== secret) this.key = { secret, key: await aesKey(secret, INFO) };
    return this.key.key;
  }

  private row(kind: string): Row | undefined {
    return this.sql.exec("SELECT * FROM integrations WHERE kind = ?", kind).toArray()[0] as unknown as Row | undefined;
  }

  /** What's stored for one, opened. */
  private async stored(row: Row | undefined): Promise<Record<string, string>> {
    if (!row?.sealed) return {};
    const key = await this.cipher();
    const out: Record<string, string> = {};
    for (const [field, box] of Object.entries(JSON.parse(row.sealed) as Record<string, string>)) {
      const [iv, ct] = box.split(".");
      out[field] = dec.decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(iv), additionalData: aad(row.kind, field) }, key, unb64(ct)));
    }
    return out;
  }

  private async seal(kind: string, values: Record<string, string>): Promise<string> {
    const key = await this.cipher();
    const out: Record<string, string> = {};
    for (const [field, value] of Object.entries(values)) {
      const iv = crypto.getRandomValues(new Uint8Array(12));
      out[field] = `${b64(iv)}.${b64(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: aad(kind, field) }, key, enc.encode(value)))}`;
    }
    return JSON.stringify(out);
  }

  private enabled(def: IntegrationDef, row: Row | undefined, values: Record<string, string>): boolean {
    if (row?.updated_at != null) return row.enabled === 1;
    return def.fields.every((f) => !f.required || values[f.name]);
  }

  /** Every integration as apps see it: secret values blank; `status` adds a line about how each is doing. */
  async list(status: (kind: IntegrationKind, values: Record<string, string>) => string | null = () => null): Promise<Integration[]> {
    const base = this.env.PUBLIC_URL ? this.env.PUBLIC_URL.replace(/\/+$/, "") : "";
    const out: Integration[] = [];
    for (const def of INTEGRATIONS) {
      const row = this.row(def.kind);
      // Sealed under another SECRETS_KEY: show it as needing its secrets again rather than fail the snapshot.
      const stored = await this.stored(row).catch(() => null);
      const env = fromEnv(def, this.env);
      const values: Record<string, string> = {};
      for (const f of def.fields) {
        const v = stored?.[f.name] ?? env[f.name];
        if (v) values[f.name] = f.secret ? "" : v;
      }
      out.push({
        kind: def.kind,
        label: def.label,
        fields: def.fields.map(({ env: _env, ...f }) => f),
        enabled: this.enabled(def, row, { ...env, ...stored }),
        values,
        fromEnv: def.fields.filter((f) => !stored?.[f.name] && env[f.name]).map((f) => f.name),
        webhookUrl: base + def.webhookPath,
        setupUrl: base && def.setupUrl ? def.setupUrl(base) : null,
        status: status(def.kind, values),
        lastEventAt: row?.last_event_at ?? null,
        lastError: stored ? (row?.last_error ?? null) : "Its saved settings can't be read with this factory's SECRETS_KEY; save them again.",
        updatedBy: row?.updated_by ?? null,
        updatedAt: row?.updated_at ?? null,
      });
    }
    return out;
  }

  /** An admin's save; throws with a message for the person when it won't do. */
  async save(kind: IntegrationKind, enabled: boolean, values: Record<string, string>, by: string): Promise<void> {
    const def = definition(kind);
    if (!def) throw new Error(`There's no ${kind} integration.`);
    const row = this.row(kind);
    const result = merged(def, enabled, values, await this.stored(row), fromEnv(def, this.env));
    if (typeof result === "string") throw new Error(result);
    this.sql.exec(
      `INSERT INTO integrations (kind, enabled, sealed, updated_by, updated_at) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT (kind) DO UPDATE SET enabled = excluded.enabled, sealed = excluded.sealed, updated_by = excluded.updated_by, updated_at = excluded.updated_at`,
      kind, enabled ? 1 : 0, await this.seal(kind, result), by, Date.now(),
    );
  }

  /** What a webhook handler works with: stored values over env vars. Null when it's off or not set up. */
  async config(kind: IntegrationKind): Promise<Record<string, string> | null> {
    const def = definition(kind);
    if (!def) return null;
    const row = this.row(kind);
    const values = { ...fromEnv(def, this.env), ...(await this.stored(row)) };
    return this.enabled(def, row, values) && def.fields.every((f) => !f.required || values[f.name]) ? values : null;
  }

  /** It reached the factory and was verified: clears the last error. */
  noteEvent(kind: IntegrationKind) {
    this.sql.exec(
      "INSERT INTO integrations (kind, last_event_at) VALUES (?, ?) ON CONFLICT (kind) DO UPDATE SET last_event_at = excluded.last_event_at, last_error = NULL",
      kind, Date.now(),
    );
  }

  noteError(kind: IntegrationKind, error: string) {
    this.sql.exec(
      "INSERT INTO integrations (kind, last_error) VALUES (?, ?) ON CONFLICT (kind) DO UPDATE SET last_error = excluded.last_error",
      kind, error.slice(0, 500),
    );
  }
}
