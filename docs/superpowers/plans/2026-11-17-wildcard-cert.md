# Wildcard Certificate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve every one-label `*.unividuell.org` site from one Let's Encrypt wildcard
certificate, obtained by DNS-01 through Cloudflare, behind a wildcard DNS record. A new
site then needs no DNS record, and its name never reaches a CT log.

**Architecture:** `update.sh` builds the edge image on the server from `caddy/Dockerfile`:
xcaddy with `caddy-dns/cloudflare` on `caddy:2-builder`, the binary copied onto
`caddy:2-alpine`. A `*.unividuell.org` site block obtains the wildcard with a scoped
Cloudflare token and aborts every name without a block of its own. Caddy ≥ 2.10 then
serves that certificate for every one-label site block instead of ordering one per name.
Certificate failures in Caddy's `system.log` reach Loki (only the `tls.*` lines) and are
mailed by a new Grafana alert.

**Tech Stack:** Caddy 2.11 (`caddy:2-builder`, `caddy:2-alpine`, xcaddy),
`github.com/caddy-dns/cloudflare`, Docker Compose v5, OpenTelemetry Collector 0.147
(filelog), Grafana alerting and Loki, Cloudflare DNS.

**Spec:** [`docs/superpowers/specs/2026-11-17-wildcard-cert-design.md`](../specs/2026-11-17-wildcard-cert-design.md)

## Global Constraints

- **Versions:** Caddy and the plugin track their latest release; nothing is pinned.
  - The Dockerfile uses `caddy:2-builder` and `caddy:2-alpine`, plus
    `ARG CF_PLUGIN_VERSION=latest` and `--with github.com/caddy-dns/cloudflare@${CF_PLUGIN_VERSION}`.
  - `update.sh` resolves the version from
    `https://proxy.golang.org/github.com/caddy-dns/cloudflare/@latest` (JSON field
    `Version`; `v0.2.4` on 2026-11-17).
- **Token, variable and placeholder:** the variable is `CLOUDFLARE_API_TOKEN`. In the
  Caddyfile it is `{env.CLOUDFLARE_API_TOKEN}`, read at runtime, not `{$…}`.
- **Token, scope:** Zone · Zone · Read and Zone · DNS · Edit, zone resources only
  `unividuell.org`, client IP filtering `158.101.161.126`, no expiry. The token never
  appears in a committed file; the repo is public.
- **Token, shape check:** the plugin checks the token's shape when Caddy provisions the
  config. It accepts `^[A-Za-z0-9_-]{35,50}$` or `^cf(ut|at)_[A-Za-z0-9_-]{32,256}$`.
  - An empty, quoted or space-padded token fails `caddy validate`, and fails a start too:
    the whole config, every site. Verified on a spike image.
  - The error message prints the token.
- **Wildcard coverage:** `*.unividuell.org` covers exactly one label.
  - `beta.countdown.` keeps its own HTTP-01 certificate and is not touched here; the
    countdown project renames it soon.
  - `news.zingler46.` leaves the edge in Task 1: its site block plus `NEWS_AUTH_USER_1`,
    `NEWS_AUTH_USER_2` and `NEWS_AUTH_HASH`.
  - The comunio-news stack under `/opt/unividuell/comunio-news/` is not touched, and
    neither are the `NEWS_*` lines in the server's `.env`.
- **Wildcard preference is decided at runtime.** Verified on Caddy v2.11.9: with the
  wildcard block present, Caddy obtains the wildcard and nothing for the one-label hosts.
  The spike still had the news block, so it obtained `*.unividuell.org`, `beta.countdown.`
  and `news.zingler46.`. After Task 1 only `*.unividuell.org` and
  `beta.countdown.unividuell.org` remain.
  - `caddy adapt` still lists the one-label hosts in the HTTP-01 policy. Check the
    preference in the runtime log, not in adapted JSON.
- **Failure log shape:** Caddy logs a failed issuance as
  `"level":"error","logger":"tls.obtain","msg":"could not get certificate from issuer"`;
  renewals log under `tls.renew`.
- **What reaches Loki from `system.log`:**
  - Only lines whose logger starts with `tls.` may be shipped. The file also carries
    `http.log.error` lines with unmasked client IPs.
  - The stream carries no `deployment.environment.name`, so the existing "Fehler im Log"
    rule (production only) never sees it.
