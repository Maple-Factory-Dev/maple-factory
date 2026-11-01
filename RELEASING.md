# Releasing

Every release script reads its credentials from the environment first and falls back to what works on a
release Mac today (a key file, a keychain profile, the login keychain, `apps/mac/.env.release`, `wrangler
login`). With the variables below set, each one runs unattended: nothing waits on a prompt or a browser.

| Script | Releases | Base it records |
|---|---|---|
| `scripts/release-runner.mjs --to feed` | maple-runner to the feed | `runner-v<version>` |
| `scripts/release-server.mjs --to feed` | the server bundle to the feed | `server-v<version>` |
| `apps/mac/scripts/release.mjs ship <v> --yes` | Maple Factory.app (DMG + appcast) | `mac-v<version>` |
| `scripts/release-site.mjs` | maplefactory.dev | `site-v<short sha>`, `site-deployed` |
| `scripts/ci/import-signing-cert.sh import` / `cleanup` | puts the Developer ID in a temp keychain, and removes it | |

## Where secrets live

In GitHub, every secret below lives in one GitHub Environment, **`release`**, with required reviewers, so a
release job only gets them once a person approves the run. The account IDs, bucket and signing identity
aren't secret and can be plain Environment variables. Nothing here is ever committed.

## Secrets

| Name | Read by | What it is (minimum scope) | Local fallback |
|---|---|---|---|
| `MAPLE_RELEASE_KEY_PEM` | release-runner, release-server (`scripts/feed.mjs`) | The Ed25519 release key's PKCS#8 PEM text (escaped `\n` newlines work too). Signs the feed's manifests; its public half is `RELEASE_PUBLIC_KEY` in `runner/src/update.rs` and `installer/maple.mjs`, checked before every release. | `MAPLE_RELEASE_KEY` (a path), then `~/.config/maple-factory/release-key.pem` |
| `CLOUDFLARE_API_TOKEN` | feed uploads (`wrangler r2 object put/get`), release-server's bundle, release-site | A Cloudflare API token: Workers R2 Storage Edit (both release buckets), Workers Scripts Edit and Workers KV Storage Edit (the site), Workers Routes Edit on the maplefactory.dev zone. | `wrangler login` |
| `CLOUDFLARE_ACCOUNT_ID` (variable) | same | The Cloudflare account. Required with the token: neither `wrangler.jsonc` names an account, and the scripts stop before any upload if the token is set without it. | `wrangler login` |
| `APPLE_CERT_P12` | `scripts/ci/import-signing-cert.sh` | Base64 of a `.p12` holding the "Developer ID Application" certificate and its private key. | the login keychain |
| `APPLE_CERT_PASSWORD` | same | The `.p12`'s export password. | |
| `SIGN_IDENTITY` (variable) | release-runner (feed), release.mjs | `Developer ID Application: Andrea Fomera (TU4485Z3KR)`. | release.mjs defaults to it |
| `NOTARY_KEY_ID` | release.mjs (`notarize`, `dmg`) | An App Store Connect API key's ID: Users and Access › Integrations › Team Keys, **Developer** role. Used when no `NOTARY_PROFILE` is set. | `NOTARY_PROFILE=screenie-notary` (a keychain profile) |
| `NOTARY_ISSUER_ID` | same | That team's issuer ID (same page). | |
| `NOTARY_KEY` | same | The key's `.p8` text (written to a 0600 temp file, removed on exit) or a path to it. | |
| `SPARKLE_PRIVATE_KEY` | release.mjs (`sign`) | The Sparkle EdDSA private key's text (`generate_keys -x`), written to a 0600 temp `SPARKLE_KEY_FILE`. Its public half is `SUPublicEDKey`, built in by `bundle.sh`. | `SPARKLE_KEY_FILE`, then the login keychain |
| `R2_ACCOUNT_ID` (variable) | release.mjs (`publish`) | The account of the updates bucket. | `.env.release` |
| `R2_BUCKET` (variable) | same | `maplefactory-updates`. | `.env.release` |
| `AWS_ACCESS_KEY_ID` | same | An R2 API token's access key: Object Read & Write on `maplefactory-updates` only. | `.env.release` |
| `AWS_SECRET_ACCESS_KEY` | same | Its secret. | `.env.release` |
| `SENTRY_AUTH_TOKEN` | release.mjs (`build`, `symbols`) | A Sentry auth token with `project:releases` and `project:write`, to upload dSYMs. `MAPLE_SKIP_SYMBOLS=1` ships without. | `.env.release` |

