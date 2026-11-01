---
name: loop-releases
description: Release whatever changed on origin/main (runner, maple-server, the Mac app, the maplefactory.dev site), update the afomera/maple-factory factory, and keep doing it every 10 minutes. Use when the user runs /loop-releases or asks to ship or check for releases.
---

# loop-releases

One round: fetch origin, work out which components changed since their last release, check them, and
release only those. Then report what went out.

## Arguments

- none: run a round now, then make sure a recurring job runs this every 10 minutes. Use CronList; if no
  job's prompt is `/loop-releases`, create one with CronCreate (`*/10 * * * *`, prompt `/loop-releases
  once`, recurring). Tell the user the job ID and that it expires after 7 days.
- `once`: one round, no scheduling. Cron ticks use this.
- an interval like `5m` or `30m`: as for none, at that cadence.
- `stop`: CronDelete the `/loop-releases` jobs and stop.

The user has authorized everything below for this loop: pushing to main, `release-runner.mjs` and
`release-server.mjs --to feed`, the Mac release stages, pushing to `afomera/maple-factory`, and deploying the
site. Anything outside it (npm publish of `installer/`, new infrastructure, force pushes) still needs a
yes first.

## Where each component's last release is

Compare trees, not commit messages: a commit can land while a build runs. Every base is a tag on origin,
set by the release scripts themselves, so a fresh checkout or CI finds the same bases (RELEASING.md).

| Component | Paths | Last released at |
|---|---|---|
| runner | `runner/` | the tag `runner-v<version in runner/Cargo.toml>` (pushed by release-runner.mjs `--to feed`); for a release from before those tags, the last commit whose subject starts `Runner 0.` (`git log -1 --format=%H --grep='^Runner 0\.'`) |
| server | `server/` | the tag `server-v<version in server/package.json>` (pushed by release-server.mjs) |
| mac | `apps/mac/` except `apps/mac/releases/` and `apps/mac/version.json` | the tag `mac-v<version in apps/mac/version.json>` (pushed by release.mjs `build`); for a release from before those tags, the old local tag `mac-built-<version>` |
| site | `apps/site/` | the tag `site-deployed` on origin (moved by release-site.mjs) |
| protocol | `protocol/` | not released on its own: a change there means the runner, server and Mac all changed |

`git diff --quiet <base> HEAD -- <paths>` says whether one changed. If a base is missing from origin and
has no fallback above, say so and ask before releasing that component instead of guessing.

`installer/` (the `maple-factory` npm package) is not released by this loop. If it changed, say so in the
report.

## The round

1. `git fetch -q --tags --force origin` (`--force` so a moved `site-deployed` comes along). If `HEAD..origin/main` is empty and the working tree has no leftovers from a
   release, say "nothing new" and stop.
2. **Never fast-forward while a Mac build stage is running** in the background: it builds from the
   working tree. Wait for its build stage to finish (later stages only package the built app). Then
   `git merge --ff-only origin/main`. (`git pull --ff-only origin main` fails here with "multiple
   branches".)
3. Work out what changed (table above). Read the diff of each, and for anything on the wire check that
   older clients survive it:
   - new enum values: the runner's enums need `#[serde(other)]`, Swift's need an `.other`/`.unknown` case.
   - new server→app message types: the Mac app's `Wire.ServerToClient` decodes unknown types as
     `.unknown`. Anything that throws a `DecodingError` sends an older app to `tooNew()`.
   - new fields: optional, with an unset value meaning the old behaviour.
   - new routes: `/dev/*` only with `env.DEV_LOGIN` and a local request. Check production refuses them.
   - storage: new tables are created if absent, backfills are guarded.
   If an older client would break, don't release; report it, so a fix can be made.
4. Checks. Skip a component whose checks fail, and report why with the output.
   - protocol: `node protocol/gen.ts` leaves `git diff` empty.
   - runner: `cargo test -q` in `runner/`.
   - server: `npx tsc --noEmit`, `node --check` on every `server/web/app/*.js` (a syntax error there
     broke the web app once while tsc passed), and `npm test` in `server/`.
   - mac: `swift build` and `swift test` in `apps/mac`.
   - site: `node --check apps/site/worker.js main.js`.
5. Release, in this order: version bumps, then server, runner, factory, Mac, and site last.

### Version bumps (runner and server together)

- Runner: bump the minor in `runner/Cargo.toml` with Python, not sed (BSD sed has no `0,/re/`):
  `re.sub(r'^version = "X"', 'version = "Y"', s, count=1, flags=re.M)`, then
  `cargo update -q -p maple-runner --offline` in `runner/`. Add a `## <version> — <YYYY-MM-DD>` section at the
  top of `runner/CHANGELOG.md` with one plain sentence on what changed. The release script reads its notes
  from there and publishes them to `maple-runner/changes.json`, the app's What's new for runners.
- Server: `npm version <minor+1> --no-git-tag-version` in `server/` (it also updates the root
  `package-lock.json`).
