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
    minutes after the last edit.
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
only). Unknown docs are 404; archived docs are refused. Binary messages are the standard
`y-websocket` framing:

- `0` sync, from `y-protocols/sync`: step 1 (state vector), step 2 (missing updates), update. The
  server sends step 1 on connect and answers the client's step 1 with step 2.
- `1` awareness, from `y-protocols/awareness`: cursors and who's here, relayed to the other sockets
  and dropped when a socket closes.

So any `y-websocket`-compatible provider can talk to it.

## Reaching the Mac and iOS apps

The editor is a web editor (TipTap + y-prosemirror) served by the Worker with the web app. The Mac
and iOS apps show it in a `WKWebView` that carries the app's existing session token, so the
WebSocket is authed the same way as the feed; the native side only lists docs (from the feed) and
opens one. One editor, one sync path, no native CRDT.

## Deferred

- The editor UI (web, and its WKWebView embedding).
- Comments and threads anchored in a doc.
- Decisions recorded from a doc, and turning parts of it into tasks.
- An MCP server so agents can read and edit docs.
- Search, history/versions browsing, and permissions finer than "org members".
