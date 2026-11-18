-- Polaris does not issue CREATE SCHEMA itself (privileged op); the relational-jdbc
-- backend defaults to schema POLARIS_SCHEMA via the JDBC currentSchema property.
-- Runs once at container init (docker-entrypoint-initdb.d).
CREATE SCHEMA IF NOT EXISTS POLARIS_SCHEMA;
