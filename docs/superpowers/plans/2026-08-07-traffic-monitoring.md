# Edge Traffic Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make edge traffic visible — which domain gets the requests, which status codes, which user agents, how long requests take — via Caddy JSON access logs rendered by GoAccess into a password-protected dashboard.

**Architecture:** Caddy writes one anonymised JSON access log for all sites. A second container runs GoAccess every 5 minutes over that file, keeping cumulative aggregates in its own database, and renders a static HTML report. Caddy serves that report at `stats.unividuell.org` behind basic auth with several possible users. Along the way, all basic-auth usernames move out of the public repo into the environment.

**Tech Stack:** Caddy 2 (`caddy:2-alpine`), GoAccess (`allinurl/goaccess:latest`), Docker Compose.

**Spec:** [`docs/superpowers/specs/2026-08-07-traffic-monitoring-design.md`](../specs/2026-08-07-traffic-monitoring-design.md)

## Global Constraints

- **The repo is public.** No password, hash, or username may be committed. Secrets live only in `.env` on the server, which is git-ignored. The one exception is the placeholder hash below, which has no known password.
- **`.env` hashes must be single-quoted.** Docker Compose interpolates `$` in `.env` values; a bcrypt hash contains three `$`. Verified: unquoted *and* double-quoted both truncate to `$2a$14`; only single quotes survive intact.
- **A Caddy bcrypt hash is exactly 60 characters.** This is the check for the above.
- **`{$VAR}` in the Caddyfile reads the container's environment**, not `.env`. Every variable must also appear under the edge service's `environment:` in `compose.yaml`.
- **`{$VAR}` resolves at `caddy adapt` time.** A missing variable fails adaptation. Because `compose.yaml` changes in this work, the edge container is *recreated*, so a bad `.env` takes all sites down — not just a failed reload.
- **A basic-auth slot may never be empty.** Verified: `caddy adapt` fails with *"username and password cannot be empty or missing"*. Unused stats slots get a Compose `:-` default instead.
- **Placeholder credential for unused stats slots** (well-formed, 60 chars, no known password — safe to commit):
  `$2a$14$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu`
  In `compose.yaml` each `$` must be written `$$`.
- **Every site block needs `log access`.** Verified: without it, the adapted config routes that host into `skip_hosts` and emits no access records, regardless of the global block.
- **GoAccess must read the log as a mounted file, never piped.** Its inode/timestamp dedup only works on direct file input; piped input duplicates entries.
- **Local verification cannot use bind mounts.** Docker Desktop on this machine denies mounts from both `/private/tmp` and the repo directory (`mounts denied`). Local checks use stdin, `docker cp`, and named volumes. This is a *local* constraint only — the server is Linux and `compose.yaml` uses bind mounts normally. Do not restructure `compose.yaml` to work around it.
- **Do not parse adapted JSON with a naive regex.** `json.dumps` inserts a space after each colon, so `"username":"x"` never matches. The checks below walk the parsed structure instead.
- **Indentation is tabs** in `Caddyfile`, matching the existing file. `compose.yaml` uses two spaces.

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `Caddyfile` | routing, TLS, logging, auth | global `access` logger; `log access` per site; env-ified usernames; new `stats` site with three credential slots |
| `compose.yaml` | container topology | env passthrough incl. slot defaults; `report` mount; `goaccess` service; `goaccess-db` volume |
| `update.sh` | server-side deploy | preflight `.env` validation; create `report/` |
| `.env.example` | secret template | all variables + the single-quote rule |
| `.gitignore` | keep artefacts out | add `report/` |
| `README.md` | operator docs | new route, monitoring section, env vars, adding a stats user |

---

### Task 1: Access logging for every site

**Files:**
- Modify: `Caddyfile` (global block + all four site blocks)

**Interfaces:**
- Consumes: nothing.
- Produces: a logger named `access` writing `/var/log/caddy/access.log` as filtered JSON; every existing site routed to it. Task 3 adds the `stats` site to the same logger; Task 4's GoAccess service consumes the file at `./logs/access.log`.

- [ ] **Step 1: Write the failing check**

Save as `/tmp/check-logging.sh` (not committed). The `BASIC_AUTH_HASH` line is needed because the news site still uses it at this point — Task 2 removes it.

