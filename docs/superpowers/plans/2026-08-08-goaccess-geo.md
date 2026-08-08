# GoAccess Geo-Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the traffic dashboard's *Geo Location* panel resolve countries, by feeding GoAccess a DB-IP Country Lite database that a small sidecar container keeps current.

**Architecture:** A third container, `edge-geoip`, checks daily whether the current month's DB-IP Country Lite database is installed and downloads it into a named volume if not. `edge-goaccess` mounts that volume read-only and passes `--geoip-database` only when the file exists, so it keeps its `network_mode: none` isolation and never crash-loops on a fresh deploy. DB-IP's CC-BY licence is satisfied by a small committed `attribution.js` served from the report directory.

**Tech Stack:** Docker Compose, `alpine:3` (busybox `wget`/`gunzip`), `allinurl/goaccess:latest` (GoAccess 1.11, built `--enable-geoip=mmdb`), DB-IP Country Lite (mmdb, CC-BY 4.0).

**Spec:** [`docs/superpowers/specs/2026-08-08-goaccess-geo-design.md`](../specs/2026-08-08-goaccess-geo-design.md)

## Global Constraints

- **Every `$` in a `compose.yaml` command block must be written `$$`.** Compose interpolates a single `$` away *before* the container sees it. Verified: `echo "GOT:$GEO"` renders as `echo "GOT:"` plus a *"variable is not set"* warning; `$$GEO` renders back as `$$GEO` and reaches the shell intact. This applies to `$$(...)`, `$${m#0}` and every plain `$$VAR`.
- **`--geoip-database` pointing at a missing file is fatal.** Verified: GoAccess prints `Fatal error has occurred` and writes no report at all. The flag must be built inside the loop, guarded on the file's existence.
- **`--html-custom-js` does not inline the file.** Verified: it emits `<script src='<path-exactly-as-given>'></script>`. The value must therefore be the **relative** path `attribution.js`, and the file must be served from the report directory — not mounted into the GoAccess container.
- **GoAccess does not require the custom-JS file to exist** at report-generation time. Verified: generation succeeds and the `<script>` tag is emitted regardless.
- **Month arithmetic must be POSIX, not bash.** Use `$${m#0}` to strip the leading zero. `10#$m` is a bashism and busybox `ash` is not bash. Verified: `$${m#0}` turned `08` into `8` inside `alpine:3`.
- **Local verification cannot use bind mounts.** Docker Desktop on this machine denies mounts from both `/private/tmp` and the repo directory. The `geoip` service uses only a *named* volume, so it runs locally as-is; anything touching `./logs` or `./report` must be checked with in-container heredocs instead. This is a *local* constraint only — do not restructure `compose.yaml` around it.
- **The `edge` network is `external: true`.** Run `docker network create edge 2>/dev/null || true` before any local `docker compose` command, exactly as `update.sh` does.
- **Country level only.** No city database, no ASN database. The empty `asn` panel is expected and is not a defect.
- **`compose.yaml` uses two-space indentation.** `attribution.js` is plain ES5-compatible browser JS with no build step and no dependencies.
- **The repo is public.** Nothing secret is introduced by this work — DB-IP needs no account or key.
- **`docker compose config` warns about unset `.env` variables locally.** The worktree has no `.env`; warnings naming `NEWS_AUTH_*` / `STATS_AUTH_*` are expected noise. Only warnings naming *this* work's variables are failures.

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `compose.yaml` | container topology | new `geoip` service; new `geoip-data` volume; `geoip-data` mounted read-only into `goaccess`; in-loop geo guard; `--html-custom-js` flag |
| `attribution.js` | the CC-BY 4.0 attribution link | **new file**, committed at repo root, deployed into `report/` |
| `update.sh` | server-side deploy | fetch `attribution.js` into `report/` after the existing `mkdir -p` |
| `README.md` | operator docs | geo subsection under `## Monitoring`; the one-time `goaccess-db` migration |

---

### Task 1: The `geoip` downloader service

**Files:**
- Modify: `compose.yaml` (new service after `goaccess`; new volume in the `volumes:` block)

**Interfaces:**
- Consumes: nothing.
- Produces: a named volume `geoip-data` containing `dbip-country-lite.mmdb` (~8.3 MB, uncompressed mmdb) and a `.stamp` file holding the installed `YYYY-MM`. Task 2 mounts this volume read-only at `/geoip` and reads exactly the path `/geoip/dbip-country-lite.mmdb`.

