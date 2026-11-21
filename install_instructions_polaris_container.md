# Installing Apache Polaris (container) on an Azure VM

**Author:** Angel Vega  
**Date:** 2026-11-21

Step-by-step instructions to deploy open-source Apache Polaris 1.8.0 with
Docker Compose on an Azure Linux VM and federate it to the Confluent Cloud
Tableflow Iceberg REST catalog, with Azure ADLS Gen2 access for table files.

For CLI installation and administration, see
[Apache Polaris CLI](POLARIS_CLI.md).

---

## 0. What you end up with

```
 Iceberg clients ──► nginx/Azure ingress :443 ──► Polaris :8181 (this VM)
                                               │   │
                                               │   └──► Postgres (container, internal only)
                                               │
                          ┌────────────────────┴──────────────────────┐
                          ▼                                           ▼
  direct HTTPS or nginx egress ──► https://tableflow.eastus2.azure.confluent.cloud    ADLS Gen2 (abfss://)
  (Polaris egress)        Tableflow Iceberg REST catalog                     Tableflow BYOS container
```

| Container  | Image                              | Ports on the VM            |
|------------|------------------------------------|----------------------------|
| `postgres` | `postgres:17-alpine`               | none (internal only)       |
| `polaris`  | `apache/polaris:1.8.0`             | `8181` (API), `127.0.0.1:8182` (health) |
| `polaris-bootstrap` (one-off) | `apache/polaris-admin-tool:1.8.0` | none           |

Federation means Polaris forwards catalog calls **live** to Tableflow. Nothing
is copied. Tables are read-only, and Tableflow stays the owner. Polaris adds
its own logins and roles, plus short-lived ADLS SAS tokens (credential vending)
so that query engines can read the data files.

---

## 1. Prerequisites

### 1.1 Azure VM
- Ubuntu 22.04 or 24.04 LTS (amd64 or arm64), at least 2 vCPU and 4 GB RAM.
- Outbound HTTPS from the VM to
  `tableflow.eastus2.azure.confluent.cloud`, directly or through your existing
  nginx/Azure egress proxy.

### 1.2 Network security group (NSG)
| Port | Source                     | Purpose                                 |
|------|----------------------------|-----------------------------------------|
| 22   | Your admin IPs only        | SSH                                     |
| 443  | As needed by ingress proxy | HTTPS ingress, if used                   |
| 8181 | Private network or proxy IP | Polaris API; do not expose to internet |

Polaris publishes 8181 on all interfaces so an ingress proxy or approved private
network client can reach it.
**Do not** open 8181 to the internet in the NSG.

### 1.3 ADLS Gen2 storage account (Tableflow BYOS)
- Storage account with **hierarchical namespace enabled**, in the **same region
  as the Kafka cluster** (eastus2).
- The container that Tableflow writes to (bring-your-own-storage). Polaris
  can't read topics that use Confluent-managed storage.

### 1.4 Identity for Polaris to access ADLS
Choose **one** of the following.

**Option A: VM system-assigned managed identity (recommended, no secret)**
```bash
az vm identity assign -g <resource-group> -n <vm-name>
PRINCIPAL_ID=$(az vm show -g <resource-group> -n <vm-name> --query identity.principalId -o tsv)
az role assignment create \
  --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope /subscriptions/<sub-id>/resourceGroups/<storage-rg>/providers/Microsoft.Storage/storageAccounts/<storage-account>
```

**Option B: service principal**
```bash
az ad sp create-for-rbac --name polaris-storage \
  --role "Storage Blob Data Contributor" \
  --scopes /subscriptions/<sub-id>/resourceGroups/<storage-rg>/providers/Microsoft.Storage/storageAccounts/<storage-account>
# Note appId -> AZURE_CLIENT_ID, password -> AZURE_CLIENT_SECRET, tenant -> AZURE_TENANT_ID
```

`Storage Blob Data Contributor` is required, because Polaris issues
user-delegation SAS tokens and `Reader` alone can't do that. Role assignments
can take several minutes to take effect.

