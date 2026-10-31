# Cluster setup record (2026-10-29)

## Proxmox

- Host `proxmox`, 10.0.0.66, Proxmox VE 9.2.21, bridge `vmbr0`, gateway 10.0.0.1.
- Existing VMs 101, 105, 106 are not part of this cluster and were not touched.
- Image: Debian 13 (trixie) generic cloud image, `debian-13-generic-amd64.qcow2`, SHA512 verified,
  stored at `/var/lib/vz/template/cloud/` on the host.

## VMs

Both: q35, cpu `host`, virtio-scsi-single (iothread, discard, ssd), virtio NIC on `vmbr0` (firewall=1),
qemu-guest-agent, cloud-init user `k8s` (SSH key only, passwordless sudo), DHCP with router reservations,
`onboot: 0`.

| VMID | Name | vCPU | RAM | Disk | MAC | IP |
|---|---|---|---|---|---|---|
| 201 | k8s-cp-1 | 2 | 3072 MB | 40 GB | BC:24:11:C8:8A:02 | 10.0.0.88 |
| 202 | k8s-worker-1 | 6 | 8192 MB | 120 GB | BC:24:11:AC:4A:23 | 10.0.0.89 |

Backup: Proxmox job for 201,202 at 03:00 to `PVEBackUpDisk`, zstd, snapshot mode, keep-daily=7, keep-weekly=4.

## Node prep (both nodes)

