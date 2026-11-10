# Planning docs

Shared, multiplayer planning and research documents, inspired by GitHub Next's
[Chopin](https://github.com/githubnext/chopin). This note is the one picture the follow-up tasks
(editor, comments, decisions, MCP) build on.

## Docs vs Scratchpad notes

| | Scratchpad `Note` | `Doc` |
|---|---|---|
| Who sees it | Its owner only | Every org member |
| Writers | One | Many, at the same time |
| Stored | OrgHub SQLite `notes` row (plain Markdown) | Index row in OrgHub; text as Yjs in its own `DocHub` |
| Belongs to | Nothing (until composed into a task) | A goal, or stands alone |

## Data model

- **OrgHub** keeps the doc index in its `docs` table: one `Doc` per doc (`id`, `title`, `goal?`,
  `createdBy`, `createdAt`, `updatedAt`, `archived?`, `icon?`). It's sent in the feed `snapshot`
  (`docs`) and kept current with `doc.updated` / `doc.removed`. Apps change it with `doc.create`,
  `doc.rename` and `doc.archive`. Unlike notes, every change is broadcast to every member.
- **DocHub** is a Durable Object per doc (`idFromName(docId)`), holding that doc's Yjs document in
  its own SQLite:
  - `updates(seq, at, by, data)`: every Yjs update as it arrives, appended.
  - `snapshot(id = 1, data, upto_seq)`: `Y.encodeStateAsUpdate` of everything up to `upto_seq`.
  - On load it applies the snapshot and then each later update. `compact()` folds the update rows
    into a new snapshot once there are more than 200 of them (or 1 MB), and from an alarm a few
    minutes after the first edit since the last compaction. A doc is capped at 20 MB in total; an
    edit that would go past that closes its socket.
  - When an edit lands it tells OrgHub (`POST /docs/<id>/touched`, at most every 30 s), which bumps
    `updatedAt` and broadcasts `doc.updated`.
- The document's content lives in the Y.Doc. The editor task picks the shared types (a
  `Y.XmlFragment` named `prosemirror` for TipTap); the server doesn't look inside.

## Why Yjs

- It's a CRDT: concurrent and offline edits merge without a central lock or operational transform
  on the server, so the DO only stores and relays bytes.
- `y-prosemirror` binds it to ProseMirror, and TipTap's Collaboration extensions sit on top of that,
  so the editor gets collaborative editing, cursors (awareness) and undo for free.
- Updates are small binary deltas and the state compacts into one snapshot, which fits a Durable
  Object's SQLite well.

## Wire format

`GET /docs/<id>/sync` upgrades to a WebSocket, authed exactly like `/client/connect` (the session
cookie or bearer token from `src/auth.ts`, same-origin check, signed-in and not revoked; org members
only). Unknown docs are 404; archived docs are refused. Archiving a doc closes its open sockets,
and revoking a member closes theirs on every doc (OrgHub POSTs DocHub's internal `/close`). Binary messages are the standard
`y-websocket` framing:

- `0` sync, from `y-protocols/sync`: step 1 (state vector), step 2 (missing updates), update. The
  server sends step 1 on connect and answers the client's step 1 with step 2.
- `1` awareness, from `y-protocols/awareness`: cursors and who's here, relayed to the other sockets
  and dropped when a socket closes. A socket speaks only for the client ids it claimed first (it
  can't rewrite someone else's cursor). States live in socket attachments so they survive
  hibernation, which keeps them small (a few clients, under 900 characters per socket).

So any `y-websocket`-compatible provider can talk to it.

## Reaching the Mac and iOS apps

The editor is a web editor (TipTap + y-prosemirror) served by the Worker with the web app. The Mac
and iOS apps show it in a `WKWebView` that carries the app's existing session token, so the
WebSocket is authed the same way as the feed; the native side only lists docs (from the feed) and
opens one. One editor, one sync path, no native CRDT.

## Editor (MF-361)

- **Source** lives in `server/docs-editor/` (TipTap 3: StarterKit, task lists, Mention, Collaboration,
  CollaborationCaret, BubbleMenu, `@tiptap/suggestion`; `y-websocket`; `prosemirror-markdown`). The shared type is
  the `Y.XmlFragment` named **`prosemirror`**.
- **Bundled and vendored**: `/app` is plain ES modules with no build step, and the installer deploys `server/web`
  as static assets into each org's Cloudflare account. So `scripts/build-docs-editor.mjs` (with esbuild pinned
  exactly) writes one checked-in ES module, `server/web/app/docs/editor.bundle.js`, plus `editor.css`. Rebuild with
  `npm run build:docs`. `npm run gen:check` fails when the bundle doesn't match the source, `server/web/app/markdown.js`
  or the lockfile. The doc page lazy-imports the bundle, so the rest of `/app` never downloads it.
