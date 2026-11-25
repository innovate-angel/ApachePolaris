#!/usr/bin/env bash
# Exercises the federated catalog through Polaris as the bootstrap administrator:
# token -> /v1/config -> namespaces -> first namespace's tables -> loadTable
# with vended-credentials (checks whether ADLS SAS keys are vended).
# Requires curl + jq. Set CURL_INSECURE=1 for self-signed certs.
set -euo pipefail
cd "$(dirname "$0")/.."

for v in POLARIS_ROOT_CLIENT_ID POLARIS_ROOT_CLIENT_SECRET; do
  [[ -n "${!v:-}" ]] || { echo "ERROR: $v is not set in the environment"; exit 1; }
done

REALM="${POLARIS_REALM:-ISBUS}"
CURL=(curl -sS)
[[ "${CURL_INSECURE:-0}" == "1" ]] && CURL+=(-k)

BASE="${POLARIS_URL:-http://localhost:8181}"
CATALOG="${POLARIS_CATALOG_NAME:-tableflow}"

echo "==> Administrator token (${POLARIS_ROOT_CLIENT_ID}) from ${BASE}"
TOKEN="$("${CURL[@]}" -X POST "${BASE}/api/catalog/v1/oauth/tokens" \
  -H "Polaris-Realm: ${REALM}" \
  -d "grant_type=client_credentials&client_id=${POLARIS_ROOT_CLIENT_ID}&client_secret=${POLARIS_ROOT_CLIENT_SECRET}&scope=PRINCIPAL_ROLE:ALL" \
  | jq -r .access_token)"
[[ "$TOKEN" != "null" && -n "$TOKEN" ]] || { echo "ERROR: token request failed"; exit 1; }
AUTH=(-H "Authorization: Bearer ${TOKEN}" -H "Polaris-Realm: ${REALM}")
echo "    token: OK (${#TOKEN} chars)"

echo "==> GET /api/catalog/v1/config?warehouse=${CATALOG}"
"${CURL[@]}" "${AUTH[@]}" "${BASE}/api/catalog/v1/config?warehouse=${CATALOG}" \
  | jq '{defaults, overrides}'

echo "==> GET /api/catalog/v1/${CATALOG}/namespaces"
ns_json="$("${CURL[@]}" "${AUTH[@]}" "${BASE}/api/catalog/v1/${CATALOG}/namespaces")"
echo "$ns_json" | jq .

first_ns="$(jq -c '.namespaces[0] // empty' <<<"$ns_json")"
if [[ -z "$first_ns" ]]; then
  echo "No namespaces in the federated catalog yet (Tableflow syncs on topic materialization)."
  exit 0
fi
ns_label="$(jq -r 'join(".")' <<<"$first_ns")"
# Iceberg REST namespace path element = components joined by unit separator (0x1F)
ns_path="$(jq -r 'join("") | @uri' <<<"$first_ns")"

echo "==> Tables in namespace ${ns_label}"
tables_json="$("${CURL[@]}" "${AUTH[@]}" "${BASE}/api/catalog/v1/${CATALOG}/namespaces/${ns_path}/tables")"
echo "$tables_json" | jq .
tname="$(jq -r '.identifiers[0].name // empty' <<<"$tables_json")"
[[ -n "$tname" ]] || { echo "No tables in namespace ${ns_label} yet."; exit 0; }
t_path="$(jq -rn --arg t "$tname" '$t | @uri')"

echo "==> loadTable ${ns_label}.${tname} with X-Iceberg-Access-Delegation: vended-credentials"
lt="$("${CURL[@]}" -w '\n%{http_code}' "${AUTH[@]}" -H "X-Iceberg-Access-Delegation: vended-credentials" \
  "${BASE}/api/catalog/v1/${CATALOG}/namespaces/${ns_path}/tables/${t_path}")" || lt="${lt:-}"$'\n'"000"
c="${lt##*$'\n'}"
if [[ "$c" =~ ^2 ]]; then
  echo "${lt%$'\n'*}" | jq '{metadataLocation: .["metadata-location"], sasKeys: (.config | keys | map(select(startswith("adls.sas-token"))))}'
  echo "All checks passed."
else
  echo "loadTable failed (HTTP $c):"
  echo "${lt%$'\n'*}" | jq . 2>/dev/null || echo "${lt%$'\n'*}"
  echo "Hint: the table's location must fall under the catalog's storageConfigInfo.allowedLocations."
  exit 1
fi
