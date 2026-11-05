# rust-agents-gitops

The GitOps version of [rust-agents](https://github.com/gbaeke/rust-agents): the same Rust "deep agent", MCP server and Postgres, on a kind cluster, but [Argo CD](https://argo-cd.readthedocs.io/) applies everything from git instead of `deploy.sh`. One more change: agentgateway is a **central AI gateway** shared by every agent, not a proxy per app.

The source was copied from rust-agents at commit `5a40b5f`. Since then the two repos are independent. How it was built, phase by phase, is in [docs/plan.md](docs/plan.md).

```
                        git (this repo, main)
                                │  Argo CD syncs every ~3 min, or on refresh
                                ▼
 kind cluster "gitops" ─────────────────────────────────────────────────────────────
  argocd            root ─▶ platform Applications (sync waves) ─▶ rust-agents
  kube-system       Sealed Secrets (decrypts the secrets in git)
  agentgateway-system   the agentgateway controller
  ai-gateway        the central gateway: models, Anthropic key, per-app keys,
                    policies, every app's MCP route, request-log Postgres
  rust-agents       agent ×3 ──x-api-key──▶ ai-gateway ──▶ api.anthropic.com   (Sonnet, Haiku)
                    mcp-server ×2 ◀──────── ai-gateway (/rust-agents/mcp)
                    Postgres (chats)
  research-agent    the same, from the same template, on Haiku only   (:31001)
 ───────────────────────────────────────────────────────────────────────────────────
 kind-registry (localhost:5001): the images, built by scripts/release.sh
```

## Quick start

Needs docker and [mise](https://mise.jdx.dev). It's a lab setup: plain http, one machine.

```sh
cluster/cluster.sh install            # kind, kubectl, helm, argocd, kubeseal (mise, no sudo)
cluster/cluster.sh up                 # the registry and the cluster (host ports 31000-31009)
bootstrap/bootstrap.sh                # Argo CD and the root Application; prints the admin password
```

Then Argo installs the rest from git, in order. Allow about a minute and a half:
1. Sealed Secrets and the CRDs;
2. the agentgateway controller;
3. the central gateway;
4. the app.

- **Agents:** rust-agents at http://omarchy:31000, research-agent at http://omarchy:31001
- **Argo CD:** http://omarchy:31009 (user `admin`, password from `bootstrap/bootstrap.sh password`)

From another machine, the host ports need the ufw-docker rule `sudo ufw route allow proto tcp from any to any port 30000:30009` (it matches the container port).

**On a new cluster:** the images live in the registry container, which `cluster.sh down` leaves running. The Sealed Secrets key comes from the backup in `~/.config/rust-agents-gitops/`, which `bootstrap.sh` restores before Sealed Secrets starts. If that key is lost, every `sealed-*.yaml` must be sealed again (see [Secrets](#secrets)).

## Using the agent

Open http://omarchy:31000 and chat:
- **What it does:** plans with a todo list, keeps notes in a scratch filesystem, hands research to subagents, and searches the knowledge base in `knowledge-base/` (product catalogue, pricing and SLA, expense policy, an API reference, a postmortem). The **Plan** and **Files** tabs show its todo list and files.
- **Tools** from the MCP server, through the gateway: `calculate`, `current_time`, `get_weather`, `fetch_url`.
- **Chats** survive pod restarts: they're in the app's Postgres, and any of the 3 pods can answer. **Reset** clears one.
- **One message at a time** per chat: a second one while it's busy gets 409.

To see what every agent's calls cost, open the gateway's admin UI. Its analytics and logs pages are unlisted; see `CLAUDE.md`.
```sh
kubectl --context kind-gitops -n ai-gateway port-forward deploy/ai-gateway 15000:15000
# http://localhost:15000/ui/llm/analytics and /ui/llm/logs (the user column is the app)
```

## The central AI gateway

One agentgateway in namespace `ai-gateway` is owned by the platform and shared by all agents, like an API management layer for model calls. Everything about it is in `platform/ai-gateway/`:
- **Models:** only the models in `models.yaml` are served; any other model gets 404.
- **Provider key:** the Anthropic key is sealed in `sealed-anthropic.yaml`. Agents never see it: the gateway swaps it in.
- **App keys:** every call, model or tool, needs an app key in `x-api-key`. The gateway only holds each key's hash, in `apps/<app>/key.yaml`; the key itself is sealed in the app's folder.
- **Tool access:** each app's MCP route is `apps/<app>/mcp.yaml`, on `/<app>/mcp`, and only that app's key may use it.
- **Usage per app:** every call is logged with the app's name (`usage-per-app.yaml`).
- **Network:** only namespaces labelled `ai-gateway.platform/client: "true"` can reach the gateway, and an agent can reach nothing else outside its namespace.

- **Models per app:** each model in `models.yaml` lists the apps that may use it (`apiKey.app in [...]`). rust-agents may use Sonnet and Haiku; research-agent only Haiku. Any other app gets 403.
- **Limits per app:** `limits.yaml` limits research-agent to 30 requests a minute (429 above that). Two caveats: it's counted per gateway replica, and in agentgateway 1.7.0 tool calls count against the limit but are never refused, so only model calls are actually limited.

Apps can't add models, routes or policies: their AppProject blocks every Gateway API and agentgateway kind, and a sync that tries is refused.

### Adding an agent

```sh
scripts/agent-key.sh <app>                                     # apps/<app>/sealed-gateway-key.yaml + platform/ai-gateway/apps/<app>/key.yaml
scripts/seal.sh postgres <app> apps/<app>/sealed-postgres.yaml
```
Then:
1. Write `apps/<app>/kustomization.yaml` as an overlay of `bases/rust-agent`. Copy `apps/research-agent/`: it sets the namespace, model, MCP URL, allowed hosts and NodePort.
2. Copy `platform/ai-gateway/apps/research-agent/mcp.yaml` with the new name.
3. Add the app to the models it may use in `models.yaml`, and to `limits.yaml` if it needs a limit.
4. Commit and push.

The ApplicationSet turns the folder into an app. Removing both folders removes the app and everything it ran, its database included.

## Day to day

| Task | How | What happens |
|---|---|---|
| Release new code | Commit the code, run `scripts/release.sh`, push | It builds and pushes both images, tagged with the source's last commit hash, and commits the tag. After the push the pods roll. |
| Change a setting | Edit `bases/rust-agent/kustomization.yaml` (every agent) or `apps/<app>/kustomization.yaml` (one agent), commit, push | The ConfigMap gets a new name (a hash of its contents), so the pods roll and the old one is pruned |
| Roll back | `git revert <release commit>`, push | The old images come back; Argo's own Rollback button is off while auto-sync is on |
| Fix drift | Nothing | A `kubectl scale` or a deleted NetworkPolicy is undone within seconds (selfHeal) |
| Refresh now | `kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite`, or **Refresh** in the UI | Saves waiting for the 3-minute poll. Refresh the app you changed, not only `root`. |

**Trying things without a commit each time (inner loop).** Self-healing undoes manual changes, and `root` even restores an app's own auto-sync setting, because that's in git too. So pause from the top down:
```sh
k() { kubectl --context kind-gitops -n argocd "$@"; }
k patch application root --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
k patch application rust-agents --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
# now change things by hand, e.g. kubectl -n rust-agents set image deploy/agent agent=localhost:5001/rust-agents/agent:<tag>
# Argo shows the app OutOfSync (see Diff in the UI) but leaves it alone
k patch application root --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
# root restores rust-agents' auto-sync, which puts everything back as git says
```
While root is paused, no Application gets changes from git. Anything worth keeping goes into git before you turn it back on.

## Secrets

Secrets are in git, encrypted with Sealed Secrets; only the controller in this cluster can decrypt them. Values travel to `kubeseal` on stdin, never as a file or a process argument.

| File | Made by |
|---|---|
| `platform/ai-gateway/sealed-anthropic.yaml` | `scripts/seal.sh anthropic <.env with ANTHROPIC_API_KEY>` |
| `platform/ai-gateway/sealed-postgres.yaml`, `apps/<app>/sealed-postgres.yaml` | `scripts/seal.sh postgres <namespace> <file>`, only once: a new password would lock Postgres out of its data |
| `apps/<app>/sealed-gateway-key.yaml` and `platform/ai-gateway/apps/<app>/key.yaml` | `scripts/agent-key.sh <app>` |

`scripts/sealing-key.sh backup` saves the controller's key outside git (done once). `restore` brings it back, and `cert` prints the public certificate.

## Compared with the script version

| | rust-agents (scripts) | rust-agents-gitops |
|---|---|---|
| Install | `kind/cluster.sh up`, `kind/agentgateway.sh install`, `deploy/deploy.sh` | `cluster.sh up`, `bootstrap.sh`; Argo does the rest, in waves |
| Rebuild from nothing | Run the three scripts again; secrets come from `.env` again | `down`, `up`, `bootstrap.sh`: about 2.5 minutes, no other step; secrets come from git |
| Release | `deploy.sh` rebuilds `:dev`, loads it into kind, restarts the pods | `release.sh` builds a tag that's never reused, commits it; the push deploys |
| A setting | Edit, run `deploy.sh` | Edit, commit, push |
| Rollback | Rebuild the old code by hand | `git revert`, push |
| Manual change in the cluster | Stays until the next `deploy.sh` | Undone within seconds |
| What git records | The manifests | The manifests, every released version, every setting, the encrypted secrets, the gateway's models, keys and policies |
| Gateway | One proxy per app, holding the key | One central gateway: models, keys, policies and usage for all agents |
| A second agent | Copy the manifests and the script steps | A folder with an overlay and a key; the ApplicationSet does the rest |
| Quick experiments | Just `kubectl` | Pause `root` and the app first |

What still needs a script: the cluster (`cluster.sh`), installing Argo CD (`bootstrap.sh`), sealing secrets (`seal.sh`, `agent-key.sh`), the sealing key backup, and building images (`release.sh`). The last could move to CI, which would build and push to a registry such as ghcr.io and commit the tag.

## Layout

```
cluster/        kind config and cluster.sh (cluster + local registry)
bootstrap/      bootstrap.sh, Argo CD's Helm values, root.yaml
argocd/         what root syncs: AppProjects, the platform Applications, the ApplicationSet over apps/*
platform/       gateway-api/ (CRDs), ai-gateway/ (the central gateway)
bases/          rust-agent/: the agent as a kustomize template (the image tags are set here by release.sh)
apps/           one folder per agent, each an overlay of bases/rust-agent
scripts/        release.sh, seal.sh, agent-key.sh, sealing-key.sh
agent/, mcp-server/, knowledge-base/, Dockerfile   the app's source
```
