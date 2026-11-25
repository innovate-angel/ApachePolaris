#!/usr/bin/env bash
# Bootstrap the configured Polaris realm (one-off). Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
REALM="${POLARIS_REALM:-ISBUS}"

for v in POSTGRES_PASSWORD POLARIS_ROOT_CLIENT_SECRET POLARIS_ROOT_CLIENT_ID POLARIS_TOKEN_BROKER_SECRET; do
  [[ -n "${!v:-}" ]] || { echo "ERROR: $v is not set in the environment"; exit 1; }
done

out="$(docker compose --profile bootstrap run --rm polaris-bootstrap 2>&1)" || {
  echo "$out"
  if grep -qiE "already (bootstrapped|exists)" <<<"$out"; then
    echo "Realm ${REALM} was already bootstrapped; nothing to do."
    exit 0
  fi
  exit 1
}
echo "$out"
