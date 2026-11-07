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
| `files.unividuell.org` | *(static file transfer, open — the file name is the secret)* |
| `prueffahrt.unividuell.org` | *(static Prüffahrt showcase, open — `/` redirects to `/showcase.html`)* |
| `monitoring.unividuell.org` | `edge-lgtm:3000` (Grafana, basicauth) |

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
| `MONITORING_AUTH_USER_1`, `MONITORING_AUTH_HASH_1` | Grafana user at `monitoring.unividuell.org` (required) |
| `COUNTDOWN_DB_MONITOR_PASSWORD` | countdown's read-only `monitor` role, both stacks (required) |
| `ALERT_SMTP_USER`, `ALERT_SMTP_PASSWORD`, `ALERT_EMAIL_TO` | Gmail sender, its app password, alert recipient (required) |

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

## Filetransfer

`https://files.unividuell.org/<name>` serves whatever sits in `filetransfer/` on the server,
next to `report/`, with no authentication at all. **The file name is the only secret.**
Nothing lists what is there: `file_server` runs without `browse`, so `/` and every
subdirectory answer 404, and a wrong name is indistinguishable from an empty server.
`update.sh` creates the directory; the mount is `:ro`, so Caddy only serves and there is no
upload endpoint — files arrive over `scp`.

```bash
scp bericht.pdf oci.unividuell.org:/opt/unividuell/edge-caddy/filetransfer/bericht-$(openssl rand -hex 12).pdf
```

The random suffix is not decoration. Nothing rate-limits or locks out this host, so a
guessable name (`bericht.pdf`, `rechnung.pdf`) is found by the first scanner that works
through a wordlist. Twelve random bytes are not reachable that way; a plain word is. Names
are case-sensitive — `Bericht.pdf` and `bericht.pdf` are different URLs.

Every response, including the 404s, carries `X-Robots-Tag: noindex, nofollow, noarchive`.
That, not a `robots.txt`, is what keeps a leaked URL out of a search index: `Disallow: /`
only stops the crawl, so a URL discovered elsewhere is still indexed and the crawler never
reads the noindex it would have been sent. `Referrer-Policy: no-referrer` keeps the secret
URL out of the `Referer` header if a served HTML file links onwards.

Two things follow from a secret being a URL rather than a credential:

- **Paste the link into a chat and third parties fetch it.** Slack, WhatsApp, Signal and
  the rest generate previews by requesting the URL from their own servers, so the secret
  is spent the moment it is shared. That is inherent to the design, not a bug in it.
- **Requested paths land in `logs/access.log`**, and `edge-goaccess` renders them into the
  `stats.unividuell.org` dashboard — so shared file names appear there in clear text and
  survive in the `goaccess-db` volume after the file is gone. The dashboard is behind basic
  auth. If that stops being acceptable, drop `log access` from the site block.

Deleting the file is the only way to revoke a link; there is no expiry and no download limit:

```bash
ssh oci.unividuell.org 'rm /opt/unividuell/edge-caddy/filetransfer/<name>'
```

## Prüffahrt showcase

`https://prueffahrt.unividuell.org` serves whatever sits in `prueffahrt/` on the server, next
to `filetransfer/`, with no authentication. The page is `showcase.html`, built in the
prueffahrt project; `/` has no page of its own and answers with a redirect there. It is a
temporary 302 on purpose: browsers cache a 301 indefinitely, so a permanent redirect would
outlive any later change to what `/` serves.

The page is meant for friends, not for search engines: every response carries the same
`X-Robots-Tag: noindex, nofollow, noarchive` as the filetransfer site, for the reason given
there. Link previews in chat apps are unaffected; they do not honour robots directives.

`update.sh` creates the directory; the mount is `:ro`, and the files arrive over `scp` — they
are not part of this repo. The page loads its images and its fonts by relative URL, so they sit
next to it. `preview.jpg` is the link-preview image its Open Graph tags point to, by absolute
URL. `fonts/` holds the web fonts (SIL OFL, licence texts alongside): serving them from here
rather than from Google Fonts keeps visitors' IPs away from Google.

```bash
scp -r showcase.html spectrogram-run3.jpg vespa-mount.jpg preview.jpg fonts oci.unividuell.org:/opt/unividuell/edge-caddy/prueffahrt/
```

A new version is live as soon as the copy finishes; Caddy needs no reload for content changes.

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
the handful of domains here. DNS for each domain must already point at this host and
80/443 must be open.

## Metrics, logs and traces (`edge-lgtm`)

