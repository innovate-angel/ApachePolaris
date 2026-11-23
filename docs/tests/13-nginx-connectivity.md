# Test 13: Nginx connectivity

**Automation:** `scripts/check-tableflow.sh`

**Objective:** Verify optional nginx egress routing to Tableflow.

**Procedure:** Set `TABLEFLOW_PROXY_BASE_URL` to nginx and validate proxy SSL, host/SNI, and authorization forwarding.

**Pass criteria:** OAuth, config, and namespace calls succeed with no URL rewrite that bypasses nginx.