- Swap off; modules `overlay`, `br_netfilter` (`/etc/modules-load.d/k8s.conf`).
- sysctls in `/etc/sysctl.d/99-k8s.conf`: `net.ipv4.ip_forward=1`, `net.bridge.bridge-nf-call-ip{,6}tables=1`.
- containerd.io 2.4.2 from download.docker.com (Debian trixie), held. Config regenerated with
  `containerd config default`, `SystemdCgroup = true`, sandbox `registry.k8s.io/pause:3.10.2`.
  (Debian's containerd 1.7 lacks the CRI RuntimeConfig method needed by kubeadm 1.37+.)
- kubelet, kubeadm, kubectl v1.37.2 from `pkgs.k8s.io/core:/stable:/v1.37/deb/`, held.

## Cluster

```
kubeadm init --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=10.0.0.88 \
  --control-plane-endpoint=10.0.0.88:6443 --node-name k8s-cp-1
```

- Worker joined with `kubeadm join 10.0.0.88:6443 ... --node-name k8s-worker-1`
  (new token: `kubeadm token create --print-join-command` on cp-1).
- kube-proxy: default (not replaced by Cilium).
- CNI: Cilium v1.20.1 via cilium-cli v0.20.1,
  `cilium install --set ipam.mode=cluster-pool --set ipam.operator.clusterPoolIPv4PodCIDRList=10.244.0.0/16`.
- Argo CD v3.5.6:
  `kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/install.yaml`

## Reaching Argo CD

- UI: https://argocd.homelab.lan (Traefik, `*.homelab.lan` wildcard cert), user `admin`.
  Initial password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
- CLI through Traefik needs gRPC-web: `argocd login argocd.homelab.lan --grpc-web`.
- The `argocd` app (`argocd-apps/argocd.yaml` -> `infrastructure/argocd/`) adds the HTTPRoute, the
  `gateway-access: "true"` label on the `argocd` namespace, and `server.insecure: "true"` in
  `argocd-cmd-params-cm` (Traefik terminates TLS). The install itself is still the manual one above;
  the namespace and ConfigMap are marked `Prune=false,Delete=false`.
- argocd-server reads `argocd-cmd-params-cm` only at startup. After changing it:
  `kubectl -n argocd rollout restart deployment argocd-server`.
- Fallback without Traefik: `kubectl -n argocd port-forward svc/argocd-server 8080:80`, then http://localhost:8080.

## Secrets (SOPS + age)

- sops-secrets-operator (`argocd-apps/sops-operator.yaml`) decrypts `SopsSecret` resources in-cluster.
- age private key: on K's Mac at `~/Library/Application Support/sops/age/keys.txt`, backup in K's
  password manager. Cluster copy is secret `sops/sops-age-key-file` (key `key`), created by hand.
- To add a secret: write a `SopsSecret` (`apiVersion: isindir.github.com/v1alpha3`) with `stringData`
  in a file named `*.sops.yaml`, run `sops -e -i file.sops.yaml`, commit. Rules are in `.sops.yaml`:
  only `data`/`stringData` values are encrypted, to K's age public key. Example:
  `apps/media/gluetun-vpn.sops.yaml`.
- Never commit an unencrypted secret.

## Monitoring

- kube-prometheus-stack 92.16.1 (`argocd-apps/monitoring.yaml`, Helm values inline): Prometheus,
  Alertmanager, Grafana, node-exporter, kube-state-metrics, Prometheus Operator.
- `argocd-apps/monitoring-extras.yaml` -> `infrastructure/monitoring/`: the `monitoring` namespace
  (`gateway-access: "true"`, `Delete=false`), the `grafana-admin` SopsSecret and the HTTPRoute.
- Grafana: https://grafana.homelab.lan, user `admin`. Needs a DNS record
  `grafana.homelab.lan -> 10.0.0.89` in Pi-hole and AdGuard.
- Grafana password: `sops infrastructure/monitoring/grafana-admin.sops.yaml`, replace
  `admin-password`, save (re-encrypts), commit, push. Grafana reads it at startup:
  `kubectl -n monitoring rollout restart deployment monitoring-grafana`.
- Prometheus: 15 days / 8 GB retention on a 10Gi local-path volume; Grafana on 2Gi.
- node-exporter listens on 9101, not 9100: Traefik already holds host port 9100 on k8s-worker-1
  (hostNetwork), and node-exporter runs on the host network too.
- etcd, scheduler, controller-manager and kube-proxy are not scraped (kubeadm binds their metrics
  to 127.0.0.1); their rules are off.
- Alertmanager has no notification channel yet (all alerts go to the `null` receiver).
- Fallback without Traefik: `kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80`.

### Headlamp

- Kubernetes web UI (pods, logs, events, nodes, workloads). Chart 0.46.0
  (`argocd-apps/headlamp.yaml`), one pod on k8s-worker-1.
- `argocd-apps/headlamp-extras.yaml` -> `infrastructure/headlamp/`: the `headlamp` namespace
  (`gateway-access: "true"`), the HTTPRoute and the `headlamp-admin` ServiceAccount.
- URL: https://headlamp.homelab.lan. Needs a DNS record `headlamp.homelab.lan -> 10.0.0.89` in
  Pi-hole and AdGuard.
- Login: paste a ServiceAccount token. Get one (valid 24h) with
  `kubectl -n headlamp create token headlamp-admin --duration=24h`. Never commit tokens.
- Read-only: `headlamp-admin` is bound to the built-in `view` ClusterRole (no Secrets, no
  changes, no exec). The chart's own cluster-admin binding is turned off; the Headlamp pod acts
  only with the token you log in with.
- Edit rights later: in `infrastructure/headlamp/serviceaccount.yaml` change `roleRef.name` from
  `view` to `edit` (or `admin`/`cluster-admin`), and the binding name with it (`roleRef` cannot be
  changed in place, so Argo CD replaces the binding when the name changes). Commit, push, get a new
  token.
- Pod logs are viewed live in Headlamp; no log history is kept, deliberately. Loki + Alloy were
  removed on 2026-10-31 to save RAM/disk; re-add them from git history (commit 87d7ce4).
- Fallback without Traefik: `kubectl -n headlamp port-forward svc/headlamp 4466:80`, then
  http://localhost:4466.

## Updating images by hand

- Versions live in the repo: container image tags in the `image:` lines under `apps/` and
  `components/`, Helm chart versions in `targetRevision` in `argocd-apps/*.yaml`.
- Run `scripts/check-updates.sh` from the Mac. It is read-only (asks public registries only, never
  the cluster) and prints pinned vs newest version per image and chart; `?` means the lookup failed.
- Read the release notes, then edit the tag/`targetRevision`. One app per commit, e.g.
  `git commit -m "Bump radarr to 6.4.5.x-ls322"`, then `git push`; Argo CD syncs it.
- Roll back: `git revert <commit>` and push.

## Open items

- MetalLB IP range (outside router DHCP pool) – to decide.
- Argo CD read-only deploy key for this repo.
- Cilium 1.20.1 -> 1.20.4 patch upgrade.
- VMs 201/202 `onboot` still 0.
- VM 105 (pihole) has no backup job.
