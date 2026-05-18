# immich

Self-hosted photo & video backup at `https://immich.home.daandewilde.be`.

Built on the upstream `immich-app/immich-charts` chart, with a small in-repo
Postgres Deployment (the upstream chart deliberately doesn't ship one — it
requires a Postgres image with the `vectorchord` extension).

## Components

| Piece | Backed by |
| --- | --- |
| Photo library | `immich-library` PVC on `nfs-nas` (RWX, 1Ti) |
| Postgres data | `immich-postgres-data` PVC on `nfs-nas` (20Gi) |
| Valkey queue | `emptyDir` (queue is ephemeral; rebuilt on restart) |
| ML model cache | PVC on `nfs-nas` (10Gi) — keeps models across restarts |
| Ingress | Traefik IngressRoute, wildcard cert from `cert-manager` |

> Running Postgres on NFS is acceptable for a homelab but not ideal — fsync
> semantics differ from local storage. If you start seeing DB latency or
> corruption warnings, move the postgres PVC to a local-path storage class.

## Vendor the upstream chart

```bash
cd apps/immich
helm dependency update
git add Chart.lock charts/
```

## First-time setup

1. **Seal the Postgres password.** `templates/postgres-password-sealedsecret.yaml`
   ships with a `REPLACE_ME_WITH_KUBESEAL_OUTPUT` placeholder. Generate the
   real ciphertext against your cluster's controller:

   ```bash
   echo -n 'your-strong-password' | kubeseal \
     --controller-name sealed-secrets-controller \
     --controller-namespace sealed-secrets \
     --raw \
     --namespace immich \
     --name immich-postgres
   ```

   Paste the output as the `password:` value under `encryptedData`. The
   decrypted Secret will be `immich-postgres` (key `password`), which is what
   both the postgres pod and the immich-server reference.

2. **Pre-size the library PVC.** 1Ti is the default — adjust
   `values.yaml → library.size` before the first sync if you need something
   different. Resizing later requires manual NFS work.
3. Commit and let ArgoCD sync. The ApplicationSet will pick up `apps/immich`
   and create the namespace.
4. Open `https://immich.home.daandewilde.be` and create the admin user. Immich
   doesn't ship a default account — first signup becomes admin.

## Verifying

```bash
kubectl -n immich get pod,svc,pvc

# Library + DB volumes bound
kubectl -n immich get pvc immich-library immich-postgres-data

# DB reachable
kubectl -n immich exec deploy/immich-postgres -- \
  pg_isready -U postgres -d immich

# Web UI through Traefik
curl -sS -o /dev/null -w '%{http_code}\n' https://immich.home.daandewilde.be
# 200
```

## Backup

Two things to snapshot from the Synology:

- `k8s-storage/immich-immich-library/` — all originals
- `k8s-storage/immich-immich-postgres-data/` — the database (snapshot while
  postgres is quiesced, or take a `pg_dump` to a sidecar PVC first)
