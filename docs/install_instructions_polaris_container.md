# Install Apache Polaris on an Azure VM

This runbook takes a fresh Ubuntu VM to a running Polaris 1.9.0 catalog
federated to Confluent Cloud Tableflow. Docker Compose runs Polaris, its
one-off Admin Tool, and PostgreSQL. Query engines connect to Polaris over
HTTPS and use vended credentials to read table files directly from ADLS Gen2.

## 1. Prerequisites — before you start

- [ ] **Azure and Confluent access.** An Azure subscription and tenant, Azure
  Portal access, and a Confluent Cloud environment with a Kafka cluster that
  supports Tableflow on Azure. Arrange for the appropriate admins to create
  resources, assign Azure roles, register an Entra application, write Key
  Vault secrets, and configure Tableflow and its provider integration.
- [ ] **VM and repository access.** Ubuntu 26.04 LTS (`amd64` or `arm64`),
  at least 2 vCPU and 4 GB RAM, and persistent disk space for images and the
  PostgreSQL volume. Keep host ports `8181` and `8182` free for Polaris. Have
  an SSH route to the VM (or Azure Bastion), a VM user with `sudo`, and the
  approved Git clone URL, deployment branch/tag, and Git authentication method.
  The approved ref must contain this runbook's changes.
- [ ] **Cloud resources.** An Azure RBAC-enabled Key Vault, a user-assigned
  managed identity for reading its secrets, a separate Polaris service principal
  for vending ADLS credentials, and an ADLS Gen2 container for Tableflow
  bring-your-own-storage (BYOS). Have a Tableflow-scoped API key and at least
  one materialized Iceberg table before validating table reads. Section 2
  explains how to prepare these.
- [ ] **Network, DNS, and TLS.** Confirm the routes below with the network
  owner. If query engines will connect remotely, arrange an approved TLS gateway
  and a trusted certificate for its client-facing DNS name. The gateway is
  external to Compose; you can verify the VM locally without it.
- [ ] **VM software.** Bash and standard Ubuntu utilities, Git, curl, jq, CA
  certificates, **Azure CLI (`az`)**, and Docker Engine with a Compose plugin
  that supports `docker compose up --wait`. Section 3 installs and verifies
  these before cloning. No separate PowerShell, Java, Python, PostgreSQL,
  Confluent CLI, or Polaris CLI installation is needed on the VM.

| From | To | Why |
|---|---|---|
| Approved admin network or Bastion | VM TCP `22` | SSH |
| Approved query engines | TLS gateway TCP `443` | Client-facing HTTPS |
| TLS gateway only | VM private IP, TCP `8181` | Polaris HTTP backend; never expose this port directly to clients |
| VM | `169.254.169.254:80` | Azure Instance Metadata Service (IMDS) for managed identity; bypass HTTP proxies |
| VM | `<vault>.vault.azure.net`, `management.azure.com`, TCP `443` | Key Vault reads and Azure CLI account discovery |
| VM and containers | Regional Tableflow host, `login.microsoftonline.com`, and `<account>.blob.core.windows.net` / `<account>.dfs.core.windows.net`, TCP `443` | Tableflow federation and ADLS credential vending |
| VM | Approved Git host (TCP `443` for HTTPS or the configured SSH port); Ubuntu package mirrors; `packages.microsoft.com` and `download.docker.com`; Docker Hub registry, auth, and image-delivery hosts (including `registry-1.docker.io` and `auth.docker.io`) | Clone, package installation, and image pulls |
| Query engines | `<account>.blob.core.windows.net` / `<account>.dfs.core.windows.net`, TCP `443` | Read Iceberg files using vended SAS credentials |

Allow DNS through the configured resolvers. NSG rules alone do not open Key
Vault or storage firewalls. For private endpoints, confirm the normal service
hostnames resolve to the private addresses from every required network. Keep
PostgreSQL `5432` internal and Polaris health port `8182` on VM loopback only.

## 2. Prepare cloud resources — Azure and Confluent consoles

