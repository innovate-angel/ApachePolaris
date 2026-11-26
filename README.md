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
   HTTPS via TLS-terminating ingress ───────────────► polaris:8181 on this VM
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

## Client TLS

The Compose stack does not terminate TLS: Polaris listens on plaintext HTTP at
port 8181, published only on `POLARIS_BIND_ADDRESS` (the VM private IP or
127.0.0.1, never all interfaces). In production, terminate client HTTPS at an approved TLS gateway
(for example, Azure Application Gateway or an organization-managed reverse
proxy), and restrict the VM's inbound 8181 rule to that gateway. Clients should
use the gateway's HTTPS hostname; do not expose plaintext 8181 to untrusted
networks. Certificate provisioning and renewal belong to that gateway.

## Azure / Confluent prerequisites

1. **VM**: Ubuntu 26.04 LTS + Docker Engine, Compose plugin, Azure CLI, Git,
   curl, and jq. Restrict SSH and port 8181 to approved ingress networks.
   Allow outbound DNS and TCP 443 to Tableflow, Key Vault, Microsoft Entra ID,
   Azure Storage, and Docker Hub; managed-identity login also needs local
   access to the Azure IMDS endpoint.
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
5. **Bootstrap identity and Key Vault**: attach a user-assigned managed identity
   to the VM and grant it `Key Vault Secrets User` on the RBAC-enabled vault
   containing the seven deployment secrets.

## Deploy

Follow the step-by-step guide:
[docs/install_instructions_polaris_container.md](docs/install_instructions_polaris_container.md).
It covers Azure and Confluent setup, VM installation, the one-command deploy
(`./scripts/deploy-from-key-vault.sh`), automatic recovery and backups, and
connecting query engines. Secrets are fetched from Key Vault at runtime; do not
put them in `.env` or print the resolved Compose configuration.

## Troubleshooting

- **Catalog create fails**: Polaris could not reach/authenticate to Tableflow
  directly — the script prints the error body. Cross-check with
  `source scripts/load-key-vault-env.sh && ./scripts/check-tableflow.sh` to
  isolate Tableflow connectivity vs Polaris issues.
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

- Use `scripts/compose.sh` for Compose operations so required secrets are loaded
  transiently from Key Vault (export the non-secret deployment settings first):
  `./scripts/compose.sh logs -f polaris`
- **After any Polaris restart** (manual, VM reboot, Docker upgrade), Polaris 1.9.0
  loses the catalog's Tableflow secret. The recovery timer (runbook step 9)
  restores it within about 5 minutes; without the timer, rerun
  `./scripts/deploy-from-key-vault.sh`.
- **Secret rotation**: follow the per-secret table in the
  [runbook](docs/install_instructions_polaris_container.md#step-13-change-secrets-rotation).
- **Query engine access**: `scripts/create-reader-principal.sh <name>` creates
  a read-only principal (runbook step 11).
- **Backup and restore**: daily via `polaris-backup.timer`, copied to Blob storage;
  on demand with `sudo systemctl start polaris-backup.service` (runbook step 14).