- **Local checks:**
  - Docker Desktop denies bind mounts, so use stdin and `docker cp`.
  - Check scripts live in
    `CHECKS=/private/tmp/claude-501/-opt-unividuell-projects-edge-caddy--claude-worktrees-wildcard-cert-dns-setup-90bc6e/addde845-8e7b-4e86-8b4d-2b1bd03d914c/scratchpad/checks`,
    not in the repo.
  - `yq` and `jq` are installed locally.
- **The server:**
  - aarch64, Docker Compose v5.7.1 (`pull --ignore-buildable` exists).
  - The collector is `/otel-lgtm/otelcol-contrib/otelcol-contrib` 0.147.0 inside
    `edge-lgtm`. Validating needs `--feature-gates=service.profilesSupport`.
- **Rollout:** nothing on the server is productive. One deploy, a hard switch, a brief
  outage is accepted.
- **Deploy source:** `update.sh` fetches from `main`, so merge before deploying.
- **Formatting:** tabs in `Caddyfile`, two spaces in YAML.
- **Commits:** messages in `feat:` / `docs:` style, ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **`news.zingler46.` resolves to the server again through the wildcard.** HTTPS must
   fail in the TLS handshake: no certificate, no comunio-news, no basic-auth prompt.
   Pinned in Task 4, step 8.
2. **The DNS-01 propagation check times out inside the container**
   (`timed out waiting for record to fully propagate`). No one-label site would have a
   certificate. Expected: `*.unividuell.org` obtained within 5 minutes. Pinned in Task 4,
   step 7, with the fix.
3. **The latest Caddy and the latest plugin do not build together.** `update.sh` must
   stop before `run` and `up`, so the running edge stays untouched. Pinned in Task 2's
   check.
4. **proxy.golang.org is unreachable.** The build still runs, with `latest`. Pinned in
   Task 2's check.
5. **A pasted token has quotes, braces or trailing whitespace.** `caddy validate` must
   fail, and nothing gets deployed. Pinned in Task 1's check.

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `caddy/Dockerfile` | the edge image | new: xcaddy build with the Cloudflare plugin |
| `compose.yaml` | caddy service | build from `./caddy`, image `edge-caddy:local`, token env |
| `Caddyfile` | routing, TLS | `*.unividuell.org` block; `news.zingler46.` block removed |
| `update.sh` | deploy | fetch Dockerfile, require token and no longer `NEWS_*`, `pull --ignore-buildable`, resolve plugin version, build |
| `.env.example` | secret template | token section; news section removed |
| `monitoring/otelcol-config.yaml` | log shipping | `filelog/caddy-tls` receiver in the `logs` pipeline |
| `monitoring/grafana-alerting.yaml` | alerts | rule `edge-cert` |
| `README.md` | operator docs | intro, Certs, Add a new site, Update, `.env` table, monitoring |

---

### Task 1: Edge image with the Cloudflare plugin, wildcard site block

**Files:**
- Create: `caddy/Dockerfile`
- Modify: `compose.yaml` (service `caddy`), `Caddyfile`, `README.md` (intro, "Routes", "Add a new site", "Certs")
- Commit with it: the spec and this plan

**Interfaces:**
- Produces:
  - image `edge-caddy:local`, built from context `./caddy` with build arg
    `CF_PLUGIN_VERSION` (default `latest`)
  - `CLOUDFLARE_API_TOKEN` in the caddy service's environment
  - Caddy module `dns.providers.cloudflare`

- [ ] **Step 1: Write the check `$CHECKS/check-caddy.sh`**