```bash
#!/usr/bin/env sh
# Adapts the Caddyfile and asserts every site is wired to the `access` logger.
set -eu
docker run --rm -i \
  -e 'BASIC_AUTH_HASH=$2a$14$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu' \
  -e 'NEWS_AUTH_USER_1=futzi' \
  -e 'NEWS_AUTH_USER_2=tonnenbolzer' \
  -e 'NEWS_AUTH_HASH=$2a$14$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu' \
  -e 'STATS_AUTH_USER_1=unividuell' \
  -e 'STATS_AUTH_HASH_1=$2a$14$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu' \
  -e 'STATS_AUTH_USER_2=unused-slot-2' \
  -e 'STATS_AUTH_HASH_2=$2a$14$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu' \
  -e 'STATS_AUTH_USER_3=unused-slot-3' \
  -e 'STATS_AUTH_HASH_3=$2a$14$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu' \
  caddy:2-alpine sh -c 'cat > /tmp/C && caddy adapt --config /tmp/C' < Caddyfile \
| python3 -c '
import json, sys
srv = json.load(sys.stdin)["apps"]["http"]["servers"]["srv0"]
logs = srv.get("logs")
assert logs is not None, "FAIL: srv0 has no logs key - no access logging at all"
names = logs.get("logger_names", {})
expected = {
  "countdown.unividuell.org", "beta.countdown.unividuell.org",
  "mobility.unividuell.org", "news.zingler46.unividuell.org",
}
missing = expected - set(names)
assert not missing, "FAIL: not logging: %s" % sorted(missing)
for host, loggers in names.items():
    assert "access" in loggers, "FAIL: %s -> %s, expected access" % (host, loggers)
assert "skip_hosts" not in logs, "FAIL: skip_hosts present: %s" % logs["skip_hosts"]
print("PASS: all sites route to the access logger")
'
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
sh /tmp/check-logging.sh
```

Expected — note it is *not* the "no logs key" branch, because the news site already has its own log block today:

```
AssertionError: FAIL: not logging: ['beta.countdown.unividuell.org', 'countdown.unividuell.org', 'mobility.unividuell.org']
```

- [ ] **Step 3: Add the `access` logger to the global block**

In `Caddyfile`, directly after the existing `log { ... }` block and still inside the global `{ }`:

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

- [ ] **Step 4: Add `log access` to every site block**

Add `log access` as the first line inside each of the four site blocks. For `news.zingler46.unividuell.org`, **delete** its existing site-local log block:

```
	log {
		output file /var/log/caddy/news_zingler46_access.log {
			roll_size 10mb
			roll_keep 7
		}
	}
```

The four blocks become:

```
countdown.unividuell.org {
	log access
	reverse_proxy countdown-web:80
}

beta.countdown.unividuell.org {
	log access
	reverse_proxy countdown-staging-web:80
}

mobility.unividuell.org {
	log access
	reverse_proxy mobility-manager:8080
}

news.zingler46.unividuell.org {
	log access
	basic_auth {
		futzi {$BASIC_AUTH_HASH}
		tonnenbolzer {$BASIC_AUTH_HASH}
	}
	reverse_proxy comunio-news-app:8080
}
```

The news credentials still reference `BASIC_AUTH_HASH` — Task 2 changes that. Leave it alone so this task stays independently reviewable.

- [ ] **Step 5: Run the check to verify it passes**

```bash
sh /tmp/check-logging.sh
```

Expected: `PASS: all sites route to the access logger`

- [ ] **Step 6: Verify the emitted records at runtime**

This proves masking and header stripping actually work, not just that the config adapts. Bind mounts are denied locally, so the config goes in via `docker cp`:

```bash
cat > /tmp/probe.caddy <<'EOF'
{
	admin off
	auto_https off
	log access {
		output stdout
		format filter {
			wrap json
			request>remote_ip ip_mask 24 48
			request>client_ip ip_mask 24 48
			request>headers>Cookie delete
			request>headers>Authorization delete
		}
		include http.log.access
	}
}
http://probe.localhost {
	log access
	respond "ok"
}
EOF
docker rm -f caddy-probe 2>/dev/null
docker create --name caddy-probe -p 8897:80 caddy:2-alpine caddy run --config /etc/caddy/Caddyfile
docker cp /tmp/probe.caddy caddy-probe:/etc/caddy/Caddyfile
docker start caddy-probe
sleep 2
curl -s -o /dev/null -H 'Host: probe.localhost' -H 'Cookie: session=secret' -H 'Authorization: Bearer tok' -A 'PlanCheck/1.0' http://localhost:8897/x
sleep 1
docker logs caddy-probe 2>/dev/null | grep '"msg":"handled request"' | python3 -c '
import json, sys
e = json.loads(sys.stdin.readline())
r = e["request"]
assert r["client_ip"].endswith(".0"), "FAIL: client_ip not masked: %s" % r["client_ip"]
assert "Cookie" not in r["headers"], "FAIL: Cookie header was logged"
assert "Authorization" not in r["headers"], "FAIL: Authorization header was logged"
for f in ("host", "uri"):
    assert f in r, "FAIL: missing %s" % f
for f in ("status", "duration"):
    assert f in e, "FAIL: missing %s" % f
print("PASS: masked, stripped, and carries host/uri/status/duration")
'
docker rm -f caddy-probe
```

