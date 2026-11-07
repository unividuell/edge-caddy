#!/usr/bin/env bash
# Mirrors the server's backup dirs to this machine (the home server "thin") and reports each
# run to edge-lgtm. thin cannot be reached from the internet, so it pulls. Run by
# backup-mirror.timer; setup in README.md (section "Backup mirror").
#
#   thin ── ssh (one key per app: read-only rrsync on its backup dir) ──> server
#   thin ── ssh tunnel :14318 → server 127.0.0.1:4318 ── OTLP ──> edge-lgtm
set -uo pipefail

SERVER=ubuntu@158.101.161.126
KEYS="$HOME/.ssh"

# app → backup dir, the same path on both sides. Each app has its own key backup-mirror-<app>.
declare -A APPS=(
  [countdown]=/opt/unividuell/countdown/backups
  [mobility-manager]=/opt/unividuell/mobility-manager/backups
)

ssh_opts() { echo "-i $KEYS/backup-mirror-$1 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"; }

# Sends one app's gauges as OTLP JSON through a short-lived tunnel. Names arrive in
# Prometheus as backup_mirror_last_success_timestamp_seconds etc., labelled app="<app>".
report() {
  local app=$1 now=$2 age=$3 bytes=$4 tunnel ok=1
  local attrs="[{\"key\":\"app\",\"value\":{\"stringValue\":\"$app\"}}]"
  local ts=$((now * 1000000000))
  gauge() { echo "{\"name\":\"$1\",\"unit\":\"$2\",\"gauge\":{\"dataPoints\":[{\"attributes\":$attrs,\"timeUnixNano\":\"$ts\",\"asInt\":\"$3\"}]}}"; }
  local body="{\"resourceMetrics\":[{\"resource\":{\"attributes\":[
    {\"key\":\"service.namespace\",\"value\":{\"stringValue\":\"backup-mirror\"}},
    {\"key\":\"service.name\",\"value\":{\"stringValue\":\"$(hostname)\"}},
    {\"key\":\"deployment.environment.name\",\"value\":{\"stringValue\":\"production\"}}]},
    \"scopeMetrics\":[{\"metrics\":[
      $(gauge backup_mirror_last_success_timestamp_seconds s "$now"),
      $(gauge backup_mirror_newest_backup_age_seconds s "$age"),
      $(gauge backup_mirror_size_bytes By "$bytes")]}]}]}"

  # shellcheck disable=SC2046
  ssh $(ssh_opts "$app") -N -o ExitOnForwardFailure=yes -L 14318:127.0.0.1:4318 "$SERVER" &
  tunnel=$!
  for _ in $(seq 20); do
    curl -fsS -o /dev/null -H 'Content-Type: application/json' --data "$body" \
      http://127.0.0.1:14318/v1/metrics 2>/dev/null && { ok=0; break; }
    sleep 1
  done
  kill "$tunnel" 2>/dev/null
  wait "$tunnel" 2>/dev/null
  return $ok
}

failed=0
for app in "${!APPS[@]}"; do
  dir=${APPS[$app]}

  # The forced rrsync roots the path at the app's dir: "./" is that dir on the server.
  # shellcheck disable=SC2046
  if ! rsync -a --delete -e "ssh $(ssh_opts "$app")" "$SERVER:./" "$dir/"; then
    echo "$app: rsync failed" >&2; failed=1; continue
  fi

  # rsync -a keeps the server's mtimes: the newest file's age says whether the server
  # still writes backups. E.g. 3600 = the last dump is an hour old.
  now=$(date +%s)
  newest=$(find "$dir" -type f -printf '%T@\n' | sort -n | tail -1)
  age=$(( now - ${newest%.*} ))
  bytes=$(du -sb "$dir" | cut -f1)

  if report "$app" "$now" "$age" "$bytes"; then
    echo "$app: mirrored, newest backup ${age}s old, $bytes bytes"
  else
    echo "$app: mirrored, but the report failed" >&2; failed=1
  fi
done
exit $failed
