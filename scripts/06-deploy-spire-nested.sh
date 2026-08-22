#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/.."

mkdir -p .generated

echo ">> exporting the root spire trust bundle"
kubectl --context kind-geic-root -n spire-root exec spire-root-server-0 -- /opt/spire/bin/spire-server bundle show > .generated/root-bundle.crt
head -1 .generated/root-bundle.crt | grep -q 'BEGIN CERTIFICATE' || { echo "ERROR: the root bundle did not come back as a PEM certificate" >&2; exit 1; }

ROOT_NODE_ENDPOINTS=""
for node in $(kubectl --context kind-geic-root get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  NODE_IP=$(kubectl --context kind-geic-root get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  echo "   root server reachable at $NODE_IP:30081"
  ROOT_NODE_ENDPOINTS="$ROOT_NODE_ENDPOINTS  - addresses:
      - $NODE_IP
    conditions:
      ready: true
"
done

cat > .generated/root-server-endpointslice.yaml <<SLICE
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: spire-root-server-remote
  namespace: spire-system
  labels:
    kubernetes.io/service-name: spire-root-server
addressType: IPv4
ports:
  - name: grpc
    port: 30081
    protocol: TCP
endpoints:
$ROOT_NODE_ENDPOINTS
SLICE

echo ">> seeding the root bundle and root endpoint into geic-a"
kubectl --context kind-geic-a -n spire-system create configmap spire-root-bundle \
  --from-file=bundle.crt=.generated/root-bundle.crt --dry-run=client -o yaml | kubectl --context kind-geic-a apply -f -
kubectl --context kind-geic-a apply -f .generated/root-server-endpointslice.yaml

echo ">> seeding the root bundle and root endpoint into geic-b"
kubectl --context kind-geic-b -n spire-system create configmap spire-root-bundle \
  --from-file=bundle.crt=.generated/root-bundle.crt --dry-run=client -o yaml | kubectl --context kind-geic-b apply -f -
kubectl --context kind-geic-b apply -f .generated/root-server-endpointslice.yaml

echo ">> deploying postgresql, one datastore per cluster and never shared across clusters"
kubectl --context kind-geic-a -n spire-system get secret spire-db >/dev/null 2>&1 || \
  kubectl --context kind-geic-a -n spire-system create secret generic spire-db \
    --from-literal=password="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"
kubectl --context kind-geic-b -n spire-system get secret spire-db >/dev/null 2>&1 || \
  kubectl --context kind-geic-b -n spire-system create secret generic spire-db \
    --from-literal=password="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"

kubectl --context kind-geic-a apply -f k8s/cluster-a/01-spire-datastore.yaml
kubectl --context kind-geic-b apply -f k8s/cluster-b/01-spire-datastore.yaml
kubectl --context kind-geic-a -n spire-system rollout status statefulset/spire-db --timeout=420s
kubectl --context kind-geic-b -n spire-system rollout status statefulset/spire-db --timeout=420s

echo ">> deploying the nested spire servers"
kubectl --context kind-geic-a apply -f k8s/cluster-a/03-spire-nested-server.yaml
kubectl --context kind-geic-b apply -f k8s/cluster-b/03-spire-nested-server.yaml
kubectl --context kind-geic-a -n spire-system rollout status statefulset/spire-nested-server --timeout=600s
kubectl --context kind-geic-b -n spire-system rollout status statefulset/spire-nested-server --timeout=600s

echo ">> waiting for each nested server to publish its trust bundle to the spire-bundle configmap"
for attempt in $(seq 1 60); do
  if kubectl --context kind-geic-a -n spire-system get configmap spire-bundle -o jsonpath='{.data.bundle\.crt}' 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then break; fi
  sleep 5
done
for attempt in $(seq 1 60); do
  if kubectl --context kind-geic-b -n spire-system get configmap spire-bundle -o jsonpath='{.data.bundle\.crt}' 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then break; fi
  sleep 5
done

echo ">> deploying the node agents and the spiffe csi driver"
kubectl --context kind-geic-a apply -f k8s/cluster-a/04-spire-agent.yaml
kubectl --context kind-geic-a apply -f k8s/cluster-a/05-spiffe-csi-driver.yaml
kubectl --context kind-geic-b apply -f k8s/cluster-b/04-spire-agent.yaml
kubectl --context kind-geic-b apply -f k8s/cluster-b/05-spiffe-csi-driver.yaml
kubectl --context kind-geic-a -n spire-system rollout status daemonset/spire-agent --timeout=420s
kubectl --context kind-geic-a -n spire-system rollout status daemonset/spiffe-csi-driver --timeout=420s
kubectl --context kind-geic-b -n spire-system rollout status daemonset/spire-agent --timeout=420s
kubectl --context kind-geic-b -n spire-system rollout status daemonset/spiffe-csi-driver --timeout=420s

echo ">> nesting check, these two ids must match"
kubectl --context kind-geic-root -n spire-root logs spire-root-server-0 | grep -oE 'local_authority_id=[a-f0-9]{16,}' | tail -1
kubectl --context kind-geic-a -n spire-system logs spire-nested-server-0 -c spire-server | grep -oE 'upstream_authority_id=[a-f0-9]{16,}' | tail -1
