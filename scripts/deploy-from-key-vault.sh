#!/usr/bin/env bash
# Authenticate through Azure Managed Identity, load transient secrets from
# Key Vault, deploy PostgreSQL/Polaris, and remove secret variables on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/load-key-vault-env.sh

cleanup() {
  unset POSTGRES_PASSWORD \
    POLARIS_ROOT_CLIENT_SECRET \
    POLARIS_TOKEN_BROKER_SECRET \
    AZURE_CLIENT_SECRET \
    TABLEFLOW_API_KEY \
    TABLEFLOW_API_SECRET
}
trap cleanup EXIT

docker compose pull
docker compose up -d postgres
docker compose ps

./scripts/bootstrap.sh
docker compose up -d polaris

./scripts/check-tableflow.sh
