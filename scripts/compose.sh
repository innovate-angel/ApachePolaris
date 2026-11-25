#!/usr/bin/env bash
# Run day-to-day Compose operations with deployment secrets loaded transiently
# from Azure Key Vault. Avoid printing the resolved Compose config.
set -euo pipefail
cd "$(dirname "$0")/.."

for arg in "$@"; do
  if [[ "$arg" == "config" ]]; then
    if [[ "$#" -ne 2 || "${1:-}" != "config" || "${2:-}" != "-q" ]]; then
      echo "ERROR: only 'config -q' is allowed; resolved Compose config contains secrets"
      exit 2
    fi
  fi
done

source scripts/load-key-vault-env.sh
exec docker compose "$@"
