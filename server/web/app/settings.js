// The factory's settings on the web, for admins who don't run the Mac app: its name, repos, secrets,
// people, prompts, integrations, and merging and risk. It sends the same feed messages the Mac app does
// and reads the snapshot and their *.updated answers; the server checks every one is an admin's.
// Connectors and each repo's worktree scripts stay in the Mac app.
//
// Each form edits a draft against the server's value it started from (syncDraft): another admin's save
// resets a form nobody has touched, and leaves one with edits in it alone. The helpers up top are pure
// and tested on their own (test/settings.test.ts).

export const LEVELS = ["low", "medium", "high"];
export const SECTIONS = [
  { key: "general", title: "General" },
  { key: "repos", title: "Repositories" },
  { key: "secrets", title: "Secrets" },
  { key: "people", title: "People" },
  { key: "prompts", title: "Prompts" },
  { key: "integrations", title: "Integrations" },
  { key: "merging", title: "Merging & risk" },
];
export const SECRET_NAME = /^[A-Z_][A-Z0-9_]*$/;
const PROMPT_MAX = 4000;

// ---- pure helpers ----

/** A whole number from a form field clamped to min…max, or `fallback` when it's blank or not a number. */
export function clampInt(value, min, max, fallback) {
  if (value === "" || value == null) return fallback;
  const n = Math.round(Number(value));
  return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : fallback;
}

/** The Merging & risk form's fields for a policy, with the server's defaults where it leaves one out. */
export function formFromPolicy(p) {
  const per = (rec, fallback) => Object.fromEntries(LEVELS.map((l) => [l, rec?.[l] ?? fallback]));
  return {
    autoMerges: p.autoMerges !== false,
    autoFixMerges: p.autoFixMerges !== false,
    autoMerge: per(p.autoMerge, false),
    planApprovals: per(p.planApprovals, 1),
    finalReviews: per(p.finalReviews, 1),
    maxFiles: p.maxFiles,
    maxLines: p.maxLines,
    scoutItems: p.scoutItems ?? 3,
    taskMinutes: p.taskMinutes ?? 60,
    taskCostUsd: p.taskCostUsd ?? "",
    checks: (p.areas ?? []).map((a) => ({
      name: a.name,
      level: a.level,
      enabled: a.enabled,
      kind: a.rule?.trim() ? "rule" : "paths",
      paths: a.paths.join(", "),
      rule: a.rule ?? "",
    })),
  };
}

/** A SensitiveArea from a risk check's row: a path check keeps its globs, a rule check its text. */
export function areaFromCheck(c) {
  const area = { name: c.name.trim(), paths: c.kind === "rule" ? [] : String(c.paths).split(/[\s,]+/).filter(Boolean), level: c.level, enabled: !!c.enabled };
  if (c.kind === "rule") area.rule = c.rule.trim();
  return area;
}

/** What the server would refuse in the risk checks (policy.ts's validPolicy), or null. */
export function checksProblem(checks) {
  const names = new Set();
  for (const c of checks.map(areaFromCheck)) {
    if (!c.name) return "Every risk check needs a name.";
    if (names.has(c.name.toLowerCase())) return `There are two risk checks named ${c.name}.`;
    names.add(c.name.toLowerCase());
    if (!c.paths.length && !c.rule) return `Give ${c.name} ${c.rule === undefined ? "some paths" : "a rule"}.`;
  }
  return null;
}

/** The RiskPolicy to save from the form: numbers clamped to what the server takes (a budget of at least
 *  one file and line, approvals and reviews 0–10, Scout 1–10 items), anything blank or unreadable back to
 *  `base`'s, and the risk checks as their rows say (or `base`'s, for a form without them). */
export function policyFromForm(form, base) {
  const counts = (key) => Object.fromEntries(LEVELS.map((l) => [l, clampInt(form[key]?.[l], 0, 10, base[key]?.[l] ?? 1)]));
  return {
    ...base,
    maxFiles: clampInt(form.maxFiles, 1, 10_000, base.maxFiles),
    maxLines: clampInt(form.maxLines, 1, 1_000_000, base.maxLines),
    areas: form.checks ? form.checks.map(areaFromCheck) : base.areas,
    planApprovals: counts("planApprovals"),
    finalReviews: counts("finalReviews"),
    autoMerge: Object.fromEntries(LEVELS.map((l) => [l, !!form.autoMerge?.[l]])),
    autoFixMerges: !!form.autoFixMerges,
    autoMerges: !!form.autoMerges,
    scoutItems: clampInt(form.scoutItems, 1, 10, base.scoutItems ?? 3),
    taskMinutes: taskMinutes(form.taskMinutes, base.taskMinutes ?? 60),
    taskCostUsd: taskCost(form.taskCostUsd, base.taskCostUsd ?? null),
  };
}

