# Install Apache Polaris on an Azure VM

This guide takes you from nothing to a running Polaris catalog that reads
Confluent Tableflow tables. Follow the steps **in order**. Each step says
**where** to do it and **what you should see** when it worked. If a step does
not show the expected result, stop and use the troubleshooting table in step 12.

**What you get:** one Ubuntu VM running Polaris and PostgreSQL in Docker.
Query engines (Spark, Trino, …) connect to Polaris over HTTPS and read table
files directly from Azure Data Lake Storage (ADLS).

| Part | Steps | Where |
|---|---|---|
| A. Prepare Azure and Confluent | 1–4 | Azure Portal, Confluent Cloud |
| B. Install on the VM | 5–9 | SSH session on the VM |
| C. Connect users | 10–11 | TLS gateway, query engine |
| D. Run it | 12–14 | SSH session on the VM |

---

## Step 0. Fill in your values worksheet

Copy this table into a private note and fill it in as you go. Every
`<placeholder>` later in this guide refers to a row here. **Secrets do not go
in this table** — they go straight into Key Vault in step 4.

| Placeholder | What it is | Found in step | Your value |
|---|---|---|---|
| `<vm-name>` | VM name | 1 | |
| `<vm-private-ip>` | VM private IP address | 1 | |
| `<vm-user>` | Linux user you SSH in as (for example `azureuser`) | 1 | |
| `<storage-account>` | ADLS Gen2 storage account name | 2 | |
| `<storage-container>` | Tableflow container name | 2 | |
| `<tenant-id>` | Polaris app Directory (tenant) ID | 2 | |
| `<polaris-app-client-id>` | Polaris app Application (client) ID | 2 | |
| `<tableflow-org-id>` | Tableflow organization ID | 3 | |
| `<tableflow-env-id>` | Tableflow environment ID | 3 | |
| `<vault-name>` | Key Vault name | 4 | |
| `<identity-client-id>` | Managed identity **Client ID** | 4 | |
| `<backup-storage-account>` | Storage account for backups (can be the same as above) | 4 | |

---

# Part A — Prepare Azure and Confluent

You need these permissions (or someone who has them): create Azure
resources, assign Azure roles, register an Entra app, write Key Vault
secrets, and configure Tableflow in Confluent Cloud.

## Step 1. Create the VM — *Azure Portal*

1. Go to **Virtual machines → Create → Azure virtual machine**.
2. Choose:
   - **Image:** Ubuntu Server 26.04 LTS
   - **Size:** at least 2 vCPU, 4 GB RAM (for example `Standard_B2s`)
   - **Authentication:** SSH public key
   - **Public inbound ports:** None (use Bastion or your admin network)
   - **Disk:** Standard SSD, at least 30 GB
3. **Networking:** choose the approved VNet and subnet. Create or use a network
   security group (NSG) with only these inbound rules:

   | Source | Port | Why |
   |---|---|---|
   | Your admin network or Azure Bastion | 22 | SSH |
   | TLS gateway subnet only (step 10) | 8181 | Polaris. Never open this to clients or the internet |

4. Click **Review + create → Create**.
5. When it finishes, open the VM and write down its **Private IP address**
   (`<vm-private-ip>`) and your SSH user (`<vm-user>`).

**Outbound access the VM needs** (ask your network team if outbound traffic is
restricted): HTTPS (443) to Ubuntu package mirrors, `packages.microsoft.com`,
`download.docker.com`, Docker Hub, GitHub, `login.microsoftonline.com`,
`management.azure.com`, `<vault-name>.vault.azure.net`,
`tableflow.<region>.azure.confluent.cloud`, and
`<storage-account>.blob.core.windows.net` / `.dfs.core.windows.net`; plus HTTP
to `169.254.169.254` (Azure managed identity; it must bypass any proxy).

## Step 2. Create storage and the Polaris app — *Azure Portal*

**2a. Storage account**

