# Test 01: Compose configuration

**Automation:** `make compose-validate`, `tests/unit/test_repository_structure.py`

**Objective:** Confirm Docker Compose and repository configuration are valid.

**Procedure:** Run `docker compose config -q` and verify required services, ports, environment variables, and JDBC pool settings.

**Pass criteria:** Compose exits successfully; `postgres`, `polaris-bootstrap`, and `polaris` exist; required secrets are supplied.
