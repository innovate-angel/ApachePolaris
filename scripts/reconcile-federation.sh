#!/usr/bin/env bash
# Restores the federated catalog's Tableflow connection after a Polaris restart.
# Polaris 1.9.0 keeps that secret in memory only; setup-tableflow-federation.sh
# leaves a working catalog untouched and recreates a broken one. Run it
# periodically (deploy/systemd/polaris-federation-reconcile.timer).
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=scripts/load-key-vault-env.sh
source scripts/load-key-vault-env.sh

# Port 8181 is published only on POLARIS_BIND_ADDRESS, which may not be localhost.
export POLARIS_URL="${POLARIS_URL:-http://${POLARIS_BIND_ADDRESS}:8181}"

# Wait for Polaris to report healthy; a stopped stack is not this job's concern.
for _ in $(seq 1 30); do
  status="$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q polaris)" 2>/dev/null || true)"
  [[ "$status" == "healthy" ]] && break
  sleep 10
done
[[ "${status:-}" == "healthy" ]] || { echo "ERROR: Polaris is not healthy; not reconciling" >&2; exit 1; }

exec ./scripts/setup-tableflow-federation.sh
