# Versioning: keep semver, or number releases by year?

Decision note for MF-267. The question is whether to keep today's semver numbers or move to calendar-numbered
releases like `2026.50` ("the 50th release of 2026"). This note changes nothing: no script, version or tag is
touched here.

**Recommendation: keep semver for now.** At today's pace a per-year counter would be in the thousands within
months, the switch can never be undone, and the one thing calendar numbers would give users (how old is this?)
is already shown by release dates. Reasons and the conditions that would change this are in
[Recommendation](#recommendation).

## Current state

Three components ship on their own, each with its own semver number:

| Component | Version today | Stored in | Bumped by (loop-releases) | Tag pushed |
|---|---|---|---|---|
| maple-runner | 0.89.0 | `runner/Cargo.toml` (`version = "0.89.0"`), and `runner/Cargo.lock` via `cargo update -p maple-runner` | **minor** +1, with a `## <version> — <date>` section in `runner/CHANGELOG.md` | `runner-v<version>`, by `scripts/release-runner.mjs --to feed` |
| maple-server | 0.84.0 | `server/package.json` (and the root `package-lock.json`) | **minor** +1, `npm version <minor+1> --no-git-tag-version` | `server-v<version>`, by `scripts/release-server.mjs --to feed` |
| Maple Factory.app | 0.2.29 (build 100) | `apps/mac/version.json`: `{"version":"0.2.29","build":100}` | **patch** +1, `release.mjs new <patch+1>`, which also bumps the build number | `mac-v<version>`, by `apps/mac/scripts/release.mjs build` |

Runner and server bumps land as one commit, `Runner 0.X.0 and maple-server 0.Y.0: <what changed>`
(`.claude/skills/loop-releases/SKILL.md`, "Version bumps"). The tags are each release's base: the next round
diffs `runner/`, `server/` and `apps/mac/` against them (`RELEASING.md`, "Tags").

Where the numbers are compared:

- **The feed** (`scripts/feed.mjs`, `compareVersions`): splits on `.`, `+`, `-` and compares numerically; a
  prerelease sorts before its release. Used to decide whether `beta.json` moves.
- **The runner's self-update** (`runner/src/update.rs`, `should_update`): `force || latest > current` with
  `semver::Version` (semver 1.0.28). Updates only go forward unless `--force`.
- **Sparkle** (Mac): the appcast's `<sparkle:version>` is the integer **build number**, and
  `<sparkle:shortVersionString>` is the display version (`apps/mac/scripts/release.mjs`, the appcast writer).
  Sparkle compares the build, so the display version never decides whether an update is offered.
- **`maple-runner/changes.json`** (the Mac app's What's new for runners): newest first by insertion order,
  one entry per version, 50 at most (`scripts/release-runner.mjs`, `withRelease`). Nothing sorts it by
  version.
- **`/healthz`** (`server/src/index.ts`) reports `version: SERVER_VERSION`; loop-releases polls it until it
  *equals* the new version. A string match, not an ordering.

Pace, for scale: this repo started on 2026-10-25 with the runner at 0.23.0. It is now 0.89.0, with 69
`Runner 0.` release commits in six days (8 on 10-28, 28 on 10-29, 16 on 10-30, 17 on 10-31). The server has
83 `server-v` tags.

## Options

### (a) Stay on semver

`MAJOR.MINOR.PATCH`, as today: runner/server bump the minor on every release, the Mac app bumps the patch.

- **Tells users:** "newer than" and, in principle, "breaking or not". Under 1.0 every minor may break, which is
  honest for where the project is.
- **Breaking changes:** can be signalled: 1.0 and later majors mean something. Today the runner and server
  don't use the patch slot at all, so the signal is unused, but it is available.
- **Hotfixes:** a patch on the last release (0.89.1), which the feed and `should_update` already order
  correctly.
- **Changelogs / Mac update prompt:** "Maple Factory 0.2.29" and "Runner 0.89.0": short, but says nothing
  about age; the date is beside it in changes.json and the appcast.
- **Cost:** none. Every tool already expects it.

### (b) `YEAR.N.patch`, per component, N restarting each January

Runner `2026.1.0`, `2026.2.0`, …; server and Mac count on their own.

- **Tells users:** the year, and "the Nth runner release this year". Age at a glance.
- **Breaking changes:** no signal; the major is the year. Breaks would have to be called out in notes.
- **Hotfixes:** the patch slot, `2026.50.1`. Works in every comparer (checked below).
- **Changelogs / update prompt:** "Runner 2026.50.0" reads well *at 50*. At this repo's pace (10–25
  runner releases a day) N passes 50 in the first week of January and reaches the thousands by year end:
  "Runner 2026.3412.0" says no more than "0.3412.0".
