# To do

Open points after the five phases of [docs/plan.md](docs/plan.md). None of them is needed for the setup to work.

## Gateway

- [ ] **Report the MCP rate-limit gap to agentgateway.** In v1.7.0, tool calls count against an app's request limit but are never refused: they get 200 with `x-ratelimit-remaining: 0`, while model calls get 429. The draft is in [docs/agentgateway-mcp-rate-limit-issue.md](docs/agentgateway-mcp-rate-limit-issue.md). It hasn't been posted; it would go out under the repo owner's GitHub account.
- [ ] **Limit tool calls after all.** Until agentgateway fixes the gap, try a limit on each app's MCP route (`apps/<app>/mcp.yaml`) instead of on the Gateway, and test whether that one is enforced.
- [ ] **Strict, cluster-wide limits.** Today's limits are counted per gateway replica (2 × 30 a minute). A `global` rate limit needs a rate limit service (for example Envoy's ratelimit with Redis).
- [ ] **Token limits as a budget.** For example `tokens: 20000, unit: Hours` per app in `limits.yaml`, which fits cost control better than a request count.

## Releases

- [ ] **Per-image tags.** Both images get the hash of the last commit to any source path, so a change to the agent also gives the unchanged MCP server a new tag and restarts its pods. Tag each image with the last commit to its own paths (for the MCP image: `mcp-server/`, `Cargo.lock`, `Dockerfile`) in `scripts/release.sh`.
- [ ] **Build images in CI.** A GitHub Actions workflow that builds and pushes to ghcr.io and commits the tag. Filter it on source paths, so the tag commit doesn't trigger another build.

## Argo CD

- [ ] **Argo manages itself** (D8, optional): an Application `argocd` for the same chart and values in project `platform`, so that changes to `bootstrap/argocd-values.yaml` go through git instead of a re-run of `bootstrap.sh`.
- [ ] **Faster pickup after a push.** Argo polls git every 3 minutes, so the gateway can lag behind an app (seen in phases 3 and 5). A GitHub webhook would fix that, but GitHub can't reach this lab machine.
- [ ] **Slow removal of an app.** Removing an app's folder took about 4.5 minutes: the controller kept failing to render the deleted path for about 4 minutes before it began deleting. Find out whether that's a setting (a retry or timeout) or expected.

## Agent

- [ ] **Per-turn MCP tool listing.** The agent lists its MCP tools once, when it connects, so tools added later only show up after a restart. Listing them at the start of each turn, or caching them briefly as the OpenAI Agents SDK does, would pick up changes. rig's `McpClientHandler` refreshes on `notifications/tools/list_changed`, but our stateless MCP route never sends that.

## Checks

- [ ] **A final rebuild test with both agents.** `cluster.sh down`, `up`, `bootstrap.sh`: everything, both agents included, must come back from git with no other step.
- [ ] **ufw-docker for host ports 31000–31009** (D6). Confirm from another machine that the existing rule for 30000–30009 covers them.
