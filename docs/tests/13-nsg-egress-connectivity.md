# Test 13: NSG egress connectivity

**Automation:** `scripts/check-tableflow.sh`

**Objective:** Verify direct outbound HTTPS connectivity from the VM to
Tableflow through the configured NSG and any Azure NAT/firewall rules.

**Procedure:** Set `TABLEFLOW_PROXY_BASE_URL` to
`https://tableflow.eastus2.azure.confluent.cloud` and run the connectivity
check.

**Pass criteria:** OAuth, config, and namespace calls succeed directly with no
application proxy in the request path.
