# Apache Polaris Deployment Software and Framework Inventory

**Author:** Angel Vega  
**Date:** 2026-11-24

This document describes the software and frameworks used by the Apache Polaris
deployment in this repository. Compose pins the Polaris server and Admin Tool
to release 1.9.0; upgrades are deliberate.

## Core Application

| Component | Version / implementation | Purpose |
|---|---|---|
| Apache Polaris | `1.9.0` official Docker tag | Iceberg REST catalog, management API, authorization, credential vending, and external catalog federation |
| Java | OpenJDK 21 | Runtime for the Polaris server and Admin Tool |
| JVM base image | Red Hat UBI 9 OpenJDK 21 runtime | Container runtime for Polaris Java applications |
| Quarkus | 3.40.1.2 in Polaris 1.9.0 | Java application framework and runtime |
| Apache Iceberg | 1.12.0 in Polaris 1.9.0 | Iceberg catalog APIs and table metadata implementation |

The pinned `apache/polaris:1.9.0` and
`apache/polaris-admin-tool:1.9.0` images contain the JVM runtime. A separate
Java installation is not required on the Azure VM.

## Container and Operating Environment

| Component | Version / implementation | Purpose |
|---|---|---|
| Docker Engine | Docker version selected by the Azure VM | Container runtime |
| Docker Compose | Compose v2.17+ | Service deployment and configuration (`up --wait`) |
| Linux | Ubuntu 26.04 LTS recommended | Azure VM operating system |
| Azure Linux VM | amd64 or arm64 | Host for the container deployment |

The containers are isolated from the host Java and Python environments.

## Database and Persistence

| Component | Version / implementation | Purpose |
|---|---|---|
| PostgreSQL | `postgres:17-alpine` | Durable Polaris metastore |
| PostgreSQL JDBC driver | 42.7.14 in Polaris 1.9.0 | JDBC connection from Polaris to PostgreSQL |
| Polaris relational JDBC persistence | Latest official Polaris implementation | Stores catalogs, namespaces, tables, principals, roles, grants, and policies |
| PostgreSQL Alpine image | Rolling PostgreSQL 17 patch release | Small production-capable database container |

PostgreSQL database: `POLARIS`

PostgreSQL application role: `M73581`

Polaris realm: `ISBUS`

Polaris bootstrap administrator: `M73580`

The database stores Polaris metadata, not Iceberg table data files.

## REST and Protocol Framework

| Component | Purpose |
|---|---|
| Apache Iceberg REST catalog API | Catalog discovery and table/namespace operations |
| Polaris Management REST API | Catalog, principal, role, and privilege administration |
| OAuth 2.0 client credentials | Polaris and external catalog authentication |
| HTTPS/TLS at an approved ingress gateway | Secure client-to-service communication; Compose's Polaris listener itself is plaintext HTTP |
| JDBC | Polaris-to-Postgres communication |

Polaris HTTP listeners:

- Port `8181`: management and Iceberg REST APIs
- Port `8182`: localhost management/health listener
- Port `5432`: PostgreSQL container listener, not published outside Docker Compose

## Azure Integrations

| Component | Implementation | Purpose |
|---|---|---|
| Azure Storage SDK | Azure SDK BOM 1.3.8 | Azure cloud integration |
| Azure Data Lake Storage Gen2 | `abfss://` | External Tableflow storage location |
| Service principal | `AZURE_TENANT_ID`, `AZURE_CLIENT_ID` (`appId`), and `AZURE_CLIENT_SECRET` | Authenticate Polaris to request user-delegation keys and mint SAS credentials |
| Azure Role: Storage Blob Data Contributor | Azure RBAC | Required for Polaris user-delegation SAS credential vending |

Azure credentials are optional for Polaris startup but are required for ADLS
credential vending. Polaris returns the resulting short-lived credentials to
authorized query engines; the query engines access ADLS directly. The VM and
Polaris do not proxy or transfer table data on behalf of those engines.
The service principal can be reused by multiple Polaris installations when
they access the same permitted storage scope. Each installation needs all
three credential values; the App ID alone is not sufficient.

## External Catalog Federation

| Component | Purpose |
|---|---|
| External catalog type | Federates to a remote Iceberg REST catalog |
| Confluent Tableflow | Remote Iceberg REST catalog used in this deployment |
| OAuth | Authentication from Polaris to Tableflow |
| Credential vending | Mints short-lived ADLS SAS credentials for query engines |

Federation is live and read-only for Tableflow tables. Polaris does not copy
Tableflow metadata or table data into its catalog database, and it does not
proxy table-data access. Clients send catalog operations to Polaris, receive
vended credentials as applicable, and connect directly to ADLS for data files.

## Optional Network Components

| Component | Requirement |
|---|---|
| Azure NSG | Restricts direct inbound client access and permits outbound HTTPS |
| Azure NAT Gateway or Azure Firewall | Optional outbound Internet access |
| Public DNS | Required for public HTTPS hostnames |
| Private DNS | Recommended for private hostnames |

Clients connect over HTTPS through an approved TLS-terminating gateway;
the gateway connects to Polaris on HTTP port 8181. Restrict that backend port
to the gateway. Polaris connects directly to Tableflow and Azure endpoints,
with network policy enforced by NSGs and any selected Azure outbound firewall
or NAT service.

## Administration and Automation

| Component | Purpose |
|---|---|
| Polaris CLI (`apache-polaris`) | Catalog, namespace, role, principal, and privilege management |
| Polaris Admin Tool | Realm bootstrap, realm purge, and metastore/NoSQL maintenance |
| Bash | Repository setup and verification scripts |
| curl | REST API calls and health checks |
| jq | JSON parsing in setup and verification scripts |

The Admin Tool does not expose a web or TCP listening port.

## Optional Query Engine Clients

The Polaris server supports Iceberg REST-compatible query engines, including:

- Apache Spark
- Apache Flink
- Apache Trino
- Dremio
- StarRocks
- Apache Doris

These tools are clients of Polaris port `8181`; they do not run inside the
Polaris containers.

## Licensing and Runtime Notes

- Polaris: Apache License
- Java runtime: OpenJDK, including the Red Hat UBI OpenJDK runtime
- PostgreSQL: PostgreSQL open-source license
- Docker: container engine subject to the organization's Docker/OCI policy
- Azure SDK and Confluent Tableflow: governed by their respective licenses
  and service terms

Version information should be revalidated before upgrades. Polaris and
PostgreSQL schema compatibility, Docker image digests, and Polaris release
notes should be checked together.
