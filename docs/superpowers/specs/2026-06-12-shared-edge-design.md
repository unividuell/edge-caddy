# Shared Edge (Caddy) + Multi-Project Hosting

**Status:** Approved design (2026-06-12)
**New repo:** `github.com/unividuell/edge-caddy`
**Server:** single host `158.101.161.126` (linux/arm64), hosts several `unividuell.org` sites.

## Purpose

One host serves multiple sites (`mobility.unividuell.org`, `news.zingler46.unividuell.org`,
and now `countdown.unividuell.org`). Only one process can bind ports 80/443, so each
project cannot run its own edge. Introduce **one shared Caddy edge** (its own repo) that
terminates TLS and routes by hostname to each project, and make every project an
independent stack that plugs into a **shared Docker network** — replacing today's
organically-grown single `/opt/unividuell` compose that mixes the edge with comunio +
mobility + redis.

## Current state (discovered)

- One compose project **`unividuell`** at `/opt/unividuell` (source: `comunio-news/infrastructur/oci/`) runs:
  - `caddy` (`comunio-news-caddy`, binds 80/443, `/opt/unividuell/Caddyfile`, `unividuell_caddy-data/config` volumes),
  - `mobility-manager` (publishes 8080; SQLite at host `/opt/unividuell/mobility-manager/`),
  - `app` (comunio-news, **disabled** via `profiles: [disabled-as-broken]`) + `redis` (publishes 6379),
  - all on network `unividuell_app-network`.
- Edge Caddyfile routes `news.zingler46…`→`app:8080` (basicauth, `BASIC_AUTH_HASH`), `mobility…`→`mobility-manager:8080`; global block: LE email `unividuell@gmail.com`, file logging.

## Target architecture (Approach A)

```
                 Internet :80/:443
                        │
              ┌─────────▼──────────┐   unividuell/edge-caddy
              │   edge (Caddy)     │   TLS for all domains, host-based routing,
              │  binds 80/443      │   reverse_proxy by container name on the `edge` net
              └─┬────────┬───────┬─┘
   countdown.…  │  mobility.…    │  news.zingler46.…
                │            │   │
        ┌───────▼──┐  ┌──────▼─┐ │  ┌───────────────┐
        │countdown-│  │mobility│ │  │comunio-news-app│  (+ redis)
        │   web :80│  │ -mgr   │ │  └───────────────┘
        └────┬─────┘  │ :8080  │ │
   (internal│ net)    └────────┘ │
      core + postgres            │
```

- **Shared network `edge`** (a user-defined bridge, fixed name `edge`). The edge and every
  app attach to it. Cross-project DNS works by **container name** on this network, so each
  app's edge-facing container has a stable `container_name`.
- The **edge** only does TLS + host routing (`reverse_proxy <container_name>:<port>`) — a thin
  router, exactly like today's `reverse_proxy app:8080` pattern.
