# Test 17: Allowed-location validation

**Objective:** Verify tables outside catalog allowed storage locations are rejected.

**Procedure:** Load or create a table location outside the configured `abfss://` allowed location.

**Pass criteria:** Polaris rejects the location with a location validation error.
