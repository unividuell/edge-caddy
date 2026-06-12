# Shared edge convention

`unividuell/edge-caddy` owns the only host binding on **80/443**. Every other project is an
independent compose stack that:

- joins the **external** Docker network `edge` (`networks: { edge: { external: true } }`),
- exposes exactly **one** public-facing container with a stable `container_name`
  (`countdown-web`, `mobility-manager`, `comunio-news-app`),
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

Server layout: all projects live under `/opt/unividuell/<project>/`.
