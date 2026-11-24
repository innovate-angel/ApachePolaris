# Test 03: Polaris schema bootstrap

**Automation:** `scripts/bootstrap.sh`

**Objective:** Verify Admin Tool creates the Polaris metastore tables and initial realm.

**Procedure:** Create `POLARIS_SCHEMA`, run the bootstrap container against the
fresh PostgreSQL database, and verify that `currentSchema=POLARIS_SCHEMA` is
configured in both Polaris and Admin Tool datasources.

Set explicit bootstrap credentials: the Admin Tool requires every realm supplied
with `--realm` to have a matching `--credential` realm/client-ID/secret tuple.

**Pass criteria:** Bootstrap succeeds and the single versioned PostgreSQL
`schema.sql` tables and initial version row are present in `polaris_schema`.
