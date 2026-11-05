# CLAUDE.md

This folder is the GitOps (Argo CD) version of `/home/geba/Projects/rust-agents`. Work follows `docs/plan.md`: one phase at a time, stopping at each checkpoint. Decisions D1–D12 were confirmed on 2026-11-05. The agentgateway is central (D9): one Gateway in namespace `ai-gateway`, owned by the platform, shared by every agent. Models, keys, policies and MCP routes live there; apps only run workloads. D9 (one central AI gateway shared by all agents, like Azure API Management with AI policies) was added to the plan later that day and confirmed by the user; it changes phases 2, 3 and 5, so the per-app gateway in `apps/rust-agents/` is replaced by `platform/ai-gateway/`.

Rules:
- No sudo: give the user the command.
- The Anthropic key never goes in git (not even encoded) or in process arguments. Read it from a file and pass it on stdin.
- Confirm before creating the GitHub repo and before every push.
- Tools come from mise. Don't commit someone else's `mise.toml`.

## agentgateway admin UI (Kubernetes mode)

In Kubernetes mode the admin UI's menu only shows Models and Client Setup under LLM (the UI hard-codes this for its read-only `dumpMode`). Two more pages work but are not linked, so open them directly:

- LLM analytics (spend, tokens, calls over time): `http://localhost:15000/ui/llm/analytics`
- LLM request logs (one row per call): `http://localhost:15000/ui/llm/logs`

They need the request-log database (`config.database.url` in `rawConfig` of `AgentgatewayParameters`, in `platform/ai-gateway/`). Since the gateway is shared, they show calls from every agent. To reach the UI, port-forward a proxy pod of the central gateway (check the generated Deployment name):

```sh
kubectl -n ai-gateway port-forward deploy/ai-gateway 15000:15000
# from another machine: add --address 0.0.0.0 and use http://omarchy:15000/...
```
