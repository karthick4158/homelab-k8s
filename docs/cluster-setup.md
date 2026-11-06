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

### Home Assistant metrics

- HA's `prometheus:` integration (`apps/home-assistant/config/configuration.yaml`) exports only
  the curated entities listed there at `/api/prometheus`. Add an entity there to graph it.
- `apps/home-assistant/servicemonitor.yaml` scrapes the `home-assistant` Service (port `http`,
  8123) every 60s with a Bearer token from Secret `ha-prometheus-token` (key `token`), made by
  `apps/home-assistant/ha-prometheus-token.sops.yaml`.
- Token: in HA, profile > Security > Long-lived access tokens > Create. Then, from the repo root
  (zsh; reads the token without echoing it, skips an empty input):
  `read -rs 'TOKEN?HA token: '; echo; [[ -n $TOKEN ]] && printf '%s' "$TOKEN" | jq -Rs . | sops set --value-stdin apps/home-assistant/ha-prometheus-token.sops.yaml '["spec"]["secretTemplates"][0]["stringData"]["token"]'; unset TOKEN`
  Commit and push.
- Grafana dashboard "Home": `infrastructure/monitoring/dashboards/home.json`, shipped as ConfigMap
  `grafana-dashboard-home` (label `grafana_dashboard: "1"`) that the Grafana sidecar loads.
  HA exports temperatures in Celsius; the panels convert to °F.

### Proxmox metrics

- prometheus-pve-exporter 3.11.0 (`infrastructure/monitoring/pve-exporter.yaml`, ns `monitoring`,
  on k8s-worker-1) reads the Proxmox API at https://10.0.0.66:8006 (self-signed, so
  `PVE_VERIFY_SSL=false`) with the read-only API token `monitoring@pve!grafana`.
- `infrastructure/monitoring/pve-servicemonitor.yaml` scrapes `/pve` every 60s with
  `module=default`, `target=10.0.0.66`, `cluster=1`, `node=1`; `instance` is set to 10.0.0.66.
- Token value: Secret `pve-exporter-token` (key `PVE_TOKEN_VALUE`), made by
  `infrastructure/monitoring/pve-exporter-token.sops.yaml` (committed with an encrypted placeholder).
- Proxmox side (once), in the Proxmox UI:
  1. Datacenter > Permissions > Users > Add: user `monitoring`, Realm "Proxmox VE authentication
     server" (`monitoring@pve`). No password needed.
  2. Datacenter > Permissions > API Tokens > Add: user `monitoring@pve`, Token ID `grafana`, leave
     Privilege Separation checked. Copy the secret (shown once).
  3. Datacenter > Permissions > Add > API Token Permission: path `/`, token `monitoring@pve!grafana`,
     role `PVEAuditor`, Propagate checked.
- Then, from the repo root (zsh; reads the token without echoing it, skips an empty input):
  `read -rs 'TOKEN?PVE token: '; echo; [[ -n $TOKEN ]] && printf '%s' "$TOKEN" | jq -Rs . | sops set --value-stdin infrastructure/monitoring/pve-exporter-token.sops.yaml '["spec"]["secretTemplates"][0]["stringData"]["PVE_TOKEN_VALUE"]'; unset TOKEN`
  Commit and push. The exporter reads the token at startup:
  `kubectl -n monitoring rollout restart deployment pve-exporter`.
- Grafana dashboard "Proxmox": `infrastructure/monitoring/dashboards/proxmox.json`, ConfigMap
  `grafana-dashboard-proxmox` (label `grafana_dashboard: "1"`). Host CPU/memory/uptime, guests
  (names from `pve_guest_info`), storage usage by storage name, guests without a backup job. The
  exporter has no last-backup-time metric.

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

## Media downloads (VPN)

- `apps/media/downloads.yaml`: one pod with qBittorrent, Transmission, Radarr, Sonarr and Seerr
  behind one gluetun VPN sidecar (`components/gluetun`). Each app has its own config PVC, Service
  and HTTPRoute in its own file. Web UI ports must be listed in `FIREWALL_INPUT_PORTS`
  (`apps/media/kustomization.yaml`, now `8080,7878,8989,5055,9091,9999`).

### Checking the VPN

- `scripts/vpn-check.sh` (run from the Mac) finds the running `downloads` pod over
  `ssh k8s@10.0.0.88 kubectl` (override with `SSH_TARGET=...`, or `SSH_TARGET=""` for a local
  kubectl), asks every running container (gluetun and each app; the one-shot `transmission-seed`
  is skipped) for its public IP via `https://api.ipify.org` (curl, else wget), and prints them
  next to this machine's home public IP. Read-only.
- Verdict: **OK** = every successful lookup shows the same IP and it is not the home IP (traffic
  goes through the VPN). **LEAK** (exit 1) = a container is seen as the home IP. **WARN** (exit
  2) = containers show different IPs, no lookup succeeded, or the home IP could not be fetched.
- Argo CD only shows what is deployed and whether it is healthy; it cannot display live data like
  the pod's public IP, so use this script for that.

