# Test 07: Health endpoint

**Automation:** `tests/integration/test_polaris_runtime.py`

**Objective:** Verify Polaris reports health on port 8182.

**Procedure:** Request `http://127.0.0.1:8182/q/health`.

**Pass criteria:** HTTP 200 and a JSON status of `UP`.