```sh
#!/usr/bin/env sh
# usage (repo root): sh $CHECKS/check-caddy.sh <image>
# The image must validate the real Caddyfile with a well-formed token and reject bad ones.
set -u
img=$1
H='$2a$14$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu'
T=dummydummydummydummydummydummydummydummy
v () { docker run --rm -i -e STATS_AUTH_USER=s -e "STATS_AUTH_HASH=$H" -e "CLOUDFLARE_API_TOKEN=$1" "$img" \
  caddy validate --adapter caddyfile --config /dev/stdin < Caddyfile >/dev/null 2>&1; }
fail=0
grep -q '^\*\.unividuell\.org {' Caddyfile || { echo "FAIL: no wildcard site block"; fail=1; }
grep -q -e zingler -e NEWS_AUTH Caddyfile compose.yaml && { echo "FAIL: news.zingler46 still on the edge"; fail=1; }
v "$T"      || { echo "FAIL: rejected a well-formed token"; fail=1; }
v "cfut_$T" || { echo "FAIL: rejected a new-format token"; fail=1; }
v "'$T'"    && { echo "FAIL: accepted a quoted token"; fail=1; }
v ""        && { echo "FAIL: accepted an empty token"; fail=1; }
v "{$T}"    && { echo "FAIL: accepted a braced token"; fail=1; }
v "$T "     && { echo "FAIL: accepted a token with a trailing space"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: $img validates the Caddyfile"
exit "$fail"
```

- [ ] **Step 2: Run it against the official image**

Run: `sh $CHECKS/check-caddy.sh caddy:2-alpine`
Expected:
- `FAIL: no wildcard site block`
- `FAIL: news.zingler46 still on the edge`
- `FAIL: rejected a well-formed token`
- `FAIL: rejected a new-format token`

The check passes no `NEWS_*`, so the news block's empty `basic_auth` fails every
validation.

- [ ] **Step 3: Replace the news block with the wildcard block**

- Delete the `news.zingler46.unividuell.org` block and its comment from `Caddyfile`.
- Delete the three `NEWS_AUTH_*` lines from the caddy service's `environment` in
  `compose.yaml`.
- Add this block to `Caddyfile`, directly after the global options:

```
*.unividuell.org {
	tls {
		dns cloudflare {env.CLOUDFLARE_API_TOKEN}
	}
	abort
}
```

Its comment states:
- This is one certificate for every one-label site. Caddy ≥ 2.10 uses it instead of
  ordering one per name, so new names stay out of CT logs.
- DNS-01 runs through the Cloudflare token in `.env`.
- A name without a block of its own gets a TLS handshake, then a closed connection.
- There is no `log access` here, so the per-host panels show only real sites.
- Two-label names are not covered: they get no certificate and fail in the handshake.
  Only `beta.countdown.` has a block of its own, until countdown renames it.

- [ ] **Step 4: Run the check against the official image again**

Run: `sh $CHECKS/check-caddy.sh caddy:2-alpine`
Expected: only `FAIL: rejected a well-formed token` and `FAIL: rejected a new-format token`.
`caddy validate` now reports `module not registered: dns.providers.cloudflare`.

- [ ] **Step 5: Create `caddy/Dockerfile`**

```dockerfile
FROM caddy:2-builder AS builder
ARG CF_PLUGIN_VERSION=latest
RUN xcaddy build --with github.com/caddy-dns/cloudflare@${CF_PLUGIN_VERSION}

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

Its header comment states:
- Why the image is built: the wildcard needs the DNS plugin.
- Both bases and the plugin follow latest, and `update.sh` passes the resolved plugin
  version.

- [ ] **Step 6: Switch the compose service `caddy` to the build**

- Replace `image: caddy:2-alpine` with `build: ./caddy` and `image: edge-caddy:local`.
- Add `- CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}` to its `environment`.
- The comment says the context is `./caddy` on purpose. The server directory holds `.env`,
  `logs/` and `filetransfer/`, and a `.` context would ship all of them to the builder.

- [ ] **Step 7: Build locally and check what compose resolves**

Run: `docker build --pull -t edge-caddy:local caddy && docker run --rm edge-caddy:local caddy list-modules | grep dns.providers`
Expected: `dns.providers.cloudflare`. The build takes about 2–3 minutes.

Run: `docker compose --env-file /dev/null -f compose.yaml config --format json 2>/dev/null | jq -c '.services.caddy | {ctx: .build.context, image}'`
Expected: `ctx` ends in `/caddy`, `image` is `"edge-caddy:local"`.

- [ ] **Step 8: Run the check against the built image**

Run: `sh $CHECKS/check-caddy.sh edge-caddy:local`
Expected: `PASS: edge-caddy:local validates the Caddyfile`

- [ ] **Step 9: Write and run the runtime check `$CHECKS/check-managed.sh`**

It runs the image for 40 s against the Let's Encrypt **staging** CA with a dummy token
(Cloudflare answers 403, nothing changes in DNS). Then it lists the names Caddy tried to
obtain.

```sh
#!/usr/bin/env sh
# usage (repo root): sh $CHECKS/check-managed.sh <image>
set -u
img=$1; tmp=$(mktemp -d)
H='$2a$14$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu'
sed 's#^\temail .*#\tacme_ca https://acme-staging-v02.api.letsencrypt.org/directory#' Caddyfile > "$tmp/Caddyfile"
docker rm -f managed-check >/dev/null 2>&1
docker create --name managed-check -e STATS_AUTH_USER=s -e "STATS_AUTH_HASH=$H" \
  -e CLOUDFLARE_API_TOKEN=dummydummydummydummydummydummydummydummy "$img" >/dev/null