- [ ] **Step 1: Write the failing check**

Save as `/tmp/check-geoip-download.sh` (not committed):

```bash
#!/usr/bin/env sh
# Asserts the geoip service downloads and installs a usable country database,
# and that Compose did not eat the shell variables in its command block.
set -eu
cd "$(git rev-parse --show-toplevel)"
docker network create edge 2>/dev/null || true

echo "--- 1. the service exists ---"
docker compose config --services 2>/dev/null | grep -qx geoip \
  || { echo "FAIL: no 'geoip' service"; exit 1; }

echo "--- 2. \$\$ escaping survived interpolation ---"
rendered=$(docker compose config 2>/dev/null)
for tok in '$$DB' '$$STAMP' '$$month' '$$cand' '$${m#0}'; do
  printf '%s' "$rendered" | grep -qF -- "$tok" \
    || { echo "FAIL: $tok missing from rendered config (Compose ate a single \$)"; exit 1; }
done
docker compose config 2>&1 >/dev/null | grep -E '"(DB|STAMP|month|cand|m|y|pm|py|prev|url|installed|GEO)" variable is not set' \
  && { echo "FAIL: Compose interpolated one of our shell variables"; exit 1; }

echo "--- 3. it actually downloads ---"
docker compose up -d geoip
ok=0
i=0
while [ $i -lt 90 ]; do
  size=$(docker compose exec -T geoip sh -c 'wc -c < /geoip/dbip-country-lite.mmdb 2>/dev/null || echo 0' | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  if [ "$size" -gt 4000000 ]; then ok=1; break; fi
  i=$((i + 1))
  sleep 2
done
[ "$ok" = 1 ] || { echo "FAIL: no database after 180s"; docker compose logs geoip; exit 1; }
echo "installed size: $size bytes"

echo "--- 4. the stamp is a plausible month ---"
stamp=$(docker compose exec -T geoip sh -c 'cat /geoip/.stamp' | tr -d '[:space:]')
echo "$stamp" | grep -qE '^[0-9]{4}-[0-9]{2}$' \
  || { echo "FAIL: .stamp is '$stamp', not YYYY-MM"; exit 1; }

echo "--- 5. no leftover temp files ---"
# `ls -a`, not `ls`: everything this service writes except the database is a dotfile,
# so a plain `ls` would report success no matter what is in there.
docker compose exec -T geoip sh -c 'ls -a /geoip' | grep -qE '^\.tmp' \
  && { echo "FAIL: temp file left behind in the volume"; exit 1; }

echo "--- 6. GoAccess accepts the file as a geo database ---"
# `docker cp`, not `exec cat`: this is 8 MB of binary and must not go through a pty.
docker cp edge-geoip:/geoip/dbip-country-lite.mmdb /tmp/geo.mmdb
docker run --rm -i --entrypoint sh allinurl/goaccess:latest -c '
cat > /tmp/db
cat > /tmp/a.log <<LOG
{"level":"info","ts":1754640000.1,"logger":"http.log.access","msg":"handled request","request":{"remote_ip":"8.8.8.0","remote_port":"1","client_ip":"8.8.8.0","proto":"HTTP/2.0","method":"GET","host":"x.org","uri":"/","headers":{"User-Agent":["Mozilla/5.0"]}},"bytes_read":0,"user_id":"","duration":0.01,"size":10,"status":200,"resp_headers":{}}
LOG
goaccess /tmp/a.log --log-format=CADDY --no-global-config --no-progress --geoip-database=/tmp/db -o json 2>/dev/null
' < /tmp/geo.mmdb | grep -q 'US United States' \
  || { echo "FAIL: 8.8.8.0 did not resolve to United States"; exit 1; }

echo "PASS"
```

Note step 6 pipes the database through stdin rather than mounting it — bind mounts are denied locally (see Global Constraints).

- [ ] **Step 2: Run the check to verify it fails**

```bash
sh /tmp/check-geoip-download.sh
```

Expected: `FAIL: no 'geoip' service`.

- [ ] **Step 3: Add the service and the volume**

In `compose.yaml`, insert this service after the `goaccess` service (before the top-level `volumes:` key). Note every `$` is doubled — see Global Constraints.

