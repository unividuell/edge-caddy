# GoAccess Geo-Support (DB-IP Country Lite)

**Status:** Approved design (2026-08-08)
**Repo:** `github.com/unividuell/edge-caddy`
**Server dir:** `/opt/unividuell/edge-caddy/`
**Builds on:** [2026-08-07 Edge Traffic Monitoring](2026-08-07-traffic-monitoring-design.md)

## Purpose

The traffic dashboard answers *which domain, which status, which user agent*. It does not
answer **where the traffic comes from**. GoAccess has a `GEO_LOCATION` panel for exactly
that, but it stays empty without a GeoIP database.

Country resolution is the goal. It separates real regional audiences from the background
noise of scanners, and it costs one database file.

## Current state (discovered)

- `compose.yaml` passes no `--geoip-database` and mounts no `.mmdb`. The `geolocation`
  panel exists in the output but is empty.
- The GoAccess container runs `network_mode: none` — deliberately, it only reads and writes
  files.
- The access log masks client IPs to `ip_mask 24 48` (`Caddyfile`), i.e. IPv4 `/24`.
- The GoAccess loop starts a **fresh** `goaccess` process every 300 s.

## Verified findings

Established empirically against `allinurl/goaccess:latest` and `alpine:3`, not assumed.

1. **The image already supports mmdb.** `goaccess --version` reports GoAccess 1.11 built
   with `--enable-geoip=mmdb`. No custom image is needed — only the database file and the
   flag.
2. **The DB-IP Country Lite database populates the panel from `/24`-masked IPs.** Four
   Caddy JSON records with `client_ip` values `8.8.8.0`, `217.0.0.0`, `133.11.0.0`,
   `200.7.4.0` parsed 4/0 valid/failed and produced a `geolocation` panel with a
   continent → country hierarchy (`NA North America` → `US United States`, `EU Europe`,
   …). Masking is not an obstacle at country level: the `/24` retains the routing prefix.
3. **A missing database file is fatal.** `--geoip-database=/does/not/exist.mmdb` aborts with
   `Fatal error has occurred` and writes no report. The flag therefore must not be passed
   before the file exists, or a fresh deploy silently produces no dashboard at all.
4. **The DB-IP download needs no account.** `https://download.db-ip.com/free/dbip-country-lite-2026-08.mmdb.gz`
   was fetched successfully with plain busybox `wget` over HTTPS. Uncompressed size 8.3 MB.
   Licensed CC-BY 4.0, released monthly.
5. **MaxMind GeoLite2 needs an account and a licence key**, limits free users to 30
   downloads per day, and its EULA *obliges* users to delete databases within 30 days of a
   new release.
6. **`alpine:3` has everything needed**: busybox `wget` (HTTPS verified against db-ip.com),
   `gunzip`, `gzip`, `date`, `sed`, and it runs as root. `curlimages/curl` also carries
   `gunzip`, but runs as UID 100 `curl_user` and would fail to write into a fresh volume.
7. **`--html-custom-js` does not inline the file.** It emits
   `<script src='<path-as-given>'></script>` verbatim. A container path such as
   `/tmp/attr.js` therefore becomes a 404 in the browser. A **relative** path yields
   `<script src='attribution.js'></script>`, resolved by the browser against the report URL
   — and GoAccess does **not** require the file to exist at generation time.
8. **HTML in `--html-report-title` survives into the page header** as a live anchor, but the
   same string is HTML-escaped into `<title>`, so the browser tab would read
   `unividuell edge — <a href="…">…</a>`. Considered and rejected — see Decisions.
9. **An `asn` panel exists in the output** even with no ASN database loaded; it simply stays
   empty. Adding ASN later is a second `--geoip-database` flag, nothing more.
10. **Compose destroys a single-`$` variable visibly, and `$$` survives.** A command
    containing `echo "GOT:$GEO"` is rewritten by `docker compose config` to `echo "GOT:"`
    plus a warning — the loss is on the face of the rendered config. `$$GEO` is echoed back
    as `$$GEO` unchanged, and executing the service shows the shell receiving the real
    variable. `$${m#0}` likewise reached busybox `ash` intact and stripped the leading zero
    from `08` to `8`.
11. **A service without `networks:` gets an auto-created default bridge.** With `edge`
    declared as the only external network, Compose still emits a `<project>_default` network
    and attaches the unassigned service to it.

## Target architecture

