# Test 08: OAuth authentication

**Automation:** `tests/integration/test_polaris_runtime.py`

**Objective:** Verify client-credential authentication in the `ISBUS` realm.

**Procedure:** Send `M73580` credentials to `/api/catalog/v1/oauth/tokens` with `Polaris-Realm: ISBUS`.

**Pass criteria:** HTTP 200 and a non-empty access token.
