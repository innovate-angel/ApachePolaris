# Shared User-Assigned Managed Identity for Azure Key Vault

This deployment can keep application secrets in Azure Key Vault while making
the VM replaceable. A standalone user-assigned managed identity is created once,
granted read access to Key Vault secrets, and attached to any VM that may run
the Polaris application.

## Identity separation

Two identities have separate responsibilities:

| Identity | Responsibility | Access |
|---|---|---|
| Shared user-assigned managed identity | Bootstrap the deployment by reading secrets from Key Vault | `Key Vault Secrets User` |
| Polaris service principal | Request Azure Storage user-delegation keys and mint SAS credentials | `Storage Blob Data Contributor` on the permitted ADLS scope |

Do not assign the Polaris service principal's storage role to the VM bootstrap
identity, and do not assign Key Vault permissions to the service principal
unless the application itself is being changed to read Key Vault directly.

## Architecture

```text
                         ┌── VM 1 ──┐
shared user-assigned MI ─┼── VM 2 ──┼── fetch secrets ──► Azure Key Vault
                         └── VM 3 ──┘
                                      │
                                      └── launch Polaris with transient
                                          environment variables
```

The managed identity is an independent Azure resource. It is not owned by a
VM, so replacing a VM does not require recreating the identity or its Key Vault
role assignment.

## 1. Create the shared identity and grant access

Create one user-assigned managed identity for the Polaris deployment:

```bash
az identity create \
  --resource-group <identity-resource-group> \
  --name <polaris-vault-reader-identity>
```

Capture its identifiers:

```bash
IDENTITY_ID="$(az identity show \
  --resource-group <identity-resource-group> \
  --name <polaris-vault-reader-identity> \
  --query id -o tsv)"

IDENTITY_CLIENT_ID="$(az identity show \
  --resource-group <identity-resource-group> \
  --name <polaris-vault-reader-identity> \
  --query clientId -o tsv)"

IDENTITY_PRINCIPAL_ID="$(az identity show \
  --resource-group <identity-resource-group> \
  --name <polaris-vault-reader-identity> \
  --query principalId -o tsv)"
```

Use Azure RBAC and grant the least-privileged secrets role:

```bash
VAULT_ID="$(az keyvault show \
  --name <key-vault-name> \
  --resource-group <key-vault-resource-group> \
  --query id -o tsv)"

az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope "$VAULT_ID"
```

The role assignment can be scoped to the vault or, where practical, to the
individual secret resources. Allow several minutes for RBAC propagation.

## 2. Attach the identity to each eligible VM

Attach the same identity resource to every VM that may host Polaris:

```bash
az vm identity assign \
  --resource-group <vm-resource-group> \
  --name <vm-name> \
  --identities "$IDENTITY_ID"
```

Verify the assignment:

```bash
az vm identity show \
  --resource-group <vm-resource-group> \
  --name <vm-name>
```

When moving Polaris to another VM, attach the existing identity to that VM.
Do not create a new Key Vault identity or repeat the role assignment.

## 3. Store deployment secrets

Recommended secret names:

| Environment variable | Key Vault secret |
|---|---|
| `POSTGRES_PASSWORD` | `polaris-postgres-password` |
| `POLARIS_ROOT_CLIENT_SECRET` | `polaris-root-client-secret` |
| `POLARIS_TOKEN_BROKER_SECRET` | `polaris-token-broker-secret` |
| `AZURE_CLIENT_SECRET` | `polaris-azure-client-secret` |
| `TABLEFLOW_API_KEY` | `polaris-tableflow-api-key` |
| `TABLEFLOW_API_SECRET` | `polaris-tableflow-api-secret` |

Store values with an approved secret-management process:

```bash
az keyvault secret set \
  --vault-name <key-vault-name> \
  --name <secret-name> \
  --value "<secret-value>"
```

Do not print secret values, save the command in shell history, or use a shell
command on a shared terminal when the deployment process supports a secret
pipeline or protected deployment variable.

Configuration identifiers that are not secrets can remain in `.env`, including
the PostgreSQL user, Polaris root client ID, Azure tenant/client IDs, storage
account/container, and Tableflow organization/environment IDs.

## 4. Authenticate to Key Vault on the VM

Install Azure CLI and sign in with the attached shared identity:

```bash
az login \
  --identity \
  --client-id "$IDENTITY_CLIENT_ID"
```

Read one secret to validate access without displaying it:

```bash
value="$(az keyvault secret show \
  --vault-name <key-vault-name> \
  --name polaris-postgres-password \
  --query value -o tsv)"

test -n "$value"
unset value
```

## 5. Launch the application with transient secrets

Docker Compose does not resolve Key Vault references directly. The deployment
process must retrieve secrets before starting Compose. Keep secret variables
out of the persisted `.env` file and export them in the same shell as the
Compose and deployment commands:

```bash
VAULT_NAME=<key-vault-name>

get_secret() {
  az keyvault secret show \
    --vault-name "$VAULT_NAME" \
    --name "$1" \
    --query value \
    --output tsv
}

export POSTGRES_PASSWORD="$(get_secret polaris-postgres-password)"
export POLARIS_ROOT_CLIENT_SECRET="$(get_secret polaris-root-client-secret)"
export POLARIS_TOKEN_BROKER_SECRET="$(get_secret polaris-token-broker-secret)"
export AZURE_CLIENT_SECRET="$(get_secret polaris-azure-client-secret)"
export TABLEFLOW_API_KEY="$(get_secret polaris-tableflow-api-key)"
export TABLEFLOW_API_SECRET="$(get_secret polaris-tableflow-api-secret)"

docker compose up -d postgres
docker compose --profile bootstrap run --rm polaris-bootstrap
docker compose up -d polaris

./scripts/check-tableflow.sh
./scripts/setup-tableflow-federation.sh
./scripts/verify.sh

unset POSTGRES_PASSWORD \
  POLARIS_ROOT_CLIENT_SECRET \
  POLARIS_TOKEN_BROKER_SECRET \
  AZURE_CLIENT_SECRET \
  TABLEFLOW_API_KEY \
  TABLEFLOW_API_SECRET
```

If a secret name is present in `.env`, remove the secret assignment rather
than leaving it blank. An assignment in `.env` may interfere with the exported
deployment value when scripts source that file.

## Moving to another VM

1. Clone the corporate repository onto the replacement VM.
2. Install the required runtime and Azure CLI.
3. Attach the existing shared user-assigned managed identity.
4. Wait for the identity assignment to propagate.
5. Sign in with `az login --identity --client-id`.
6. Run the secret retrieval and deployment sequence.

The Key Vault, managed identity, secret names, and RBAC assignment remain
unchanged.

## Operational considerations

- Scope `Key Vault Secrets User` as narrowly as corporate policy permits.
- Keep Key Vault RBAC authorization enabled; avoid legacy access policies.
- Enable soft delete and purge protection on Key Vault.
- Restrict Key Vault network access and authorize the VM's outbound route.
- Rotate application secrets in Key Vault, then restart/redeploy the affected
  containers so the new values are loaded.
- Do not log secret values or run `docker compose config` with unrestricted
  output while secret environment variables are exported.
- Limit Docker group membership. Users with privileged Docker access may be
  able to inspect environment variables in running containers.
- Keep Key Vault retrieval in a protected deployment or systemd unit rather
  than embedding the logic in an interactive shell for production automation.