- **Awareness user**: `{ login, name, color, avatar }`, where `color` comes from a hash of the login (so a person
  gets the same color everywhere).
- **Markdown mapping** (`src/markdown.js`, tests in `server/test/docs-markdown.test.ts`): headings, bullet, ordered
  and task lists (`- [ ]` / `- [x]`), quotes, fenced code with its language, links, bold/italic/code/strike. A
  member mention is the `mention` node and exports as `@login`. A known task id is the `taskRef` node, which links
  to `#/t/MF-12` and exports as `MF-12`; unknown ids stay text, resolved with `markdown.js`'s `taskResolver`.
  Pasted plain text that looks like Markdown goes through the parser.
- **Token auth for embeds**: a browser WebSocket can't set `Authorization`, so the embed sends
  `Sec-WebSocket-Protocol: maple-token, mft_…`. It's accepted only on an upgrade to `/docs/<id>/sync`, looked up
  like a bearer token (revoked or expired tokens get 401), and DocHub echoes `maple-token`.
- **Embed bridge** (`/app/docs/embed.html`, for a WKWebView; `frame-ancestors 'none'` means it isn't iframable):
  `window.mapleDocs.load({ docId, token, me, members, tasks })`, `setTheme('light'|'dark')`, `exportMarkdown()`,
  `focus()` (caret at the end of the doc), `destroy()`. Events `ready`, `status`, `peers`, `synced`, `theme`, `error`, `openTask` are posted to
  `window.webkit.messageHandlers.maple` if it exists, otherwise to `window.parent`, and logged as `[maple-docs]`.

## In the Mac app (MF-362)

- **Index:** `FeedState.docs` (and `FactoryClient.docs`) hold the snapshot's `docs`, kept current by `doc.updated`
  (upsert) and `doc.removed`. `activeDocs` drops archived ones, newest edit first. The sidebar's Docs page lists
  them by goal ("No goal" last); a goal's overview has a Docs section. Create, rename and archive send `doc.create`,
  `doc.rename` and `doc.archive`. There's no command to move a doc to another goal yet.
- **Native bridge:** `DocEditorView` hosts `<server>/app/docs/embed?theme=…` (the server redirects `embed.html` there, dropping the query) in a WKWebView with a `maple`
  message handler. On `ready` it calls `mapleDocs.load(args)` through `callAsyncJavaScript` with the token as a
  typed argument, so the token is never in a URL (each load and navigation is logged as `[docs] load|navigate <url>`).
  It calls `setTheme` when the app's appearance changes, opens `openTask` natively, shows `status`/`synced`/`peers`
  in a title bar, and shows `error` with a Retry. Navigation stays on the embed's origin; other links go to NSWorkspace.
- **New docs open ready to type (MF-382):** the editor's Placeholder extension marks an empty doc's paragraph
  `is-editor-empty` (the "Type / for blocks…" hint), and on the first `sync` an empty Yjs fragment gets one empty
  paragraph (`ensureStarterBlock`). `FactoryClient.createDoc` remembers the title; the `doc.updated` whose
  `createdBy` is me and whose title matches opens that doc (like the web's `pendingCreate`), and on its `synced`
  `DocEditorView` makes the WKWebView first responder and calls `mapleDocs.focus()`.
- **Demo mode:** `createDocEditor({ demo: { markdown } })` seeds the Y.Doc from Markdown (`seedFromMarkdown`), uses a
  local Awareness with no socket, and posts `synced`. `scripts/build-docs-editor.mjs` copies embed.html, the bundle
  and the CSS into `apps/mac/Sources/MapleFactory/Resources/DocsEmbed` (checked by `gen:check`). Signed out, the app
  serves that copy on `maple-docs://` and opens one demo doc ("Docs in Maple Factory"). embed.html loads its CSS
  relatively so the same file works from both places.
- **Links and ⌘K:** `maplefactory://doc/<id>` opens a doc; `-destination docs` and `-destination doc:<id>` open the
  page or a doc. ⌘K has "New doc", the Docs page, and a result for each doc.

## Deferred

- Android push for doc @mentions and decisions: the app has no Firebase client or project config yet, so it
  doesn't register a push token. Android still opens docs from `maplefactory://doc/<id>` links. Follow-up once there's a Firebase project.
- An MCP server so agents can read and edit docs.
- Search, history/versions browsing, and permissions finer than "org members".


## Comments (MF-364)

Select text (or a block) and choose **Comment** in the bubble menu to start a thread on it.

- **Where threads live.** OrgHub's `doc_threads` table, one JSON `DocThread` per row, not in the Yjs doc. So the doc's
  content and its Markdown export never carry comments. `Doc.openThreads` is worked out from that table on every read.
- **Anchors.** A `DocAnchor` is two Yjs relative positions (base64, opaque to the server) on the `prosemirror`
  fragment, plus the quoted text. Concurrent edits move the anchor with the text: typing before the range shifts it,
  typing inside grows it. When the range collapses (its text was deleted), `resolveAnchor` says `{orphan: true}` and the
  rail lists the thread under **On deleted text** (`server/docs-editor/src/comments.js`).
- **Wire.** `doc.comment {doc, thread?, text, anchor?}` starts a thread (an anchor is required then) or replies. A reply
  reopens a resolved thread. `doc.resolve` / `doc.reopen` flip it. `doc.threads {doc}` is answered with `doc.threads`
  to that connection only. Every change is broadcast as `doc.thread.updated`, plus `doc.updated` with the new count.
  Limits: 10k characters a comment, 500 threads a doc, and anchors of at most 2 KB.
- **@mentions** use `mentionsIn` (members only, never the author). Each mention is pushed with reason `mention` and ref
  `doc:<id>` through `Push.send`, so quiet hours and a relay that's off are handled the same way as task comments.
- **Editor.** Open threads' ranges are highlighted (the active one is stronger). The margin rail lines cards up with
  their anchors and has Open / Resolved filters, reply (with `@` completion), Resolve and Reopen. Hosts pass
  `threads()` and `sendThreadCommand(cmd)` to `createDocEditor` and call `handle.threadsChanged()`.
- **Embed (Mac).** `mapleDocs.updateThreads(threads)` feeds the threads in. The embed posts `command {command}` for the
  app to send on its socket and `threads {open}` for badges. The Mac app shows the open-thread count on doc rows, in
  the goal's Docs section, on the editor's title bar, and the total on the sidebar's Docs row.

## Planning visuals (MF-363)

Docs carry the blocks a plan needs, each a TipTap node in `server/docs-editor/src/nodes.js` with a Markdown
form that stays readable on GitHub and for agents reading an exported doc. Type `/` for the block menu.

| Block | In the editor | Markdown |
| --- | --- | --- |
| Diagram | Mermaid source beside a live preview (the offline renderer in `/app/mermaid`); click it for the zoom/pan/search viewer | a ` ```mermaid ` fence |
| Table | resizable columns, header row; the bubble menu adds and deletes rows and columns | a GFM pipe table, header row first (column widths aren't exported) |
| Chart | bar or line SVG of the nearest table above it: first column labels, every numeric column a series; no library, no network | a ` ```chart ` fence with `type: bar\|line` and `title:` lines |
| Image | pasted, dropped or picked png/jpeg/gif/webp, uploaded to R2 (`POST /api/attachments`); SVG is always a file | `![alt](/attachments/<id>/<name> "width=320")` |
| File | any other upload, as a chip | a paragraph that is only `[name](/attachments/<id>/<name> "mime · N bytes")` |
| Callout | note, tip, warning or important (click the label to change it) | `> [!NOTE]` / `[!TIP]` / `[!WARNING]` / `[!IMPORTANT]` |
| Toggle | a collapsible section with a heading | `> [!TOGGLE] heading`, then the quoted body |
| Divider | a rule | `---` |
| Task embed | a live card: id, title, state, PR and owner, redrawn as the feed changes (slash menu → pick a task) | `> [!TASK] MF-12 · title · state · PR #n · @owner` (only the id is read back) |

The host passes full tasks (`tasks()`: id, title, state, pr, assignee, goal) and calls
`handle.tasksChanged()` when the feed changes (the web app on `task.updated` and `snapshot`; app hosts
through `mapleDocs.updateTasks(tasks)`). Export snapshots each embed's current state.

Images load only from `/attachments/`: an image in pasted or imported Markdown that points anywhere else
(or sits inside other text) stays a plain link, so a doc never makes a viewer's browser fetch an outside URL.

Asking an agent from a doc is a side conversation in a thread (MF-366, below), not an embedded `/research`
block; a `> [!RESEARCH]` quote still imports as an ordinary quote.

## Doc tools for agents (MF-365)

Agent sessions (a task's planner, builder and reviewer, and personal sessions on a member's machine) get six
tools on the runner's `maple` MCP server, served by OrgHub's engine (`server/src/factory/doc-tools.ts`); the
runner checks their arguments first (`validate()` in `runner/src/mcp.rs`).

- `list_docs {q?, goal?, limit?}`: the org's docs that aren't archived.
- `read_doc {doc}`: the doc as Markdown, each top-level block preceded by `<!-- block b-<client>-<clock> -->`
  (the id of the Y.XmlElement item holding it, so it stays put until that block is deleted), then its open
  threads and suggestions and the block and text each sits on.
- `comment_on_doc {doc, text, block? | quote?}`: a thread on a quoted span (exact text, found once), a whole
  block, or (neither) the whole doc.
- `reply_to_doc_thread {doc, thread, text}`, `resolve_doc_thread {doc, thread}`.
- `suggest_doc_edit {doc, replacement, block? | quote?, note?}`: a DocThread with `suggestion` set
  (`{replacement, status: open|accepted|rejected, decidedBy, decidedAt}`). Agents never write doc text: only a
  person's **Accept** in the editor (`doc.suggestion {doc, thread, accept}`) changes it.

Docs are looked up only in this OrgHub's store, so only the org's own docs are reachable; archived docs,
threads of another doc, over 500 threads, replacements over 10,000 characters and anchored spans over 2,000
characters (an anchor keeps only that much of its quote) are refused. A reply on a decided suggestion leaves it
resolved. Agents' comments carry `agent` (e.g. "MF-365 builder"), shown as a badge.

DocHub converts headlessly with `server/docs-editor/src/headless.js` (y-tiptap's `initProseMirrorDoc`, the
editor's TipTap schema and Markdown serializer, no DOM) behind internal routes only OrgHub calls:
`POST /read`, `/anchor` (a quote or block → the same base64 Y.RelativePosition anchor comments.js makes) and
`/apply` (Accept: refuses when the anchored text no longer reads as the quote, otherwise replaces it via
`updateYFragment` on a copy first, so the update's own size counts against the doc cap; the update is persisted, sent to every open socket and touches OrgHub). A refused apply
comes back to the person as an error and the suggestion stays open.

In the web editor a suggestion's text is struck through in red, and its rail card ("Suggested edit by …")
shows the original and the rendered replacement with Accept / Reject; decided ones sit under Resolved as Accepted or
Rejected.

## Decisions (MF-367)

Decisions are kept out of the prose so they can be reviewed. Type `/decision` in a doc to add a decision card: the question, the options considered (2–10), the chosen option and the rationale. A decision is **proposed**, then a person **accepts** it (a chosen option is required) or **rejects** it, with an optional *Why?*. An accepted decision can be **superseded**: its Supersede button proposes a new decision with `supersedes` set, and when that one is accepted the old one becomes superseded (`supersededBy`), which is final. Proposed decisions can be edited; decided ones can't.

The server owns decisions, not the doc text. OrgHub keeps each decision's current state in a `decisions` table, and every change is appended to `decision_log`. SQLite triggers (`decision_log_no_update`, `decision_log_no_delete`) abort any UPDATE or DELETE, and `Store.recordDecision` is the only way to write to it, so history can't be quietly edited. The doc's Yjs text only holds a `decision` embed with the id; the card draws live from the feed (`decision.updated`, plus `decisions` in the snapshot), so editing the text can't change what was decided. Markdown export writes `> [!DECISION] <id> · question · status → chosen`.

- Client messages: `decision.propose`, `decision.edit` (only while proposed), `decision.accept`, `decision.reject` (members only, recorded as the member) and `decision.log` (the append-only log, to that connection).
- Agents get `propose_decision` with the other doc tools. It records a proposed decision with `agent` set and inserts the card after the given block or quote, or at the end (DocHub `POST /insert-decision`). No agent tool accepts or rejects; only people decide. `read_doc` lists a doc's decisions.
- Web: `#/decisions` lists every decision with Open / Accepted / Rejected / Superseded / All chips and Person and Goal filters. A row links to `#/docs/<doc>?decision=<id>`, which scrolls to and flashes the card, and History shows the log. The nav entry is badged with the open count.
- Apps: `FeedState.decisions`, `openDecisionTotal` and `openDecisionCount(goal:)`. The Mac sidebar has a Decisions row badged with open decisions and a native list, and a goal's Docs section shows its open-decision badge. The iPhone goal overview shows the count.

## Tasks from docs (MF-368)

A doc's plan can turn into factory work without copying it out. **Make tasks** opens from three places: the bubble menu over a selection, a hover button on any heading (that heading's section, up to the next heading of the same or a higher level), and an accepted decision's card. The dialog is prefilled from the editor's own Markdown serializer and split by `docs-editor/src/split.js`, the same code the server uses: one task, one per sub-heading, or one per list item. Titles and briefs can be edited, "Each waits on the one before" chains them with `after`, they can share an effort name (the heading by default), and a goal picker shows when the doc has no goal.

- Client message `doc.makeTasks {doc, anchor? | decision?, goal?, tasks: [{title, brief}] (1–20), chain, effort?}`. Web sends it on its socket; the Mac embed relays it as a `command`, like decisions.
- The engine checks everything before making anything (`checkSource` in `server/src/factory/doc-tasks.ts`). It refuses archived docs, a doc with no goal when none was picked, a goal that isn't the doc's, a decision that isn't accepted or belongs to another doc, an empty list or more than 20 tasks, and titles or briefs over the limit. It then reads the source in DocHub (`POST /section` → `sectionAt`) and makes drafts through `makeDrafts`, the same path `propose_tasks` and `submit_findings` use. Each draft gets `Task.fromDoc` (doc, title, heading, quote, decision, and the section's Markdown capped at 8k) and a closing line in its brief: `From doc [<title> › <heading>](#/docs/<id>?decision=<id>)`. Live task embeds go in right after the source (`POST /insert-tasks` → `insertTaskEmbeds`), skipping ids already in the doc.
- The planner's prompt gets a "## From doc" block: the excerpt, the selected text, and for a decision its question, chosen option, rationale and why, read live from the store. It also says `read_doc` shows the doc as it is now. Builder and reviewer get only the title and link line.
- The task page shows "From doc <title> › <heading>" (and "Decision: <question>") next to "Follow-up of". An accepted decision's card in the doc and its row on `#/decisions` list the tasks made from it, live from the feed, each with its state.

## Side conversations (MF-366)

Select text, choose **Ask an agent** in the bubble menu (or on a thread card), pick Planner or Researcher and
type the question. The editor sends `doc.ask {doc, thread?, anchor?, text, role?}`; OrgHub starts the thread
(or adds to it) and `Engine.ask` (`server/src/factory/engine.ts`, pure parts in `factory/doc-asks.ts`) opens an
interactive session:

- **Where:** the asker's own online, unpaused machines that have the agent and are under their usage caps,
  least busy first, then a machine a teammate lends. When none qualifies the asker gets the reason (paused,
  over cap, offline, no agent) and nothing is saved or opened. At most three live asks per member.
- **What it sees:** the doc as `read_doc` shows it, the selected quote and the thread so far; when the doc's
  goal has a repo, the session runs in an `ask-<8>` worktree of it (the runner's task checkout path, with
  `taskId` null), otherwise in the runner's home.
- **What it can do:** only the doc tools, as `<role> for @<asker>`: it answers with `reply_to_doc_thread` and
  proposes wording (or a mermaid diagram) with `suggest_doc_edit`, which a person accepts or rejects. Other
  factory tools are refused. It can read code and the web; the prompt tells it never to edit files.
- **Status:** `DocThread.agent` (`DocAgentRun`) follows the session: Starting → Thinking/Working (from
  `session.activity`) → Done when its turn ends (runner state `done`) after it replied or suggested an edit that
  turn, or Waiting ("its turn ended without a reply") when it didn't; Stopped, or Failed. A `done` within 10 s of
  a typed follow-up, before any work, is taken as the previous turn's and ignored. An answered ask stops counting
  toward the live limit and the budget, but its open session still counts toward the machine's load; it stays
  open for follow-ups for 15 minutes of quiet (`IDLE_GRACE_MS`), then the sweep closes it (a Waiting card turns Done). The card shows it as a chip that pulses while
  it runs, with Stop (`doc.agentStop`: the asker, the machine's owner or an admin).
- **Follow-ups:** a reply in a thread whose agent session is open (working, or answered and within its grace
  period) is typed into it (MachineHub `/input`) as "<who> in doc thread <id>: …", turning the chip back to
  Thinking. Otherwise only a comment that mentions `@planner` / `@researcher` (`docAgentsIn`, doc threads
  only) or the Ask action starts a fresh run with the transcript; a plain reply between people doesn't.
- **Budget:** each ask is held to the policy's per-task minutes and cost (`taskMinutes`, `taskCostUsd`); the
  alarm's sweep (`checkAskBudgets`) kills one past it and says so in the thread. Asks are kept in the OrgHub kv
  (`docask:<session>`).

## On iPhone and Android (MF-370)

Each goal has a **Docs** row on its overview (iPhone `GoalOverviewView`, Android `RootScreen`). It lists the goal's active docs, newest edit first, with open-thread and open-decision badges. A doc opens on three tabs:

- **Doc**: the factory's `/app/docs/embed` in a web view, driven by the same bridge as the Mac's `DocEditorView`. The page URL carries only `?theme=`. On `ready` the host calls `mapleDocs.load` with `docId`, `me`, `members`, `token`, `threads` and `decisions`, then pushes `updateThreads` and `updateDecisions` when they change. The editor rail's `command` events go to the socket. Task links open natively and other links open in the browser. A status strip shows connecting, synced or an error with Retry. Signed out (the demo), the bundled embed (copied by `scripts/build-docs-editor.mjs` to `apps/ios/Resources/DocsEmbed` and to the Android assets) runs in demo mode.
  - iPhone: a `WKWebView` (`DocWebView.swift`) with a `maple` message handler. The bundled copy is served on the `maple-docs` scheme, as on the Mac.
  - Android: a `WebView` with an `addJavascriptInterface` bridge called `MapleAndroid`. `embed.html`'s `post()` has a third branch, `window.MapleAndroid?.postMessage(JSON.stringify(msg))`, ahead of the `parent.postMessage` fallback. The host calls into the page with `evaluateJavascript`. Because that bridge reaches every page and frame, the host locks it down like the iOS policy: `shouldOverrideUrlLoading` keeps only the embed page in the view (task links open natively, other links go to the browser), bridge messages count only while the WebView is on the embed URL, `ready` is heard once per page load, and every later message must carry a nonce the host hands the main frame with `mapleDocs.load` (as `window.__mapleAndroidNonce`, which `post()` adds). `command` events pass the same type allowlist as iOS (`doc.comment/resolve/reopen/suggestion/ask/agentStop`, `decision.propose/edit/accept/reject`) and are decoded into wire messages, never relayed raw.
- **Comments**: native list of open threads (`doc.threads` when it appears), each with its quote, comments (agent badge), a reply field (`doc.comment` with `thread`) and Resolve (`doc.resolve`). "Show resolved" lists resolved threads with Reopen.
- **Decisions**: the doc's decisions, open first, with question, options and notes, rationale and why. While a decision is proposed: Accept (option picker, chosen preselected, optional why → `decision.accept`) and Reject (optional why → `decision.reject`).

**Push.** A proposed decision (a person's `decision.propose` or an agent's `propose_decision`, both through `DocTools.propose`) pushes reason `decision`, ref `doc:<docId>` (`decisions.pushTargets`, wired as the engine's `decisionPushes` hook in `org-hub.ts`). It goes to members @mentioned in the question, rationale or option notes, never the proposer. For an agent's proposal it also goes to `proposedBy` when that's a member: the person the agent works for. A task agent's proposal names its task, so only the mentions get one. The relay (`apps/site/push.js`) knows `decision` ("A decision needs you") and accepts `doc:<id>` refs. On iPhone a tapped `doc:<id>` push opens that doc: on Decisions for `decision`, on Comments for `mention`. `-pushRef doc:<id> -pushReason decision` does the same at launch. No banner shows while that doc is on screen. Android push waits on a Firebase project (see Deferred).

