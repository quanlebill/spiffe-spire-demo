# Deployment runbook

Three clusters: `geic-root` holds the identity plane (OpenBao + root SPIRE server);
`geic-a` and `geic-b` are symmetric workload clusters.
---

## 0. Prerequisites

- Docker with **~7 GB** available to the daemon (six kind nodes, ~6 GB in steady state)
- `kind` ≥ 0.32, `kubectl`, and `istioctl` 1.30.x, all on `PATH`
- Internet access to pull Calico, SPIRE, OpenBao, PostgreSQL and Istio images

### Resource reality: three etcd instances on one disk

Three kind clusters means three etcd instances writing to the same virtual disk. On Docker
Desktop this is the binding constraint, and it is *not* CPU or memory. Measured on this
setup while the test suite was running:

```
CPU        8–18% per node          ← fine
Memory     5.7 GB / 7.6 GB (75%)   ← fine
etcd       98 × "apply request took too long"  (up to 449 ms vs 100 ms expected)
```

When etcd falls behind, `kube-scheduler` and `kube-controller-manager` cannot renew their
5-second leader leases and crash-loop. The symptoms are actively misleading:

| Symptom | Actual cause |
|---|---|
| Pods stuck `Pending` with **no Events** | scheduler is down, nothing is scheduling |
| `kubectl exec` fails with `context deadline exceeded` | kubelet / API server backed up |
| `spire-server entry show` returns nothing | the exec failed — the entries are fine |
| Deployment rollouts time out | new pods never get scheduled |

None of these mean SPIRE or Istio is misconfigured. Check
`kubectl -n kube-system get pods` on the affected cluster first — if the scheduler is
`CrashLoopBackOff`, let the cluster go idle and it recovers on its own.

To reduce pressure: give Docker more disk throughput (or use a Linux host with an SSD),
and do not run the test suite while a deployment stage is still running.

---

## Quick start

```bash
bash scripts/deploy-all.sh
```

Then verify it by working through [testing.md](testing.md), which is grouped by enforcement
layer.

```bash
bash scripts/clean.sh
```

`deploy-all.sh` runs stages 01–08 in order. Expect roughly 20–30 minutes on a cold start,
most of it pulling and side-loading images.

---

## The stages

| Script | What it does |
|---|---|
| `01-create-clusters.sh` | Creates all three kind clusters with the default CNI disabled, untaints the `geic-root` and `geic-b` control-planes, and rewrites every NetworkPolicy `ipBlock` to match this machine's kind docker network |
| `02-install-cni.sh` | Renders and installs Calico per cluster with the right pod CIDR, fixes interface autodetection, and disables IPIP |
| `03-build-and-load-images.sh` | Builds the three workload images, pulls the Istio images once, exports them as single-platform archives, side-loads everything into the two workload clusters |
| `04-deploy-openbao.sh` | Deploys OpenBao with file storage on a PVC, initialises and unseals it, mints the root CA, and enables the Kubernetes auth method with a `sign-intermediate`-only role |
| `05-deploy-spire-root.sh` | Creates read-only attestation kubeconfigs for both workload clusters, deploys the root SPIRE server, registers both downstream CAs |
| `06-deploy-spire-nested.sh` | Publishes the trust bundle and root endpoint to both clusters, deploys PostgreSQL, the replicated nested servers, agents and the SPIFFE CSI driver |
| `07-install-istio.sh` | Installs Istio with the `spire` injection template so `istio-agent` uses SPIRE for SDS instead of istiod's CA |
| `08-deploy-workloads.sh` | Registers workload identities, deploys the service packs, mesh policies and NetworkPolicies, wires the cross-cluster endpoint, and deploys the intruder pods the test suite uses |

Run any stage on its own:

```bash
bash scripts/06-deploy-spire-nested.sh
```
---