Expected: `PASS: masked, stripped, and carries host/uri/status/duration`

- [ ] **Step 7: Commit**

```bash
git add Caddyfile && git commit -m "feat: JSON access log with masked IPs for every site"
```

---

### Task 2: Move basic-auth credentials out of the public repo

**Files:**
- Modify: `Caddyfile` (news site block)
- Modify: `compose.yaml` (edge `environment:`)
- Modify: `.env.example`

**Interfaces:**
- Consumes: the site blocks from Task 1.
- Produces: environment variables `NEWS_AUTH_USER_1`, `NEWS_AUTH_USER_2`, `NEWS_AUTH_HASH`. Task 3 adds the `STATS_AUTH_*_N` slots to the same `environment:` list. `BASIC_AUTH_HASH` no longer exists after this task.

- [ ] **Step 1: Write the failing check**

Save as `/tmp/check-secrets.sh`:

```bash
#!/usr/bin/env sh
# Asserts no credential literals are committed and the env plumbing is complete.
set -eu
fail=0
for name in futzi tonnenbolzer; do
  if git grep -qF -- "$name" -- Caddyfile; then
    echo "FAIL: username '$name' is committed in Caddyfile"; fail=1
  fi
done
if git grep -qF -- 'BASIC_AUTH_HASH' -- Caddyfile compose.yaml .env.example; then
  echo "FAIL: BASIC_AUTH_HASH still referenced (renamed to NEWS_AUTH_HASH)"; fail=1
fi
for v in NEWS_AUTH_USER_1 NEWS_AUTH_USER_2 NEWS_AUTH_HASH; do
  git grep -qF -- "{\$$v}" -- Caddyfile || { echo "FAIL: Caddyfile lacks {\$$v}"; fail=1; }
  git grep -qF -- "$v=\${$v}" -- compose.yaml || { echo "FAIL: compose.yaml does not pass $v through"; fail=1; }
  git grep -qF -- "$v=" -- .env.example || { echo "FAIL: .env.example lacks $v"; fail=1; }
done
grep -qi 'single' .env.example || { echo "FAIL: .env.example does not document the single-quote rule"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: no credentials committed, env plumbing complete"
exit "$fail"
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
sh /tmp/check-secrets.sh
```

Expected: `FAIL: username 'futzi' is committed in Caddyfile`, plus failures for `BASIC_AUTH_HASH` and each missing variable.

- [ ] **Step 3: Replace the news credentials in `Caddyfile`**

```
news.zingler46.unividuell.org {
	log access
	basic_auth {
		{$NEWS_AUTH_USER_1} {$NEWS_AUTH_HASH}
		{$NEWS_AUTH_USER_2} {$NEWS_AUTH_HASH}
	}
	reverse_proxy comunio-news-app:8080
}
```

- [ ] **Step 4: Pass the variables through in `compose.yaml`**

Replace the edge service's `environment:` list:

```yaml
    environment:
      - NEWS_AUTH_USER_1=${NEWS_AUTH_USER_1}
      - NEWS_AUTH_USER_2=${NEWS_AUTH_USER_2}
      - NEWS_AUTH_HASH=${NEWS_AUTH_HASH}
```

- [ ] **Step 5: Rewrite `.env.example`**

```
# ==========================================================
#  edge-caddy secrets. NEVER commit this file (see .gitignore).
#
#  IMPORTANT: wrap every hash in SINGLE quotes.
#  Docker Compose interpolates '$' in .env values, and a bcrypt
#  hash contains three of them. Unquoted AND double-quoted both
#  truncate the hash to "$2a$14"; only single quotes survive.
#  A Caddy hash is always exactly 60 characters — that is the check,
#  and update.sh refuses to deploy if it is not.
#
#  Generate a hash with:
#    docker run --rm caddy:2-alpine caddy hash-password --plaintext '<password>'
# ==========================================================

# --- news.zingler46.unividuell.org (both users share one hash) ---
NEWS_AUTH_USER_1=
NEWS_AUTH_USER_2=
NEWS_AUTH_HASH=''

# --- stats.unividuell.org (traffic dashboard) ---
# Slot 1 is required. Slots 2 and 3 are optional: uncomment and fill a pair to
# add a user — no repo change needed. An unfilled slot falls back to a
# placeholder credential that nobody can log in with.
STATS_AUTH_USER_1=
STATS_AUTH_HASH_1=''

#STATS_AUTH_USER_2=
#STATS_AUTH_HASH_2=''

#STATS_AUTH_USER_3=
#STATS_AUTH_HASH_3=''
```

