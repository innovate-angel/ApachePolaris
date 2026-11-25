# Test 06: Polaris restart

**Automation:** `make test-restart` (`tests/restart/test_federation_restart.py`)
for the mechanism, against an isolated copy of the stack with a stand-in remote
catalog. Manual on the deployed VM against Tableflow.

**Objective:** Verify the federated catalog works again after a Polaris restart
and keeps its catalog roles, grants, and role assignments.

Polaris 1.9.0 holds the catalog's Tableflow client secret in memory only, so
after a restart the catalog is still listed but requests through it return
HTTP `500` until `scripts/setup-tableflow-federation.sh` recreates it.
"Catalogs remain visible" is therefore not a pass criterion.

**Procedure:** Restart `polaris` and wait for the health endpoint. Rerun
`./scripts/deploy-from-key-vault.sh`. Compare the catalog roles, their grants,
and their principal-role assignments with the state before the restart, and
list namespaces as a read-only principal.

**Pass criteria:** Health is `UP` and OAuth succeeds. The deployment reports
`Recreating catalog 'tableflow'` and exits `0` with `All checks passed.` (a
table loaded through the federated catalog with SAS credentials). Catalog
roles, grants, and assignments are unchanged, and the read-only principal can
list namespaces with its existing credentials.
