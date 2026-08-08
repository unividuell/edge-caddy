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
  echo ".env created from template — fill in the values in .env, then re-run ./update.sh"
  exit 1
fi

# Preflight. {$VAR} placeholders resolve at `caddy adapt` time, and compose.yaml
# changes recreate the edge container — so a bad .env is a site-wide outage, not a
# failed reload. Abort before touching anything.

hash_help () {
  cat >&2 <<'HELP'
Every hash line in .env must have this exact shape — SINGLE quotes, 60 characters:
  NEWS_AUTH_HASH='$2a$14$.....................................................'
Docker Compose interpolates '$' in .env values and a bcrypt hash contains three of
them. Only single quotes survive: unquoted and DOUBLE-quoted hashes both reach Caddy
truncated, which starts fine and silently locks everyone out. A Caddy hash is always
exactly 60 characters. Generate one with:
  docker run --rm caddy:2-alpine caddy hash-password --plaintext '<password>'
HELP
}

# Required usernames: present and non-empty (quotes, if any, do not count as content).
missing=""
for v in NEWS_AUTH_USER_1 NEWS_AUTH_USER_2 STATS_AUTH_USER_1; do
  val=$(grep -E "^${v}=" .env | tail -1 | cut -d= -f2-)
  val=$(printf '%s' "$val" | sed "s/^['\"]//; s/['\"]\$//")
  [ -n "$val" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
  echo "ERROR: .env is missing or empty for:$missing" >&2
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
    echo "Note: BASIC_AUTH_HASH was renamed to NEWS_AUTH_HASH." >&2
    hash_help
    exit 1
  fi
  if ! printf '%s\n' "$hline" | grep -q "^${hv}='.\{60\}'\$"; then
    echo "ERROR: $hv in .env is not a valid Caddy password hash line." >&2
    hash_help
    exit 1
  fi
}

for v in NEWS_AUTH_HASH STATS_AUTH_HASH_1; do
  check_hash "$v"
done

# Stats slots 2 and 3 are optional: absent, commented out or left empty is fine —
# compose.yaml then falls back to a placeholder credential nobody can log in with.
# A slot that IS filled in must be as well-formed as any other.
for v in STATS_AUTH_HASH_2 STATS_AUTH_HASH_3; do
  line=$(grep -E "^${v}=" .env | tail -1) || true
  [ -n "$line" ] || continue
  val=$(printf '%s' "$line" | cut -d= -f2-)
  case "$val" in ""|"''"|'""') continue ;; esac
  check_hash "$v"
done

mkdir -p logs report

# GoAccess references this as <script src='attribution.js'>, resolved against the report
# URL — so it belongs next to index.html, not with the infra files above. report/ is
# git-ignored, hence the fetch here rather than at the top with the others.
curl -fsSL "$BASE/attribution.js" -o report/attribution.js

docker network create edge 2>/dev/null || true
docker compose --env-file .env -f compose.yaml pull

# Last gate before anything is recreated: adapt the real, bind-mounted Caddyfile with the
# real .env in a throwaway container. `up -d` recreates the edge container whenever
# compose.yaml changed, so a config error surviving the checks above is a site-wide
# outage. --no-deps leaves goaccess alone, --rm leaves nothing behind, and `run` publishes
# no ports, so the currently running edge is untouched.
echo "Validating Caddyfile against .env ..."
if ! docker compose --env-file .env -f compose.yaml run --rm --no-deps -T \
     --entrypoint sh caddy -c 'caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile'; then
  echo "ERROR: caddy validate failed (see above). Nothing was changed — fix the config first." >&2
  exit 1
fi

docker compose --env-file .env -f compose.yaml up -d
# The Caddyfile is bind-mounted; `up -d` does NOT recreate the container on a config-only
# change, so reload Caddy explicitly to pick up Caddyfile edits (new sites/routes).
docker compose --env-file .env -f compose.yaml exec -T caddy caddy reload --config /etc/caddy/Caddyfile
docker image prune -f
echo "Edge update complete."