- [ ] **Step 6: Run the check to verify it passes**

```bash
sh /tmp/check-secrets.sh
```

Expected: `PASS: no credentials committed, env plumbing complete`

- [ ] **Step 7: Verify the config still adapts**

Remove the now-obsolete `-e 'BASIC_AUTH_HASH=...'` line from `/tmp/check-logging.sh` first, then:

```bash
sh /tmp/check-logging.sh
```

Expected: `PASS: all sites route to the access logger`

- [ ] **Step 8: Commit**

```bash
git add Caddyfile compose.yaml .env.example
git commit -m "refactor: move basic-auth usernames and hash into the environment"
```

---

### Task 3: The `stats` site with multiple credential slots

**Files:**
- Modify: `Caddyfile` (new site block)
- Modify: `compose.yaml` (report mount + `STATS_AUTH_*` passthrough with defaults)

**Interfaces:**
- Consumes: the `access` logger from Task 1, the env pattern from Task 2.
- Produces: `stats.unividuell.org` serving `/srv/report` behind basic auth with three slots (`STATS_AUTH_USER_1..3` / `STATS_AUTH_HASH_1..3`), backed by the host directory `./report`. Task 4's GoAccess service writes `index.html` into that directory.

- [ ] **Step 1: Write the failing check**

Save as `/tmp/check-stats.sh`:

```bash
#!/usr/bin/env sh
# Asserts the stats site exists with three slots, is authenticated, serves /srv/report.
set -eu
docker run --rm -i \
  -e 'NEWS_AUTH_USER_1=futzi' \
  -e 'NEWS_AUTH_USER_2=tonnenbolzer' \
  -e 'NEWS_AUTH_HASH=$2a$14$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu' \
  -e 'STATS_AUTH_USER_1=unividuell' \
  -e 'STATS_AUTH_HASH_1=$2a$14$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu' \
  -e 'STATS_AUTH_USER_2=unused-slot-2' \
  -e 'STATS_AUTH_HASH_2=$2a$14$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu' \
  -e 'STATS_AUTH_USER_3=unused-slot-3' \
  -e 'STATS_AUTH_HASH_3=$2a$14$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu' \
  caddy:2-alpine sh -c 'cat > /tmp/C && caddy adapt --config /tmp/C' < Caddyfile \
| python3 -c '
import json, sys

def find_stats(routes):
    for r in routes:
        if "stats.unividuell.org" in json.dumps(r.get("match", [])):
            return r
    return None

def accounts(node):
    if isinstance(node, dict):
        if "accounts" in node:
            return node["accounts"]
        for v in node.values():
            r = accounts(v)
            if r is not None:
                return r
    if isinstance(node, list):
        for v in node:
            r = accounts(v)
            if r is not None:
                return r
    return None

srv = json.load(sys.stdin)["apps"]["http"]["servers"]["srv0"]
route = find_stats(srv["routes"])
assert route is not None, "FAIL: no stats site"
accts = accounts(route)
assert accts, "FAIL: stats site has no basic-auth accounts"
users = [a["username"] for a in accts]
assert len(users) == 3, "FAIL: expected 3 credential slots, got %s" % users
assert "unividuell" in users, "FAIL: STATS_AUTH_USER_1 did not resolve: %s" % users
assert "/srv/report" in json.dumps(route), "FAIL: stats site does not serve /srv/report"
assert "access" in json.dumps(srv["logs"]["logger_names"].get("stats.unividuell.org", [])), \
    "FAIL: stats site not routed to the access logger"
print("PASS: stats site with %d slots, authenticated, serving /srv/report" % len(users))
'
grep -q './report:/srv/report:ro' compose.yaml || { echo "FAIL: compose.yaml does not mount ./report"; exit 1; }
for n in 1 2 3; do
  grep -q "STATS_AUTH_HASH_$n=" compose.yaml || { echo "FAIL: compose.yaml does not pass STATS_AUTH_HASH_$n"; exit 1; }
done
grep -q 'STATS_AUTH_HASH_2:-' compose.yaml || { echo "FAIL: slot 2 has no default, so an unset slot breaks adapt"; exit 1; }
echo "PASS: compose.yaml wiring present"
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
sh /tmp/check-stats.sh
```