docker cp "$tmp/Caddyfile" managed-check:/etc/caddy/Caddyfile
docker start managed-check >/dev/null; sleep 40
docker cp managed-check:/var/log/caddy/system.log "$tmp/system.log"; docker rm -f managed-check >/dev/null
got=$(jq -r 'select(.msg=="obtaining certificate") | .identifier' "$tmp/system.log" | sort -u | tr '\n' ' ')
want='*.unividuell.org beta.countdown.unividuell.org '
[ "$got" = "$want" ] && echo "PASS: Caddy manages only $want" || { echo "FAIL: Caddy manages: $got"; exit 1; }
```

Run: `sh $CHECKS/check-managed.sh edge-caddy:local`
Expected: `PASS: Caddy manages only *.unividuell.org beta.countdown.unividuell.org`

- [ ] **Step 10: Update `README.md`**

- **Intro (lines 8–9):** the edge image is built on the server from `caddy/Dockerfile`
  (`caddy:2-alpine` plus the Cloudflare DNS plugin), not pulled.
- **"Routes":** remove the `news.zingler46.unividuell.org` row.
- **"Certs":** rewrite it to say:
  - Every one-label name uses the one wildcard certificate (DNS-01, Cloudflare token).
  - DNS has a `*` A record to `158.101.161.126`, DNS only.
  - The CT logs show only `*.unividuell.org` for new names; names issued before are
    public for good.
  - Sites use one-label names only. `beta.countdown.` is the last two-label name, with
    its own certificate and CT entry, until countdown renames it.
  - The explicit A records stay until then: while `beta.countdown` has one, `countdown`
    without its own record would be an empty node, and the wildcard does not answer for
    those.
  - Unknown one-label names get a closed connection. Two-label names fail in the
    handshake.
  - Certificates live in the `caddy-data` volume.
- **"Add a new site":**
  - Pick a one-label name: no Cloudflare record and no certificate are needed.
  - Drop "Caddy obtains the cert on first request".

- [ ] **Step 11: Commit**

```bash
git add caddy/Dockerfile compose.yaml Caddyfile README.md docs/superpowers/specs/2026-11-17-wildcard-cert-design.md docs/superpowers/plans/2026-11-17-wildcard-cert.md
git commit -m "feat: wildcard certificate for *.unividuell.org via Cloudflare DNS-01"
```

---

### Task 2: `update.sh` builds the edge image and requires the token

**Files:**
- Modify: `update.sh`, `.env.example`, `README.md` ("Bootstrap" `.env` table and hash example, "Update")

**Interfaces:**
- Consumes (from Task 1):
  - compose service `caddy` with `build: ./caddy` and `image: edge-caddy:local`
  - build arg `CF_PLUGIN_VERSION`
  - repo path `caddy/Dockerfile`

- [ ] **Step 1: Write the check `$CHECKS/check-update.sh`**

It runs `update.sh` in a sandbox. `curl` serves files from this checkout (or fakes the Go
proxy), and `docker` only logs its arguments.

```sh
#!/usr/bin/env sh
# usage (repo root): sh $CHECKS/check-update.sh
set -u
repo=$(pwd); fail=0
H="'\$2a\$14\$DDDDDDDDDDDDDDDDDDDDDDuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu'"
BASE_ENV="STATS_AUTH_USER=s
STATS_AUTH_HASH=$H
COUNTDOWN_DB_MONITOR_PASSWORD=x
ALERT_SMTP_USER=x
ALERT_SMTP_PASSWORD=x
ALERT_EMAIL_TO=x"
TOKEN=CLOUDFLARE_API_TOKEN=dummydummydummydummydummydummydummydummy

