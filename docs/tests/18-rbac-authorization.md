# Test 18: RBAC authorization

**Objective:** Verify catalog and namespace authorization is enforced.

**Procedure:** Create a read-only principal and test allowed reads plus denied writes/deletes.

**Pass criteria:** Authorized operations succeed; unauthorized operations return `403`.
