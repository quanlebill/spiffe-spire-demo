# Zero-trust verification

Every test is grouped under **the enforcement layer it exercises**, so a pass tells you
something specific: not "it didn't connect", but *which* control refused, and for what
reason.
---

# Baseline — the intended paths must work

Not a layer. If these fail, every result below is meaningless.

### B.1 `frontend-a → backend-a` (intra-cluster)

```bash
kubectl --context kind-geic-a -n workloads exec deploy/frontend -c frontend -- sh -c 'python -m shared.probe "http://$LISTEN_HOST:8080/send?host=backend&port=8080&message=t1"'
```

```json
{"target":"backend:8080","status_code":200,"body":{"status":"message received","handled_by":"backend","handled_in_cluster":"geic-a","verified_caller":"spiffe://ndip/ns/workloads/sa/frontend-a"}}
```

`verified_caller` comes from the `X-Forwarded-Client-Cert` header. The application never
terminated TLS — Envoy did, and Envoy is the only party that can write that header.

### B.2 `frontend-a → backend-b` (cross-cluster, the whole point)

```bash
kubectl --context kind-geic-a -n workloads exec deploy/frontend -c frontend -- sh -c 'python -m shared.probe "http://$LISTEN_HOST:8080/send?host=backend-geic-b&port=8080&message=t2"'
```

Expect `"handled_in_cluster":"geic-b"` with `verified_caller` still `frontend-a`. **A workload
in one cluster was authenticated by name in another cluster** — no shared Kubernetes API, no
shared etcd, no shared secret, no certificate in the application.

### B.3 `frontend-b → backend-b` (intra-cluster, geic-b)

```bash
kubectl --context kind-geic-b -n workloads exec deploy/frontend -c frontend -- sh -c 'python -m shared.probe "http://$LISTEN_HOST:8080/send?host=backend&port=8080&message=t3"'
```

Expect `verified_caller` = `spiffe://ndip/ns/workloads/sa/frontend-b`.

---

# Layer 1 — Control-plane isolation

*The root CA and root SPIRE server live in their own cluster. An attacker with full
credentials for a workload cluster still cannot reach the signing key.*

### L1.1 The root SPIRE server holds no RBAC in its own cluster

It attests both workload clusters entirely through two read-only kubeconfigs, so it needs
nothing locally:

```bash
kubectl --context kind-geic-root auth can-i get pods --as=system:serviceaccount:spire-root:spire-root-server -A
```

```bash
kubectl --context kind-geic-root auth can-i create tokenreviews --as=system:serviceaccount:spire-root:spire-root-server -A
```

> The one service account in `geic-root` that *does* hold cluster RBAC is `openbao`, bound to
> `system:auth-delegator` so it can run the `TokenReview` behind the Kubernetes auth method.
> `kubectl --context kind-geic-root auth can-i create tokenreviews --as=system:serviceaccount:openbao:openbao -A`
> answers `yes`. That is the deliberate cost of removing the static Vault token.

### L1.2 No static credential exists between SPIRE and OpenBao

The root server authenticates with the Kubernetes auth method
What it carries instead is a projected token, audience-scoped and rotated by kubelet:
```bash
kubectl --context kind-geic-root -n spire-root get pod spire-root-server-0 -o jsonpath='{range .spec.volumes[*].projected.sources[*].serviceAccountToken}{.audience}{" expires="}{.expirationSeconds}{"\n"}{end}'
```

```
openbao expires=3600
```

And the OpenBao role that token maps to grants exactly one policy:

```bash
kubectl --context kind-geic-root -n openbao exec openbao-0 -- sh -c "BAO_TOKEN=$(kubectl --context kind-geic-root -n openbao get secret openbao-unseal -o jsonpath='{.data.root-token}' | base64 -d) bao read auth/kubernetes/role/spire-root-server"
```

```
audience                          openbao
bound_service_account_names       [spire-root-server]
bound_service_account_namespaces  [spire-root]
token_period                      24h
token_policies                    [spire-upstream]
```

`token_period` makes the issued token renewable indefinitely — and unlike the static token
this replaced, something actually renews it. To watch that, set `log_level = "DEBUG"` on the
root server and look for:

```bash
kubectl --context kind-geic-root -n spire-root logs spire-root-server-0 | grep -i renew
```

```
level=debug msg="Token will be renewed" plugin_name=vault
level=debug msg="Successfully renew auth token" lease_duration=86400 plugin_name=vault
```
---