# run <env> [proxy-down] [build-fails]  ->  sets $d (sandbox) and $rc
run () {
  d=$(mktemp -d); mkdir -p "$d/bin"; cp update.sh "$d/"
  cat > "$d/bin/curl" <<EOF
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift 2;; -*) shift;; *) url=\$1; shift;; esac; done
case "\$url" in
  https://proxy.golang.org/*) [ "${2:-}" = proxy-down ] && exit 22; echo '{"Version":"v9.9.9","Time":"2026-01-01T00:00:00Z"}';;
  */unividuell/edge-caddy/main/*) cp "$repo/\${url#*/main/}" "\$out";;
  *) exit 22;;
esac
EOF
  cat > "$d/bin/docker" <<EOF
#!/bin/sh
echo "\$*" >> "$d/docker.log"
case " \$* " in *" build "*) [ "${3:-}" = build-fails ] && exit 1;; esac
exit 0
EOF
  chmod +x "$d/bin/curl" "$d/bin/docker"; : > "$d/docker.log"
  printf '%s\n' "$1" > "$d/.env"
  (cd "$d" && PATH="$d/bin:$PATH" sh update.sh > out.log 2>&1); rc=$?
}
line () { grep -n -F -- "$1" "$d/docker.log" | head -1 | cut -d: -f1; }

run "$BASE_ENV
$TOKEN"
[ "$rc" -eq 0 ] || { echo "FAIL: valid .env rejected (rc $rc)"; fail=1; }
[ -s "$d/caddy/Dockerfile" ] || { echo "FAIL: caddy/Dockerfile not fetched"; fail=1; }
p=$(line "pull --ignore-buildable"); b=$(line "build --pull --build-arg CF_PLUGIN_VERSION=v9.9.9 caddy")
r=$(line "run --rm --no-deps"); u=$(line "up -d")
[ -n "$p" ] && [ -n "$b" ] && [ -n "$r" ] && [ -n "$u" ] && [ "$p" -lt "$b" ] && [ "$b" -lt "$r" ] && [ "$r" -lt "$u" ] \
  || { echo "FAIL: expected pull --ignore-buildable < build v9.9.9 < validate run < up -d"; fail=1; }

for e in "$BASE_ENV" "$BASE_ENV
CLOUDFLARE_API_TOKEN="; do
  run "$e"
  [ "$rc" -ne 0 ] && grep -q CLOUDFLARE_API_TOKEN "$d/out.log" && [ -z "$(line ' build ')" ] && [ -z "$(line 'up -d')" ] \
    || { echo "FAIL: missing/empty token not rejected before building"; fail=1; }
done

run "$BASE_ENV
$TOKEN" proxy-down
[ "$rc" -eq 0 ] && [ -n "$(line 'CF_PLUGIN_VERSION=latest caddy')" ] || { echo "FAIL: no fallback to latest"; fail=1; }