Expected: `AssertionError: FAIL: no stats site`

- [ ] **Step 3: Add the site block to `Caddyfile`**

Append after the news block:

```
# traffic dashboard (GoAccess renders report/index.html; basicauth at the edge)
# Slot 1 is required; unused slots fall back to a placeholder via compose.yaml.
stats.unividuell.org {
	log access
	basic_auth {
		{$STATS_AUTH_USER_1} {$STATS_AUTH_HASH_1}
		{$STATS_AUTH_USER_2} {$STATS_AUTH_HASH_2}
		{$STATS_AUTH_USER_3} {$STATS_AUTH_HASH_3}
	}
	root * /srv/report
	file_server
}
```

- [ ] **Step 4: Wire `compose.yaml`**

Add to the edge service's `environment:` list. The `$$` is Compose's escape for a literal `$`; write it exactly as shown:

```yaml
      - STATS_AUTH_USER_1=${STATS_AUTH_USER_1}
      - STATS_AUTH_HASH_1=${STATS_AUTH_HASH_1}
      - STATS_AUTH_USER_2=${STATS_AUTH_USER_2:-unused-slot-2}
      - STATS_AUTH_HASH_2=${STATS_AUTH_HASH_2:-$$2a$$14$$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu}
      - STATS_AUTH_USER_3=${STATS_AUTH_USER_3:-unused-slot-3}
      - STATS_AUTH_HASH_3=${STATS_AUTH_HASH_3:-$$2a$$14$$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu}
```

Add to the edge service's `volumes:` list, after the `logs` line:

```yaml
      - ./report:/srv/report:ro
```

- [ ] **Step 5: Run the check to verify it passes**

```bash
sh /tmp/check-stats.sh
```

Expected: `PASS: stats site with 3 slots, authenticated, serving /srv/report` and `PASS: compose.yaml wiring present`

- [ ] **Step 6: Verify auth behaviour at runtime, including the unused slot**

An unused slot must grant nothing. This is the security-relevant check of the whole task:

```bash
REAL=$(docker run --rm caddy:2-alpine caddy hash-password --plaintext 'slot1-test-pw')
DUMMY='$2a$14$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu'
cat > /tmp/stats.caddy <<'EOF'
{
	admin off
	auto_https off
}
http://stats.localhost {
	basic_auth {
		{$STATS_AUTH_USER_1} {$STATS_AUTH_HASH_1}
		{$STATS_AUTH_USER_2} {$STATS_AUTH_HASH_2}
		{$STATS_AUTH_USER_3} {$STATS_AUTH_HASH_3}
	}
	root * /srv/report
	file_server
}
EOF
docker rm -f caddy-stats 2>/dev/null
docker create --name caddy-stats -p 8896:80 \
  -e "STATS_AUTH_USER_1=unividuell"   -e "STATS_AUTH_HASH_1=$REAL" \
  -e "STATS_AUTH_USER_2=unused-slot-2" -e "STATS_AUTH_HASH_2=$DUMMY" \
  -e "STATS_AUTH_USER_3=unused-slot-3" -e "STATS_AUTH_HASH_3=$DUMMY" \
  caddy:2-alpine caddy run --config /etc/caddy/Caddyfile
docker cp /tmp/stats.caddy caddy-stats:/etc/caddy/Caddyfile
docker start caddy-stats
sleep 2
docker exec caddy-stats sh -c 'mkdir -p /srv/report && echo "<h1>report</h1>" > /srv/report/index.html'
p () { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$@" -H 'Host: stats.localhost' http://localhost:8896/; }
echo "no creds            -> $(p)  (expect 401)"
echo "wrong creds         -> $(p -u wrong:wrong)  (expect 401)"
echo "real slot 1         -> $(p -u unividuell:slot1-test-pw)  (expect 200)"
echo "unused slot, empty  -> $(p -u unused-slot-2:)  (expect 401)"
echo "unused slot, guess  -> $(p -u unused-slot-2:unused)  (expect 401)"
echo "unused slot, hash   -> $(p -u "unused-slot-2:$DUMMY")  (expect 401)"
docker rm -f caddy-stats
```

Expected: `401`, `401`, `200`, `401`, `401`, `401`.

- [ ] **Step 7: Commit**

```bash
git add Caddyfile compose.yaml
git commit -m "feat: serve the traffic dashboard behind basic auth with multiple user slots"
```

---

### Task 4: The GoAccess service

**Files:**
- Modify: `compose.yaml` (new service + volume)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `./logs/access.log` written by Task 1; `./report` served by Task 3.
- Produces: `./report/index.html`, regenerated every 300 s; cumulative aggregates in the `goaccess-db` named volume.

