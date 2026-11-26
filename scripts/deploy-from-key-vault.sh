#!/usr/bin/env bash
# Authenticate through Azure Managed Identity, load transient secrets from
# Key Vault, deploy and configure Polaris, then remove secret variables on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

for command in az docker curl jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: required command '$command' is not installed"
    exit 1
  }
done
docker compose version >/dev/null

source scripts/load-key-vault-env.sh

cleanup() {
  unset POSTGRES_PASSWORD \
    POLARIS_DB_PASSWORD \
    POLARIS_ROOT_CLIENT_SECRET \
    POLARIS_TOKEN_BROKER_SECRET \
    AZURE_CLIENT_SECRET \
    TABLEFLOW_API_KEY \
    TABLEFLOW_API_SECRET
}
trap cleanup EXIT

docker compose config -q
docker compose up -d postgres
docker compose ps

./scripts/bootstrap.sh
docker compose up -d --wait polaris

./scripts/check-tableflow.sh
./scripts/setup-tableflow-federation.sh
./scripts/verify.sh
