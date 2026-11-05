# Local request rate limit is counted but not enforced on MCP routes

**Version:** agentgateway v1.7.0 (Helm charts `agentgateway` and `agentgateway-crds` v1.7.0), Kubernetes mode, Gateway API v1.6.3, kind.

**Setup**
- One Gateway with an HTTP listener on 8080.
- An `AgentgatewayModel` (Anthropic) and an MCP route: an `HTTPRoute` on `/app/mcp` → an `AgentgatewayBackend` with `mcp.sessionRouting: Stateless` and one static StreamableHTTP target.
- `apiKeyAuthentication` on the Gateway (keys from ConfigMaps, metadata `{"app": "..."}`).
- This local rate limit on the Gateway:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: { name: limits }
spec:
  targetRefs:
    - { group: gateway.networking.k8s.io, kind: Gateway, name: ai-gateway }
  traffic:
    rateLimit:
      conditional:
        - condition: apiKey.app == "research-agent"
          policy:
            local:
              - { key: apiKey.app, requests: 30, unit: Minutes }
```

**Steps**
1. Send 120 `tools/list` requests (`POST /app/mcp`, JSON-RPC) with the same key, in quick succession.
2. Then send one LLM request (`POST /v1/messages`) with that key.

**Expected:** once the bucket is empty, the MCP requests get 429, like LLM requests do.

**Actual:**
- All 120 MCP requests return **200**, and every one of them carries `x-ratelimit-remaining: 0`. So the limit is evaluated and the bucket is empty, but the request isn't rejected.
- The LLM request right after gets **429 "rate limit exceeded"**: the MCP requests did drain the bucket.
- After the window resets, LLM requests pass again.

So MCP traffic consumes the request budget but is never denied by it.
