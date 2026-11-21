#!/usr/bin/env bash
# Creates the EXTERNAL (federated) Polaris catalog that proxies live to the
# Confluent Tableflow Iceberg REST catalog, then grants the bootstrap
# service_admin principal role read/manage access to it. Idempotent.
# Requires: curl, jq. Set CURL_INSECURE=1 for self-signed certs (testing only).
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

REALM="${POLARIS_REALM:-ISBUS}"

for v in AZURE_TENANT_ID AZURE_STORAGE_ACCOUNT AZURE_STORAGE_CONTAINER \
         TABLEFLOW_PROXY_BASE_URL TABLEFLOW_ORG_ID TABLEFLOW_ENV_ID \
         TABLEFLOW_API_KEY TABLEFLOW_API_SECRET \
         POLARIS_ROOT_CLIENT_ID POLARIS_ROOT_CLIENT_SECRET; do
  [[ -n "${!v:-}" ]] || { echo "ERROR: $v is not set in .env"; exit 1; }
done

CURL=(curl -sS)
[[ "${CURL_INSECURE:-0}" == "1" ]] && CURL+=(-k)

POLARIS_URL="${POLARIS_URL:-http://localhost:8181}"
MGMT="${POLARIS_URL}/api/management/v1"
CATALOG="${POLARIS_CATALOG_NAME:-tableflow}"
CATALOG_ROLE="${POLARIS_ADMIN_CATALOG_ROLE:-tableflow_reader}"
BASE_LOC="abfss://${AZURE_STORAGE_CONTAINER}@${AZURE_STORAGE_ACCOUNT}.dfs.core.windows.net/"

CATALOG_URI="${TABLEFLOW_CATALOG_URI:-${TABLEFLOW_PROXY_BASE_URL%/}/iceberg/catalog/organizations/${TABLEFLOW_ORG_ID}/environments/${TABLEFLOW_ENV_ID}}"
TOKEN_URI="${TABLEFLOW_TOKEN_URI:-${CATALOG_URI}/v1/oauth/tokens}"

echo "==> Getting Polaris administrator token (${POLARIS_ROOT_CLIENT_ID}) from ${POLARIS_URL}"
resp="$("${CURL[@]}" -X POST "${POLARIS_URL}/api/catalog/v1/oauth/tokens" \
  -H "Polaris-Realm: ${REALM}" \
  -d "grant_type=client_credentials&client_id=${POLARIS_ROOT_CLIENT_ID}&client_secret=${POLARIS_ROOT_CLIENT_SECRET}&scope=PRINCIPAL_ROLE:ALL")"
TOKEN="$(jq -r .access_token <<<"$resp")"
[[ "$TOKEN" != "null" && -n "$TOKEN" ]] || { echo "ERROR: token request failed: $resp"; exit 1; }
AUTH=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -H "Polaris-Realm: ${REALM}")

# request <method> <url> [json-body] -> prints "<code>\n<body>"
request() {
  local method="$1" url="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    "${CURL[@]}" -w '\n%{http_code}' -X "$method" "$url" "${AUTH[@]}" -d "$body"
  else
    "${CURL[@]}" -w '\n%{http_code}' -X "$method" "$url" -H "Authorization: Bearer ${TOKEN}"
  fi
}

code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${TOKEN}" "${MGMT}/catalogs/${CATALOG}" || true)"
if [[ "$code" == "200" ]]; then
  echo "==> Catalog '${CATALOG}' already exists; skipping create."
  echo "    To change it: DELETE ${MGMT}/catalogs/${CATALOG} or update via the management API."
