# Test 11: Catalog role and grants

**Automation:** `scripts/setup-tableflow-federation.sh`

**Objective:** Verify the catalog role and principal-role assignment exist.

**Procedure:** Create `tableflow_reader`, grant `CATALOG_MANAGE_CONTENT`, and assign it to `service_admin`.

**Pass criteria:** Catalog role, grant, and principal-role assignment all exist.
