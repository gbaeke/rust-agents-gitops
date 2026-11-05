# CLAUDE.md

This folder is the GitOps (Argo CD) version of `/home/geba/Projects/rust-agents`. Work follows `docs/plan.md`: one phase at a time, stopping at each checkpoint. Decisions D1–D8 were confirmed on 2026-11-05.

Rules:
- No sudo: give the user the command.
- The Anthropic key never goes in git (not even encoded) or in process arguments. Read it from a file and pass it on stdin.
- Confirm before creating the GitHub repo and before every push.
- Tools come from mise. Don't commit someone else's `mise.toml`.

## agentgateway admin UI (Kubernetes mode)

In Kubernetes mode the admin UI's menu only shows Models and Client Setup under LLM (the UI hard-codes this for its read-only `dumpMode`). Two more pages work but are not linked, so open them directly:

- LLM analytics (spend, tokens, calls over time): `http://localhost:15000/ui/llm/analytics`
- LLM request logs (one row per call): `http://localhost:15000/ui/llm/logs`

They need the request-log database (`config.database.url` in `rawConfig` of `AgentgatewayParameters`, see `apps/rust-agents/gateway.yaml`). To reach the UI, port-forward a proxy pod:

```sh
kubectl -n rust-agents port-forward deploy/agentgateway 15000:15000
# from another machine: add --address 0.0.0.0 and use http://omarchy:15000/...
```
