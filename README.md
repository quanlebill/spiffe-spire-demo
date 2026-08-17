# SPIRE mTLS Demo

A SPIRE deployment on a local kind cluster, plus two FastAPI workloads (`frontend`
and `backend`) that authenticate each other over mutual TLS using SPIFFE SVIDs
issued by SPIRE
- Trust domain: `ndip`
- Kind cluster name: `geic-cluster`
- SPIRE control plane namespace: `spire`
- Workload namespace: `workloads`
- Frontend identity: `spiffe://ndip/frontend`
- Backend identity: `spiffe://ndip/backend`

## Prerequisites

- Docker
- [`kind`](https://kind.sigs.k8s.io/)
- `kubectl`

## Step 1 — Create the kind cluster

```bash
kind create cluster --config k8s/0_create_kind_cluster.yaml
```

This creates `geic-cluster` with one control-plane node and two worker nodes,
and points `kubectl` at it as context `kind-geic-cluster`.

## Step 2 — Deploy the SPIRE control plane

```bash
kubectl apply -f k8s/1_create_namespace.yaml
kubectl apply -f k8s/2_spire_server.yaml
kubectl -n spire rollout status statefulset/spire-server --timeout=120s
kubectl apply -f k8s/3_spire_agent.yaml
```

Wait for the agent DaemonSet to come up on both worker nodes:

```bash
kubectl -n spire get pods -w
```

Wait until you see two `spire-agent-*` pods and `spire-server-0`, all `1/1
Running`.

Confirm both agents attested successfully:

```bash
kubectl -n spire exec spire-server-0 -- /opt/spire/bin/spire-server agent list -socketPath /tmp/spire-server/private/api.sock
```
## Step 3 — Build and load the workload images

```bash
docker build -f app/backend/Dockerfile -t backend-workload:latest app
docker build -f app/frontend/Dockerfile -t frontend-workload:latest app
kind load docker-image backend-workload:latest frontend-workload:latest --name geic-cluster
```

`kind load docker-image` copies the locally built images into every node of
the cluster so the pods can start with `imagePullPolicy: IfNotPresent`
without needing a registry.

## Step 4 — Register the workload identities

Each workload pod fetches its SVID by asking its node's spire-agent for one,
but the agent will only hand one out if a matching registration entry
exists. Register `spiffe://ndip/backend` and `spiffe://ndip/frontend`
against **every** attested agent, so the pod gets an identity no matter
which worker node it lands on:

```bash
kubectl -n spire exec spire-server-0 -- /opt/spire/bin/spire-server entry create -socketPath /tmp/spire-server/private/api.sock -parentID <AGENT_SPIFFE_ID> -spiffeID spiffe://ndip/backend -selector k8s:ns:workloads -selector k8s:sa:backend-workload
```

```bash
kubectl -n spire exec spire-server-0 -- /opt/spire/bin/spire-server entry create -socketPath /tmp/spire-server/private/api.sock -parentID <AGENT_SPIFFE_ID> -spiffeID spiffe://ndip/frontend -selector k8s:ns:workloads -selector k8s:sa:frontend-workload
```

Replace `<AGENT_SPIFFE_ID>` with one of the SPIFFE IDs from the step 2
`agent list` output. This cluster has two worker nodes (two agents), so run
each command once per agent SPIFFE ID — 4 `entry create` calls total — so
the pod gets an identity no matter which node it lands on. Each call prints
the entry it created.

## Step 5 — Deploy the workloads

```bash
kubectl apply -f k8s/4_backend_workload.yaml
kubectl apply -f k8s/5_frontend_workload.yaml
```

Watch until both are `1/1 Running`:

```bash
kubectl -n workloads get pods -w
```

If a pod's init container shows `Init:Error` and the pod restarts, that
almost always means step 4 ran after step 5 (no registration entry existed
yet when the pod first tried to fetch its SVID). It will recover on its own
retry once the entry exists — check with:

```bash
kubectl -n workloads logs backend-workload -c fetch-svid
kubectl -n workloads logs frontend-workload -c fetch-svid
```

## Step 6 — Run the test: verify the mTLS exchange

The frontend automatically sends a message to the backend a few seconds
after it starts up. Check both apps' logs:

```bash
kubectl -n workloads logs backend-workload -c backend-workload
kubectl -n workloads logs frontend-workload -c frontend-workload
```

Expected backend output:

```
backend workload listening with mutual tls on 0.0.0.0:8443
received message from spiffe://ndip/frontend: hello from frontend
sent reply to spiffe://ndip/frontend: backend received: hello from frontend
```

Expected frontend output:

```
frontend workload listening with mutual tls on 0.0.0.0:8443
sent message to spiffe://ndip/backend: hello from frontend
received reply from spiffe://ndip/backend: backend received: hello from frontend
```

If you see both, the full round trip worked: frontend authenticated
backend's certificate before sending, backend authenticated frontend's
certificate before accepting the message and before sending its reply, and
frontend authenticated backend's certificate again before accepting the
reply.

## Step 7 (optional) — Send a request by hand with openssl

Both services already do this automatically over Python — this step does
the same thing manually from a terminal, using each pod's real,
SPIRE-issued certificate, so you can see the raw TLS handshake and HTTP
exchange yourself.

From the **frontend** pod, call backend's `/receive-message`:

```bash
kubectl exec -n workloads frontend-workload -c frontend-workload -- sh -c '
BODY="{\"message\": \"hello from openssl\"}"
printf "POST /receive-message HTTP/1.1\r\nHost: backend-workload-service\r\nContent-Type: application/json\r\nContent-Length: ${#BODY}\r\nConnection: close\r\n\r\n${BODY}" | openssl s_client -quiet -connect backend-workload-service:8443 -cert /run/spire/svids/svid.0.pem -key /run/spire/svids/svid.0.key -CAfile /run/spire/svids/bundle.0.pem
'
```

Expected output — the TLS handshake details, followed by a real HTTP
response:

```
HTTP/1.1 200 status
content-length: 29
content-type: application/json

{"status":"message received"}
```

From the **backend** pod, call frontend's `/receive-reply` the same way:

```bash
kubectl exec -n workloads backend-workload -c backend-workload -- sh -c '
BODY="{\"reply\": \"hello from openssl on backend\"}"
printf "POST /receive-reply HTTP/1.1\r\nHost: frontend-workload-service\r\nContent-Type: application/json\r\nContent-Length: ${#BODY}\r\nConnection: close\r\n\r\n${BODY}" | openssl s_client -quiet -connect frontend-workload-service:8443 -cert /run/spire/svids/svid.0.pem -key /run/spire/svids/svid.0.key -CAfile /run/spire/svids/bundle.0.pem
'
```

Both commands use the pod's own already-fetched SVID files
(`/run/spire/svids/svid.0.pem`, `svid.0.key`, `bundle.0.pem`) as the client
certificate for `openssl s_client`, so the request is genuinely
authenticated as that workload — this is not a spoofed identity, just a
manual client instead of the Python one built into the app. Check
`kubectl -n workloads logs backend-workload -c backend-workload` (or
`frontend-workload`) afterward to see the request logged on the receiving
side, same as in step 6.

To see a rejection instead of a `200`, have frontend call *its own*
`/receive-reply` endpoint — it presents the frontend's certificate, but
that endpoint only accepts the backend's identity:

```bash
kubectl exec -n workloads frontend-workload -c frontend-workload -- sh -c '
BODY="{\"reply\": \"this should be rejected\"}"
printf "POST /receive-reply HTTP/1.1\r\nHost: frontend-workload-service\r\nContent-Type: application/json\r\nContent-Length: ${#BODY}\r\nConnection: close\r\n\r\n${BODY}" | openssl s_client -quiet -connect frontend-workload-service:8443 -cert /run/spire/svids/svid.0.pem -key /run/spire/svids/svid.0.key -CAfile /run/spire/svids/bundle.0.pem
'
```

```
HTTP/1.1 403 status
content-length: 61
content-type: application/json

{"detail":"only the backend workload may call this endpoint"}
```

## Step 8 (optional) — Prove the identity check actually rejects impostors

This deploys a third workload with its own valid, SPIRE-issued identity
(`spiffe://ndip/intruder` — a real trust-domain member, just not `frontend`)
and has it call the backend directly. It should be rejected with `403`.

```bash
kubectl -n spire exec spire-server-0 -- /opt/spire/bin/spire-server entry create -socketPath /tmp/spire-server/private/api.sock -parentID <AGENT_SPIFFE_ID> -spiffeID spiffe://ndip/intruder -selector k8s:ns:workloads -selector k8s:sa:intruder-workload
```

As in step 4, replace `<AGENT_SPIFFE_ID>` and run once per agent SPIFFE ID
from the step 2 output.

```bash
kubectl apply -f k8s/6_intruder_workload.yaml
kubectl -n workloads logs intruder-workload -c intruder-workload
```

Expected output: `response status 403: {'detail': 'only the frontend
workload may call this endpoint'}`, and the backend log gains a line:
`rejected request from unauthorized workload identity: spiffe://ndip/intruder`.

Clean up afterward:

```bash
kubectl -n workloads delete pod intruder-workload
```

(`k8s/7_forged_certificate_test.yaml` runs a stricter variant of this test —
a certificate that isn't signed by the SPIRE CA at all, rather than one with
the wrong identity — and confirms it's rejected at the TLS handshake layer,
before the request ever reaches the application. Registering its entry and
reading it follows the same pattern as step 8.)

## Cleanup

```bash
kind delete cluster --name geic-cluster
```

This removes the cluster and everything running in it, including the built
images loaded onto its nodes (your local `docker images` copies are
unaffected).
