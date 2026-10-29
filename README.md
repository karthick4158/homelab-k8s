# homelab-k8s

GitOps repo for the homelab Kubernetes cluster on Proxmox. Argo CD syncs this repo into the cluster.

## Cluster

| Node | VMID | IP | Role | vCPU / RAM / Disk |
|---|---|---|---|---|
| k8s-cp-1 | 201 | 10.0.0.88 | control plane | 2 / 3 GB / 40 GB |
| k8s-worker-1 | 202 | 10.0.0.89 | worker | 6 / 8 GB / 120 GB |

Proxmox host: 10.0.0.66. Details and versions: [docs/cluster-setup.md](docs/cluster-setup.md).

## Layout

- `bootstrap/` – `root-app.yaml`, the only thing applied by hand.
- `argocd-apps/` – one Argo CD `Application` per component; the root app watches this folder.
- `infrastructure/` – cluster services (MetalLB, ingress, cert-manager, ...).
- `apps/` – workloads.
- `docs/` – how the cluster was built and how to rebuild it.

## Rules

1. No plain secrets in this repo. Use Sealed Secrets or SOPS (to be added).
2. Pin every version: chart versions, image tags, manifest URLs. Never `latest` or `stable`.
3. Change the cluster through Git, not `kubectl edit`. Argo CD self-heals drift.

## Bootstrap

1. Argo CD installed (v3.5.6, see docs).
2. Add a read-only deploy key for this repo to Argo CD.
3. `kubectl apply -n argocd -f bootstrap/root-app.yaml`
