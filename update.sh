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

docker network create edge 2>/dev/null || true
docker compose --env-file .env -f compose.yaml pull
docker compose --env-file .env -f compose.yaml up -d
# The Caddyfile is bind-mounted; `up -d` does NOT recreate the container on a config-only
# change, so reload Caddy explicitly to pick up Caddyfile edits (new sites/routes).
docker compose --env-file .env -f compose.yaml exec -T caddy caddy reload --config /etc/caddy/Caddyfile
docker image prune -f
echo "Edge update complete."
