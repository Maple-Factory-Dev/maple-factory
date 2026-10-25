# maplefactory.dev

The marketing site: static HTML, CSS and JS, no build step.

```sh
cd apps/site && python3 -m http.server 8790   # http://localhost:8790
```

Cloudflare Pages: build command none, output directory `apps/site`. `_headers` sets caching.

Type is [Atlas](https://afomera.dev/fonts) (SIL OFL, see `fonts/OFL.txt`): Serif for headlines, Sans for text,
Mono for labels. The fonts are the variable TTFs converted to WOFF2.

The waitlist form posts to `/api/waitlist`, which doesn't exist yet (add a Pages Function).