# Layer 7 — Credentials

*The application container holds no key, no socket and no token. Kubernetes RBAC is
name-scoped.* Placed here because none of it depends on network state.

### L7.1 The SPIRE socket is mounted only into Envoy

```bash
kubectl --context kind-geic-a -n workloads get pod -l app=backend -o jsonpath='{.items[0].spec.initContainers[?(@.name=="istio-proxy")].volumeMounts[*].name}'
```

```
workload-socket credential-socket workload-certs istiod-ca-cert istio-ca-crl istio-data istio-envoy istio-token istio-podinfo
```

```bash
kubectl --context kind-geic-a -n workloads get pod -l app=backend -o jsonpath='{.items[0].spec.containers[?(@.name=="backend")].volumeMounts[*].name}'
```

`istio-proxy` has `workload-socket`. The app container prints **nothing** — zero mounts.

### L7.2 The app cannot read the Workload API socket

```bash
kubectl --context kind-geic-a -n workloads exec deploy/backend -c backend -- ls /run/secrets/workload-spiffe-uds
```

```
ls: cannot access '/run/secrets/workload-spiffe-uds': No such file or directory
command terminated with exit code 2
```

### L7.3 The SPIRE entry is scoped to the Envoy container

```bash
kubectl --context kind-geic-a -n spire-system exec spire-nested-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show -spiffeID spiffe://ndip/ns/workloads/sa/backend-a
```

```
Selector : k8s:container-name:istio-proxy
Selector : k8s:ns:workloads
Selector : k8s:sa:backend-a
```

Even if the app *could* reach the socket, it would fail attestation — its container name is
`backend`, not `istio-proxy`.

### L7.4 The app carries no Kubernetes API token

```bash
kubectl --context kind-geic-a -n workloads exec deploy/backend -c backend -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
```

```
cat: /var/run/secrets/kubernetes.io/serviceaccount/token: No such file or directory
command terminated with exit code 1
```

### L7.5 The nested SPIRE server cannot patch configmaps cluster-wide

```bash
kubectl --context kind-geic-a auth can-i patch configmaps --as=system:serviceaccount:spire-system:spire-nested-server -n kube-system
```

```bash
kubectl --context kind-geic-a auth can-i patch configmaps --as=system:serviceaccount:spire-system:spire-nested-server -n istio-system
```

```bash
kubectl --context kind-geic-a auth can-i patch configmaps/spire-bundle --as=system:serviceaccount:spire-system:spire-nested-server -n spire-system
```

`no`, `no`, then `yes` — allowed only on the single named bundle ConfigMap.

### L7.6 Service Account without Role Binding: Deny-all resource access by default

```bash
kubectl --context kind-geic-a auth can-i list secrets --as=system:serviceaccount:spire-system:spire-nested-server -A
```

```bash
kubectl --context kind-geic-a auth can-i list secrets --as=system:serviceaccount:spire-system:spire-agent -A
```

```bash
kubectl --context kind-geic-a auth can-i list secrets --as=system:serviceaccount:spire-system:spiffe-csi-driver -A
```

```bash
kubectl --context kind-geic-a auth can-i list secrets --as=system:serviceaccount:workloads:frontend-a -A
```

```bash
kubectl --context kind-geic-a auth can-i list secrets --as=system:serviceaccount:workloads:backend-a -A
```

All five `no`. The workloads answer `no` because they have **no RoleBinding at all** — the
absence of a binding is the deny. Kubernetes RBAC is additive-only; an "empty" Role would
enforce nothing.

---

# Assume breach — open the network layer

Everything from here to layer 2 runs with L3 **deliberately open**, so that Calico cannot
take credit for a result the mesh produced.

```bash
kubectl --context kind-geic-a apply -f k8s/tests/assume-breach-networkpolicy.yaml
```

```bash
kubectl --context kind-geic-b apply -f k8s/tests/assume-breach-networkpolicy.yaml
```

```bash
sleep 6
```

---

# Layer 3 — Traffic capture

*`istio-init` iptables redirect all inbound to Envoy on 15006 and all outbound to 15001. The
application never sees a socket that bypasses the proxy.*

### L3.1 Attack the pod IP directly, bypassing Service and DNS

The pod IP is resolved inline, so there is still nothing to set up first:

```bash
kubectl --context kind-geic-a -n workloads exec intruder-plain -c toolbox -- curl -sS -m 8 http://$(kubectl --context kind-geic-a -n workloads get pod -l app=backend -o jsonpath='{.items[0].status.podIP}'):8080/receive-message
```

Connection reset. Addressing the pod directly changes nothing, because every inbound packet
is redirected to Envoy on 15006 before it can reach port 8080.

### L3.2 Port 8080 is owned by Envoy, not the app

```bash
kubectl --context kind-geic-a -n workloads exec intruder-plain -c toolbox -- sh -c "echo | openssl s_client -connect $(kubectl --context kind-geic-a -n workloads get pod -l app=backend -o jsonpath='{.items[0].status.podIP}'):8080 2>/dev/null | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'"
```

```
X509v3 Subject Alternative Name:
    URI:spiffe://ndip/ns/workloads/sa/backend-a
```

A TLS server answers on 8080 presenting backend-a's SVID. The application speaks plain HTTP,
so it cannot possibly be the thing answering.

### L3.3 The iptables rules istio-init installed

```bash
kubectl --context kind-geic-a -n workloads logs deploy/backend -c istio-init | grep -E 'ISTIO_REDIRECT|ISTIO_IN_REDIRECT|PREROUTING'
```

```
-A ISTIO_REDIRECT     -p tcp -j REDIRECT --to-ports 15001
-A ISTIO_IN_REDIRECT  -p tcp -j REDIRECT --to-ports 15006
-A PREROUTING         -p tcp -j ISTIO_INBOUND
```

### L3.4 What is actually listening inside the pod

The whole listener dump as one `python -c`, parsing `/proc/net/tcp` in a single expression:

```bash
kubectl --context kind-geic-a -n workloads exec deploy/backend -c backend -- python -c "import socket,struct;[print(socket.inet_ntoa(struct.pack('<L',int(l.split()[1].split(':')[0],16)))+':'+str(int(l.split()[1].split(':')[1],16))+' uid='+l.split()[7]) for l in open('/proc/net/tcp').read().splitlines()[1:] if l.split()[3]=='0A']"
```

```
10.10.110.144:8080 uid=1000     <- the application, on the pod IP only
0.0.0.0:15090      uid=1337     <- Envoy metrics
0.0.0.0:15001      uid=1337     <- Envoy outbound
0.0.0.0:15006      uid=1337     <- Envoy inbound
0.0.0.0:15021      uid=1337     <- Envoy health
127.0.0.1:15000    uid=1337     <- Envoy admin (loopback only)
```

The application is `uid=1000` bound to the pod IP alone; everything on `0.0.0.0` is `uid=1337`,
which is Envoy.

---

# Layer 4 — Transport identity

*`PeerAuthentication: STRICT` plus SVIDs whose chain terminates at the OpenBao root. Answers
"who are you" — not "may you".*

### L4.1 The chain Envoy actually presents

The SVID chain is three concatenated PEM certificates. `crl2pkcs7` bundles them so
`pkcs7 -print_certs` can walk all three in one pass — no temporary files, no loop:

```bash
istioctl --context kind-geic-a proxy-config secret deploy/frontend.workloads -o json | tr -d ' \n' | grep -o '"certificateChain":{"inlineBytes":"[^"]*"' | head -1 | sed 's/.*inlineBytes":"//; s/"$//' | base64 -d | kubectl --context kind-geic-a -n workloads exec -i intruder-plain -c toolbox -- sh -c 'openssl crl2pkcs7 -nocrl -certfile /dev/stdin | openssl pkcs7 -print_certs -noout'
```

```
subject=C=US, O=SPIRE                                       ← leaf SVID, 1h
issuer =C=VN, O=GEIC, OU=DOWNSTREAM-1, CN=NDIP SPIRE Root   ← nested CA, 24h

subject=C=VN, O=GEIC, OU=DOWNSTREAM-1, CN=NDIP SPIRE Root
issuer =C=VN, O=GEIC, CN=NDIP SPIRE Root                    ← root SPIRE CA, 168h

subject=C=VN, O=GEIC, CN=NDIP SPIRE Root
issuer =C=VN, O=GEIC, CN=NDIP Root CA                       ← OpenBao root, 10y
```

Four levels. `OU=DOWNSTREAM-1` is the marker the root server stamps on a downstream CA.

Add `-text` to see the algorithms — every CA key is EC P-384, so every signature is
`ecdsa-with-SHA384`, while the leaf's own key is EC P-256:

```bash
istioctl --context kind-geic-a proxy-config secret deploy/frontend.workloads -o json | tr -d ' \n' | grep -o '"certificateChain":{"inlineBytes":"[^"]*"' | head -1 | sed 's/.*inlineBytes":"//; s/"$//' | base64 -d | kubectl --context kind-geic-a -n workloads exec -i intruder-plain -c toolbox -- sh -c 'openssl crl2pkcs7 -nocrl -certfile /dev/stdin | openssl pkcs7 -print_certs -text -noout | grep -E "Signature Algorithm|Public-Key|NIST CURVE"'
```

### L4.2 The mesh trust root *is* the OpenBao root

Compare serial numbers — these two must print the same value:

```bash
kubectl --context kind-geic-root -n openbao exec openbao-0 -- sh -c 'bao read -field=certificate pki/cert/ca' | kubectl --context kind-geic-a -n workloads exec -i intruder-plain -c toolbox -- openssl x509 -noout -subject -serial
```

```bash
kubectl --context kind-geic-root -n spire-root exec spire-root-server-0 -- /opt/spire/bin/spire-server bundle show | kubectl --context kind-geic-a -n workloads exec -i intruder-plain -c toolbox -- openssl x509 -noout -serial
```

This is the test that catches a silently-destroyed or replaced root CA. It is also the test
that caught the CA being wiped when OpenBao ran in `-dev` mode — everything kept working
until the next rotation 168h later, and only this check failed immediately.

### L4.3 The nesting is real

```bash
kubectl --context kind-geic-root -n spire-root logs spire-root-server-0 | grep -oE 'X509 CA (activated|prepared).*' | tail -1
```

```bash
kubectl --context kind-geic-a -n spire-system logs spire-nested-server-0 -c spire-server | grep -o 'upstream_authority_id=[a-f0-9]*' | tail -1
```

The root server's `local_authority_id` must equal the nested server's
`upstream_authority_id`. On a freshly-minted CA the root line also carries
`self_signed=false`; after a restart SPIRE reloads from its journal and logs only
`upstream_authority_id`, which is the restart-proof form of the same claim.

### L4.4 ATTACK — plaintext HTTP from an unmeshed pod

```bash
kubectl --context kind-geic-a -n workloads exec intruder-plain -c toolbox -- curl -sS -m 8 -X POST -H 'Content-Type: application/json' -d '{"message":"pwn"}' http://backend:8080/receive-message
```

```
curl: (56) Recv failure: Connection reset by peer
```

Envoy requires mTLS; a cleartext request is reset. No application data leaks.

### L4.5 ATTACK — a forged certificate claiming frontend-a's identity

Mint it inside the intruder pod:

```bash
kubectl --context kind-geic-a -n workloads exec intruder-plain -c toolbox -- python forge_certificate.py spiffe://ndip/ns/workloads/sa/frontend-a /tmp/forged
```

Then present it:

```bash
kubectl --context kind-geic-a -n workloads exec intruder-plain -c toolbox -- sh -c "printf 'POST /receive-message HTTP/1.1\r\nHost: backend\r\nContent-Length: 15\r\n\r\n{\"message\":\"x\"}' | openssl s_client -connect $(kubectl --context kind-geic-a -n workloads get pod -l app=backend -o jsonpath='{.items[0].status.podIP}'):8080 -cert /tmp/forged/forged.pem -key /tmp/forged/forged.key -ign_eof 2>&1 | tail -4"
```

```
error:0A000416:SSL routines:ssl3_read_bytes:ssl/tls alert certificate unknown:SSL alert number 46
```

Blocked because the chain does not reach the OpenBao root. The SPIFFE ID is an assertion; the
signature is the proof.

> **TLS 1.3 subtlety:** the client's handshake appears to complete, because in TLS 1.3 the
> client sends its certificate last and does not wait for approval. The rejection arrives as
> an alert only when data is actually sent — which is why this test sends a request rather
> than merely connecting.

---

# Layer 5 — Authorization

*`AuthorizationPolicy` on SPIFFE principal, method and path. Answers "may you" — a different
question from layer 4.*

### L5.1 ATTACK — a real SPIRE-issued SVID, wrong identity

`intruder-mesh` is fully attested and holds a genuine certificate signed by the real CA:

```bash
kubectl --context kind-geic-a -n workloads exec intruder-mesh -c toolbox -- curl -sS -m 8 -w '\nHTTP:%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{"message":"pwn"}' http://backend:8080/receive-message
```

