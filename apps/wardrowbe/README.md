# wardrowbe

Self-hosted [Wardrowbe](https://github.com/Anyesh/wardrowbe) — an AI wardrobe /
outfit app. Deployed as a custom Helm chart; ArgoCD picks it up via the `apps/*`
ApplicationSet (namespace: `wardrowbe`).

## Components

| Component | Image                                 | Purpose                              |
| --------- | ------------------------------------- | ------------------------------------ |
| frontend  | `ghcr.io/anyesh/wardrowbe:frontend-*` | Next.js UI (port 3000, exposed)      |
| backend   | `ghcr.io/anyesh/wardrowbe:backend-*`  | FastAPI API (port 8000, internal)    |
| worker    | `ghcr.io/anyesh/wardrowbe:backend-*`  | arq background worker (AI tagging)   |
| Postgres  | CloudNativePG cluster                 | `wardrowbe-db` (apps/cloudnative-pg) |
| Redis     | redis-operator `Redis` CR             | `wardrowbe-redis` (apps/redis-operator) — arq broker |

- **UI:** https://wardrobe.home.daandewilde.be — Open the frontend; login is
  **native OIDC (NextAuth)** against Pocket ID (dedicated client, like
  `wealthfolio`). Backend/worker stay internal; the browser reaches the API
  through the frontend's `/api/v1/*` proxy.
- **AI:** points at the in-cluster `ollama` (`gemma3:4b`, multimodal) for both
  photo auto-tagging (vision) and outfit recommendations (text). CPU inference is
  slow — tagging runs in the worker with a 600s timeout.

## Related manifests (in the operator apps)

- `apps/cloudnative-pg/templates/wardrowbe-db.yaml` — Postgres cluster (→ service
  `wardrowbe-db-rw:5432`) + `wardrowbe-db-app-sealedsecret.yaml` (DB credentials).
- `apps/redis-operator/templates/wardrowbe-redis.yaml` — Redis (→ service
  `wardrowbe-redis:6379`), password from `wardrowbe-secrets/redis-password`.

## Setup (one-time)

1. **Create a Pocket ID OIDC client** (`https://auth.home.daandewilde.be`, admin →
   OIDC Clients → add):
   - **Callback URL:** `https://wardrobe.home.daandewilde.be/api/auth/callback/oidc`
   - **Scopes:** `openid email profile`. Restrict who can log in via the client's
     allowed groups if you want.
   - Copy the **Client ID** → `values.yaml` `oidc.clientId`, and the **Client
     Secret** for sealing below.

2. **Seal the secrets** and paste each ciphertext into the indicated field.

   `wardrowbe-secrets` (this chart, `values.yaml`):
   ```bash
   # SECRET_KEY  → secrets.encryptedSecretKey
   openssl rand -hex 32 | tr -d '\n' | kubeseal --controller-name sealed-secrets-controller \
     --controller-namespace sealed-secrets --raw --namespace wardrowbe --name wardrowbe-secrets

   # NEXTAUTH_SECRET  → secrets.encryptedNextauthSecret
   openssl rand -hex 32 | tr -d '\n' | kubeseal --controller-name sealed-secrets-controller \
     --controller-namespace sealed-secrets --raw --namespace wardrowbe --name wardrowbe-secrets

   # redis-password (URL-safe hex)  → secrets.encryptedRedisPassword
   openssl rand -hex 16 | tr -d '\n' | kubeseal --controller-name sealed-secrets-controller \
     --controller-namespace sealed-secrets --raw --namespace wardrowbe --name wardrowbe-secrets

   # OIDC_CLIENT_SECRET (from Pocket ID)  → secrets.encryptedOidcClientSecret
   echo -n '<CLIENT_SECRET>' | kubeseal --controller-name sealed-secrets-controller \
     --controller-namespace sealed-secrets --raw --namespace wardrowbe --name wardrowbe-secrets
   ```

   `wardrowbe-db-app` (in `apps/cloudnative-pg/templates/wardrowbe-db-app-sealedsecret.yaml`):
   ```bash
   # username (must equal the cluster owner: wardrowbe)
   echo -n 'wardrowbe' | kubeseal --controller-name sealed-secrets-controller \
     --controller-namespace sealed-secrets --raw --namespace wardrowbe --name wardrowbe-db-app
   # password (URL-safe hex — embedded in DATABASE_URL)
   openssl rand -hex 24 | tr -d '\n' | kubeseal --controller-name sealed-secrets-controller \
     --controller-namespace sealed-secrets --raw --namespace wardrowbe --name wardrowbe-db-app
   ```

3. **Ensure the model is pulled:**
   ```bash
   kubectl -n ollama exec deploy/ollama -- ollama pull gemma3:4b
   ```

4. Push → ArgoCD creates the `wardrowbe` app and adds the DB/Redis CRs to the
   operator apps. The backend runs `alembic upgrade head` as an init container
   before serving.

## Notes

- **Migrations** run automatically via the backend's `migrate` init container.
- The `wardrowbe` namespace is created by this Application; the DB/Redis CRs in the
  operator apps target it and converge via `SkipDryRunOnMissingResource` (same
  pattern as immich/paperless).
- Photos live on `nfs-nas` (RWX, shared by backend + worker) at `/data/wardrobe`.
