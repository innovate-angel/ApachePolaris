# Test 19: Backup and restore

**Objective:** Verify PostgreSQL metadata can be backed up and restored.

**Procedure:** Run `pg_dump`, recreate or replace the database, restore with `psql`, and verify the realm/catalog.

**Pass criteria:** Restored metadata and credentials are functional.
