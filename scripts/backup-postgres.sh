#!/usr/bin/env bash
# Dumps the Polaris metastore (catalogs, principals, roles, grants) to
# ${BACKUP_DIR}/polaris-<UTC timestamp>.dump in pg_dump custom format and
# deletes dumps older than ${BACKUP_RETENTION_DAYS} days.
# Restore: pg_restore --clean --if-exists -d POLARIS <file>
# When BACKUP_STORAGE_ACCOUNT is set, each dump is also uploaded to the
# ${BACKUP_CONTAINER:-polaris-backups} blob container using the VM's managed
# identity (IDENTITY_CLIENT_ID), so backups survive the loss of the VM.
set -euo pipefail
BACKUP_DIR="${BACKUP_DIR:-/var/backups/polaris}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
[[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] || { echo "ERROR: BACKUP_RETENTION_DAYS must be a number" >&2; exit 2; }

# Located by Compose labels rather than `docker compose`, which would demand
# every deployment secret just to interpolate the file.
container="$(docker ps -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-polaris}" \
  --filter label=com.docker.compose.service=postgres)"
[[ -n "$container" ]] || { echo "ERROR: the postgres container is not running" >&2; exit 1; }

umask 077
mkdir -p "$BACKUP_DIR"
target="${BACKUP_DIR}/polaris-$(date -u +%Y%m%dT%H%M%SZ).dump"

# pg_dump runs inside the container as the database user over the local socket,
# so no password is needed here.
docker exec "$container" sh -c 'pg_dump -U "$POSTGRES_USER" -d POLARIS -Fc' >"${target}.tmp"
[[ -s "${target}.tmp" ]] || { rm -f "${target}.tmp"; echo "ERROR: pg_dump produced no output" >&2; exit 1; }
mv "${target}.tmp" "$target"
echo "Wrote $target"

if [[ -n "${BACKUP_STORAGE_ACCOUNT:-}" ]]; then
  login_args=(--identity --allow-no-subscriptions)
  [[ -n "${IDENTITY_CLIENT_ID:-}" ]] && login_args+=(--client-id "$IDENTITY_CLIENT_ID")
  az login "${login_args[@]}" >/dev/null || { echo "ERROR: managed-identity login failed; $target was not uploaded" >&2; exit 1; }
  az storage blob upload --auth-mode login --only-show-errors --output none \
    --account-name "$BACKUP_STORAGE_ACCOUNT" --container-name "${BACKUP_CONTAINER:-polaris-backups}" \
    --name "$(basename "$target")" --file "$target" \
    || { echo "ERROR: upload of $target failed" >&2; exit 1; }
  echo "Uploaded $(basename "$target") to $BACKUP_STORAGE_ACCOUNT/${BACKUP_CONTAINER:-polaris-backups}"
else
  echo "WARNING: BACKUP_STORAGE_ACCOUNT is not set; the backup exists only on this VM" >&2
fi

find "$BACKUP_DIR" -maxdepth 1 -name 'polaris-*.dump' -type f -mtime "+${BACKUP_RETENTION_DAYS}" -print -delete
