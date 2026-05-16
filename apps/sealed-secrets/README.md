# sealed-secrets

Bitnami Sealed Secrets controller. Lets you commit encrypted `SealedSecret`
resources to Git; the controller decrypts them into normal `Secret` objects
inside the cluster.

## One-time setup

### 1. Vendor the upstream chart

ArgoCD does not run `helm dep update` automatically. Run it once before the
first sync, then commit the `charts/*.tgz` tarball:

```bash
cd apps/sealed-secrets
helm dependency update
git add Chart.lock charts/
```

### 2. Install the `kubeseal` CLI on your workstation

```bash
# macOS
brew install kubeseal
# Linux
KUBESEAL_VERSION=0.27.1
curl -sL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" \
  | tar -xz kubeseal && sudo install -m 755 kubeseal /usr/local/bin/
```

### 3. Back up the master key (CRITICAL — do this immediately after first sync)

The controller generates a fresh RSA key pair on first start. If you lose it,
every `SealedSecret` in Git becomes garbage. Back it up out of band:

```bash
kubectl -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-master.key
```

Store `sealed-secrets-master.key` on the Synology NAS (encrypted folder) and in
your password manager. **Never commit it.**

Restore on a new cluster:
```bash
kubectl apply -f sealed-secrets-master.key
kubectl -n sealed-secrets rollout restart deploy/sealed-secrets-controller
```

## Encrypting a secret

```bash
kubectl create secret generic my-secret \
  --namespace my-app \
  --from-literal=password='hunter2' \
  --dry-run=client -o yaml \
  | kubeseal --format=yaml \
      --controller-namespace=sealed-secrets \
      --controller-name=sealed-secrets-controller \
  > apps/my-app/templates/my-sealedsecret.yaml
```

Commit the resulting file. The controller will decrypt and create the `Secret`
inside the cluster.

## Verifying

```bash
kubectl -n sealed-secrets get pod
kubectl -n sealed-secrets logs deploy/sealed-secrets-controller --tail=20
```