```
              Internet :80/:443                          download.db-ip.com
                     │                                           │
        ┌────────────▼─────────────┐                             │ monthly
        │      edge-caddy          │                  ┌──────────▼──────────┐
        │  TLS + host routing      │                  │     edge-geoip      │
        └──┬─────────┬──────────┬──┘                  │  loop: daily check  │
           │         │          │                     └──────────┬──────────┘
   reverse_proxy   writes    serves                              │ writes
   to the apps       │          │                                │
                     │          │                        geoip-data volume
            logs/access.log   report/                   dbip-country-lite.mmdb
            (JSON, masked)    ├── index.html                     │
                     │        └── attribution.js                 │ (ro)
                     │ (ro)         ▲                            │
        ┌────────────▼─────────┐    │                            │
        │     edge-goaccess    │────┘  writes                    │
        │  loop: every 5 min   │◀────────────────────────────────┘
        │  network_mode: none  │
        └──────────┬───────────┘
                   │ --restore --persist
            goaccess-db volume
```

A third container, asleep 99.99 % of the time. It exists so that `edge-goaccess` keeps its
`network_mode: none` isolation: the component that parses untrusted request data stays off
the network, and the component that touches the network never parses logs.

## Components

### 1. `compose.yaml` — the `geoip` downloader service

```yaml
  geoip:
    image: alpine:3
    container_name: edge-geoip
    restart: unless-stopped
    # No `networks:` — Compose's default bridge. It needs egress to db-ip.com and has no
    # business on the `edge` network next to the application containers.
    entrypoint: ["/bin/sh", "-c"]
    volumes:
      - geoip-data:/geoip
```

Loop, once per pass:

1. `month = date -u +%Y-%m`. If the database exists **and** `/geoip/.stamp` already holds
   that month, sleep and do nothing.
2. Otherwise try `dbip-country-lite-<month>.mmdb.gz`, then the **previous** month. On the
   first days of a month the new file is not always published yet.
3. Download to `/geoip/.tmp.gz`, `gunzip`, then `mv` onto `dbip-country-lite.mmdb` — atomic,
   same filesystem, so a reader never sees a truncated database.
4. Write the **candidate that was actually installed** into `.stamp`, not the current month.
   Falling back to the previous month therefore leaves the stamp behind the calendar and the
   loop keeps retrying daily until the current month's file appears.
5. On success `sleep 86400`; on failure `sleep 3600`. A failed download leaves the previous
   database untouched.
6. Each step echoes one line so `docker logs edge-geoip` tells the whole story.

Month arithmetic uses POSIX parameter expansion (`${m#0}`) to strip the leading zero, not
`10#$m` — the latter is a bashism and busybox `ash` is not bash.

> **Compose interpolation hazard.** The script is a Compose block scalar, so **every** shell
> variable must be written `$$VAR`. A single `$` is interpolated away by Compose before the
> container ever sees it, leaving an empty string and a silently broken loop. This is the
> same sharp edge that already governs the `.env` hashes in this repo.

### 2. `compose.yaml` — the GoAccess service

Gains `- geoip-data:/geoip:ro`. `network_mode: none` stays.

The database flag is built **inside** the loop, guarded on the file's existence
(finding 3), so that:

- a fresh deploy renders a report immediately, geo-less, while the download is still running,
  instead of crash-looping;
- the flag starts applying on the next 5-minute pass once the file lands, with no restart;
- the monthly replacement is picked up automatically, because each pass is a new process.

```sh
GEO=""
[ -f /geoip/dbip-country-lite.mmdb ] && GEO="--geoip-database=/geoip/dbip-country-lite.mmdb"
```

(written `$$GEO` in `compose.yaml`, per the hazard above).

`--html-custom-js=attribution.js` is added — a relative path, per finding 7.

### 3. `attribution.js` — the CC-BY obligation

DB-IP's licence requires a visible `IP Geolocation by DB-IP` link on pages that display
results. A small committed script appends it to the report footer.

It lives in the repo root and is deployed **into `report/`**, next to `index.html`, because
the browser resolves `src='attribution.js'` against the report URL and Caddy serves that
directory with `file_server`. `report/` is git-ignored, so `update.sh` places it there.

### 4. `update.sh`

One additional fetch, `attribution.js` into `report/`. It must run **after** the existing
`mkdir -p logs report`, not with the other fetches at the top of the script.

The `caddy validate` gate is untouched — the `Caddyfile` does not change at all in this work.

### 5. `README.md`

A geo subsection under the monitoring chapter: what resolves (country, not city), where the
database comes from, its licence, the monthly refresh, and how to force a refresh
(`docker restart edge-geoip`).

### 6. One-time migration (operator, documented, **not** in `update.sh`)

GoAccess resolves geo at parse time, so records already in `goaccess-db` never gain a
country. The volume is dropped once so the current `access.log` is re-parsed with the
database in place:

```
docker compose rm -sf goaccess && docker volume rm edge-caddy_goaccess-db && ./update.sh
```

