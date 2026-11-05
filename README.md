# rust-agents-gitops

A Rust "deep agent" on Claude, with an MCP tool server and Postgres, running on a local kind cluster and deployed the GitOps way: [Argo CD](https://argo-cd.readthedocs.io/) applies everything from this repo, and secrets are in git, encrypted with Sealed Secrets. Every model and tool call goes through [agentgateway](https://agentgateway.dev), set up as a **central AI gateway** that all agents share. It holds the Anthropic key, the allowed models, a key per agent, limits and each agent's tool route. Two agents run from one template.

How it was built, phase by phase, is in [docs/plan.md](docs/plan.md).

**How it gets deployed:**

```
 git: this repo, branch main
   │  Argo CD polls it at most every 3 minutes (or press Refresh)
   ▼
 Argo CD (namespace argocd): the root Application syncs argocd/, wave by wave

   wave  what                                       namespace
   -10   AppProjects: platform, apps                argocd
    -3   Sealed Secrets                             kube-system
    -3   Gateway API CRDs                           (cluster-wide)
    -2   agentgateway CRDs                          (cluster-wide)
    -1   agentgateway controller                    agentgateway-system
     0   the central AI gateway                     ai-gateway
     1   ApplicationSet: one app per apps/ folder
           rust-agents                              rust-agents
           research-agent                           research-agent
```

**How a call flows** (each box is a namespace):

```
 rust-agents :31000                ai-gateway
 ┌─────────────────────┐           ┌──────────────────────┐
 │ agent ×3            ├───┐       │ central gateway ×2   │
 │ mcp-server ×2       │   │       │                      │
 │ Postgres (chats)    │   ├──────▶│ Anthropic key        ├──▶ api.anthropic.com
 └─────────────────────┘   │       │ models per app       │
                           │       │ a key per app        │
 research-agent :31001     │       │ limits               │
 ┌─────────────────────┐   │       │ an MCP route per app │
 │ the same template,  ├───┘       │ request log          │
 │ on Haiku only       │           └──────────────────────┘
 └─────────────────────┘
```

Model calls and tool calls both carry the app's key in `x-api-key`. The gateway sends an app's tool calls on to that app's own mcp-server, at `/<app>/mcp`. Images come from a local registry container, `kind-registry` on `localhost:5001`, filled by `scripts/release.sh`.

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

- **Agents:** rust-agents at http://localhost:31000, research-agent at http://localhost:31001
- **Argo CD:** http://localhost:31009 (user `admin`, password from `bootstrap/bootstrap.sh password`)

From another machine, use the Docker host's name or IP instead of `localhost`. On Linux with ufw, the host ports also need the ufw-docker rule `sudo ufw route allow proto tcp from any to any port 30000:30009` (it matches the container port).

**On a new cluster:** the images live in the registry container, which `cluster.sh down` leaves running. The Sealed Secrets key comes from the backup in `~/.config/rust-agents-gitops/`, which `bootstrap.sh` restores before Sealed Secrets starts. If that key is lost, every `sealed-*.yaml` must be sealed again (see [Secrets](#secrets)).

### On macOS or Windows

Built and tested on Linux. The scripts are plain bash (3.2 is enough), so on macOS they should run as they are, with Docker Desktop or OrbStack instead of Docker Engine. Untested there so far.
- **URLs:** the same, on `localhost`. The ufw rule doesn't apply.
- **Images:** on Apple Silicon, `release.sh` builds arm64 images, which match kind's arm64 nodes.
- **Sealing key:** copy `~/.config/rust-agents-gitops/sealing-key.yaml` from the machine that made the cluster before you run `bootstrap.sh`. Without it, the new cluster can't decrypt the `sealed-*.yaml` files in git, and each one must be sealed again (see [Secrets](#secrets)).
- **Windows:** run everything inside WSL2, with Docker Desktop's WSL integration or Docker Engine in the WSL distro.

## Using the agent

Open http://localhost:31000 and chat:
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

## What's in git, and what isn't

Git holds the manifests, every released image tag, every setting, the encrypted secrets, and the gateway's models, keys and policies. So a lost cluster comes back with `cluster.sh down`, `cluster.sh up` and `bootstrap.sh` in about 2.5 minutes, with no other step. Only the chats in Postgres are lost.

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
