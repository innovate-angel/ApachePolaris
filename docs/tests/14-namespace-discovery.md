# Test 14: Namespace discovery

**Automation:** `scripts/verify.sh`

**Objective:** Verify federated namespaces are visible through Polaris.

**Procedure:** Authenticate and call `/api/catalog/v1/{catalog}/namespaces`.

**Pass criteria:** The response is a valid namespace list or an explicit not-yet-materialized result.
