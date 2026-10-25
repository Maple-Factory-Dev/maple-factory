// maple-factory server: one org's factory, in that org's own Cloudflare account.

import type { Env } from "./env.ts";
import { authConfigured, currentMember, devToken, handleAuth, sameOrigin } from "./auth.ts";
import { authenticateRunner, createEnrollment, enroll, MACHINE_ID, removeMachine } from "./machines.ts";
import { home, taskLink } from "./page.ts";
import { jiraWebhook, linearWebhook } from "./trackers.ts";
import { isLocal, machineHub, orgHub, text } from "./util.ts";
import { PROTOCOL_VERSION } from "./wire.ts";
import { intakeApi, intakeKey, slackCommand } from "./intake-routes.ts";

export { MachineHub } from "./machine-hub.ts";
export { OrgHub } from "./org-hub.ts";

const isUpgrade = (request: Request) => request.headers.get("upgrade")?.toLowerCase() === "websocket";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    if (path === "/healthz") {
      // What the apps need before signing in: the protocol, the org, and how to sign in here.
      const signIn = env.DEV_LOGIN && isLocal(request) ? "dev" : authConfigured(env) ? "github" : "unconfigured";
      return Response.json({ ok: true, protocol: PROTOCOL_VERSION, org: env.GITHUB_ORG || null, signIn, devLogin: signIn === "dev" ? env.DEV_LOGIN : null });
    }

    // Runners: enroll with a code, then connect with their own token.
    if (path === "/runner/enroll" && request.method === "POST") return enroll(request, env);
    if (path === "/runner/connect") {
      const id = url.searchParams.get("runner") ?? "";
      if (!isUpgrade(request)) return text("Expected a WebSocket.", 426);
      if (!MACHINE_ID.test(id) || !(await authenticateRunner(env, id, request))) return text("Unknown machine or bad token.", 401);
      const forward = new Request(request);
      forward.headers.set("x-machine-id", id);
      return machineHub(env, id).fetch(new Request("https://hub/runner", forward));
    }
    if (path.startsWith("/releases/")) {
      const object = await env.RELEASES.get(path.slice("/releases/".length));
      if (!object) return text("Not found.", 404);
      return new Response(object.body, { headers: { "content-type": object.httpMetadata?.contentType ?? "application/octet-stream", etag: object.httpEtag } });
    }

    const link = path.match(/^\/t\/([A-Z][A-Z0-9]{0,5}-\d+)$/);
    if (link) return taskLink(link[1]);

    if (path === "/integrations/slack/command" && request.method === "POST") return slackCommand(request, env);
    if (path === "/integrations/linear" && request.method === "POST") return linearWebhook(request, env);
    if (path === "/integrations/jira" && request.method === "POST") return jiraWebhook(request, env, url);
    if (path.startsWith("/api/intake") && intakeKey(request, env)) return (await intakeApi(request, env, path, null))!;

    const auth = await handleAuth(request, env);
    if (auth) return auth;
    if (path === "/dev/token" && request.method === "POST") return devToken(request, env);

    const me = await currentMember(request, env);
    if (path === "/") return home(request, env, me);
    if (!me) return text("Sign in first.", 401);
    if (!sameOrigin(request)) return text("Bad origin.", 403);

    // Apps: the live feed, and one socket per terminal being watched.
    if (path === "/client/connect") {
      if (!isUpgrade(request)) return text("Expected a WebSocket.", 426);
      const forward = new Request(request);
      forward.headers.set("x-member", JSON.stringify(me));
      return orgHub(env).fetch(new Request("https://org/connect", forward));
    }
    if (path === "/client/terminal") {
      if (!isUpgrade(request)) return text("Expected a WebSocket.", 426);
      const machine = url.searchParams.get("machine") ?? "";
      const session = url.searchParams.get("session") ?? "";
      if (!MACHINE_ID.test(machine) || !/^[0-9a-f-]{36}$/.test(session)) return text("Expected machine and session.", 400);
      const target = new URL("https://hub/view");
      target.searchParams.set("session", session);
      target.searchParams.set("login", me.login);
      for (const key of ["cols", "rows"]) if (url.searchParams.has(key)) target.searchParams.set(key, url.searchParams.get(key)!);
      return machineHub(env, machine).fetch(new Request(target, request));
    }

    const intake = await intakeApi(request, env, path, me);
    if (intake) return intake;
    if (path === "/api/me") return Response.json({ member: me, org: env.GITHUB_ORG || "local" });
    if (path === "/api/machines" && request.method === "GET") return orgHub(env).fetch("https://org/machines");
    const diff = /^\/api\/tasks\/([\w-]+)\/diff$/.exec(path);
    if (diff && request.method === "GET") return orgHub(env).fetch(`https://org/diff?task=${diff[1]}`);
    if (path === "/api/machines/enroll" && request.method === "POST") return createEnrollment(request, env, me);
    const removing = /^\/api\/machines\/([a-z0-9-]+)$/.exec(path);
    if (removing && request.method === "DELETE") return removeMachine(env, me, removing[1]);

    return text("Not found.", 404);
  },
} satisfies ExportedHandler<Env>;