run "$BASE_ENV
$TOKEN" "" build-fails
[ "$rc" -ne 0 ] && [ -z "$(line 'run --rm')" ] && [ -z "$(line 'up -d')" ] || { echo "FAIL: failed build did not stop the update"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: update.sh builds the edge image safely"
exit "$fail"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `sh $CHECKS/check-update.sh`
Expected:
- `FAIL: valid .env rejected`. The `.env` holds no `NEWS_*`, and the old preflight still
  requires them.
- `FAIL: caddy/Dockerfile not fetched`
- the order line
- both "missing/empty token" lines
- `no fallback to latest`

The build-fails case passes vacuously for now, because the preflight stops first.

- [ ] **Step 3: Change `update.sh`**

- **After the self-restart block:** `mkdir -p caddy` and
  `curl -fsSL "$BASE/caddy/Dockerfile" -o caddy/Dockerfile`, under a short "Edge image"
  comment.
- **Required variables:**
  - Add `CLOUDFLARE_API_TOKEN` to the loop. The error output adds a hint pointing to the
    token section in `.env.example`.
  - Remove `NEWS_AUTH_USER_1` and `NEWS_AUTH_USER_2` from the loop, and `NEWS_AUTH_HASH`
    from the `check_hash` loop.
  - Remove the note `BASIC_AUTH_HASH was renamed to NEWS_AUTH_HASH`.
  - The `hash_help` example becomes `STATS_AUTH_HASH='$2a$14$…'`.
- **Pull and build:** replace the `pull` line with these lines:

```sh
docker compose --env-file .env -f compose.yaml pull --ignore-buildable
CF_PLUGIN_VERSION=$(curl -fsSL https://proxy.golang.org/github.com/caddy-dns/cloudflare/@latest | sed -n 's/.*"Version":"\([^"]*\)".*/\1/p')
CF_PLUGIN_VERSION=${CF_PLUGIN_VERSION:-latest}
echo "Building the edge image with caddy-dns/cloudflare $CF_PLUGIN_VERSION ..."
docker compose --env-file .env -f compose.yaml build --pull --build-arg CF_PLUGIN_VERSION="$CF_PLUGIN_VERSION" caddy
```

  The comment above it explains the resolved version:
  - A new plugin release busts the build cache, just as `--pull` does for a new Caddy.
  - If neither changed, the cached image stays, and `up -d` leaves the running container
    alone.
  - Without the proxy, the build falls back to `latest`.
- **Validation gate comment:** extend it. The gate now also catches a malformed token, and
  an image without the plugin.

- [ ] **Step 4: Change `.env.example`**

- Remove the `news.zingler46` section.
- The header's hash example becomes `STATS_AUTH_HASH='…'`.
- Add the token section after the stats block, headed
  `# --- wildcard certificate *.unividuell.org (required) ---`.
- Where to create the token: dash.cloudflare.com → My Profile → API Tokens.
- The permissions, zone and IP filter from Global Constraints.
- Unquoted, no `$`.
- Caddy refuses a malformed token, and with it the whole edge.
- `CLOUDFLARE_API_TOKEN=`

- [ ] **Step 5: Run the check and a syntax check**

Run: `sh $CHECKS/check-update.sh && sh -n update.sh && echo SYNTAX-OK`
Expected: `PASS: update.sh builds the edge image safely` and `SYNTAX-OK`

- [ ] **Step 6: Update `README.md`**

- **`.env` table:**
  - Remove the two `NEWS_AUTH_*` rows.
  - Add a `CLOUDFLARE_API_TOKEN` row: the Cloudflare token for the wildcard certificate
    (required), with a pointer to `.env.example` for the scope.
- **Hash-quoting example below the table:** `STATS_AUTH_HASH='$2a$14$…'`.
- **"Update", step 2:** pulls `edge-lgtm` and builds the edge image from
  `caddy/Dockerfile` with the latest Caddy and plugin. That takes about 2–3 minutes when
  either changed and is cached otherwise.
- **"Update", fetched files:** add `caddy/Dockerfile` to the list.

- [ ] **Step 7: Commit**

```bash
git add update.sh .env.example README.md
git commit -m "feat: update.sh builds the edge image and requires the Cloudflare token"
```

---

### Task 3: Mail when Caddy cannot get a certificate

**Files:**
- Modify: `monitoring/otelcol-config.yaml`, `monitoring/grafana-alerting.yaml`, `README.md` (monitoring diagram and alert list)

**Interfaces:**
- Consumes: Caddy's `/var/log/caddy/system.log`, mounted in `edge-lgtm` as
  `/caddy-logs/system.log` (existing `./logs:/caddy-logs:ro`).
- Produces:
  - Loki stream `{service_namespace="edge-caddy", service_name="system-log"}`
  - Grafana rule `uid: edge-cert`, title `Edge: Zertifikat`

- [ ] **Step 1: Write the check `$CHECKS/check-alert.sh`**

```sh
#!/usr/bin/env sh
# usage (repo root): sh $CHECKS/check-alert.sh
set -u
o=monitoring/otelcol-config.yaml; a=monitoring/grafana-alerting.yaml; fail=0
r='.receivers."filelog/caddy-tls"'
[ "$(yq "$r.include[0]" $o)" = /caddy-logs/system.log ] || { echo "FAIL: receiver does not read system.log"; fail=1; }
[ "$(yq "$r.operators[0].type" $o)" = filter ] || { echo "FAIL: no filter operator"; fail=1; }
[ "$(yq "$r.resource.\"service.name\"" $o)" = system-log ] || { echo "FAIL: service.name"; fail=1; }
[ "$(yq "$r.resource.\"deployment.environment.name\"" $o)" = null ] || { echo "FAIL: stream must not be production"; fail=1; }
yq '.service.pipelines.logs.receivers[]' $o | grep -qx filelog/caddy-tls || { echo "FAIL: receiver not in logs pipeline"; fail=1; }
q=$(yq '.groups[0].rules[] | select(.uid == "edge-cert") | .data[0].model.expr' $a)
for s in 'service_name="system-log"' 'level="error"' 'tls\.(obtain|renew)'; do
  printf '%s' "$q" | grep -qF "$s" || { echo "FAIL: rule edge-cert lacks $s"; fail=1; }
done
[ "$(yq '.groups[0].rules[] | select(.uid == "edge-cert") | .noDataState' $a)" = OK ] || { echo "FAIL: noDataState"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: certificate errors reach Loki and an alert"
exit "$fail"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `sh $CHECKS/check-alert.sh`
Expected: every `FAIL:` line except `stream must not be production`, which passes
vacuously.

- [ ] **Step 3: Add the receiver and wire it into the image's `logs` pipeline**

```yaml
  filelog/caddy-tls:
    include: [/caddy-logs/system.log]
    start_at: end
    storage: file_storage
    operators:
      - type: filter
        expr: 'not (body matches "\"logger\":\"tls\\.")'
    resource:
      service.namespace: edge-caddy
      service.name: system-log
```

- Put it below `filelog/caddy`, marked `unividuell`.
- Its comment states:
  - It ships certificate lines only, for the alert.
  - Other lines stay out because `http.log.error` carries unmasked client IPs.
  - There is no environment label, so "Fehler im Log" stays off it: the upstream errors
    there belong to "App down".
- In the `logs` pipeline: `receivers: [otlp, filelog/caddy, filelog/caddy-tls]`.
- Add a header diagram line `caddy system.log (tls) ──────┤`.

- [ ] **Step 4: Add the rule after `edge-burst` in `monitoring/grafana-alerting.yaml`**

```yaml
      - uid: edge-cert
        title: 'Edge: Zertifikat'
        condition: C
        for: 0m
        noDataState: OK
        execErrState: Error
        labels: {}
        annotations:
          summary: '{{ $values.A.Value }} fehlgeschlagene Zertifikatsversuche in 1 h, siehe logs/system.log'
        data:
          - refId: A
            datasourceUid: loki
            relativeTimeRange: {from: 3600, to: 0}
            model:
              refId: A
              queryType: instant
              expr: sum(count_over_time({service_namespace="edge-caddy", service_name="system-log"} | json | level="error" | logger=~`tls\.(obtain|renew)` [1h]))
          - refId: C
            datasourceUid: __expr__
            model:
              refId: C
              type: threshold
              expression: A
              conditions:
                - evaluator: {type: gt, params: [0]}
```

Its comment states:
- The wildcard shares one certificate across every one-label site, so a broken token
  takes them all down together, 30 days after the first failed renewal.
- A single failed attempt mails. Caddy retries by itself, so a mail that resolves within
  the hour was transient.

- [ ] **Step 5: Run the check, then validate the collector config on the server**

Run: `sh $CHECKS/check-alert.sh`
Expected: `PASS: certificate errors reach Loki and an alert`

Run: `ssh oci.unividuell.org 'docker exec -i edge-lgtm /otel-lgtm/otelcol-contrib/otelcol-contrib validate --feature-gates=service.profilesSupport --config=/dev/stdin && echo VALID' < monitoring/otelcol-config.yaml`
Expected: `VALID`. This is read-only and changes nothing on the server.

- [ ] **Step 6: Update `README.md`**

- Diagram: a `logs/system.log (tls lines only)` row.
- Alert list: "certificate errors at the edge".

- [ ] **Step 7: Commit**

```bash
git add monitoring/otelcol-config.yaml monitoring/grafana-alerting.yaml README.md
git commit -m "feat: mail when Caddy cannot get a certificate"
```

---

### Task 4: Rollout

Steps marked **User** are the user's to do: they hold the Cloudflare account and the
token. Never handle the token value. Every server step needs the user's go-ahead.

- [ ] **Step 1 (User): Create the Cloudflare token.** Use the scope from Global
  Constraints, starting from the "Edit zone DNS" template and adding Zone · Zone · Read.

- [ ] **Step 2 (User): Create the DNS record** A `*` → `158.101.161.126`, DNS only.
  Leave every existing record in place.

- [ ] **Step 3: Verify DNS**

Run: `dig +short probe-$(openssl rand -hex 4).unividuell.org A @daisy.ns.cloudflare.com; dig +short countdown.unividuell.org A @daisy.ns.cloudflare.com`
Expected: `158.101.161.126` twice.

- [ ] **Step 4 (User): Add `CLOUDFLARE_API_TOKEN=<token>` to the server's `.env`.**
  The file is `/opt/unividuell/edge-caddy/.env`; the value goes in unquoted.

- [ ] **Step 5: Merge into `main`** (superpowers:finishing-a-development-branch, with the user's choice of PR or direct merge)

- [ ] **Step 6: Deploy**

Run (with the user's go-ahead): `ssh oci.unividuell.org 'cd /opt/unividuell/edge-caddy && ./update.sh'`
Expected:
- `Building the edge image with caddy-dns/cloudflare v…`
- `Validating Caddyfile against .env ...`
- `Edge update complete.`

- [ ] **Step 7: Verify the wildcard was obtained**

Run, up to 5 minutes after the deploy: `ssh oci.unividuell.org "docker exec edge-caddy grep -cF 'certificate obtained successfully\",\"identifier\":\"*.unividuell.org' /var/log/caddy/system.log"`
Expected: `1` or more.

If the log shows `timed out waiting for record to fully propagate` instead:
1. Add `resolvers 1.1.1.1 1.0.0.1` to the wildcard `tls` block.
2. Commit, merge, deploy again.

- [ ] **Step 8: Verify what is served**

Run: `for h in countdown mobility stats files prueffahrt beta.countdown; do printf '%-15s ' $h; openssl s_client -connect $h.unividuell.org:443 -servername $h.unividuell.org </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName | tail -1; done`
Expected: `DNS:*.unividuell.org` for the five one-label hosts, and
`DNS:beta.countdown.unividuell.org` for the last.

Run: `curl -sS https://probe-$(openssl rand -hex 4).unividuell.org/ ; curl -s -o /dev/null -w '%{http_code}\n' https://prueffahrt.unividuell.org/`
Expected: `curl: (52) Empty reply from server`, then `302`.

Run: `curl -sS --resolve news.zingler46.unividuell.org:443:158.101.161.126 https://news.zingler46.unividuell.org/`
Expected: `curl: (35) … tlsv1 alert internal error`: no certificate and no basic-auth prompt
(Review Focus 1). `--resolve` sidesteps a local resolver that may still have the old
NXDOMAIN cached.

- [ ] **Step 9: Verify the log stream and the rule**

Run, 15 minutes after the deploy:

```bash
ssh oci.unividuell.org 'docker exec -i edge-lgtm sh -s' <<'EOF'
curl -sG http://127.0.0.1:3100/loki/api/v1/query --data-urlencode 'query=sum(count_over_time({service_name="system-log"}[1h]))'; echo
curl -sG http://127.0.0.1:3100/loki/api/v1/query --data-urlencode 'query=sum(count_over_time({service_name="system-log"} !~ `"logger":"tls\.` [1h]))'; echo
curl -s http://127.0.0.1:3000/api/v1/provisioning/alert-rules/edge-cert | grep -o '"title":"[^"]*"'
EOF
```

Expected:
1. The first result has one value above 0.
2. The second has `"result":[]`: no non-tls lines.
3. The last line is `"title":"Edge: Zertifikat"`.

If the provisioning API asks for auth, check the rule under Alerting in Grafana instead.

- [ ] **Step 10: Update memory**

Rewrite `unividuell-dns-cloudflare.md` in the project memory:
- The `*` A record exists.
- One-label names need no record and use the DNS-01 wildcard.
- The token sits in `.env`.
- The explicit A records stay until `beta.countdown` is gone (the empty-node rule).

Drop the "cannot be one" paragraph.

- [ ] **Step 11 (optional, with the user's go-ahead): Remove leftovers on the server.**
  `logs/news_zingler46_access*.log` (from July and August) and the `NEWS_*` lines in
  `.env`. Neither is read any more. Keeping the `.env` lines makes a later revival of
  comunio-news cheaper.