else
  echo "==> Creating federated catalog '${CATALOG}'"
  echo "    remote uri:   ${CATALOG_URI}"
  echo "    token uri:    ${TOKEN_URI}"
  catalog_json="$(jq -n \
    --arg name "$CATALOG" \
    --arg loc "$BASE_LOC" \
    --arg tenant "$AZURE_TENANT_ID" \
    --arg uri "$CATALOG_URI" \
    --arg tokenuri "$TOKEN_URI" \
    --arg cid "$TABLEFLOW_API_KEY" \
    --arg csecret "$TABLEFLOW_API_SECRET" \
    --arg scope "${TABLEFLOW_OAUTH_SCOPE:-}" \
    --arg rcn "${TABLEFLOW_REMOTE_CATALOG_NAME:-}" \
    '{
      catalog: {
        type: "EXTERNAL",
        name: $name,
        properties: {"default-base-location": $loc},
        storageConfigInfo: {
          storageType: "AZURE",
          tenantId: $tenant,
          hierarchical: true,
          allowedLocations: [$loc]
        },
        connectionConfigInfo: (
          {
            connectionType: "ICEBERG_REST",
            uri: $uri,
            authenticationParameters: (
              {
                authenticationType: "OAUTH",
                tokenUri: $tokenuri,
                clientId: $cid,
                clientSecret: $csecret
              }
              + (if $scope != "" then {scopes: [$scope | split("[ ,]+"; "") | .[] | select(length>0)] | flatten} else {} end)
            )
          }
          + (if $rcn != "" then {remoteCatalogName: $rcn} else {} end)
        )
      }
    }')"
  out="$(request POST "${MGMT}/catalogs" "$catalog_json")"
  c="${out##*$'\n'}"
  if [[ "$c" =~ ^2 ]]; then
    echo "    created (HTTP $c)"
  else
    echo "ERROR: catalog creation failed (HTTP $c):"
    echo "${out%$'\n'*}"
    exit 1
  fi
fi

# --- catalog role + grant, assigned to service_admin ---
echo "==> Creating catalog role '${CATALOG_ROLE}' in catalog '${CATALOG}'"
out="$(request POST "${MGMT}/catalogs/${CATALOG}/catalog-roles" \
  "{\"catalogRole\": {\"name\": \"${CATALOG_ROLE}\"}}")"
c="${out##*$'\n'}"
if [[ "$c" =~ ^2 || "$c" == "409" ]]; then
  echo "    ok (HTTP $c)"
else
  echo "ERROR (HTTP $c): ${out%$'\n'*}"; exit 1
fi

echo "==> Granting CATALOG_MANAGE_CONTENT to '${CATALOG_ROLE}'"
out="$(request PUT "${MGMT}/catalogs/${CATALOG}/catalog-roles/${CATALOG_ROLE}/grants" \
  '{"grant": {"type": "catalog", "privilege": "CATALOG_MANAGE_CONTENT"}}')"
c="${out##*$'\n'}"
if [[ "$c" =~ ^2 || "$c" == "409" ]]; then
  echo "    ok (HTTP $c)"
else
  echo "ERROR (HTTP $c): ${out%$'\n'*}"; exit 1
fi

echo "==> Assigning '${CATALOG_ROLE}' to principal role 'service_admin'"
out="$(request PUT "${MGMT}/principal-roles/service_admin/catalog-roles/${CATALOG}" \
  "{\"catalogRole\": {\"name\": \"${CATALOG_ROLE}\"}}")"
c="${out##*$'\n'}"
if [[ "$c" =~ ^2 || "$c" == "409" ]]; then
  echo "    ok (HTTP $c)"
else
  echo "ERROR (HTTP $c): ${out%$'\n'*}"; exit 1
fi

cat <<OUT

=== Done ===
Federated catalog : ${CATALOG} (type EXTERNAL -> Tableflow via ${CATALOG_URI})
Administrator     : ${POLARIS_ROOT_CLIENT_ID} now reads it via 'service_admin' -> '${CATALOG_ROLE}'
Next              : ./scripts/check-tableflow.sh   # sanity-check nginx->Tableflow directly
                    ./scripts/verify.sh          # exercise the federated catalog through Polaris
OUT
