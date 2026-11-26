#!/usr/bin/env bash
# Creates the EXTERNAL (federated) Polaris catalog that proxies live to the
# Confluent Tableflow Iceberg REST catalog, then grants the bootstrap
# service_admin principal role read/manage access to it. Idempotent.
#
# Polaris 1.9.0 keeps a federated catalog's client secret only in memory
# (polaris.secrets-manager.type=in-memory), so every Polaris restart loses it,
# and the management API cannot update a catalog's connection. When the
# existing catalog's connection no longer works, or its settings differ from
# the deployment settings, this script recreates the catalog and restores its
# catalog roles, grants, and principal-role assignments.
# Set POLARIS_RECREATE_CATALOG=1 to force that.
# Requires: curl, jq. Set CURL_INSECURE=1 for self-signed certs (testing only).
set -euo pipefail
cd "$(dirname "$0")/.."

REALM="${POLARIS_REALM:-ISBUS}"

for v in AZURE_TENANT_ID AZURE_STORAGE_ACCOUNT AZURE_STORAGE_CONTAINER \
         TABLEFLOW_PROXY_BASE_URL TABLEFLOW_ORG_ID TABLEFLOW_ENV_ID \
         TABLEFLOW_API_KEY TABLEFLOW_API_SECRET \
         POLARIS_ROOT_CLIENT_ID POLARIS_ROOT_CLIENT_SECRET; do
  [[ -n "${!v:-}" ]] || { echo "ERROR: $v is not set in the environment"; exit 1; }
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

# Journal for a catalog recreation. It exists only between the snapshot and a
# completed restore, so an interrupted run resumes from it. Contains no secrets.
STATE_DIR="${POLARIS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/polaris}"
SNAPSHOT="${STATE_DIR}/catalog-rbac-${REALM}-${CATALOG}.json"
# Serialize with other runs (timer, manual, reader provisioning) for this deployment.
mkdir -p "$STATE_DIR"
exec 9>"${STATE_DIR}/.lock"
flock 9

echo "==> Getting Polaris administrator token (${POLARIS_ROOT_CLIENT_ID}) from ${POLARIS_URL}"
# The secret is passed on stdin so it never appears in the process list, and the
# response is not echoed on failure.
TOKEN="$(printf %s "$POLARIS_ROOT_CLIENT_SECRET" | "${CURL[@]}" -X POST "${POLARIS_URL}/api/catalog/v1/oauth/tokens" \
  -H "Polaris-Realm: ${REALM}" \
  --data-urlencode grant_type=client_credentials --data-urlencode "client_id=${POLARIS_ROOT_CLIENT_ID}" \
  --data-urlencode client_secret@- --data-urlencode scope=PRINCIPAL_ROLE:ALL \
  | jq -r '.access_token // empty')" || TOKEN=""
[[ -n "$TOKEN" ]] || { echo "ERROR: administrator token request to ${POLARIS_URL} failed" >&2; exit 1; }
AUTH=(-H "Authorization: Bearer ${TOKEN}" -H "Polaris-Realm: ${REALM}")

# request <method> <url> [json-body] -> sets $code and $body
request() {
  local out args=(-w '\n%{http_code}' -X "$1" "$2" "${AUTH[@]}")
  [[ -n "${3:-}" ]] && args+=(-H "Content-Type: application/json" -d "$3")
  out="$("${CURL[@]}" "${args[@]}")" || out=$'\n000'
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
}

# ok [code...] -> true when the last request returned 2xx or one of the codes
ok() { [[ "$code" =~ ^2 || " $* " == *" ${code} "* ]]; }
fail() { echo "ERROR: $1 (HTTP ${code}): ${body}" >&2; exit 1; }
uri() { jq -rn --arg v "$1" '$v | @uri'; }

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

create_catalog() {
  echo "==> Creating federated catalog '${CATALOG}'"
  echo "    remote uri:   ${CATALOG_URI}"
  echo "    token uri:    ${TOKEN_URI}"
  request POST "${MGMT}/catalogs" "$catalog_json"
  ok || fail "catalog creation failed"
  echo "    created (HTTP ${code})"
}

# --- catalog role + grant, assigned to service_admin ---
ensure_admin_role() {
  echo "==> Creating catalog role '${CATALOG_ROLE}' in catalog '${CATALOG}'"
  request POST "${MGMT}/catalogs/${CATALOG}/catalog-roles" \
    "$(jq -cn --arg name "$CATALOG_ROLE" '{catalogRole: {name: $name}}')"
  ok 409 || fail "creating catalog role '${CATALOG_ROLE}'"
  echo "    ok (HTTP ${code})"

  echo "==> Granting CATALOG_MANAGE_CONTENT to '${CATALOG_ROLE}'"
  request PUT "${MGMT}/catalogs/${CATALOG}/catalog-roles/$(uri "$CATALOG_ROLE")/grants" \
    '{"grant": {"type": "catalog", "privilege": "CATALOG_MANAGE_CONTENT"}}'
  ok 409 || fail "granting CATALOG_MANAGE_CONTENT to '${CATALOG_ROLE}'"
  echo "    ok (HTTP ${code})"

  echo "==> Assigning '${CATALOG_ROLE}' to principal role 'service_admin'"
  request PUT "${MGMT}/principal-roles/service_admin/catalog-roles/${CATALOG}" \
    "$(jq -cn --arg name "$CATALOG_ROLE" '{catalogRole: {name: $name}}')"
  ok 409 || fail "assigning '${CATALOG_ROLE}' to 'service_admin'"
  echo "    ok (HTTP ${code})"
}

