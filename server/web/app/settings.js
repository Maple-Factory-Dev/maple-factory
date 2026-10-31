// The factory's settings on the web, for admins who don't run the Mac app: its name, repos, secrets,
// people, prompts, and merging and risk. It sends the same feed messages the Mac app does and reads
// the snapshot and their *.updated answers; the server checks every one is an admin's. Connectors and
// each repo's worktree scripts stay in the Mac app.
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
  };
}

/** The RiskPolicy to save from the form: numbers clamped to what the server takes (a budget of at least
 *  one file and line, approvals and reviews 0–10, Scout 1–10 items), anything blank or unreadable back to
 *  `base`'s, and what the form doesn't show (the sensitive areas) kept from `base`. */
export function policyFromForm(form, base) {
  const counts = (key) => Object.fromEntries(LEVELS.map((l) => [l, clampInt(form[key]?.[l], 0, 10, base[key]?.[l] ?? 1)]));
  return {
    ...base,
    maxFiles: clampInt(form.maxFiles, 1, 10_000, base.maxFiles),
    maxLines: clampInt(form.maxLines, 1, 1_000_000, base.maxLines),
    areas: base.areas,
    planApprovals: counts("planApprovals"),
    finalReviews: counts("finalReviews"),
    autoMerge: Object.fromEntries(LEVELS.map((l) => [l, !!form.autoMerge?.[l]])),
    autoFixMerges: !!form.autoFixMerges,
    autoMerges: !!form.autoMerges,
    scoutItems: clampInt(form.scoutItems, 1, 10, base.scoutItems ?? 3),
  };
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
export function createSettings({ state, h, send, toast, render }) {
  const drafts = new Map(); // form → { server, value }
  const saving = new Map(); // what's been sent → the toast for when its *.updated comes back
  const confirming = new Set(); // destructive buttons asking "Sure?"
  const secret = { repo: null, name: "", value: "" };
  let adding = "";
  let nameBusy = false;

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
  const toggle = (label, detail, on, flip) => h("label", { class: "set-row toggle-row" },
    h("span", { class: "set-label" }, h("span", {}, label), detail && h("span", { class: "set-detail" }, detail)),
    h("input", { type: "checkbox", class: "switch", role: "switch", checked: on, onchange: (e) => flip(e.target.checked) }));
  const saveBar = (key, dirty, onSave, onReset) => h("div", { class: "set-actions" },
    h("span", { class: "muted", style: "font-size:13px" }, saving.has(key) ? "Saving…" : dirty ? "Unsaved changes" : ""),
    h("span", { class: "spacer" }),
    dirty && h("button", { type: "button", class: "btn", onclick: onReset }, "Discard"),
    h("button", { type: "button", class: "btn primary", disabled: !dirty || saving.has(key), onclick: onSave }, "Save"));
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
      macOnly("The factory's icon"),
    ];
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

  function merging() {
    if (!state.policy) return h("div", { class: "card empty" }, "Loading…");
    const d = draft("policy", formFromPolicy(state.policy));
    const f = d.value;
    const set = (fn) => { fn(f); render(); };
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
      h("h2", {}, "Scout"),
      h("div", { class: "card set-card" },
        field("Items per Scout run", "The most leftovers one run turns into drafted plans (1–10).", num("scoutItems", f.scoutItems, 1, 10, (v) => (f.scoutItems = v))),
        saveBar("policy", isDirty(d), () => go({ type: "policy.save", policy: policyFromForm(f, state.policy) }, { key: "policy", text: "Saved Merging & risk." }), () => { drafts.delete("policy"); render(); })),
      macOnly("Sensitive areas"),
    ];
  }

  const BODIES = { general, repos, secrets, people, prompts, merging };

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
    const answered = { "policy.updated": ["policy"], "prompts.updated": ["prompts"], "members.updated": ["members"], "repos.updated": ["repos", "owners"], "secrets.updated": ["secrets"] }[m.type];
    if (m.type === "error") {
      saving.clear();
      return;
    }
    for (const key of answered ?? []) {
      if (!saving.has(key)) continue;
      toast(saving.get(key));
      saving.delete(key);
    }
  }

  return { view, receive };
}
