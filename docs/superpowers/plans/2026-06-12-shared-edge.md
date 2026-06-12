# Shared Edge (Caddy) + Multi-Project Hosting — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single mashed `/opt/unividuell` compose with one shared Caddy edge (binds 80/443, TLS, host-routing) plus four independent per-project stacks that join an external `edge` Docker network — re-homed under `/opt/unividuell/<project>/`.

**Architecture:** A new `unividuell/edge-caddy` repo owns the only 80/443 binding and reverse-proxies by container name over a user-defined external bridge network `edge`. Each app (countdown, mobility-manager, comunio-news) exposes one stable-named container on `edge`, keeps private services on its own internal net, and binds no public ports. TLS terminates at the edge; apps speak plain HTTP behind it.

**Tech Stack:** Docker Compose v2/v5, Caddy 2 (caddy:2-alpine), ghcr.io private images, curl-bootstrapped `update.sh` per repo, external Docker network `edge`.

**Spec:** `docs/superpowers/specs/2026-06-12-shared-edge-design.md` (in this repo).

**Note on validation (no TDD here — this is infra config):** the "test" for each file is a static validation that runs without bind-mounting `/opt` (Docker Desktop on this mac does not share `/opt`):
- Compose: `docker compose -f <file> --env-file <env> config -q` (renders + validates syntax; does not require the external network to exist).
- Caddyfile: pipe via stdin into a throwaway container —
  `docker run --rm -i caddy:2-alpine sh -c 'cat > /tmp/Caddyfile && caddy fmt /tmp/Caddyfile > /dev/null && caddy adapt --config /tmp/Caddyfile --adapter caddyfile > /dev/null && echo ADAPT_OK'`

---

## File structure

