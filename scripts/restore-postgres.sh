#!/usr/bin/env bash
# Restores a dump written by backup-postgres.sh into the running PostgreSQL
# container, replacing the current Polaris metastore. Polaris is stopped first
# and left stopped; start it again with ./scripts/deploy-from-key-vault.sh
# once this prints "RESTORE OK". The restore runs in one transaction, so a
# failure leaves the database unchanged.
# Usage: restore-postgres.sh <dump-file>
set -euo pipefail

dump="${1:-}"
[[ -n "$dump" ]] || { echo "Usage: $0 <dump-file>" >&2; exit 2; }
[[ -s "$dump" ]] || { echo "ERROR: $dump not found or empty" >&2; exit 1; }

# Located by Compose labels rather than `docker compose`, which would demand
# every deployment secret just to interpolate the file.
find_container() {
  docker ps -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-polaris}" \
    --filter "label=com.docker.compose.service=$1"
}

postgres="$(find_container postgres)"
[[ -n "$postgres" ]] || {
  echo "ERROR: the postgres container is not running; start it with: ./scripts/compose.sh up -d --wait postgres" >&2
  exit 1
}

polaris="$(find_container polaris)"
if [[ -n "$polaris" ]]; then
  echo "==> Stopping Polaris"
  docker stop "$polaris" >/dev/null
fi

echo "==> Restoring $dump"
docker exec -i "$postgres" \
  sh -c 'pg_restore --clean --if-exists --single-transaction -U "$POSTGRES_USER" -d POLARIS' <"$dump"
echo "RESTORE OK"
