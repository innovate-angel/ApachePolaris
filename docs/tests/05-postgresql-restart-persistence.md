# Test 05: PostgreSQL restart persistence

**Automation:** Manual container integration

**Objective:** Verify restart preserves Polaris metadata.

**Procedure:** Create a catalog, restart `postgres`, and list catalogs through Polaris.

**Pass criteria:** The catalog, realm, principals, roles, and grants remain available.
