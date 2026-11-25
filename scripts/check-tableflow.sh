#!/usr/bin/env bash
# Direct check of the VM -> Tableflow path, bypassing Polaris.
# Separates Tableflow connectivity problems from Polaris federation problems.
# Requires curl + jq. Set CURL_INSECURE=1 for self-signed certs (testing only).
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

for v in TABLEFLOW_PROXY_BASE_URL TABLEFLOW_ORG_ID TABLEFLOW_ENV_ID TABLEFLOW_API_KEY TABLEFLOW_API_SECRET; do
  [[ -n "${!v:-}" ]] || { echo "ERROR: $v is not set in .env"; exit 1; }
done

CURL=(curl -fsS)
[[ "${CURL_INSECURE:-0}" == "1" ]] && CURL+=(-k)

CATALOG_URI="${TABLEFLOW_CATALOG_URI:-${TABLEFLOW_PROXY_BASE_URL%/}/iceberg/catalog/organizations/${TABLEFLOW_ORG_ID}/environments/${TABLEFLOW_ENV_ID}}"
TOKEN_URI="${TABLEFLOW_TOKEN_URI:-${CATALOG_URI}/v1/oauth/tokens}"

echo "==> Token from ${TOKEN_URI}"
data="grant_type=client_credentials&client_id=${TABLEFLOW_API_KEY}&client_secret=${TABLEFLOW_API_SECRET}"
[[ -n "${TABLEFLOW_OAUTH_SCOPE:-}" ]] && data="${data}&scope=${TABLEFLOW_OAUTH_SCOPE}"
TOKEN="$("${CURL[@]}" -X POST "${TOKEN_URI}" -d "$data" | jq -r .access_token)"
echo "    token: OK (${#TOKEN} chars)"

echo "==> GET ${CATALOG_URI}/v1/config"
"${CURL[@]}" -H "Authorization: Bearer ${TOKEN}" "${CATALOG_URI}/v1/config" | jq '{defaults, overrides}'
echo "    (note any absolute URLs / uri overrides above)"

echo "==> GET ${CATALOG_URI}/v1/namespaces"
"${CURL[@]}" -H "Authorization: Bearer ${TOKEN}" "${CATALOG_URI}/v1/namespaces" | jq .
