# Test 12: Direct Tableflow connectivity

**Automation:** `scripts/check-tableflow.sh`

**Objective:** Verify Polaris can reach Tableflow directly by HTTPS.

**Procedure:** Set `TABLEFLOW_PROXY_BASE_URL` to the direct Tableflow URL and run the connectivity check.

**Pass criteria:** OAuth, `/v1/config`, and `/v1/namespaces` succeed.
