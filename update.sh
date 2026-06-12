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
