# Apache Polaris Deployment Software and Framework Inventory

This document describes the software and frameworks used by the Apache Polaris
1.8.0 deployment in this repository.

## Core Application

| Component | Version / implementation | Purpose |
|---|---|---|
| Apache Polaris | 1.8.0 | Iceberg REST catalog, management API, authorization, credential vending, and external catalog federation |
| Java | OpenJDK 21 | Runtime for the Polaris server and Admin Tool |
| JVM base image | Red Hat UBI 9 OpenJDK 21 runtime | Container runtime for Polaris Java applications |
| Quarkus | 3.39.3 | Java application framework and runtime |
| Apache Iceberg | 1.11.0 | Iceberg catalog APIs and table metadata implementation |

The official `apache/polaris:1.8.0` and
`apache/polaris-admin-tool:1.8.0` images contain the JVM runtime. A separate
Java installation is not required on the Azure VM.

## Container and Operating Environment

| Component | Version / implementation | Purpose |
|---|---|---|
| Docker Engine | Docker version selected by the Azure VM | Container runtime |
| Docker Compose | Compose v2 | Service deployment and configuration |
| Linux | Ubuntu 22.04 or 24.04 LTS recommended | Azure VM operating system |
| Azure Linux VM | amd64 or arm64 | Host for the container deployment |

The containers are isolated from the host Java and Python environments.

## Database and Persistence

| Component | Version / implementation | Purpose |
|---|---|---|
| PostgreSQL | `postgres:17-alpine` | Durable Polaris metastore |
| PostgreSQL JDBC driver | 42.7.13 | JDBC connection from Polaris to PostgreSQL |
| Polaris relational JDBC persistence | 1.8.0 implementation | Stores catalogs, namespaces, tables, principals, roles, grants, and policies |
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
| HTTPS/TLS | Secure REST communication |
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
| Azure managed identity or service principal | DefaultAzureCredential or configured credentials | Authenticate Polaris to Azure Storage |
| Azure Role: Storage Blob Data Contributor | Azure RBAC | Required for Polaris user-delegation SAS credential vending |

Azure credentials are optional for Polaris startup but are required for ADLS
credential vending and associated storage operations.

## External Catalog Federation

| Component | Purpose |
|---|---|
| External catalog type | Federates to a remote Iceberg REST catalog |
| Confluent Tableflow | Remote Iceberg REST catalog used in this deployment |
| OAuth | Authentication from Polaris to Tableflow |
| Credential vending | Mints short-lived ADLS SAS credentials for query engines |

Federation is live and read-only for Tableflow tables. Polaris does not copy
Tableflow metadata or table data into its catalog database.

## Optional Network Components

| Component | Requirement |
|---|---|
| Nginx | Optional public TLS/reverse proxy and optional Tableflow egress proxy |
| Azure Application Gateway, Front Door, or Load Balancer | Optional alternative ingress |
| Azure NAT Gateway or Azure Firewall | Optional outbound Internet access |
| Public DNS | Required for public HTTPS hostnames |
| Private DNS | Recommended for private hostnames |

Nginx is not required by Polaris. It is only required if the deployment
needs its routing, TLS termination, or proxy policy.

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
