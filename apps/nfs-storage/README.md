# nfs-storage

Dynamic PVC provisioning backed by the Synology NAS via NFS. Creates a default
`StorageClass` named `nfs-nas`. Every PVC bound to it gets its own subdirectory
on the share.

- NAS: `192.168.4.10`
- Export: `/volume1/k8s-storage`

## One-time Synology setup

1. **Control Panel → Shared Folder → Create**
   - Name: `k8s-storage`
   - Location: `volume1`
   - Disable recycle bin
2. **Control Panel → File Services → NFS** — enable NFS, NFSv4.1 on.
3. **Shared Folder → `k8s-storage` → Edit → NFS Permissions → Create**
   - Hostname / IP: `192.168.4.0/24`
   - Privilege: **Read/Write**
   - Squash: **Map all users to admin** (equivalent of `no_root_squash` for our use)
   - Security: `sys`
   - Async: **Enabled**
   - Allow connections from non-privileged ports: **Enabled**
   - Allow users to access mounted subfolders: **Enabled**
4. Verify export path matches: `/volume1/k8s-storage`.

## Vendor the upstream chart

```bash
cd apps/nfs-storage
helm dependency update
git add Chart.lock charts/
```

## Verifying

```bash
kubectl get storageclass            # expect nfs-nas (default)
kubectl -n nfs-storage get pod      # provisioner pod Running

# throwaway PVC
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: smoke, namespace: default }
spec:
  accessModes: [ReadWriteMany]
  resources: { requests: { storage: 1Gi } }
EOF

kubectl get pvc smoke               # should be Bound within seconds
kubectl delete pvc smoke
```

On the NAS, the subdir `default-smoke` will appear under `k8s-storage/`. With
`archiveOnDelete: true` it's renamed to `archived-default-smoke-...` rather
than removed — safe default for a homelab.
