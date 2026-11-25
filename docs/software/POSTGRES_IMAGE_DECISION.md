# PostgreSQL Container Image Decision

**Author:** Angel Vega  
**Date:** 2026-11-24

## Decision

This deployment uses:

```yaml
image: postgres:17-alpine
```

The PostgreSQL container provides the durable metastore for the pinned Apache
Polaris 1.9.0 release. The image is a rolling PostgreSQL 17 tag based on Alpine Linux.

## Rationale

### Polaris compatibility

Apache Polaris supports PostgreSQL through the relational-JDBC persistence
implementation. PostgreSQL stores Polaris metadata, realms, principals, roles,
grants, catalog entities, and policies.

### PostgreSQL major version

PostgreSQL 17 is the selected major version because the deployment requires a
currently supported PostgreSQL runtime while remaining compatible with the
official Polaris JDBC implementation.

The major version should not be changed automatically or during a routine
container restart.

### Rolling patch tag

`postgres:17-alpine` is preferred over `postgres:17.6-alpine` because it follows
current PostgreSQL 17 patch releases.

Docker pull verification currently resolves the tag to PostgreSQL 17.12, subject
to future patch updates. The exact patch must be verified before and after image
updates.

For stricter reproducibility, an exact patch tag such as
`postgres:17.12-alpine` can replace the rolling tag after operator approval.

### Alpine Linux

The Alpine image is generally smaller and has a smaller base package surface
than standard Debian-based PostgreSQL images. It provides the official
PostgreSQL entrypoint, initialization scripts, health tools, and data-directory
management.

Alpine is an implementation choice, not a Polaris requirement.

### Containerized deployment

Docker Compose manages the database lifecycle, persistent named volume,
initialization script, environment variables, health check, and network access.

PostgreSQL is not published to the host. Polaris and the Admin Tool connect
over the Compose network using:

```text
postgres:5432/POLARIS
```

## Persistence

The PostgreSQL data directory is mounted at:

```text
/var/lib/postgresql/data
```

Initialization scripts under `postgres/initdb/` run only when the data directory
is first initialized. Restarting the container does not rerun the initialization
scripts or reset Polaris metadata.

Removing the Docker named volume with `docker compose down -v` deletes all
Polaris metadata.

## Production considerations

A containerized PostgreSQL image is suitable for a controlled deployment, but
Azure managed PostgreSQL should be considered for stronger production operations.

Compare the container with Azure Database for PostgreSQL Flexible Server:

| Need | PostgreSQL container | Azure managed PostgreSQL |
|---|---|---|
| Automated patching | Operator-managed | Azure-managed options |
| Automated backups | Operator/configuration required | Built-in backup options |
| High availability | Operator-designed | Managed HA options |
| Private networking | Requires VNet/Docker planning | Native Azure private endpoints/VNet |
| Monitoring | Operator-designed | Azure Monitor integration |
| OS/container maintenance | VM and Docker operations | Reduced platform maintenance |
| Portability | High | Azure-specific |

For a multi-replica or high-availability Polaris deployment, a managed PostgreSQL
service should be evaluated to reduce database operational risk.

## JDBC pool interaction

The PostgreSQL container is separate from Polaris query-engine clients.

The Polaris server and Admin Tool use a JDBC pool, currently configured with:

```yaml
QUARKUS_DATASOURCE_DB_KIND: postgresql
QUARKUS_DATASOURCE_JDBC_MIN_SIZE: "2"
QUARKUS_DATASOURCE_JDBC_MAX_SIZE: "20"
```

These values control only Polaris-to-PostgreSQL connections. They do not limit:

- Query-engine connections to Polaris
- Iceberg REST requests
- External catalog federation sessions
- Polaris catalog, namespace, or table counts

For multiple Polaris replicas, each replica has its own JDBC pool. PostgreSQL
`max_connections` must be sized for all replicas, bootstrap operations,
administrative tools, and database maintenance.

## Upgrade process

Before changing PostgreSQL:

1. Create a complete logical backup with `pg_dump`.
2. Stop write activity or take an application-consistent backup.
3. Record the current PostgreSQL and Polaris versions.
4. Test the target image in a non-production environment.
5. Review Polaris relational-JDBC release notes and schema migration requirements.
6. Upgrade PostgreSQL using a supported major-version procedure.
7. Update the pinned image and rebuild/replace the container.
8. Run the health, OAuth, catalog, namespace, and credential-vending tests.

Do not use an existing data directory across unsupported PostgreSQL major
versions.

## Alternatives

- Exact PostgreSQL patch pin: `postgres:17.12-alpine`
- PostgreSQL Debian image: for environments requiring glibc/toolchain behavior
- Azure Database for PostgreSQL Flexible Server: recommended for managed
  production operations

The final choice should be approved with backup, recovery, security, support,
and Azure platform requirements.
