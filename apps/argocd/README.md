# argocd

Traefik `IngressRoute` exposing the ArgoCD UI at
`https://argocd.home.daandewilde.be`. Same templates-only pattern as
`traefik-config/` — no upstream Helm dependency.

ArgoCD itself is installed manually (see `setup.md` Step 9) — not GitOps-
managed. This chart only ships the route.

## Prerequisites (must already be live)

1. **MetalLB + traefik-config** — Traefik reachable at `192.168.4.30`.
2. **cert-manager** — wildcard cert `wildcard-home-daandewilde-be-tls`
   present in `kube-system`; picked up as Traefik's default TLS cert by
   `apps/traefik-config/`.
3. **AdGuard** — DNS rewrite `*.home.daandewilde.be → 192.168.4.30` active,
   LAN clients using `192.168.4.31` for DNS.
4. **`server.insecure: true`** already set on ArgoCD (done in `setup.md` Step
   11) — Traefik terminates TLS.

If any of these is missing the IngressRoute still applies cleanly; it just
won't serve real traffic / a trusted cert until they catch up.

## Verifying

```bash
kubectl -n argocd get ingressroute argocd-home

# from LAN
dig +short argocd.home.daandewilde.be       # -> 192.168.4.30
curl -sS -o /dev/null -w '%{http_code}\n' https://argocd.home.daandewilde.be
# 200 (or 307 redirect to /login)
```

Browser: `https://argocd.home.daandewilde.be`, login `admin` + the bootstrap
password.

## Cleaning up the old nip.io route

The original `argocd` IngressRoute (created in `setup.md` Step 11, hostname
`argocd.192.168.4.21.nip.io`, plain HTTP) is **not managed by ArgoCD** — Argo
only tracks resources it created itself. Once the new route works, remove the
old one manually:

```bash
kubectl -n argocd delete ingressroute argocd
```

The new one is named `argocd-home` specifically so the two don't collide
during the cutover.
