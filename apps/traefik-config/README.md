# traefik-config

Overrides for the k3s-bundled Traefik via a `HelmChartConfig` in `kube-system`.
k3s' embedded Helm controller merges this on top of the bundled Traefik chart
on next reconcile.

What this pins:
- `Service` LoadBalancer IP → `192.168.4.30` (assigned by MetalLB)
- `web` (80) → permanent redirect to `websecure` (443)
- `websecure` (443) → TLS enabled
- Default TLS store → wildcard cert `wildcard-home-daandewilde-be-tls` (issued
  by cert-manager into `kube-system`)

## Dependency order

This Application creates an empty namespace `traefik-config` (the
`ApplicationSet` always does that) — the actual `HelmChartConfig` lives in
`kube-system`. That's fine; the empty namespace is harmless.

Apply order, end to end:
1. `metallb/` syncs → pool exists.
2. `traefik-config/` syncs → k3s reconciles Traefik with the LB IP.
3. `cert-manager/` issues the wildcard cert into `kube-system`.
4. Traefik picks up the cert (controller restart on Secret change is automatic
   for the default TLS store after a few seconds).

If MetalLB isn't live yet, the Traefik Service will stay in `Pending` — that's
the expected failure mode, not a bug here.

## Verifying

```bash
kubectl -n kube-system get svc traefik
# expect EXTERNAL-IP: 192.168.4.30

kubectl -n kube-system get helmchartconfig traefik -o yaml
# spec.valuesContent shows the rendered overrides

# After cert-manager has issued the cert:
kubectl -n kube-system get secret wildcard-home-daandewilde-be-tls
echo | openssl s_client -connect 192.168.4.30:443 -servername whatever.home.daandewilde.be 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
# Issuer: Let's Encrypt, Subject CN: *.home.daandewilde.be
```
