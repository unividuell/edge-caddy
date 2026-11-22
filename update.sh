#!/usr/bin/env sh
# Full update: fetch latest infra files from main, ensure the edge network, pull, build the
# edge image, validate, restart.
set -eu
BASE="https://raw.githubusercontent.com/unividuell/edge-caddy/main"

# compose.yaml and the Caddyfile are staged as *.new and replace the live files only once
# the validation gate below has passed. The live Caddyfile is bind-mounted into the running
# edge and is what its next restart loads — a new one may need an image that an aborted run
# never built (the Cloudflare plugin), so an abort must leave both files as they were.
# Leftover *.new files from an aborted run are simply overwritten by the next one.
curl -fsSL "$BASE/compose.yaml" -o compose.yaml.new
curl -fsSL "$BASE/Caddyfile"    -o Caddyfile.new
curl -fsSL "$BASE/README.md"    -o README.md
curl -fsSL "$BASE/update.sh"    -o update.sh.new && chmod +x update.sh.new
# A changed script restarts itself: the old one would miss newly added files, and docker
# then bind-mounts a missing file as an empty root-owned directory.
if cmp -s update.sh.new update.sh; then rm update.sh.new; else mv update.sh.new update.sh; exec ./update.sh "$@"; fi

# Edge image: built here from caddy/Dockerfile (caddy:2-alpine + the Cloudflare DNS plugin).
mkdir -p caddy
curl -fsSL "$BASE/caddy/Dockerfile" -o caddy/Dockerfile

# klang.unividuell.org: one static page, versioned here (README, "Sound test").
mkdir -p klang
curl -fsSL "$BASE/klang/index.html" -o klang/index.html

# Monitoring stack config (edge-lgtm). A new dashboard needs its own line here.
mkdir -p monitoring/dashboards
curl -fsSL "$BASE/monitoring/otelcol-config.yaml"    -o monitoring/otelcol-config.yaml
curl -fsSL "$BASE/monitoring/grafana-dashboards.yaml" -o monitoring/grafana-dashboards.yaml
curl -fsSL "$BASE/monitoring/grafana-alerting.yaml"   -o monitoring/grafana-alerting.yaml
curl -fsSL "$BASE/monitoring/grafana-no-sample-dashboards.yaml" -o monitoring/grafana-no-sample-dashboards.yaml
for d in countdown mobility-manager server; do
  curl -fsSL "$BASE/monitoring/dashboards/$d.json" -o "monitoring/dashboards/$d.json"
done

if [ ! -f .env ]; then
  curl -fsSL "$BASE/.env.example" -o .env
  echo ".env created from template — fill in the values in .env, then re-run ./update.sh"
  exit 1
fi

# Preflight. {$VAR} placeholders resolve at `caddy adapt` time, and compose.yaml
# changes recreate the edge container — so a bad .env is a site-wide outage, not a
# failed reload. Abort before touching anything.

hash_help () {
  cat >&2 <<'HELP'
Every hash line in .env must have this exact shape — SINGLE quotes, 60 characters:
  STATS_AUTH_HASH='$2a$14$.....................................................'
Docker Compose interpolates '$' in .env values and a bcrypt hash contains three of
them. Only single quotes survive: unquoted and DOUBLE-quoted hashes both reach Caddy
truncated, which starts fine and silently locks everyone out. A Caddy hash is always
exactly 60 characters. Generate one with:
  docker run --rm caddy:2-alpine caddy hash-password --plaintext '<password>'
HELP
}

# Required usernames and passwords: present and non-empty (quotes, if any, do not count as content).
missing=""
for v in STATS_AUTH_USER COUNTDOWN_DB_MONITOR_PASSWORD ALERT_SMTP_USER ALERT_SMTP_PASSWORD ALERT_EMAIL_TO CLOUDFLARE_API_TOKEN; do
  val=$(grep -E "^${v}=" .env | tail -1 | cut -d= -f2-)
  val=$(printf '%s' "$val" | sed "s/^['\"]//; s/['\"]\$//")
  [ -n "$val" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
  echo "ERROR: .env is missing or empty for:$missing" >&2
  echo "Note: MONITORING_AUTH_USER_1 / _HASH_1 were renamed to STATS_AUTH_USER / STATS_AUTH_HASH." >&2
  case "$missing" in *CLOUDFLARE_API_TOKEN*)
    echo "Note: CLOUDFLARE_API_TOKEN is the wildcard certificate's DNS token — scope and how to create it: .env.example." >&2 ;;
  esac
  exit 1
fi