1. Go to **Storage accounts → Create**.
2. **Region:** the same region as your Confluent Kafka cluster (for example
   East US 2).
3. **Advanced** tab: turn on **Enable hierarchical namespace**.
4. Create it. Then open **Data storage → Containers → + Container** and create
   one empty container for Tableflow.
5. Write down `<storage-account>` and `<storage-container>`.

**2b. Polaris app registration** (Polaris uses it to hand out short-lived
read access to the table files)

1. Go to **Microsoft Entra ID → App registrations → New registration**.
   Name it, for example, `polaris-credential-vending`. Click **Register**.
2. On the app's **Overview** page, write down **Directory (tenant) ID**
   (`<tenant-id>`) and **Application (client) ID** (`<polaris-app-client-id>`).
3. Open **Certificates & secrets → Client secrets → New client secret**.
   Choose an expiry and click **Add**. Copy the **Value** column right away
   (not the Secret ID). You will paste it into Key Vault in step 4.
   **Put a reminder in your calendar for the expiry date.**

**2c. Give the Polaris app access to the storage account**

1. Open the storage account → **Access control (IAM) → Add → Add role
   assignment**.
2. Role: **Storage Blob Data Contributor**. Members: the app from 2b.
3. **Review + assign.** This must be on the **storage account**, not only the
   container.

## Step 3. Turn on Tableflow — *Confluent Cloud*

