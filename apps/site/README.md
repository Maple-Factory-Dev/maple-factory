# maplefactory.dev

The marketing site: static HTML, CSS and JS, no build step.

```sh
cd apps/site && python3 -m http.server 8790   # http://localhost:8790
```

A Worker with static assets: `npx wrangler deploy` from here (wrangler.jsonc). The files are served as
they are (`.assetsignore` keeps the Worker's own out); worker.js only runs for `/releases/`, the signed
release feed in the `maplefactory-releases` R2 bucket. `/deploy` (deploy.html) has people turn R2 on
before the Deploy to Cloudflare button, which can't provision the factory's bucket without it. `_headers` sets caching.

Type is [Atlas](https://afomera.dev/fonts) (SIL OFL, see `fonts/OFL.txt`): Serif for headlines, Sans for text,
Mono for labels. The fonts are the variable TTFs converted to WOFF2.