**Repo `unividuell/edge-caddy`** (new, already `git init`'d at `/opt/unividuell/projects/edge-caddy`):
- Create: `Caddyfile` — global block + 3 site blocks, each `reverse_proxy <container_name>:<port>`.
- Create: `compose.yaml` — single `caddy` service (`container_name: edge-caddy`), the only 80/443 binding, external `edge` net.
- Create: `.env.example` — `BASIC_AUTH_HASH=`.
- Create: `update.sh` — curl infra from main + `docker network create edge || true` + pull/up.
- Create: `.gitignore` — `.env`, `logs/`.
- Create: `README.md` — bootstrap, add-a-site how-to, cert notes.
- Create: `.claude/guidelines/shared-edge.md` — the convention (feed-knowledge-back).

**Repo `unividuell/countdown`** (`/opt/unividuell/projects/countdown.unividuell.org`) — adapt:
- Modify: `deploy/Caddyfile` — `countdown.unividuell.org { … }` → `:80 { … }`.
- Modify: `deploy/compose.prod.yaml` — drop `ports` 80/443 from `caddy`, add `container_name: countdown-web`, add networks (`edge` external + `internal`), attach `caddy` to both, attach `core`/`postgres`/`db-backup`/`pgadmin` to `internal`.
- Modify: `deploy/update.sh` — add `docker network create edge || true`.
- Modify: `deploy/README.md` — server dir `/opt/countdown` → `/opt/unividuell/countdown`; note edge dependency.
- Modify: `.claude/guidelines/deployment.md` — add shared-edge cross-link note.

**Repo `unividuell/mobility-manager`** (`/opt/unividuell/projects/mobility-manager`) — adapt:
- Create: `deploy/compose.prod.yaml` — `mobility-manager` service, external `edge` net, no 8080 publish, `./data:/data`.
- Create: `deploy/.env.example` — `MOBILITY_MANAGER_GITHUB_CLIENT_SECRET=`.
- Create: `deploy/update.sh`.
- Modify: `README.md` — deployment section: edge net, no host port, `./data` mount + chown, server dir.

**Repo `unividuell/comunio-news`** (`/opt/unividuell/projects/comunio-news`) — adapt:
- Create: `deploy/compose.prod.yaml` — `app` (on `edge`) + `redis` (internal), no caddy, no 6379 publish.
- Create: `deploy/.env.example` — the four comunio secrets.
- Create: `deploy/update.sh`.
- Create: `deploy/README.md` — bootstrap + note the edge owns the `news.zingler46` route + basicauth.

**Server cutover** — manual, coordinated, in the final section. NOT subagent-executable.

---

## Task 1: edge-caddy — Caddyfile

**Files:**
- Create: `/opt/unividuell/projects/edge-caddy/Caddyfile`

- [ ] **Step 1: Write the Caddyfile**

```caddy
# ================= Global config =================
{
	email unividuell@gmail.com
	log {
		output file /var/log/caddy/system.log {
			roll_size 3mb
			roll_keep 2
		}
		level INFO
	}
}

# countdown SPA + API (TLS here; countdown-web serves :80 plain behind the edge)
countdown.unividuell.org {
	reverse_proxy countdown-web:80
}

# mobility-manager (plain :8080 behind the edge)
mobility.unividuell.org {
	reverse_proxy mobility-manager:8080
}

# comunio-news (basicauth at the edge)
news.zingler46.unividuell.org {
	log {
		output file /var/log/caddy/news_zingler46_access.log {
			roll_size 10mb
			roll_keep 7
		}
	}
	basicauth {
		futzi {$BASIC_AUTH_HASH}
		tonnenbolzer {$BASIC_AUTH_HASH}
	}
	reverse_proxy comunio-news-app:8080
}
```

- [ ] **Step 2: Validate it adapts**

Run:
```bash
docker run --rm -i caddy:2-alpine sh -c 'cat > /tmp/Caddyfile && caddy adapt --config /tmp/Caddyfile --adapter caddyfile > /dev/null && echo ADAPT_OK' < /opt/unividuell/projects/edge-caddy/Caddyfile
```
Expected: prints `ADAPT_OK` (no adapt warnings/errors). The `{$BASIC_AUTH_HASH}` placeholder is fine — Caddy resolves env at runtime; adapt treats it as a literal.

- [ ] **Step 3: Commit**

```bash
cd /opt/unividuell/projects/edge-caddy
git add Caddyfile
git commit -m "feat: edge Caddyfile routing all three domains"
```

---

## Task 2: edge-caddy — compose.yaml

**Files:**
- Create: `/opt/unividuell/projects/edge-caddy/compose.yaml`

- [ ] **Step 1: Write the compose file**

```yaml
name: edge-caddy

services:
  caddy:
    image: caddy:2-alpine
    container_name: edge-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    environment:
      - BASIC_AUTH_HASH=${BASIC_AUTH_HASH}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ./logs:/var/log/caddy
      - caddy-data:/data
      - caddy-config:/config
    networks:
      - edge

volumes:
  caddy-data:
  caddy-config:

networks:
  edge:
    external: true
```

- [ ] **Step 2: Validate compose renders**

Run:
```bash
cd /opt/unividuell/projects/edge-caddy
printf 'BASIC_AUTH_HASH=placeholder\n' > /tmp/edge.env
docker compose -f compose.yaml --env-file /tmp/edge.env config -q && echo CONFIG_OK
```
Expected: prints `CONFIG_OK`. (External network `edge` is not checked for existence by `config`.)

- [ ] **Step 3: Commit**

```bash
cd /opt/unividuell/projects/edge-caddy
git add compose.yaml
git commit -m "feat: edge compose (only 80/443 binding, external edge net)"
```

---

## Task 3: edge-caddy — .env.example + .gitignore

**Files:**
- Create: `/opt/unividuell/projects/edge-caddy/.env.example`
- Create: `/opt/unividuell/projects/edge-caddy/.gitignore`

- [ ] **Step 1: Write .env.example**

```dotenv
# bcrypt hash for the news.zingler46 basicauth users (futzi + tonnenbolzer share it).
# Generate with: docker run --rm caddy:2-alpine caddy hash-password --plaintext '<password>'
BASIC_AUTH_HASH=
```

- [ ] **Step 2: Write .gitignore**

```gitignore
.env
logs/
```

- [ ] **Step 3: Commit**

```bash
cd /opt/unividuell/projects/edge-caddy
git add .env.example .gitignore
git commit -m "chore: edge .env.example + gitignore"
```

---

## Task 4: edge-caddy — update.sh

**Files:**
- Create: `/opt/unividuell/projects/edge-caddy/update.sh`

- [ ] **Step 1: Write update.sh**

```sh
#!/usr/bin/env sh
# Full update: fetch latest infra files from main, ensure the edge network, pull, restart.
set -eu
BASE="https://raw.githubusercontent.com/unividuell/edge-caddy/main"

curl -fsSL "$BASE/compose.yaml" -o compose.yaml
curl -fsSL "$BASE/Caddyfile"    -o Caddyfile
curl -fsSL "$BASE/README.md"    -o README.md
curl -fsSL "$BASE/update.sh"    -o update.sh.new && chmod +x update.sh.new && mv update.sh.new update.sh

if [ ! -f .env ]; then
  curl -fsSL "$BASE/.env.example" -o .env
  echo ".env created from template — fill in BASIC_AUTH_HASH, then re-run ./update.sh"
  exit 1
fi

docker network create edge 2>/dev/null || true
docker compose --env-file .env -f compose.yaml pull
docker compose --env-file .env -f compose.yaml up -d
docker image prune -f
echo "Edge update complete."
```

- [ ] **Step 2: Set executable + sanity-check shell syntax**

Run:
```bash
cd /opt/unividuell/projects/edge-caddy
chmod +x update.sh
sh -n update.sh && echo SYNTAX_OK
```
Expected: prints `SYNTAX_OK`.

- [ ] **Step 3: Commit**

```bash
cd /opt/unividuell/projects/edge-caddy
git add update.sh
git commit -m "feat: edge update.sh (curl infra, ensure edge net, pull/up)"
```

---

## Task 5: edge-caddy — README + guideline

**Files:**
- Create: `/opt/unividuell/projects/edge-caddy/README.md`
- Create: `/opt/unividuell/projects/edge-caddy/.claude/guidelines/shared-edge.md`

- [ ] **Step 1: Write README.md**

````markdown
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

## Bootstrap (first time)
```bash
mkdir -p /opt/unividuell/edge-caddy && cd /opt/unividuell/edge-caddy
curl -fsSL https://raw.githubusercontent.com/unividuell/edge-caddy/main/update.sh -o update.sh && chmod +x update.sh
./update.sh          # fetches compose.yaml + Caddyfile + a .env template, then stops
# edit .env: set BASIC_AUTH_HASH (see below)
./update.sh          # creates the edge network, pulls caddy, starts the edge
```

`BASIC_AUTH_HASH` is a bcrypt hash shared by the two news users:
```bash
docker run --rm caddy:2-alpine caddy hash-password --plaintext '<password>'
```

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

## Certs
Caddy stores certs/ACME state in the `caddy-data` volume. A fresh volume triggers
Let's Encrypt issuance for every domain on first request — well within rate limits for
three domains. DNS for each domain must already point at this host and 80/443 must be open.
````

- [ ] **Step 2: Write the guideline**

```markdown
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
```

- [ ] **Step 3: Commit**

```bash
cd /opt/unividuell/projects/edge-caddy
git add README.md .claude/guidelines/shared-edge.md
git commit -m "docs: edge README + shared-edge guideline"
```

---

## Task 6: countdown — Caddyfile to :80 (drop own TLS)

**Files:**
- Modify: `/opt/unividuell/projects/countdown.unividuell.org/deploy/Caddyfile`

- [ ] **Step 1: Rewrite the site address from the domain to `:80`**

Replace the whole file with (only the first line changes — domain → `:80`; routing stays):

```caddy
:80 {
	encode zstd gzip

	@backend path /api/* /oauth2/* /login/* /logout/*

	# API paths -> backend. A dedicated handle block (not a bare reverse_proxy) so it is
	# mutually exclusive with the SPA catch-all and evaluated first; otherwise the catch-all
	# handle matches everything (incl. /api/*) and the file_server swallows API requests.
	handle @backend {
		reverse_proxy core:8080
	}

	# everything else -> SPA with HTML5 history-mode fallback
	handle {
		root * /srv
		try_files {path} /index.html
		file_server
	}
}
```

- [ ] **Step 2: Validate it adapts and route order is correct**

Run:
```bash
docker run --rm -i caddy:2-alpine sh -c 'cat > /tmp/Caddyfile && caddy adapt --config /tmp/Caddyfile --adapter caddyfile' < /opt/unividuell/projects/countdown.unividuell.org/deploy/Caddyfile | python3 -c "import sys,json; d=json.load(sys.stdin); print('ADAPT_OK')"
```
Expected: prints `ADAPT_OK`. (The two `handle` blocks keep `@backend` evaluated before the SPA catch-all — unchanged from the working config.)

- [ ] **Step 3: Commit**

```bash
cd /opt/unividuell/projects/countdown.unividuell.org
git add deploy/Caddyfile
git commit -m "feat(deploy): serve countdown-web on :80 (TLS moves to shared edge)"
```

---

## Task 7: countdown — compose.prod.yaml (no 80/443, join edge)

**Files:**
- Modify: `/opt/unividuell/projects/countdown.unividuell.org/deploy/compose.prod.yaml`

- [ ] **Step 1: Replace the file**

Key changes: `caddy` gets `container_name: countdown-web`, loses `ports`, joins `edge`+`internal`; every other service joins `internal`; add a `networks:` section (`edge` external, `internal` bridge).

```yaml
name: countdown

services:
  postgres:
    image: postgres:18
    restart: unless-stopped
    environment:
      - POSTGRES_DB=app
      - POSTGRES_USER=admin
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks:
      - internal

  db-backup:
    image: postgres:18
    # long-running backup loop (not one-shot) — keep it alive across crashes/restarts
    restart: unless-stopped
    environment:
      - PGPASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - ./backups:/backups
    entrypoint: ["/bin/bash", "-c"]
    command:
      - |
        set -eo pipefail
        while true; do
          until pg_isready -h postgres -U admin -d app; do sleep 2; done
          pg_dump -h postgres -U admin -d app | gzip > "/backups/app-$$(date +%Y%m%d-%H%M%S).sql.gz"
          find /backups -name 'app-*.sql.gz' -mtime +7 -delete
          sleep 86400
        done
    depends_on:
      - postgres
    networks:
      - internal

  core:
    image: ghcr.io/unividuell/countdown-core:latest
    restart: unless-stopped
    environment:
      - SPRING_PROFILES_ACTIVE=production
      - GITHUB_CLIENT_SECRET=${GITHUB_CLIENT_SECRET}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    depends_on:
      - postgres
    networks:
      - internal

  caddy:
    image: ghcr.io/unividuell/countdown-web:latest
    container_name: countdown-web
    restart: unless-stopped
    volumes:
      - caddy-data:/data
      - caddy-config:/config
    depends_on:
      - core
    networks:
      - edge      # reachable by the shared edge (reverse_proxy countdown-web:80)
      - internal  # to reach core:8080

  pgadmin:
    image: dpage/pgadmin4:latest
    profiles: [debug]
    restart: unless-stopped
    environment:
      - PGADMIN_DEFAULT_EMAIL=${PGADMIN_EMAIL}
      - PGADMIN_DEFAULT_PASSWORD=${PGADMIN_PASSWORD}
    ports:
      - "127.0.0.1:5050:80"
    configs:
      - source: pgadmin_servers
        target: /pgadmin4/servers.json
    volumes:
      - pgadmin-data:/var/lib/pgadmin
    depends_on:
      - postgres
    networks:
      - internal

configs:
  pgadmin_servers:
    content: |
      {
        "Servers": { "1": {
          "Name": "countdown app (postgres)", "Group": "Servers",
          "Host": "postgres", "Port": 5432, "MaintenanceDB": "app",
          "Username": "admin", "SSLMode": "prefer"
        } }
      }

volumes:
  pgdata:
  caddy-data:
  caddy-config:
  pgadmin-data:

networks:
  edge:
    external: true
  internal:
    driver: bridge
```

- [ ] **Step 2: Validate compose renders**

Run:
```bash
cd /opt/unividuell/projects/countdown.unividuell.org/deploy
printf 'POSTGRES_PASSWORD=x\nGITHUB_CLIENT_SECRET=x\nPGADMIN_EMAIL=a@b.c\nPGADMIN_PASSWORD=x\n' > /tmp/cd.env
docker compose -f compose.prod.yaml --env-file /tmp/cd.env config -q && echo CONFIG_OK
```
Expected: prints `CONFIG_OK`, and the rendered `caddy` service has no `ports:` 80/443.

- [ ] **Step 3: Commit**

```bash
cd /opt/unividuell/projects/countdown.unividuell.org
git add deploy/compose.prod.yaml
git commit -m "feat(deploy): join shared edge net, drop 80/443 publish"
```

---

## Task 8: countdown — update.sh, README, deployment guideline

**Files:**
- Modify: `/opt/unividuell/projects/countdown.unividuell.org/deploy/update.sh`
- Modify: `/opt/unividuell/projects/countdown.unividuell.org/deploy/README.md`
- Modify: `/opt/unividuell/projects/countdown.unividuell.org/.claude/guidelines/deployment.md`

- [ ] **Step 1: Add the edge-network ensure to update.sh**

In `deploy/update.sh`, insert the network-create line immediately before the `docker compose ... pull` line:

```sh
docker network create edge 2>/dev/null || true
docker compose --env-file .env -f compose.prod.yaml pull
```

- [ ] **Step 2: Update README.md — server dir + edge dependency**

- Replace every `/opt/countdown` with `/opt/unividuell/countdown` (the bootstrap `mkdir -p`, the "in `/opt/countdown/`" intro, the Update `cd`).
- In the DNS prerequisite, change "Caddy cannot obtain a TLS certificate" wording: TLS is now obtained by the **shared edge**, not this stack. Replace the DNS bullet with:

```markdown
- DNS: `A`/`AAAA` `countdown.unividuell.org` → this server's public IP. TLS is terminated
  by the shared **edge-caddy** (see `/opt/unividuell/edge-caddy`), which must be running and
  routing `countdown.unividuell.org` → `countdown-web:80`. This stack publishes no host
  ports; it only joins the external `edge` network.
```

- Add a line to the Bootstrap section noting the edge must exist first:

```markdown
> Requires the shared **edge-caddy** stack to be up (it owns 80/443 + TLS) and the external
> `edge` network to exist. `update.sh` creates the network idempotently if missing.
```

- [ ] **Step 3: Update the deployment guideline with a shared-edge cross-link**

Append to `.claude/guidelines/deployment.md` a new section just before the "Docker Desktop gotcha" section:

```markdown
## Shared edge (multi-project host)

This server hosts several `unividuell.org` sites; only one process can bind 80/443. TLS +
host-routing live in the separate **`unividuell/edge-caddy`** repo (its own guideline:
shared-edge). countdown therefore:
- serves `countdown-web` on **`:80`** (Caddyfile address `:80`, not the domain) — no own TLS;
- **publishes no host ports**; the `countdown-web` container joins the external **`edge`**
  network (stable `container_name: countdown-web`) and an `internal` net for `core`/`postgres`;
- relies on the edge for the two-hop `X-Forwarded-*` chain (edge → countdown-web → core), so
  `forward-headers-strategy=framework` still yields `https://countdown.unividuell.org/...`.
- Server dir is `/opt/unividuell/countdown/`.
```

- [ ] **Step 4: Validate update.sh syntax**

Run:
```bash
sh -n /opt/unividuell/projects/countdown.unividuell.org/deploy/update.sh && echo SYNTAX_OK
```
Expected: prints `SYNTAX_OK`.

- [ ] **Step 5: Commit**

```bash
cd /opt/unividuell/projects/countdown.unividuell.org
git add deploy/update.sh deploy/README.md .claude/guidelines/deployment.md
git commit -m "docs(deploy): shared-edge layout — /opt/unividuell/countdown, edge net, guideline"
```

- [ ] **Step 6: Rebuild the countdown-web image (Caddyfile is baked in)**

The Caddyfile change (Task 6) is baked into `countdown-web` — the running image must be rebuilt.
After merging these countdown changes to `main`, trigger the web build:
```bash
gh workflow run build-web.yml --repo unividuell/countdown --ref main
gh run watch --repo unividuell/countdown $(gh run list --repo unividuell/countdown --workflow build-web.yml -L1 --json databaseId -q '.[0].databaseId')
```
Expected: workflow succeeds; `ghcr.io/unividuell/countdown-web:latest` updated. (The `deploy/Caddyfile` path is already in the `build-web.yml` push filter, so the merge itself also triggers it — this is the manual fallback.)

---

## Task 9: mobility-manager — deploy/compose.prod.yaml

**Files:**
- Create: `/opt/unividuell/projects/mobility-manager/deploy/compose.prod.yaml`

- [ ] **Step 1: Write the compose file**

`mobility-manager` joins `edge`, publishes no port, mounts `./data:/data` (SQLite). Healthcheck
is the bash `/dev/tcp` probe from the repo README (the run image lacks curl/wget).

```yaml
name: mobility-manager

services:
  mobility-manager:
    image: ghcr.io/unividuell/mobility-manager:latest
    container_name: mobility-manager
    restart: unless-stopped
    environment:
      SPRING_PROFILES_ACTIVE: production
      MOBILITY_MANAGER_GITHUB_CLIENT_SECRET: ${MOBILITY_MANAGER_GITHUB_CLIENT_SECRET}
      MOBILITY_MANAGER_GITHUB_CLIENT_ID: ${MOBILITY_MANAGER_GITHUB_CLIENT_ID:-}
    volumes:
      # SQLite DB lands at ./data/mobility-manager.db on the host.
      # The dir must be owned by the buildpack run user: chown 1002:1000 ./data
      - ./data:/data
    networks:
      - edge
    healthcheck:
      test: ['CMD', 'bash', '-c', 'exec 3<>/dev/tcp/127.0.0.1/8080 && printf ''GET /actuator/health HTTP/1.0\r\n\r\n'' >&3 && grep -q UP <&3']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

networks:
  edge:
    external: true
```

- [ ] **Step 2: Validate compose renders**

Run:
```bash
cd /opt/unividuell/projects/mobility-manager/deploy
printf 'MOBILITY_MANAGER_GITHUB_CLIENT_SECRET=x\n' > /tmp/mm.env
docker compose -f compose.prod.yaml --env-file /tmp/mm.env config -q && echo CONFIG_OK
```
Expected: prints `CONFIG_OK`; rendered service has no `ports:`.

- [ ] **Step 3: Commit**

```bash
cd /opt/unividuell/projects/mobility-manager
git add deploy/compose.prod.yaml
git commit -m "feat(deploy): standalone compose on shared edge net (no host port)"
```

---

## Task 10: mobility-manager — .env.example + update.sh

**Files:**
- Create: `/opt/unividuell/projects/mobility-manager/deploy/.env.example`
- Create: `/opt/unividuell/projects/mobility-manager/deploy/update.sh`

- [ ] **Step 1: Write .env.example**

```dotenv
# mobility-manager production secrets (all MOBILITY_MANAGER_-prefixed)
MOBILITY_MANAGER_GITHUB_CLIENT_SECRET=
# optional: only if production uses a separate GitHub OAuth app
#MOBILITY_MANAGER_GITHUB_CLIENT_ID=
```

- [ ] **Step 2: Write update.sh**

```sh
#!/usr/bin/env sh
# Full update: fetch latest infra from main, ensure edge net, pull, restart.
set -eu
BASE="https://raw.githubusercontent.com/unividuell/mobility-manager/main/deploy"

curl -fsSL "$BASE/compose.prod.yaml" -o compose.prod.yaml
curl -fsSL "$BASE/update.sh"         -o update.sh.new && chmod +x update.sh.new && mv update.sh.new update.sh

if [ ! -f .env ]; then
  curl -fsSL "$BASE/.env.example" -o .env
  echo ".env created from template — fill in MOBILITY_MANAGER_GITHUB_CLIENT_SECRET, then re-run ./update.sh"
  exit 1
fi

# SQLite data dir must be owned by the buildpack run user (uid 1002, gid 1000)
mkdir -p data
docker network create edge 2>/dev/null || true
docker compose --env-file .env -f compose.prod.yaml pull
docker compose --env-file .env -f compose.prod.yaml up -d
docker image prune -f
echo "mobility-manager update complete."
```

- [ ] **Step 3: Set executable + validate syntax**

Run:
```bash
cd /opt/unividuell/projects/mobility-manager/deploy
chmod +x update.sh
sh -n update.sh && echo SYNTAX_OK
```
Expected: prints `SYNTAX_OK`.

- [ ] **Step 4: Commit**

```bash
cd /opt/unividuell/projects/mobility-manager
git add deploy/.env.example deploy/update.sh
git commit -m "feat(deploy): .env.example + update.sh"
```

---

## Task 11: mobility-manager — README deployment section

**Files:**
- Modify: `/opt/unividuell/projects/mobility-manager/README.md`

- [ ] **Step 1: Replace the "Running on the server" / compose-snippet content**

The repo now ships its own `deploy/compose.prod.yaml` + `update.sh`; the README should point
at those and reflect the shared edge (no host port, `./data` mount, `/opt/unividuell/mobility-manager`).
Replace the `### Running on the server`, `### docker-compose snippet`, and `Bring it up` blocks with:

````markdown
### Running on the server

Deployment lives in `deploy/` (`compose.prod.yaml`, `.env.example`, `update.sh`). The app
runs behind the shared **edge-caddy** (TLS + `mobility.unividuell.org` routing); it publishes
**no host port** and joins the external `edge` network as `container_name: mobility-manager`.

Server dir: **`/opt/unividuell/mobility-manager/`**. The SQLite DB lives under `./data/`
(bind-mounted to `/data`), so it survives image/container replacement.

**One-time host setup.** The buildpack run image runs as the non-root `cnb` user
(uid `1002`, gid `1000`), so the data dir must be owned by that uid — otherwise the app
crashes on startup with `SQLITE_CANTOPEN`:

```bash
sudo mkdir -p /opt/unividuell/mobility-manager/data
sudo chown -R 1002:1000 /opt/unividuell/mobility-manager/data
```

Authenticate to GHCR (private package) with a token that has `read:packages`:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <github-username> --password-stdin
```

### Bootstrap / update

```bash
mkdir -p /opt/unividuell/mobility-manager && cd /opt/unividuell/mobility-manager
curl -fsSL https://raw.githubusercontent.com/unividuell/mobility-manager/main/deploy/update.sh -o update.sh && chmod +x update.sh
./update.sh          # fetches compose + .env template, then stops
# edit .env: MOBILITY_MANAGER_GITHUB_CLIENT_SECRET
./update.sh          # ensures edge net, pulls, starts
```

> The shared edge-caddy stack must be up (it owns 80/443 + TLS). The GitHub OAuth app's
> callback URL must be `https://mobility.unividuell.org/login/oauth2/code/github`.
````

- [ ] **Step 2: Commit**

```bash
cd /opt/unividuell/projects/mobility-manager
git add README.md
git commit -m "docs: server deployment via deploy/ behind shared edge"
```

---

## Task 12: comunio-news — deploy/compose.prod.yaml (app + redis, no caddy)

**Files:**
- Create: `/opt/unividuell/projects/comunio-news/deploy/compose.prod.yaml`

- [ ] **Step 1: Write the compose file**

Extracted from `infrastructur/oci/docker-compose.yml`, minus `caddy` (moves to the edge):
`app` joins `edge`, `redis` stays internal (no 6379 publish). Keep the `disabled-as-broken`
profile so the app stays down until fixed — the edge route just 502s meanwhile.

```yaml
name: comunio-news

services:
  app:
    image: ghcr.io/unividuell/comunio-news:latest
    container_name: comunio-news-app
    profiles: [disabled-as-broken]
    restart: unless-stopped
    environment:
      - SPRING_PROFILES_ACTIVE=oci
      - GOOGLE_GENAI_API_KEY=${GOOGLE_GENAI_API_KEY}
      - OPENAI_API_KEY=${OPENAI_API_KEY}
      - STATS_COMUNIO_USER=${STATS_COMUNIO_USER}
      - STATS_COMUNIO_PW=${STATS_COMUNIO_PW}
    depends_on:
      - redis
    networks:
      - edge      # reachable by the shared edge (reverse_proxy comunio-news-app:8080)
      - internal  # to reach redis
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  redis:
    image: redis:alpine
    container_name: comunio-news-redis
    restart: unless-stopped
    command: redis-server --save 60 1 --loglevel warning
    volumes:
      - redis-data:/data
    networks:
      - internal

volumes:
  redis-data:

networks:
  edge:
    external: true
  internal:
    driver: bridge
```

- [ ] **Step 2: Validate compose renders**

Run:
```bash
cd /opt/unividuell/projects/comunio-news/deploy
printf 'GOOGLE_GENAI_API_KEY=x\nOPENAI_API_KEY=x\nSTATS_COMUNIO_USER=x\nSTATS_COMUNIO_PW=x\n' > /tmp/cn.env
docker compose -f compose.prod.yaml --env-file /tmp/cn.env --profile disabled-as-broken config -q && echo CONFIG_OK
```
Expected: prints `CONFIG_OK`; no service publishes a host port.

- [ ] **Step 3: Commit**

```bash
cd /opt/unividuell/projects/comunio-news
git add deploy/compose.prod.yaml
git commit -m "feat(deploy): standalone app+redis on shared edge (caddy moves to edge-caddy)"
```

---

## Task 13: comunio-news — .env.example + update.sh

**Files:**
- Create: `/opt/unividuell/projects/comunio-news/deploy/.env.example`
- Create: `/opt/unividuell/projects/comunio-news/deploy/update.sh`

- [ ] **Step 1: Write .env.example**

```dotenv
# comunio-news production secrets
GOOGLE_GENAI_API_KEY=
OPENAI_API_KEY=
STATS_COMUNIO_USER=
STATS_COMUNIO_PW=
```

- [ ] **Step 2: Write update.sh**

Note: the app is currently behind the `disabled-as-broken` profile, so `up -d` without
`--profile disabled-as-broken` only starts `redis`. The script ensures the edge net and pulls;
to actually run the app once fixed, add `--profile disabled-as-broken` (or remove the profile).

```sh
#!/usr/bin/env sh
# Full update: fetch latest infra from main, ensure edge net, pull, restart.
set -eu
BASE="https://raw.githubusercontent.com/unividuell/comunio-news/main/deploy"

curl -fsSL "$BASE/compose.prod.yaml" -o compose.prod.yaml
curl -fsSL "$BASE/README.md"         -o README.md
curl -fsSL "$BASE/update.sh"         -o update.sh.new && chmod +x update.sh.new && mv update.sh.new update.sh

if [ ! -f .env ]; then
  curl -fsSL "$BASE/.env.example" -o .env
  echo ".env created from template — fill in the secrets, then re-run ./update.sh"
  exit 1
fi

docker network create edge 2>/dev/null || true
# app is gated behind the disabled-as-broken profile; this pulls/starts redis only.
# Once the app is fixed, append: --profile disabled-as-broken
docker compose --env-file .env -f compose.prod.yaml pull
docker compose --env-file .env -f compose.prod.yaml up -d
docker image prune -f
echo "comunio-news update complete (app gated behind disabled-as-broken profile)."
```

- [ ] **Step 3: Set executable + validate syntax**

Run:
```bash
cd /opt/unividuell/projects/comunio-news/deploy
chmod +x update.sh
sh -n update.sh && echo SYNTAX_OK
```
Expected: prints `SYNTAX_OK`.

- [ ] **Step 4: Commit**

```bash
cd /opt/unividuell/projects/comunio-news
git add deploy/.env.example deploy/update.sh
git commit -m "feat(deploy): .env.example + update.sh"
```

---

## Task 14: comunio-news — deploy/README.md

**Files:**
- Create: `/opt/unividuell/projects/comunio-news/deploy/README.md`

- [ ] **Step 1: Write README.md**

````markdown
# comunio-news — server deployment

Runs as a standalone stack behind the shared **edge-caddy** (TLS + the
`news.zingler46.unividuell.org` route **and its basicauth** live in the edge, not here).
This stack is just `app` + `redis`; it publishes no host ports. `app` joins the external
`edge` network as `comunio-news-app`; `redis` stays on an internal net.

Server dir: **`/opt/unividuell/comunio-news/`**. Images: `ghcr.io/unividuell/comunio-news:latest`
(private — `docker login ghcr.io` with a `read:packages` token first).

> **The app is currently gated behind the `disabled-as-broken` compose profile.** A plain
> `up -d` starts only `redis`; the edge route to it returns 502 until the app is fixed and
> started with `--profile disabled-as-broken` (or the profile is removed).

## Bootstrap / update
```bash
mkdir -p /opt/unividuell/comunio-news && cd /opt/unividuell/comunio-news
curl -fsSL https://raw.githubusercontent.com/unividuell/comunio-news/main/deploy/update.sh -o update.sh && chmod +x update.sh
./update.sh          # fetches compose + .env template, then stops
# edit .env: GOOGLE_GENAI_API_KEY, OPENAI_API_KEY, STATS_COMUNIO_USER, STATS_COMUNIO_PW
./update.sh          # ensures edge net, pulls, starts redis (app gated)
```

The shared edge-caddy stack must be up (it owns 80/443 + TLS + the basicauth for this site).
redis data is treated as a disposable cache (fresh `comunio-news_redis-data` volume is fine).
````

- [ ] **Step 2: Commit**

```bash
cd /opt/unividuell/projects/comunio-news
git add deploy/README.md
git commit -m "docs: server deployment behind shared edge"
```

---

## Server cutover (MANUAL — coordinate with the user; brief mobility downtime)

> This section is **not** subagent-executable. It touches live services (mobility + news) and
> requires SSH to `ubuntu@158.101.161.126`. Run it interactively with the user after all repo
> changes are merged to `main` and images are published. Coordinate the downtime window.

**Preconditions:**
- All four repos' changes merged to `main`; `countdown-web` rebuilt (Task 8 Step 6); mobility +
  comunio images already in ghcr.
- DNS for all three domains already points at the host (mobility + news existing; countdown set).
- The server is logged in to ghcr (`docker login ghcr.io`, `read:packages`).

**Sequence (on the server):**

- [ ] **1. Prep per-project subdirs under `/opt/unividuell/`** (these coexist with the old
  root-level `/opt/unividuell/{docker-compose.yml,Caddyfile,.env}` until cleanup):
  ```bash
  cd /opt/unividuell
  # edge
  mkdir -p edge-caddy && (cd edge-caddy && curl -fsSL https://raw.githubusercontent.com/unividuell/edge-caddy/main/update.sh -o update.sh && chmod +x update.sh && ./update.sh)   # writes .env template, stops
  # countdown
  mkdir -p countdown && (cd countdown && curl -fsSL https://raw.githubusercontent.com/unividuell/countdown/main/deploy/update.sh -o update.sh && chmod +x update.sh && ./update.sh)
  # comunio
  mkdir -p comunio-news && (cd comunio-news && curl -fsSL https://raw.githubusercontent.com/unividuell/comunio-news/main/deploy/update.sh -o update.sh && chmod +x update.sh && ./update.sh)
  # mobility: dir already exists with the live SQLite at ./mobility-manager.db
  (cd mobility-manager && curl -fsSL https://raw.githubusercontent.com/unividuell/mobility-manager/main/deploy/update.sh -o update.sh && chmod +x update.sh && ./update.sh)
  ```
  Then fill each `.env` (edge `BASIC_AUTH_HASH`; countdown `POSTGRES_PASSWORD`/`GITHUB_CLIENT_SECRET`/pgadmin; mobility secret; comunio four keys).

- [ ] **2. Preserve mobility's SQLite into `./data/`** with correct ownership:
  ```bash
  cd /opt/unividuell/mobility-manager
  sudo mkdir -p data
  sudo mv mobility-manager.db data/ 2>/dev/null || true   # if it was at the dir root
  sudo chown -R 1002:1000 data
  ```

- [ ] **3. Create the shared network:**
  ```bash
  docker network create edge 2>/dev/null || true
  ```

- [ ] **4. Stop the old mashed stack** (frees 80/443; **mobility downtime starts**):
  ```bash
  cd /opt/unividuell && docker compose -f docker-compose.yml down
  ```

- [ ] **5. Bring up the new stacks** (edge first so it owns 80/443; it re-issues LE certs on a
  fresh `caddy-data` volume for all three domains on first request):
  ```bash
  (cd /opt/unividuell/edge-caddy && ./update.sh)
  (cd /opt/unividuell/mobility-manager && ./update.sh)
  (cd /opt/unividuell/countdown && ./update.sh)
  (cd /opt/unividuell/comunio-news && ./update.sh)   # redis only (app gated)
  ```

- [ ] **6. Verify:**
  ```bash
  curl -fsS -o /dev/null -w '%{http_code}\n' https://mobility.unividuell.org/actuator/health   # 200
  curl -fsS -o /dev/null -w '%{http_code}\n' https://countdown.unividuell.org/                  # 200 (SPA)
  curl -s -o /dev/null -w '%{http_code}\n' https://news.zingler46.unividuell.org/               # 401 (basicauth) then 502 once authed (app down) — expected
  ```
  Then test **countdown login end-to-end** in a browser (GitHub OAuth round-trip → lands back on
  `https://countdown.unividuell.org`, not :8080 / not `/api/me`).

- [ ] **7. Cleanup** (only after verification): archive + remove the old root-level files and the
  comunio repo's on-server edge bits:
  ```bash
  cd /opt/unividuell
  mkdir -p _archive-old-stack
  mv docker-compose.yml Caddyfile .env logs _archive-old-stack/ 2>/dev/null || true
  ```
  `/opt/unividuell/` stays as the parent of the per-project subdirs. Keep `_archive-old-stack`
  until everything has been stable for a while.

**Rollback** (if the new edge fails before cleanup): the old root files are still present —
```bash
cd /opt/unividuell
docker compose -f edge-caddy/compose.yaml --env-file edge-caddy/.env down 2>/dev/null || true
docker compose -f docker-compose.yml up -d
```
The old `caddy-data` volume is untouched, so certs are immediately valid again.

---

## Self-review

**Spec coverage** (`2026-06-12-shared-edge-design.md`):
- Shared `edge` network external + idempotent create → Tasks 2,4,7,9,10,12,13 + guideline (Task 5).
- edge-caddy repo (compose/Caddyfile/.env/update.sh/README) → Tasks 1–5.
- countdown adapt (`:80`, no 80/443, container_name, both nets, update.sh, rebuild image) → Tasks 6–8.
- mobility adapt (own compose, edge net, no 8080, SQLite preserve + chown 1002:1000) → Tasks 9–11 + cutover step 2.
- comunio adapt (app on edge + internal redis, drop 6379, basicauth at edge, disabled profile) → Tasks 12–14.
- `/opt/unividuell/<project>/` layout → READMEs (Tasks 5,8,11,14) + cutover steps.
- Restructure/retire old root files → cutover step 7 + rollback.
- Two-hop X-Forwarded for OAuth → guideline (Task 5) + countdown deployment.md (Task 8).
- Feed knowledge back → Task 5 guideline + Task 8 countdown deployment.md cross-link.

**Container-name consistency:** `countdown-web` (Tasks 6 edge route is `countdown-web:80`, Task 7 sets `container_name: countdown-web`) ✓; `mobility-manager` (edge `mobility-manager:8080`, Task 9 `container_name: mobility-manager`) ✓; `comunio-news-app` (edge `comunio-news-app:8080`, Task 12 `container_name: comunio-news-app`) ✓.

**Network-name consistency:** the external network is `edge` everywhere; the edge compose's project `name: edge-caddy` is distinct from the `edge` *network* (which is `external: true` and created out-of-band) ✓.

**Placeholder scan:** every file step contains full content; commands have expected output. No TBD/TODO.