## Rotating

> **Don't rotate the release key or the Sparkle key casually.** Every installed runner and every installed
> Mac app trusts only the public half it was built with. A new key means a release with the new public
> half signed by the *old* key first, then waiting until clients have it; a lost or replaced key with no
> such bridge strands every install on its current version.

- **`MAPLE_RELEASE_KEY_PEM`**: only if it leaked. Make a new key (`node scripts/release-runner.mjs --new-key`
  with `MAPLE_RELEASE_KEY` pointing at a new path), put its public half in `runner/src/update.rs` and
  `installer/maple.mjs`, release a runner signed with the old key, then replace the secret with the new
  PEM (`cat new.pem`) and back the file up somewhere safe.
- **`SPARKLE_PRIVATE_KEY`**: only if it leaked. The same bridge: ship an app built with the new
  `SUPublicEDKey` signed by the old key, then swap the secret. The key is shared with Screenie, so
  rotating it is a Screenie change too.
- **`CLOUDFLARE_API_TOKEN`**: Cloudflare dashboard › My Profile › API Tokens › Roll (or create a new one
  with the scopes above), update the secret, delete the old token.
- **`APPLE_CERT_P12` / `APPLE_CERT_PASSWORD`**: when the certificate nears expiry (Developer ID certs last
  five years) or leaks. Create a Developer ID Application certificate at developer.apple.com, export it
  with its key from Keychain Access as `.p12` with a new password, `base64 -i cert.p12 | pbcopy`, update
  both secrets. Revoking the old one only if it leaked (revoking invalidates what it signed after the
  revocation date).
- **`NOTARY_KEY_ID` / `NOTARY_ISSUER_ID` / `NOTARY_KEY`**: App Store Connect › Integrations › Team Keys ›
  generate a new Developer key, download the `.p8` (once), update the three secrets, revoke the old key.
- **`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`**: Cloudflare › R2 › Manage API tokens › create a token
  with Object Read & Write on `maplefactory-updates`, update both, delete the old token.
- **`SENTRY_AUTH_TOKEN`**: Sentry › Settings › Auth Tokens › create one with the scopes above, update the
  secret, revoke the old one.

## Tags

Each release's base is a tag on origin, pushed by the script that released it, so the next release (on a
Mac or in CI) diffs against the same thing. `.claude/skills/loop-releases` reads them.

| Tag | Pushed by | Marks |
|---|---|---|
| `runner-v<version>` | `release-runner.mjs --to feed`, before building | the runner tree that release built (older releases: the `Runner 0.` commit) |
| `server-v<version>` | `release-server.mjs --to feed`, before building | the server tree; Deploy-button factories update from it |
| `mac-v<version>` | `release.mjs build` (not in a rehearsal with `MAPLE_RELEASES_DIR`, or with `--no-tag`) | the tree the app was built from; `symbols` rebuilds from it (older releases: local `mac-built-<version>`) |
| `site-v<short sha>` | `release-site.mjs`, after a deploy answers | every site deploy |
| `site-deployed` | same (the one tag pushed with `--force`) | the site that's live now |

## Rehearsing

- Feed: `--to dir:<scratch>/feed` writes a feed-shaped folder and tags nothing.
- Mac: `MAPLE_RELEASES_DIR=<scratch>/releases MAPLE_SITE_DIR=<scratch>/site` keeps the release out of the
  repo and skips the `mac-v` tag; `MAPLE_STOP_BEFORE_PUBLISH=1` makes `ship --yes` stop before publishing.
- Site: `node scripts/release-site.mjs --dry-run`.
