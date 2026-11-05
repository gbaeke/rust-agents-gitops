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
| `usage-per-app.yaml` | logs the calling app (`apiKey.app`) as the request log's user |
| `network-policies.yaml` | only client namespaces reach the proxy; only the proxy reaches Postgres |
| `apps/<app>/` | per app: `key.yaml`, its key hash (`scripts/agent-key.sh <app>`), and `mcp.yaml`, its MCP backend, route on `/<app>/mcp` and the rule that only its own key may use it |
