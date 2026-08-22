#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/.."

mkdir -p .generated

echo ">> registering the geic-a workload identities"
kubectl --context kind-geic-a -n spire-system exec spire-nested-server-0 -c spire-server -- /opt/spire/bin/spire-server entry create -node \
  -spiffeID spiffe://ndip/nodes/geic-a-workers \
  -parentID spiffe://ndip/spire/server \
  -selector k8s_psat:cluster:geic-a >/dev/null 2>&1 || echo "   node alias for geic-a already present"
kubectl --context kind-geic-a -n spire-system exec spire-nested-server-0 -c spire-server -- /opt/spire/bin/spire-server entry create \
  -parentID spiffe://ndip/nodes/geic-a-workers \
  -spiffeID spiffe://ndip/ns/workloads/sa/frontend-a \
  -selector k8s:ns:workloads -selector k8s:sa:frontend-a -selector k8s:container-name:istio-proxy >/dev/null 2>&1 || echo "   entry for frontend-a already present"
kubectl --context kind-geic-a -n spire-system exec spire-nested-server-0 -c spire-server -- /opt/spire/bin/spire-server entry create \
  -parentID spiffe://ndip/nodes/geic-a-workers \
  -spiffeID spiffe://ndip/ns/workloads/sa/backend-a \
  -selector k8s:ns:workloads -selector k8s:sa:backend-a -selector k8s:container-name:istio-proxy >/dev/null 2>&1 || echo "   entry for backend-a already present"
kubectl --context kind-geic-a -n spire-system exec spire-nested-server-0 -c spire-server -- /opt/spire/bin/spire-server entry create \
  -parentID spiffe://ndip/nodes/geic-a-workers \
  -spiffeID spiffe://ndip/ns/workloads/sa/intruder-mesh \
  -selector k8s:ns:workloads -selector k8s:sa:intruder-mesh -selector k8s:container-name:istio-proxy >/dev/null 2>&1 || echo "   entry for intruder-mesh already present"

echo ">> registering the geic-b workload identities"
kubectl --context kind-geic-b -n spire-system exec spire-nested-server-0 -c spire-server -- /opt/spire/bin/spire-server entry create -node \
  -spiffeID spiffe://ndip/nodes/geic-b-workers \
  -parentID spiffe://ndip/spire/server \
  -selector k8s_psat:cluster:geic-b >/dev/null 2>&1 || echo "   node alias for geic-b already present"
kubectl --context kind-geic-b -n spire-system exec spire-nested-server-0 -c spire-server -- /opt/spire/bin/spire-server entry create \
  -parentID spiffe://ndip/nodes/geic-b-workers \
  -spiffeID spiffe://ndip/ns/workloads/sa/frontend-b \
  -selector k8s:ns:workloads -selector k8s:sa:frontend-b -selector k8s:container-name:istio-proxy >/dev/null 2>&1 || echo "   entry for frontend-b already present"
kubectl --context kind-geic-b -n spire-system exec spire-nested-server-0 -c spire-server -- /opt/spire/bin/spire-server entry create \
  -parentID spiffe://ndip/nodes/geic-b-workers \
  -spiffeID spiffe://ndip/ns/workloads/sa/backend-b \
  -selector k8s:ns:workloads -selector k8s:sa:backend-b -selector k8s:container-name:istio-proxy >/dev/null 2>&1 || echo "   entry for backend-b already present"
kubectl --context kind-geic-b -n spire-system exec spire-nested-server-0 -c spire-server -- /opt/spire/bin/spire-server entry create \
  -parentID spiffe://ndip/nodes/geic-b-workers \
  -spiffeID spiffe://ndip/ns/workloads/sa/intruder-mesh \
  -selector k8s:ns:workloads -selector k8s:sa:intruder-mesh -selector k8s:container-name:istio-proxy >/dev/null 2>&1 || echo "   entry for intruder-mesh already present"

echo ">> deploying the geic-b service pack first, it is the cross-cluster target"
kubectl --context kind-geic-b apply -f k8s/cluster-b/07-workloads.yaml

echo ">> deploying the geic-a service pack"
kubectl --context kind-geic-a apply -f k8s/cluster-a/07-workloads.yaml

echo ">> wiring backend-geic-b in geic-a to the geic-b node ports"
BACKEND_NODE_ENDPOINTS=""
for node in $(kubectl --context kind-geic-b get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  NODE_IP=$(kubectl --context kind-geic-b get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  echo "   backend-geic-b reachable at $NODE_IP:30080"
  BACKEND_NODE_ENDPOINTS="$BACKEND_NODE_ENDPOINTS  - addresses:
      - $NODE_IP
    conditions:
      ready: true
"
done

cat > .generated/backend-geic-b-endpointslice.yaml <<SLICE
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: backend-geic-b-remote
  namespace: workloads
  labels:
    kubernetes.io/service-name: backend-geic-b
addressType: IPv4
ports:
  - name: http
    port: 30080
    protocol: TCP
endpoints:
$BACKEND_NODE_ENDPOINTS
SLICE
kubectl --context kind-geic-a apply -f .generated/backend-geic-b-endpointslice.yaml

echo ">> deploying the intruder pods used by the test suite"
kubectl --context kind-geic-a apply -f k8s/tests/intruders.yaml
kubectl --context kind-geic-b apply -f k8s/tests/intruders.yaml

kubectl --context kind-geic-a -n workloads rollout status deployment/frontend --timeout=600s
kubectl --context kind-geic-a -n workloads rollout status deployment/backend --timeout=600s
kubectl --context kind-geic-b -n workloads rollout status deployment/frontend --timeout=600s
kubectl --context kind-geic-b -n workloads rollout status deployment/backend --timeout=600s
kubectl --context kind-geic-a -n workloads wait --for=condition=Ready pod/intruder-plain pod/intruder-mesh --timeout=420s
kubectl --context kind-geic-b -n workloads wait --for=condition=Ready pod/intruder-plain pod/intruder-mesh --timeout=420s

kubectl --context kind-geic-a -n workloads get pods
kubectl --context kind-geic-b -n workloads get pods
