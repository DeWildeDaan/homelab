# printstash

Self-hosted [PrintStash](https://github.com/xiao-villamor/PrintStash) — a 3D
print asset vault (models, G-code, printer/revision tracking). Deployed as a
custom Helm chart; ArgoCD picks it up via the `apps/*` ApplicationSet
(namespace: `printstash`).

Single unified container (`ghcr.io/xiao-villamor/printstash`) bundles the web
UI, API, and SQLite — no separate DB/cache to stand up.

- **UI:** https://printstash.home.daandewilde.be — login is native OIDC
  against Pocket ID (dedicated client, like `wealthfolio`).

## Storage

| Volume     | Mount          | StorageClass | Why |
| ---------- | -------------- | ------------ | --- |
| `vault`    | `/data` (holds `files/` + `thumbs/`) | `nfs-nas` | 3D model/G-code library + previews — bulk media, must live on the NAS. `files` and `thumbs` **must** share one PVC: PrintStash's "local" storage provider verifies itself with a hardlink between `data_dir` and `thumb_dir`, which fails across two separate NFS mounts even on the same storageClass. |
| `backups`  | `/data/backups`| `nfs-nas`    | Backup exports |
| `db`       | `/data/db`     | `longhorn`   | SQLite database — latency-sensitive, small |
| `staging`  | `/data/staging`| `longhorn`   | In-flight upload buffer — latency-sensitive, small |

## Setup (one-time)

1. **Create a Pocket ID OIDC client** (`https://auth.home.daandewilde.be`, admin →
   OIDC Clients → add):
   - **Callback URL:** `https://printstash.home.daandewilde.be/api/v1/auth/oidc/callback`
   - **Scopes:** `openid profile email groups`.
   - Copy the **Client ID** → `values.yaml` `oidc.clientId`, and the **Client
     Secret** for sealing below.

2. **Seal the secrets** and paste each ciphertext into the indicated field.

   `printstash-secrets` (this chart, `values.yaml`):
   ```bash
   # VAULT_JWT_SECRET  → secrets.encryptedJwtSecret
   openssl rand -hex 32 | tr -d '\n' | kubeseal --controller-name sealed-secrets-controller \
     --controller-namespace sealed-secrets --raw --namespace printstash --name printstash-secrets

   # VAULT_OIDC_CLIENT_SECRET (from Pocket ID)  → secrets.encryptedOidcClientSecret
   echo -n '<CLIENT_SECRET>' | kubeseal --controller-name sealed-secrets-controller \
     --controller-namespace sealed-secrets --raw --namespace printstash --name printstash-secrets
   ```

3. **First login:** `VAULT_SETUP_MODE` defaults to `trusted_network`, which
   lets the first browser to hit `/setup` register as the initial admin. Once
   that account exists, set `VAULT_SETUP_MODE=disabled` in
   `templates/deployment.yaml` and redeploy to close that window.

4. In Pocket ID, add the initial admin user to the `admin` group (matches
   `oidc.adminGroups` in `values.yaml`) so they land with admin rights on
   first SSO login.