```yaml
  # Keeps the GeoIP country database current. It exists as its own container so that
  # edge-goaccess — which parses untrusted request data — can stay on network_mode: none.
  geoip:
    image: alpine:3
    container_name: edge-geoip
    restart: unless-stopped
    # No `networks:` on purpose: Compose's auto-created default bridge gives the egress
    # this needs, and it has no business on `edge` beside the application containers.
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        DB=/geoip/dbip-country-lite.mmdb
        STAMP=/geoip/.stamp
        while :; do
          month=$$(date -u +%Y-%m)
          if [ -f "$$DB" ] && [ "$$(cat "$$STAMP" 2>/dev/null)" = "$$month" ]; then
            sleep 86400
            continue
          fi
          # DB-IP publishes monthly. On the first days of a month the new file may not
          # exist yet, so fall back to the previous month.
          y=$$(date -u +%Y)
          m=$$(date -u +%m)
          pm=$$(( $${m#0} - 1 ))
          py=$$y
          if [ "$$pm" -eq 0 ]; then pm=12; py=$$(( y - 1 )); fi
          prev=$$(printf '%s-%02d' "$$py" "$$pm")
          installed=""
          for cand in "$$month" "$$prev"; do
            url="https://download.db-ip.com/free/dbip-country-lite-$$cand.mmdb.gz"
            echo "geoip: trying $$cand"
            if wget -q -O /geoip/.tmp.gz "$$url" \
               && gunzip -f /geoip/.tmp.gz \
               && mv /geoip/.tmp "$$DB"; then
              printf '%s' "$$cand" > "$$STAMP"
              installed=$$cand
              echo "geoip: installed $$cand ($$(wc -c < "$$DB") bytes)"
              break
            fi
          done
          rm -f /geoip/.tmp.gz /geoip/.tmp
          # The stamp records the month actually installed, not today's. Falling back to
          # the previous month therefore leaves it behind the calendar, and the daily
          # retry keeps going until the current month's file appears.
          if [ -n "$$installed" ]; then
            sleep 86400
          else
            echo "geoip: no database available, retrying in 1h"
            sleep 3600
          fi
        done
    volumes:
      - geoip-data:/geoip
```

And add the volume to the existing top-level `volumes:` block:

```yaml
volumes:
  caddy-data:
  caddy-config:
  goaccess-db:
  geoip-data:
```

- [ ] **Step 4: Run the check to verify it passes**

```bash
sh /tmp/check-geoip-download.sh
```

Expected: `PASS`, with an installed size around 8 300 000 bytes.

- [ ] **Step 5: Tear the local test containers down**

```bash
docker compose down && docker volume rm edge-caddy_geoip-data
```

- [ ] **Step 6: Commit**

```bash
git add compose.yaml
git commit -m "feat: add geoip sidecar that keeps the DB-IP country database current"
```

---

### Task 2: GoAccess resolves countries

**Files:**
- Modify: `compose.yaml` (the `goaccess` service — `volumes:` and `command:`)

**Interfaces:**
- Consumes: `geoip-data` from Task 1, mounted read-only at `/geoip`, file `/geoip/dbip-country-lite.mmdb`.
- Produces: a report whose `geolocation` panel is populated. Task 3 adds a second flag to the same `goaccess` invocation.

- [ ] **Step 1: Write the failing check**

Save as `/tmp/check-goaccess-geo.sh` (not committed). It checks the compose wiring statically, then exercises the guard logic — both branches — inside a container, because `./logs` and `./report` cannot be bind-mounted locally.

