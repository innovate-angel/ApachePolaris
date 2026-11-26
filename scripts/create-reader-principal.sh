#!/usr/bin/env bash
# Creates a Polaris principal for a query engine with read-only access to the
# federated catalog and prints its client ID and secret once. Idempotent:
# rerunning for an existing principal re-checks its access and never changes
# its credentials.
# Usage: create-reader-principal.sh <principal-name>
# Requires: curl, jq. Set CURL_INSECURE=1 for self-signed certs (testing only).
set -euo pipefail
cd "$(dirname "$0")/.."

PRINCIPAL="${1:-}"
[[ "$PRINCIPAL" =~ ^[A-Za-z0-9_-]+$ ]] || {
  echo "Usage: $0 <principal-name>   (letters, digits, '_' and '-')" >&2
  exit 2
}

for v in POLARIS_ROOT_CLIENT_ID POLARIS_ROOT_CLIENT_SECRET; do
  [[ -n "${!v:-}" ]] || { echo "ERROR: $v is not set in the environment"; exit 1; }
done

REALM="${POLARIS_REALM:-ISBUS}"
CURL=(curl -sS)
[[ "${CURL_INSECURE:-0}" == "1" ]] && CURL+=(-k)

POLARIS_URL="${POLARIS_URL:-http://localhost:8181}"
MGMT="${POLARIS_URL}/api/management/v1"
CATALOG="${POLARIS_CATALOG_NAME:-tableflow}"
PRINCIPAL_ROLE="${POLARIS_READER_PRINCIPAL_ROLE:-${CATALOG}_readers}"
CATALOG_ROLE="${POLARIS_READER_CATALOG_ROLE:-${CATALOG}_read_only}"
# Same lock as setup-tableflow-federation.sh, so a catalog recreation cannot
# drop roles created mid-run.
STATE_DIR="${POLARIS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/polaris}"
mkdir -p "$STATE_DIR"
exec 9>"${STATE_DIR}/.lock"
flock 9
# List and describe namespaces and tables, and load a table with vended read
# credentials. Nothing that writes, drops, or administers.
PRIVILEGES=(NAMESPACE_LIST NAMESPACE_READ_PROPERTIES TABLE_LIST TABLE_READ_PROPERTIES TABLE_READ_DATA)

# token <client-id>, client secret on stdin -> prints an access token, or nothing
token() {
  "${CURL[@]}" -X POST "${POLARIS_URL}/api/catalog/v1/oauth/tokens" -H "Polaris-Realm: ${REALM}" \
    --data-urlencode grant_type=client_credentials --data-urlencode "client_id=$1" \
    --data-urlencode client_secret@- --data-urlencode scope=PRINCIPAL_ROLE:ALL \
    | jq -r '.access_token // empty'
}

# request <method> <url> [json-body] -> sets $code and $body
request() {
  local out args=(-w '\n%{http_code}' -X "$1" "$2" -H "Authorization: Bearer ${TOKEN}" -H "Polaris-Realm: ${REALM}")
  [[ -n "${3:-}" ]] && args+=(-H "Content-Type: application/json" -d "$3")
  out="$("${CURL[@]}" "${args[@]}")" || out=$'\n000'
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
}

# ok [code...] -> true when the last request returned 2xx or one of the codes
ok() { [[ "$code" =~ ^2 || " $* " == *" ${code} "* ]]; }
fail() { echo "ERROR: $1 (HTTP ${code}): ${body}" >&2; exit 1; }
named() { jq -cn --arg kind "$1" --arg name "$2" '{($kind): {name: $name}}'; }

TOKEN="$(printf %s "$POLARIS_ROOT_CLIENT_SECRET" | token "$POLARIS_ROOT_CLIENT_ID")" || TOKEN=""
[[ -n "$TOKEN" ]] || { echo "ERROR: administrator token request to ${POLARIS_URL} failed" >&2; exit 1; }

echo "==> Principal role '${PRINCIPAL_ROLE}'"
request POST "${MGMT}/principal-roles" "$(named principalRole "$PRINCIPAL_ROLE")"
ok 409 || fail "creating principal role '${PRINCIPAL_ROLE}'"

echo "==> Catalog role '${CATALOG_ROLE}' in catalog '${CATALOG}': ${PRIVILEGES[*]}"
request POST "${MGMT}/catalogs/${CATALOG}/catalog-roles" "$(named catalogRole "$CATALOG_ROLE")"
ok 409 || fail "creating catalog role '${CATALOG_ROLE}' in catalog '${CATALOG}'"
for privilege in "${PRIVILEGES[@]}"; do
  request PUT "${MGMT}/catalogs/${CATALOG}/catalog-roles/${CATALOG_ROLE}/grants" \
    "$(jq -cn --arg privilege "$privilege" '{grant: {type: "catalog", privilege: $privilege}}')"
  ok 409 || fail "granting ${privilege} to '${CATALOG_ROLE}'"
done
request PUT "${MGMT}/principal-roles/${PRINCIPAL_ROLE}/catalog-roles/${CATALOG}" "$(named catalogRole "$CATALOG_ROLE")"
ok 409 || fail "assigning '${CATALOG_ROLE}' to '${PRINCIPAL_ROLE}'"

echo "==> Principal '${PRINCIPAL}'"
request POST "${MGMT}/principals" "$(named principal "$PRINCIPAL")"
ok 409 || fail "creating principal '${PRINCIPAL}'"
created="$body"
[[ "$code" == "409" ]] && created=""
request PUT "${MGMT}/principals/${PRINCIPAL}/principal-roles" "$(named principalRole "$PRINCIPAL_ROLE")"
ok 409 || fail "assigning '${PRINCIPAL_ROLE}' to '${PRINCIPAL}'"

if [[ -z "$created" ]]; then
  cat <<OUT

Principal '${PRINCIPAL}' already existed; its credentials were not changed and
cannot be shown again. It has principal role '${PRINCIPAL_ROLE}'.
OUT
  exit 0
fi

client_id="$(jq -r .credentials.clientId <<<"$created")"
client_secret="$(jq -r .credentials.clientSecret <<<"$created")"

echo "==> Listing namespaces in '${CATALOG}' as '${PRINCIPAL}'"
TOKEN="$(printf %s "$client_secret" | token "$client_id")" || TOKEN=""
[[ -n "$TOKEN" ]] || { echo "ERROR: token request for the new principal failed" >&2; exit 1; }
request GET "${POLARIS_URL}/api/catalog/v1/${CATALOG}/namespaces"
ok || fail "the new principal could not list namespaces"
echo "    ok (HTTP ${code})"

cat <<OUT

=== Done ===
Principal      : ${PRINCIPAL}  (principal role '${PRINCIPAL_ROLE}' -> catalog role '${CATALOG_ROLE}')
Client ID      : ${client_id}
Client secret  : ${client_secret}

The secret is shown only this once. Store it in the query engine's secret
store now, then clear this terminal's scrollback.
OUT