One [`grafana/otel-lgtm`](https://github.com/grafana/docker-otel-lgtm) container for every
project: an OpenTelemetry Collector, Prometheus, Loki, Tempo and Grafana in one image.
Grafana is at `https://monitoring.unividuell.org`, behind basic auth; inside, it runs
anonymous with admin rights.

```
apps ── OTLP (metrics, traces) ── monitoring network ──┐
docker json-file logs (every container) ── ro mount ───┼──> collector ──> Prometheus / Loki / Tempo ──> Grafana
logs/access.log (this edge) ───────────────────────────┤
host CPU / RAM / disk / load ──────────────────────────┤
project databases (role `monitor`) ── monitoring network ┘
```

Our collector config is `monitoring/otelcol-config.yaml`; it replaces the image's own.
Alert rules, the mail contact point and the routing are `monitoring/grafana-alerting.yaml`:
5xx answers, `ERROR` log lines, an app gone silent and a nearly full disk, production only.
Mail goes via Gmail to `ALERT_EMAIL_TO`. It cannot report the server itself being down.
Dashboards are `monitoring/dashboards/*.json` (`countdown`, `mobility-manager`, `server`), provisioned at start —
edits in the Grafana UI do not survive a restart. A new dashboard also needs its line in
`update.sh`. Data lives in the `lgtm-data` volume and is kept for 30 days (Prometheus also
caps at 5 GB). Nothing in there needs a backup.

**Labels.** Everything carries `service_namespace` (the project), `service_name` and
`deployment_environment_name`. For container logs they come from the compose labels: the
project `countdown-staging` becomes namespace `countdown`, environment `staging`; every other
project is `production`. Apps sending OTLP must set the same values themselves.

### One-time setup

1. **DNS**: an A record `monitoring.unividuell.org` → the server.
2. **`.env`**: add `MONITORING_AUTH_USER_1` / `MONITORING_AUTH_HASH_1` (hash rules as above),
   `COUNTDOWN_DB_MONITOR_PASSWORD` (`openssl rand -hex 24`; no `$`) and
   `ALERT_SMTP_USER` / `ALERT_SMTP_PASSWORD` (a Gmail app password, without spaces) / `ALERT_EMAIL_TO`.
3. **Docker daemon** — `/etc/docker/daemon.json`:
   ```json
   {
     "log-driver": "json-file",
     "log-opts": {
       "max-size": "10m",
       "max-file": "3",
       "labels": "com.docker.compose.project,com.docker.compose.service"
     }
   }
   ```
   `labels` writes project and service into every log line — without it a line arrives
   but belongs to no project. `max-size`/`max-file` rotate the logs, which `json-file`
   otherwise never does. Then `sudo systemctl restart docker`: **every container restarts**.
   The options apply only to containers created afterwards, so recreate each stack once
   (`docker compose … up -d --force-recreate`, or its `update.sh` after a change).
   `update.sh` warns while the default driver is not `json-file`.
4. **Deploy with the new `update.sh`.** The running script cannot pick up its own
   replacement (see *Geo data*), and only the new one fetches `monitoring/` and creates the
   `monitoring` network:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/unividuell/edge-caddy/main/update.sh -o update.sh && ./update.sh
   ```

### Connecting a project

- **Logs**: nothing to do; every container's stdout is read. Spring apps should log ECS
  JSON (`logging.structured.format.console: ecs`): the collector unpacks level, logger,
  trace id and stack trace from it. Other formats arrive as plain text.
- **Metrics and traces**: the sending container joins the external network `monitoring`
  and exports OTLP to `http://edge-lgtm:4318`, with resource attributes `service.namespace`
  and `deployment.environment.name` set as above.
- **Database**: the project creates a read-only login role `monitor` with `pg_monitor`
  (statistics, no table rows) and puts its postgres, under a fixed `container_name`, on the
  `monitoring` network. Here: one `postgresql/<stack>` receiver per stack plus a
  `resource/<stack>-db` processor and a pipeline in `monitoring/otelcol-config.yaml`, the
  password in `.env`, passed through in `compose.yaml`. countdown is the example.
  Until the project side is deployed the receiver logs `no such host`; harmless.

### Updating the image

The tag is pinned in `compose.yaml`. Before raising it, diff our collector config against
the new image's (header of `monitoring/otelcol-config.yaml`). The image is 0.x: if the new
version cannot read the old data, `docker volume rm edge-caddy_lgtm-data` and start empty.

## Backup mirror

The home server **thin** (Debian, not reachable from the internet) pulls each app's backup
dir every 12 h into the same path on thin, `rsync --delete`, and reports each run to
`edge-lgtm`. Files: `backup-mirror/`.

```
thin ── ssh, key backup-mirror-<app>: forced read-only rrsync on that app's dir ──> server
thin ── same key, tunnel only to 127.0.0.1:4318 ── OTLP ──> edge-lgtm
```

| app | dir (server and thin) |
|---|---|
| countdown | `/opt/unividuell/countdown/backups` |
| mobility-manager | `/opt/unividuell/mobility-manager/backups` |

Metrics, label `app`: `backup_mirror_last_success_timestamp_seconds`,
`backup_mirror_newest_backup_age_seconds`, `backup_mirror_size_bytes`. Alerts: no run for
4 days (thin is off for days at times), or the newest backup over 26 h old when mirrored
(the app's backup on the server stopped). Panel at the top of the server dashboard.

**Setup on thin**, as `clemens`:

```bash
sudo apt install rsync
mkdir -p ~/backup-mirror ~/.config/systemd/user
B=https://raw.githubusercontent.com/unividuell/edge-caddy/main/backup-mirror
curl -fsSL $B/backup-mirror.sh -o ~/backup-mirror/backup-mirror.sh && chmod +x ~/backup-mirror/backup-mirror.sh
curl -fsSL $B/backup-mirror.service -o ~/.config/systemd/user/backup-mirror.service
curl -fsSL $B/backup-mirror.timer   -o ~/.config/systemd/user/backup-mirror.timer
systemctl --user daemon-reload && systemctl --user enable --now backup-mirror.timer
sudo loginctl enable-linger clemens   # user timers run without a login
```

Per app: on thin `sudo install -d -o clemens <dir>` and
`ssh-keygen -t ed25519 -N '' -C "backup-mirror <app>@thin" -f ~/.ssh/backup-mirror-<app>`;
on the server one line in `~ubuntu/.ssh/authorized_keys`:

```
restrict,port-forwarding,permitopen="127.0.0.1:4318",command="rrsync -ro <dir>" <thin's backup-mirror-<app>.pub>
```

A new app: these two steps, its line in `APPS` in `backup-mirror.sh`, and a backup routine
on the server that writes finished files there. Log of a run: `journalctl --user -u backup-mirror`.
