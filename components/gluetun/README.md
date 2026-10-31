# Gluetun VPN component

Gluetun (Surfshark WireGuard) as a native sidecar: the app's traffic goes through the VPN, with a kill switch.

## Put an app behind the VPN

1. Label its Deployment (in `metadata.labels`): `vpn: gluetun`.
2. In the app's `kustomization.yaml`:
   ```yaml
   namespace: <app namespace>  # needed so the generated ConfigMaps land there
   components: [../../components/gluetun]
   configMapGenerator:
     - name: gluetun-app
       literals:
         - FIREWALL_INPUT_PORTS=<app ports>,9999  # 9999 = gluetun health probes
   ```
3. Add a `gluetun-vpn.sops.yaml` in the app's namespace: copy the structure of
   `apps/media/gluetun-vpn.sops.yaml` (used by qBittorrent only),
   change the namespace, fill it with `sops`.

Several apps in one pod (one VPN connection): put all their containers in a
single Deployment and list all their ports in `FIREWALL_INPUT_PORTS`.

## Changing the gluetun version or VPN country

Only here: image tag in `sidecar.yaml`, `SERVER_COUNTRIES` in `kustomization.yaml`.
