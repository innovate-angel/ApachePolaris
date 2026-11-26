#!/usr/bin/env bash
# Creates or updates the PostgreSQL role Polaris connects as. The role is not a
# superuser; it owns the Polaris schema and everything in it.
#
# Run by the one-off polaris-db-role Compose service before every bootstrap
# (./scripts/bootstrap.sh, and so every deployment). It also applies password
# changes and migrates installations whose Polaris tables are still owned by the
# PostgreSQL superuser. Idempotent. Connects with the PG* environment variables.
set -euo pipefail
: "${POLARIS_DB_USER:?POLARIS_DB_USER is not set}" "${POLARIS_DB_PASSWORD:?POLARIS_DB_PASSWORD is not set}"
psql -v ON_ERROR_STOP=1 -q <<'SQL'
\set app_user `printf %s "$POLARIS_DB_USER"`
\set app_password `printf %s "$POLARIS_DB_PASSWORD"`

SELECT format('CREATE ROLE %I', :'app_user')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user')
\gexec
ALTER ROLE :"app_user" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD :'app_password';
SELECT format('GRANT CONNECT, CREATE ON DATABASE %I TO %I', current_database(), :'app_user')
\gexec

CREATE SCHEMA IF NOT EXISTS polaris_schema;
ALTER SCHEMA polaris_schema OWNER TO :"app_user";

-- Tables, views and standalone sequences (sequences owned by a column follow their table).
SELECT format('ALTER %s %I.%I OWNER TO %I',
              CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW'
                             WHEN 'S' THEN 'SEQUENCE' ELSE 'TABLE' END,
              n.nspname, c.relname, :'app_user')
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'polaris_schema'
  AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
  AND c.relowner <> (SELECT oid FROM pg_roles WHERE rolname = :'app_user')
  AND NOT (c.relkind = 'S' AND EXISTS (
    SELECT FROM pg_depend d WHERE d.objid = c.oid AND d.deptype IN ('a', 'i')))
\gexec
SELECT format('ALTER ROUTINE %s OWNER TO %I', p.oid::regprocedure, :'app_user')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'polaris_schema'
  AND p.proowner <> (SELECT oid FROM pg_roles WHERE rolname = :'app_user')
\gexec
SQL
echo "Database role $POLARIS_DB_USER is ready"
