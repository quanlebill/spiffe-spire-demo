#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/.."

echo ">> creating kind clusters"
kind get clusters 2>/dev/null | grep -qx geic-root || kind create cluster --config k8s/clusters/geic-root.yaml
kind get clusters 2>/dev/null | grep -qx geic-a    || kind create cluster --config k8s/clusters/geic-a.yaml
kind get clusters 2>/dev/null | grep -qx geic-b    || kind create cluster --config k8s/clusters/geic-b.yaml

kind export kubeconfig --name geic-root
kind export kubeconfig --name geic-a
kind export kubeconfig --name geic-b

echo ">> untainting control-planes on geic-root and geic-b"
kubectl --context kind-geic-root taint node geic-root-control-plane node-role.kubernetes.io/control-plane- 2>/dev/null || true
kubectl --context kind-geic-b    taint node geic-b-control-plane    node-role.kubernetes.io/control-plane- 2>/dev/null || true

echo ">> rewriting NetworkPolicy ipBlocks to match this machine's kind docker network"
KIND_NETWORK_CIDR=$(docker network inspect kind --format '{{range .IPAM.Config}}{{if not (eq .Subnet "")}}{{.Subnet}} {{end}}{{end}}' | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1)
echo "   kind network = $KIND_NETWORK_CIDR"
sed -i "s|cidr: [0-9.]*/16|cidr: $KIND_NETWORK_CIDR|g" \
  k8s/cluster-root/02-spire-root-server.yaml \
  k8s/cluster-a/07-workloads.yaml \
  k8s/cluster-b/07-workloads.yaml

kubectl --context kind-geic-root get nodes
kubectl --context kind-geic-a get nodes
kubectl --context kind-geic-b get nodes
