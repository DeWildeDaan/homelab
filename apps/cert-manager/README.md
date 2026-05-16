# cert-manager

cert-manager + a Let's Encrypt **production** `ClusterIssuer` that solves the
DNS-01 challenge via Cloudflare, plus a wildcard `Certificate` for
`*.home.daandewilde.be` issued into `kube-system` so Traefik can serve it as
its default cert (see `apps/traefik-config/`).

## Dependency order

This app depends on:
1. `sealed-secrets/` being healthy — otherwise the Cloudflare token SealedSecret can't decrypt.
2. The Cloudflare token SealedSecret being regenerated with a real token (one-time, see below).

ArgoCD will retry; nothing breaks permanently if these aren't ready yet.

## Vendor the upstream chart

```bash
cd apps/cert-manager
helm dependency update
git add Chart.lock charts/
```

## One-time — create the Cloudflare API token

1. Cloudflare dashboard → **My Profile → API Tokens → Create Token → Custom**
2. Permissions:
   - `Zone` → `DNS` → `Edit`
   - `Zone` → `Zone` → `Read`
3. Zone Resources: `Include → Specific zone → daandewilde.be`
4. TTL / IP filtering: leave default for homelab use.
5. Copy the token once — it won't be shown again.

## One-time — seal the token and replace the placeholder

```bash
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token='<paste-token-here>' \
  --dry-run=client -o yaml \
| kubeseal --format=yaml \
    --controller-namespace=sealed-secrets \
    --controller-name=sealed-secrets-controller \
> apps/cert-manager/templates/cloudflare-token-sealedsecret.yaml

git add apps/cert-manager/templates/cloudflare-token-sealedsecret.yaml
git commit -m "cert-manager: seal Cloudflare API token"
git push
```

ArgoCD will resync; the controller decrypts to a normal `Secret`; cert-manager
picks up the change and retries the issuance.

## Verifying

```bash
kubectl -n cert-manager get pod         # cert-manager / cainjector / webhook Running
kubectl get clusterissuer letsencrypt-prod -o yaml | grep -A3 conditions:
# expect Ready: True

# The wildcard cert (lives in kube-system so Traefik can read it):
kubectl -n kube-system get certificate wildcard-home-daandewilde-be
# READY=True within ~60-120s of a valid token

kubectl -n kube-system get secret wildcard-home-daandewilde-be-tls
# tls.crt + tls.key present

# Watch the issuance lifecycle:
kubectl -n kube-system get order,challenge -w
```

End-to-end HTTPS check (once Traefik is on 192.168.4.30):
```bash
echo | openssl s_client -connect 192.168.4.30:443 \
  -servername adguard.home.daandewilde.be 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
# Issuer: Let's Encrypt
# Subject: CN = *.home.daandewilde.be
```

## Renewal

Automatic — cert-manager renews 15 days before expiry. No action required.
