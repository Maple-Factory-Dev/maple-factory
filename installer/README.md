# maple-factory

Sets up and updates a [Maple Factory](https://maplefactory.dev) in your own Cloudflare account.

```sh
npx maple-factory install            # or: npm i -g maple-factory && maple install
```

It asks for a Cloudflare API token (`maple token` prints a link that makes one with the right
permissions: Workers Scripts, D1, R2 and Workers Routes edit, Zone and Account Settings read), your GitHub
organization (or your own username, for a factory of your own) and, optionally, a custom domain. `--allow
octocat,hubot` lets other GitHub logins sign in too. Then it:

1. fetches the latest server release from maplefactory.dev and checks it's signed with Maple Factory's
   release key and matches its sha256;
2. creates the R2 bucket (if R2 isn't switched on in the account, it links you to the dashboard and
   waits), then the D1 database, applies its migrations and deploys the Worker;
3. opens `https://<factory>/setup`, where an owner of the org (or you, for your own account) creates the factory's GitHub App.

```sh
maple update [--channel beta]        # the next release; migrations first, then the Worker
maple update --allow octocat,hubot   # who else may sign in, besides the org's members (or you); '' for nobody
maple status
maple install --dry-run --org acme   # verify and build the deploy without touching Cloudflare
```

What it made (account, database, domain, version) is remembered in `~/.config/maple-factory/factories/`;
the token never is. `CLOUDFLARE_API_TOKEN` skips the prompt.