1. Set up the Azure provider integration for Tableflow by following
   [Confluent's storage guide](https://docs.confluent.io/cloud/current/topics/tableflow/how-to-guides/configure-storage.html).
   When it tells you to, give Confluent's service principal **Storage Blob
   Data Contributor** and **Reader** on the storage account from step 2a.
2. Open a Kafka topic that has data → **Enable Tableflow** → choose **Iceberg**
   and **Bring Your Own Storage** → choose the integration, storage account and
   container from step 2a. Wait until a table appears.
3. Open **Tableflow → API access** and copy the **REST Catalog Endpoint**. It
   looks like this:

   ```text
   https://tableflow.eastus2.azure.confluent.cloud/iceberg/catalog/organizations/<org-id>/environments/<env-id>
   ```

   Write down `<tableflow-org-id>` and `<tableflow-env-id>`. If your region is
   not `eastus2`, also note the host (`https://tableflow.<region>.azure.confluent.cloud`).
4. Still in **API access**, click **Create API key**. Choose a service account
   that can read this Tableflow catalog and pick **Tableflow** as the scope.
   Copy the **key** and **secret** — they go into Key Vault in step 4. Do not
   use a Kafka cluster key.

## Step 4. Key Vault, VM identity and backup storage — *Azure Portal*

**4a. Key Vault and secrets**

1. Go to **Key vaults → Create** (or open the existing vault). On **Access
   configuration**, choose **Azure role-based access control**. Write down
   `<vault-name>`.
2. Give yourself permission to add secrets: on the vault, **Access control
   (IAM) → Add role assignment → Key Vault Secrets Officer** → yourself.
3. Generate three random values on your own computer (Linux, macOS, WSL or
   Azure Cloud Shell):

   ```bash
   openssl rand -hex 32      # value 1: database password
   openssl rand -hex 32      # value 2: Polaris admin secret
   openssl rand -base64 48   # value 3: token signing key
   ```

4. In the vault, open **Objects → Secrets → + Generate/Import** and create
   these **six** secrets. The names must match exactly:

   | Secret name | Value |
   |---|---|
   | `polaris-postgres-password` | Value 1 |
   | `polaris-root-client-secret` | Value 2 |
   | `polaris-token-broker-secret` | Value 3. Never change it casually: changing it logs out every client |
   | `polaris-azure-client-secret` | App client secret **Value** from step 2b |
   | `polaris-tableflow-api-key` | Tableflow API key from step 3 |
   | `polaris-tableflow-api-secret` | Tableflow API secret from step 3 |

**4b. Managed identity for the VM** (lets the VM read Key Vault without any
password on disk)

1. Go to **Managed Identities → Create**. Name it, for example,
   `polaris-vault-reader`. Create it.
2. Open it and write down its **Client ID** (`<identity-client-id>`). Not the
   Object (principal) ID.
3. Open the **VM → Security → Identity → User assigned → + Add**, choose this
   identity, and click **Add**.
4. Open the **Key Vault → Access control (IAM) → Add role assignment →
   Key Vault Secrets User** → Members: **Managed identity** → this identity.

**4c. Backup container** (so backups survive if the VM is lost)

1. Pick a storage account for backups (`<backup-storage-account>`). A separate
   account is best; the Tableflow account from step 2a also works.
2. In it, create a container named `polaris-backups`.
3. On that **container**, **Access control (IAM) → Add role assignment →
   Storage Blob Data Contributor** → Members: **Managed identity** → the
   identity from 4b.
4. Optional but recommended: on the storage account, **Data management →
   Lifecycle management** → add a rule that deletes blobs in `polaris-backups`
   older than 30 days.

Role assignments can take up to 10 minutes to start working.

---

# Part B — Install on the VM

Connect to the VM with SSH (or Bastion) as `<vm-user>` and run every command
below in that session. Copy and paste each block exactly as shown.

## Step 5. Install software — *VM*

**5a. Basic tools and Azure CLI**

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git gnupg jq
curl -fsSL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

**5b. Docker**

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Membership of the `docker` group is effectively root access on the VM: add only
trusted administrators. **Now log out and SSH in again** so the Docker
permission takes effect.

**5c. Check everything is installed**

```bash
git --version && jq --version && az version --output none && echo "az OK"
docker run --rm hello-world | grep -m1 "Hello from Docker"
docker compose version
```

✅ **Expected:** version numbers, `az OK`, `Hello from Docker!`, and a Docker
Compose version. If `docker` says "permission denied", you did not log out and
back in.

## Step 6. Download the project — *VM*

```bash
cd ~
git clone https://github.com/innovate-angel/ApachePolaris.git
cd ~/ApachePolaris
```

✅ **Expected:** `ls` shows `docker-compose.yml`, `scripts` and `docs`.

## Step 7. Create the settings file — *VM*

All non-secret settings live in **one file**, `/etc/polaris/deployment.env`.
The scripts and the automatic timers both read it. Secrets never go in it.

1. Create the file:

   ```bash
   sudo mkdir -p /etc/polaris
   sudo nano /etc/polaris/deployment.env
   ```

2. Paste this, then replace every `<…>` with your worksheet values. No quotes,
   no spaces around `=`:

   ```text
   VAULT_NAME=<vault-name>
   IDENTITY_CLIENT_ID=<identity-client-id>
   POLARIS_BIND_ADDRESS=<vm-private-ip>
   AZURE_TENANT_ID=<tenant-id>
   AZURE_CLIENT_ID=<polaris-app-client-id>
   AZURE_STORAGE_ACCOUNT=<storage-account>
   AZURE_STORAGE_CONTAINER=<storage-container>
   TABLEFLOW_PROXY_BASE_URL=https://tableflow.eastus2.azure.confluent.cloud
   TABLEFLOW_ORG_ID=<tableflow-org-id>
   TABLEFLOW_ENV_ID=<tableflow-env-id>
   BACKUP_STORAGE_ACCOUNT=<backup-storage-account>
   BACKUP_CONTAINER=polaris-backups
   ```

   Change `TABLEFLOW_PROXY_BASE_URL` if your Tableflow region is not East US 2.
   Save with **Ctrl+O, Enter**, exit with **Ctrl+X**.

3. Load the settings into your session. **Run this line every time you open a
   new SSH session** before using any script:

   ```bash
   cd ~/ApachePolaris && set -a && source /etc/polaris/deployment.env && set +a
   ```

4. Check that the VM can read Key Vault:

   ```bash
   ./scripts/compose.sh config -q && echo "PREFLIGHT OK"
   ```

   ✅ **Expected:** `PREFLIGHT OK`. If not, check step 4b (identity attached,
   role assigned, waited 10 minutes) and the secret names in step 4a.

## Step 8. Deploy — *VM*

```bash
./scripts/deploy-from-key-vault.sh; echo "EXIT CODE: $?"
```

This starts PostgreSQL and Polaris, creates the admin account, connects
Polaris to Tableflow, and tests everything. The first run downloads images and
takes a few minutes.

| Exit code | Last line | Meaning |
|---|---|---|
| **0** | `All checks passed.` | ✅ Done. Polaris reads Tableflow tables and hands out storage access |
| **3** | `INCONCLUSIVE: ...` | ✅ Deployed, but Tableflow has no table yet. Wait for a table, then run the check below |
| other | `ERROR: ...` or `FAILED: ...` | ❌ Fix the cause shown (step 12), then run step 8 again. Rerunning is always safe |

To re-run only the checks later:

```bash
(set -e; source scripts/load-key-vault-env.sh; ./scripts/verify.sh)
```

## Step 9. Turn on automatic recovery and backups — *VM*

Two timers keep the installation healthy without anyone watching it:

- **Recovery** (every 5 minutes): after any Polaris restart or VM reboot,
  Polaris forgets its Tableflow password. This timer puts it back. When
  everything works it changes nothing.
- **Backup** (daily): saves the Polaris database to `/var/backups/polaris` on
  the VM, keeps 14 days, and uploads each backup to the `polaris-backups`
  container from step 4c.

**9a. Install the timers**

```bash
cd ~/ApachePolaris
for unit in deploy/systemd/*; do
  sed -e "s|/opt/polaris|$PWD|g" -e "s|^User=.*|User=$USER|" "$unit" |
    sudo tee "/etc/systemd/system/$(basename "$unit")" >/dev/null
done
sudo systemctl daemon-reload
sudo systemctl enable --now polaris-federation-reconcile.timer polaris-backup.timer
systemctl list-timers 'polaris-*'
```

✅ **Expected:** two timers listed, `polaris-backup.timer` and
`polaris-federation-reconcile.timer`, each with a **NEXT** time.

**9b. Test the backup**

```bash
sudo systemctl start polaris-backup.service
journalctl -u polaris-backup -n 5 --no-pager
```

✅ **Expected:** `Wrote /var/backups/polaris/polaris-<time>.dump` and
`Uploaded ... to <backup-storage-account>/polaris-backups`. In the Azure
Portal, the file is visible in the `polaris-backups` container.

**9c. Test the recovery**

```bash
./scripts/compose.sh restart polaris
echo "Wait 6 minutes..." && sleep 360
journalctl -u polaris-federation-reconcile -n 30 --no-pager | grep -E "Recreating|ok \(HTTP|ERROR"
```

✅ **Expected:** a `Recreating catalog 'tableflow'` line followed by
`ok (HTTP 200)`, and no `ERROR`.

---

# Part C — Connect users

## Step 10. Put HTTPS in front of Polaris — *TLS gateway*

Polaris itself speaks plain HTTP on port 8181. Users must reach it only through
an HTTPS gateway (for example Azure Application Gateway).

1. **Listener:** HTTPS on port 443 with a trusted certificate for your
   hostname (`<gateway-hostname>`, for example `polaris.example.com`).
2. **Backend:** `<vm-private-ip>`, HTTP, port **8181**. Keep the path as is.
3. **Health probe:** HTTP `GET /api/catalog/v1/config` on port 8181, and treat
   status **401** as healthy (Polaris answers 401 to requests without a login;
   that means it is up).
4. **VM network security group:** allow port 8181 **only** from the gateway's
   subnet (step 1).
5. Test from any computer that can reach the gateway:

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' https://<gateway-hostname>/api/catalog/v1/config
   ```

   ✅ **Expected:** `401` with no certificate warning.

## Step 11. Give a query engine read-only access — *VM, then the engine*

**11a. Create a login for the engine** (one per engine; on the VM after the
settings line from step 7):

```bash
(set -e; source scripts/load-key-vault-env.sh; ./scripts/create-reader-principal.sh my-spark-engine)
```

✅ **Expected:** the output ends with **Client ID** and **Client secret**.
**The secret is shown only once.** Store it in the engine's secret store now.
Never give an engine the Polaris admin secret, and never grant it the
`tableflow_reader` catalog role: despite its name, that role can change content.

**11b. Configure the engine** with these settings:

| Setting | Value |
|---|---|
| Catalog URI | `https://<gateway-hostname>/api/catalog` |
| Warehouse | `tableflow` |
| Credential | `<client-id>:<client-secret>` from 11a |
| Scope | `PRINCIPAL_ROLE:ALL` |
| Header `X-Iceberg-Access-Delegation` | `vended-credentials` |
| Header `Polaris-Realm` | `ISBUS` |

Example for Spark 3.5:

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

**11c. Test it** in the engine:

```sql
SHOW NAMESPACES IN tableflow;
SELECT * FROM tableflow.`<namespace>`.`<table>` LIMIT 1;
CREATE NAMESPACE tableflow.must_be_rejected;
```

✅ **Expected:** namespaces are listed, one row comes back, and the
`CREATE NAMESPACE` is **rejected** (the engine is read-only).

---

# Part D — Run it

Before any command in this part, open an SSH session and run the settings line:

```bash
cd ~/ApachePolaris && set -a && source /etc/polaris/deployment.env && set +a
```

## Step 12. Troubleshooting

| Problem | What to do |
|---|---|
| `permission denied` from `docker` | Log out and SSH in again (step 5b) |
| `PREFLIGHT` fails, managed identity or Key Vault `403` | Identity attached to the VM? **Key Vault Secrets User** assigned? Waited 10 minutes? Secret names exactly as in step 4a? |
| `... is not set as a shell environment variable` | You skipped the settings line, or a line in `/etc/polaris/deployment.env` is empty |
| Polaris not healthy | `./scripts/compose.sh logs --tail 100 polaris postgres` |
| Tableflow `401` or `403` | API key is not Tableflow-scoped, was deleted, or the service account cannot read the catalog |
| Tableflow `404` or TLS error | Compare `TABLEFLOW_PROXY_BASE_URL`, org ID and env ID with the endpoint from step 3 |
| `vended no ADLS SAS credentials` or storage `403` | App client secret expired? App has **Storage Blob Data Contributor** on the storage **account**? |
| Engine queries fail with HTTP `500` after a restart | Recovery timer will fix it within 5 minutes. Check `journalctl -u polaris-federation-reconcile -n 40` |
| `could not be restored` | Fix the reported cause and run step 8 again; it resumes where it stopped |
| Backup upload fails | Identity has **Storage Blob Data Contributor** on the `polaris-backups` container (step 4c)? |

**Useful commands**

```bash
./scripts/compose.sh ps                                  # are containers running and healthy?
./scripts/compose.sh logs --tail 100 polaris             # Polaris logs
systemctl list-timers 'polaris-*'                        # when timers ran / run next
journalctl -u polaris-federation-reconcile -n 40         # recovery log
journalctl -u polaris-backup -n 20                       # backup log
```

## Step 13. Change secrets (rotation)

Always: add the new value as a **new version** of the same Key Vault secret,
then run step 8 again. Some secrets need one extra step first:

| Secret | Before running step 8 | After |
|---|---|---|
| `polaris-postgres-password` | Run **A** below | Brief outage while containers restart |
| `polaris-root-client-secret` | Keep the old version enabled, then run **B** below | Disable the old version |
| `polaris-token-broker-secret` | Nothing | All clients must log in again |
| `polaris-azure-client-secret` | Create the new client secret in Entra; keep the old one | When step 8 ends with `All checks passed.`, delete the old client secret in Entra |
| `polaris-tableflow-api-key` + `polaris-tableflow-api-secret` | Create the new key in Confluent; update **both** secrets | Delete the old key in Confluent |

**A. Set the new database password** (expected output: `ALTER ROLE`):

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

**B. Set the new admin secret** (signs in with the previous version, then
switches to the new one):

```bash
(
  set -euo pipefail
  source scripts/load-key-vault-env.sh
  polaris="http://$POLARIS_BIND_ADDRESS:8181"
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
  echo "Admin secret updated"
)
```

**C. New secret for a query engine login** (the old secret stops working
immediately; replace `my-spark-engine` with the login name):

```bash
(
  set -euo pipefail
  source scripts/load-key-vault-env.sh
  polaris="http://$POLARIS_BIND_ADDRESS:8181"
  token="$(printf %s "$POLARIS_ROOT_CLIENT_SECRET" |
    curl -fsS -X POST "$polaris/api/catalog/v1/oauth/tokens" -H "Polaris-Realm: $POLARIS_REALM" \
      --data-urlencode grant_type=client_credentials \
      --data-urlencode "client_id=$POLARIS_ROOT_CLIENT_ID" \
      --data-urlencode client_secret@- \
      --data-urlencode scope=PRINCIPAL_ROLE:ALL | jq -r .access_token)"
  curl -fsS -X POST "$polaris/api/management/v1/principals/my-spark-engine/reset" \
    -H "Authorization: Bearer $token" -H "Polaris-Realm: $POLARIS_REALM" | jq .credentials
)
```

## Step 14. Backup, restore and upgrade

**Backup now** (for example before an upgrade):

```bash
sudo systemctl start polaris-backup.service && journalctl -u polaris-backup -n 5 --no-pager
```

**Restore a backup.** This replaces the current Polaris data with the backup.

1. Pick the file: `sudo ls /var/backups/polaris`. If the VM was lost, download
   it from the `polaris-backups` container in the Azure Portal and copy it to
   the new VM first.
2. Restore the database (change the file name on the first line). The block
   stops at the first error and restores everything or nothing:

   ```bash
   (
     set -euo pipefail
     dump=/var/backups/polaris/polaris-<time>.dump
     sudo test -s "$dump" || { echo "ERROR: $dump not found or empty"; exit 1; }
     ./scripts/compose.sh up -d --wait postgres
     ./scripts/compose.sh stop polaris
     pg="$(docker ps -q --filter label=com.docker.compose.project=polaris \
                        --filter label=com.docker.compose.service=postgres)"
     sudo cat "$dump" | docker exec -i "$pg" \
       sh -c 'pg_restore --clean --if-exists --single-transaction -U "$POSTGRES_USER" -d POLARIS'
     echo "RESTORE OK"
   )
   ```

   ✅ **Expected:** `RESTORE OK`. If you see an error instead, stop: Polaris
   is still stopped and the database is unchanged. Fix the cause and run the
   block again.

3. **Only after `RESTORE OK`**, start Polaris again:

   ```bash
   ./scripts/deploy-from-key-vault.sh; echo "EXIT CODE: $?"
   ```

   ✅ **Expected:** exit code 0 or 3, as in step 8.

**Upgrade Polaris.** Take a backup, read the
[Polaris upgrade notes](https://polaris.apache.org/releases/1.9.0/metastores/relational-jdbc/#upgrading-polaris),
update **both** Polaris image tags in `docker-compose.yml` together, then run
step 8. Do not change the PostgreSQL major version (17) without a planned
migration.

**Never** run `docker compose down -v`: it deletes the database.
