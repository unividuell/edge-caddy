# Edge Traffic Monitoring (Caddy access logs + GoAccess)

**Status:** Approved design (2026-08-07)
**Repo:** `github.com/unividuell/edge-caddy`
**Server dir:** `/opt/unividuell/edge-caddy/`

## Purpose

Give the operator insight into what actually happens on the edge: **which domain receives
the traffic, which status codes are returned, which user agents call, and how long requests
take**. Today none of this is visible.

The edge is the only place where every request for every project passes through, so it is
the correct and only place to collect this — no per-project instrumentation needed.

## Current state (discovered)

- The global `log` block in `Caddyfile` writes `/var/log/caddy/system.log` at level INFO.
  This is the **system** log (Caddy messages, ACME, errors) — **not** an access log.
- Exactly one site has an access log: `news.zingler46.unividuell.org`, in Caddy's default
  format, with unmasked client IPs.
- `countdown.unividuell.org`, `beta.countdown.unividuell.org` and `mobility.unividuell.org`
  produce **no request records at all**.
- `logs/` is already bind-mounted into the edge container and git-ignored.

## Verified findings

These were established empirically against `caddy:2-alpine` and `allinurl/goaccess:latest`,
not assumed. They constrain the design.

1. **A global `log` block alone does not enable access logging.** Adapting a config whose
   sites carry no `log` directive yields a `srv0` with no `logs` key at all — no access
   records are emitted, regardless of `include http.log.access`. With `log` present in the
   site blocks, `logs.logger_names` appears. Sites that omit it are added to `skip_hosts`.
   → **Every site block must carry `log access`.**
2. **`format filter` works as documented.** `ip_mask` masked a client IP to its network
   prefix, and `Cookie` / `Authorization` headers were absent from the emitted records.
3. **GoAccess parses Caddy's JSON natively** via the built-in `--log-format=CADDY` preset —
   0 failed records — and populates `vhosts`, `status_codes`, `browsers`, `requests`,
   `not_found` and `hosts`. A `Googlebot` user agent was classified as `Crawlers`.
4. **`--persist` / `--restore` do not double-count on re-read.** Three consecutive runs over
   an unchanged file held counts steady; appending two records raised exactly those counts.
   This dedup relies on inode + last-line + timestamp tracking and **only works on direct
   file input** — piped input is documented to duplicate.
   → **GoAccess must mount the log file, not receive it on stdin.**
   `--restore` against an empty `--db-path` also succeeds rather than erroring, so the loop
   needs no first-run special case.
5. **Caddy's `duration` field is parsed into GoAccess time metrics.** Durations of 0.004 s /
   0.150 s / 1.900 s surfaced as `avgts`/`maxts` of 4 000 / 150 000 / 1 900 000 µs, with
   `cumts` summing correctly across hits.
6. **A unique visitor is keyed on IP + User-Agent + day.** 3 IP networks × 3 user agents ×
   2 requests = 9 unique visitors from 18 requests; and one IP with one user agent across
   three days counted as 3 unique visitors.
7. **Caddy's `hash` filter is unsalted and stable** across requests and container restarts
   (same input IP → `4e73a253` every time). Considered and rejected — see Decisions.

## Target architecture

```
              Internet :80/:443
                     │
        ┌────────────▼─────────────┐
        │      edge-caddy          │
        │  TLS + host routing      │
        └──┬─────────┬──────────┬──┘
           │         │          │
   reverse_proxy   writes    serves
   to the apps       │          │
                     │          │
            logs/access.log   report/index.html
            (JSON, masked)    (basic_auth,
                     │         stats.unividuell.org)
                     │ (ro)         ▲
        ┌────────────▼─────────┐    │
        │     edge-goaccess    │────┘  writes
        │  loop: every 5 min   │
        └──────────┬───────────┘
                   │ --restore --persist
            goaccess-db volume
            (cumulative aggregates)
```

Two containers. GoAccess is a small C binary that runs for a few seconds per interval and is
otherwise asleep; its footprint is negligible next to the existing app stacks.

Raw logs stay short-lived and size-bounded; long-term history lives only as aggregates in
the GoAccess database. That is both the retention mechanism and the data-minimisation
measure.

## Components

### 1. `Caddyfile` — named access logger

A **named** logger `access`, added alongside the existing default logger so `system.log`
keeps working unchanged:

```
log access {
    output file /var/log/caddy/access.log {
        roll_size 20mb
        roll_keep 5
    }
    format filter {
        wrap json
        request>remote_ip ip_mask 24 48
        request>client_ip ip_mask 24 48
        request>headers>Cookie delete
        request>headers>Authorization delete
    }
    include http.log.access
}
```

### 2. `Caddyfile` — `log access` in every site block

Added to `countdown`, `beta.countdown`, `mobility`, `news.zingler46` and the new `stats`
site. The site-local log block on `news.zingler46` (`news_zingler46_access.log`, unmasked,
non-JSON) is **removed** — all sites share one log, and the `vhosts` panel separates them.

### 3. `Caddyfile` — the `stats` site

Follows the existing `news.zingler46` basic-auth pattern:

```
stats.unividuell.org {
    log access
    basic_auth {
        stats {$STATS_AUTH_HASH}
    }
    root * /srv/report
    file_server
}
```

