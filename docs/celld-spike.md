# Spike: maple-server under `celld dev` (MF-372)

Follow-up to MF-371. **Result: server/ runs on celld with no product code changes.** A real runner enrolls
and streams a live session end to end. Two issues are in celld itself (nested `index.html`, and D1
migrations in dev), and one is minor (Sentry on the uncaught-throw path).

## Setup

- **celld 0.6.3** (latest, 2026-10-21), aarch64-apple-darwin, installed from the release asset:
  `gh release download v0.6.3 -R denoland/celld -p celld-aarch64-apple-darwin.gz && gunzip … && cp … ~/.local/bin/celld`.
  `gh attestation verify` returned 404 (no attestation published for this asset), even though the README says provenance is verifiable.
- esbuild has to be on PATH or in `CELLD_ESBUILD`. The repo's `node_modules/.bin/esbuild` (0.28.2, from wrangler) works.
- Run: `cd server/celld && cp -R ../web web && cp -R ../migrations migrations && CELLD_ESBUILD=../../node_modules/.bin/esbuild celld dev wrangler.jsonc --port 8788 --logs`
  (add `CELLD_IDLE_EVICT_S=5` for the hibernation check), then `curl -XPOST localhost:8788/__celld/migrate`.
- `server/celld/.dev.vars` (gitignored):
  ```
  DEV_LOGIN=celld-spike
  GITHUB_ORG=celld-spike
  PUBLIC_URL=http://localhost:8788
  SENTRY_DSN=http://publickey@127.0.0.1:9999/1   # a local catcher, so the spike never reports to the real project
  ```

### Throwaway config vs `server/wrangler.jsonc`

```diff
-  "main": "src/index.ts",
+  "main": "entry.ts",                       // re-exports ../src/index.ts + /__celld/* probe routes
-  "compatibility_flags": ["nodejs_als"],
+  "compatibility_flags": ["nodejs_als", "delete_all_deletes_alarm"],
-  "assets": { "directory": "./web", … }     // celld refuses symlinks and `..`: ./web is a copy
-  "dev": { "host": "localhost" },           // rejected by celld (unknown top-level key)
+  { "name": "ALARM_PROBE", "class_name": "AlarmProbe" } + migration v3   // spike-only alarm probe
-      "migrations_dir": "migrations"        // must be inside the project, no `..`: a copy
+  "rules": [{ "type": "Text", "globs": ["**/*.sql"] }]                  // entry.ts imports the migrations
-  "keep_vars": true                         // rejected by celld
```

`entry.ts` passes every request except `/__celld/*` to the real Worker (`withSentry`-wrapped) unchanged.

## Results