# Lists namespaces through the federated catalog; fails when Polaris cannot
# authenticate to or reach the remote catalog.
probe() { request GET "${POLARIS_URL}/api/catalog/v1/${CATALOG}/namespaces"; }

# Names of the connection/storage settings that differ between the deployment
# settings and the existing catalog (the client secret cannot be compared).
changed_settings() {
  jq -rn --argjson want "$catalog_json" --argjson have "$1" '
    def settings: {
      "remote uri": .connectionConfigInfo.uri,
      "remote catalog name": (.connectionConfigInfo.remoteCatalogName // ""),
      "token uri": .connectionConfigInfo.authenticationParameters.tokenUri,
      "client id": .connectionConfigInfo.authenticationParameters.clientId,
      "scopes": (.connectionConfigInfo.authenticationParameters.scopes // []),
      "tenant id": .storageConfigInfo.tenantId,
      "allowed locations": .storageConfigInfo.allowedLocations
    };
    ($want.catalog | settings) as $w | ($have | settings) as $h
    | [$w | keys[] | select($w[.] != $h[.])] | join(", ")'
}

# Confirms the deployment's Tableflow credentials work before anything is
# deleted. The secret is passed on stdin, not on the command line.
check_tableflow_credentials() {
  local args=(--data-urlencode grant_type=client_credentials \
    --data-urlencode "client_id=${TABLEFLOW_API_KEY}" --data-urlencode client_secret@-)
  [[ -n "${TABLEFLOW_OAUTH_SCOPE:-}" ]] && args+=(--data-urlencode "scope=${TABLEFLOW_OAUTH_SCOPE}")
  printf %s "$TABLEFLOW_API_SECRET" | "${CURL[@]}" -f -o /dev/null -X POST "${TOKEN_URI}" "${args[@]}"
}

# Records every catalog role with its grants and principal-role assignments.
snapshot_rbac() {
  local listing name grants roles='[]'
  request GET "${MGMT}/catalogs/${CATALOG}/catalog-roles"
  ok || fail "listing catalog roles"
  listing="$body"
  while IFS= read -r name; do
    request GET "${MGMT}/catalogs/${CATALOG}/catalog-roles/$(uri "$name")/grants"
    ok || fail "listing grants of catalog role '${name}'"
    grants="$body"
    request GET "${MGMT}/catalogs/${CATALOG}/catalog-roles/$(uri "$name")/principal-roles"
    ok || fail "listing principal roles of catalog role '${name}'"
    roles="$(jq -c --arg name "$name" --argjson listing "$listing" \
      --argjson grants "$grants" --argjson assignees "$body" \
      '. + [{
        name: $name,
        properties: ([$listing.roles[] | select(.name == $name) | .properties][0] // {}),
        grants: $grants.grants,
        principalRoles: [$assignees.roles[].name]
      }]' <<<"$roles")"
  done < <(jq -r '.roles[].name' <<<"$listing")

  mkdir -p "$STATE_DIR"
  # Keep anything recorded by an interrupted run that this listing lacks.
  if [[ -s "$SNAPSHOT" ]]; then
    roles="$(jq -c --slurpfile previous "$SNAPSHOT" '
      $previous[0].roles + . | group_by(.name) | map({
        name: .[0].name,
        properties: (map(.properties) | add),
        grants: (map(.grants) | add | unique),
        principalRoles: (map(.principalRoles) | add | unique)
      })' <<<"$roles")"
  fi
  (umask 077; jq -n --arg realm "$REALM" --arg catalog "$CATALOG" --argjson roles "$roles" \
    '{realm: $realm, catalog: $catalog, roles: $roles}' >"${SNAPSHOT}.tmp")
  mv "${SNAPSHOT}.tmp" "$SNAPSHOT"
  echo "    recorded $(jq '.roles | length' "$SNAPSHOT") catalog role(s) in ${SNAPSHOT}"
}

# Polaris only drops a catalog once catalog_admin is its last catalog role.
# Roles are taken from a live listing: deleting a role that does not exist
# returns HTTP 400, so the snapshot (which may hold older roles) cannot be used.
drop_catalog() {
  local name
  request GET "${MGMT}/catalogs/${CATALOG}/catalog-roles"
  ok || fail "listing catalog roles"
  while IFS= read -r name; do
    request DELETE "${MGMT}/catalogs/${CATALOG}/catalog-roles/$(uri "$name")"
    ok || fail "deleting catalog role '${name}'"
  done < <(jq -r '.roles[].name | select(. != "catalog_admin")' <<<"$body")
  request DELETE "${MGMT}/catalogs/${CATALOG}"
  ok 404 || fail "deleting catalog '${CATALOG}'"
  echo "    dropped catalog '${CATALOG}'"
}

restore_rbac() {
  local role name item failures=0
  echo "==> Restoring catalog roles, grants, and assignments from ${SNAPSHOT}"
  while IFS= read -r role; do
    name="$(jq -r .name <<<"$role")"
    if [[ "$name" != "catalog_admin" ]]; then
      request POST "${MGMT}/catalogs/${CATALOG}/catalog-roles" "$(jq -c '{catalogRole: {name, properties}}' <<<"$role")"
      if ! ok 409; then
        echo "    FAILED to create catalog role '${name}' (HTTP ${code}): ${body}" >&2
        failures=$((failures + 1))
        continue
      fi
    fi
    while IFS= read -r item; do
      request PUT "${MGMT}/catalogs/${CATALOG}/catalog-roles/$(uri "$name")/grants" "$(jq -c '{grant: .}' <<<"$item")"
      if ! ok 409; then
        echo "    FAILED to grant ${item} to '${name}' (HTTP ${code}): ${body}" >&2
        failures=$((failures + 1))
      fi
    done < <(jq -c '.grants[]' <<<"$role")
    while IFS= read -r item; do
      request PUT "${MGMT}/principal-roles/$(uri "$item")/catalog-roles/${CATALOG}" "$(jq -c '{catalogRole: {name}}' <<<"$role")"
      if ! ok 409; then
        echo "    FAILED to assign '${name}' to principal role '${item}' (HTTP ${code}): ${body}" >&2
        failures=$((failures + 1))
      fi
    done < <(jq -r '.principalRoles[]' <<<"$role")
    echo "    ${name}: $(jq -r '"\(.grants | length) grant(s), \(.principalRoles | length) principal role(s)"' <<<"$role")"
  done < <(jq -c '.roles[]' "$SNAPSHOT")

  if [[ "$failures" -gt 0 ]]; then
    echo "ERROR: ${failures} item(s) could not be restored. ${SNAPSHOT} was kept;" >&2
    echo "       fix the cause and rerun this script to retry the restore." >&2
    exit 1
  fi
  rm -f "$SNAPSHOT"
}

request GET "${MGMT}/catalogs/${CATALOG}"
if [[ "$code" == "404" ]]; then
  create_catalog
  ensure_admin_role
elif [[ "$code" == "200" ]]; then
  existing="$body"
  if [[ "$(jq -r '.type + ":" + (.connectionConfigInfo.connectionType // "")' <<<"$existing")" != "EXTERNAL:ICEBERG_REST" ]]; then
    echo "ERROR: catalog '${CATALOG}' exists but is not a federated Iceberg REST catalog; not touching it." >&2
    exit 1
  fi
  # The probe below runs as the administrator, so its access must be in place.
  ensure_admin_role

  reason=""
  if [[ "${POLARIS_RECREATE_CATALOG:-0}" == "1" ]]; then
    reason="POLARIS_RECREATE_CATALOG=1"
  else
    changed="$(changed_settings "$existing")"
    if [[ -n "$changed" ]]; then
      reason="these settings differ from the deployment settings: ${changed}"
    else
      probe
      ok || reason="a request through it failed (HTTP ${code}); expected after a Polaris restart, which loses the stored Tableflow secret"
    fi
  fi

  if [[ -z "$reason" ]]; then
    echo "==> Catalog '${CATALOG}' exists and its Tableflow connection works; leaving it unchanged."
  else
    echo "==> Recreating catalog '${CATALOG}': ${reason}"
    if ! check_tableflow_credentials; then
      echo "ERROR: the Tableflow API key was rejected or ${TOKEN_URI} is unreachable." >&2
      echo "       Catalog '${CATALOG}' was left unchanged; fix that first (./scripts/check-tableflow.sh)." >&2
      exit 1
    fi
    snapshot_rbac
    drop_catalog
    create_catalog
  fi
else
  fail "could not read catalog '${CATALOG}'"
fi

# Also completes a restore that an earlier, interrupted run left unfinished.
if [[ -s "$SNAPSHOT" ]]; then
  restore_rbac
fi

echo "==> Checking the Tableflow connection through catalog '${CATALOG}'"
probe
ok || fail "a request through catalog '${CATALOG}' failed"
echo "    ok (HTTP ${code})"

cat <<OUT

=== Done ===
Federated catalog : ${CATALOG} (type EXTERNAL -> Tableflow via ${CATALOG_URI})
Administrator     : ${POLARIS_ROOT_CLIENT_ID} now reads it via 'service_admin' -> '${CATALOG_ROLE}'
Next              : ./scripts/check-tableflow.sh   # sanity-check direct VM->Tableflow access
                    ./scripts/verify.sh          # exercise the federated catalog through Polaris
OUT
