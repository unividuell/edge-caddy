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
| `beta.countdown.unividuell.org` | `countdown-staging-web:80` |
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
bcrypt hash contains three of them; unquoted *and* double-quoted both eat the `$…`
sequences, leaving `$2a$14` plus the tail after the last one — around 38 characters,
varying with the salt. Caddy accepts such a hash without complaint and simply never
matches a password, so the failure is a silent lockout, not an error. A Caddy hash is
always exactly 60 characters, so `update.sh` requires this exact shape and aborts
before deploying otherwise:

```
NEWS_AUTH_HASH='$2a$14$.....................................................'
```

### Adding a dashboard user

Two steps, both required:

1. Fill the next free slot in `.env` (`STATS_AUTH_USER_2` / `STATS_AUTH_HASH_2`).
2. Add the matching two lines to the edge service's `environment:` in `compose.yaml` —
   `{$VAR}` in the `Caddyfile` reads the *container's* environment, so a variable that
   is only in `.env` never reaches Caddy.

Then `./update.sh`. The `Caddyfile` already declares slots 2 and 3; a slot whose
variables are unset drops out of the config, so only the slots you wire up exist.
A fourth user additionally needs a slot in the `stats` block in `Caddyfile`.

## Update (route/infra changes)
```bash
cd /opt/unividuell/edge-caddy && ./update.sh
```
Re-fetches `compose.yaml`, `Caddyfile`, `README.md`, and itself from `main`, then:

1. **`.env` preflight** — every required variable present and non-empty, and every hash
   in the single-quoted 60-character form. Aborts with an explanatory message otherwise,
   before anything is touched.
2. Ensures the `edge` network and runs `docker compose pull`.
3. **Validation gate** — `caddy validate` against the real `Caddyfile` with the real
   `.env`, in a throwaway container that publishes no ports. Aborts if the config would
   not start, leaving the running edge untouched.
4. `docker compose up -d`, then `caddy reload` — `up -d` does not recreate the container
   for a `Caddyfile`-only change, so the reload is what picks up new sites and routes.

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

After a first deploy `stats.unividuell.org` returns **404 for up to five minutes** —
`report/index.html` does not exist until GoAccess completes its first pass.

It answers: which domain gets the traffic, which status codes, which user agents
and bots, which URLs, and average/max request duration per row.

It does **not** alert, and it has no latency percentiles — only average and max.
Unique visitors are keyed on masked IP + user agent + day, so treat them as a
trend, not a headcount.

### Geo data

**Enabling this for the first time needs two `./update.sh` runs.** `update.sh` replaces
itself with `mv`, which is a rename — the shell already running it keeps its file descriptor
on the *old* inode and finishes executing the old script. So the first `./update.sh` after
this feature lands fetches the new `compose.yaml` (goaccess starts passing
`--html-custom-js=attribution.js`) but does **not** fetch `report/attribution.js` itself,
because that fetch only exists in the *new* `update.sh`. Until a second `./update.sh` runs,
the report links to a file that 404s and the CC-BY attribution is missing. The one-time
migration below doubles as that second run.

The dashboard resolves the **country** of each request — not the city, and not the
provider. The `edge-geoip` container keeps a DB-IP Country Lite database in the
`geoip-data` volume, checking daily and downloading a new one each month. GoAccess
picks up a replaced database on its next 5-minute pass, with no restart.

The database is licensed **CC-BY 4.0**, which requires the *IP Geolocation by DB-IP*
link that `report/attribution.js` adds to the bottom of the report. Do not remove it.

Client IPs are masked (`/24` IPv4, `/48` IPv6) before they are ever written, so a country
is the most this can resolve — which is also why no city database is installed. VPN and
cloud traffic resolves to the exit node, so a scanner in `eu-central-1` counts as Germany.

`docker restart edge-geoip` only resumes the loop — useful if it is stuck in the hourly
retry after a failed download, since restarting re-enters the loop immediately instead of
waiting out the `sleep 3600`. It does **not** force a re-download: with a current `.stamp`,
the loop's very first check on restart (`[ -f "$DB" ] && [ stamp = month ]`) is already true,
so it just sleeps another 24 h without touching the network.

To actually force a fresh download — e.g. to pick up a corrected release — delete the stamp
first, so the loop's guard fails and it re-fetches:

```bash
docker exec edge-geoip rm -f /geoip/.stamp && docker restart edge-geoip
```

Then check the result:

```bash
docker logs --tail 20 edge-geoip
```

Give it a few seconds before trusting this — right after a restart it can still show the
*previous* run's `geoip: installed YYYY-MM` line, which reads as success but predates the new
attempt. A failed download leaves the previous database in place and retries hourly, and
nothing alerts.

**One-time migration when enabling geo.** GoAccess resolves countries at parse time, so
records already aggregated in `goaccess-db` never gain one. Run this **once**, and never
from `update.sh` — there it would discard the accumulated history on every deploy:

```bash
docker compose rm -sf goaccess && docker volume rm edge-caddy_goaccess-db && ./update.sh
```

`docker compose stop` is not enough — `docker volume rm` refuses a volume referenced by any
container, including a stopped one. `rm -sf` stops **and removes** the container first, so the
volume is actually free to drop.

That re-parses the current `access.log` with geo. Data from already-rotated logs is gone
as far as countries are concerned.

Ad-hoc queries against the raw log. Caddy writes it as root with mode `0600`, so
reading it needs `sudo` — e.g. the top 10 user agents:

```bash
sudo jq -r '.request.headers."User-Agent"[0]' logs/access.log | sort | uniq -c | sort -rn | head
```

Traffic per domain, which is what the `vhosts` panel shows:

```bash
sudo jq -r '.request.host' logs/access.log | sort | uniq -c | sort -rn
```

The slowest requests, which the dashboard only summarises as an average:

```bash
sudo jq -r '[.duration, .status, .request.host, .request.uri] | @tsv' logs/access.log | sort -rn | head
```

## Certs
Caddy stores certs/ACME state in the `caddy-data` volume. A fresh volume triggers
Let's Encrypt issuance for every domain on first request — well within rate limits for
five domains. DNS for each domain must already point at this host and 80/443 must be open.
