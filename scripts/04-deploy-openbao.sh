#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/.."

mkdir -p .generated

echo ">> creating namespaces"
kubectl --context kind-geic-root apply -f k8s/cluster-root/00-namespaces.yaml
kubectl --context kind-geic-a    apply -f k8s/cluster-a/00-namespaces.yaml
kubectl --context kind-geic-b    apply -f k8s/cluster-b/00-namespaces.yaml

echo ">> deploying openbao"
kubectl --context kind-geic-root apply -f k8s/cluster-root/01-openbao.yaml
kubectl --context kind-geic-root -n openbao wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 --timeout=420s

echo ">> waiting for the openbao api to answer"
for attempt in $(seq 1 60); do
  BAO_STATUS=$(kubectl --context kind-geic-root -n openbao exec openbao-0 -- sh -c 'bao status -format=json' 2>/dev/null || true)
  if printf '%s' "$BAO_STATUS" | grep -q '"initialized"'; then break; fi
  sleep 3
done
printf '%s' "$BAO_STATUS" | grep -q '"initialized"' || { echo "ERROR: openbao never answered bao status" >&2; exit 1; }

if printf '%s' "$BAO_STATUS" | grep -q '"initialized": *true'; then
  echo ">> openbao already initialised, reusing the stored unseal key"
else
  echo ">> initialising openbao with one key share and a threshold of one"
  kubectl --context kind-geic-root -n openbao exec openbao-0 -- sh -c 'bao operator init -key-shares=1 -key-threshold=1 -format=json' > .generated/openbao-init.json
  UNSEAL_KEY=$(tr -d ' \n\r"' < .generated/openbao-init.json | sed 's/.*unseal_keys_b64:\[//; s/\].*//' | cut -d, -f1)
  ROOT_TOKEN=$(tr -d ' \n\r"' < .generated/openbao-init.json | sed 's/.*root_token://; s/[,}].*//')
  [ ${#UNSEAL_KEY} -gt 10 ] || { echo "ERROR: could not parse the unseal key out of .generated/openbao-init.json" >&2; exit 1; }
  [ ${#ROOT_TOKEN} -gt 10 ] || { echo "ERROR: could not parse the root token out of .generated/openbao-init.json" >&2; exit 1; }
  kubectl --context kind-geic-root -n openbao create secret generic openbao-unseal \
    --from-literal=unseal-key="$UNSEAL_KEY" --from-literal=root-token="$ROOT_TOKEN" \
    --dry-run=client -o yaml | kubectl --context kind-geic-root apply -f -
fi

BAO_STATUS=$(kubectl --context kind-geic-root -n openbao exec openbao-0 -- sh -c 'bao status -format=json' 2>/dev/null || true)

if printf '%s' "$BAO_STATUS" | grep -q '"sealed": *true'; then
  echo ">> unsealing openbao"
  UNSEAL_KEY=$(kubectl --context kind-geic-root -n openbao get secret openbao-unseal -o jsonpath='{.data.unseal-key}' | base64 -d)
  kubectl --context kind-geic-root -n openbao exec openbao-0 -- sh -c "bao operator unseal $UNSEAL_KEY" | grep -E 'Sealed|Initialized'
else
  echo ">> openbao is already unsealed"
fi
kubectl --context kind-geic-root -n openbao wait --for=condition=Ready pod/openbao-0 --timeout=300s

ROOT_TOKEN=$(kubectl --context kind-geic-root -n openbao get secret openbao-unseal -o jsonpath='{.data.root-token}' | base64 -d)

echo ">> enabling the pki engine and minting the NDIP root CA"
kubectl --context kind-geic-root -n openbao exec openbao-0 -- sh -c 'export BAO_TOKEN='"$ROOT_TOKEN"'
set -e
bao secrets list | grep -q "^pki/" || bao secrets enable -path=pki -max-lease-ttl=87600h pki
bao read pki/cert/ca >/dev/null 2>&1 || bao write -field=certificate pki/root/generate/internal common_name="NDIP Root CA" issuer_name=ndip-root ttl=87600h key_type=ec key_bits=384 organization=GEIC country=VN >/dev/null
bao write pki/config/urls issuing_certificates=http://openbao.openbao.svc.cluster.local:8200/v1/pki/ca crl_distribution_points=http://openbao.openbao.svc.cluster.local:8200/v1/pki/crl >/dev/null
printf "%s" "path \"pki/root/sign-intermediate\" { capabilities = [\"update\"] }" > /tmp/spire-upstream.hcl
bao policy write spire-upstream /tmp/spire-upstream.hcl >/dev/null
'


echo ">> enabling the kubernetes auth method so openbao trusts projected service account tokens"
kubectl --context kind-geic-root -n openbao exec openbao-0 -- sh -c 'export BAO_TOKEN='"$ROOT_TOKEN"'
set -e
bao auth list | grep -q "^kubernetes/" || bao auth enable kubernetes
bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443 >/dev/null
bao write auth/kubernetes/role/spire-root-server \
  bound_service_account_names=spire-root-server \
  bound_service_account_namespaces=spire-root \
  audience=openbao \
  token_policies=spire-upstream \
  token_period=24h >/dev/null
'
kubectl --context kind-geic-root -n openbao exec openbao-0 -- sh -c "BAO_TOKEN=$ROOT_TOKEN bao read auth/kubernetes/role/spire-root-server" | grep -Ei "bound_service_account|audience|token_policies|token_period"

echo ">> removing the static upstream token this setup no longer uses"
kubectl --context kind-geic-root -n spire-root delete secret openbao-upstream-token --ignore-not-found

kubectl --context kind-geic-root -n openbao exec openbao-0 -- sh -c 'bao read -field=certificate pki/cert/ca' | head -3
