# Test 16: Credential vending

**Automation:** `scripts/verify.sh`; its pass/fail behaviour is covered by `tests/unit/test_verify_script.py`

**Objective:** Verify Polaris vends ADLS credentials for a Tableflow table.

**Procedure:** Call `loadTable` with `X-Iceberg-Access-Delegation: vended-credentials`.

**Pass criteria:** `scripts/verify.sh` exits `0` with `All checks passed.`: the
response contains a `metadataLocation` in the expected ADLS account and
container and at least one ADLS SAS configuration key. Exit `3`
(`INCONCLUSIVE`, no table to load) and exit `1` (no SAS keys) are not passes.
