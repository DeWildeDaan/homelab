# ollama

Self-hosted [Ollama](https://ollama.com) LLM runtime with an [Open WebUI](https://openwebui.com)
chat frontend. Deployed as a custom Helm chart; ArgoCD picks it up automatically
via the `apps/*` ApplicationSet (namespace: `ollama`).

## Components

| Component  | Image                                | Purpose                          | Storage                 |
| ---------- | ------------------------------------ | -------------------------------- | ----------------------- |
| ollama     | `ollama/ollama`                      | LLM API server (port `11434`)    | `nfs-nas` 30Gi (models) |
| open-webui | `ghcr.io/open-webui/open-webui`      | Chat UI (port `8080`)            | `longhorn` 2Gi (SQLite) |

- **UI:** https://ollama.home.daandewilde.be — Open WebUI with **native OIDC**
  against Pocket ID (its own dedicated client, like `wealthfolio`). The ingress is
  *not* behind the `pocket-id-*` middleware, so there's a single login prompt.
- **API:** Ollama is reachable in-cluster at `http://ollama.ollama.svc.cluster.local:11434`.
  It is intentionally *not* exposed through the ingress.

## SSO setup (one-time)

Open WebUI has its own Pocket ID client. To wire it up:

1. **Create the client in Pocket ID** (`https://auth.home.daandewilde.be`, admin →
   OIDC Clients → add):
   - **Callback URL:** `https://ollama.home.daandewilde.be/oauth/oidc/callback`
   - Allow the `admin` and `non_admin` groups on the client (group claims must be
     emitted for role mapping to work).
   - Save, then copy the generated **Client ID** and **Client Secret**.
2. **Put the Client ID** into `values.yaml` → `oidc.clientId` (non-secret).
3. **Seal the Client Secret** and paste the ciphertext into
   `values.yaml` → `secrets.encryptedOidcClientSecret`:

   ```bash
   echo -n '<CLIENT_SECRET_FROM_POCKET_ID>' | kubeseal \
     --controller-name sealed-secrets-controller \
     --controller-namespace sealed-secrets \
     --raw \
     --namespace ollama \
     --name ollama-secrets
   ```
4. Commit + push. ArgoCD syncs; the first person to log in via Pocket ID becomes
   the Open WebUI admin (members of the `admin` group get admin, `non_admin` get
   user; anyone else is denied by `OAUTH_ALLOWED_ROLES`).
5. Once SSO works, optionally set `openWebui.loginForm: false` to hide the local
   email/password form and leave only the Pocket ID button.

> The Deployment reads OAuth settings from env on every boot
> (`ENABLE_OAUTH_PERSISTENT_CONFIG=false`), so changes in `values.yaml` always
> take effect — nothing gets frozen into the SQLite DB after first launch.

## Notes

- **CPU-only.** The k3s nodes have no GPU and 4–8Gi RAM, so stick to small models
  (`llama3.2:1b`/`3b`, `qwen2.5:3b`, `phi3`). Larger models will be slow or OOM.
- **Models don't autoload.** Pull one after the pod is up, e.g.:

  ```bash
  kubectl -n ollama exec deploy/ollama -- ollama pull llama3.2:3b
  ```

  or add it from the Open WebUI model settings.
- Model files live on the NAS (`nfs-nas`); Open WebUI's SQLite state lives on
  Longhorn to avoid NFS file-locking issues.
