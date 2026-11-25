#!/usr/bin/env bash
# Sources deployment configuration and secrets into the current shell.
# This file intentionally does not read or create a .env file.
set -euo pipefail

: "${VAULT_NAME:?Set VAULT_NAME to the Azure Key Vault name}"

AZ_LOGIN_ARGS=(--identity)
if [[ -n "${IDENTITY_CLIENT_ID:-}" ]]; then
  AZ_LOGIN_ARGS+=(--client-id "$IDENTITY_CLIENT_ID")
fi

az login "${AZ_LOGIN_ARGS[@]}" >/dev/null

get_secret() {
  az keyvault secret show \
    --vault-name "$VAULT_NAME" \
    --name "$1" \
    --query value \
    --output tsv
}

load_secret() {
  local environment_name="$1"
  local secret_name="$2"
  local value
  value="$(get_secret "$secret_name")"
  [[ -n "$value" ]] || { echo "ERROR: Key Vault secret '$secret_name' is empty"; return 1; }
  export "$environment_name=$value"
  unset value
}

load_secret POSTGRES_PASSWORD polaris-postgres-password
load_secret POLARIS_ROOT_CLIENT_SECRET polaris-root-client-secret
load_secret POLARIS_TOKEN_BROKER_SECRET polaris-token-broker-secret
load_secret AZURE_CLIENT_SECRET polaris-azure-client-secret
load_secret TABLEFLOW_API_KEY polaris-tableflow-api-key
load_secret TABLEFLOW_API_SECRET polaris-tableflow-api-secret

export POSTGRES_USER="${POSTGRES_USER:-M73581}"
export POLARIS_ROOT_CLIENT_ID="${POLARIS_ROOT_CLIENT_ID:-M73580}"
export POLARIS_REALM="${POLARIS_REALM:-ISBUS}"
export TABLEFLOW_PROXY_BASE_URL="${TABLEFLOW_PROXY_BASE_URL:-https://tableflow.eastus2.azure.confluent.cloud}"
export POLARIS_CATALOG_NAME="${POLARIS_CATALOG_NAME:-tableflow}"
export POLARIS_ADMIN_CATALOG_ROLE="${POLARIS_ADMIN_CATALOG_ROLE:-tableflow_reader}"

for v in AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_STORAGE_ACCOUNT AZURE_STORAGE_CONTAINER \
         TABLEFLOW_ORG_ID TABLEFLOW_ENV_ID; do
  [[ -n "${!v:-}" ]] || { echo "ERROR: $v is not set as a shell environment variable"; return 1; }
done
