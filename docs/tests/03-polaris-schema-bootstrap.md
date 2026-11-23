# Test 03: Polaris schema bootstrap

**Automation:** `scripts/bootstrap.sh`

**Objective:** Verify Admin Tool creates the Polaris metastore tables and initial realm.

**Procedure:** Run the bootstrap container against the fresh PostgreSQL database.

**Pass criteria:** Bootstrap succeeds and the Polaris version/entity tables are present in `polaris_schema`.