- Each **app** is its own repo/stack with its own internal network for its private services
  (e.g. countdown's `core`+`postgres`), and joins `edge` only with its public-facing container.
  No app publishes 80/443.

### The shared network

Created once and treated as **external** by every compose so any stack can come up
independently:
```bash
docker network create edge 2>/dev/null || true
```
Each compose declares:
```yaml
networks:
  edge:
    external: true
```
Each project's `update.sh` runs the idempotent `docker network create edge || true` before `up`.

## Server layout

All projects live under **`/opt/unividuell/<project>/`** — `/opt/unividuell` becomes the
parent directory of independent per-project stacks (no longer a single compose project):
- `/opt/unividuell/edge-caddy/`
- `/opt/unividuell/countdown/`   (moved from the temporary `/opt/countdown`)
- `/opt/unividuell/mobility-manager/`
- `/opt/unividuell/comunio-news/`

Today's root-level `/opt/unividuell/{docker-compose.yml,Caddyfile,.env}` (the mashed project)
are retired in favour of these subdirs. **Mobility's SQLite already lives at
`/opt/unividuell/mobility-manager/mobility-manager.db`** — preserve it: move it into
`/opt/unividuell/mobility-manager/data/` and mount `./data:/data` from the new project dir
(so the project's compose/.env don't sit inside the mounted data dir).

## Repos & changes

### NEW: `unividuell/edge-caddy`
Contents (the only thing on 80/443):
- `compose.yaml`: service `caddy` (image `caddy:2-alpine`), `container_name: edge-caddy`, ports `80:80`,`443:443`,`443:443/udp`, mounts `./Caddyfile`→`/etc/caddy/Caddyfile`, `./logs`→`/var/log/caddy`, `caddy-data`/`caddy-config` volumes, env `BASIC_AUTH_HASH`, on the external `edge` network.
- `Caddyfile`: the global block (email, logging) + one site block per domain, each `reverse_proxy <container_name>:<port>`:
  - `mobility.unividuell.org` → `mobility-manager:8080`
  - `news.zingler46.unividuell.org` → `comunio-news-app:8080` (with the basicauth block)
  - `countdown.unividuell.org` → `countdown-web:80`
- `.env.example` (`BASIC_AUTH_HASH=`), `update.sh` (curl infra + `docker network create edge || true` + `docker compose pull && up -d`), `README.md` (curl-bootstrap, add-a-site how-to).
- Server dir: `/opt/unividuell/edge-caddy/`.

### countdown (`unividuell/countdown`) — adapt
- Server dir: `/opt/unividuell/countdown/` (moved from the temporary `/opt/countdown`).
- `deploy/compose.prod.yaml`: `caddy` (countdown-web) service — **remove `ports: 80/443`**, add `container_name: countdown-web`, attach to **both** the external `edge` network (for the edge to reach it) and countdown's internal network (to reach `core`). `core`+`postgres`+`db-backup` stay internal (no change).
- `deploy/Caddyfile` (baked into `countdown-web`): change the site from `countdown.unividuell.org { … }` to **`:80 { … }`** (no domain ⇒ no own TLS; TLS is at the edge). Keep the two-`handle` routing (`@backend` → `core:8080`, catch-all → SPA). **Rebuild the `countdown-web` image** (CI).
- `core` still needs correct `redirect_uri`: the edge sets `X-Forwarded-*` (Host=countdown.unividuell.org, Proto=https); countdown-web's `reverse_proxy` must forward them to `core`. Configure countdown-web to trust the edge and pass through `X-Forwarded-*` (Caddy does by default; verify the two-hop chain yields `https://countdown.unividuell.org/...`). `core`'s `forward-headers-strategy=framework` stays.
- `deploy/update.sh`: add `docker network create edge || true` before `up`.

### mobility-manager (`unividuell/mobility-manager`) — adapt
- Add its own `deploy/compose.prod.yaml` (extracted from the shared compose): `mobility-manager` service (image `ghcr.io/unividuell/mobility-manager:latest`, `container_name: mobility-manager`, prod profile, `MOBILITY_MANAGER_*` env, healthcheck), on the external `edge` network, **no `8080` host publish**. Mount its SQLite data — **preserve the existing DB**: move the existing `mobility-manager.db` into `./data/` under the project dir and mount `./data:/data`. `.env.example`, `update.sh`, `README.md`.
- Server dir: `/opt/unividuell/mobility-manager/` (with the preserved SQLite file in `./data/`).

### comunio-news (`unividuell/comunio-news`) — adapt
- Extract `app` + `redis` into a self-contained `deploy/compose.prod.yaml` in the comunio repo: `app` (`container_name: comunio-news-app`, `SPRING_PROFILES_ACTIVE=oci`, its env, depends on redis) + `redis` (internal; drop the public 6379 publish unless needed externally), `app` on the external `edge` network, redis on comunio's internal network. The `disabled-as-broken` profile can stay until the app is fixed (the edge route is harmless while down). `.env.example`, `update.sh`, `README.md`.
- The edge keeps the `news.zingler46` site (basicauth) → `comunio-news-app:8080`.
- redis data: the current `unividuell_redis-data` is cache-like; starting a fresh `comunio-news_redis-data` is acceptable (the app is down anyway). Note it.
- Server dir: `/opt/unividuell/comunio-news/`.

### Restructure `/opt/unividuell` into per-project subdirs
`/opt/unividuell` is **kept as the parent directory**; only the old root-level mashed stack is
retired — i.e. `/opt/unividuell/{docker-compose.yml,Caddyfile,.env}` (sourced from
`comunio-news/infrastructur/oci/`) — once its services have been re-homed into the new
`/opt/unividuell/<project>/` subdirs (edge-caddy, countdown, mobility-manager, comunio-news).
Keep a copy/backup of the old root files (and the comunio repo's `infrastructur/oci`
`{docker-compose.yml,Caddyfile}`) before deleting.

## Server cutover (one careful step, brief mobility downtime)

Preconditions: DNS for all three domains already point here (mobility + news existing; countdown done). All app images are in ghcr (countdown built; mobility/comunio already published).

Sequence (run on the server, coordinated):
1. **Prep** each new project subdir under `/opt/unividuell/` (`/opt/unividuell/{edge-caddy,countdown,mobility-manager,comunio-news}/`) via each repo's `curl … update.sh`; fill each `.env`. These subdirs coexist with the old root-level `/opt/unividuell/{docker-compose.yml,Caddyfile,.env}` until step 6. **Note:** `/opt/unividuell/mobility-manager/` already exists (the old stack mounts the SQLite from there) — its `update.sh` lands the new compose/.env alongside; preserve the DB by moving `/opt/unividuell/mobility-manager/mobility-manager.db` into `/opt/unividuell/mobility-manager/data/`.
2. `docker network create edge`.
3. **Stop the old stack:** `cd /opt/unividuell && docker compose down` (uses the old root `docker-compose.yml`; frees 80/443; mobility goes down here — the downtime window starts).
4. **Bring up** the new stacks: edge-caddy, mobility-manager, countdown, comunio (each `cd /opt/unividuell/<project> && ./update.sh`). Edge obtains/【re-issues】 LE certs (new caddy-data volume) for all three domains.
5. **Verify:** `https://mobility.unividuell.org` and `https://countdown.unividuell.org` serve; `news.zingler46` routes (502 while comunio app disabled, as before). Test countdown login end-to-end.
6. **Cleanup:** once verified, archive/remove the old root-level `/opt/unividuell/{docker-compose.yml,Caddyfile,.env}` (and the now-migrated `/opt/unividuell/mobility-manager/mobility-manager.db` once confirmed running from `./data/`) and the edge/compose bits from the comunio repo's `infrastructur/oci`. `/opt/unividuell/` remains as the parent of the per-project subdirs.

**Rollback:** if the new edge fails, the old root files are still present — `cd /opt/unividuell && docker compose -f docker-compose.yml up -d` restores the old stack (keep them until verified). Certs: moving to a new caddy-data volume triggers Let's Encrypt re-issuance for 3 domains — well within rate limits; the old volume remains for rollback.

## Out of scope / follow-ups
- Per-app CI for mobility/comunio image builds already exist (their repos publish to ghcr); only their *deployment* (compose) moves into their repos.
- No auto-deploy (manual `update.sh` per project, as for countdown).
- Monitoring/log-aggregation of the edge beyond Caddy's file logs.
- Migrating the comunio redis volume contents (treated as disposable cache).

## Feed knowledge back
After implementation, capture the shared-edge convention (one edge on 80/443; apps join the external `edge` network with a stable `container_name`; apps don't bind 80/443; TLS at the edge; `X-Forwarded-*` two-hop for OAuth) into `.claude/guidelines/` of the edge-caddy repo (and a short cross-link note in countdown's `deployment.md`).
