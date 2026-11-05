# Restore Home Assistant from an encrypted backup

Snapshots are made by `scripts/backup-ha.sh` and stored in `backups/ha/`
as `ha-config-YYYY-MM-DD.tar.gz.age` (tar of `/config`, encrypted with age to
the recipient in `.sops.yaml`). The newest 3 are kept.

**Not in the backup:** recorder history (`home-assistant_v2.db*`), logs,
`tts/`, `backups/`, `deps/`, `__pycache__/`. History starts empty after a restore.
`configuration.yaml` also lives in Git at `apps/home-assistant/config/` and is
mounted over the PVC copy from a ConfigMap, so the Git version wins.

## Prerequisites

- `age` installed on the Mac (`brew install age`).
- The age private key from K's password manager, saved to a temporary file
  (e.g. `~/ha-restore.key`, `chmod 600`). Delete it when done.
- SSH access to `k8s@10.0.0.88`.

## Steps

1. **Stop HA via Git** (Argo self-heal reverts `kubectl scale`):
   set `replicas: 0` in `apps/home-assistant/home-assistant.yaml`, commit, push.
   Wait until the pod is gone:

   ```bash
   ssh k8s@10.0.0.88 'kubectl -n home-assistant get pods -w'
   ```

2. **Start a helper pod as root** mounting the PVC (RWO, so it must run on
   `k8s-worker-1`, same node as HA):

   ```bash
   ssh k8s@10.0.0.88 'kubectl apply -f -' <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: ha-restore
     namespace: home-assistant
   spec:
     nodeSelector:
       kubernetes.io/hostname: k8s-worker-1
     securityContext:
       runAsUser: 0
     containers:
       - name: shell
         image: busybox:1.37
         command: ["sleep", "3600"]
         volumeMounts:
           - name: config
             mountPath: /config
     volumes:
       - name: config
         persistentVolumeClaim:
           claimName: home-assistant-config
   EOF
   ssh k8s@10.0.0.88 'kubectl -n home-assistant wait --for=condition=Ready pod/ha-restore --timeout=120s'
   ```

3. **Decrypt and extract** (plaintext only ever exists in the pipe):

   ```bash
   age -d -i ~/ha-restore.key backups/ha/ha-config-YYYY-MM-DD.tar.gz.age \
     | ssh k8s@10.0.0.88 'kubectl -n home-assistant exec -i ha-restore -- tar xzf - -C /config'
   ```

   Check, then remove the helper:

   ```bash
   ssh k8s@10.0.0.88 'kubectl -n home-assistant exec ha-restore -- ls -la /config /config/.storage'
   ssh k8s@10.0.0.88 'kubectl -n home-assistant delete pod ha-restore'
   ```

4. **Start HA via Git:** set `replicas: 1`, commit, push. Delete `~/ha-restore.key`.

5. **Verify:**
   - Argo CD: `home-assistant` app is Synced / Healthy.
   - Zigbee: ZHA (ConBee at `/dev/ttyACM0`, passed through to VM 202) is
     online and devices respond.
   - HomeKit bridge: accessories respond in the Home app (re-pair only if not).
   - UI at https://ha.homelab.lan loads and logins work.
