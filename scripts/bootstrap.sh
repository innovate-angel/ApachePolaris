#!/usr/bin/env bash
# Bootstrap the configured Polaris realm (one-off). Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
REALM="${POLARIS_REALM:-ISBUS}"

out="$(docker compose --profile bootstrap run --rm polaris-bootstrap 2>&1)" || {
  echo "$out"
  if grep -qiE "already (bootstrapped|exists)" <<<"$out"; then
    echo "Realm ${REALM} was already bootstrapped; nothing to do."
    exit 0
  fi
  exit 1
}
echo "$out"