A **separate** hash from `BASIC_AUTH_HASH`, so the news credentials and the monitoring
credentials are independent.

### 4. `compose.yaml` — the GoAccess service

```yaml
  goaccess:
    image: allinurl/goaccess:latest
    container_name: edge-goaccess
    restart: unless-stopped
    volumes:
      - ./logs:/logs:ro
      - ./report:/report
      - goaccess-db:/db
```

driven by a loop that, every 300 s:

1. passes `--restore --persist` unconditionally — no first-run special case is needed,
2. tolerates a not-yet-existing `/logs/access.log` (fresh deploy, before the first request),
3. renders to `/report/.index.html.tmp` and then `mv`s it onto `/report/index.html`, so
   Caddy never serves a half-written page,
4. passes `--no-global-config` for determinism and `--tz=Europe/Berlin` so timestamps read
   in local time rather than UTC (the image ships `tzdata`; the flag was verified to
   produce `+0200`).

Crawlers are deliberately **not** filtered out — bot traffic is part of what the operator
wants to see.

The edge gains `- ./report:/srv/report:ro`; a `goaccess-db` named volume is added.

### 5. Supporting files

- `update.sh` — fetch the new files from `main`; create `report/` before `up`.
- `.env.example` — document `STATS_AUTH_HASH` with its generation command.
- `.gitignore` — add `report/`.
- `README.md` — the new route, the monitoring section, the DNS prerequisite.

## Decisions and rationale

**GoAccess over Grafana+Loki.** Loki answers more questions but is a stack to operate. The
requirement is insight, not alerting, and the operator explicitly judged Loki's effort
disproportionate. The JSON logs this design produces are exactly what a Loki shipper would
consume later, so the migration path stays open.

**Logs, not Prometheus metrics.** Caddy's metrics carry `server`, `handler`, `code` and
`method` labels but **no host label**, and all `:443` sites share one server (`srv0`).
Metrics therefore cannot answer "which domain gets the traffic", and carry no user agents at
all. `metrics` remains a sensible *additive* step later for latency percentiles.

**`ip_mask 24 48`, not `hash`.** Hashing would make each IP 1:1 distinguishable and improve
unique-visitor accuracy, but an unsalted 32-bit hash over the IPv4 space is trivially
brute-forceable — pseudonymisation, not anonymisation, so the data stays personal — and it
destroys geo resolution that a /24 preserves. It would also only fix one of the four
distortions listed under Limitations; the dominant one (per-day counting) is unaffected.

**Periodic regeneration, not `--real-time-html`.** Real-time needs a WebSocket proxied
through the edge. Periodic rendering is robust against log rotation and adds no listener.

**One shared log file.** Per-site files would multiply rotation state and force GoAccess to
track several inodes for no gain; `vhosts` already separates the domains.

## What this does not provide

- **No alerting.** Nothing fires when the 5xx rate climbs.
- **No latency percentiles.** GoAccess reports average, maximum and cumulative time served
  per row — there is no p95. Averages hide outliers.
- **No accurate visitor counts.** See Limitations.

## Limitations (accepted)

**Unique visitors are a trend indicator, not a headcount.** Four distortions, in descending
order of impact:

1. The key includes the day, so a returning visitor is counted again each day; a monthly
   figure is a sum of daily uniques, not a count of distinct people.
2. `/24` masking merges people who share a network prefix and a browser — notably behind
   mobile CGNAT.
3. The user agent is part of the key, so a browser update or a second device inflates it.
4. Bots are included (visible as `Crawlers`).

Server logs cannot do better in principle. Cookieless client-side analytics would, for the
browser-facing SPA only, and is deliberately out of scope here.

**Rotation may drop a tail.** If Caddy rotates between two GoAccess runs, the inode changes
and GoAccess parses the new file from its start; records still unread in the rotated file
are lost. At 20 MB roll size and a 5-minute interval this is rare, and this is an overview
dashboard, not billing.

## Prerequisites (operator)

- A **DNS A record** for `stats.unividuell.org` pointing at the host. Without it Caddy
  cannot obtain a certificate.
- `STATS_AUTH_HASH` in `.env`:
  `docker run --rm caddy:2-alpine caddy hash-password --plaintext '<password>'`

## Verification

1. **Config adapts.** `caddy adapt` on the new `Caddyfile`. Per the repo guideline,
   `{$ENV}` placeholders resolve at adapt time, so validate with realistic dummy hashes.
2. **Adapted JSON is correct.** `srv0.logs.logger_names` names every site against the
   `access` logger, and `skip_hosts` is absent.
3. **Records are written and sanitised.** After deploy, request each domain, then confirm
   `logs/access.log` holds one JSON record per request with a masked `client_ip`, a `host`,
   a `status`, a `User-Agent` and a `duration` — and no `Cookie` or `Authorization` header.
4. **The report renders.** `report/index.html` exists after one interval and shows all four
   domains under Virtual Hosts.
5. **No double counting.** Note a hit count, wait two intervals without traffic, confirm it
   is unchanged.
6. **The dashboard is protected.** `stats.unividuell.org` returns 401 without credentials
   and the report with them.
