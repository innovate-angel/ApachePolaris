# Test 04: Bootstrap idempotency

**Automation:** `scripts/bootstrap.sh`

**Objective:** Confirm bootstrap can be rerun without resetting realm credentials.

**Procedure:** Run `scripts/bootstrap.sh` twice with the same realm,
`M73580` client ID, and secret.

**Pass criteria:** The second run reports an existing/bootstrapped realm and exits successfully.