```bash
#!/usr/bin/env sh
# Asserts GoAccess mounts the database read-only, guards on its existence,
# and resolves countries when it is present.
set -eu
cd "$(git rev-parse --show-toplevel)"
docker network create edge 2>/dev/null || true
rendered=$(docker compose config 2>/dev/null)

echo "--- 1. the volume is mounted read-only ---"
printf '%s' "$rendered" | grep -qF 'geoip-data' \
  || { echo "FAIL: goaccess does not reference geoip-data"; exit 1; }
# Compose renders volumes in long form. A bare `read_only: true` grep would also match
# the pre-existing ./logs:/logs:ro entry, so scope it to the geoip-data block.
printf '%s' "$rendered" | grep -A3 'source: geoip-data' | grep -q 'read_only: true' \
  || { echo "FAIL: the geoip mount is not read-only"; exit 1; }

echo "--- 2. the flag is guarded, not unconditional ---"
printf '%s' "$rendered" | grep -qF '$$GEO' \
  || { echo "FAIL: no \$\$GEO in the goaccess command"; exit 1; }
printf '%s' "$rendered" | grep -qF -- '-f /geoip/dbip-country-lite.mmdb' \
  || { echo "FAIL: the existence guard is missing"; exit 1; }
printf '%s' "$rendered" | grep -qE -- '--geoip-database=/geoip/dbip-country-lite\.mmdb [^"]*\\$' \
  && { echo "FAIL: --geoip-database appears unconditionally in the command"; exit 1; }

echo "--- 3. both guard branches behave ---"
docker run --rm --entrypoint sh --network bridge allinurl/goaccess:latest -c '
set -e
mkdir -p /logs /report /geoip
cat > /logs/access.log <<LOG
{"level":"info","ts":1754640000.1,"logger":"http.log.access","msg":"handled request","request":{"remote_ip":"8.8.8.0","remote_port":"1","client_ip":"8.8.8.0","proto":"HTTP/2.0","method":"GET","host":"x.org","uri":"/","headers":{"User-Agent":["Mozilla/5.0"]}},"bytes_read":0,"user_id":"","duration":0.01,"size":10,"status":200,"resp_headers":{}}
{"level":"info","ts":1754640001.1,"logger":"http.log.access","msg":"handled request","request":{"remote_ip":"217.0.0.0","remote_port":"1","client_ip":"217.0.0.0","proto":"HTTP/2.0","method":"GET","host":"x.org","uri":"/a","headers":{"User-Agent":["Mozilla/5.0"]}},"bytes_read":0,"user_id":"","duration":0.01,"size":10,"status":200,"resp_headers":{}}
LOG

# This is the loop body from compose.yaml, with $$ unescaped back to $.
run_once () {
  GEO=""
  [ -f /geoip/dbip-country-lite.mmdb ] && GEO="--geoip-database=/geoip/dbip-country-lite.mmdb"
  goaccess /logs/access.log --log-format=CADDY --no-global-config --no-progress \
    --tz=Europe/Berlin --db-path=/db --restore --persist --real-os $GEO \
    -o /report/.tmp.json >/dev/null 2>&1 || return 1
  return 0
}

mkdir -p /db
echo "  branch A: no database present"
run_once || { echo "FAIL-A: goaccess did not produce a report without a database"; exit 1; }
# The point of branch A is that a database-less pass still renders, rather than dying the
# way an unconditional --geoip-database would. Verified: GoAccess then omits the
# geolocation key entirely, so asserting its presence here would be asserting the opposite.
grep -q "\"general\"" /report/.tmp.json || { echo "FAIL-A: not a valid GoAccess report"; exit 1; }
grep -q "\"geolocation\"" /report/.tmp.json && { echo "FAIL-A: geo resolved without a database?"; exit 1; }

rm -rf /db && mkdir -p /db
echo "  branch B: database present"
wget -q -O /tmp/db.gz "https://download.db-ip.com/free/dbip-country-lite-$(date -u +%Y-%m).mmdb.gz" \
  || wget -q -O /tmp/db.gz "https://download.db-ip.com/free/dbip-country-lite-$(date -u -d @$(( $(date -u +%s) - 2592000 )) +%Y-%m).mmdb.gz"
gunzip -f /tmp/db.gz && mv /tmp/db /geoip/dbip-country-lite.mmdb
run_once || { echo "FAIL-B: goaccess failed with a database present"; exit 1; }
grep -q "United States" /report/.tmp.json || { echo "FAIL-B: 8.8.8.0 did not resolve"; exit 1; }
grep -q "Germany" /report/.tmp.json || { echo "FAIL-B: 217.0.0.0 did not resolve"; exit 1; }
echo "  both branches OK"
' || exit 1

echo "PASS"
```

Note the `-o /report/.tmp.json` in the check: the real service renders HTML, but JSON is what a script can assert against, and GoAccess infers the format from the file extension. Do **not** reach for `--output-format=json` — verified, no such option: GoAccess exits 1 and writes nothing. The flags actually under test, the guard and `--geoip-database`, behave identically either way.

