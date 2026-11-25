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

Export non-secret deployment settings in the same shell as the deployment
command (for example `VAULT_NAME`, `IDENTITY_CLIENT_ID`, Azure IDs, storage
account/container, and Tableflow organization/environment IDs). The deployment
scripts do not read `.env`; `.env.example` is a deprecated reference only.

## 4. Authenticate to Key Vault on the VM

Install Azure CLI and sign in with the attached shared identity:

```bash
az login \
  --identity \
  --allow-no-subscriptions \
  --client-id "$IDENTITY_CLIENT_ID"
```

The managed identity needs access to the vault, not a subscription-wide role.

Read one secret to validate access without displaying it:

```bash
value="$(az keyvault secret show \
  --vault-name <key-vault-name> \
  --name polaris-postgres-password \
  --query value -o tsv)"

test -n "$value"
unset value
```

## 5. Deploy with transient secrets

Docker Compose does not resolve Key Vault references directly. The deployment
entry point retrieves secrets before starting Compose. Keep secret variables
out of the persisted `.env` file and let the script clean them up on exit:

```bash
export VAULT_NAME="<key-vault-name>"
export IDENTITY_CLIENT_ID="<managed-identity-client-id>"
# Export the non-secret settings required by the deployment.
./scripts/deploy-from-key-vault.sh
```

Use `./scripts/compose.sh <operation>` for day-to-day Compose commands; it
retrieves Key Vault secrets transiently and refuses to print resolved config.

## Moving to another VM

1. Clone the corporate repository onto the replacement VM.
2. Install the required runtime and Azure CLI.
3. Attach the existing shared user-assigned managed identity.
4. Wait for the identity assignment to propagate.
5. Export the non-secret deployment settings.
6. Run `./scripts/deploy-from-key-vault.sh`.

The Key Vault, managed identity, secret names, and RBAC assignment remain
unchanged.

## Operational considerations

- Scope `Key Vault Secrets User` as narrowly as corporate policy permits.
- Keep Key Vault RBAC authorization enabled; avoid legacy access policies.
- Enable soft delete and purge protection on Key Vault.
- Restrict Key Vault network access and authorize the VM's outbound route.
- Rotate application secrets in Key Vault, then run the deployment entry point
  or use `./scripts/compose.sh` to restart affected containers.
- Do not log secret values or run `docker compose config` with unrestricted
  output while secret environment variables are exported. The Compose wrapper
  only permits `config -q`.
- Limit Docker group membership. Users with privileged Docker access may be
  able to inspect environment variables in running containers.
- Keep Key Vault retrieval in a protected deployment or systemd unit rather
  than embedding the logic in an interactive shell for production automation.

