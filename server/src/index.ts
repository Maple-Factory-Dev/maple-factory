// maple-factory server: one org's factory, in that org's own Cloudflare account.

import type { Env } from "./env.ts";
import { serve as serveAttachment, serveRunner as serveRunnerAttachment, upload as uploadAttachment, uploadProof } from "./attachments.ts";
import { authConfigured, currentMember, devToken, handleAuth, sameOrigin } from "./auth.ts";
import { authenticateRunner, createEnrollment, enroll, MACHINE_ID, removeMachine } from "./machines.ts";
import { installScript } from "./install.ts";
import { home, taskLink } from "./page.ts";
import { githubWebhook, jiraWebhook, linearWebhook } from "./trackers.ts";
import { isLocal, machineHub, orgHub, publicOrigin, text } from "./util.ts";
import { PROTOCOL_VERSION } from "./wire.ts";
import { intakeApi, intakeKey, slackCommand } from "./intake-routes.ts";
import { release } from "./releases.ts";
import { applySettings } from "./settings.ts";
import { handleSetup } from "./setup.ts";
import { SERVER_VERSION, serverUpdate } from "./version.ts";

export { MachineHub } from "./machine-hub.ts";
export { OrgHub } from "./org-hub.ts";

/** Pages people open in a browser. Once the factory has a PUBLIC_URL, these move there from its other
 *  addresses (its workers.dev one), since GitHub sign-in only comes back to that one. */
const PAGES = /^\/(app(\/.*)?|setup(\/(?!id$).*)?|auth\/login|t\/.*)?$/;

const isUpgrade = (request: Request) => request.headers.get("upgrade")?.toLowerCase() === "websocket";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    await applySettings(env);

    if (env.PUBLIC_URL && request.method === "GET" && !isLocal(request) && PAGES.test(path) && !isUpgrade(request)) {
      const home = new URL(env.PUBLIC_URL);
      if (home.host !== url.host) return Response.redirect(`${home.origin}${path}${url.search}`, 302);
    }

    if (path === "/healthz") {
      // What the apps need before signing in: the protocol, the org, and how to sign in here.
      const signIn = env.DEV_LOGIN && isLocal(request) ? "dev" : authConfigured(env) ? "github" : "unconfigured";
      return Response.json({ ok: true, version: SERVER_VERSION, protocol: PROTOCOL_VERSION, org: env.GITHUB_ORG || null, signIn, devLogin: signIn === "dev" ? env.DEV_LOGIN : null });
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
    if (path.startsWith("/runner/attachments/") && request.method === "GET") return serveRunnerAttachment(request, env, path.slice("/runner/attachments/".length));
    const proof = /^\/runner\/proof\/([^/]+)$/.exec(path);
    if (proof && request.method === "PUT") return uploadProof(request, env, proof[1]);
    if (path === "/install.sh") return installScript(publicOrigin(request, env));
    if (path.startsWith("/releases/")) return (await release(env, path.slice("/releases/".length))) ?? text("Not found.", 404);

    const link = path.match(/^\/t\/([A-Z][A-Z0-9]{0,9}-\d+)$/);
    if (link) return taskLink(link[1]);

    if (path === "/integrations/slack/command" && request.method === "POST") return slackCommand(request, env);
    if (path === "/integrations/linear" && request.method === "POST") return linearWebhook(request, env);
    if (path === "/integrations/github" && request.method === "POST") return githubWebhook(request, env);
    if (path === "/integrations/jira" && request.method === "POST") return jiraWebhook(request, env, url);
    if (path.startsWith("/api/intake") && intakeKey(request, env)) return (await intakeApi(request, env, path, null))!;

    const setup = await handleSetup(request, env);
    if (setup) return setup;
    const auth = await handleAuth(request, env);
    if (auth) return auth;
    if (path === "/dev/token" && request.method === "POST") return devToken(request, env);
    if (path.startsWith("/dev/") && env.DEV_LOGIN && isLocal(request)) {
      // Local dev, for the e2e tests: publish a release file to the bucket, or run the org hub's alarm now.
      const file = /^\/dev\/releases\/([\w.\-/]+)$/.exec(path);
      if (file && request.method === "PUT" && !file[1].includes("..")) {
        await env.RELEASES.put(file[1], await request.arrayBuffer(), { httpMetadata: { contentType: "application/json" } });
        return new Response(null, { status: 204 });
      }
      if (path === "/dev/alarm" && request.method === "POST") return orgHub(env).fetch(`https://org/dev/alarm${url.search}`, { method: "POST" });
    }

    const me = await currentMember(request, env);
    if (path === "/") return home(request, env, me, me?.role === "admin" ? await serverUpdate(env) : null);
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

    // Files pasted or dropped into briefs and notes (src/attachments.ts).
    if (path === "/api/attachments" && request.method === "POST") return uploadAttachment(request, env, me);
    if (path.startsWith("/attachments/") && request.method === "GET") return serveAttachment(env, path.slice("/attachments/".length));

    const intake = await intakeApi(request, env, path, me);
    if (intake) return intake;
    if (path === "/api/me") return Response.json({ member: me, org: env.GITHUB_ORG || "local" });
    if (path === "/api/machines" && request.method === "GET") return orgHub(env).fetch("https://org/machines");
    if (path === "/api/usage/goals" && request.method === "GET") return orgHub(env).fetch("https://org/usage/goals");
    if (path === "/api/stats" && request.method === "GET") {
      // For prompt and loop tuning: ?days= (7, 30 or 90), &goal=, &raw=1 adds the event rows.
      if (me.role !== "admin") return text("Only admins can see statistics.", 403);
      return orgHub(env).fetch(`https://org/stats${url.search}`);
    }
    const diff = /^\/api\/tasks\/([\w-]+)\/diff$/.exec(path);
    if (diff && request.method === "GET") return orgHub(env).fetch(`https://org/diff?task=${diff[1]}`);
    if (path === "/api/machines/enroll" && request.method === "POST") return createEnrollment(request, env, me);
    const removing = /^\/api\/machines\/([a-z0-9-]+)$/.exec(path);
    if (removing && request.method === "DELETE") return removeMachine(env, me, removing[1]);

    return text("Not found.", 404);
  },
} satisfies ExportedHandler<Env>;