`docker compose stop` alone is not enough: `docker volume rm` refuses a volume referenced by
any container, including a stopped one, so the chain would abort at the `docker volume rm`
step and never reach `./update.sh` — leaving `goaccess` stopped. `rm -sf` stops **and
removes** the container, and the trailing `./update.sh` is what brings `goaccess` back up and
re-parses `access.log` with geo. This must stay a manual, documented step. In `update.sh` it
would discard the accumulated history on every single deploy.

## Decisions and rationale

**DB-IP Lite over MaxMind GeoLite2.** Both resolve countries equally well. GeoLite2 costs an
account, a licence key that becomes another secret in `.env`, and a contractual obligation to
delete stale copies within 30 days — a compliance duty attached to a hobby dashboard. DB-IP
is a plain URL and asks only for a link. GoAccess names it as a source in its own manual.

**Country only, not city or ASN.** The city database is an order of magnitude larger, and
GoAccess shows cities only inside the hosts panel, not as a panel of their own — while the
`/24` masking makes city resolution unreliable anyway. ASN would be genuinely useful for
separating cloud scanners from humans, but it is a second database for a question nobody has
asked yet. Finding 9 confirms the panel is already there when it is wanted; adding it later
is one flag.

**A dedicated downloader container, not a step in `update.sh`.** A fetch in `update.sh` would
be ~10 lines and no new service, but the database would then only ever be as fresh as the
last manual deploy. A container that checks daily keeps it current without anyone
remembering to.

**`alpine:3`, not the GoAccess image reused.** `allinurl/goaccess` also carries `wget` and
`gunzip` and is already pulled, so reusing it would cost zero additional footprint. Rejected
for legibility: two containers from one image with unrelated jobs is a puzzle for whoever
reads `docker ps` next, and `alpine:3` is 8 MB.

**Not on the `edge` network.** The downloader needs outbound internet, nothing else. Putting
it on `edge` would give it a route to every application container for no reason.

**`--html-custom-js`, not HTML in the report title.** The title trick needs no extra file and
does render a working link (finding 8) — but it also poisons the `<title>` element, so the
browser tab and every bookmark would show raw markup. One small committed file is the better
trade.

**The database is downloaded, not committed.** 8.3 MB of binary per monthly update in a
public repo, for data that is freely fetchable, is the wrong use of git.

## What this does not provide

- **No city resolution.** Country and continent only.
- **No ASN / provider breakdown.** The panel exists but stays empty.
- **No geo for historical data** beyond the one-time re-parse of the current `access.log`.
  Records in already-rotated logs are gone as far as geo is concerned.

## Limitations (accepted)

**Country attribution is approximate.** `/24` masking preserves the routing prefix, so
country lookups are sound in the ordinary case, but a `/24` that straddles a border resolves
to whichever country DB-IP assigns the network. VPN and cloud egress resolve to the exit
node, not the user — a scanner running in `eu-central-1` counts as Germany.

**The free database lags.** Monthly releases, and the loop tolerates being a month behind
during the first days of a month. Country assignments change slowly enough that this does not
matter.

**A failed download is silent to the dashboard.** The report keeps rendering with the
previous database, or without geo entirely on a fresh deploy that never managed a download.
The evidence lives in `docker logs edge-geoip`; nothing alerts.

## Verification

1. **Compose renders as intended.** `docker compose config` echoes every `$$VAR` back
   **unchanged as `$$VAR`**, and emits no *"variable is not set"* warning. Per finding 10 a
   missed escape shows up right here: the variable would be gone from the rendered command
   and the warning would name it.
2. **The download works.** `docker logs edge-geoip` reports an installed month, and
   `dbip-country-lite.mmdb` is present in the volume at roughly 8 MB.
3. **The guard works.** Before the database exists, the GoAccess container still produces
   `report/index.html` rather than crash-looping (this is the fresh-deploy path from
   finding 3).
4. **Geo actually resolves.** After one 5-minute pass with the database in place, the
   dashboard's *Geo Location* panel is non-empty and lists plausible countries — not a single
   bucket and not `Unknown` for everything.
5. **The attribution renders.** The DB-IP link is visible on the report page and
   `report/attribution.js` returns 200 (behind basic auth), not 404.
6. **The re-parse took effect.** After dropping `goaccess-db`, the geo panel's hit total
   matches the dashboard's overall total rather than covering only the period since
   activation.
7. **The monthly swap needs no restart.** Replace the file in the volume by hand and confirm
   the next pass picks it up — GoAccess is a new process each interval, so this should hold
   without touching the container.
8. **Nothing else regressed.** The existing panels (vhosts, status codes, browsers) still
   populate, and `stats.unividuell.org` still returns 401 without credentials.