- One commit, `Runner 0.X.0 and maple-server 0.Y.0: <what changed>`, or just the one that changed.
- Push with retries: `for i in 1 2 3; do git fetch -q origin && git rebase -q origin/main && git push -q
  origin main && break; git rebase --abort 2>/dev/null; done`. If the rebase pulls in commits nobody
  checked, or conflicts (often `package-lock.json`), drop the bump commit (`git reset --hard
  origin/main`), go back to step 3 with the new commits, and bump again.

### Server

1. `node scripts/release-server.mjs --to feed`. Confirm `git ls-remote --tags origin server-v<v>`.
2. Update the factory:
   ```
   C=<scratchpad>/afomera-copy; rm -rf $C && gh repo clone afomera/maple-factory $C -- -q && cd $C
   node <repo>/server/scripts/update.mjs --into $C --from <repo>/server --version <v>
   git diff --quiet wrangler.jsonc        # the factory's own config must not change
   npm ci && npx tsc --noEmit && for f in web/app/*.js; do node --check $f; done; rm -rf node_modules
   git add -A && git commit -m "Update Maple Factory to maple-server <v>: <what changed>" && git push
   ```
   Workers Builds deploys the push.
3. Poll `https://factory.afomera.dev/healthz` (every 15s, up to 10 minutes) until `version` is the new
   one. Then fetch the live `/app/app.js` (and any other changed `web/app/*.js`) and `node --check` it.

### Runner

In the background, so the server and factory can go meanwhile:
`SIGN_IDENTITY="Developer ID Application: Andrea Fomera (TU4485Z3KR)" node scripts/release-runner.mjs --to feed`
(no `--notes`: the CHANGELOG section is the notes). It ends with `Released maple-runner <v> for … (latest.json,
beta.json, changes.json).` and takes several minutes (Linux targets build in Docker). The three targets build
in parallel: the log shows `▸ <target> started` for each, a heartbeat every 30s, then `✓ <target> built in …`
lines. Each build's own output is in `runner/target/release-logs/<target>.log`; a failed build prints the end of
its log and nothing is published. Re-run with `--serial` (one target at a time) only if Docker runs out of memory.

### Mac app

The app bundles the runner, so its build waits for a runner release in progress.

1. `node apps/mac/scripts/release.mjs new <patch+1>` (bumps `version.json` and its build number).
2. Write `apps/mac/releases/<v>/notes.md`. Keep the frontmatter `new` wrote and replace the body with
   `### Added` / `### Changed` / `### Fixed` bullets from the commits since the last release's tag
   (`mac-v<previous>`). Write them for the people using the app: what they can do now, with the UI's own
   names in bold.
3. `node apps/mac/scripts/release.mjs ship <v> --yes` in the background, after the runner's
   `Released maple-runner` line if one is running. `--yes` answers both confirmations (without it, `ship`
   fails at once when stdin isn't a terminal). Its build stage tags `mac-v<v>` at HEAD and pushes it: no
   tag step by hand. A stage that fails late can be run again on its own (`notarize`, `dmg`, `sign`,
   `appcast`, `publish`).
4. Check the log shows `✓ <v> is live` and that
   `curl -s "https://updates.maplefactory.dev/appcast.xml?x=$RANDOM"` lists `<v>` first. Only then
   commit `apps/mac/releases/<v>` (with `release.json`) and `apps/mac/version.json` as
   `Mac app <v> released: <what changed>`, and push with retries.
5. Commits that landed during the build aren't in it: next round releases them.

### Site

If `apps/site/` changed since `site-deployed`, CI normally has it already: every push to main touching
`apps/site/**` starts `.github/workflows/deploy-site.yml`, which runs the same script.
1. `gh run list -w deploy-site.yml -L 5 --json headSha,status,conclusion,url` and look for a run on
   origin/main's sha (or a later one). Queued, waiting for approval in `release`, or in progress: leave it,
   report it as waiting, and check again next round. Succeeded: done (`site-deployed` has moved).
2. Only when there's no run for it, or the run failed, deploy from here: `node scripts/release-site.mjs`.
   It deploys with `npx --no-install wrangler deploy` (wrangler comes from the root workspace's
   node_modules), checks `/`, every page changed since `site-deployed` (200) and `/download/mac` (302 to a
   `.dmg`), then tags `site-v<short sha>`, moves `site-deployed`, and pushes both.

## Report

What was released this round, as a short table (component, version, where it is now), plus anything
skipped and why, anything waiting on a background build, and any older-client check you made. If nothing
changed, one line.

## Gotchas

- zsh: `$ref:server` triggers modifiers, so write `${ref}`. There's no `timeout`, and a foreground `sleep`
  is blocked. Wait on background work with an `until grep -q …; do sleep 10; done` command run in the
  background.
- Never commit `~/.config/maple-factory/release-key.pem` or `apps/mac/.env.release`.
- Don't commit release files before checking that the publish succeeded.
