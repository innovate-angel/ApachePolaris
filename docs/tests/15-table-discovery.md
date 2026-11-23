# Test 15: Table discovery

**Automation:** `scripts/verify.sh`

**Objective:** Verify tables in the first federated namespace are visible.

**Procedure:** Call the namespace tables endpoint after namespace discovery.

**Pass criteria:** Valid Iceberg identifiers are returned or an explicit no-table status is reported.