- [ ] **Step 1: Verify the exact GoAccess invocation before wiring it in**

Confirms every flag works together against a real Caddy log, using named volumes because bind mounts are denied locally:

```bash
docker volume rm ga-plan-logs ga-plan-db ga-plan-report 2>/dev/null
docker volume create ga-plan-logs; docker volume create ga-plan-db; docker volume create ga-plan-report
docker run --rm -i -v ga-plan-logs:/logs alpine sh -c 'cat > /logs/access.log' <<'EOF'
{"level":"info","ts":1786000000.1,"logger":"http.log.access.access","msg":"handled request","request":{"remote_ip":"203.0.113.0","client_ip":"203.0.113.0","proto":"HTTP/1.1","method":"GET","host":"countdown.unividuell.org","uri":"/","headers":{"User-Agent":["Mozilla/5.0 (Macintosh) Chrome/120.0"]}},"bytes_read":0,"user_id":"","duration":0.031,"size":900,"status":200,"resp_headers":{}}
{"level":"info","ts":1786000001.2,"logger":"http.log.access.access","msg":"handled request","request":{"remote_ip":"198.51.100.0","client_ip":"198.51.100.0","proto":"HTTP/1.1","method":"GET","host":"mobility.unividuell.org","uri":"/nope","headers":{"User-Agent":["Googlebot/2.1 (+http://www.google.com/bot.html)"]}},"bytes_read":0,"user_id":"","duration":1.400,"size":120,"status":404,"resp_headers":{}}
EOF
docker run --rm -v ga-plan-logs:/logs:ro -v ga-plan-db:/db -v ga-plan-report:/report \
  --entrypoint /bin/sh allinurl/goaccess:latest -c '
    goaccess /logs/access.log \
      --log-format=CADDY --no-global-config --no-progress --tz=Europe/Berlin \
      --db-path=/db --restore --persist --real-os \
      --html-report-title="unividuell edge" \
      -o /report/.index.html.tmp \
    && mv /report/.index.html.tmp /report/index.html \
    && echo "generated: $(wc -c < /report/index.html) bytes" \
    && grep -c "countdown.unividuell.org" /report/index.html'
docker volume rm ga-plan-logs ga-plan-db ga-plan-report
```

Expected: a byte count well over 100000 and a non-zero grep count. If any flag is rejected, fix the command here before continuing.

- [ ] **Step 2: Add the service to `compose.yaml`**

Under `services:`, after the `caddy` service:

```yaml
  goaccess:
    image: allinurl/goaccess:latest
    container_name: edge-goaccess
    restart: unless-stopped
    # No network access needed — it only reads and writes files.
    network_mode: none
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        while :; do
          if [ -s /logs/access.log ]; then
            goaccess /logs/access.log \
              --log-format=CADDY \
              --no-global-config \
              --no-progress \
              --tz=Europe/Berlin \
              --db-path=/db \
              --restore --persist \
              --real-os \
              --html-report-title='unividuell edge' \
              -o /report/.index.html.tmp \
            && mv /report/.index.html.tmp /report/index.html
          fi
          sleep 300
        done
    volumes:
      - ./logs:/logs:ro
      - ./report:/report
      - goaccess-db:/db
```

Notes for the implementer:
- `-s` (not `-f`) skips a log file that exists but is still empty — a fresh deploy before the first request.
- Rendering to `.index.html.tmp` and then `mv`-ing is what stops Caddy serving a half-written page; `mv` within one filesystem is atomic.
- Crawlers are deliberately **not** filtered (`--ignore-crawlers` is intentionally absent) — bot traffic is part of what should be visible.

- [ ] **Step 3: Add the volume**

Extend the top-level `volumes:` block:

```yaml
volumes:
  caddy-data:
  caddy-config:
  goaccess-db:
```

- [ ] **Step 4: Ignore the generated report**

Append to `.gitignore`:

```
report/
```

- [ ] **Step 5: Verify the compose topology**