### Transmission

- https://transmission.homelab.lan (`apps/media/transmission.yaml`), LinuxServer image, web UI on
  9091, config on a 500Mi local-path PVC, library mounted at `/data` like qBittorrent. Needs a DNS
  record `transmission.homelab.lan -> 10.0.0.89` in Pi-hole and AdGuard.
- Downloads go to `/data/data/downloads/transmission/completed` (in progress:
  `/data/data/downloads/transmission/incomplete`), mirroring qBittorrent's
  `/data/data/downloads/qbittorrent/{completed,incomplete}`. These two paths (and
  `incomplete-dir-enabled: true`) are enforced from Git on every pod start: the
  `transmission-seed` init container seeds `settings.json` from the image defaults if it is
  missing, then rewrites only those three keys. Changing the folders in the web UI lasts only until
  the next restart; change them in `apps/media/downloads.yaml` instead. All other settings
  (password, speed limits, peers) are saved normally by Transmission and kept. Transmission creates
  the folders itself.
- Peer port 51413 (`PEERPORT`); qBittorrent keeps its image default 6881, so they do not clash in
  the shared network namespace. Neither port is forwarded through the VPN (outbound peers only).
- No password by default: anyone on the LAN who reaches the hostname can use it. To add one later,
  create `apps/media/transmission-auth.sops.yaml`, a `SopsSecret` (namespace `media`) with a
  secret `transmission-auth` holding `stringData` keys `USER` and `PASS`, encrypt it with
  `sops -e -i`, add it to `apps/media/kustomization.yaml`, and give the `transmission` container
  `envFrom: [{secretRef: {name: transmission-auth}}]`. The image applies USER/PASS on every start.
- Radarr/Sonarr: Settings > Download Clients > add Transmission, host `localhost`, port `9091`
  (same pod), URL base `/transmission/`, plus the username/password once they are set.

### Profilarr

- https://profilarr.homelab.lan (`apps/media/profilarr.yaml`), syncs quality profiles and custom
  formats to Radarr/Sonarr. Profilarr v2, image `ghcr.io/dictionarry-hub/profilarr:2.3.1`, web UI
  on 6868 (listed in `FIREWALL_INPUT_PORTS`), data in `/config` on the 1Gi local-path PVC
  `profilarr-data` (v2 keeps git clones of the profile databases). Runs with PUID 1000 / PGID 100 /
  UMASK 002 like the arr containers. Same pod, so it reaches Radarr at `localhost:7878` and Sonarr
  at `localhost:8989`. Needs a DNS record `profilarr.homelab.lan -> 10.0.0.89` in Pi-hole and
  AdGuard.
- `ORIGIN=https://profilarr.homelab.lan` is set because it sits behind the reverse proxy (Traefik);
  the v2 README marks it required in that setup. Add more URLs comma-separated if it is ever
  reached by another name.
- Built-in login (`AUTH` left at its default `on`): the admin user is created on the first visit.
- v1 (`santiagosayshey/profilarr`) was dropped: it is unmaintained, and its data is not compatible
  with v2, hence the new PVC.
- Cleanup: the old v1 PVC `profilarr-config` is left behind. Once the pod runs on the new one,
  delete it with `kubectl -n media delete pvc profilarr-config`.

### Rename and move job (mkv-rename)

- CronJob `mkv-rename` (`apps/media/mkv-rename.yaml`) runs `apps/media/mkv-rename.sh` (shipped
  as a generated ConfigMap) every 5 minutes in a `busybox:1.37.0` pod as uid 1000 / gid 100, with
  the library mounted at `/data` like qBittorrent. It renames each
  `<anything> - Title (YYYY)<anything>.mkv` in `SOURCE_DIR` to `Title (YYYY).mkv` and moves it to
  `TARGET_DIR`. It never overwrites (prints `Skipped, target exists`), leaves files modified in
  the last 2 minutes alone (still being written) and skips names without a `(YYYY)` match
  (`No match, skipped`). Only `.mkv` files directly in `SOURCE_DIR` are handled, not subfolders.
- Set `SOURCE_DIR` and `TARGET_DIR` in `apps/media/mkv-rename.yaml` (the `value:` lines right
  under lines 45 and 47, marked `# K: set these two paths`). Until neither contains `CHANGE_ME`,
  every run fails with an error. A missing `SOURCE_DIR` also fails; `TARGET_DIR` is created.
- Schedule `*/5 * * * *`, one run at a time (`concurrencyPolicy: Forbid`), no retries, a run is
  killed after 30 minutes; the last 3 successful and 3 failed Jobs are kept.
- Output: the Job's pod logs in Headlamp (namespace `media`), or
  `kubectl -n media get jobs` then `kubectl -n media logs job/<name>`.
- Run once now: `kubectl -n media create job --from=cronjob/mkv-rename mkv-rename-manual` (delete
  it afterwards with `kubectl -n media delete job mkv-rename-manual` before reusing the name).
- Pause: add `suspend: true` under `spec:` in `apps/media/mkv-rename.yaml`, commit and push
  (Argo CD would revert a `kubectl patch`). Remove it to resume.
