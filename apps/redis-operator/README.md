# redis-operator

The [OT redis-operator](https://ot-container-kit.github.io/redis-operator/). It
replaces the DIY `Deployment` + `Service` (and bundled-subchart) Redis pattern
with a single declarative `Redis` CR per app that the operator owns end-to-end —
including **rolling upgrades** (bump the image tag → the operator rolls the pod),
which is the whole reason this exists. Same model as `apps/cloudnative-pg`: one
operator, one CR per app, no shared instance.

Installs cluster-wide into the `redis-operator` namespace and manages its own
CRDs (`redis.redis.opstreelabs.in` — `Redis`, `RedisReplication`, `RedisCluster`,
`RedisSentinel`). No IngressRoute — the operator has no UI, it only reconciles
`Redis` resources.

## Redis manifests live here

Every app's Redis is a standalone `Redis` CR defined in `templates/` (e.g.
`immich-redis.yaml`), even though each one **runs in its consuming app's
namespace** (`metadata.namespace: <app>`) so the app can read its Redis password
from a same-namespace secret and reach it over an in-namespace service. The
cluster-wide operator reconciles them wherever they land.

The operator names the ClusterIP Service **exactly after the CR** on port `6379`
(plus `<name>-headless`), so a CR named `paperless-redis` reproduces the Service
name the app already dials.

Within this app's sync: operator + CRDs = wave 0 → `Redis` CRs = wave 2 (with
`SkipDryRunOnMissingResource` so the first sync doesn't fail while the CRD is
still being created).

## Upgrades

- **Operator**: bump the chart dependency `version` in `Chart.yaml` (Renovate
  tracks it via the `helmv3` manager).
- **Redis**: bump `kubernetesConfig.image` on each `Redis` CR (a handful of lines
  in this one folder); the operator rolls the pod. Bumped deliberately, same
  convention as the CNPG cluster image tags.

## Auth & persistence

- **Auth** is optional per CR via `kubernetesConfig.redisSecret` (sets
  `requirepass`). Omit for no-auth (matches the previously-bundled instances).
- **Persistence** is optional per CR via `storage.volumeClaimTemplate`. Omit for
  ephemeral — these are all cache/queue workloads, not a source of truth.

## Verifying

```bash
kubectl -n redis-operator get pods                 # operator Running
kubectl get crd | grep opstreelabs                 # redis.redis.opstreelabs.in CRDs present
kubectl -n <app> get redis                         # per-app Redis CR Ready
```
