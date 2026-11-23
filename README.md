# Apache Polaris federating to Confluent Cloud Tableflow

Deploys open-source [Apache Polaris](https://polaris.apache.org) (Iceberg REST
catalog) on a single Azure Linux VM with Docker Compose + Postgres, configured
to **federate** to the Confluent Cloud **Tableflow** Iceberg REST catalog and
vend ADLS Gen2 credentials for the Tableflow BYOS container.

For server deployment, see [install_instructions_polaris_container.md](docs/install_instructions_polaris_container.md).
For CLI installation and administration, see [POLARIS_CLI.md](docs/POLARIS_CLI.md).
For test cases and validation procedures, see [docs/tests/README.md](docs/tests/README.md).

## What "federation" means here

Polaris exposes a normal Iceberg REST catalog to clients, but proxies every
catalog call **live** to the remote Tableflow catalog — there is no copy or
sync. Tableflow owns the table metadata (it is materialized by Confluent); the
tables are read-only to consumers. Polaris adds value on top: its own
authnz/roles and **credential vending** — it mints ADLS user-delegation SAS
tokens so clients can read the data files directly from the BYOS storage
account.

## Architecture

```
 Iceberg clients (Spark/Trino/Flink)
        │  Iceberg REST + OAuth
        ▼
   existing nginx :443  ──(public TLS, inbound)──►  polaris:8181 on this VM
        │                                            │
        │        ┌───────────────────────────────────┼─────────────┐
        │        │                                   │             │
        ▼        │        federates live ───────────►│ postgres    │ (metadata, internal only)
 tableflow.eastus2.azure.confluent.cloud             │             ▼
   (through the SAME nginx, :443 egress)             │      ADLS Gen2 (abfss://)
                                                     │      Tableflow BYOS container
                                                     │      (SAS vending via MI/SP)
```

## nginx egress proxy (the user's existing nginx)

Polaris's outbound calls to Tableflow go through nginx on 443. Requirements:

```nginx
location /iceberg/ {
    proxy_pass https://tableflow.eastus2.azure.confluent.cloud;
    proxy_ssl_server_name on;                                    # SNI
    proxy_set_header Host tableflow.eastus2.azure.confluent.cloud;
    # Authorization request header is forwarded unchanged by default; don't clear it
    proxy_request_buffering off;
    # do NOT rewrite bodies — Tableflow /v1/config may return absolute URLs
}
```

- The Polaris container must resolve and reach the nginx hostname on 443
  (`TABLEFLOW_PROXY_BASE_URL`), and nginx's cert must be publicly trusted.
- Caveat: if Tableflow's `/v1/config` response contains a `uri` override or
  absolute URLs, clients may bypass the nginx proxy — `scripts/check-tableflow.sh`
  prints the config response so you can spot this.
- `TABLEFLOW_PROXY_BASE_URL` can also be set to
  `https://tableflow.eastus2.azure.confluent.cloud` to bypass nginx entirely.

## Azure / Confluent prerequisites

1. **VM**: Ubuntu LTS + Docker Engine & compose plugin. NSG: only 443 (and
   admin SSH) inbound. **Port 8181 must NOT be public** — only nginx reaches it.
2. **ADLS Gen2 storage account**: hierarchical namespace enabled, same region
   as the Kafka cluster; this is the Tableflow **BYOS** container. Tables in
   Confluent-managed storage cannot be read by Polaris.
3. **Polaris identity** on the storage account: managed identity (recommended)
   or service principal with **`Storage Blob Data Contributor`** — required for
   issuing user-delegation SAS (`Reader` alone cannot mint SAS).
4. **Confluent**: a Confluent Cloud API key/secret **scoped to Tableflow** with
   access to the environment; Tableflow topics configured for BYOS into that
   ADLS container.
5. Polaris realm bootstrap (this repo's `scripts/bootstrap.sh`).

## Deploy

```bash
git clone <this repo> && cd ApachePolaris
cp .env.example .env && editor .env     # fill in all values

docker compose up -d postgres
./scripts/bootstrap.sh                  # one-off: creates realm ISBUS + service_admin
docker compose up -d                    # polaris on :8181

./scripts/check-tableflow.sh            # sanity: nginx -> Tableflow, without Polaris
./scripts/setup-tableflow-federation.sh # creates EXTERNAL catalog + role/grant for M73580
./scripts/verify.sh                     # token -> config -> namespaces -> loadTable (SAS check)
```

## Troubleshooting

- **Catalog create fails**: Polaris could not reach/authenticate to Tableflow
  through nginx — the script prints the error body. Cross-check with
  `./scripts/check-tableflow.sh` to isolate nginx/Tableflow vs Polaris issues.
- **401 from Tableflow**: bad API key/secret, or the key isn't scoped to
  Tableflow / lacks access to the environment.
- **403 AuthorizationPermissionMismatch** on ADLS: Polaris identity missing
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
