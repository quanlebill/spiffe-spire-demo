#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/.."

echo ">> installing istio on geic-a"
istioctl install -y --context kind-geic-a -f k8s/cluster-a/06-istio.yaml --set values.global.imagePullPolicy=IfNotPresent

echo ">> installing istio on geic-b"
istioctl install -y --context kind-geic-b -f k8s/cluster-b/06-istio.yaml --set values.global.imagePullPolicy=IfNotPresent

kubectl --context kind-geic-a -n istio-system rollout status deployment/istiod --timeout=420s
kubectl --context kind-geic-b -n istio-system rollout status deployment/istiod --timeout=420s

kubectl --context kind-geic-a -n istio-system get pods
kubectl --context kind-geic-b -n istio-system get pods