- [ ] **Step 2: Run the check to verify it fails**

```bash
sh /tmp/check-goaccess-geo.sh
```

Expected: `FAIL: goaccess does not reference geoip-data`.

- [ ] **Step 3: Mount the volume read-only**

In the `goaccess` service's `volumes:` block in `compose.yaml`, add the third entry:

```yaml
    volumes:
      - ./logs:/logs:ro
      - ./report:/report
      - goaccess-db:/db
      - geoip-data:/geoip:ro
```

- [ ] **Step 4: Guard the flag inside the loop**

Replace the `goaccess` service's `command:` block with this. The two new lines are the `GEO=` pair and the `$$GEO \` continuation; everything else is unchanged.

```yaml
    command:
      - |
        while :; do
          if [ -s /logs/access.log ]; then
            # Built per pass, not once: a missing database file is fatal to GoAccess, so
            # a fresh deploy must render geo-less until edge-geoip finishes. Each pass is
            # a new process, so the flag starts applying — and monthly database swaps get
            # picked up — with no restart.
            GEO=""
            [ -f /geoip/dbip-country-lite.mmdb ] && GEO="--geoip-database=/geoip/dbip-country-lite.mmdb"
            goaccess /logs/access.log \
              --log-format=CADDY \
              --no-global-config \
              --no-progress \
              --tz=Europe/Berlin \
              --db-path=/db \
              --restore --persist \
              --real-os \
              $$GEO \
              --html-report-title='unividuell edge' \
              -o /report/.tmp.html \
            && mv /report/.tmp.html /report/index.html
          fi
          sleep 300
        done
```

- [ ] **Step 5: Run the check to verify it passes**

```bash
sh /tmp/check-goaccess-geo.sh
```

Expected: `PASS`, with `both branches OK`.

- [ ] **Step 6: Commit**

```bash
git add compose.yaml
git commit -m "feat: resolve countries in the GoAccess report"
```

---

### Task 3: The CC-BY attribution link

**Files:**
- Create: `attribution.js`
- Modify: `compose.yaml` (one flag in the `goaccess` command)
- Modify: `update.sh` (one fetch, after the existing `mkdir -p logs report`)

**Interfaces:**
- Consumes: the `goaccess` command block from Task 2.
- Produces: `report/attribution.js` on the server, referenced by `index.html` as `<script src='attribution.js'></script>`.

- [ ] **Step 1: Write the failing check**

Save as `/tmp/check-attribution.sh` (not committed):

```bash
#!/usr/bin/env sh
# Asserts the report references attribution.js relatively, that the script is
# deployed next to index.html, and that it injects a DB-IP link.
set -eu
cd "$(git rev-parse --show-toplevel)"

echo "--- 1. the file exists and names DB-IP ---"
[ -f attribution.js ] || { echo "FAIL: attribution.js missing"; exit 1; }
grep -qF 'db-ip.com' attribution.js || { echo "FAIL: no db-ip.com link in attribution.js"; exit 1; }
grep -qF 'IP Geolocation by DB-IP' attribution.js \
  || { echo "FAIL: the licence-required wording is missing"; exit 1; }

echo "--- 2. the flag uses a RELATIVE path ---"
rendered=$(docker compose config 2>/dev/null)
printf '%s' "$rendered" | grep -qF -- '--html-custom-js=attribution.js' \
  || { echo "FAIL: --html-custom-js is absent or not the bare relative path"; exit 1; }
printf '%s' "$rendered" | grep -qE -- '--html-custom-js=/' \
  && { echo "FAIL: an absolute path would 404 in the browser"; exit 1; }

echo "--- 3. update.sh deploys it into report/, AFTER mkdir ---"
grep -qF 'attribution.js' update.sh || { echo "FAIL: update.sh does not fetch attribution.js"; exit 1; }
mk=$(grep -n 'mkdir -p logs report' update.sh | head -1 | cut -d: -f1)
at=$(grep -n 'attribution.js' update.sh | head -1 | cut -d: -f1)
[ -n "$mk" ] && [ -n "$at" ] && [ "$at" -gt "$mk" ] \
  || { echo "FAIL: the fetch (line $at) must come after mkdir -p (line $mk)"; exit 1; }
grep -qF 'report/attribution.js' update.sh \
  || { echo "FAIL: it must be fetched INTO report/, next to index.html"; exit 1; }

echo "--- 4. the generated report references it ---"
docker run --rm -i --entrypoint sh allinurl/goaccess:latest -c '
cat > /tmp/a.log <<LOG
{"level":"info","ts":1754640000.1,"logger":"http.log.access","msg":"handled request","request":{"remote_ip":"8.8.8.0","remote_port":"1","client_ip":"8.8.8.0","proto":"HTTP/2.0","method":"GET","host":"x.org","uri":"/","headers":{"User-Agent":["Mozilla/5.0"]}},"bytes_read":0,"user_id":"","duration":0.01,"size":10,"status":200,"resp_headers":{}}
LOG
goaccess /tmp/a.log --log-format=CADDY --no-global-config --no-progress \
  --html-custom-js=attribution.js -o /tmp/r.html >/dev/null 2>&1
grep -o "<script src=.attribution.js.></script>" /tmp/r.html
' | grep -q "attribution.js" \
  || { echo "FAIL: the report does not reference attribution.js"; exit 1; }

echo "PASS"
```

