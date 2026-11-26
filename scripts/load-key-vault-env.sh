#!/usr/bin/env bash
# Sources deployment configuration and secrets into the current shell.
# This file intentionally does not read or create a .env file.

# Compose otherwise auto-loads a local .env file. Deployment config and secrets
# must come from the caller's environment and Key Vault, not a persisted file.
export COMPOSE_DISABLE_ENV_FILE=1

if [[ -z "${VAULT_NAME:-}" ]]; then
  echo "ERROR: Set VAULT_NAME to the Azure Key Vault name" >&2
  return 1
fi

AZ_LOGIN_ARGS=(--identity --allow-no-subscriptions)
if [[ -n "${IDENTITY_CLIENT_ID:-}" ]]; then
  AZ_LOGIN_ARGS+=(--client-id "$IDENTITY_CLIENT_ID")
fi

if ! az login "${AZ_LOGIN_ARGS[@]}" >/dev/null; then
  echo "ERROR: Azure managed-identity login failed" >&2
  return 1
fi

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
  if ! value="$(get_secret "$secret_name")"; then
    echo "ERROR: Could not retrieve Key Vault secret '$secret_name'" >&2
    return 1
  fi
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

for v in POLARIS_BIND_ADDRESS AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_STORAGE_ACCOUNT AZURE_STORAGE_CONTAINER \
         TABLEFLOW_ORG_ID TABLEFLOW_ENV_ID; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: $v is not set as a shell environment variable" >&2
    return 1
  fi
done

# Port 8181 is published only on POLARIS_BIND_ADDRESS, which is usually the VM
# private IP rather than localhost.
export POLARIS_URL="${POLARIS_URL:-http://${POLARIS_BIND_ADDRESS}:8181}"