Complete this section before your first VM deployment. Reuse resources that
already satisfy these requirements; do not generate replacement credentials
for an existing deployment just to follow this guide.

### 2.1 Create or confirm the VM and storage

1. In Azure Portal, open **Virtual machines → Create → Azure virtual machine**.
   Select the approved resource group, VNet/subnet, Ubuntu 26.04 LTS image,
   size, and persistent disk. Configure SSH key authentication and the inbound
   rules in section 1. If your VM already exists, confirm these settings
   instead.
2. In Azure Portal, open **Storage accounts → Create**. Select the Kafka
   cluster's Azure region (East US 2 for the example in this repository).
   On **Advanced**, enable **Hierarchical namespace**. Create a dedicated empty
   container under **Data storage → Containers** for a new Tableflow setup,
   or confirm the existing BYOS container. Record the storage account and
   container names.
3. Configure the storage network policy for Confluent, the Polaris VM, and
   the query engines that will read the data. Use the approved private or
   service endpoint design; do not open the storage account to work around
   a blocked route.

### 2.2 Give Confluent and Polaris access to storage

1. In Confluent Cloud, set up the Azure provider integration for Tableflow
   using [Confluent's storage setup guide](https://docs.confluent.io/cloud/current/topics/tableflow/how-to-guides/configure-storage.html).
   In Azure Portal, grant the integration's **Confluent** service principal
   `Storage Blob Data Contributor` and `Reader` on the storage account.
2. Create or reuse a **separate** Polaris application in **Microsoft Entra
   ID → App registrations** in the storage account's tenant. Record its
   **Directory (tenant) ID** and **Application (client) ID**. In the app's
   **Certificates & secrets → Client secrets**, create a secret if needed.
   Save the secret **Value**, not the Secret ID, for Key Vault.
3. On the storage account, go to **Access control (IAM) → Add role assignment**.
   Grant `Storage Blob Data Contributor` at **storage account scope** to the
   Polaris application's service principal. It must be able to request a user
   delegation key; container-only scope does not suffice for that operation.

### 2.3 Enable Tableflow and collect catalog credentials

1. In Confluent Cloud, open the target Kafka topic and select **Enable
   Tableflow**. Choose Iceberg and **Bring Your Own Storage**, then select the
   provider integration, storage account, and container from the preceding
   steps. Use a topic with data and wait for an Iceberg table to materialize.
2. Open **Tableflow → API access** and copy the **REST Catalog Endpoint**.
   Record the HTTPS host and the organization and environment IDs from the
   endpoint:

   ```text
   https://tableflow.eastus2.azure.confluent.cloud/iceberg/catalog/organizations/<org-id>/environments/<env-id>
   ```

3. Under **API access → Create/View API keys → Add API key**, choose an
   approved service account authorized to read the target Tableflow catalog.
   Choose **Tableflow** as the resource scope. Save both the key and its
   secret for Key Vault. Do not use a Kafka cluster or Cloud management API
   key here.

### 2.4 Populate Key Vault and attach the VM identity

1. In **Key vaults**, create or select the deployment vault. Confirm its
   permission model is **Azure role-based access control**. Allow secret
   access from the VM and the approved admin network. Use an account with
   `Key Vault Secrets Officer` or equivalent data-plane permission to add the
   secrets under **Objects → Secrets → Generate/Import**.
2. Create the six enabled secrets below using the **exact names**. For a fresh
   deployment, generate two different random passwords (`openssl rand -hex 32`
   for each, or an approved password generator) and generate a separate signing
   key with `openssl rand -base64 48`. Generate them on a trusted admin system
   and transfer the values directly to Key Vault using your approved process.

   | Key Vault secret name | What to store |
   |---|---|
   | `polaris-postgres-password` | Generated PostgreSQL password |
   | `polaris-root-client-secret` | Generated Polaris bootstrap administrator secret |
   | `polaris-token-broker-secret` | Generated Base64 signing key; keep it stable across redeployments |
   | `polaris-azure-client-secret` | Polaris Entra app's client secret **value** from section 2.2 |
   | `polaris-tableflow-api-key` | Tableflow-scoped key from section 2.3 |
   | `polaris-tableflow-api-secret` | Matching Tableflow API secret |

3. In **Managed Identities**, create or select the user-assigned deployment
   identity and record its **Client ID**, not its Object (principal) ID.
   On the VM, go to **Identity → User assigned → Add** and attach it.
4. On the vault, go to **Access control (IAM) → Add role assignment**. Grant
   `Key Vault Secrets User` to that managed identity at vault scope. Wait
   for the assignment to propagate. The VM's identity does not need
   permission to create secrets or a subscription-wide role. The Polaris
   service principal does not need Key Vault access.

For the equivalent Azure CLI identity setup, see
[Shared User-Assigned Managed Identity](./AZURE_KEY_VAULT_SHARED_IDENTITY.md).

## 3. Install packages — on the Ubuntu VM

SSH to the VM as the deployment user (or connect through Bastion). Use Bash
for the remaining VM commands. Stop and resolve any command error before
moving to the next section.

### 3.1 Install Git, curl, jq, and Azure CLI

Use the signed Microsoft apt repository
([Azure CLI installation reference](https://learn.microsoft.com/cli/azure/install-azure-cli-linux?pivots=apt)):

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git gnupg jq
sudo install -m 0755 -d /etc/apt/keyrings

(
  set -euo pipefail
  ubuntu_codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
  architecture="$(dpkg --print-architecture)"
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null
  sudo chmod a+r /etc/apt/keyrings/microsoft.gpg
  sudo tee /etc/apt/sources.list.d/azure-cli.sources > /dev/null <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${ubuntu_codename}
Components: main
Architectures: ${architecture}
Signed-By: /etc/apt/keyrings/microsoft.gpg
EOF
  sudo apt-get update
  sudo apt-get install -y azure-cli
)

git --version
curl --version
jq --version
az version
```

### 3.2 Install Docker Engine and the Compose plugin

On a fresh VM, use [Docker's signed apt repository](https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository).
On a VM with an existing Docker installation, verify it first. Do not
replace a working installation or remove volumes to follow these commands.

```bash
(
  set -euo pipefail
  ubuntu_codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
  architecture="$(dpkg --print-architecture)"
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${ubuntu_codename}
Components: stable
Architectures: ${architecture}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
)
```

If only `sudo` can access Docker, grant the approved deployment user Docker
access. Membership in the `docker` group is effectively root access; do not
grant it to untrusted users.

```bash
sudo usermod -aG docker "$USER"
```

Disconnect and reconnect over SSH after changing group membership. Verify these
commands as the deployment user **without** `sudo`:

```bash
docker info --format '{{.ServerVersion}}'
docker compose version
docker compose up --help | grep -F -- '--wait'
```

## 4. Clone and configure — on the VM

Replace the bracketed placeholders below before running the commands. Use
approved Git credentials; do not put tokens in the clone URL.

```bash
cd "$HOME" &&
  git clone --branch '<approved-branch-or-tag>' '<approved-git-url>' ApachePolaris &&
  cd ApachePolaris
```

Export the non-secret settings in the same Bash session you'll use to deploy.
You can keep this block in an approved configuration file for future sessions,
but do not store secrets in it or rely on `.env`.

```bash
export VAULT_NAME='<vault-name>'
export IDENTITY_CLIENT_ID='<VM-managed-identity-client-id>'
export POLARIS_BIND_ADDRESS='<VM-private-IP-reached-by-TLS-gateway>'  # or 127.0.0.1; never 0.0.0.0
export AZURE_TENANT_ID='<Polaris-Entra-app-tenant-id>'
export AZURE_CLIENT_ID='<Polaris-Entra-app-client-id>'
export AZURE_STORAGE_ACCOUNT='<ADLS-account-name>'
export AZURE_STORAGE_CONTAINER='<Tableflow-BYOS-container-name>'
export TABLEFLOW_PROXY_BASE_URL='https://tableflow.eastus2.azure.confluent.cloud'
export TABLEFLOW_ORG_ID='<Tableflow-organization-id>'
export TABLEFLOW_ENV_ID='<Tableflow-environment-id>'
```

`TABLEFLOW_PROXY_BASE_URL` is the Tableflow HTTPS origin from section 2.3 (no
path), despite its name. The scripts append the catalog path and derive the
OAuth token URL. The repository defaults are realm `ISBUS`, PostgreSQL user
`M73581`, bootstrap client ID `M73580`, and catalog name `tableflow`. Leave
`POLARIS_URL` unset during deployment so the scripts use the local HTTP
listener. Keep `CURL_INSECURE` unset so TLS certificate validation stays on.

### Preflight: prove the VM can read Key Vault and resolve Compose

```bash
./scripts/compose.sh config -q
```

This uses `az login --identity` with the attached identity, checks that all
six secret values can be read, and validates Compose without printing the
resolved configuration. Exit status zero means the preflight passed. No
containers are started. If it fails, do not deploy: check the VM identity
attachment, vault permissions and firewall, secret names, and exported
settings. There is no interactive Azure login or PowerShell step on the VM.

## 5. Deploy and verify — on the VM

From `~/ApachePolaris`, keeping the exports from section 4:

```bash
./scripts/deploy-from-key-vault.sh
```

The script loads secrets in its own process, starts `postgres:17-alpine`,
bootstraps the realm with `apache/polaris-admin-tool:1.9.0`, waits for
`apache/polaris:1.9.0` to be healthy, checks direct Tableflow access, creates
or repairs the federated catalog, and runs verification. Compose pulls missing
images automatically. On a fresh volume, the Postgres init script creates the
SQL schema and the matching Polaris Admin Tool creates its tables.

The script's exit status says what was proven:

| Exit status | Last line | Meaning |
|---|---|---|
| `0` | `All checks passed.` | A table loaded through Polaris, it is in the expected ADLS account and container, and Polaris vended SAS credentials for it |
| `3` | `INCONCLUSIVE: ...` | Everything is deployed, but Tableflow has published no table yet, so credential vending is unproven |
| Any other | `ERROR: ...` or `FAILED: ...` | That step failed; fix the cause and rerun |

```bash
./scripts/compose.sh ps
curl -fsS http://127.0.0.1:8182/q/health | jq -e '.status == "UP"'
```

Both `postgres` and `polaris` should be healthy. The one-off Admin Tool is not
a running service. A green health check alone proves none of the above. After
an `INCONCLUSIVE` result, check Tableflow, wait for a table to materialize,
then rerun verification until it exits `0`:

```bash
(set -e; source scripts/load-key-vault-env.sh; ./scripts/verify.sh)
```

You can rerun the deployment at any time without removing the database volume;
it is also how restarts and secret changes are applied (section 7). When the
catalog's Tableflow settings have changed or its connection has stopped
working, the rerun recreates the catalog and restores its catalog roles,
grants, and role assignments.

## 6. Connect a query engine — after local verification

### 6.1 Put the TLS gateway in front of Polaris

1. Configure the approved gateway with an HTTPS listener on `443`, the
   certificate matching the client-facing hostname, and an HTTP backend
   pointing to `<vm-private-ip>:8181`. Preserve the `/api/catalog` path and
   authorize the gateway's source subnet/IPs for `8181` in the VM NSG.
2. Configure the health probe as an HTTP `GET /api/catalog/v1/config` on port
   `8181` that treats status `401` as healthy (in Azure Application Gateway: a
   custom probe with the status code match set to `401`). A working Polaris
   answers an unauthenticated request to that path with `401`, so the probe
   needs no credentials. If the gateway can only accept `2xx`/`3xx`, use a TCP
   probe on `8181` instead. Do not open the VM-only `8182` health port; the
   probe shows that Polaris is serving, while database health stays visible on
   the VM at `http://127.0.0.1:8182/q/health`.
3. From a machine that reaches the gateway, confirm the route and the
   certificate. Expect `401`, with no certificate warning and without `-k`:

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' https://<gateway-hostname>/api/catalog/v1/config
   ```

### 6.2 Create a read-only principal for the engine

On the VM, from `~/ApachePolaris` with the section 4 exports, create one
principal per query engine:

```bash
(set -e; source scripts/load-key-vault-env.sh; ./scripts/create-reader-principal.sh '<engine-principal-name>')
```

The script creates the principal, puts it in the `tableflow_readers` principal
role, and grants that role the `tableflow_read_only` catalog role. The
principal can list and describe namespaces and tables and load tables with
vended read credentials; creating, altering, or dropping anything and the
management API are denied. The output ends with the principal's **client ID
and client secret, shown only once**: put them in the engine's secret store
immediately. Rerunning the script for an existing principal re-checks its
access and leaves its credentials unchanged; section 7 covers issuing a new
secret.

Do not give a query engine the bootstrap administrator's credentials, and do
not grant it the `tableflow_reader` catalog role: despite its name, that role
carries `CATALOG_MANAGE_CONTENT` and exists for the deployment's own
verification.

### 6.3 Configure the engine

Use an Iceberg REST-capable engine with Azure storage support and these
settings:

| Setting | Value |
|---|---|
| Catalog URI | `https://<gateway-hostname>/api/catalog` |
| Warehouse | `tableflow` |
| OAuth credential | `<client-id>:<client-secret>` from section 6.2, read from the engine's secret store |
| OAuth scope | `PRINCIPAL_ROLE:ALL` |
| OAuth token endpoint | `https://<gateway-hostname>/api/catalog/v1/oauth/tokens`; Iceberg clients derive it from the catalog URI, so set it only if the engine asks for it |
| Header `X-Iceberg-Access-Delegation` | `vended-credentials` |
| Header `Polaris-Realm` | `ISBUS`. Polaris falls back to this realm when the header is absent, so an engine that cannot send custom headers still works |

For example, Spark 3.5 with Iceberg 1.12.0 (match the runtime artifact to the
engine's Spark and Scala versions):

```bash
spark-sql \
  --packages org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:1.12.0,org.apache.iceberg:iceberg-azure-bundle:1.12.0 \
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \
  --conf spark.sql.catalog.tableflow=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.tableflow.catalog-impl=org.apache.iceberg.rest.RESTCatalog \
  --conf spark.sql.catalog.tableflow.uri=https://<gateway-hostname>/api/catalog \
  --conf spark.sql.catalog.tableflow.warehouse=tableflow \
  --conf spark.sql.catalog.tableflow.credential="${POLARIS_CLIENT_ID}:${POLARIS_CLIENT_SECRET}" \
  --conf spark.sql.catalog.tableflow.scope=PRINCIPAL_ROLE:ALL \
  --conf spark.sql.catalog.tableflow.token-refresh-enabled=true \
  --conf spark.sql.catalog.tableflow.header.X-Iceberg-Access-Delegation=vended-credentials \
  --conf spark.sql.catalog.tableflow.header.Polaris-Realm=ISBUS \
  --conf spark.redaction.regex='(?i)secret|password|token|access[.]?key|credential'
```

### 6.4 Prove the read path

1. List the namespaces and tables, then run a small read against the known
   materialized table:

   ```sql
   SHOW NAMESPACES IN tableflow;
   SELECT * FROM tableflow.`<namespace>`.`<table>` LIMIT 1;
   ```

   A returned row verifies the client-to-gateway connection **and** the
   client-to-ADLS data path with vended credentials.
2. Confirm the principal is read-only. This statement must be rejected as
   forbidden:

   ```sql
   CREATE NAMESPACE tableflow.must_be_rejected;
   ```

## 7. Troubleshooting and operations

| Symptom | Check or action |
|---|---|
| `az: command not found` or `docker: command not found` | Complete section 3 on the VM, not on your workstation |
| Managed identity login error | Check the attached identity's client ID, IMDS reachability, and proxy exclusions |
| Key Vault `403` or missing secret | Check `Key Vault Secrets User`, role propagation, firewall/private DNS, and enabled secret names |
| Docker socket permission denied | Confirm the deployment user is authorized and has reconnected since the group change |
| Bootstrap reports a missing schema | Check the Postgres volume's initialization history and `postgres/initdb/01-schema.sql`. Do **not** delete a volume that holds data |
| Polaris unhealthy | Check `./scripts/compose.sh logs --tail 100 postgres polaris` and verify database credentials and the token-broker signing key |
| Tableflow `401` or `403` | Confirm the API key is Tableflow-scoped, current, and authorized for this environment |
| Tableflow `404` or TLS error | Compare the derived URL to the Confluent REST endpoint and check DNS, egress, and certificate trust |
| Verification fails with `vended no ADLS SAS credentials`, or ADLS `403` | Check the Polaris service principal's client secret (not expired), its storage-account role, networking and ACLs, the vending flags in `configs/polaris/application.properties`, and the catalog's allowed location |
| Requests through the `tableflow` catalog return HTTP `500` `NullPointerException` | Polaris restarted and lost the Tableflow secret. Rerun `./scripts/deploy-from-key-vault.sh` (see below) |
| Deployment ends with `INCONCLUSIVE` and exit status `3` | Tableflow has published no table yet. Check the topic's Tableflow status, then rerun verification (section 5) |
| Deployment stops with `could not be restored` | A catalog role, grant, or assignment could not be put back after the catalog was recreated. Fix the reported cause and rerun the deployment; the record it retries from is under `~/.local/state/polaris/` |

In a new SSH session, re-export the non-secret settings from section 4 and
change to `~/ApachePolaris` before running Compose operations.

```bash
./scripts/compose.sh logs --tail 100 polaris
```

### After any Polaris restart

Polaris 1.9.0 keeps the catalog's Tableflow client secret in memory only.
Whenever the Polaris container restarts (a manual restart, a VM reboot, a
Docker Engine upgrade, or a crash), the `tableflow` catalog stays listed but
every request through it fails with HTTP `500` until the connection is
re-established. Polaris cannot update a catalog's connection in place, so the
deployment script recreates the catalog and restores its catalog roles, grants,
and role assignments. Principals and their credentials are not touched. The
catalog is missing for a few seconds while this happens; engine queries in that
window fail and can be retried.

To restart Polaris deliberately:

```bash
./scripts/compose.sh restart polaris
./scripts/deploy-from-key-vault.sh
```

Nothing reruns the deployment after an unplanned restart. Rerun it after every
VM reboot and Docker upgrade, and check the catalog at any time with:

```bash
(set -e; source scripts/load-key-vault-env.sh; ./scripts/verify.sh)
```

### Rotate secrets

Add the new value as a new version of the same Key Vault secret, then rerun
`./scripts/deploy-from-key-vault.sh`. The rerun recreates the containers whose
values changed, re-establishes the Tableflow connection, and verifies. A
Compose `restart` does not load new values into a container. PostgreSQL and
Polaris each store one of the secrets themselves, so those two need a step on
the VM before the rerun:

| Key Vault secret | Before the rerun | What the rerun does, and what to expect |
|---|---|---|
| `polaris-postgres-password` | Run **Set the database password** below | Recreates both containers, a brief outage. Without the step, the rerun stops at bootstrap with `password authentication failed` |
| `polaris-root-client-secret` | Keep the previous version enabled, then run **Set the administrator secret** below | Recreates nothing. Without the step, the rerun stops with `token request failed`; Polaris and the query engines keep working. Disable the previous version afterwards |
| `polaris-token-broker-secret` | Nothing | Recreates Polaris. Every token issued before is rejected with `401`, so engines must authenticate again |
| `polaris-azure-client-secret` | Create the new client secret in Entra and leave the old one in place | Recreates Polaris. Once the rerun ends with `All checks passed.`, delete the old client secret in Entra. Entra client secrets expire: record the date and rotate before it, because credential vending stops when it passes |
| `polaris-tableflow-api-key` and `polaris-tableflow-api-secret` | Create the new Tableflow-scoped key in Confluent and update both secrets together | Sees the new key ID and recreates the catalog, keeping its roles and grants. Then delete the old key in Confluent |

**Set the database password** to the current Key Vault value. Expect the
output `ALTER ROLE`:

```bash
(
  set -euo pipefail
  source scripts/load-key-vault-env.sh
  NEW_POSTGRES_PASSWORD="$POSTGRES_PASSWORD" docker compose exec -T -e NEW_POSTGRES_PASSWORD postgres \
    sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d POLARIS' <<'SQL'
\set new_password `printf %s "$NEW_POSTGRES_PASSWORD"`
ALTER ROLE CURRENT_USER PASSWORD :'new_password';
SQL
)
```

**Set the administrator secret** to the current Key Vault value. The block
signs in with the previous enabled version and then replaces it; run a second
time, it fails at the sign-in and changes nothing:

```bash
(
  set -euo pipefail
  source scripts/load-key-vault-env.sh
  polaris=http://127.0.0.1:8181
  previous_id="$(az keyvault secret list-versions --vault-name "$VAULT_NAME" \
    --name polaris-root-client-secret \
    --query 'sort_by([?attributes.enabled], &attributes.created)[-2].id' --output tsv)"
  token="$(az keyvault secret show --id "$previous_id" --query value --output tsv |
    tr -d '\n' |
    curl -fsS -X POST "$polaris/api/catalog/v1/oauth/tokens" -H "Polaris-Realm: $POLARIS_REALM" \
      --data-urlencode grant_type=client_credentials \
      --data-urlencode "client_id=$POLARIS_ROOT_CLIENT_ID" \
      --data-urlencode client_secret@- \
      --data-urlencode scope=PRINCIPAL_ROLE:ALL | jq -r .access_token)"
  jq -n --arg secret "$POLARIS_ROOT_CLIENT_SECRET" '{clientSecret: $secret}' |
    curl -fsS -o /dev/null -X POST "$polaris/api/management/v1/principals/root/reset" \
      -H "Authorization: Bearer $token" -H "Polaris-Realm: $POLARIS_REALM" \
      -H 'Content-Type: application/json' -d @-
)
```

**Query engine principals** from section 6.2 are not in Key Vault. This issues
a new secret for one and prints it once; the old secret stops working
immediately, so update the engine's secret store right away:

```bash
(
  set -euo pipefail
  source scripts/load-key-vault-env.sh
  polaris=http://127.0.0.1:8181
  token="$(printf %s "$POLARIS_ROOT_CLIENT_SECRET" |
    curl -fsS -X POST "$polaris/api/catalog/v1/oauth/tokens" -H "Polaris-Realm: $POLARIS_REALM" \
      --data-urlencode grant_type=client_credentials \
      --data-urlencode "client_id=$POLARIS_ROOT_CLIENT_ID" \
      --data-urlencode client_secret@- \
      --data-urlencode scope=PRINCIPAL_ROLE:ALL | jq -r .access_token)"
  curl -fsS -X POST "$polaris/api/management/v1/principals/<engine-principal-name>/reset" \
    -H "Authorization: Bearer $token" -H "Polaris-Realm: $POLARIS_REALM" | jq .credentials
)
```

### Backup and upgrade

Back up the metastore to an approved location and protect the backup like a
secret. For example, with the default database user:

```bash
(umask 077; ./scripts/compose.sh exec -T postgres pg_dump -U M73581 POLARIS \
  > "polaris-$(date +%F).sql")
```

For an upgrade, take a backup, follow the versioned
[JDBC metastore migration instructions](https://polaris.apache.org/releases/1.9.0/metastores/relational-jdbc/#upgrading-polaris),
and update both Polaris image tags together. Do not start a new release until
any required database migration is applied. Never run `down -v` on data you
intend to keep.
