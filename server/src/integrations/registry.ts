// The integrations an admin can set up in Settings › Integrations: what each one asks for, which of
// its fields are secret, where its webhook lands and the Worker env var each field fell back on
// before Settings had it. Adding one (Discord, say) is an entry here plus its webhook handler.

import type { Env } from "../env.ts";
import type { IntegrationField, IntegrationKind } from "../wire.ts";
import { orgHub } from "../util.ts";

export interface IntegrationDef {
  kind: IntegrationKind;
  label: string;
  /** Where its events reach the factory. */
  webhookPath: string;
  fields: (IntegrationField & { env: keyof Env })[];
}

const LABEL_HELP = "The label that sends an issue to the factory. Default: maple.";

export const INTEGRATIONS: IntegrationDef[] = [
  {
    kind: "slack",
    label: "Slack",
    webhookPath: "/integrations/slack/command",
    fields: [
      { name: "signingSecret", label: "Signing secret", secret: true, required: true, env: "SLACK_SIGNING_SECRET", help: "Your Slack app's Basic Information › Signing Secret. Point its /maple slash command at the URL below." },
    ],
  },
  {
    kind: "linear",
    label: "Linear",
    webhookPath: "/integrations/linear",
    fields: [
      { name: "webhookSecret", label: "Webhook signing secret", secret: true, required: true, env: "LINEAR_WEBHOOK_SECRET", help: "From the webhook you add in Linear's Settings › API, pointed at the URL below (Issues and Comments)." },
      { name: "apiKey", label: "API key", secret: true, required: false, env: "LINEAR_API_KEY", help: "A personal API key, so the factory's bot can comment back on the issue." },
      { name: "label", label: "Label", secret: false, required: false, env: "LINEAR_LABEL", help: LABEL_HELP },
    ],
  },
  {
    kind: "jira",
    label: "Jira",
    webhookPath: "/integrations/jira",
    fields: [
      { name: "webhookSecret", label: "Webhook secret", secret: true, required: true, env: "JIRA_WEBHOOK_SECRET", help: "Any long random string. Jira Cloud doesn't sign webhooks: add it to the URL below as ?secret=…" },
      { name: "site", label: "Site", secret: false, required: true, env: "JIRA_SITE", help: "Your Jira site, e.g. https://acme.atlassian.net. Only its issues are taken, and only it gets the API token." },
      { name: "email", label: "Account email", secret: false, required: false, env: "JIRA_EMAIL", help: "The account the bot comments as." },
      { name: "apiToken", label: "API token", secret: true, required: false, env: "JIRA_API_TOKEN", help: "That account's API token (id.atlassian.com › Security)." },
      { name: "label", label: "Label", secret: false, required: false, env: "JIRA_LABEL", help: LABEL_HELP },
    ],
  },
];

export function definition(kind: string): IntegrationDef | undefined {
  return INTEGRATIONS.find((d) => d.kind === kind);
}

/** Its fields' values from the Worker's env vars, the ones that are set. */
export function fromEnv(def: IntegrationDef, env: Env): Record<string, string> {
  const out: Record<string, string> = {};
  for (const f of def.fields) {
    const v = env[f.env];
    if (typeof v === "string" && v) out[f.name] = v;
  }
  return out;
}

/**
 * Checks an admin's save and folds it onto what's stored, as connectors' `merged` does: a blank secret
 * keeps the stored one, a blank plain field clears it. An enabled integration needs its required fields,
 * from the save, what's stored or the env vars. Returns the values to store, or a problem for the person.
 */
export function merged(def: IntegrationDef, enabled: boolean, saved: Record<string, string>, stored: Record<string, string>, env: Record<string, string>): Record<string, string> | string {
  for (const name of Object.keys(saved)) if (!def.fields.some((f) => f.name === name)) return `${def.label} has no setting called ${name}.`;
  const out: Record<string, string> = {};
  for (const f of def.fields) {
    let value = (saved[f.name] ?? "").trim();
    if (!value && f.secret) value = stored[f.name] ?? "";
    if (value && f.name === "label") {
      value = value.toLowerCase();
      if (/\s/.test(value)) return `${def.label}'s label can't have spaces.`;
    }
    if (value && f.name === "site") {
      if (!/^https:\/\/[^\s/]+\/?$/.test(value)) return `${def.label}'s site needs to be an https:// address, like https://acme.atlassian.net.`;
      value = new URL(value).origin;
    }
    if (value) out[f.name] = value;
    if (enabled && f.required && !value && !env[f.name]) return `${def.label} needs its ${f.label.toLowerCase()}.`;
  }
  return out;
}

/** How the Worker's handlers reach integrations' settings and status (OrgHub keeps them). */
export interface IntegrationAccess {
  /** Stored values over env vars; null when it's off or not set up. */
  config(kind: IntegrationKind): Promise<Record<string, string> | null>;
  /** It was heard from and verified, or (with `error`) something went wrong. */
  event(kind: IntegrationKind, error?: string): Promise<void>;
}

export function integrationAccess(env: Env): IntegrationAccess {
  return {
    config: async (kind) => (await orgHub(env).fetch(`https://org/integrations/${kind}/config`)).json(),
    event: async (kind, error) => {
      await orgHub(env).fetch(`https://org/integrations/${kind}/event`, { method: "POST", body: JSON.stringify({ error: error ?? null }) });
    },
  };
}

export const integrationConfig = (env: Env, kind: IntegrationKind) => integrationAccess(env).config(kind);
export const integrationEvent = (env: Env, kind: IntegrationKind, error?: string) => integrationAccess(env).event(kind, error);
