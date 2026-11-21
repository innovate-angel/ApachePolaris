# Apache Polaris CLI

**Author:** Angel Vega  
**Date:** 2026-11-21

This document describes installation, configuration, authentication, and
common usage of the Apache Polaris CLI.

The CLI is not required to start Polaris or run the Admin Tool. It is used for
normal management operations after the Polaris realm and server are available.

## Installation

### Azure VM or administrator workstation

Install the CLI with Python and pip:

```bash
python3 -m pip install --upgrade pip
python3 -m pip install apache-polaris
polaris --help
```

Recommended practice is to use a virtual environment:

```bash
python3 -m venv ~/.venv/polaris-cli
source ~/.venv/polaris-cli/bin/activate
python3 -m pip install apache-polaris
```

The CLI does not need to be installed inside the
`apache/polaris:1.8.0` container. Installing it on the VM or an administrator
workstation is simpler and keeps credentials outside the server container.

### Docker alternative

The official Polaris server images do not provide a documented interactive
`polaris` CLI command. A separate Python environment or container can provide
the CLI, but using the VM or workstation installation avoids an unnecessary
container.

## Authentication

The CLI supports OAuth client credentials or an existing access token.

For client credentials:

```bash
polaris \
  --host polaris.example.com \
  --scheme https \
  --realm ISBUS \
  --client-id M73580 \
  --client-secret '<M73580-secret>' \
  catalogs list
```

For direct bearer-token authentication:

```bash
polaris \
  --base-url https://polaris.example.com \
  --realm ISBUS \
  --access-token '<bearer-token>' \
  catalogs list
```

Do not provide client credentials and an access token in the same command.

### Environment variables

The CLI can read credentials from environment variables:

```bash
export CLIENT_ID=M73580
export CLIENT_SECRET='<M73580-secret>'
export REALM=ISBUS
export HEADER=Polaris-Realm

polaris --host polaris.example.com --scheme https catalogs list
```

If the variables are not set, provide the values as command-line options.

Supported global options include:

```text
--host HOST
--port PORT
--scheme {http,https}
--base-url BASE_URL
--catalog-url CATALOG_URL
--client-id CLIENT_ID
--client-secret CLIENT_SECRET
--access-token ACCESS_TOKEN
--realm REALM
--header HEADER
--profile PROFILE
--page-size PAGE_SIZE
```

Use `--base-url` instead of combining `--host`, `--port`, and `--scheme`.

## Client Profiles

The CLI stores reusable connection settings in `~/.polaris.json` by default.
Set `POLARIS_HOME` to change the profile directory.

Create or select profiles using the CLI profile commands:

```bash
polaris profiles --help
polaris profiles list
```

Profile commands can vary by installed CLI release. The profile name can be
selected with:

```bash
polaris --profile isbus-prod catalogs list
```

Set a default profile through the environment:

```bash
export CLIENT_PROFILE=isbus-prod
```

Profiles are convenient, but secret-bearing profile files must be protected:

```bash
chmod 600 ~/.polaris.json
```

Do not store Polaris secrets in source control or shell history.

## Realm Selection

Set the Polaris realm for every administrative context:

```bash
--realm ISBUS
```

This repository configures the Polaris realm as `ISBUS`. The CLI sends the
realm using the `Polaris-Realm` header unless a custom header name is configured.

If `--realm` is omitted, the CLI does not send the realm header and Polaris
uses its configured default behavior.

## Connection Forms

### Host and port

```bash
polaris \
  --host polaris.example.com \
  --port 443 \
  --scheme https \
  --realm ISBUS \
  --client-id M73580 \
  --client-secret '<M73580-secret>' \
  catalogs list
```

### Complete base URL

Use this for public HTTPS hostnames, private prefixes, or reverse proxies:

```bash
polaris \
  --base-url https://polaris.example.com \
  --realm ISBUS \
  --client-id M73580 \
  --client-secret '<M73580-secret>' \
  catalogs list
```

Do not combine `--base-url` with `--host`, `--port`, or `--scheme`.

### Catalog URL

Use `--catalog-url` when a deployment maps the Iceberg REST catalog directly
and the complete catalog root differs from the management base URL:

```bash
polaris \
  --base-url https://polaris.example.com \
  --catalog-url https://polaris.example.com/api/catalog/v1 \
  --realm ISBUS \
  --client-id M73580 \
  --client-secret '<M73580-secret>' \
  namespaces list --catalog tableflow
```

## Common Management Commands

### Catalogs

```bash
polaris catalogs list
polaris catalogs get tableflow
polaris catalogs summarize tableflow
polaris catalogs delete tableflow
```

Create an internal catalog:

```bash
polaris catalogs create \
  --type internal \
  --storage-type azure \
  --default-base-location abfss://container@account.dfs.core.windows.net/ \
  --tenant-id <tenant-id> \
  my_catalog
```

Create an external Iceberg REST catalog:

```bash
polaris catalogs create \
  --type external \
  --catalog-connection-type iceberg-rest \
  --catalog-uri https://tableflow.example.com/iceberg \
  --catalog-authentication-type oauth \
  --catalog-token-uri https://tableflow.example.com/iceberg/v1/oauth/tokens \
  --catalog-client-id <remote-client-id> \
  --catalog-client-secret <remote-client-secret> \
  tableflow
```

### Namespaces

```bash
polaris namespaces create --catalog tableflow sales
polaris namespaces create --catalog tableflow sales.east
polaris namespaces list --catalog tableflow
polaris namespaces list --catalog tableflow --parent sales
polaris namespaces get --catalog tableflow sales.east
polaris namespaces delete --catalog tableflow sales.east
```

### Principals and credentials

```bash
polaris principals list
polaris principals create data_reader
polaris principals rotate-credentials data_reader
polaris principals get M73580
```

The bootstrap administrator `M73580` should not be used for routine queries or
applications. Create a dedicated principal with the minimum required privileges.

### Roles and privileges

```bash
polaris principal-roles list
polaris catalog-roles list --catalog tableflow
polaris privileges namespace grant \
  --catalog tableflow \
  --catalog-role tableflow_reader \
  --namespace sales \
  TABLE_READ_DATA
```

Use `--help` with each command to inspect version-specific options:

```bash
polaris --help
polaris catalogs --help
polaris catalogs create --help
polaris namespaces --help
polaris principals --help
```

## HTTPS and TLS

For public HTTPS, the CLI uses the workstation or VM operating-system trust
store. For a private certificate authority:

- Install the private root certificate on the administrator workstation or VM.
- Or configure the CLI/Python environment to trust the private CA.
- Do not use `CURL_INSECURE=1` for production.

The Polaris server container also needs to trust HTTPS certificates presented
by external catalog endpoints.

## Security Recommendations

- Use an HTTPS endpoint for all remote CLI connections.
- Keep port `8181` private unless protected by an approved ingress gateway.
- Prefer dedicated service principals over `M73580`.
- Protect `.env`, `.polaris.json`, and shell histories.
- Use least-privilege catalog roles and namespace/table grants.
- Rotate credentials with `polaris principals rotate-credentials`.
- Keep the CLI, Polaris server, and Admin Tool versions aligned.

## Relationship to the Admin Tool

The Admin Tool and CLI serve different purposes:

| Tool | Purpose |
|---|---|
| Polaris Admin Tool | Bootstrap/purge realms and maintain the metastore |
| Polaris CLI | Create and manage catalogs, namespaces, principals, roles, and privileges |

The Admin Tool is used during installation or metastore maintenance. The CLI
is used by administrators and automation after installation.