/** A task's time budget from the form: 0 (or below) is off, otherwise 5–1440 minutes; blank keeps `fallback`. */
export function taskMinutes(value, fallback) {
  const n = clampInt(value, -1, 1440, fallback);
  return n <= 0 ? 0 : Math.max(5, n);
}

/** A task's cost budget from the form, to the cent: blank is no limit; unreadable keeps `fallback`. */
export function taskCost(value, fallback) {
  if (value === "" || value == null) return null;
  const n = Number(value);
  return Number.isFinite(n) ? Math.max(0, Math.round(n * 100) / 100) : fallback;
}

/** GitHub logins from what an admin typed: "a, @b, https://github.com/c/" → ["a", "b", "c"], once each
 *  (ignoring case), without `org` (the factory's own, which always counts). */
export function cleanOwners(text, org = "") {
  const owners = [];
  for (const raw of String(text ?? "").split(/[\s,]+/)) {
    const login = raw.trim().replace(/^@/, "").replace(/^https?:\/\/(www\.)?github\.com\//i, "").replace(/\/+$/, "");
    if (!login || login.toLowerCase() === org.toLowerCase()) continue;
    if (!owners.some((o) => o.toLowerCase() === login.toLowerCase())) owners.push(login);
  }
  return owners;
}

/** An integration's status line, as the Mac app words it: `tone` is "error", "muted" or "faint". `ago`
 *  turns a time into "3m ago". */
export function integrationStatus(i, ago) {
  if (i.lastError) return { tone: "error", text: `Error: ${i.lastError}` };
  if (i.enabled) return { tone: "muted", text: i.lastEventAt ? `Connected · last event ${ago(i.lastEventAt)}` : "Connected · no events yet" };
  return i.updatedBy ? { tone: "muted", text: "Off" } : { tone: "faint", text: "Not set up" };
}

/** What to send to keep an integration as it is: secrets blank (kept), plain values as stored, and the
 *  ones the env vars give left out, so saving doesn't copy them into Settings. */
export function keptValues(i) {
  return Object.fromEntries(Object.entries(i.values ?? {}).filter(([name]) => !i.fromEnv?.includes(name)));
}

/** The form's fields for an integration: secrets blank, plain values as stored unless the env vars give them. */
export function integrationForm(i) {
  return Object.fromEntries(i.fields.map((f) => [f.name, f.secret || i.fromEnv?.includes(f.name) ? "" : i.values?.[f.name] ?? ""]));
}

/** The integrations.save for `draft` (the form's fields) over what's kept: a blank secret keeps the
 *  stored one, a blank plain field clears it. */
export function integrationSave(i, draft, enabled) {
  return { type: "integrations.save", kind: i.kind, enabled, values: { ...keptValues(i), ...draft } };
}

/** The URL to paste into Slack, Linear or Jira: on this server when it only gives a path, and for Jira
 *  with the webhook secret it has to carry. */
export function webhookUrl(i, origin) {
  const url = i.webhookUrl.startsWith("/") ? String(origin).replace(/\/+$/, "") + i.webhookUrl : i.webhookUrl;
  return url + (i.kind === "jira" ? "?secret=<webhook secret>" : "");
}

/** Slack's three URLs (events, interactivity, the slash command), next to its command URL. */
export function slackUrls(i, origin) {
  const command = webhookUrl(i, origin);
  const base = command.replace(/\/command$/, "");
  return [["Events URL", `${base}/events`], ["Interactivity URL", `${base}/actions`], ["Slash command URL", command]];
}

/** The setup guide on the site. */
export const SLACK_GUIDE = "https://maplefactory.dev/docs/slack";

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const copy = (v) => JSON.parse(JSON.stringify(v ?? null));

/** Whether a draft's value differs from the server's value it's held against. */
export const isDirty = (draft) => !!draft && !same(draft.value, draft.server);

/** The draft for a form, held against the server's latest `server` value: a new one starts from it; one
 *  with nothing changed follows it; one with edits keeps them, and is dirty only while they differ from it. */
export function syncDraft(draft, server) {
  if (!draft) return { server: copy(server), value: copy(server) };
  if (same(draft.server, server)) return draft;
  return isDirty(draft) ? { server: copy(server), value: draft.value } : { server: copy(server), value: copy(server) };
}

// ---- the page ----

/** The Settings page, wired to the app: `h` builds elements, `send` puts a message on the feed. */
export function createSettings({ state, h, send, toast, render, ago }) {
  const drafts = new Map(); // form → { server, value }
  const saving = new Map(); // what's been sent → the toast for when its *.updated comes back
  const confirming = new Set(); // destructive buttons asking "Sure?"
  const secret = { repo: null, name: "", value: "" };
  let adding = "";
  let nameBusy = false;
  let errorReports = null; // GET /api/error-reports: { on, locked }, once loaded
  let errorReportsBusy = false;

  /** The form's draft, synced to the server's value for it. */
  const draft = (key, server) => {
    const d = syncDraft(drafts.get(key), server);
    drafts.set(key, d);
    return d;
  };
  const go = (msg, done) => {
    if (!send(msg)) return false;
    saving.set(done.key, done.text);
    render();
    return true;
  };
  const ask = (key, label, yes, onYes) => confirming.has(key)
    ? [h("span", { class: "muted confirm" }, label),
      h("button", { type: "button", class: "btn small", onclick: () => { confirming.delete(key); render(); } }, "Keep"),
      h("button", { type: "button", class: "btn small danger", onclick: () => { confirming.delete(key); onYes(); } }, yes)]
    : null;
  const keep = (key, el) => (el.setAttribute("data-keep", `settings:${key}`), el);
  const field = (label, detail, control) => h("label", { class: "set-row" },
    h("span", { class: "set-label" }, h("span", {}, label), detail && h("span", { class: "set-detail" }, detail)), control);
  const toggle = (label, detail, on, flip, disabled = false) => h("label", { class: "set-row toggle-row" },
    h("span", { class: "set-label" }, h("span", {}, label), detail && h("span", { class: "set-detail" }, detail)),
    h("input", { type: "checkbox", class: "switch", role: "switch", checked: on, disabled, onchange: (e) => flip(e.target.checked) }));
  const saveBar = (key, dirty, onSave, onReset, { label = "Save", ready = dirty } = {}) => h("div", { class: "set-actions" },
    h("span", { class: "muted", style: "font-size:13px" }, saving.has(key) ? "Saving…" : dirty ? "Unsaved changes" : ""),
    h("span", { class: "spacer" }),
    dirty && h("button", { type: "button", class: "btn", onclick: onReset }, "Discard"),
    h("button", { type: "button", class: "btn primary", disabled: !ready || saving.has(key), onclick: onSave }, label));
  const macOnly = (what) => h("p", { class: "set-mac muted" }, `${what}: manage in the Mac app.`);

  function general() {
    const d = draft("name", state.name ?? "");
    const save = async () => {
      nameBusy = true;
      render();
      const name = d.value.trim();
      try {
        const res = await fetch("/api/name", name
          ? { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ name }) }
          : { method: "DELETE" });
        if (!res.ok) throw new Error(await res.text());
        state.name = (await res.json()).name ?? null;
        toast(name ? `Renamed to ${name}.` : `Back to ${state.org}.`);
      } catch (e) {
        toast(e.message || "Couldn't rename the factory.");
      }
      nameBusy = false;
      render();
    };
    const input = keep("name", h("input", { type: "text", maxlength: "60", placeholder: state.org, value: d.value,
      oninput: (e) => { d.value = e.target.value; render(); }, onkeydown: (e) => e.key === "Enter" && isDirty(d) && save() }));
    return [
      h("div", { class: "card set-card" },
        field("Name", `Shown instead of ${state.org}. Leave it blank to use the org's name.`, input),
        h("div", { class: "set-actions" }, h("span", { class: "spacer" }),
          h("button", { type: "button", class: "btn primary", disabled: !isDirty(d) || nameBusy, onclick: save }, nameBusy ? "Saving…" : "Save"))),
      errorReportsCard(),
      macOnly("The factory's icon"),
    ];
  }

  /** Whether the server and web app send crash and error reports (src/error-reports.ts). */
  function errorReportsCard() {
    if (!errorReports) {
      errorReports = { on: true, locked: false, loading: true };
      fetch("/api/error-reports").then((res) => (res.ok ? res.json() : Promise.reject(new Error()))).then((got) => { errorReports = got; render(); },
        () => { errorReports = { on: true, locked: false, failed: true }; render(); });
    }
    const flip = async (on) => {
      errorReportsBusy = true;
      render();
      try {
        const res = await fetch("/api/error-reports", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ on }) });
        if (!res.ok) throw new Error(await res.text());
        errorReports = await res.json();
        toast(errorReports.on ? "Error reports are on." : "Error reports are off.");
      } catch (e) {
        toast(e.message || "Couldn't change error reports.");
      }
      errorReportsBusy = false;
      render();
    };
    const { on, locked, loading, failed } = errorReports;
    return h("div", { class: "card set-card" },
      toggle("Send error reports to Maple Factory",
        "Errors in this factory's server and web app go to Maple Factory's Sentry project, with the server's version and the org. Never what anyone typed or sent: no cookies, credentials, request bodies or query strings.",
        on, flip, locked || loading || failed || errorReportsBusy),
      locked && h("p", { class: "set-detail muted", style: "margin:0" }, "Set by the Worker's SENTRY_DSN. Change or remove it there to use this toggle."),
      failed && h("p", { class: "set-detail muted", style: "margin:0" }, "Couldn't read whether error reports are on."),
      h("p", { class: "set-detail muted", style: "margin:0" }, h("a", { href: "https://maplefactory.dev/security#errors", target: "_blank", rel: "noopener" }, "What's sent, and what never is")));
  }

  function repos() {
    const list = [...(state.repos ?? [])].sort((a, b) => a.name.localeCompare(b.name));
    const add = () => {
      const name = adding.trim();
      if (!name) return;
      if (go({ type: "repos.add", name }, { key: "repos", text: `Added ${name}.` })) adding = "";
    };
    const owners = draft("owners", (state.repoOwners ?? []).join(", "));
    const saveOwners = () => go({ type: "repos.owners.set", owners: cleanOwners(owners.value, state.org) }, { key: "owners", text: "Saved the other GitHub accounts." });
    return [
      h("div", { class: "row set-head" },
        h("p", { class: "muted", style: "flex:1;margin:0" }, "The repos goals can work in: the ones the GitHub App is installed on, and any added here."),
        h("button", { type: "button", class: "btn small", onclick: () => { if (send({ type: "repos.refresh" })) toast("Reading the GitHub App's repos again…"); } }, "Refresh")),
      list.length
        ? h("div", { class: "list" }, list.map((r) => h("div", { class: "item set-item" },
          h("div", { style: "flex:1;min-width:0" },
            h("div", { class: "title mono" }, r.name),
            h("div", { class: "sub" }, r.source === "github" ? "GitHub App" : "Added by hand", r.isPrivate ? " · private" : " · public",
              r.defaultBranch ? ` · ${r.defaultBranch}` : "", r.description ? ` · ${r.description}` : "")),
          r.source !== "github" && (ask(`repo:${r.name}`, `Remove ${r.name}?`, "Remove",
            () => go({ type: "repos.remove", name: r.name }, { key: "repos", text: `Removed ${r.name}.` }))
            ?? h("button", { type: "button", class: "btn small danger-text", onclick: () => { confirming.add(`repo:${r.name}`); render(); } }, "Remove")))))
        : h("div", { class: "card empty" }, "No repos yet."),
      h("div", { class: "card set-card" },
        field("Add a repo", "One the GitHub App doesn't list, as owner/name.",
          h("div", { class: "row set-inline" },
            keep("repo-add", h("input", { type: "text", placeholder: "acme/web", value: adding, autocapitalize: "off", spellcheck: "false",
              oninput: (e) => { adding = e.target.value; render(); }, onkeydown: (e) => e.key === "Enter" && add() })),
            h("button", { type: "button", class: "btn", disabled: !adding.trim() || saving.has("repos"), onclick: add }, "Add")))),
      h("h2", {}, "Other GitHub accounts"),
      h("div", { class: "card set-card" },
        field("Approved accounts", `Repos in another org (or someone's own account) come in once it's approved here and the GitHub App is installed there. Logins, separated by commas.`,
          keep("owners", h("input", { type: "text", placeholder: "another-org, @someone", value: owners.value, autocapitalize: "off", spellcheck: "false",
            oninput: (e) => { owners.value = e.target.value; render(); } }))),
        state.githubApp && h("p", { class: "set-detail", style: "margin:0" }, "Then ", h("a", { href: state.githubApp.installUrl, target: "_blank", rel: "noopener" }, "install the GitHub App"), " on that account."),
        saveBar("owners", isDirty(owners), saveOwners, () => { drafts.delete("owners"); render(); })),
      macOnly("Each repo's worktree scripts"),
    ];
  }

  function secrets() {
    const repoNames = [...(state.repos ?? [])].map((r) => r.name).sort();
    if (!repoNames.length) return h("div", { class: "card empty" }, "Add a repo first; secrets belong to one.");
    if (!repoNames.includes(secret.repo)) secret.repo = repoNames[0];
    const mine = (state.secrets ?? []).filter((s) => s.repo === secret.repo).sort((a, b) => a.name.localeCompare(b.name));
    const name = secret.name.trim();
    const replacing = mine.some((s) => s.name === name);
    const valid = SECRET_NAME.test(name) && secret.value.length > 0;
    const set = () => {
      if (!valid) return;
      if (go({ type: "secrets.set", repo: secret.repo, name, value: secret.value }, { key: "secrets", text: `${replacing ? "Replaced" : "Set"} ${name} on ${secret.repo}.` })) {
        secret.name = "";
        secret.value = "";
        render();
      }
    };
    return [
      h("p", { class: "muted" }, "Environment variables a repo's tasks get on the machine running them. Values are encrypted and never shown again, here or in any app."),
      h("div", { class: "card set-card" },
        field("Repo", null, h("select", { onchange: (e) => { secret.repo = e.target.value; render(); } },
          repoNames.map((n) => h("option", { value: n, selected: n === secret.repo }, n))))),
      mine.length
        ? h("div", { class: "list" }, mine.map((s) => h("div", { class: "item set-item" },
          h("div", { style: "flex:1;min-width:0" },
            h("div", { class: "title mono" }, s.name),
            h("div", { class: "sub" }, `Set by ${s.updatedBy} · ${new Date(s.updatedAt).toLocaleString()}`)),
          ask(`secret:${s.repo}/${s.name}`, `Delete ${s.name}?`, "Delete",
            () => go({ type: "secrets.delete", repo: s.repo, name: s.name }, { key: "secrets", text: `Deleted ${s.name} from ${s.repo}.` }))
            ?? [h("button", { type: "button", class: "btn small", onclick: () => { secret.name = s.name; secret.value = ""; render(); document.querySelector("[data-keep='settings:secret-value']")?.focus(); } }, "Replace"),
              h("button", { type: "button", class: "btn small danger-text", onclick: () => { confirming.add(`secret:${s.repo}/${s.name}`); render(); } }, "Delete")])))
        : h("div", { class: "card empty" }, `${secret.repo} has no secrets yet.`),
      h("h2", {}, replacing ? `Replace ${name}` : "Add a secret"),
      h("div", { class: "card set-card" },
        field("Name", "Capital letters, digits and _, not starting with a digit.",
          keep("secret-name", h("input", { type: "text", class: "mono", placeholder: "API_KEY", value: secret.name, autocapitalize: "characters", autocomplete: "off", spellcheck: "false",
            oninput: (e) => { secret.name = e.target.value.toUpperCase(); render(); } }))),
        field("Value", replacing ? "Replaces the stored value." : null,
          keep("secret-value", h("input", { type: "password", class: "mono", autocomplete: "new-password", value: secret.value,
            oninput: (e) => { secret.value = e.target.value; render(); }, onkeydown: (e) => e.key === "Enter" && set() }))),
        name && !SECRET_NAME.test(name) && h("p", { class: "set-warn" }, `${name} isn't a usable name.`),
        h("div", { class: "set-actions" }, h("span", { class: "spacer" }),
          h("button", { type: "button", class: "btn primary", disabled: !valid || saving.has("secrets"), onclick: set }, replacing ? "Replace" : "Add secret"))),
    ];
  }

  function people() {
    const me = state.me.login;
    const members = [...state.members].sort((a, b) => (a.role === b.role ? a.login.localeCompare(b.login) : a.role === "admin" ? -1 : 1));
    return [
      h("p", { class: "muted" }, "Admins change the factory's settings, secrets and prompts. Owners of the GitHub organization always are; an admin can make anyone else who has signed in one too, or remove their access, which signs them out everywhere at once."),
      h("div", { class: "list" }, members.map((m) => {
        const locked = m.adminSource === "github";
        const badge = m.role !== "admin" ? h("span", { class: "pill" }, "Member")
          : locked ? h("span", { class: "pill role locked", title: "An owner of the GitHub organization; change it on GitHub." }, "GitHub owner")
            : h("span", { class: "pill role", title: m.adminGrantedBy ? `Made admin by ${m.adminGrantedBy}` : null }, "Admin");
        const actions = m.login === me ? [h("span", { class: "muted", style: "font-size:13px" }, "You")]
          : ask(`revoke:${m.login}`, `Sign ${m.login} out everywhere?`, "Remove",
            () => go({ type: "members.revoke", login: m.login }, { key: "members", text: `Removed ${m.login}'s access.` }))
            ?? [
              m.role !== "admin" && h("button", { type: "button", class: "btn small", onclick: () => go({ type: "admins.grant", login: m.login }, { key: "members", text: `${m.login} is an admin now.` }) }, "Make admin"),
              m.adminSource === "granted" && h("button", { type: "button", class: "btn small", onclick: () => go({ type: "admins.revoke", login: m.login }, { key: "members", text: `${m.login} isn't an admin any more.` }) }, "Remove admin"),
              !locked && h("button", { type: "button", class: "btn small danger-text", onclick: () => { confirming.add(`revoke:${m.login}`); render(); } }, "Remove member"),
            ];
        return h("div", { class: "item set-item person" },
          m.avatarUrl ? h("img", { class: "avatar", src: m.avatarUrl, alt: "" }) : h("span", { class: "avatar" }, m.login[0].toUpperCase()),
          h("div", { style: "flex:1;min-width:0" },
            h("div", { class: "title" }, m.name || m.login, " ", badge),
            h("div", { class: "sub" }, `@${m.login}`, m.adminSource === "granted" && m.adminGrantedBy ? ` · made admin by ${m.adminGrantedBy}` : "")),
          h("div", { class: "row set-buttons" }, actions));
      })),
    ];
  }

  function prompts() {
    const server = { planner: state.prompts?.planner ?? "", builder: state.prompts?.builder ?? "", reviewer: state.prompts?.reviewer ?? "" };
    const d = draft("prompts", server);
    const roles = [
      ["planner", "Planning", "How the planner should plan: conventions, what a plan must cover."],
      ["builder", "Building", "What the builder must do: test commands, style, what not to touch."],
      ["reviewer", "Review", "What the review agent should check for."],
    ];
    return [
      h("p", { class: "muted" }, "Added to every factory session's prompt, by role. A repo's and a goal's instructions add to these."),
      h("div", { class: "card set-card" },
        roles.map(([key, label, hint]) => h("label", { class: "set-row stacked" },
          h("span", { class: "set-label" }, h("span", {}, label),
            d.value[key].length > PROMPT_MAX - 500 && h("span", { class: d.value[key].length > PROMPT_MAX ? "set-warn" : "set-detail" }, `${d.value[key].length} / ${PROMPT_MAX}`)),
          keep(`prompt:${key}`, h("textarea", { rows: "5", placeholder: hint, oninput: (e) => { d.value[key] = e.target.value; render(); } }, d.value[key])))),
        saveBar("prompts", isDirty(d), () => go({ type: "prompts.save", prompts: d.value }, { key: "prompts", text: "Saved the prompts." }), () => { drafts.delete("prompts"); render(); })),
    ];
  }

  function integrations() {
    if (state.integrations == null) {
      return h("div", { class: "card empty" }, h("strong", {}, "Needs a newer server"), h("br"), "Update this factory's maple-server to set up integrations here.");
    }
    const copyUrl = (url) => navigator.clipboard.writeText(url).then(() => toast("Copied the webhook URL."), () => toast("Couldn't copy the webhook URL."));
    return [
      h("p", { class: "muted" }, "Where requests come into the factory from: Slack's @Maple and /maple, and Linear or Jira issues with the factory's label. The bot answers back where they came from."),
      state.integrations.map((i) => {
        const key = `integration:${i.kind}`;
        const d = draft(key, integrationForm(i));
        const status = integrationStatus(i, ago);
        const url = webhookUrl(i, location.origin);
        const fromEnv = i.fields.filter((f) => i.fromEnv?.includes(f.name));
        const save = (msg, text) => go(msg, { key, text });
        return h("div", { class: "card set-card" },
          h("div", { class: "set-row" },
            h("span", { class: "set-label" }, h("span", {}, i.label), h("span", { class: `set-status ${status.tone}` }, status.text)),
            h("input", { type: "checkbox", class: "switch", role: "switch", "aria-label": `${i.label} enabled`, checked: i.enabled, disabled: saving.has(key),
              onchange: (e) => save(integrationSave(i, keptValues(i), e.target.checked), `${i.label} is ${e.target.checked ? "on" : "off"}.`) })),
          i.kind === "slack" && slackSteps(i),
          i.fields.map((f) => {
            const isSet = i.values?.[f.name] != null;
            const env = i.fromEnv?.includes(f.name);
            const placeholder = f.secret ? (isSet ? "•••••••" : f.required ? "Required" : "Optional")
              : env ? i.values[f.name] ?? "" : f.required ? "Required" : "Optional";
            return field(h("span", {}, f.label, env && h("span", { class: "pill set-env", title: "Set by the Worker's environment variables" }, "environment")),
              f.help + (f.secret && isSet ? " Leave it blank to keep the one that's set." : ""),
              keep(`${key}:${f.name}`, h("input", { type: f.secret ? "password" : "text", class: "mono", placeholder, value: d.value[f.name] ?? "",
                autocomplete: f.secret ? "new-password" : "off", autocapitalize: "off", spellcheck: "false",
                oninput: (e) => { d.value[f.name] = e.target.value; render(); } })));
          }),
          i.kind === "slack" ? slackUrls(i, location.origin).map(([label, u]) => h("div", { class: "set-row set-webhook" },
            h("span", { class: "set-label" }, h("span", {}, label), h("span", { class: "set-detail mono", title: u }, u)),
            h("button", { type: "button", class: "btn small", onclick: () => copyUrl(u) }, "Copy"))) : h("div", { class: "set-row set-webhook" },
            h("span", { class: "set-label" }, h("span", {}, "Webhook URL"), h("span", { class: "set-detail mono", title: url }, url)),
            h("button", { type: "button", class: "btn small", onclick: () => copyUrl(url) }, "Copy")),
          fromEnv.length > 0 && h("p", { class: "set-detail", style: "margin:0" }, `Set by environment: ${fromEnv.map((f) => f.label).join(", ")}. A value saved here wins over it.`),
          i.updatedBy && i.updatedAt && h("p", { class: "set-detail", style: "margin:0" }, `Saved by @${i.updatedBy} · ${ago(i.updatedAt)}`),
          saveBar(key, isDirty(d), () => save(integrationSave(i, d.value, true), `Saved ${i.label}.`), () => { drafts.delete(key); render(); },
            { label: i.enabled ? "Save" : "Save and turn on", ready: isDirty(d) || !i.enabled }));
      }),
    ];
  }

  /** Slack's setup: the button that creates the app with this factory's URLs, the steps after it, and how it's doing. */
  function slackSteps(i) {
    return h("div", { class: "set-row stacked slack-setup" },
        h("span", { class: "set-label" }, h("span", {}, "Set up @Maple"), i.status && h("span", { class: "set-detail" }, i.status)),
        h("ol", { class: "slack-steps" },
          h("li", {}, i.setupUrl
            ? [h("a", { class: "btn small primary", href: i.setupUrl, target: "_blank", rel: "noopener" }, "Create the Slack app"), " opens Slack with this factory's URLs filled in. Pick your workspace and create it."]
            : ["Set this factory's PUBLIC_URL so the app can be created for you, or create it from the manifest in the ", h("a", { href: SLACK_GUIDE, target: "_blank", rel: "noopener" }, "setup guide"), "."]),
          h("li", {}, "In the app, Install App › Install to Workspace."),
          h("li", {}, "Paste its Basic Information › Signing Secret and OAuth & Permissions › Bot User OAuth Token below, and save. Then /invite @Maple to a public channel.")),
        h("span", { class: "set-detail" }, h("a", { href: SLACK_GUIDE, target: "_blank", rel: "noopener" }, "How @Maple works and what it can read")));
  }

  function merging() {
    if (!state.policy) return h("div", { class: "card empty" }, "Loading…");
    const d = draft("policy", formFromPolicy(state.policy));
    const f = d.value;
    const set = (fn) => { fn(f); render(); };
    const problem = checksProblem(f.checks);
    const num = (key, value, min, max, onset) => keep(`policy:${key}`, h("input", { type: "number", inputmode: "numeric", class: "set-num", min, max, value,
      oninput: (e) => set(() => onset(e.target.value === "" ? "" : e.target.valueAsNumber)) }));
    return [
      h("p", { class: "muted" }, "What happens after a change is approved, and how much sign-off each risk level needs, for everyone in the factory."),
      h("h2", {}, "After approval"),
      h("div", { class: "card set-card" },
        toggle("Merge approved changes automatically", "When a change is proven, reviewed and its checks pass, the factory merges it if its risk level allows. Off: nothing merges on its own; ready changes wait in Pending merge.",
          f.autoMerges, (on) => set((x) => (x.autoMerges = on))),
        toggle("Fix merges automatically", "When an approved change won't merge, a builder brings the branch up to date and resolves the conflicts, twice at most, before asking you.",
          f.autoFixMerges, (on) => set((x) => (x.autoFixMerges = on)))),
      h("h2", {}, "By risk level"),
      h("div", { class: "card set-card risk-table" },
        h("div", { class: "risk-grid" },
          h("span", {}), LEVELS.map((l) => h("span", { class: `risk-head risk-${l}` }, l[0].toUpperCase() + l.slice(1))),
          h("span", { class: "set-label" }, "Plan approvals"), LEVELS.map((l) => num(`plan:${l}`, f.planApprovals[l], 0, 10, (v) => (f.planApprovals[l] = v))),
          h("span", { class: "set-label" }, "Final reviews"), LEVELS.map((l) => num(`review:${l}`, f.finalReviews[l], 0, 10, (v) => (f.finalReviews[l] = v))),
          h("span", { class: "set-label" }, "Auto-merge"), LEVELS.map((l) => h("label", { class: "risk-check" },
            h("input", { type: "checkbox", class: "switch", role: "switch", "aria-label": `Auto-merge ${l} risk`, checked: f.autoMerge[l], disabled: !f.autoMerges,
              onchange: (e) => set((x) => (x.autoMerge[l] = e.target.checked)) })))),
        !f.autoMerges && h("p", { class: "set-detail", style: "margin:8px 0 0" }, "Auto-merge is off for the whole factory, so these don't apply until it's back on.")),
      h("h2", {}, "PR budget"),
      h("div", { class: "card set-card" },
        field("Most files", "Over this, a change is at least medium risk and should be split.", num("maxFiles", f.maxFiles, 1, 10000, (v) => (f.maxFiles = v))),
        field("Most lines", "Added and removed, together.", num("maxLines", f.maxLines, 1, 1000000, (v) => (f.maxLines = v)))),
      h("h2", {}, "Task budget"),
      h("div", { class: "card set-card" },
        field("Agent time per task", "Minutes of agent work, all its sessions together, before it's asked to stop and raise a hand (5–1440; 0 is off).",
          num("taskMinutes", f.taskMinutes, 0, 1440, (v) => (f.taskMinutes = v))),
        field("Cost per task", "Dollars of agent work before it asks. Blank: no cost limit.",
          keep("policy:taskCostUsd", h("input", { type: "number", inputmode: "decimal", class: "set-num", min: 0, step: "0.01", placeholder: "No limit", value: f.taskCostUsd,
            oninput: (e) => set(() => (f.taskCostUsd = e.target.value === "" ? "" : e.target.valueAsNumber)) }))),
        h("p", { class: "set-detail", style: "margin:8px 0 0" }, "Past either, the agent is asked to stop and raise a hand; if it doesn't within 10 minutes, the factory raises one for it.")),
      h("h2", {}, "Risk checks"),
      h("p", { class: "muted" }, "A change's risk is the highest of: the planner's read, each check below it trips, and medium when it's over the PR budget. Path checks match the diff's files; the planner judges rules and cites the ones that apply."),
      h("div", { class: "card set-card" },
        f.checks.length ? f.checks.map((c, i) => riskCheckRow(f, c, i, set)) : h("p", { class: "muted", style: "margin:0" }, "No risk checks: only the planner's read and the size count."),
        h("div", { class: "row" },
          h("button", { type: "button", class: "btn small", onclick: () => set((x) => x.checks.push({ name: "", level: "medium", enabled: true, kind: "rule", paths: "", rule: "" })) }, "Add check"))),
      h("h2", {}, "Scout"),
      h("div", { class: "card set-card" },
        field("Items per Scout run", "The most leftovers one run turns into drafted plans (1–10).", num("scoutItems", f.scoutItems, 1, 10, (v) => (f.scoutItems = v))),
        problem && h("p", { class: "set-warn" }, problem),
        saveBar("policy", isDirty(d), () => go({ type: "policy.save", policy: policyFromForm(f, state.policy) }, { key: "policy", text: "Saved Merging & risk." }), () => { drafts.delete("policy"); render(); },
          { ready: isDirty(d) && !problem })),
    ];
  }

  function riskCheckRow(f, c, i, set) {
    const text = (key, attrs) => keep(`check:${i}:${key}`, h("input", { type: "text", value: c[key], spellcheck: "false", ...attrs, oninput: (e) => set(() => (c[key] = e.target.value)) }));
    return h("div", { class: "risk-check-row" },
      h("input", { type: "checkbox", class: "switch", role: "switch", "aria-label": `${c.name || "This check"} on`, checked: c.enabled, onchange: (e) => set(() => (c.enabled = e.target.checked)) }),
      h("div", { class: "risk-check-body" },
        h("div", { class: "row risk-check-head" },
          text("name", { placeholder: "Name", "aria-label": "Name", class: "risk-check-name" }),
          h("select", { "aria-label": "Level", onchange: (e) => set(() => (c.level = e.target.value)) },
            LEVELS.map((l) => h("option", { value: l, selected: l === c.level }, l[0].toUpperCase() + l.slice(1)))),
          h("select", { "aria-label": "Kind", onchange: (e) => set(() => (c.kind = e.target.value)) },
            h("option", { value: "paths", selected: c.kind === "paths" }, "Paths"),
            h("option", { value: "rule", selected: c.kind === "rule" }, "Rule")),
          h("button", { type: "button", class: "btn small danger-text", onclick: () => set((x) => x.checks.splice(i, 1)) }, "Remove")),
        c.kind === "rule"
          ? text("rule", { placeholder: "Changes the public HTTP API", "aria-label": "Rule" })
          : text("paths", { placeholder: "db/migrations/**, lib/auth/**", "aria-label": "Paths", class: "mono", autocapitalize: "off" })));
  }

  const BODIES = { general, repos, secrets, people, prompts, integrations, merging };

  function view(sub) {
    if (state.me?.role !== "admin") {
      return h("div", {}, h("h1", {}, "Settings"),
        h("div", { class: "card empty" }, "Only admins can change factory settings. Ask one of the factory's admins if something here needs to change."));
    }
    const key = BODIES[sub] ? sub : "general";
    const current = SECTIONS.find((s) => s.key === key);
    return h("div", { class: "settings" },
      h("nav", { class: "set-nav", "aria-label": "Settings sections" },
        SECTIONS.map((s) => h("a", { href: `#/settings/${s.key}`, class: s.key === key ? "on" : null, "aria-current": s.key === key ? "page" : null }, s.title)),
        h("p", { class: "set-mac muted" }, "Connectors and worktree scripts: in the Mac app.")),
      h("div", { class: "set-body" }, h("h1", {}, current.title), BODIES[key]()));
  }

  /** A message from the feed: an answer to something sent from here shows its toast. */
  function receive(m) {
    const answered = { "policy.updated": ["policy"], "prompts.updated": ["prompts"], "members.updated": ["members"], "repos.updated": ["repos", "owners"], "secrets.updated": ["secrets"],
      "integrations.updated": (m.integrations ?? []).map((i) => `integration:${i.kind}`) }[m.type];
    if (m.type === "error") {
      saving.clear();
      return;
    }
    for (const key of answered ?? []) {
      if (!saving.has(key)) continue;
      toast(saving.get(key));
      saving.delete(key);
      // A saved integration's secrets come back blank: start its form again from what's stored.
      if (key.startsWith("integration:")) drafts.delete(key);
    }
  }

  return { view, receive };
}
