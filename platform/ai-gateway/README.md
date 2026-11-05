# platform/ai-gateway/

The central AI gateway, synced by the Application `ai-gateway` (`argocd/platform.yaml`). Argo reads every `.yaml` here, including the subfolders; this README is ignored.

| File | What |
|---|---|
| `namespace.yaml` | namespace `ai-gateway`, restricted |
| `sealed-*.yaml` | the Anthropic key and the Postgres password, from `scripts/seal.sh` |
| `postgres.yaml` | the request-log database (`agentgateway`) for the admin UI's analytics |
| `gateway.yaml` | the Gateway `ai-gateway` and how its proxy runs |
| `models.yaml` | the model catalogue: only these are served |
| `api-keys.yaml` | callers must send a key whose hash is in an `apps/<app>/key.yaml` |
| `network-policies.yaml` | only client namespaces reach the proxy; only the proxy reaches Postgres |
| `apps/<app>/` | per app: its key hash (`scripts/agent-key.sh <app>`) and, from phase 3, its MCP route |