- Alternative: Radarr/Sonarr can rename on import themselves (Settings > Media Management >
  Rename Movies/Episodes), which makes this job unnecessary for anything they download.

## Tools (Omni Tools, IT-Tools)

- Two stateless browser tool sites, each in its own namespace with one replica, no storage and no
  login: Omni Tools (`iib0011/omni-tools`) at omni-tools.homelab.lan and IT-Tools
  (`corentinth/it-tools`) at it-tools.homelab.lan. Manifests in `apps/omni-tools/` and
  `apps/it-tools/`, Argo apps in `argocd-apps/`, cards in the Homepage "Tools" group.

## ESPHome

- Dashboard at esphome.homelab.lan (`apps/esphome/`, Argo app `argocd-apps/esphome.yaml`, card in
  the Homepage "Home" group). This is a second ESPHome instance; the one on VM 101 is untouched.
- Pods can't use mDNS, so devices must be reached by IP (give them static IPs / DHCP reservations)
  for OTA and status. `ESPHOME_DASHBOARD_USE_PING=true` makes status use ping instead of mDNS.
- Config lives in the `esphome-config` PVC (2Gi, local-path) at `/config`. The old config from
  VM 101 can be copied in later (`kubectl cp`) by K.

## Home Assistant

- `apps/home-assistant/`, Argo app `argocd-apps/home-assistant.yaml`, route ha.homelab.lan.
  Image pinned to `ghcr.io/home-assistant/home-assistant:2026.11.0`.
- Runs with `hostNetwork: true` pinned to k8s-worker-1 so LAN discovery (mDNS/SSDP) works. The
  ConBee Zigbee stick is passed through in Proxmox to VM 202 and mounted at `/dev/ttyACM0`
  (container is privileged for it). Config in the `home-assistant-config` PVC (10Gi, local-path).
- Starts at `replicas: 0`; the instance on VM 101 stays live. Argo self-heal reverts
  `kubectl scale`, so the replica count only changes in Git.
- The Homepage Home Assistant card still points at the old instance; update it at cutover.

Cutover outline:

1. On VM 101, stop the `homeassistant`, `restarter_ha` and `watchtower` containers.
2. Copy the old HA config into the `home-assistant-config` PVC.
3. In Proxmox, move the ConBee USB device from VM 101 to VM 202; check `/dev/ttyACM0` exists on
   k8s-worker-1.
4. Set `replicas: 1` in `apps/home-assistant/home-assistant.yaml`, commit, push, let Argo sync.

HA rejects proxied requests unless Traefik is trusted. `configuration.yaml` needs:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 10.0.0.89
    - 10.244.0.0/16
```

HA config in Git:

- `configuration.yaml` lives in `apps/home-assistant/config/`. Kustomize turns it into the
  `ha-config` ConfigMap, mounted read-only with `subPath` at `/config/configuration.yaml` over
  the PVC copy. HA's file editor can't save it.
- Edit workflow: edit the file in the repo, commit, push; Argo syncs, the ConfigMap hash changes
  and the pod restarts with the new config. A broken file puts HA in recovery mode; fix or
  revert it in Git.
- Stay on the PVC on purpose (HA's UI writes them): `automations.yaml`, `scripts.yaml`,
  `scenes.yaml`, `groups.yaml`, `.storage/`, `themes/`, `govee_learning.yaml`, the databases.
- `secrets.yaml` stays on the PVC and is never in Git; use `!secret name` in the Git copy and
  add the value to `/config/secrets.yaml` on the PVC.
- To add another hand-edited file (e.g. a `packages/` dir), add it under `config/`, add it to the
  generator (separate generator for a directory, mounted at `/config/<dir>`), and mount it.

## Updating images by hand

- Versions live in the repo: container image tags in the `image:` lines under `apps/` and
  `components/`, Helm chart versions in `targetRevision` in `argocd-apps/*.yaml`.
- Run `scripts/check-updates.sh --dry-run` from the Mac to only list what is outdated (asks public
  registries and Helm repo indexes, never the cluster). Images on `latest`, digest-pinned or in the
  private `ghcr.io/karthick4158/` registry are listed as skipped.
- Run `scripts/check-updates.sh` to apply updates: it prints a numbered table (`!! major` = major
  jump, `careful` = gluetun/plex/argo-cd/traefik/kube-prometheus-stack), asks which numbers to
  apply (`a` = all non-major, `q` = quit), edits the files, shows the diff, then asks `Commit?`
  (one commit per app, `<app>: update <old> -> <new>`) and `Push now?`. Argo CD only syncs after
  the push. Read the release notes before picking anything marked major or careful.
- Roll back: `git revert <commit>` and push.

## Open items

- MetalLB IP range (outside router DHCP pool) – to decide.
- Argo CD read-only deploy key for this repo.
- Cilium 1.20.1 -> 1.20.4 patch upgrade.
- VMs 201/202 `onboot` still 0.
- VM 105 (pihole) has no backup job.
