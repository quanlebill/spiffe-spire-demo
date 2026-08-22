#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/01-create-clusters.sh
bash scripts/02-install-cni.sh
bash scripts/03-build-and-load-images.sh
bash scripts/04-deploy-openbao.sh
bash scripts/05-deploy-spire-root.sh
bash scripts/06-deploy-spire-nested.sh
bash scripts/07-install-istio.sh
bash scripts/08-deploy-workloads.sh

echo
echo ">> deployment complete, now verify it with doc/testing.md"