# Hashes. Compose interpolates '$' in .env values, so an unquoted bcrypt hash is
# silently truncated — `caddy adapt` still succeeds and you are simply locked out, with
# no error anywhere — and an empty one makes `caddy adapt` fail outright, crash-looping
# the freshly recreated container. Requiring the single-quoted, exactly-60-character
# form rejects the empty, the unquoted, the double-quoted and the wrong-length case
# with one rule.
check_hash () {
  hv="$1"
  hline=$(grep -E "^${hv}=" .env | tail -1) || true
  if [ -z "$hline" ]; then
    echo "ERROR: $hv is missing from .env." >&2
    echo "Note: MONITORING_AUTH_HASH_1 was renamed to STATS_AUTH_HASH." >&2
    hash_help
    exit 1
  fi
  if ! printf '%s\n' "$hline" | grep -q "^${hv}='.\{60\}'\$"; then
    echo "ERROR: $hv in .env is not a valid Caddy password hash line." >&2
    hash_help
    exit 1
  fi
}

for v in STATS_AUTH_HASH; do
  check_hash "$v"
done

mkdir -p logs filetransfer prueffahrt
# First deploy only: nothing runs yet, and the gate's throwaway container bind-mounts
# ./Caddyfile — a missing one would come back as an empty root-owned directory.
[ -e Caddyfile ] || cp Caddyfile.new Caddyfile

docker network create edge 2>/dev/null || true
docker network create monitoring 2>/dev/null || true

# edge-lgtm reads docker's json-file logs; another driver leaves the log panels empty
# without any error. Warn only: the edge itself works either way.
if [ "$(docker info --format '{{.LoggingDriver}}')" != "json-file" ]; then
  echo "WARNING: docker's default log driver is not json-file — container logs will not reach monitoring (README, \"One-time setup\")." >&2
fi
docker compose --env-file .env -f compose.yaml.new pull --ignore-buildable

# The edge image is built, not pulled. Caddy and the Cloudflare plugin both follow their
# latest release: `--pull` picks up a new caddy:2-builder / caddy:2-alpine, and the
# plugin's latest version, resolved here, is passed in as a build arg — so a new plugin
# release busts the build cache the same way. If neither changed, the cached image is
# reused and `up -d` leaves the running container alone. Without the Go proxy the build
# falls back to `latest` (and to the cache, if the base images did not change either); the
# time limits keep a blackholed proxy from stalling the whole update.
CF_PLUGIN_VERSION=$(curl -fsSL --connect-timeout 5 --max-time 20 https://proxy.golang.org/github.com/caddy-dns/cloudflare/@latest | sed -n 's/.*"Version":"\([^"]*\)".*/\1/p')
CF_PLUGIN_VERSION=${CF_PLUGIN_VERSION:-latest}
echo "Building the edge image with caddy-dns/cloudflare $CF_PLUGIN_VERSION ..."
docker compose --env-file .env -f compose.yaml.new build --pull --build-arg CF_PLUGIN_VERSION="$CF_PLUGIN_VERSION" caddy

# Last gate before anything is recreated: adapt the fetched Caddyfile (on stdin) with the
# real .env and the new compose.yaml in a throwaway container. `up -d` recreates the edge
# container whenever compose.yaml or the image changed, so a config error surviving the
# checks above is a site-wide outage. It runs on the image just built, so it also catches an
# image without the DNS plugin and a malformed CLOUDFLARE_API_TOKEN: the plugin checks the
# token's shape on provisioning, and a bad one stops the whole config, every site.
# --no-deps leaves the other services alone, --rm leaves nothing behind, and `run`
# publishes no ports, so the currently running edge is untouched.
echo "Validating Caddyfile against .env ..."
if ! docker compose --env-file .env -f compose.yaml.new run --rm --no-deps -T \
     --entrypoint sh caddy -c 'caddy validate --adapter caddyfile --config /dev/stdin' < Caddyfile.new; then
  echo "ERROR: caddy validate failed (see above). Nothing was deployed: the running edge, its Caddyfile and compose.yaml are unchanged — fix the config first." >&2
  exit 1
fi

# Gate passed: put the new files in place. `cat >` rewrites the Caddyfile in place — it is
# bind-mounted into the running edge by inode, and `mv` would leave the container (and the
# reload below) on the old file.
cat Caddyfile.new > Caddyfile && rm Caddyfile.new
cat compose.yaml.new > compose.yaml && rm compose.yaml.new

docker compose --env-file .env -f compose.yaml up -d
# The Caddyfile is bind-mounted; `up -d` does NOT recreate the container on a config-only
# change, so reload Caddy explicitly to pick up Caddyfile edits (new sites/routes).
docker compose --env-file .env -f compose.yaml exec -T caddy caddy reload --config /etc/caddy/Caddyfile
# Same for edge-lgtm: its collector reads the bind-mounted config only at start.
docker compose --env-file .env -f compose.yaml restart lgtm
docker image prune -f
echo "Edge update complete."