```bash
STATS_AUTH_USER_1=a STATS_AUTH_HASH_1=b \
NEWS_AUTH_USER_1=x NEWS_AUTH_USER_2=y NEWS_AUTH_HASH=z \
  docker compose -f compose.yaml config | python3 -c '
import sys, yaml
c = yaml.safe_load(sys.stdin)
svc = c["services"]
assert "goaccess" in svc, "FAIL: goaccess service missing"
g = svc["goaccess"]
assert g.get("network_mode") == "none", "FAIL: goaccess should have no network"
assert "goaccess-db" in c["volumes"], "FAIL: goaccess-db volume missing"
cmd = " ".join(g["command"]) if isinstance(g["command"], list) else g["command"]
for flag in ("--log-format=CADDY", "--restore", "--persist", "--db-path=/db", "--no-global-config"):
    assert flag in cmd, "FAIL: command missing %s" % flag
assert "/logs/access.log" in cmd, "FAIL: goaccess does not read the mounted file"
after = cmd.split("goaccess", 1)[1].split("&&", 1)[0]
assert "|" not in after, "FAIL: log appears to be piped, not read as a file"
mounts = [v.split(":")[1] for v in svc["caddy"]["volumes"] if v.startswith("./")]
assert "/srv/report" in mounts, "FAIL: edge does not mount the report dir"
env = svc["caddy"]["environment"]
env = env if isinstance(env, dict) else dict(e.split("=", 1) for e in env)
assert env.get("STATS_AUTH_USER_2") == "unused-slot-2", "FAIL: slot 2 default did not apply: %r" % env.get("STATS_AUTH_USER_2")
assert len(env.get("STATS_AUTH_HASH_2", "")) == 60, "FAIL: slot 2 placeholder hash is %d chars, expected 60" % len(env.get("STATS_AUTH_HASH_2", ""))
print("PASS: compose topology correct, slot defaults resolve")
'
git check-ignore -q report/ && echo "PASS: report/ is git-ignored"
```

Expected: `PASS: compose topology correct, slot defaults resolve` and `PASS: report/ is git-ignored`.

- [ ] **Step 6: Commit**

```bash
git add compose.yaml .gitignore
git commit -m "feat: render the traffic dashboard with a periodic GoAccess pass"
```

---

### Task 5: Deploy safety in `update.sh`

**Files:**
- Modify: `update.sh`

**Interfaces:**
- Consumes: the variable names established in Tasks 2 and 3.
- Produces: an aborting preflight check, so a bad `.env` fails loudly instead of recreating the edge container into an outage.

- [ ] **Step 1: Write the failing check**

Save as `/tmp/check-update.sh`:

```bash
#!/usr/bin/env sh
# Asserts update.sh refuses to deploy on an incomplete or badly-quoted .env.
set -eu
H="'\$2a\$14\$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu'"
tmp=$(mktemp -d); cp update.sh "$tmp/"; cd "$tmp"
mkdir -p bin
printf '#!/bin/sh\nexit 0\n' > bin/docker && chmod +x bin/docker
printf '#!/bin/sh\nexit 0\n' > bin/curl   && chmod +x bin/curl
export PATH="$tmp/bin:$PATH"
fail=0

valid () {
  printf "NEWS_AUTH_USER_1=futzi\nNEWS_AUTH_USER_2=tonnenbolzer\nNEWS_AUTH_HASH=%s\nSTATS_AUTH_USER_1=unividuell\nSTATS_AUTH_HASH_1=%s\n" "$H" "$H" > .env
}

valid
sh update.sh >/dev/null 2>&1 || { echo "FAIL: rejected a valid .env"; fail=1; }

valid; printf "STATS_AUTH_USER_2=bob\nSTATS_AUTH_HASH_2=%s\n" "$H" >> .env
sh update.sh >/dev/null 2>&1 || { echo "FAIL: rejected a valid .env with an optional slot filled"; fail=1; }

printf "NEWS_AUTH_USER_1=futzi\n" > .env
sh update.sh >/dev/null 2>&1 && { echo "FAIL: accepted an .env missing required variables"; fail=1; }

# Unquoted hash: compose would truncate it to 6 characters.
printf "NEWS_AUTH_USER_1=f\nNEWS_AUTH_USER_2=t\nNEWS_AUTH_HASH=\$2a\$14\nSTATS_AUTH_USER_1=u\nSTATS_AUTH_HASH_1=%s\n" "$H" > .env
sh update.sh >/dev/null 2>&1 && { echo "FAIL: accepted a truncated (unquoted) hash"; fail=1; }

# A filled optional slot with a broken hash must also be caught.
valid; printf "STATS_AUTH_USER_2=bob\nSTATS_AUTH_HASH_2=\$2a\$14\n" >> .env
sh update.sh >/dev/null 2>&1 && { echo "FAIL: accepted a truncated hash in an optional slot"; fail=1; }

cd - >/dev/null; rm -rf "$tmp"
[ "$fail" -eq 0 ] && echo "PASS: update.sh validates .env before deploying"
exit "$fail"
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
sh /tmp/check-update.sh
```

