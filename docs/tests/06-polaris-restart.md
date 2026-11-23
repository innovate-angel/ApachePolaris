# Test 06: Polaris restart

**Automation:** Manual container integration

**Objective:** Verify the Polaris server reconnects after restart.

**Procedure:** Restart `polaris`; wait for the health endpoint; obtain a token; list catalogs.

**Pass criteria:** Health is `UP`, OAuth succeeds, and persisted catalogs remain visible.
