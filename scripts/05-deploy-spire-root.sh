#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/.."

mkdir -p .generated

echo ">> granting the root spire server read-only attestation access to both workload clusters"
kubectl --context kind-geic-a apply -f k8s/cluster-a/02-root-server-access.yaml
kubectl --context kind-geic-b apply -f k8s/cluster-b/02-root-server-access.yaml

echo ">> waiting for the service account token secrets to be populated"
for attempt in $(seq 1 60); do
  if kubectl --context kind-geic-a -n spire-system get secret spire-root-reader-token -o jsonpath='{.data.token}' 2>/dev/null | grep -q .; then break; fi
  sleep 2
done
for attempt in $(seq 1 60); do
  if kubectl --context kind-geic-b -n spire-system get secret spire-root-reader-token -o jsonpath='{.data.token}' 2>/dev/null | grep -q .; then break; fi
  sleep 2
done

GEIC_A_API_IP=$(kubectl --context kind-geic-a get node geic-a-control-plane -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
GEIC_A_TOKEN=$(kubectl --context kind-geic-a -n spire-system get secret spire-root-reader-token -o jsonpath='{.data.token}' | base64 -d)
GEIC_A_CA=$(kubectl --context kind-geic-a -n spire-system get secret spire-root-reader-token -o jsonpath='{.data.ca\.crt}')
echo "   geic-a api = https://$GEIC_A_API_IP:6443"
cat > .generated/geic-a.conf <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
  - name: geic-a
    cluster:
      server: https://$GEIC_A_API_IP:6443
      certificate-authority-data: $GEIC_A_CA
users:
  - name: spire-root-reader
    user:
      token: $GEIC_A_TOKEN
contexts:
  - name: geic-a
    context:
      cluster: geic-a
      user: spire-root-reader
current-context: geic-a
KUBECONFIG
kubectl --context kind-geic-root -n spire-root create secret generic geic-a-kubeconfig \
  --from-file=geic-a.conf=.generated/geic-a.conf --dry-run=client -o yaml | kubectl --context kind-geic-root apply -f -

GEIC_B_API_IP=$(kubectl --context kind-geic-b get node geic-b-control-plane -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
GEIC_B_TOKEN=$(kubectl --context kind-geic-b -n spire-system get secret spire-root-reader-token -o jsonpath='{.data.token}' | base64 -d)
GEIC_B_CA=$(kubectl --context kind-geic-b -n spire-system get secret spire-root-reader-token -o jsonpath='{.data.ca\.crt}')
echo "   geic-b api = https://$GEIC_B_API_IP:6443"
cat > .generated/geic-b.conf <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
  - name: geic-b
    cluster:
      server: https://$GEIC_B_API_IP:6443
      certificate-authority-data: $GEIC_B_CA
users:
  - name: spire-root-reader
    user:
      token: $GEIC_B_TOKEN
contexts:
  - name: geic-b
    context:
      cluster: geic-b
      user: spire-root-reader
current-context: geic-b
KUBECONFIG
kubectl --context kind-geic-root -n spire-root create secret generic geic-b-kubeconfig \
  --from-file=geic-b.conf=.generated/geic-b.conf --dry-run=client -o yaml | kubectl --context kind-geic-root apply -f -

echo ">> deploying the root spire server"
kubectl --context kind-geic-root apply -f k8s/cluster-root/02-spire-root-server.yaml
kubectl --context kind-geic-root -n spire-root rollout status statefulset/spire-root-server --timeout=420s

echo ">> CA provenance reported by the root server"
kubectl --context kind-geic-root -n spire-root logs spire-root-server-0 | grep -oE 'X509 CA prepared.*self_signed=[a-z]+.*' | tail -1

echo ">> registering geic-a as a downstream CA"
kubectl --context kind-geic-root -n spire-root exec spire-root-server-0 -- /opt/spire/bin/spire-server entry create -node \
  -spiffeID spiffe://ndip/nodes/geic-a \
  -parentID spiffe://ndip/spire/server \
  -selector k8s_psat:cluster:geic-a >/dev/null 2>&1 || echo "   node alias for geic-a already present"
kubectl --context kind-geic-root -n spire-root exec spire-root-server-0 -- /opt/spire/bin/spire-server entry create \
  -parentID spiffe://ndip/nodes/geic-a \
  -spiffeID spiffe://ndip/nested-server/geic-a \
  -selector unix:uid:1000 \
  -downstream >/dev/null 2>&1 || echo "   downstream entry for geic-a already present"

echo ">> registering geic-b as a downstream CA"
kubectl --context kind-geic-root -n spire-root exec spire-root-server-0 -- /opt/spire/bin/spire-server entry create -node \
  -spiffeID spiffe://ndip/nodes/geic-b \
  -parentID spiffe://ndip/spire/server \
  -selector k8s_psat:cluster:geic-b >/dev/null 2>&1 || echo "   node alias for geic-b already present"
kubectl --context kind-geic-root -n spire-root exec spire-root-server-0 -- /opt/spire/bin/spire-server entry create \
  -parentID spiffe://ndip/nodes/geic-b \
  -spiffeID spiffe://ndip/nested-server/geic-b \
  -selector unix:uid:1000 \
  -downstream >/dev/null 2>&1 || echo "   downstream entry for geic-b already present"

kubectl --context kind-geic-root -n spire-root exec spire-root-server-0 -- /opt/spire/bin/spire-server entry show
