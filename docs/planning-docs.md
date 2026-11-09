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
  `destroy()`. Events `ready`, `status`, `peers`, `synced`, `theme`, `error`, `openTask` are posted to
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
- **Demo mode:** `createDocEditor({ demo: { markdown } })` seeds the Y.Doc from Markdown (`seedFromMarkdown`), uses a
  local Awareness with no socket, and posts `synced`. `scripts/build-docs-editor.mjs` copies embed.html, the bundle
  and the CSS into `apps/mac/Sources/MapleFactory/Resources/DocsEmbed` (checked by `gen:check`). Signed out, the app
  serves that copy on `maple-docs://` and opens one demo doc ("Docs in Maple Factory"). embed.html loads its CSS
  relatively so the same file works from both places.
- **Links and ⌘K:** `maplefactory://doc/<id>` opens a doc; `-destination docs` and `-destination doc:<id>` open the
  page or a doc. ⌘K has "New doc", the Docs page, and a result for each doc.

## Deferred

- Hosting the embed in the iOS app.
- Decisions recorded from a doc, and turning parts of it into tasks.
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

A `/research` block (ask an agent from inside a doc, answer embedded) was pulled out of MF-363 and left to
MF-366; until then a `> [!RESEARCH]` quote imports as an ordinary quote.