- **Cost:** a next-version helper (year rollover), plus everything in [Risks](#risks).

### (c) One shared `YEAR.N` across runner, server and Mac

Every release round takes the next number, and whatever ships in it carries that number.

- **Tells users:** "runner 2026.50 and server 2026.50 went out together", which is useful for matching a
  factory with its runners and app.
- **Breaking changes:** no signal.
- **Hotfixes:** patch slot, but only on the component that needs it, so components still drift
  (`runner 2026.50.1`, `server 2026.50.0`).
- **Gaps:** a component that didn't change skips numbers (Mac jumps 2026.12 → 2026.31), which looks like
  missing releases. Or every component releases every round, which means Mac builds (notarize, DMG, minutes
  each) for no change.
- **Cost:** the most: one counter shared across three release scripts that today run independently, and the
  loop must reserve the number before any of them starts.

### (d) `YEAR.MONTH.patch`

`2026.11.0`, `2026.11.1`, … `2026.12.0`.

- **Tells users:** the month. Bounded numbers in the first two slots.
- **Must be `2026.1`, never `2026.01`:** semver rejects leading zeros (checked below), and so do npm and Cargo.
- **Breaking changes:** no signal.
- **Hotfixes vs. releases:** the patch slot has to carry *every* release in the month, so hundreds of patches a
  month (`2026.11.412`), and "patch" stops meaning hotfix.
- **Changelogs / update prompt:** "Maple Factory 2026.11.3" reads well for a component that ships a handful of
  times a month; it reads badly for the runner.

## Compatibility

All three comparers accept and order calendar numbers. Checked against the real code:

**The feed's `compareVersions`** (`scripts/feed.mjs`):

```
$ node -e 'import("./scripts/feed.mjs").then(({compareVersions:c})=>{for(const [a,b] of [["2026.1.0","0.89.0"],["2026.50.1","2026.50.0"],["2026.50.0","2026.9.0"],["2027.1.0","2026.50.3"],["2026.1.0-beta.1","2026.1.0"]])console.log(`compareVersions(${a}, ${b}) = ${c(a,b)}`)})'
compareVersions(2026.1.0, 0.89.0) = 1
compareVersions(2026.50.1, 2026.50.0) = 1
compareVersions(2026.50.0, 2026.9.0) = 1
compareVersions(2027.1.0, 2026.50.3) = 1
compareVersions(2026.1.0-beta.1, 2026.1.0) = -1
```

2026.1.0 sorts above 0.89.0, a hotfix above its release, 50 above 9 (numeric, not string), a new year above
the old one, and a beta below its release.

**The runner's `should_update`** (`runner/src/update.rs`, semver 1.0.28), from a throwaway test module
appended to `update.rs`, run with `cargo test --offline calver_check -- --nocapture` and then removed (not
committed):

```
should_update(0.89.0 -> 2026.1.0) = true
should_update(2026.50.0 -> 2026.50.1) = true
should_update(2026.9.0 -> 2026.50.0) = true
should_update(2026.50.3 -> 2027.1.0) = true
should_update(2026.1.0 -> 0.90.0) = false
Version::parse("2026.01.0") = Err(Error("invalid leading zero in minor version number"))
test result: ok. 1 passed; 0 failed
```

Installed 0.89.0 runners would update to 2026.1.0. Once on 2026.x, a 0.x release is never taken. Zero-padded
months don't parse.

**Sparkle / `CFBundleShortVersionString`** (Mac): Sparkle compares `<sparkle:version>`, the build number,
which keeps counting up whatever the display version is. `CFBundleShortVersionString` must be up to three
period-separated integers, which `2026.50.0` is. So the Mac app can switch display numbers at any time with no
update risk, as long as the build number keeps rising.

## Risks

What a switch could break, beyond the comparers above:

- **No way back.** Installs never downgrade (`should_update` is `latest > current`), so after one runner ships
  as 2026.1.0, a return to 0.x or 1.x strands every runner that took it. Going back would mean
  `2027.x`-or-higher forever, or `--force` on every machine.
- **Cargo and npm semver rules.** Both accept `2026.50.0`, but they read the first number as the major:
  every January is a "breaking" major, and `^2026.1.0` ranges stop at the year end. Nothing depends on
  `maple-runner` or `maple-server` as a library today, so this only matters for tooling that reads the
  version as semver (Dependabot-style "major bump" labels, `npm version minor`, which would bump the wrong slot).
- **loop-releases bumps.** The skill says "bump the minor" (runner, server) and "patch+1" (Mac). With (b)/(c)
  the bump becomes "N+1, or YEAR+1.1.0 in January", which needs a helper rather than a one-liner.
- **The `Runner 0.` fallback.** loop-releases finds pre-tag runner releases with
  `git log --grep='^Runner 0\.'`, and the bump commit is `Runner 0.X.0 and maple-server 0.Y.0: …`. Once
  tags exist for every release this fallback is only for old history, but the commit subject template and any
  greps written against it need updating.
- **changes.json ordering.** It is ordered by insertion, not version, so a switch doesn't reorder it. But it
  keeps 50 entries: at the current pace that is two or three days of runner releases, under any scheme.
- **`/healthz` polling.** An equality check on the version string, so any scheme works, provided the polled
  string is exactly what `server/package.json` says.
- **The installer and site.** A search of `installer/` and `apps/site/src` for `0.`-shaped version patterns
  found none, so nothing there assumes a 0.x number; they read versions from the feed.
- **Mac build numbers.** Must keep rising across the switch; `release.mjs new` already takes the max of
  `version.json` and every past release, so this holds.

## Recommendation

**Keep semver (option a).** Reasons:

1. **The pace makes per-year counters long.** The point of `2026.50` is a small, readable number. The runner
   ships 10–25 times a day; N would be in the hundreds by mid-January and the thousands by December. Option (d)
   moves the same problem into the patch slot.
2. **It can't be undone.** Every comparer accepts the switch, which is exactly why it's permanent:
   runners that update to 2026.x never come back down.
3. **Age is already visible.** changes.json carries `publishedAt`, the appcast and changelog sections carry
   dates. The Mac update prompt can show "released 31 Oct" without changing the number.
4. **Semver still has a job to do.** A 1.0 (runner, server, protocol stable) is a meaningful moment for
   factory owners; under calendar numbers there's no way to say "this one breaks".
5. **It costs nothing.** No helper, no skill edits, no tooling surprises.

Small improvements that get most of the readability, if wanted (each its own ticket):

- Show the release date beside the version on the Mac update prompt and in What's new.
- Use the patch slot for hotfixes (0.89.1) instead of always bumping the minor, so "patch" means "fix only".
- Plan a 1.0 for runner and server once the protocol settles.

**What would change this:**

- **The pace drops to a few releases a month** (a stable, public product). Then `YEAR.N` stays small and reads
  well; (b) for runner and server becomes attractive.
- **Factory owners need to match components.** If support keeps asking "which runner goes with which server",
  a shared number (c) earns its cost.
- **The Mac app alone.** Because Sparkle compares the build number, the Mac display version could move to
  `YEAR.MONTH.patch` (d) on its own with no update risk, if the app's cadence makes that read well.

### If we switch anyway: follow-up sketch (a proposal, not done here)

1. `scripts/next-version.mjs <component>`: reads the current version and today's date, prints the next
   `YEAR.N.0` (`YEAR+1.1.0` on the first release of a new year), refusing to go backwards. Unit-tested against
   `compareVersions`.
2. `.claude/skills/loop-releases/SKILL.md`: replace "bump the minor" / "patch+1" with the helper, and change
   the bump commit subject from `Runner 0.X.0 and maple-server 0.Y.0` to `Runner <v> and maple-server <v>`.
   Keep the `Runner 0.` grep for pre-tag history.
3. `RELEASING.md`: a "Version numbers" section: the scheme, that it can't go back, the zero-padding rule.
4. First release: the first runner/server round on or after the decision date, e.g. runner `2026.1.0`
   following `0.N.0`, announced in its changelog section ("version numbers now count releases this year").
   The Mac app on its next release, with the build number continuing as before.
