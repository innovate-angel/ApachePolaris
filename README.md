# Apache Polaris federating to Confluent Cloud Tableflow

Deploys open-source [Apache Polaris](https://polaris.apache.org) (Iceberg REST
catalog) on a single Azure Linux VM with Docker Compose + Postgres, configured
to **federate** to the Confluent Cloud **Tableflow** Iceberg REST catalog and
vend ADLS Gen2 credentials for the Tableflow BYOS container.

For server deployment, see [install_instructions_polaris_container.md](docs/install_instructions_polaris_container.md).
For shared VM bootstrap identity and Key Vault secret retrieval, see
[AZURE_KEY_VAULT_SHARED_IDENTITY.md](docs/AZURE_KEY_VAULT_SHARED_IDENTITY.md).
For CLI installation and administration, see [POLARIS_CLI.md](docs/POLARIS_CLI.md).
For test cases and validation procedures, see [docs/tests/README.md](docs/tests/README.md).

## What "federation" means here

Polaris exposes a normal Iceberg REST catalog to clients, but forwards every
catalog call **live** to the remote Tableflow catalog — there is no copy or
sync. Tableflow owns the table metadata (it is materialized by Confluent); the
tables are read-only to consumers. Polaris adds value on top: its own
authnz/roles and **credential vending** — it mints ADLS user-delegation SAS
tokens so clients can read the data files directly from the BYOS storage
account. Polaris mediates authorization and vends credentials; it does not
proxy or transfer the table data. The Polaris process still needs an Azure
identity to request the user-delegation key used to sign those tokens.

## Architecture

```
 Iceberg clients (Spark/Trino/Flink)
        │  Iceberg REST + OAuth
        ▼
   direct :8181 access, restricted by NSG ─────────► polaris:8181 on this VM
        │                                            │
        │                                            ├── metadata/RBAC ──► postgres
        │                                            ├── direct HTTPS ───► Tableflow
        │                                            └── delegation-key request
        │                                                                      │
        └──────────────── data read with vended SAS ─────────────────► ADLS Gen2
                                                               BYOS container
```

## Direct network path

Polaris and its helper scripts connect directly to
`https://tableflow.eastus2.azure.confluent.cloud` on TCP 443. Configure DNS,
outbound NSG rules, and any Azure NAT/firewall rules for that connection.
There is no proxy in the request path.

## Azure / Confluent prerequisites

1. **VM**: Ubuntu 26.04 LTS + Docker Engine & compose plugin. Restrict SSH and
   Polaris port 8181 to approved inbound networks. Allow direct outbound TCP
   443 to Tableflow and required Azure endpoints.
2. **ADLS Gen2 storage account**: hierarchical namespace enabled, same region
   as the Kafka cluster; this is the Tableflow **BYOS** container. Tables in
   Confluent-managed storage cannot be read by Polaris.
3. **Polaris workload identity**: service principal (selected for this
   deployment) with **`Storage Blob Data Contributor`** on the storage account.
   The same service principal credentials can be reused across VMs and Polaris
   installations that access the same permitted storage; configure its
   `AZURE_TENANT_ID`, `AZURE_CLIENT_ID` (`appId`), and `AZURE_CLIENT_SECRET` on
   every installation. Polaris uses this identity to mint SAS tokens; clients
   then access ADLS directly, without table data passing through the VM.
4. **Confluent**: a Confluent Cloud API key/secret **scoped to Tableflow** with
   access to the environment; Tableflow topics configured for BYOS into that
   ADLS container.
5. Polaris realm bootstrap (this repo's `scripts/bootstrap.sh`).

## Deploy

```bash
git clone <this repo> && cd ApachePolaris

# On an Azure VM, export configuration values, authenticate to Key Vault with
# the attached managed identity, and deploy with transient environment variables.
export VAULT_NAME="<key-vault-name>"
export IDENTITY_CLIENT_ID="<user-assigned-managed-identity-client-id>"
export AZURE_TENANT_ID="<tenant-id>"
export AZURE_CLIENT_ID="<polaris-service-principal-app-id>"
export AZURE_STORAGE_ACCOUNT="<storage-account>"
export AZURE_STORAGE_CONTAINER="<tableflow-container>"

./scripts/deploy-from-key-vault.sh
```

## Troubleshooting

- **Catalog create fails**: Polaris could not reach/authenticate to Tableflow
  directly — the script prints the error body. Cross-check with
  `./scripts/check-tableflow.sh` to isolate Tableflow connectivity vs Polaris issues.
- **401 from Tableflow**: bad API key/secret, or the key isn't scoped to
  Tableflow / lacks access to the environment.
- **403 AuthorizationPermissionMismatch** on ADLS: Polaris workload identity missing
  `Storage Blob Data Contributor`, or HNS ACLs block the path (RBAC takes a
  few minutes to propagate).
- **loadTable returns no `adls.sas-token.*` keys**: credential vending not
  engaged — check `ALLOW_EXTERNAL_CATALOG_CREDENTIAL_VENDING` /
  `ALLOW_FEDERATED_CATALOGS_CREDENTIAL_VENDING`, and that the table's location
  reported by Tableflow falls under `storageConfigInfo.allowedLocations`.
- **Empty namespaces**: no Tableflow-enabled topic has materialized tables yet.

## Operations

- **Backup**: `docker compose exec postgres pg_dump -U M73581 POLARIS > backup.sql`
- **Logs**: `docker compose logs -f polaris`
