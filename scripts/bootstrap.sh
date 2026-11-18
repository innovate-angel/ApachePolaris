#!/usr/bin/env bash
# Bootstrap the POLARIS realm (one-off). Safe to re-run: reports if already done.
set -euo pipefail
cd "$(dirname "$0")/.."

out="$(docker compose --profile bootstrap run --rm polaris-bootstrap 2>&1)" || {
  echo "$out"
  if grep -qiE "already (bootstrapped|exists)" <<<"$out"; then
    echo "Realm POLARIS was already bootstrapped; nothing to do."
    exit 0
  fi
  exit 1
}
echo "$out"
