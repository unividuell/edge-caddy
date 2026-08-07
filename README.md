# edge-caddy — shared TLS edge for unividuell.org

The single Caddy that binds **80/443** on the host and reverse-proxies by hostname to
each project. It is the only process allowed on those ports. Every app runs as its own
stack and joins the external Docker network **`edge`**; the edge reaches each app by its
stable `container_name`. TLS terminates here — apps speak plain HTTP behind it.

Server dir: **`/opt/unividuell/edge-caddy/`**. Images are pulled from Docker Hub
(`caddy:2-alpine`, public — no ghcr login needed for the edge itself).

## Routes
| Domain | Upstream container |
| --- | --- |
| `countdown.unividuell.org` | `countdown-web:80` |
| `mobility.unividuell.org` | `mobility-manager:8080` |
| `news.zingler46.unividuell.org` | `comunio-news-app:8080` (basicauth) |
| `stats.unividuell.org` | *(static GoAccess report, basicauth)* |

## Bootstrap (first time)
```bash
mkdir -p /opt/unividuell/edge-caddy && cd /opt/unividuell/edge-caddy
curl -fsSL https://raw.githubusercontent.com/unividuell/edge-caddy/main/update.sh -o update.sh && chmod +x update.sh
./update.sh          # fetches compose.yaml + Caddyfile + a .env template, then stops
# edit .env: fill in credentials (see below)
./update.sh          # creates the edge network, pulls caddy, starts the edge
```

`.env` holds all credentials and is never committed. Copy `.env.example` and fill in:

| Variable | Meaning |
| --- | --- |
| `NEWS_AUTH_USER_1`, `NEWS_AUTH_USER_2` | the two `news.zingler46` users |
| `NEWS_AUTH_HASH` | bcrypt hash shared by both news users |
| `STATS_AUTH_USER_1`, `STATS_AUTH_HASH_1` | first dashboard user (required) |
| `STATS_AUTH_USER_2/3`, `STATS_AUTH_HASH_2/3` | further dashboard users (optional) |

```bash
docker run --rm caddy:2-alpine caddy hash-password --plaintext '<password>'
```

**Wrap every hash in single quotes.** Compose interpolates `$` in `.env` values and a
bcrypt hash contains three of them; unquoted *and* double-quoted both truncate it to
`$2a$14`. A Caddy hash is always exactly 60 characters — `update.sh` checks this and
aborts before deploying if it is wrong.

### Adding a dashboard user

Fill the next free slot in `.env` and run `./update.sh`. Slots 2 and 3 need no repo
change; unfilled slots fall back to a placeholder credential nobody can log in with.
A fourth user means adding a slot to the `stats` block in `Caddyfile` and to the edge
service's `environment:` in `compose.yaml`.

## Update (route/infra changes)
```bash
cd /opt/unividuell/edge-caddy && ./update.sh
```
Re-fetches `compose.yaml`, `Caddyfile`, `README.md`, and itself from `main`, ensures the
`edge` network, then `docker compose pull && up -d`.

## Add a new site
1. Add a site block to `Caddyfile`: `<domain> { reverse_proxy <container_name>:<port> }`.
2. Make sure the app's compose attaches that container to the external `edge` network with
   a stable `container_name` and **publishes no host ports**.
3. Commit, then on the server `./update.sh`. Caddy obtains the cert on first request.

## Monitoring

Every site writes one JSON access log, `logs/access.log`, with client IPs masked
(IPv4 `/24`, IPv6 `/48`) and `Cookie` / `Authorization` headers stripped. The
`edge-goaccess` container renders it into `report/index.html` every 5 minutes and
keeps cumulative aggregates in the `goaccess-db` volume, so history outlives log
rotation. The dashboard is at `https://stats.unividuell.org` behind basic auth.

It answers: which domain gets the traffic, which status codes, which user agents
and bots, which URLs, and average/max request duration per row.

It does **not** alert, and it has no latency percentiles — only average and max.
Unique visitors are keyed on masked IP + user agent + day, so treat them as a
trend, not a headcount.

Ad-hoc queries against the raw log, e.g. the top 10 user agents:

```bash
jq -r '.request.headers."User-Agent"[0]' logs/access.log | sort | uniq -c | sort -rn | head
```

## Certs
Caddy stores certs/ACME state in the `caddy-data` volume. A fresh volume triggers
Let's Encrypt issuance for every domain on first request — well within rate limits for
three domains. DNS for each domain must already point at this host and 80/443 must be open.