- [ ] **Step 2: Run the check to verify it fails**

```bash
sh /tmp/check-attribution.sh
```

Expected: `FAIL: attribution.js missing`.

- [ ] **Step 3: Create `attribution.js`**

Create `attribution.js` at the repo root:

```javascript
/*
 * Geo data in this report comes from DB-IP's free IP-to-Country Lite database,
 * which is licensed CC-BY 4.0 and requires a visible attribution link on pages
 * that display its results. See docs/superpowers/specs/2026-08-08-goaccess-geo-design.md.
 *
 * GoAccess references this file as <script src='attribution.js'>, resolved by the
 * browser against the report URL — so it must sit next to index.html in report/.
 */
(function () {
  function addAttribution() {
    if (document.getElementById('dbip-attribution')) {
      return;
    }
    var p = document.createElement('p');
    p.id = 'dbip-attribution';
    p.style.textAlign = 'center';
    p.style.padding = '1em 0';
    p.style.fontSize = '0.85em';
    p.style.opacity = '0.7';

    var a = document.createElement('a');
    a.href = 'https://db-ip.com';
    a.rel = 'noopener';
    a.textContent = 'IP Geolocation by DB-IP';

    p.appendChild(a);
    document.body.appendChild(p);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', addAttribution);
  } else {
    addAttribution();
  }
})();
```

- [ ] **Step 4: Add the flag**

In the `goaccess` service's `command:` in `compose.yaml`, add one line immediately before `--html-report-title`:

```yaml
              --html-custom-js=attribution.js \
```

The path is relative on purpose — GoAccess writes it into the `<script src>` verbatim, and the browser resolves it against the report URL.

- [ ] **Step 5: Deploy it in `update.sh`**

In `update.sh`, immediately after the existing `mkdir -p logs report` line, add:

```sh
# GoAccess references this as <script src='attribution.js'>, resolved against the report
# URL — so it belongs next to index.html, not with the infra files above. report/ is
# git-ignored, hence the fetch here rather than at the top with the others.
curl -fsSL "$BASE/attribution.js" -o report/attribution.js
```

- [ ] **Step 6: Run the check to verify it passes**

```bash
sh /tmp/check-attribution.sh
```

Expected: `PASS`.

- [ ] **Step 7: Commit**

```bash
git add attribution.js compose.yaml update.sh
git commit -m "feat: satisfy DB-IP's CC-BY attribution requirement in the report"
```

---

### Task 4: Operator documentation

**Files:**
- Modify: `README.md` (a geo subsection under `## Monitoring`, after the paragraph ending *"…only average and max."*)

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the failing check**

Save as `/tmp/check-geo-docs.sh` (not committed):

```bash
#!/usr/bin/env sh
# Asserts the README documents what geo resolves, where the data comes from,
# how to force a refresh, and the one-time migration — with the exact commands.
set -eu
cd "$(git rev-parse --show-toplevel)"

fail=0
check () {
  grep -qF -- "$1" README.md || { echo "FAIL: README does not mention: $1"; fail=1; }
}
check 'DB-IP'
check 'CC-BY'
check 'edge-geoip'
check 'docker restart edge-geoip'
check 'docker volume rm edge-caddy_goaccess-db'
check 'country'

echo "--- the migration must be marked one-time, not part of update.sh ---"
grep -qiF 'once' README.md || { echo "FAIL: the migration is not marked as one-time"; fail=1; }

echo "--- no city claim ---"
grep -qiE 'cit(y|ies) (are|is) (shown|resolved|available)' README.md \
  && { echo "FAIL: README claims city resolution, which this does not provide"; fail=1; }

[ "$fail" = 0 ] || exit 1
echo "PASS"
```

