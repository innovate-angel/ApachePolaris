#!/usr/bin/env bash
# Direct check of the VM -> Tableflow path, bypassing Polaris.
# Separates Tableflow connectivity problems from Polaris federation problems.
# Requires curl + jq. Set CURL_INSECURE=1 for self-signed certs (testing only).
set -euo pipefail
cd "$(dirname "$0")/.."

for v in TABLEFLOW_PROXY_BASE_URL TABLEFLOW_ORG_ID TABLEFLOW_ENV_ID TABLEFLOW_API_KEY TABLEFLOW_API_SECRET; do
  [[ -n "${!v:-}" ]] || { echo "ERROR: $v is not set in the environment"; exit 1; }
done

CURL=(curl -fsS)
[[ "${CURL_INSECURE:-0}" == "1" ]] && CURL+=(-k)

CATALOG_URI="${TABLEFLOW_CATALOG_URI:-${TABLEFLOW_PROXY_BASE_URL%/}/iceberg/catalog/organizations/${TABLEFLOW_ORG_ID}/environments/${TABLEFLOW_ENV_ID}}"
TOKEN_URI="${TABLEFLOW_TOKEN_URI:-${CATALOG_URI}/v1/oauth/tokens}"

echo "==> Token from ${TOKEN_URI}"
# The secret is passed on stdin so it never appears in the process list.
args=(--data-urlencode grant_type=client_credentials --data-urlencode "client_id=${TABLEFLOW_API_KEY}" --data-urlencode client_secret@-)
[[ -n "${TABLEFLOW_OAUTH_SCOPE:-}" ]] && args+=(--data-urlencode "scope=${TABLEFLOW_OAUTH_SCOPE}")
TOKEN="$(printf %s "$TABLEFLOW_API_SECRET" | "${CURL[@]}" -X POST "${TOKEN_URI}" "${args[@]}" | jq -r '.access_token // empty')"
[[ -n "$TOKEN" ]] || { echo "ERROR: Tableflow token request to ${TOKEN_URI} failed" >&2; exit 1; }
echo "    token: OK (${#TOKEN} chars)"

echo "==> GET ${CATALOG_URI}/v1/config"
"${CURL[@]}" -H "Authorization: Bearer ${TOKEN}" "${CATALOG_URI}/v1/config" | jq '{defaults, overrides}'
echo "    (note any absolute URLs / uri overrides above)"

echo "==> GET ${CATALOG_URI}/v1/namespaces"
"${CURL[@]}" -H "Authorization: Bearer ${TOKEN}" "${CATALOG_URI}/v1/namespaces" | jq .
