# Test 02: Fresh PostgreSQL deployment

**Automation:** Manual or container integration runner

**Objective:** Verify an empty PostgreSQL data directory initializes with the database, role, and schema.

**Procedure:** Start from a newly created volume, start Postgres, and query `\l`, `\du`, and `\dn`.

**Pass criteria:** `POLARIS` exists, `M73581` exists, and `polaris_schema` is created.