- [ ] **Step 2: Run the check to verify it fails**

```bash
sh /tmp/check-geo-docs.sh
```

Expected: `FAIL: README does not mention: DB-IP`.

- [ ] **Step 3: Add the geo subsection**

In `README.md`, insert this immediately after the paragraph ending *"only average and max."* and before the *"Ad-hoc queries against the raw log"* paragraph:

```markdown
### Geo data

The dashboard resolves the **country** of each request — not the city, and not the
provider. The `edge-geoip` container keeps a DB-IP Country Lite database in the
`geoip-data` volume, checking daily and downloading a new one each month. GoAccess
picks up a replaced database on its next 5-minute pass, with no restart.

The database is licensed **CC-BY 4.0**, which requires the *IP Geolocation by DB-IP*
link that `report/attribution.js` adds to the bottom of the report. Do not remove it.

Client IPs are masked (`/24` IPv4, `/48` IPv6) before they are ever written, so a country
is the most this can resolve — which is also why no city database is installed. VPN and
cloud traffic resolves to the exit node, so a scanner in `eu-central-1` counts as Germany.

Force a refresh, e.g. after a failed download:

```bash
docker restart edge-geoip
```

Then watch it work — a failed download leaves the previous database in place and
retries hourly, and nothing alerts:

```bash
docker logs --tail 20 edge-geoip
```

**One-time migration when enabling geo.** GoAccess resolves countries at parse time, so
records already aggregated in `goaccess-db` never gain one. Run this **once**, and never
from `update.sh` — there it would discard the accumulated history on every deploy:

```bash
docker compose stop goaccess && docker volume rm edge-caddy_goaccess-db && ./update.sh
```

That re-parses the current `access.log` with geo. Data from already-rotated logs is gone
as far as countries are concerned.
```

- [ ] **Step 4: Run the check to verify it passes**

```bash
sh /tmp/check-geo-docs.sh
```

Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: document geo resolution, its licence, and the one-time migration"
```

---

## Deployment (operator, after merge)

Not a task — this is what the operator runs on the server once the branch is merged.

1. `./update.sh` — pulls `alpine:3` and creates the `geoip` service. This first run does
   **not** fetch `attribution.js`: `update.sh` replaces itself with `mv`, a rename, so the
   shell already executing it finishes the *old* script to completion — which has no fetch
   for a file it does not know exists yet. `attribution.js` only lands on a second run.
2. `docker logs edge-geoip` — expect `geoip: installed YYYY-MM (…bytes)` within a minute.
3. Wait one 5-minute pass, then confirm the *Geo Location* panel on `stats.unividuell.org` is populated.
4. Run the one-time migration from the README's *Geo data* section —
   `docker compose rm -sf goaccess && docker volume rm edge-caddy_goaccess-db && ./update.sh`
   — so the existing `access.log` is re-parsed with countries. This is also the second
   `./update.sh` run, and the one that finally fetches `attribution.js` into `report/`.
5. Confirm the *IP Geolocation by DB-IP* link renders at the bottom of the report — this
   cannot resolve before step 4's second run.

## Spec verification coverage

The spec's Verification section, mapped to where each item is covered:

| Spec check | Covered by |
| --- | --- |
| 1. Compose renders as intended | Task 1, check step 2 |
| 2. The download works | Task 1, check steps 3–4 |
| 3. The guard works | Task 2, check step 3 branch A |
| 4. Geo actually resolves | Task 2, check step 3 branch B; deployment step 3 |
| 5. The attribution renders | Task 3, check steps 1/4; deployment step 5 |
| 6. The re-parse took effect | Deployment step 4 (operator, needs the live server) |
| 7. The monthly swap needs no restart | Task 2 step 4's per-pass flag construction; observable on the server at the next month boundary |
| 8. Nothing else regressed | Task 2, check step 3 (other panels still emitted); deployment step 3 |
