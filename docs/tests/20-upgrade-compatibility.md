# Test 20: Upgrade compatibility

**Objective:** Verify Polaris and Admin Tool upgrades preserve the metastore.

**Procedure:** Back up PostgreSQL, match Polaris/Admin versions, apply operator-driven schema upgrades, and restart.

**Pass criteria:** Version, entities, credentials, and grants survive; no automated migration surprises occur.