Get your tenant ID (it's required in both options):
```bash
az account show --query tenantId -o tsv
```

### 1.5 Confluent Cloud
- The Tableflow REST catalog endpoint:
  `https://tableflow.eastus2.azure.confluent.cloud/iceberg/catalog/organizations/54c99051-8b33-4f51-b105-132f643b1720/environments/env-xq8wnq`
- A Confluent Cloud **API key and secret scoped to Tableflow** that can access
  environment `env-xq8wnq`:
  ```bash
  confluent api-key create --resource tableflow
  ```
- Tableflow-enabled topics configured for **BYOS** into the ADLS container
  from section 1.3.

### 1.6 Tableflow network access (nginx is optional)
Polaris calls the URL configured by `TABLEFLOW_PROXY_BASE_URL`. It can call
Tableflow directly, for example:

```text
TABLEFLOW_PROXY_BASE_URL=https://tableflow.eastus2.azure.confluent.cloud
```

If outbound HTTPS is routed through an existing nginx egress proxy, set
`TABLEFLOW_PROXY_BASE_URL` to that proxy and configure it to forward
`/iceberg/...` to Tableflow. Example `server`/`location` block:

```nginx
location /iceberg/ {
    proxy_pass https://tableflow.eastus2.azure.confluent.cloud;
    proxy_ssl_server_name on;                                   # send SNI to Tableflow
    proxy_set_header Host tableflow.eastus2.azure.confluent.cloud;
    proxy_request_buffering off;
    # The Authorization request header is forwarded by default; do not clear it.
}
```

The Polaris container must be able to resolve and reach the configured base
URL on 443. A direct Tableflow URL requires outbound DNS, NAT/firewall access,
and a publicly trusted certificate chain. An nginx hostname also requires its
certificate to be trusted by the container.

---

## 2. Copy the repository to the VM

From your Mac:
```bash
cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/opencode_projects
rsync -av --exclude .git ApachePolaris/ <user>@<vm-ip>:~/ApachePolaris/
```

Or push the repo to a private Git remote and run `git clone` on the VM.

Expected layout on the VM:
```
ApachePolaris/
├── docker-compose.yml
├── .env.example
├── polaris/application.properties
├── postgres/initdb/01-schema.sql
└── scripts/
    ├── bootstrap.sh
    ├── check-tableflow.sh
    ├── setup-tableflow-federation.sh
    └── verify.sh
```

---

## 3. Install Docker, curl and jq on the VM

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl jq openssl
curl -fsSL https://get.docker.com | sudo sh          # Docker Engine + compose plugin
sudo usermod -aG docker "$USER"
newgrp docker                                         # or log out and back in
docker version && docker compose version
```

---

## 4. Configure `.env`

```bash
cd ~/ApachePolaris
cp .env.example .env
chmod 600 .env
nano .env
```

| Variable | What to set |
|----------|-------------|
| `POSTGRES_USER` | `M73581` (PostgreSQL application role) |
| `POSTGRES_PASSWORD` | Strong password |
| `POLARIS_ROOT_CLIENT_ID` | `M73580` (the Polaris bootstrap administrator) |
| `POLARIS_ROOT_CLIENT_SECRET` | Strong password for the `M73580` principal |
| `POLARIS_TOKEN_BROKER_SECRET` | Output of `openssl rand -base64 48` |
| `POLARIS_PUBLIC_HOSTNAME` | Optional, informational only |
| `AZURE_TENANT_ID` | **Required**: tenant of the storage account |
| `AZURE_CLIENT_ID` | Blank for system-assigned MI; MI client ID for user-assigned MI; `appId` for service principal |
| `AZURE_CLIENT_SECRET` | Blank for managed identity; SP password for service principal |
| `AZURE_STORAGE_ACCOUNT` | ADLS Gen2 account name (no domain) |
| `AZURE_STORAGE_CONTAINER` | Tableflow BYOS container name |
| `TABLEFLOW_PROXY_BASE_URL` | Direct Tableflow URL or your nginx base URL, with no trailing path |
| `TABLEFLOW_ORG_ID` | `54c99051-8b33-4f51-b105-132f643b1720` (prefilled) |
| `TABLEFLOW_ENV_ID` | `env-xq8wnq` (prefilled) |
| `TABLEFLOW_API_KEY` / `TABLEFLOW_API_SECRET` | Tableflow-scoped Confluent API key and secret |
| `TABLEFLOW_OAUTH_SCOPE` | Leave empty unless Tableflow requires a scope |
| `TABLEFLOW_REMOTE_CATALOG_NAME` | Leave empty |
| `TABLEFLOW_CATALOG_URI` / `TABLEFLOW_TOKEN_URI` | Leave empty (derived automatically) |
| `POLARIS_CATALOG_NAME` | `tableflow` (name of the catalog inside Polaris) |
| `POLARIS_ADMIN_CATALOG_ROLE` | `tableflow_reader` (default is fine) |

The derived URLs that Polaris uses are:
```
catalog: ${TABLEFLOW_PROXY_BASE_URL}/iceberg/catalog/organizations/${TABLEFLOW_ORG_ID}/environments/${TABLEFLOW_ENV_ID}
token:   <catalog>/v1/oauth/tokens
```

Validate the configuration:
```bash
docker compose config -q && echo "compose config OK"
```

---

## 5. Start Postgres and bootstrap Polaris

```bash
docker compose pull
docker compose --profile bootstrap pull polaris-bootstrap
docker compose up -d postgres
docker compose ps                     # wait until postgres is "healthy"

./scripts/bootstrap.sh                # one-time: creates realm ISBUS + M73580 administrator
```
Expected output: `Realm 'POLARIS' successfully bootstrapped.` If you run it
again, it reports that the realm is already bootstrapped and exits cleanly.

The schema script in `postgres/initdb/` only runs the **first** time the
Postgres volume is created.

---

## 6. Start Polaris

```bash
docker compose up -d
docker compose ps                     # polaris should become "healthy" (about 30-60 s)
curl -s http://127.0.0.1:8182/q/health | jq .status     # "UP"
docker compose logs polaris --tail 50
```

Look for `polaris-server 1.8.0 ... started` and `Listening on http://0.0.0.0:8181`.

---

## 7. Check Tableflow connectivity (without Polaris)

```bash
./scripts/check-tableflow.sh
```
This gets a token through `TABLEFLOW_PROXY_BASE_URL`, then prints `/v1/config`
and the namespace list. It works with either direct Tableflow access or nginx
egress. Fix any failure here before you continue. If direct access is used,
ensure Azure DNS, outbound routing/NAT, and TLS trust are available. If nginx
is used, check the proxy configuration and for absolute URLs or `uri`
overrides that might cause clients to bypass nginx.

---

## 8. Create the federated catalog in Polaris

```bash
./scripts/setup-tableflow-federation.sh
```
This does the following:
1. Creates an **EXTERNAL** catalog `tableflow` with:
   - a connection to the Tableflow REST catalog (OAuth with your API key),
   - an Azure storage config: `abfss://<container>@<account>.dfs.core.windows.net/`
     (hierarchical namespace on).
2. Creates the catalog role `tableflow_reader` with `CATALOG_MANAGE_CONTENT`.
3. Assigns that role to `M73580`'s `service_admin` principal role.

It's safe to rerun. Catalog creation doesn't contact Tableflow, so wrong URLs
or keys only show up in the next step.

To change the catalog later, delete it and rerun the script:
```bash
TOKEN=$(curl -s http://localhost:8181/api/catalog/v1/oauth/tokens \
  -d "grant_type=client_credentials&client_id=M73580&client_secret=<M73580-secret>&scope=PRINCIPAL_ROLE:ALL" | jq -r .access_token)
curl -X DELETE -H "Authorization: Bearer $TOKEN" http://localhost:8181/api/management/v1/catalogs/tableflow
```
The delete may fail while catalog roles still exist. If it does, delete the
role `tableflow_reader` first.

---

## 9. Verify end to end through Polaris

```bash
./scripts/verify.sh
```
It checks the following, in order:
1. Administrator token for `M73580`
2. `/v1/config?warehouse=tableflow`
3. Namespaces (federated from Tableflow)
4. Tables in the first namespace
5. Loading the first table with `X-Iceberg-Access-Delegation: vended-credentials`,
   which shows `metadata-location` and the names of the `adls.sas-token.*` keys

Success ends with `All checks passed.` If there are no namespaces or tables
yet, wait for Tableflow to materialize a topic.

---

## 10. Connect a query engine (example: Spark)

```properties
spark.sql.catalog.polaris=org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.polaris.type=rest
spark.sql.catalog.polaris.uri=https://<polaris-public-or-private-host>/api/catalog
spark.sql.catalog.polaris.warehouse=tableflow
spark.sql.catalog.polaris.credential=M73580:<M73580-secret>
spark.sql.catalog.polaris.scope=PRINCIPAL_ROLE:ALL
spark.sql.catalog.polaris.header.X-Iceberg-Access-Delegation=vended-credentials
```
For production, create a dedicated read-only principal instead of using `M73580`.

---

## 11. Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `bootstrap` fails with `no schema has been selected` | The Postgres volume was created without the init script. Run `docker compose down -v` (this **deletes data**), then repeat step 5 |
| `polaris` not healthy | `docker compose logs polaris`. Check DB credentials and `POLARIS_TOKEN_BROKER_SECRET` |
| `check-tableflow.sh` 401 | Wrong API key or secret, or the key isn't scoped to Tableflow or lacks access to `env-xq8wnq` |
| `check-tableflow.sh` 404 / TLS error | For direct access, verify DNS, outbound routing/NAT, TLS trust, and URL values. For nginx access, verify `location`/`proxy_pass`, SNI, and certificate trust |
| `verify.sh` namespaces call fails | Polaris can't reach `TABLEFLOW_PROXY_BASE_URL` from inside the container. Test with `docker compose exec polaris curl -sI $TABLEFLOW_PROXY_BASE_URL` |
| `not in the list of allowed locations` | The table location from Tableflow isn't under `abfss://<container>@<account>.dfs.core.windows.net/`. Fix `AZURE_STORAGE_*` and recreate the catalog |
| `AADSTS...` errors in logs | Wrong tenant or SP credentials, an expired secret, or the managed identity isn't enabled |
| `403 AuthorizationPermissionMismatch` | Polaris identity lacks `Storage Blob Data Contributor` (or role propagation is still pending), or HNS ACLs block the path |
| No `adls.sas-token.*` keys | Credential vending isn't active. Check the flags in `polaris/application.properties` and the allowed locations |

Useful commands:
```bash
docker compose logs -f polaris
docker compose exec polaris curl -s http://localhost:8182/q/health
docker compose exec postgres psql -U M73581 -d POLARIS -c '\dn'
```

---

## 12. Operations

**Restart or stop**
```bash
docker compose restart polaris
docker compose stop
docker compose up -d
```

**Back up metadata**
```bash
docker compose exec -T postgres pg_dump -U M73581 POLARIS > polaris-$(date +%F).sql
```

**Restore**
```bash
docker compose exec -T postgres psql -U M73581 -d POLARIS < polaris-YYYY-MM-DD.sql
```

**Upgrade Polaris**: change the image tags for `apache/polaris` and
`apache/polaris-admin-tool` in `docker-compose.yml`, take a backup, then:
```bash
docker compose pull && docker compose up -d
```
Read the Polaris release notes for any required schema migration before you
upgrade.

**Rotate secrets**
- Tableflow API key: update `.env`, delete the catalog, and rerun step 8.
- `M73580` secret: rotate it through the Polaris CLI
  (`polaris principals rotate-credentials M73580`) or management API
  (`POST /api/management/v1/principals/M73580/rotate`), then update `.env`.

**Remove everything** (this **deletes all Polaris metadata**):
```bash
docker compose --profile bootstrap down -v
```
