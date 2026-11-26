#!/usr/bin/env bash
# Exercises the federated catalog through Polaris as the bootstrap administrator:
# token -> /v1/config -> namespaces -> first table found in any namespace ->
# loadTable with vended-credentials.
# Exit status:
#   0  a table loaded, it is in the expected ADLS container, and Polaris vended
#      ADLS SAS credentials for it
#   1  a check failed
#   3  inconclusive: the catalog has no table yet, so credential vending and
#      data access are unproven
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

fail() { echo "FAILED: $*" >&2; exit 1; }

echo "==> Administrator token (${POLARIS_ROOT_CLIENT_ID}) from ${BASE}"
TOKEN="$(printf %s "$POLARIS_ROOT_CLIENT_SECRET" | "${CURL[@]}" -X POST "${BASE}/api/catalog/v1/oauth/tokens" \
  -H "Polaris-Realm: ${REALM}" \
  --data-urlencode grant_type=client_credentials --data-urlencode "client_id=${POLARIS_ROOT_CLIENT_ID}" \
  --data-urlencode client_secret@- --data-urlencode scope=PRINCIPAL_ROLE:ALL \
  | jq -r '.access_token // empty')" || TOKEN=""
[[ -n "$TOKEN" ]] || fail "token request to ${BASE} failed"
AUTH=(-H "Authorization: Bearer ${TOKEN}" -H "Polaris-Realm: ${REALM}")
echo "    token: OK (${#TOKEN} chars)"

# get <path> [curl-args...] -> prints the response body; fails on a non-2xx status
get() {
  local path="$1" out code
  shift
  out="$("${CURL[@]}" -w '\n%{http_code}' "${AUTH[@]}" "$@" "${BASE}${path}")" || out=$'\n000'
  code="${out##*$'\n'}"
  [[ "$code" =~ ^2 ]] || fail "GET ${path} returned HTTP ${code}: ${out%$'\n'*}"
  printf '%s\n' "${out%$'\n'*}"
}

echo "==> GET /api/catalog/v1/config?warehouse=${CATALOG}"
get "/api/catalog/v1/config?warehouse=${CATALOG}" | jq '{defaults, overrides}'

echo "==> GET /api/catalog/v1/${CATALOG}/namespaces"
ns_json="$(get "/api/catalog/v1/${CATALOG}/namespaces")" || {
  echo "Hint: Polaris loses the catalog's Tableflow secret on every restart;" >&2
  echo "      ./scripts/deploy-from-key-vault.sh re-establishes the connection." >&2
  exit 1
}
echo "$ns_json" | jq .

ns_label="" ns_path="" tname=""
while IFS= read -r ns; do
  ns_label="$(jq -r 'join(".")' <<<"$ns")"
  # Iceberg REST namespace path element = components joined by unit separator (0x1F)
  ns_path="$(jq -r 'join("\u001f") | @uri' <<<"$ns")"
  echo "==> Tables in namespace ${ns_label}"
  tables_json="$(get "/api/catalog/v1/${CATALOG}/namespaces/${ns_path}/tables")"
  echo "$tables_json" | jq .
  tname="$(jq -r '.identifiers[0].name // empty' <<<"$tables_json")"
  [[ -z "$tname" ]] || break
done < <(jq -c '.namespaces[]?' <<<"$ns_json")

if [[ -z "$tname" ]]; then
  echo "INCONCLUSIVE: catalog '${CATALOG}' has no table to load yet (Tableflow publishes a table" >&2
  echo "once a topic materializes). Credential vending and data access are NOT verified;" >&2
  echo "rerun this script when a table exists." >&2
  exit 3
fi
t_path="$(jq -rn --arg t "$tname" '$t | @uri')"

echo "==> loadTable ${ns_label}.${tname} with X-Iceberg-Access-Delegation: vended-credentials"
table="$(get "/api/catalog/v1/${CATALOG}/namespaces/${ns_path}/tables/${t_path}" \
  -H "X-Iceberg-Access-Delegation: vended-credentials")" || {
  echo "Hint: the table's location must fall under the catalog's storageConfigInfo.allowedLocations." >&2
  exit 1
}
summary="$(jq '{
  metadataLocation: .["metadata-location"],
  sasKeys: ([(.config // {}), (.["storage-credentials"][]?.config // {})]
    | map(keys[] | select(startswith("adls.sas-token"))) | unique)
}' <<<"$table")"
echo "$summary"

location="$(jq -r '.metadataLocation // ""' <<<"$summary")"
[[ -n "$location" ]] || fail "loadTable returned no metadata-location for ${ns_label}.${tname}"
if [[ -n "${AZURE_STORAGE_ACCOUNT:-}" && -n "${AZURE_STORAGE_CONTAINER:-}" ]]; then
  # abfss://<container>@<account>.dfs.core.windows.net/... or https://<account>.blob.core.windows.net/<container>/...
  if [[ "$location" != *"//${AZURE_STORAGE_CONTAINER}@${AZURE_STORAGE_ACCOUNT}."* \
     && "$location" != *"//${AZURE_STORAGE_ACCOUNT}."*"/${AZURE_STORAGE_CONTAINER}/"* ]]; then
    fail "${ns_label}.${tname} is at ${location}, not in container '${AZURE_STORAGE_CONTAINER}' of storage account '${AZURE_STORAGE_ACCOUNT}'"
  fi
else
  echo "    AZURE_STORAGE_ACCOUNT / AZURE_STORAGE_CONTAINER not set; table location not checked"
fi

if [[ "$(jq '.sasKeys | length' <<<"$summary")" -eq 0 ]]; then
  echo "Hint: check the Polaris service principal (AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET)," >&2
  echo "      its role on the storage account, and the credential-vending flags in" >&2
  echo "      configs/polaris/application.properties." >&2
  fail "Polaris vended no ADLS SAS credentials for ${ns_label}.${tname}; query engines cannot read its data"
fi
echo "All checks passed."
