# Test 20: Upgrade compatibility

**Objective:** Verify Polaris and Admin Tool upgrades preserve the metastore.

**Procedure:** Back up PostgreSQL, match Polaris/Admin versions, compare the
PostgreSQL `schema.sql` between release tags, apply operator-driven migrations
before starting the new Polaris binary, and restart. Verify
`currentSchema=POLARIS_SCHEMA` remains on the existing schema.

**Pass criteria:** Version, entities, credentials, and grants survive; the binary
recognizes the migrated schema version; re-bootstrap alone does not perform or
replace schema migrations.
