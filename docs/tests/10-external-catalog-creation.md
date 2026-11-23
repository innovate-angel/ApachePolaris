# Test 10: External catalog creation

**Automation:** `scripts/setup-tableflow-federation.sh`, `tests/e2e/test_tableflow_federation.py`

**Objective:** Verify creation of an external Iceberg REST catalog.

**Procedure:** Run the setup script and inspect the `tableflow` catalog.

**Pass criteria:** The catalog is type `EXTERNAL`, points to Tableflow HTTPS, and is rerunnable.