```
RBAC: access denied
HTTP:403
```

**The sharpest result in the suite.** The certificate validates perfectly against the trust
bundle — and the request is still refused, because `AuthorizationPolicy` allows only
`ndip/ns/workloads/sa/frontend-a`. A valid identity is not an authorisation.

### L5.2 ATTACK — the same attack inside geic-b

```bash
kubectl --context kind-geic-b -n workloads exec intruder-mesh -c toolbox -- curl -sS -m 8 -w '\nHTTP:%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{"message":"pwn"}' http://backend:8080/receive-message
```

Also `RBAC: access denied`. Being in the same namespace and cluster as the target grants
nothing.

---

# Layer 6 — Egress scope

*`Sidecar.egress.hosts` plus `outboundTrafficPolicy: REGISTRY_ONLY`. `egress.hosts` is the
allow-list; `REGISTRY_ONLY` is what makes it enforcing rather than advisory.*

### L6.1 ATTACK — backend tries to call frontend

L3 is wide open between them, but `backend`'s `Sidecar` declares egress to `istio-system/*`
only:

```bash
kubectl --context kind-geic-a -n workloads exec deploy/backend -c backend -- sh -c 'python -m shared.probe "http://$LISTEN_HOST:8080/send?host=frontend&port=8080&message=t37"'
```

```json
{"target":"frontend:8080","status_code":null,"error":"ConnectionResetError: [Errno 104] Connection reset by peer"}
```

A reset rather than a 502 because the app opens a raw TCP connection, and `frontend` is not in
`backend`'s egress scope — so there is no cluster for it, and the request falls into the
BlackHoleCluster.

---

# Restore lockdown

```bash
kubectl --context kind-geic-a delete -f k8s/tests/assume-breach-networkpolicy.yaml
```

```bash
kubectl --context kind-geic-b delete -f k8s/tests/assume-breach-networkpolicy.yaml
```

```bash
sleep 8
```

---

# Layer 2 — L3/L4 network

*Calico `NetworkPolicy`, default-deny on ingress **and** egress. kindnet does not implement
NetworkPolicy at all, so without Calico this layer would silently not exist.*

### L2.1 ATTACK — the intruder now cannot even reach Envoy

