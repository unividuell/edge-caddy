# Shared edge convention

`unividuell/edge-caddy` owns the only host binding on **80/443**. Every other project is an
independent compose stack that:

- is served under a **one-label** hostname, `<name>.unividuell.org` — never
  `<a>.<b>.unividuell.org`. The edge's `*` DNS record and its `*.unividuell.org` wildcard
  certificate cover exactly one label: such a name needs no Cloudflare record and no
  certificate of its own, and it never shows up in a Certificate Transparency log (which
  scanners read live). A two-label name would need both, and would be published.
- joins the **external** Docker network `edge` (`networks: { edge: { external: true } }`),
- exposes exactly **one** public-facing container with a stable `container_name`
  (`countdown-web`, `mobility-manager`),
- **publishes no host ports** (no `80/443`, no `8080`, no `6379`),
- keeps private services (db, redis) on its **own internal network**, not on `edge`.

The edge does `reverse_proxy <container_name>:<port>` — cross-project DNS works by container
name on the `edge` network. TLS terminates at the edge; apps serve plain HTTP behind it.

**Two-hop X-Forwarded for OAuth:** edge → app. The edge sets `X-Forwarded-Host/Proto`
(Host=`<domain>`, Proto=`https`). An app that itself proxies further (countdown: edge →
countdown-web → core) must pass those through so the innermost service builds correct
`https://<domain>/...` URLs (OAuth `redirect_uri`!). Caddy forwards `X-Forwarded-*` by
default; Spring needs `server.forward-headers-strategy=framework`.

**The `edge` network is created idempotently** by each project's `update.sh`
(`docker network create edge 2>/dev/null || true`) so any stack can come up independently.

**Caddyfile gotchas (current Caddy; the edge image is `caddy:2-alpine` plus the Cloudflare
DNS plugin, built from `caddy/Dockerfile`):**
- The directive is **`basic_auth`**, not the pre-2.8 `basicauth`.
- `{$ENV}` placeholders are resolved **at `caddy adapt` time**, not only at runtime — so
  `caddy adapt` of a `basic_auth` block with an empty hash *fails*.
- **Validate locally with the edge image, not plain `caddy:2-alpine`** — that one fails on
  the wildcard block with `module not registered: dns.providers.cloudflare`. Pass a
  real-looking hash, and a dummy token in token shape (35–50 of `A-Za-z0-9_-`): the plugin
  checks the shape on provisioning and refuses anything else.
  ```bash
  docker build -t edge-caddy:local caddy
  docker run --rm -i -e STATS_AUTH_USER=x -e 'STATS_AUTH_HASH=$2a$14$...' \
    -e CLOUDFLARE_API_TOKEN=dummydummydummydummydummydummydummydummy \
    edge-caddy:local caddy validate --adapter caddyfile --config /dev/stdin < Caddyfile
  ```

**Monitoring** (`edge-lgtm`, README "Metrics, logs and traces"): container logs are read from
docker's json-file logs, so a project only has to log to stdout — ECS JSON for Spring apps.
OTLP senders join the external network **`monitoring`** (not `edge`, so private services such
as core or postgres can report without becoming reachable from the edge) and set
`service.namespace` = project, `deployment.environment.name` = `production`/`staging`.

Server layout: all projects live under `/opt/unividuell/<project>/`.