| # | Brief item | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | crypto.subtle RSASSA-PKCS1-v1_5 sign (`github.ts` `appJwt`) | **PASS** | `appJwt` from `src/github.ts`, run inside celld with a 2048-bit openssl key in both PKCS#1 and PKCS#8; `node:crypto.verify` → true for both |
| 2 | Hibernation WebSockets + `setWebSocketAutoResponse` + `serialize/deserializeAttachment` (`machine-hub.ts`) | **PASS** | Fake runner and a viewer on one MachineHub. ping→pong before idle and after it. The viewer's `ready` attachment, set by `session.replay`, survives hibernation, and output is routed after it. Log: `23:03:11 eviction_durability_barrier` (hibernated) → ping at about 23:03:16 answered **with no wake** → `23:03:26 reused local eviction snapshot epoch=2` on the next real frame |
| 3 | Alarms | **PASS** (spike DO only) | On the spike `AlarmProbe` DO: `setAlarm(+1s)` fires `alarm()` and `getAlarm()` is then null. Under `delete_all_deletes_alarm`, `deleteAll()` clears a pending alarm (`getAlarm()` → null). celld reports the flag as honored in `Cloudflare.compatibilityFlags`. Not exercised: the real DocHub compaction alarm (`doc-hub.ts:171`), OrgHub's alarm scheduling (`org-hub.ts:106`) and the DocHub WebSocket/Yjs path (see Gaps) |
| 4 | D1 migrations via `celld d1 migrations apply` | **PARTIAL** | `celld d1 …` only reaches a fleet bucket: `Error: celld d1 requires --bucket s3://NAME…`. celld dev's local store isn't reachable from operator commands (documented). All eight files (0001–0008) apply cleanly through D1 `batch()` from the spike route, and app reads and writes work (`/api/me`, `PUT /api/name`, enroll codes). State survives `celld dev` restarts |
| 5 | R2 RELEASES get/put | **PASS** | `RELEASES.put` through `/api/attachments` → 201; get through `/attachments/<id>/…` → same bytes; `/releases/` miss → 404. `celld r2` also needs a fleet bucket, so the `--local` release-script path isn't usable with dev |
| 6 | Static assets, `auto-trailing-slash` | **PARTIAL** (celld bug) | `/app` → 307 `/app/`, `/app/index.html` → 307 `/app/`, `/app/app.css` → 200, but **`/app/` → 404** (falls through to the Worker's "Not found."). Reproduced in a minimal asset-only project (`pub/app/index.html`; `/` works, `/app/` 404s). A `_redirects` 200 rewrite doesn't work around it |
| 7 | `@sentry/cloudflare` without `nodejs_als` | **PARTIAL** | The SDK loads. `withSentry` and `instrumentDurableObjectWithSentry` wrap and serve. `nodejs_als` is "accepted without effect", but `node:async_hooks` AsyncLocalStorage keeps its store across awaits anyway. `captureException` + `flush` delivered an envelope to the local catcher. `/debug/sentry-test` (uncaught throw → 500) delivered an envelope on the probe run but not on the first cold tries, so the `waitUntil` flush after a thrown handler looks unreliable |
| 8 | Runner enroll + live session | **PASS** | maple-runner 0.108.0 `enroll --url http://localhost:8788 --test` → `run` → `connected to ws://localhost:8788/runner/connect`. `e2e-local.mjs`: shell opened, typed command echoed through the relay, Kill → `cause=killed`, exit → `cause=exited code=3`, **PASS** |

### Differences from `wrangler dev` noticed

- `request.url` carries the port (`http://localhost:8788/…`), as in wrangler. `isLocal()` and DEV_LOGIN work unchanged, and PUBLIC_URL=http://localhost:8788 causes no redirects.
- `celld dev` watches the project and restarts on **any** file change in it, including probe scripts. Restarts drop open WebSockets. Hibernatable sockets survive hibernation, not a restart.
- D1's `sqlite_master` also lists celld's internal tables (`_cf_ALARM`, `_cf_KV`, `_litestream_*`…).
- `Content-Length` is stripped from Worker responses. No compression (needs a proxy in front).
- Writes on a single node wait for the bucket. That's fine for dev; production wants 2+ nodes (see MF-371).
- The runner's tmux socket path must stay under SUN_LEN (104 bytes on macOS). That's the runner's limit, not celld's, but a deep `$HOME` trips it.

## Gaps

- **DocHub and OrgHub weren't driven.** The plan called for a DocHub connect + Yjs edit + wait-for-compaction check and OrgHub alarm scheduling; the spike only checked alarms on its own `AlarmProbe` DO and hibernation on MachineHub. The alarm API they use is the same one that passed, so a failure there is unlikely, but it's unproven. If this spike is revisited: open a DocHub socket, send one Yjs update, wait past `COMPACT_AFTER_MS` and check the compaction landed; and hit OrgHub's `/dev/alarm` route (`org-hub.ts:353`) and check `getAlarm()`.

## Code changes server/ would need for celld

1. **`server/wrangler.jsonc:13` (`dev`) and `:48` (`keep_vars`)**: celld rejects unknown top-level keys. Keep a celld config next to the wrangler one (`maple install --celld` writes it), or strip the keys at deploy. No source change.
2. **`server/wrangler.jsonc:10`**: add `delete_all_deletes_alarm`, so any future `deleteAll()` on an alarm-using hub (DocHub's compaction alarm, `src/doc-hub.ts:171`; OrgHub, `src/org-hub.ts:106`) clears the alarm the same way on both platforms. Today the only `deleteAll()` is MachineHub's `forget` (`src/machine-hub.ts:71`), and MachineHub never sets an alarm, so this is consistency, not a live bug. It's harmless on Cloudflare, so it can go into the shared config.
3. **D1 migrations (`server/package.json` `dev`/`deploy` scripts)**: `celld d1 migrations apply maple --bucket …` works only against a fleet bucket. For local celld, either run dev against a local MinIO fleet node (`celld --bucket s3://… --endpoint http://localhost:9000`), or have the Worker apply `migrations/*.sql` itself on first request (bundled as Text, tracked in `d1_migrations`, as `server/celld/entry.ts` does). The second option also helps self-hosters who never run the CLI.
4. **`/app/` index (`src/index.ts:46`, the fetch handler)**: until celld fixes nested `index.html` under `auto-trailing-slash`, add an `assets.binding` (`ASSETS`) and serve `/app/` from the Worker by fetching `/app/index.html` through it. Check that the binding doesn't 307 the same way. Better: file the bug upstream with the minimal repro above; it's a celld defect by their own rule ("an unsupported feature that does not cause an error is a defect").
5. **Sentry on thrown requests (`src/index.ts:46` `withSentry` / `src/sentry.ts`)**: don't rely on the SDK's `waitUntil` flush after a handler throws. Catch at the top of `fetch`, `captureException`, `await Sentry.flush(2000)`, then return the 500. `nodejs_als` can stay; celld ignores it and ALS works without it.
6. **Release uploads (`scripts/feed.mjs:135`, `wrangler r2 object put --local` behind `release-runner.mjs --local`)**: celld dev has no local R2 CLI. Use `celld r2 put maple-releases KEY --bucket …` against a fleet, or the Worker's own upload routes.
7. **Assets dir and migrations must be real directories inside the project**: no symlinks, no `..`. `server/web` and `server/migrations` already are, so the celld config should sit in `server/`, not a subfolder. The spike config lives in `server/celld/` only to stay throwaway, which is why it copies them.

No change was needed for crypto (`github.ts`), the hubs' hibernation, auto-response or attachments, alarms, R2 bindings, or the runner protocol.