The exact command from [L3.1](#l31-attack-the-pod-ip-directly-bypassing-service-and-dns),
rerun with default-deny back in force:

```bash
kubectl --context kind-geic-a -n workloads exec intruder-plain -c toolbox -- curl -sS -m 8 http://$(kubectl --context kind-geic-a -n workloads get pod -l app=backend -o jsonpath='{.items[0].status.podIP}'):8080/receive-message
```

```
curl: (28) Connection timed out after 8002 milliseconds
```

**Timeout, not reset** — and that difference is the whole test. A reset means Envoy saw the
connection and refused it. A timeout means Calico dropped the packet before Envoy existed as
far as the attacker is concerned.

### L2.2 The legitimate path is unaffected by the lockdown

```bash
kubectl --context kind-geic-a -n workloads exec deploy/frontend -c frontend -- sh -c 'python -m shared.probe "http://$LISTEN_HOST:8080/send?host=backend&port=8080&message=t42"'
```

Still `200`.

---

# HA and attestation Testing

Not enforcement layers. These verify the machinery the seven layers assume is working.

### P.1 Node attestation — an unauthorised agent must not join

The `k8s_psat` allow-lists are disjoint per tier: the root server accepts only
`spire-system:spire-nested-server`, the nested servers only `spire-system:spire-agent`.

```bash
kubectl --context kind-geic-a apply -f k8s/tests/rogue-agent.yaml
```

```bash
sleep 40
```

```bash
kubectl --context kind-geic-a -n spire-system logs rogue-agent | grep -i error
```

```
level=error msg="Agent crashed" error="failed to receive attestation response: rpc error: code = PermissionDenied desc = nodeattestor(k8s_psat): \"spire-system:rogue-agent\" is not an allowed service account for cluster \"geic-a\""
```

```bash
kubectl --context kind-geic-a delete -f k8s/tests/rogue-agent.yaml
```

### P.2 Datastore durability and failover

> `spire-nested-server` currently ships at **`replicas: 1`**, so the two-replica comparison
> below has nothing to compare — skip the `spire-nested-server-1` commands. Raise both
> `k8s/cluster-{a,b}/03-spire-nested-server.yaml` to `replicas: 2` and re-run stage 06 to
> exercise it; `geic-b`'s control-plane is already untainted so the required anti-affinity has
> a second node to use.

Entries live in PostgreSQL, not in the server pod:

```bash
kubectl --context kind-geic-a -n spire-system exec spire-nested-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show | grep -c "SPIFFE ID"
```

A non-zero count — `4` here: one node alias plus `frontend-a`, `backend-a` and
`intruder-mesh`. At `replicas: 2` the same command against `spire-nested-server-1` returns the
identical number, because the datastore — not the CA — is what they share:

```bash
kubectl --context kind-geic-a -n spire-system exec spire-nested-server-1 -c spire-server -- /opt/spire/bin/spire-server entry show | grep -c "SPIFFE ID"
```

Each replica keeps its **own** CA, both chaining to the same root (needs `replicas: 2`):

```bash
kubectl --context kind-geic-a -n spire-system logs spire-nested-server-0 -c spire-server | grep "X509 CA activated" | tail -1 | grep -oE '(local|upstream)_authority_id=[a-f0-9]+' | paste -sd' '
```

```bash
kubectl --context kind-geic-a -n spire-system logs spire-nested-server-1 -c spire-server | grep "X509 CA activated" | tail -1 | grep -oE '(local|upstream)_authority_id=[a-f0-9]+' | paste -sd' '
```

```
local_authority_id=ec988b80a961c448960e59f4575bd4e21edfb244 upstream_authority_id=117264560d16509744b3c1a448bb255c49f7fb1a
local_authority_id=003e0bed9daeff00acf85359c1c1d6bee73893d8 upstream_authority_id=117264560d16509744b3c1a448bb255c49f7fb1a
```

Different CA keys, same upstream. Now kill the server and confirm issuance continues:

```bash
kubectl --context kind-geic-a -n spire-system delete pod spire-nested-server-0 --wait=false
```

```bash
kubectl --context kind-geic-a -n spire-system rollout status statefulset/spire-nested-server --timeout=420s
```

```bash
kubectl --context kind-geic-a -n workloads rollout restart deploy/backend
```

```bash
kubectl --context kind-geic-a -n workloads rollout status deploy/backend --timeout=600s
```

Reaching `Ready` means the backend obtained a **fresh** SVID after the server was replaced.

```bash
kubectl --context kind-geic-a -n workloads exec deploy/frontend -c frontend -- sh -c 'python -m shared.probe "http://$LISTEN_HOST:8080/send?host=backend&port=8080&message=ha"'
```

The entry count is unchanged afterwards, because the entries were never in the pod:

```bash
kubectl --context kind-geic-a -n spire-system exec spire-nested-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show | grep -c "SPIFFE ID"
```

Finally, the root CA survives an OpenBao restart — the failure this replaced was `-dev` mode
destroying the PKI mount outright. Record the serial:

```bash
kubectl --context kind-geic-root -n openbao exec openbao-0 -- sh -c 'bao read -field=certificate pki/cert/ca' | kubectl --context kind-geic-a -n workloads exec -i intruder-plain -c toolbox -- openssl x509 -noout -serial
```

```bash
kubectl --context kind-geic-root -n openbao delete pod openbao-0
```

```bash
kubectl --context kind-geic-root -n openbao wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 --timeout=300s
```

It comes back **sealed**. The unseal key is read inline from the Secret:

```bash
kubectl --context kind-geic-root -n openbao exec openbao-0 -- sh -c "bao operator unseal $(kubectl --context kind-geic-root -n openbao get secret openbao-unseal -o jsonpath='{.data.unseal-key}' | base64 -d)"
```

```bash
kubectl --context kind-geic-root -n openbao exec openbao-0 -- sh -c 'bao read -field=certificate pki/cert/ca' | kubectl --context kind-geic-a -n workloads exec -i intruder-plain -c toolbox -- openssl x509 -noout -serial
```

Same serial before and after. Or just re-run `bash scripts/04-deploy-openbao.sh`, which
unseals it for you.

---

## Leave the cluster locked down

```bash
kubectl --context kind-geic-a delete -f k8s/tests/assume-breach-networkpolicy.yaml --ignore-not-found
```

```bash
kubectl --context kind-geic-b delete -f k8s/tests/assume-breach-networkpolicy.yaml --ignore-not-found
```

---
