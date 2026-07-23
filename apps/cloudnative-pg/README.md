# cloudnative-pg

The [CloudNativePG](https://cloudnative-pg.io/) operator. It replaces the DIY
`Deployment` + `PVC` + `SealedSecret` Postgres pattern with a single declarative
`Cluster` CR per app that the operator owns end-to-end — including **in-place
major-version upgrades** (bump the image tag → the operator runs `pg_upgrade`),
which is the whole reason this exists.

Installs cluster-wide into the `cloudnative-pg` namespace and manages its own
CRDs (`clusters.postgresql.cnpg.io`, …). No IngressRoute — the operator has no
UI, it only reconciles `Cluster` resources.

## Cluster manifests live here

Every app's Postgres `Cluster` is defined in `templates/` (e.g.
`paperless-db.yaml`), even though each cluster **runs in its consuming app's
namespace** (`metadata.namespace: <app>`) so the app can read its DB password
from a same-namespace secret and reach the DB over an in-namespace service. The
cluster-wide operator reconciles them wherever they land.

Within this app's sync: operator + CRDs = wave 0 → app secrets = wave 1 →
`Cluster` CRs = wave 2 (with `SkipDryRunOnMissingResource` so the first sync
doesn't fail while the CRD is still being created).

### Major upgrades are blue/green, by name

The major version is baked into each cluster name (`paperless-db-16`). To upgrade,
stand up `paperless-db-17` **beside** the old one (importing from it), repoint the
app's `PAPERLESS_DBHOST`, verify, then delete the old cluster file. The
credential secret (`paperless-db-app`) is referenced explicitly and is
version-independent, so it never changes across upgrades. Full steps are in the
header comment of `templates/paperless-db.yaml`.

## Requires Server-Side Apply

CNPG's `clusters.postgresql.cnpg.io` (and `poolers`) CRDs are larger than
Kubernetes' 262144-byte annotation limit, so ArgoCD's default **client-side**
apply fails with `metadata.annotations: Too long`. The cluster ApplicationSet
therefore sets `syncOptions: [ServerSideApply=true]` (see `setup.md` Step 12).
Symptom if it's missing: operator logs `no matches for kind "Cluster" in version
"postgresql.cnpg.io/v1"` because the CRD never applied.

## Dependency order

Deploy this app and let it go **Healthy first**. The sync-waves above order
things correctly within this app; ArgoCD also retries, so a briefly-missing CRD
self-heals.

## Verifying

```bash
kubectl -n cloudnative-pg get pods                 # operator Running
kubectl get crd | grep cnpg                         # clusters.postgresql.cnpg.io present
kubectl get deploy -n cloudnative-pg cnpg-cloudnative-pg -o wide
```

Optional but handy — the `cnpg` kubectl plugin for cluster status/backups:

```bash
kubectl krew install cnpg
kubectl cnpg status -n paperless-ngx paperless-db
```
