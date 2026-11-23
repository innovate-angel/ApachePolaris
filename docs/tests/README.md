# Apache Polaris Test Plan

**Author:** Angel Vega  
**Date:** 2026-11-23

This directory defines one document per deployment test case.

## Test levels

| Level | Command | Purpose |
|---|---|---|
| Unit/static | `make test-unit` | Repository structure, configuration syntax, required files |
| Integration | `make test-integration` | Live Docker, health, OAuth, and authentication checks |
| E2E | `make test-e2e` | Tableflow federation and credential vending |

External Tableflow/Azure credentials are required for E2E tests. Run them
only in an environment with the `.env` values populated.

## Cases

1. [Compose configuration](01-compose-configuration.md)
2. [Fresh PostgreSQL deployment](02-fresh-postgresql-deployment.md)
3. [Polaris schema bootstrap](03-polaris-schema-bootstrap.md)
4. [Bootstrap idempotency](04-bootstrap-idempotency.md)
5. [PostgreSQL restart persistence](05-postgresql-restart-persistence.md)
6. [Polaris restart](06-polaris-restart.md)
7. [Health endpoint](07-health-endpoint.md)
8. [OAuth authentication](08-oauth-authentication.md)
9. [Wrong realm rejection](09-wrong-realm-rejection.md)
10. [External catalog creation](10-external-catalog-creation.md)
11. [Catalog role and grants](11-catalog-role-and-grants.md)
12. [Direct Tableflow connectivity](12-direct-tableflow-connectivity.md)
13. [Nginx connectivity](13-nginx-connectivity.md)
14. [Namespace discovery](14-namespace-discovery.md)
15. [Table discovery](15-table-discovery.md)
16. [Credential vending](16-credential-vending.md)
17. [Allowed-location validation](17-allowed-location-validation.md)
18. [RBAC authorization](18-rbac-authorization.md)
19. [Backup and restore](19-backup-and-restore.md)
20. [Upgrade compatibility](20-upgrade-compatibility.md)
21. [TLS and private CA](21-tls-private-ca.md)
