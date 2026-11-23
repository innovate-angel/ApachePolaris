# Test 16: Credential vending

**Automation:** `scripts/verify.sh`

**Objective:** Verify Polaris vends ADLS credentials for a Tableflow table.

**Procedure:** Call `loadTable` with `X-Iceberg-Access-Delegation: vended-credentials`.

**Pass criteria:** The response contains `metadataLocation` and ADLS SAS configuration keys.
