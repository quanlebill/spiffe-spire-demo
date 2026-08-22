#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

kind delete cluster --name geic-root || true
kind delete cluster --name geic-a || true
kind delete cluster --name geic-b || true

rm -rf .generated k8s/cni
