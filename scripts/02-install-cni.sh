#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/.."

mkdir -p .generated k8s/cni

echo ">> fetching the calico v3.30.4 manifest"
[ -f .generated/calico-v3.30.4.yaml ] || curl -sSL -o .generated/calico-v3.30.4.yaml \
  https://raw.githubusercontent.com/projectcalico/calico/v3.30.4/manifests/calico.yaml

echo ">> rendering one calico manifest per cluster pod CIDR"
sed -e 's|^\(  *\)# - name: CALICO_IPV4POOL_CIDR|\1- name: CALICO_IPV4POOL_CIDR|' \
    -e 's|^\(  *\)#   value: "192.168.0.0/16"|\1  value: "10.30.0.0/16"|' \
    .generated/calico-v3.30.4.yaml > k8s/cni/calico-geic-root.yaml
sed -e 's|^\(  *\)# - name: CALICO_IPV4POOL_CIDR|\1- name: CALICO_IPV4POOL_CIDR|' \
    -e 's|^\(  *\)#   value: "192.168.0.0/16"|\1  value: "10.10.0.0/16"|' \
    .generated/calico-v3.30.4.yaml > k8s/cni/calico-geic-a.yaml
sed -e 's|^\(  *\)# - name: CALICO_IPV4POOL_CIDR|\1- name: CALICO_IPV4POOL_CIDR|' \
    -e 's|^\(  *\)#   value: "192.168.0.0/16"|\1  value: "10.20.0.0/16"|' \
    .generated/calico-v3.30.4.yaml > k8s/cni/calico-geic-b.yaml

echo ">> installing calico on geic-root"
kubectl --context kind-geic-root apply -f k8s/cni/calico-geic-root.yaml
kubectl --context kind-geic-root -n kube-system set env daemonset/calico-node IP_AUTODETECTION_METHOD=kubernetes-internal-ip
kubectl --context kind-geic-root -n kube-system rollout status daemonset/calico-node --timeout=420s

echo ">> installing calico on geic-a"
kubectl --context kind-geic-a apply -f k8s/cni/calico-geic-a.yaml
kubectl --context kind-geic-a -n kube-system set env daemonset/calico-node IP_AUTODETECTION_METHOD=kubernetes-internal-ip
kubectl --context kind-geic-a -n kube-system rollout status daemonset/calico-node --timeout=420s

echo ">> installing calico on geic-b"
kubectl --context kind-geic-b apply -f k8s/cni/calico-geic-b.yaml
kubectl --context kind-geic-b -n kube-system set env daemonset/calico-node IP_AUTODETECTION_METHOD=kubernetes-internal-ip
kubectl --context kind-geic-b -n kube-system rollout status daemonset/calico-node --timeout=420s

echo ">> disabling IPIP encapsulation"
kubectl --context kind-geic-root patch ippool default-ipv4-ippool --type merge -p '{"spec":{"ipipMode":"Never"}}'
kubectl --context kind-geic-a    patch ippool default-ipv4-ippool --type merge -p '{"spec":{"ipipMode":"Never"}}'
kubectl --context kind-geic-b    patch ippool default-ipv4-ippool --type merge -p '{"spec":{"ipipMode":"Never"}}'

echo ">> waiting for coredns"
kubectl --context kind-geic-root -n kube-system rollout status deployment/coredns --timeout=300s
kubectl --context kind-geic-a    -n kube-system rollout status deployment/coredns --timeout=300s
kubectl --context kind-geic-b    -n kube-system rollout status deployment/coredns --timeout=300s