Expected: `FAIL: accepted an .env missing required variables`, `FAIL: accepted a truncated (unquoted) hash`, and `FAIL: accepted a truncated hash in an optional slot`.

- [ ] **Step 3: Add the preflight to `update.sh`**

Insert directly after the existing `if [ ! -f .env ] ... fi` block, before `docker network create edge`:

```sh
# Preflight. {$VAR} placeholders resolve at `caddy adapt` time, and compose.yaml
# changes recreate the edge container — so a bad .env is a site-wide outage, not a
# failed reload. Abort before touching anything.
missing=""
for v in NEWS_AUTH_USER_1 NEWS_AUTH_USER_2 NEWS_AUTH_HASH STATS_AUTH_USER_1 STATS_AUTH_HASH_1; do
  grep -qE "^${v}=.+" .env || missing="$missing $v"
done
if [ -n "$missing" ]; then
  echo "ERROR: .env is missing or empty for:$missing" >&2
  echo "Note: BASIC_AUTH_HASH was renamed to NEWS_AUTH_HASH." >&2
  exit 1
fi

# Compose interpolates '$' in .env values, so an unquoted bcrypt hash silently
# truncates. Caddy hashes are always 60 characters — check every hash that is set.
# Stats slots 2 and 3 are optional; skip them when absent or empty.
for v in NEWS_AUTH_HASH STATS_AUTH_HASH_1 STATS_AUTH_HASH_2 STATS_AUTH_HASH_3; do
  line=$(grep -E "^${v}=" .env | head -1) || true
  [ -z "$line" ] && continue
  val=$(printf '%s' "$line" | sed -E "s/^${v}=//; s/^'//; s/'\$//")
  [ -z "$val" ] && continue
  if [ "${#val}" -ne 60 ]; then
    echo "ERROR: $v is ${#val} characters, expected 60." >&2
    echo "Wrap the hash in SINGLE quotes in .env — double quotes do not help." >&2
    exit 1
  fi
done

mkdir -p logs report
```

- [ ] **Step 4: Run the check to verify it passes**

```bash
sh /tmp/check-update.sh
```

Expected: `PASS: update.sh validates .env before deploying`

- [ ] **Step 5: Commit**

```bash
git add update.sh
git commit -m "feat: validate .env before deploying the edge"
```

---

### Task 6: Operator documentation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Add the route**

Extend the Routes table:

```markdown
| `stats.unividuell.org` | *(static GoAccess report, basicauth)* |
```

- [ ] **Step 2: Replace the bootstrap credential paragraph**

The current text describes only `BASIC_AUTH_HASH`. Replace it with:

````markdown
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
````

- [ ] **Step 3: Add a Monitoring section**

Before the `## Certs` section:

````markdown
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
````

- [ ] **Step 4: Verify the docs match reality**

```bash
grep -q 'stats.unividuell.org' README.md && echo "PASS: route documented"
grep -q 'STATS_AUTH_HASH_1' README.md && echo "PASS: env vars documented"
grep -qi 'single quotes' README.md && echo "PASS: quoting rule documented"
grep -q '## Monitoring' README.md && echo "PASS: monitoring section present"
grep -qi 'Adding a dashboard user' README.md && echo "PASS: user-adding documented"
! grep -q 'BASIC_AUTH_HASH' README.md && echo "PASS: no stale variable name"
```

Expected: six `PASS` lines.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: document the traffic dashboard, credential slots, and the .env quoting rule"
```

---

## Deployment (operator, after merge)

Not part of the implementation tasks — this is what happens on the server.

1. Update `.env` **first**: move the old `BASIC_AUTH_HASH` value to `NEWS_AUTH_HASH`, add
   `NEWS_AUTH_USER_1` / `NEWS_AUTH_USER_2` and `STATS_AUTH_USER_1` / `STATS_AUTH_HASH_1`,
   single-quote every hash, and delete the old `BASIC_AUTH_HASH` line.
2. `cd /opt/unividuell/edge-caddy && ./update.sh` — the preflight aborts on a bad `.env`
   before anything is recreated.
3. Confirm, in order:
   - `news.zingler46.unividuell.org` still returns 401 without and 200 with credentials
     (regression check on a live site after the hash rename),
   - all four existing sites still serve,
   - `logs/access.log` grows and its records carry a masked `client_ip` and no
     `Cookie` / `Authorization` header,
   - after ~5 minutes `report/index.html` exists,
   - `stats.unividuell.org` returns 401 without credentials and the report with them,
   - the Virtual Hosts panel lists all five domains.
4. Note a hit count, wait ten minutes with no traffic, confirm it has not doubled.
