# Test 09: Wrong realm rejection

**Objective:** Verify requests cannot access `ISBUS` resources from an unconfigured realm.

**Procedure:** Request an OAuth token or catalog API with an invalid or mismatched realm header.

**Pass criteria:** Polaris rejects the request with an appropriate `404` or authentication/authorization response.
