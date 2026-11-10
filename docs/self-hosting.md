# Self-hosting on celld

> **Experimental.** [celld](https://github.com/denoland/celld) is in beta (the factory is tested on 0.6.3),
> and so is this path. Known gaps today, from the MF-372 spike (`docs/celld-spike.md`):
>
> - **The web app doesn't load**: `/app/` 404s under celld's `auto-trailing-slash` (a celld bug). The Mac,
>   iPhone and Android apps and runners work, and `/setup` works.
> - Sentry may miss errors from requests that throw (the flush after a thrown handler is unreliable).
> - celld has no built-in TLS or compression; put a proxy in front (below).
>
> Cloudflare (`maple install` with no `--target`) is still the supported way to run a factory.

## How it fits together

```
             internet
                │  https
          ┌─────▼─────┐
          │   Caddy   │  TLS + compression; the only thing with published ports
          └──┬─────┬──┘
     :8080   │     │   :8080         public Worker listener (what Caddy proxies)
       ┌─────▼─┐ ┌─▼─────┐
       │celld-1│ │celld-2│ ◄─ :8081 ─►  internal listener: peers + unauthenticated operator routes
       └───┬───┘ └───┬───┘              (never published, never proxied)
           └────┬────┘
        ┌───────▼────────┐
        │  fleet bucket  │  deployments, D1, R2, Durable Object state, node leases
        └────────────────┘
```

- **Nodes** run `celld --bucket s3://NAME`. Each one serves the Worker on its public listener (`:8080`) and
  talks to its peers on the internal one (`:8081`). A node owns some Durable Objects, keeps their SQLite on
  local disk and replicates writes to its peers and the bucket. Run two or more: with one node every write
  waits for the bucket (`CELLD_DURABILITY=fleet` needs a follower).
- **The fleet bucket** holds everything durable: each deployment `celld deploy` writes (nodes pick up a new
  one in place, with no restart), the D1 database, the R2 bucket, Durable Object snapshots and node leases.
- **`maple install --target celld`** verifies maplefactory.dev's signed server release, writes a
  celld-compatible `wrangler.json`, runs `celld deploy` into the bucket and `celld d1 migrations apply`.
  `celld d1` goes through a running node, so the fleet must be up when you install.

## Bucket requirements

Any of these works as the fleet bucket:

| Store | `--bucket` | `--endpoint` |
| --- | --- | --- |
| AWS S3 | `s3://NAME` | (none) |
| Cloudflare R2 | `s3://NAME` | `https://ACCOUNT_ID.r2.cloudflarestorage.com` |
| Tigris | `s3://NAME` | `https://fly.storage.tigris.dev` |
| Google Cloud Storage | `gs://NAME` (Application Default Credentials) | (none; celld rejects it for gs://) |
| MinIO and other S3-compatible stores | `s3://NAME` | `http://HOST:9000` |

- It **must support conditional writes** (`If-None-Match: *` and `If-Match` on PUT): celld uses them for
  node leases and deployment pointers. S3, R2, Tigris and GCS do. For MinIO or anything else, use a release
  that does, and check with `celld diagnose --bucket s3://NAME --endpoint …`, which tests a conditional write.
- **Turn versioning on** (or object lock), so a bad write or a deleted object can be recovered (see Backups).
- `s3://NAME/PREFIX` puts the fleet under a prefix, so several fleets can share one bucket.
- Credentials come from the standard AWS chain (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
  `AWS_SESSION_TOKEN`, `AWS_REGION`, or an instance role). The installer passes them to celld and never
  saves them. Give the key read/write/delete on that bucket and nothing else.

## docker-compose

Two nodes and Caddy, on one host. Save it as `docker-compose.yml` beside a `.env` (below), then
`docker compose up -d`.

```yaml
# Maple Factory on celld (experimental): two nodes behind Caddy. docs/self-hosting.md
x-celld: &celld
  image: ghcr.io/denoland/celld:0.6.3
  restart: unless-stopped
  environment: &celld-env
    CELLD_BUCKET: ${CELLD_BUCKET}
    S3_ENDPOINT: ${S3_ENDPOINT:-}
    AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
    AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
    AWS_REGION: ${AWS_REGION:-us-east-1}
    CELLD_ADDR: 0.0.0.0:8080            # public listener: Caddy proxies this one
    CELLD_INTERNAL_ADDR: 0.0.0.0:8081   # peers and operator routes: no ports: mapping, ever
    CELLD_TRUST_FORWARDED_HEADERS: "1"  # Caddy sets X-Forwarded-Host/Proto
    CELLD_WATCH: /var/lib/celld
  networks: [fleet]
  # No `ports:` on the nodes: only Caddy is reachable from outside the fleet network.

services:
  celld-1:
    <<: *celld
    environment:
      <<: *celld-env
      CELLD_ADVERTISE: celld-1:8081
    volumes: [celld-1:/var/lib/celld]
  celld-2:
    <<: *celld
    environment:
      <<: *celld-env
      CELLD_ADVERTISE: celld-2:8081
    volumes: [celld-2:/var/lib/celld]

  caddy:
    image: caddy:2.10
    restart: unless-stopped
    ports: ["${HTTP_PORT:-80}:80", "${HTTPS_PORT:-443}:443"]
    environment:
      MAPLE_HOST: ${MAPLE_HOST}
    command:
      - sh
      - -c
      - |
        cat > /etc/caddy/Caddyfile <<'EOF'
        {$$MAPLE_HOST} {
          encode zstd gzip
          reverse_proxy celld-1:8080 celld-2:8080 {
            lb_policy round_robin
            fail_duration 10s
          }
        }
        EOF
        exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
    volumes: [caddy-data:/data]
    networks: [fleet]

  # celld's CLI on the fleet network, for `maple install` / `maple update` (CELLD="docker compose run --rm cli"):
  # `celld d1` reaches a node on its internal address, which only exists in here.
  cli:
    image: ghcr.io/denoland/celld:0.6.3
    profiles: [tools]
    environment: *celld-env
    volumes: ["${HOME}/.config/maple-factory:${HOME}/.config/maple-factory"]
    networks: [fleet]

networks:
  fleet: {}

volumes:
  celld-1: {}
  celld-2: {}
  caddy-data: {}
```

`.env` (keep it out of version control):

```sh
CELLD_BUCKET=s3://maple-fleet
S3_ENDPOINT=                      # blank for AWS S3; the R2/Tigris/MinIO endpoint otherwise
AWS_ACCESS_KEY_ID=…
AWS_SECRET_ACCESS_KEY=…
AWS_REGION=us-east-1
MAPLE_HOST=maple.acme.dev         # Caddy gets a certificate for it; point its DNS here first
```

Nodes log `no deployment yet` until the first `celld deploy`, then serve it.

### Tailscale Funnel instead of Caddy

With no public IP or open ports, Tailscale Funnel can terminate TLS on `https://NODE.TAILNET.ts.net`.
Replace the `caddy` service with this one (and use that address as `--url`). Funnel has no compression, and
it reaches one node; put Caddy behind it on `:80` if you want both nodes and compression.

```yaml
  tailscale:
    image: tailscale/tailscale:v1.90.6
    hostname: maple
    environment:
      TS_AUTHKEY: ${TS_AUTHKEY}        # a reusable auth key, tagged for Funnel in your ACLs
      TS_STATE_DIR: /var/lib/tailscale
      TS_SERVE_CONFIG: /config/serve.json
    volumes: [tailscale:/var/lib/tailscale, ./serve.json:/config/serve.json:ro]
    networks: [fleet]
```

`serve.json`:

```json
{
  "TCP": { "443": { "HTTPS": true } },
  "Web": { "${TS_CERT_DOMAIN}:443": { "Handlers": { "/": { "Proxy": "http://celld-1:8080" } } } },
  "AllowFunnel": { "${TS_CERT_DOMAIN}:443": true }
}
```

## Keep :8081 private

The internal listener carries peer traffic with no TLS, and its operator routes run work, evict and inspect
state and shut the node down **without authentication**. So:

- Never give it a `ports:` mapping and never proxy it. In the compose file only Caddy publishes ports; check
  from the host with `curl -m 3 http://localhost:8081/` (it should fail to connect).
- Nodes on several hosts need to reach each other's `:8081`: use a private network (a VPC, WireGuard or
  Tailscale), and firewall `:8081` (and `:8080`, which only the proxy needs) to the fleet's own addresses.
  celld refuses a public IP in `CELLD_ADVERTISE` unless you pass `CELLD_UNSAFE_PUBLIC_ADVERTISE=1`; don't.

## Install, set up, update

You need Node 20+, and the bucket credentials in the environment. `celld` itself comes from the compose
file's `cli` service (as below) or from `server/celld/install.sh` on a machine inside the fleet's network.
The installer checks it's celld 0.6.x.

```sh
docker compose up -d                                  # the fleet first: celld d1 needs a running node
export AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…    # same as .env
export CELLD="docker compose run --rm -T cli"         # run from the directory with docker-compose.yml
npx maple-factory install --target celld --bucket s3://maple-fleet [--endpoint URL] \
  --url https://maple.acme.dev --org acme [--allow octocat] [--channel beta]
```

It prints each step:

```
celld             0.6.3 ok
Release           maple-server 0.105.0 (stable) verified
Fleet bucket      s3://maple-fleet
Worker            maple-factory 0.105.0 deployed 3db95d9f8b48ce4f
Migrations        8 applied
```

A first install deploys first and then applies migrations, because nodes only take a lease (and `celld d1`
can only reach them) once the bucket has a deployment. Nobody can sign in before `/setup`, so it doesn't
matter that the server briefly runs on an empty database. Every update applies migrations first, then deploys.

Then open `https://maple.acme.dev/setup` as an owner of the GitHub org to make the factory's GitHub App, as on
Cloudflare. `/setup` keeps the App's keys and the session secret in D1, so there's nothing else to set.

`--dry-run --org acme --bucket s3://…` verifies the release, writes the config and runs `celld deploy
--dry-run`, without writing anything to the bucket.

What install set up is remembered in `~/.config/maple-factory/factories/<name>.json` (the target, bucket,
endpoint and URL; never credentials), so these just work:

```sh
npx maple-factory update     # newer release: migrations, then celld deploy; nodes adopt it in place
npx maple-factory status     # Factory  maple-factory in celld (bucket s3://maple-fleet)
```

## Backups

Everything the factory keeps is in the fleet bucket; the nodes' disks are caches.

- **Versioning or object lock** on the bucket is the first line: it covers deleted and overwritten objects.
- **A copy elsewhere**: sync the bucket to one in another account or region on a schedule, e.g.
  `rclone sync src:maple-fleet backup:maple-fleet-$(date +%F)` or S3/R2 bucket replication. Copy the whole
  prefix: deployments, leases and replication logs only make sense together.
- **A logical D1 dump**, small and easy to inspect, through a running node:
  `docker compose run --rm -T cli d1 execute maple-factory ~/.config/maple-factory/factories/maple-factory/wrangler.json --command "SELECT name FROM sqlite_master WHERE type='table'" --json`,
  then one `SELECT *` per table (or `.dump`-style with `sqlite3` on the JSON). celld 0.6.3 has no `d1 export`.

To restore: stop the nodes (`docker compose down`), copy the backup into an empty bucket (or roll the versioned
objects back), point `CELLD_BUCKET` at it, start the nodes and run `npx maple-factory update --force`, which
redeploys the release into it and checks the migrations.

## Environment

| Variable | Where | What |
| --- | --- | --- |
| `CELLD_BUCKET`, `S3_ENDPOINT`, `AWS_*` | nodes, `cli` | the fleet bucket and its credentials |
| `CELLD_ADDR`, `CELLD_INTERNAL_ADDR`, `CELLD_ADVERTISE` | nodes | public and internal listeners, and the address peers use |
| `CELLD_TRUST_FORWARDED_HEADERS=1` | nodes | only behind a proxy that sets X-Forwarded-Host/Proto |
| `AWS_*` | `maple` | bucket credentials for install/update; never saved |
| `CELLD` | `maple` | celld's command line (default `celld` on PATH) |

The Worker's own vars (`GITHUB_ORG`, `GITHUB_ALLOWED_LOGINS`, `RELEASE_CHANNEL`, `PUBLIC_URL`, `MAPLE_DEPLOY`)
are in the deployed config; change them with `maple update --allow …` or by reinstalling with `--force`.

## Trying it locally with MinIO

To try the whole path on one machine, add a MinIO bucket next to the fleet with this
`docker-compose.minio.yml`, and start everything with both files:

```yaml
services:
  minio:
    image: pgsty/minio:latest          # a maintained build of MinIO; it supports conditional writes
    command: server /data
    environment: { MINIO_ROOT_USER: maple, MINIO_ROOT_PASSWORD: maplemaple }
    ports: ["9000:9000"]
    networks: [fleet]
  # The CLI shares MinIO's network namespace, so http://localhost:9000 means the same bucket in here as on the host.
  cli:
    network_mode: service:minio
    networks: !reset []
```

```sh
cat > .env <<'EOF'
CELLD_BUCKET=s3://maple
S3_ENDPOINT=http://minio:9000
AWS_ACCESS_KEY_ID=maple
AWS_SECRET_ACCESS_KEY=maplemaple
MAPLE_HOST=:80
HTTP_PORT=8080
EOF
docker compose -f docker-compose.yml -f docker-compose.minio.yml up -d
docker compose -f docker-compose.yml -f docker-compose.minio.yml exec minio mkdir -p /data/maple   # the bucket
AWS_ACCESS_KEY_ID=maple AWS_SECRET_ACCESS_KEY=maplemaple \
CELLD="docker compose -f docker-compose.yml -f docker-compose.minio.yml run --rm -T cli" \
  npx maple-factory install --target celld --bucket s3://maple --endpoint http://localhost:9000 \
  --url http://localhost:8080 --org acme
curl localhost:8080/healthz
```
