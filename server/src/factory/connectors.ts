// The factory's MCP connectors: MCP servers every session gets alongside `maple`. Their env and
// header values are secrets: they go to runners in session.open and never to the apps, which see
// each key with an empty value.

import type { McpConnector } from "../wire.ts";

const NAME = /^[a-z0-9][a-z0-9-]{0,39}$/;
const KEY = /^[A-Za-z_][A-Za-z0-9_-]*$/;

/** The list as apps see it: every secret value blank, so only which keys are set shows. */
export function redacted(connectors: McpConnector[]): McpConnector[] {
  const blank = (m: Record<string, string>) => Object.fromEntries(Object.keys(m).map((k) => [k, ""]));
  return connectors.map((c) => ({ ...c, env: blank(c.env ?? {}), headers: blank(c.headers ?? {}) }));
}

/**
 * Checks an admin's save and folds it onto what's stored: a blank secret value keeps the stored one
 * (same connector name, same key); a key left out is removed. Returns the list to store, or a
 * problem for the person.
 */
export function merged(saved: McpConnector[], before: McpConnector[]): McpConnector[] | string {
  const names = new Set<string>();
  const out: McpConnector[] = [];
  for (const raw of saved) {
    const name = raw.name.trim().toLowerCase();
    if (!NAME.test(name)) return `“${raw.name}” isn't a connector name: use lowercase letters, digits and dashes.`;
    if (name === "maple") return "maple is the factory's own MCP server; pick another name.";
    if (names.has(name)) return `There are two connectors named ${name}.`;
    names.add(name);
    const old = before.find((c) => c.name === name);
    const secrets = (now: Record<string, string> | undefined, was: Record<string, string> | undefined, what: string): Record<string, string> | string => {
      const kept: Record<string, string> = {};
      for (const [k0, v] of Object.entries(now ?? {})) {
        const k = k0.trim();
        if (!KEY.test(k)) return `${name}: “${k0}” isn't a valid ${what} name.`;
        const value = v === "" ? was?.[k] : v;
        if (value === undefined) return `${name}: ${k} needs a value.`;
        kept[k] = value;
      }
      return kept;
    };
    const transport = raw.transport;
    if (transport !== "stdio" && transport !== "http") return `${name}: pick stdio or http.`;
    const command = raw.command?.trim() || null;
    const url = raw.url?.trim() || null;
    if (transport === "stdio" && !command) return `${name} needs a command to run.`;
    if (transport === "http" && !(url && /^https?:\/\/\S+$/.test(url))) return `${name} needs an http(s) URL.`;
    const env = transport === "stdio" ? secrets(raw.env, old?.env, "environment variable") : {};
    if (typeof env === "string") return env;
    const headers = transport === "http" ? secrets(raw.headers, old?.headers, "header") : {};
    if (typeof headers === "string") return headers;
    out.push({
      name,
      transport,
      command: transport === "stdio" ? command : null,
      args: transport === "stdio" ? (raw.args ?? []).filter((a) => a !== "") : [],
      url: transport === "http" ? url : null,
      env,
      headers,
      enabled: raw.enabled,
      autoAllow: raw.autoAllow,
    });
  }
  return out;
}
