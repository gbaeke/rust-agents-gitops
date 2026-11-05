# Plan: a GitOps version of the Kubernetes setup, in a new repo

Status: **phase 1 done, at checkpoint 1** (2026-11-05). D1–D12 confirmed. This plan is written so it can be picked up from scratch in a later session.

In this plan, "this repo" or "here" means the script-based original at `/home/geba/Projects/rust-agents` (github.com/gbaeke/rust-agents). Copy what is needed from it; nothing may depend on it afterwards. "The new repo" is this folder, `/home/geba/Projects/rust-agents-gitops`.

This repo deploys with scripts: `kind/cluster.sh`, `kind/agentgateway.sh` and `deploy/deploy.sh`. The new repo deploys the same app onto the same kind setup, but [Argo CD](https://argo-cd.readthedocs.io/) applies everything from git. Both versions stay, so they can be compared side by side. The new repo is created from scratch and is **self-contained**: the Rust source (`agent/`, `mcp-server/`, `knowledge-base/`, `Cargo.toml`, `Cargo.lock`, `Dockerfile`), the manifests and the cluster config are all copied from here. After that, neither repo depends on the other, and they can drift apart.

## Goal

| Phase | Outcome |
|---|---|
| **1. Cluster, registry and Argo CD** | A second kind cluster `gitops` with a local image registry, Argo CD installed by one script, and a root Application that syncs the repo. |
| **2. Platform from git** | Gateway API CRDs, agentgateway (CRDs and controller), Sealed Secrets and a **central AI gateway** shared by all agents (see D9), each an Argo Application, installed in the right order with no script. |
| **3. The app from git** | rust-agents (agent, MCP server, Postgres, network policies) synced by Argo, including its secrets. It behaves like the script version, but its model and tool calls go through the shared gateway with its own key. |
| **4. Day-to-day flow** | A new image is built and released by changing its tag in git. Drift is undone automatically, and a rollback is a `git revert`. |
| **5. Many apps** | An ApplicationSet turns each folder under `apps/` into an app in its own namespace, limited by an AppProject. A second agent shares the central gateway with its own key, limits and usage. |

Each phase ends with a checkpoint where the user reviews the result before the next one starts.

## Rules carried over from this repo

- No sudo: when a command needs it, give the user the command.
- The Anthropic key never goes in git (not even encoded) or in process arguments. Read it from a file and pass it on stdin.
- Confirm before creating the GitHub repo and before every push.
- Tools come from mise. Don't commit someone else's `mise.toml`.
- The admin UI pages `/ui/llm/analytics` and `/ui/llm/logs` are unlisted (see this repo's `CLAUDE.md`). Copy that note into the new repo's `CLAUDE.md`.

## Decisions (confirmed 2026-11-05)

| # | Question | Proposal | Why / alternative |
|---|---|---|---|
| D1 | Repo name and visibility | `gbaeke/rust-agents-gitops`, **public** | Argo then needs no repo credentials. Only encrypted secrets are in git. If it's private, Argo needs a deploy key, which becomes one more secret to create at bootstrap. |
| D2 | Where images come from | A **local registry** container `kind-registry` (host port 5001), built from the repo's own source by `scripts/release.sh` | CI in the same repo pushing to ghcr.io is a possible later step. Its tag-bump commit must not trigger another build, so filter the workflow on source paths. |
| D3 | Image tags | The short hash of the last commit that touched the source (`git log -1 --format=%h -- agent mcp-server knowledge-base Cargo.toml Cargo.lock Dockerfile`). Refuse to release while those paths have uncommitted changes. | Argo only reacts to changes in git, so a reused `:dev` tag would never roll out. The release commit itself only changes `apps/`, so it doesn't change the tag. |
| D4 | Secrets in git | **Sealed Secrets.** The sealing key is backed up outside git and restored before the controller starts. | Without the backup, every `cluster.sh down` and `up` means sealing everything again. External Secrets Operator needs a secret store, so it's overkill for kind. |
| D5 | Second cluster or the same one | A **second cluster `gitops`**, next to `dev` | The script and GitOps versions don't fight over one namespace. The cost is about 1.3 GiB more RAM, and the machine has 27 GB. |
| D6 | Ports | Host ports **31000–31009** → NodePorts 30000–30009 | Apps keep the same NodePorts as on `dev`. ufw-docker matches the container port, so the existing `ufw route allow … 30000:30009` should cover it. Verify. The agent is at `http://omarchy:31000`, and the Argo UI at `http://omarchy:31009`. |
| D7 | Repo layout | App-of-apps with one root, below | It's the common pattern and easy to follow in the Argo UI. |
| D8 | Who manages Argo itself | Helm installs it once at bootstrap. Argo managing itself is optional, in phase 4. | Self-management is neat, but a mistake there can break Argo. |
| D9 | One gateway per app, or a central one | **One central AI gateway** in namespace `ai-gateway`, owned by the platform, shared by all agents. Think of it as Azure API Management with AI gateway policies (details below the table). | The script version runs one proxy per app (a `Gateway` in `rust-agents`). That isolates apps but leaves model governance to each app, which is the opposite of the goal: central models, keys, policies and spend. |
| D10 | Who declares an app's MCP tools on the gateway | **All central:** each app's AgentgatewayBackend and HTTPRoute live in `platform/ai-gateway/`, not in the app | Apps only run workloads and can't touch the gateway at all. The cost: adding an agent or a tool server is also a platform change. |
| D11 | How the gateway tells agents apart | **A gateway key per app from the start.** Calls without a valid key are refused. | Per-agent policies, limits and usage need an identity. A key per app is the simplest one agentgateway supports (`apiKeyAuthentication`). |
| D12 | The second app in phase 5 | **A second instance of the agent** in its own namespace, from a kustomize base with one overlay per agent. `hello` is dropped. | That proves the point of D9: two agents sharing one gateway, each with its own key, models and limits. |

### D9 in detail: the central AI gateway

What the platform owns, in `platform/ai-gateway/` and namespace `ai-gateway`:
- **The Gateway** `ai-gateway`, plus its AgentgatewayParameters: 2–3 replicas, ClusterIP, seccomp, and the request-log database.
- **The model catalogue:** one AgentgatewayModel per allowed model. Only these are served.
- **The provider keys,** such as the Anthropic key, as a SealedSecret. No agent ever sees them.
- **Its own Postgres,** for request logs and the analytics page across all agents. It no longer uses an app's database.
- **The central policies:** who may call (each agent's key), which models each agent may use, token and request limits per agent, and later prompt guards and budgets.
- **Each app's MCP route** (D10), in `platform/ai-gateway/apps/<app>.yaml`: an AgentgatewayBackend pointing at `mcp-server.<app>.svc.cluster.local:8081`, and an HTTPRoute on `/<app>/mcp`.
- **Each app's key entry** (D11), in the same file: a ConfigMap labelled `ai-gateway.platform/api-key: "true"` holding only the key's hash, `{"keyHash": "sha256:…", "metadata": {"app": "<app>"}}`. A hash of a random 32-byte key can't be reversed, so this ConfigMap doesn't need sealing. One AgentgatewayPolicy selects all of these ConfigMaps (`apiKeyAuthentication.configMapSelector`) and reads the key from the `x-api-key` header, which is where rig's Anthropic client sends it. Other policies can then match on `apiKey.app`.

What an app owns, in its own namespace: only workloads.
- **The agent, its MCP servers and its own Postgres** (for chats only).
- **Its gateway key,** as a SealedSecret, passed to the agent as `ANTHROPIC_API_KEY`. `scripts/agent-key.sh <app>` makes a new random key, seals it into `apps/<app>/sealed-gateway-key.yaml`, and writes its hash into `platform/ai-gateway/apps/<app>.yaml`. The raw key only ever travels on stdin into `kubeseal`.
- **Its base URLs:** `ANTHROPIC_BASE_URL=http://ai-gateway.ai-gateway.svc.cluster.local:8080` (check the generated Service name) and `MCP_URL=.../rust-agents/mcp`.

How it's enforced:
- **The listener** has `allowedRoutes.namespaces.from: Same`: only objects in `ai-gateway` can attach to the Gateway.
- **AppProject `apps`** puts every `gateway.networking.k8s.io` and `agentgateway.dev` kind on its blocklist. An app can't add models, routes, backends or policies.
- **NetworkPolicies:**
  - agents may reach only the gateway's proxy pods in `ai-gateway` on 8080, plus their own Postgres and DNS;
  - the gateway accepts only namespaces labelled `ai-gateway.platform/client: "true"`, which apps set on their namespace;
  - each app's MCP servers accept only the `ai-gateway` namespace's proxy pods;
  - the gateway's Postgres accepts only the gateway and its db Job.

Check while building (agentgateway v1.7.0):
- per-client rate and token limits (`traffic.rateLimit`), and how to restrict a client to certain models (`traffic.authorization` with a CEL rule on `apiKey.app` and the requested model);
- whether the request logs record which key made each call (`apiKey.app`), so usage can be split per agent;
- whether a route prefix like `/rust-agents/mcp` reaches the MCP target's own path `/mcp` unchanged, or needs a URL rewrite;
- whether the API-key policy, when it targets the whole Gateway, also covers the MCP routes, and that it doesn't break the replacement of the client key with the Anthropic key.

Found already: `traffic.apiKeyAuthentication` takes a `secretRef`, `secretSelector` or `configMapSelector`; ConfigMap-backed keys must be `keyHash`; the header is set with `location.header.name`.

## Repo layout

```
rust-agents-gitops/
  README.md                 what this is, the comparison with the script version, quick start
  CLAUDE.md                 UI page note, rules above
  docs/plan.md              this plan, updated as phases complete
  Cargo.toml, Cargo.lock    the workspace, copied from rust-agents
  Dockerfile                same multi-stage build: targets agent and mcp-server
  agent/, mcp-server/       Rust source, copied
  knowledge-base/           baked into the agent image, copied
  cluster/
    cluster.yaml            kind config: 1 control-plane + 2 workers, ports 31000-31009, registry mirror
    cluster.sh              install | up | start | stop | status | down (also starts the registry)
  bootstrap/
    bootstrap.sh            restore the sealing key, helm install Argo CD, apply root.yaml
    argocd-values.yaml      NodePort 30009, insecure (http), health checks (see phase 1)
    root.yaml               the root Application → argocd/
  argocd/                   what the root syncs: only Argo objects
    platform.yaml           Applications: gateway-api-crds, agentgateway-crds, agentgateway, sealed-secrets
    projects.yaml           AppProject `platform`, AppProject `apps`
    apps.yaml               the ApplicationSet over apps/*
  platform/
    gateway-api/kustomization.yaml   remote standard-install.yaml at the pinned version
    ai-gateway/             D9: namespace, Gateway, Parameters, models, policies, provider keys, its Postgres
      apps/<app>/           D10/D11: per app, key.yaml (its key hash) and mcp.yaml (its MCP backend + route)
  bases/
    rust-agent/             phase 5: the agent app as a kustomize base (phase 3 keeps it in apps/rust-agents)
  apps/
    rust-agents/            kustomize: the manifests from deploy/k8s minus the gateway, plus its sealed secrets
    <second agent>/         phase 5: an overlay of bases/rust-agent (D12)
  scripts/
    seal.sh                 seals the provider key (from a .env file) for platform/ai-gateway/
    agent-key.sh            makes a gateway key for one agent: sealed for the app, hash for the gateway
    release.sh              build and push images, set tags, commit (push after confirming)
    sealing-key.sh          backup | restore of the Sealed Secrets key (to ~/.config/rust-agents-gitops/)
```

---

## Phase 1: cluster, registry and Argo CD

**Built 2026-11-05.** What was learned:
- The source came from rust-agents `5a40b5f`.
- Registry: kind's guide now uses `registry:3`. On kind v0.33 the nodes read `/etc/containerd/certs.d` already, so the `containerdConfigPatches` entry was left out. Only `hosts.toml` per node is needed, and the busybox test passed.
- Argo CD: chart 10.14.0, which is Argo CD v3.6.1. The `argocd` CLI from mise is 3.6.0, and `kubeseal` is 0.41.2.
- Health checks: v3.6.1 has a built-in one for Gateway (waits for `Programmed=True`) and the other Gateway API kinds. It has none for Application or agentgateway, so `argocd-values.yaml` adds Lua for Application, AgentgatewayBackend (`status.conditions` Accepted) and AgentgatewayModel (route-style `status.parents[].conditions`). The two agentgateway checks are untested until there are such objects.
- Checkpoint 1 results:
  - the root is Synced and Healthy at `c8bcf1e`, with no children;
  - the UI answers on `localhost:31009`;
  - memory: Argo CD uses about 200 MiB (application-controller 99, repo-server 36, applicationset-controller 32, server 28, redis 7);
  - the whole `gitops` cluster at idle takes about 1.8 GiB of node containers (control plane 1.14 GiB, workers 0.29 and 0.39 GiB), and the registry 20 MiB;
  - there's no metrics-server, so these numbers come from `crictl stats` and `docker stats`.

1.1 **Create the repo.** After confirming D1, run `gh repo create`, then:
- copy the Rust source, as listed in the layout above, from this repo at its current `main`. Note the source commit in the first commit message. Leave out `compose.yaml`, `kind/`, `deploy/` and `target/`;
- check that `cargo build` and `docker build --target agent` work there;
- add the README skeleton, this plan as `docs/plan.md`, and `.gitignore` (`target/`, `.env`, `*.key`, `*-key.yaml`).

1.2 **`cluster/cluster.yaml` and `cluster.sh`.** Start from this repo's `kind/` and change:
- the name, with `KIND_CLUSTER` defaulting to `gitops`;
- the port mappings, from host 31000–31009 to container 30000–30009;
- a `containerdConfigPatches` entry for `/etc/containerd/certs.d`, so the nodes can pull `localhost:5001/...` from the registry. Follow kind's "local registry" guide.

`cluster.sh up` also starts the `kind-registry` container (`registry:2`, `127.0.0.1:5001→5000`) if it isn't running. It connects the container to the `kind` network, writes `hosts.toml` into each node, and applies kind's `local-registry-hosting` ConfigMap. `install` also installs the `argocd` and `kubeseal` CLIs through mise. `down` leaves the registry running, since another cluster may use it.

1.3 **`bootstrap/bootstrap.sh`:**
1. Check that the context `kind-gitops` exists.
2. If a sealing key backup exists, restore it into `kube-system` before Sealed Secrets starts (see 2.4).
3. `helm upgrade -i argocd argo/argo-cd -n argocd --create-namespace -f argocd-values.yaml --version <pinned>`. Pin the latest stable chart, checked at the start.
4. Wait for the server.
5. `kubectl apply -f root.yaml`.
6. Print the UI URL and the admin password (`argocd-initial-admin-secret`).

Subcommands: `password`, `status`, `uninstall`.

1.4 **`argocd-values.yaml`:**
- `server.service.type: NodePort` with nodePort 30009, and `configs.params.server.insecure: true`. It's plain http on a lab machine; say so in the README.
- **A health check for `argoproj.io/Application`.** Since Argo CD 1.8 a parent doesn't wait for its child Applications to be healthy. Without this check, the platform's sync waves don't order anything. Use the Lua snippet from the Argo docs ("App of Apps" / sync waves).
- Health checks for `gateway.networking.k8s.io/Gateway` (condition `Programmed=True`) and `agentgateway.dev/AgentgatewayModel` / `AgentgatewayBackend` (`Accepted=True`). Check first whether the pinned Argo already has them built in; if not, add Lua under `resource.customizations.health.<group>_<kind>`.
- Skip dex and notifications to save memory.

1.5 **`root.yaml`:** an Application for `argocd/` on `main`, with `automated: {prune: true, selfHeal: true}`.

**Checkpoint 1:** the Argo UI opens at `http://omarchy:31009`, the root Application is Synced and Healthy (with nothing under it yet), and the registry answers. Test that by tagging and pushing a `busybox` image and running a pod from `localhost:5001/busybox`. Record how much memory Argo uses.

---

## Phase 2: the platform from git

2.1 **AppProject `platform`:** may create cluster-wide resources (CRDs, ClusterRoles, webhooks) and deploy to `agentgateway-system`, `ai-gateway`, `kube-system` and `argocd`. Apps don't get this project.

2.2 **Applications in `argocd/platform.yaml`,** in sync waves:

| Wave | Application | Source | Notes |
|---|---|---|---|
| -3 | `sealed-secrets` | Helm chart `sealed-secrets` (bitnami-labs repo), pinned | `fullnameOverride: sealed-secrets-controller` in `kube-system`. That's the name and place `kubeseal` expects by default. |
| -3 | `gateway-api-crds` | `platform/gateway-api` (kustomize, remote `standard-install.yaml` v1.6.3) | `ServerSideApply=true`: the CRDs are too large for a client-side apply. |
| -2 | `agentgateway-crds` | OCI Helm `cr.agentgateway.dev/charts/agentgateway-crds` v1.7.0 | `ServerSideApply=true`. In Argo the OCI repo is written without `oci://` and with `enableOCI`. Check the current syntax. |
| -1 | `agentgateway` | OCI Helm `cr.agentgateway.dev/charts/agentgateway` v1.7.0 | Namespace `agentgateway-system`, `CreateNamespace=true`. Same values as `kind/agentgateway.sh` (none so far). |

Found while building 2.2:
- **Sealed Secrets:** the chart moved to `https://bitnami.github.io/sealed-secrets` (the bitnami-labs URL gives a 404). It's pinned at 2.22.0 (controller 0.41.2), with `keyrenewperiod: "0"` so there's only ever one key to back up.
- **OCI:** Argo v3.6 takes OCI as a native source (`repoURL: oci://cr.agentgateway.dev/charts/<chart>`, `path: .`, `targetRevision: v1.7.0`), so `enableOCI` isn't needed.
- **Finalizers:** the platform Applications have no resources-finalizer, so removing one from git can't delete CRDs and everything of their kinds.
- **Gateway API:** v1.7.0 is out (2026-10-29), but this stays on v1.6.3, as in the script version.

- **A project needs a destination namespace even for cluster-scoped apps.** `gateway-api-crds` first had none, and the project rejected the empty namespace (`InvalidSpecError`). It now targets `kube-system`, which CRDs ignore.
- **A stuck wave doesn't fix itself from git.** The root's sync, pinned to the bad commit, kept waiting for the invalid child to turn Healthy. While it ran, auto-sync didn't pick up the fix. Terminating it got things going: `argocd app terminate-op root`, or set `status.operationState.phase: Terminating` on the Application. This is the cost of making the root wait for each wave's health.
- **Waves work:** after the fix, `agentgateway-crds` was only created once wave -3 was Healthy, and `agentgateway` after it. It took about 40 s in total.

2.3 **The GatewayClass.** The controller chart has no GatewayClass and no Helm hooks: the controller creates `agentgateway` itself at runtime. So Argo doesn't track it and won't prune it. Confirmed: it appears and is Accepted about 20 s after the controller starts.

2.4 **`scripts/sealing-key.sh`:**
- `backup` saves the Secret labelled `sealedsecrets.bitnami.com/sealed-secrets-key` from `kube-system` to `~/.config/rust-agents-gitops/sealing-key.yaml`, mode 600.
- `restore` applies that file, and `bootstrap.sh` runs it first.

Run `backup` once, right after the controller first starts. Done 2026-11-05. The certificate's SHA-256 fingerprint is `EB:9E:BF:01:…:E8:03:23` (`scripts/sealing-key.sh cert | openssl x509 -noout -fingerprint -sha256`). After a rebuild it must be the same.

2.5 **The central AI gateway** (D9), as an Application `ai-gateway` at wave 0 in project `platform`. Its order inside the Application:
1. namespace;
2. SealedSecrets (`anthropic` from `seal.sh`, the gateway Postgres password);
3. Postgres;
4. the db Job that creates the `agentgateway` database (see 2.6);
5. Gateway and Parameters: 2 replicas, listener `allowedRoutes.namespaces.from: Same`, request-log database;
6. models, the API-key policy and the per-app files under `apps/` (empty until phase 3);
7. NetworkPolicies.

2.6 **The `agentgateway` database: no Job needed.** The gateway has a Postgres of its own, so the image creates the database on first start, with `POSTGRES_USER` and `POSTGRES_DB` both set to `agentgateway`. That replaces the planned Sync-hook Job and the `psql` exec from `deploy.sh`.

Built as: `platform/ai-gateway/` synced as a directory with `recurse: true`, so a new `apps/<app>/` folder needs no list to be edited. Waves inside the Application:
- -2: namespace;
- -1: SealedSecrets;
- 0: Postgres;
- 1: Gateway and Parameters;
- 2: models, the `api-keys` policy, key ConfigMaps and NetworkPolicies.

Both `claude-sonnet-5-5` and `claude-haiku-5-5` are declared. Haiku keeps tests cheap, and phase 5's second agent will use it.

2.7 **`scripts/seal.sh <path to .env>`** reads the Anthropic key from the `.env` line as `deploy.sh` did. It builds the Secret `anthropic` (`Authorization=<key>`) with `kubectl create secret generic --dry-run=client -o yaml --from-env-file=/dev/stdin` and pipes it into `kubeseal -o yaml`. It writes `platform/ai-gateway/sealed-anthropic.yaml`. Nothing unencrypted touches the disk or a process argument. The gateway's Postgres password is sealed the same way, generated **only if** the sealed file doesn't have it yet, because a new password would lock Postgres out of its existing data.

A SealedSecret is encrypted for its namespace and name (the default strict scope). Keep both as they are.

Then test the gateway with a temporary key from `agent-key.sh test` and curl from a throwaway pod in a namespace labelled as a client:
- a declared model answers;
- an undeclared model gets 404;
- no key or a wrong key is refused;
- a pod in an unlabelled namespace can't connect at all.

Remove the `test` key afterwards.

**Checkpoint 2:** all five Applications are Synced and Healthy, `kubectl get gatewayclass agentgateway` is Accepted, and the Gateway `ai-gateway` is Programmed. Then test the order: run `cluster.sh down`, `up` and `bootstrap.sh`, and check that the platform comes back with no manual step and the same sealing key (compare `kubeseal --fetch-cert` before and after).

---

## Phase 3: the app from git

3.1 **Copy the manifests.** Copy `deploy/k8s/*` from this repo into `apps/rust-agents/`, then adapt:
- **Leave out `gateway.yaml`.** Its model moves to `platform/ai-gateway/`. Its MCP backend and route become `platform/ai-gateway/apps/rust-agents.yaml` (D10), on `/rust-agents/mcp` and pointing at `mcp-server.rust-agents.svc.cluster.local:8081`.
- **`agent-config`:** `ANTHROPIC_BASE_URL` and `MCP_URL` point at the central gateway. `ANTHROPIC_API_KEY` is no longer a literal: it comes from Secret `gateway-key`.
- **Namespace:** add the label `ai-gateway.platform/client: "true"`.
- **NetworkPolicies:** the agent's egress goes to the proxy pods in namespace `ai-gateway`, and the MCP server's ingress comes from them.
- **Images:** `localhost:5001/rust-agents/agent` and `localhost:5001/rust-agents/mcp-server`, tags set through `images:` in `kustomization.yaml`, and `imagePullPolicy: IfNotPresent`. That's fine now that tags are never reused.
- **Remove** the comments that refer to `deploy.sh`, and point them at the new scripts.

3.2 **Secrets.** The provider key belongs to the platform (2.7). The app gets two Secrets:
- `gateway-key`, from `agent-key.sh rust-agents` (D11), which also writes the hash into `platform/ai-gateway/apps/rust-agents.yaml`;
- `postgres`, for its own Postgres (chats only), sealed the same way as the gateway's in 2.7: generated once, never replaced.

Both go in `apps/rust-agents/sealed-secrets.yaml`.

3.3 **No `agentgateway` database here.** It lives with the central gateway (2.6), so the app has no db Job.

3.4 **Sync waves for the resources** (annotation `argocd.argoproj.io/sync-wave`):

| Wave | Resources |
|---|---|
| -2 | Namespace (with the restricted and client labels) |
| -1 | SealedSecrets, the `agent-config` ConfigMap |
| 0 | Postgres StatefulSet and Service |
| 1 | mcp-server, agent, PDBs, NetworkPolicies |

The gateway is platform, so it's already running when the app syncs. The app's MCP route sits in the `ai-gateway` Application and may sync before the MCP server exists; it shows unhealthy until then, which is fine.

3.5 **The Application.** For now, add a plain Application `rust-agents` in `argocd/` (the ApplicationSet replaces it in phase 5), in project `apps`, destination `rust-agents`. Don't use `CreateNamespace`: the namespace comes from git, with its security labels.

3.6 **Things to watch for:**
- **Controller-made objects** (in phase 2, in `ai-gateway`). The proxy Deployment and Service are made by the controller and must not be pruned or shown as OutOfSync. Check how Argo treats them: they carry an ownerReference to the Gateway, so they should show as its children.
- **Fields filled in after apply** (also phase 2). Anything on AgentgatewayParameters or Gateway that the API server or controller fills in, causing a permanent OutOfSync, gets `ServerSideApply=true` on the Application or a narrow `ignoreDifferences`.
- **The Postgres PVC** comes from `volumeClaimTemplates`, so Argo doesn't own it and deleting the Application keeps the data. Document this, and give `scripts/` a `wipe` command that deletes the namespace after confirming.

3.7 **First release.** `scripts/release.sh`:
1. Refuse if the source paths have uncommitted changes. The tag is as in D3.
2. `docker build --target agent` and `--target mcp-server` from the repo root.
3. Push to `localhost:5001`.
4. `kustomize edit set image` (or `kubectl kustomize` tooling) in `apps/rust-agents`.
5. Commit "Release rust-agents <sha>".
6. Show the diff, and push only after confirming.

Then `argocd app sync rust-agents` or a refresh, so we don't wait for the 3-minute poll.

**Checkpoint 3:** repeat the checks done on the script version (see `docs/kubernetes-plan.md`):
- 3 agent pods, and a chat that continues across pods and after every pod is deleted;
- 409 when busy;
- reset;
- an undeclared model refused (404);
- direct egress blocked;
- the request log rows in the central gateway's analytics page, marked as rust-agents' calls;
- the agent's pods can't reach `api.anthropic.com` directly, and a wrong gateway key gets refused.

Then run `cluster.sh down`, `up` and `bootstrap.sh`, and check that the whole app comes back from git with no other step. Postgres data is lost then, since the PVC goes with the cluster. That's expected.

---

## Phase 4: day-to-day flow

4.1 **A release:** change code in this repo, commit, `release.sh`, push, sync. Agent pods roll and nothing else changes.

4.2 **A setting:** change `SESSION_TTL_DAYS` in git and push. The ConfigMap hash changes, the pods roll, and the old ConfigMap is pruned.

4.3 **Drift:** `kubectl scale deploy/agent --replicas=1` is reverted by selfHeal within seconds. `kubectl delete networkpolicy agent-egress` comes back.

4.4 **Rollback:** `git revert` the release commit and push, and the old images come back. Compare this with Argo's own History/Rollback, which is disabled while auto-sync is on.

4.5 **Inner loop.** Document how to iterate fast without a commit per edit:
- `argocd app set rust-agents --sync-policy none`, then `kubectl set image` or `kind load`;
- re-enable auto-sync and release properly when done.

4.6 **Optional:** Argo manages itself. An Application `argocd` for the same chart and values in project `platform`. Only do this if the user wants it (D8).

**Checkpoint 4:** write in the README a short comparison with the script version: what each step costs, what git now records, and what still needs a script (the cluster, the bootstrap, sealing, images).

---

## Phase 5: many apps

5.1 **ApplicationSet `apps`.** A git directory generator over `apps/*`:
- each directory gives an Application named after it, deployed to the namespace with that name, in project `apps`;
- the same auto-sync and prune settings;
- it replaces the hand-made Application from 3.5. Watch that the change doesn't delete and recreate the app's resources: use the same Application name, and check `preserveResourcesOnDeletion` before switching.

5.2 **AppProject `apps`:**
- **Cluster-wide resources:** only `Namespace`, so no CRDs, ClusterRoles or webhooks. Apps use the platform; they don't change it.
- **Namespaced resources:** every `gateway.networking.k8s.io` and `agentgateway.dev` kind is blocked (D10).
- **Destinations:** this cluster, any namespace except `kube-system`, `argocd`, `agentgateway-system` and `ai-gateway`. Check that the pinned Argo supports `!` exclusions in destinations; if not, list the app namespaces.
- **Source:** only this repo.

5.3 **A second agent** (D12):
- Move `apps/rust-agents/` into a kustomize base `bases/rust-agent/`, and make `apps/rust-agents/` an overlay of it. Its rendered output must stay the same: compare `kubectl kustomize` before and after, so Argo sees no change.
- Add `apps/<second agent>/` as a second overlay. Pick the name then. It has its own namespace, a different `AGENT_MODEL` (for example `claude-haiku-5-5`) and NodePort 30001 → `http://omarchy:31001`.
- Run `agent-key.sh <second agent>`. That gives the app its key and the platform its file with the key hash and MCP route.

Adding the two folders and pushing are the only steps.

5.4 **Show the shared gateway at work:**
- each agent gets only the models its policy allows;
- going over the second agent's token or request limit throttles it and not rust-agents;
- the analytics show usage per agent;
- adding an AgentgatewayModel or HTTPRoute in the second agent's folder fails the sync with a project error;
- adding a ClusterRole there fails the same way.

**Checkpoint 5:** two agents, each from its folder, each limited to its namespace and sharing one gateway with its own key and limits. Removing a folder removes its app; its file in `platform/ai-gateway/apps/` has to go with it.

---

## Open questions to check while building

- The current Sealed Secrets chart version, and the exact OCI Helm source syntax for agentgateway charts. (Argo CD: chart 10.14.0, see phase 1.)
- ~~Whether Argo has built-in health checks for Gateway API and agentgateway resources (1.4).~~ Gateway API yes, agentgateway no; see phase 1.
- ~~Whether kind's registry setup still uses `certs.d` / `hosts.toml` on kind 0.33.~~ `hosts.toml` yes, the containerd patch is no longer needed; see phase 1.
- Whether the existing ufw-docker rule covers the new host ports (D6).
- The D9 questions above.
- Memory with both clusters and Argo running.
