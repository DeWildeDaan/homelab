# paperless-ngx

Self-hosted document management + OCR at `https://paperless.home.daandewilde.be`.

Built on the upstream `gabe565/paperless-ngx` chart (which itself bundles the
bitnami `postgresql` + `redis` subcharts). Gotenberg and Tika run alongside
as small in-repo Deployments to give paperless the Office-document pipeline.

## Components

| Piece | Backed by |
| --- | --- |
| Document library (media + data + consume + export) | PVCs on `nfs-nas` (RWX) |
| Postgres data | `data-paperless-ngx-postgresql-0` PVC on `local-path` (10Gi) — see note below |
| Redis queue | `emptyDir` (queue is ephemeral; rebuilt on restart) |
| Gotenberg + Tika | In-repo Deployments (`templates/gotenberg.yaml`, `templates/tika.yaml`) |
| Ingress | Traefik IngressRoute, wildcard cert from `cert-manager` |

> Postgres uses `local-path` (k3s built-in) for the same reason as immich:
> Synology NFS squashes every UID to admin, which breaks Postgres's strict
> pgdata ownership check. The PVC is pinned to whichever node it first lands
> on. Acceptable for a homelab; revisit if you add Longhorn or similar.

## Vendor the upstream chart

```bash
cd apps/paperless-ngx
helm dependency update
git add Chart.lock charts/
```

## First-time setup

1. **Seal the three secrets.** Two SealedSecret templates ship with
   `REPLACE_ME_WITH_KUBESEAL_OUTPUT` placeholders. Generate each ciphertext
   against your cluster's controller and paste in.

   ```bash
   # Helper — adjust the value before piping
   seal() {
     local name=$1 key=$2 value=$3
     echo -n "$value" | kubeseal \
       --controller-name sealed-secrets-controller \
       --controller-namespace sealed-secrets \
       --raw \
       --namespace paperless-ngx \
       --name "$name"
   }

   # templates/postgres-password-sealedsecret.yaml
   seal paperless-postgres postgres-password 'your-strong-postgres-password'

   # templates/paperless-secrets-sealedsecret.yaml — three keys in one secret
   seal paperless-secrets secret-key     "$(openssl rand -base64 48)"
   seal paperless-secrets admin-password 'your-first-boot-admin-password'
   seal paperless-secrets redis-password "$(openssl rand -base64 32)"
   ```

   Paste each output under the matching `encryptedData:` key. After
   decryption the cluster will hold:
   - `paperless-postgres` — key `postgres-password`
   - `paperless-secrets` — keys `secret-key`, `admin-password`, `redis-password`

2. **Pre-size the media PVC.** 100Gi default — adjust
   `values.yaml → paperless-ngx.persistence.media.size` before the first sync.
   Resizing later requires manual NFS work.

3. Commit and let ArgoCD sync. The ApplicationSet picks up `apps/paperless-ngx`
   and creates the namespace.

4. Open `https://paperless.home.daandewilde.be` and sign in as `admin` with
   the password you sealed above. Change it immediately from the user menu.

## Verifying

```bash
kubectl -n paperless-ngx get pod,svc,pvc

# All four library PVCs bound
kubectl -n paperless-ngx get pvc

# DB reachable
kubectl -n paperless-ngx exec sts/paperless-ngx-postgresql -- \
  pg_isready -U postgres -d paperless

# Gotenberg + Tika reachable from the paperless pod
kubectl -n paperless-ngx exec deploy/paperless-ngx -- \
  wget -qO- http://paperless-gotenberg:3000/health
kubectl -n paperless-ngx exec deploy/paperless-ngx -- \
  wget -qO- http://paperless-tika:9998/tika

# Web UI through Traefik
curl -sS -o /dev/null -w '%{http_code}\n' https://paperless.home.daandewilde.be
# 200 (or 302 to /accounts/login/)
```

## Adding documents

Drop files into the `paperless-ngx-paperless-ngx-consume` share on the
Synology — paperless watches `/usr/src/paperless/consume` and ingests them
automatically. The web UI also has an upload button.

## Backup

Two things to snapshot from the Synology:

- `k8s-storage/paperless-ngx-paperless-ngx-media/` — all originals + archives
- The Postgres data — `pg_dump` to a PVC on `nfs-nas`, then snapshot from the
  NAS side. The local-path PV itself isn't on the Synology, so it won't get
  picked up by share-level backups.
