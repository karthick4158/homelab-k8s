# Restore Vaultwarden from an encrypted backup

Snapshots are made by `scripts/backup-vaultwarden.sh` and stored in
`backups/vaultwarden/` as `vaultwarden-data-YYYY-MM-DD.tar.gz.age` (tar of
`/data`, encrypted with age to the recipient in `.sops.yaml`). The newest 3 are kept.

**Not in the backup:** `icon_cache/` and `tmp/` (rebuilt on demand).
The SQLite DB is copied while Vaultwarden runs, together with its `-wal` file;
for a guaranteed-consistent copy, stop Vaultwarden (step 1) before backing up.

## Prerequisites

- `age` installed on the Mac (`brew install age`).
- The age private key from K's password manager, saved to a temporary file
  (e.g. `~/vw-restore.key`, `chmod 600`). Delete it when done.
  Keep that key somewhere other than Vaultwarden itself.
- SSH access to `k8s@10.0.0.88`.

## Steps

1. **Stop Vaultwarden via Git** (Argo self-heal reverts `kubectl scale`):
   set `replicas: 0` in `apps/vaultwarden/vaultwarden.yaml`, commit, push.
   Wait until the pod is gone:

   ```bash
   ssh k8s@10.0.0.88 'kubectl -n vaultwarden get pods -w'
   ```

2. **Start a helper pod** mounting the PVC. The local-path volume is tied to
   one node, and the scheduler places the pod there on its own:

   ```bash
   ssh k8s@10.0.0.88 'kubectl apply -f -' <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: vw-restore
     namespace: vaultwarden
   spec:
     containers:
       - name: shell
         image: busybox:1.37
         command: ["sleep", "3600"]
         volumeMounts:
           - name: data
             mountPath: /data
     volumes:
       - name: data
         persistentVolumeClaim:
           claimName: vaultwarden-data
   EOF
   ssh k8s@10.0.0.88 'kubectl -n vaultwarden wait --for=condition=Ready pod/vw-restore --timeout=120s'
   ```

3. **Remove the current DB files** (so an old `-wal` can't mix with the
   restored DB), then **decrypt and extract** (plaintext only ever exists in the pipe):

   ```bash
   ssh k8s@10.0.0.88 'kubectl -n vaultwarden exec vw-restore -- sh -c "rm -f /data/db.sqlite3 /data/db.sqlite3-wal /data/db.sqlite3-shm"'
   age -d -i ~/vw-restore.key backups/vaultwarden/vaultwarden-data-YYYY-MM-DD.tar.gz.age \
     | ssh k8s@10.0.0.88 'kubectl -n vaultwarden exec -i vw-restore -- tar xzf - -C /data'
   ```

   Check, then remove the helper:

   ```bash
   ssh k8s@10.0.0.88 'kubectl -n vaultwarden exec vw-restore -- ls -la /data'
   ssh k8s@10.0.0.88 'kubectl -n vaultwarden delete pod vw-restore'
   ```

4. **Start Vaultwarden via Git:** set `replicas: 1`, commit, push. Delete `~/vw-restore.key`.

5. **Verify:**
   - Argo CD: `vaultwarden` app is Synced / Healthy.
   - https://vaultwarden.homelab.lan loads, K can log in and the vault items are there.
