# Plan: the GitOps setup on Azure (AKS, managed PostgreSQL)

Status: **draft, nothing built.** Decisions A1–A14 are proposals, not yet confirmed. Written 2026-11-06.

This plan takes what runs on kind today and builds it again on Azure: AKS instead of kind, Azure Database for PostgreSQL flexible server instead of a Postgres pod per app, and Azure services for registry, secrets, identity and monitoring. The techniques stay the same: Argo CD syncs everything inside the cluster from git, an app-of-apps root with sync waves, an ApplicationSet over `apps/*`, AppProjects as guard rails, and the central AI gateway (D9) owned by the platform. What changes is everything around the cluster, which now also comes from code (Bicep), and the way secrets and identity work.

It follows the Cloud Adoption Framework (CAF) for the landing zone, naming, tagging and governance, and the Well-Architected Framework (WAF) for the workload. The last section maps both to the plan. The AKS baseline reference architecture is the model for the cluster.

## Goal

| Phase | Outcome |
|---|---|
| **0. Decisions and prerequisites** | A1–A14 confirmed, subscription ready, quotas checked, Entra groups and the deploy identity in place. |
| **1. Landing zone** | Management (logs, policy, Defender, budgets) and networking (hub, spoke, firewall or NAT, private DNS) from Bicep, deployed by a pipeline. |
| **2. Shared services** | ACR, Key Vault, the PostgreSQL flexible server, Claude models in Microsoft Foundry and the managed identities, all private. |
| **3. Cluster and Argo CD** | A private-by-default AKS cluster with Entra sign-in, workload identity and Cilium, and Argo CD syncing the root from git. |
| **4. Platform from git** | Gateway API, agentgateway, External Secrets, the ingress controller and the central AI gateway on Foundry, in sync waves as today. |
| **5. The apps from git** | Both agents running on AKS: databases on the flexible server with Entra sign-in, secrets from Key Vault, a private (or WAF-protected) UI with sign-in. |
| **6. Day two** | Images built in CI, promotion from dev to prod, upgrades, backup and restore drills, dashboards, alerts and a cost review. |

Each phase ends with a checkpoint where the user reviews the result before the next one starts, as in `docs/plan.md`.

## Rules carried over

- No sudo: when a command needs it, give the user the command.
- No secret in git, not even encoded, and none in process arguments. On Azure most secrets disappear (workload identity); the rest live in Key Vault and are written to it from stdin or a file.
- Confirm before creating the GitHub repo, before every push, and **before every deployment that creates or deletes Azure resources** (they cost money; show the what-if first).
- Tools come from mise (`az`, `bicep`, `kubelogin`, `kubectl`, `helm`, `argocd`). Don't commit someone else's `mise.toml`.

## What carries over and what changes

| Today (kind) | On Azure | Why |
|---|---|---|
| `cluster/cluster.sh` (kind) | Bicep in `infra/`, deployed by a GitHub Actions workflow | The cluster and everything around it become code too. |
| `bootstrap/bootstrap.sh` (Helm installs Argo CD) | The AKS Argo CD extension (GA on AKS), set up by Bicep; bootstrap only applies `root.yaml` | Microsoft keeps Argo CD patched; Entra SSO and workload identity come built in. See A8. |
| Local registry `localhost:5001` | Azure Container Registry, private, pulled by the kubelet identity | |
| Sealed Secrets, sealing key backup | Key Vault + External Secrets Operator (A6), and workload identity wherever a password can go away | No sealing key to back up; Key Vault holds what's left. |
| A Postgres StatefulSet per app, one for the gateway | One flexible server, one database per app plus `agentgateway` (A5) | Managed backups, patching, HA. |
| Anthropic API key, sent by the gateway | Claude in Microsoft Foundry, reached over a private endpoint with the gateway's workload identity (A4) | No provider key at all; Azure billing, quotas and data boundary. |
| NodePort 30000 on the host | Internal load balancer, or Application Gateway for Containers with WAF, plus Entra sign-in (A9) | The UI has no sign-in of its own. |
| NetworkPolicies (kind's CNI) | The same NetworkPolicies, enforced by Cilium, plus Cilium FQDN policies for egress | |
| `release.sh` on the laptop | A CI workflow builds and pushes to ACR, and opens a PR with the new tag | Same tag scheme (D3). |
| The admin UI by port-forward | The same; Argo CD UI behind Entra SSO | |

Unchanged: the AppProjects `platform` and `apps`, the ApplicationSet, the sync waves and the Application health check from `argocd-values.yaml`, D9–D12 (central gateway, MCP routes and keys in `platform/ai-gateway/apps/<app>/`, one overlay per agent), the PDBs, the restricted pod security labels.

## Decisions (to confirm)

| # | Question | Proposal | Why / alternative |
|---|---|---|---|
| A1 | Where the code lives | A **new repo `rust-agents-azure`**, copied from this one, self-contained, as this repo was copied from the script version | The kind setup keeps working and the two can be compared. Alternative: environments as folders in this repo (`clusters/kind`, `clusters/aks-dev`). That avoids a copy, but every platform folder needs a kind and an Azure variant from day one. |
| A2 | Landing zone | **An application landing zone in the CAF shape, sized for one subscription:** a platform part (management and connectivity) and a workload part, each in its own resource groups, with the relevant Azure Landing Zone policies assigned at subscription scope | A real ALZ (management groups, platform subscriptions) is the target in an organisation. The plan keeps the same split, so moving the workload into a real Corp landing zone later only changes where the platform parts come from. |
| A3 | How Azure resources are made | **Bicep with Azure Verified Modules (AVM)** for everything outside the cluster, deployed by GitHub Actions with OIDC (no stored credential), `what-if` on every PR. **Azure Service Operator (ASO)** only for what belongs to one app (A10). | Bicep is Azure's own and AVM modules carry WAF defaults. Terraform works as well. ASO for everything would put the cluster in charge of the network it runs on, which makes a rebuild circular. |
| A4 | Model provider | **Claude in Microsoft Foundry**, on a Foundry resource with a private endpoint; agentgateway authenticates with **its workload identity** (Entra), no key. Anthropic's own API stays a fallback provider, off by default. | agentgateway's Azure provider supports Foundry (`resourceType` foundry; models named `claude-*` go to the Anthropic-native path) and implicit Entra auth through workload identity. **Check** that v1.7.0's `AgentgatewayModel` takes that provider, or whether it needs an `AgentgatewayBackend`. **Check** which Claude models are hosted on Azure in the chosen region (Haiku 5.5 is GA hosted on Azure) and the default quota. |
| A5 | PostgreSQL shape | **One flexible server**, databases `agentgateway`, `rust_agents`, `research_agent`. Reached over a **private endpoint** (public access off). **Entra authentication**, password authentication off once agentgateway can do without (see A7). Dev: Burstable B2s, 7-day backups. Prod: General Purpose D2ds, zone-redundant HA, 35-day backups, geo-redundant backup. | Separate databases, not one shared database: the table names and advisory-lock keys have no app prefix (`todo.md`). Private endpoint over VNet integration: it fits a hub with central private DNS, and it can be added to or removed from an existing server. |
| A6 | Secrets that remain | **Key Vault (RBAC mode, private endpoint) + External Secrets Operator.** One vault for the platform, one per app (CAF: a vault per app per environment). Each app's `SecretStore` uses that app's workload identity, so an app can read only its own vault. | ESO fits GitOps: the `ExternalSecret` is in git and makes an ordinary Secret, so `secretKeyRef` keeps working. The AKS Key Vault CSI add-on is managed by Microsoft but needs a volume mount to sync a Secret. |
| A7 | Database sign-in | **Agents: Entra tokens with their workload identity** (a code change, phase 5). **agentgateway: a password in Key Vault** until it supports Entra for its request-log database. | Tokens expire after about an hour, so the agent must refresh them (see "Code changes"). Check agentgateway's database options first; if it can take a token, switch it as well and turn password auth off. |
| A8 | Argo CD | **The AKS Argo CD extension**, set up by Bicep with the values from today's `argocd-values.yaml` (health checks, the Application check), Entra SSO with Entra groups mapped to Argo roles, and HA mode in prod (redis-ha needs four nodes). | Alternative: Helm from the bootstrap as today. Check first that the extension passes every key we use (`configs.cm` Lua health checks, `resource.customizations`). If one is missing, install by Helm and accept the patching work. |
| A9 | How users reach the agent UI | **Dev: internal only** (internal load balancer, reached over Bastion or a point-to-site VPN). **Prod: Application Gateway for Containers with a WAF policy**, Entra sign-in in front (oauth2-proxy or Entra's own auth at the edge), TLS certificate from Key Vault. | The UI has no sign-in, and the session id is the only thing that keeps sessions apart. It must never be public without sign-in in front. AGC speaks Gateway API, like agentgateway, so both are just GatewayClasses. |
| A10 | Per-app Azure resources | **ASO in the cluster, in the platform layer:** per app a user-assigned managed identity, its federated credential for the app's service account, and its database on the flexible server. The files go in `platform/azure/apps/<app>/`, next to `platform/ai-gateway/apps/<app>/`, so adding an agent stays "two folders and a push" (D10). | ASO's own identity gets only what this needs on the workload resource group (Managed Identity Contributor, and the database rights on the one server). Role assignments are made through a constrained "Role Based Access Control Administrator" condition that allows only the few roles apps need. Alternative: an app is a Bicep change too, which is simpler but leaves GitOps. |
| A11 | Egress | **Dev: NAT Gateway + Cilium FQDN policies** (Advanced Container Networking Services). **Prod: Azure Firewall** (Standard, or Premium for TLS inspection) with user-defined routes, as in the AKS baseline. | Firewall is the baseline's recommendation but costs several hundred euros a month on its own. The FQDN policies already limit each pod, so dev still blocks what matters. |
| A12 | `fetch_url` on the MCP server | **Allow-list in the firewall** (or FQDN policy) for the MCP server's egress: open-meteo and a short list of sites, and fix the SSRF and body-size items in `todo.md` first. | An unrestricted web fetcher next to private endpoints is the main SSRF risk in the whole design. If the agent must browse freely, give the MCP server its own egress path (Firewall Premium with web categories) and nothing else. |
| A13 | Environments | **dev now, prod later**, as folders: `infra/env/dev`, `infra/env/prod`, and in git `clusters/dev`, `clusters/prod` (one Argo per cluster, each with its own root). Promotion is a PR that copies an image tag from dev to prod. | Folders, not branches: a branch per environment drifts. Each cluster has its own Argo, so a broken prod sync can't come from dev. |
| A14 | Cluster flavour | **AKS Standard with every setting explicit** (below), Free tier in dev, Standard tier (uptime SLA) in prod. | AKS Automatic gives most of these defaults in one switch (Cilium, node auto-provisioning, deployment safeguards, managed Prometheus). It's a good choice later; set explicitly first, so the plan shows what each setting does. |

## Architecture

```
   GitHub (repo, Actions with OIDC)
        |  Bicep what-if / deploy         images -> ACR
        v
 Subscription  (tags: workload, env, owner, costCenter)
 |
 |-- rg-<wl>-mgmt-<env>       Log Analytics, Managed Prometheus, Managed Grafana,
 |                            action groups, budget
 |-- rg-<wl>-conn-<env>       hub VNet: Azure Firewall (prod) or NAT GW (dev),
 |                            Bastion, private DNS zones, DNS Private Resolver (if on-prem)
 |-- rg-<wl>-<env>            spoke VNet (peered):
 |                              snet-aks-nodes   AKS (Azure CNI Overlay + Cilium)
 |                              snet-ingress     AGC (prod) / internal LB
 |                              snet-pe          private endpoints:
 |                                               ACR, Key Vaults, PostgreSQL, Foundry
 |                            ACR, Key Vaults, PostgreSQL flexible server, Foundry,
 |                            managed identities
 `-- rg-<wl>-aks-nodes-<env>  (AKS-managed node resource group, locked down)

 In the cluster, as today:
   argocd (extension) -> root -> platform waves -> ai-gateway -> apps/*
   agents --(own key)--> ai-gateway --(workload identity, private endpoint)--> Foundry
   agents --(Entra token)--> PostgreSQL db per app
   ai-gateway --(password from Key Vault)--> PostgreSQL db agentgateway
```

### Address plan (dev; prod uses its own ranges)

| Range | Use |
|---|---|
| 10.40.0.0/22 | hub: `AzureFirewallSubnet` /26, `AzureFirewallManagementSubnet` /26 (Basic), `AzureBastionSubnet` /26, resolver subnets /28 |
| 10.41.0.0/22 | spoke: `snet-aks-nodes` /24, `snet-ingress` /24 (AGC needs a delegated /24), `snet-pe` /27 |
| 100.64.0.0/16 | pod CIDR (overlay, not routed in the VNet) |
| 172.16.0.0/16 | service CIDR |

Check the ranges against anything the user's other networks use before peering or VPN.

### Naming and tagging

- CAF abbreviations: `rg-`, `vnet-`, `snet-`, `afw-`, `bas-`, `aks-`, `cr` (no dash), `kv-`, `psql-`, `id-`, `log-`, `amg-`, `pe-`. Pattern `<abbr>-<workload>-<env>-<region>-<nn>`, e.g. `aks-ragents-dev-swc-01`.
- Required tags, enforced by policy: `workload`, `env`, `owner`, `costCenter`, `dataClassification`. The node resource group inherits them (AKS propagates tags from the cluster).

## Identity map

Every Azure call is made by a managed identity or an Entra group; no service principal secrets.

| Identity | Federated with | Rights |
|---|---|---|
| `id-github-deploy` | GitHub Actions, `environment:dev` / `environment:prod` subject | Contributor on the workload resource groups, constrained RBAC Administrator, `what-if` on PRs uses a read-only twin |
| `id-github-acr` | GitHub Actions, branch `main` | AcrPush on the registry |
| AKS control plane (user-assigned) | — | Network Contributor on the spoke subnets |
| AKS kubelet | — | AcrPull |
| `id-argocd` | `argocd` service accounts | AcrPull (only if charts or manifests come from ACR as OCI) |
| `id-aso` | `azureserviceoperator-system` | as in A10 |
| `id-eso-platform` | ESO in `ai-gateway` | Key Vault Secrets User on the platform vault |
| `id-ai-gateway` | the gateway's proxy service account | Cognitive Services User on the Foundry resource |
| `id-<app>` (by ASO) | `<app>/agent` service account | Key Vault Secrets User on its own vault; a PostgreSQL role owning its own database |
| `id-db-admin` | the db-init Job's service account | member of the Entra group that is the server's PostgreSQL administrator |
| Entra groups | humans | `grp-aks-admins` (AKS RBAC Cluster Admin, through PIM), `grp-aks-readers`, `grp-argocd-admins`, `grp-argocd-readers`, `grp-psql-admins` |

Local accounts on AKS are disabled; `kubectl` uses Entra through `kubelogin`.

## Code changes needed before phase 5

These change the Rust code, so they go through `release.sh` / CI like any other change:

1. **PostgreSQL with Entra tokens** (`agent/src/store.rs`). A token from workload identity (`azure_identity` crate, the workload identity credential) as the password, refreshed before it expires: build the pool from connect options and replace them with `Pool::set_connect_options` on a timer; the per-turn lock connection takes a fresh token each time. TLS is required (`sslmode=require`; the rustls feature is already on). Keep plain `DATABASE_URL` working for kind and `cargo run`.
2. **Connect directly on port 5432,** never through the built-in PgBouncer (6432): the turn lock is a session-level advisory lock held for the whole turn.
3. **The flooding and bounds items in `todo.md`,** especially the cap on concurrent turns and the pool's `max_connections`. A managed server has a hard connection limit that every app and the gateway share (a few dozen on Burstable).
4. **JSON logs** (the logging items in `todo.md`), so Container Insights and Log Analytics can query fields.
5. **The `fetch_url` SSRF and body-size fixes** (A12).

Not needed: anything for Foundry. The agent still talks the Anthropic API to the gateway with its own key; only the gateway knows it's Foundry behind it.

## Repo layout (new parts)

```
rust-agents-azure/
  infra/
    main.bicep                 subscription scope: resource groups, then the modules
    modules/                   thin wrappers around AVM modules (network, aks, acr, kv, psql, foundry, monitor)
    env/dev.bicepparam         dev profile (A11, A14: NAT, Free tier, Burstable, no AGC)
    env/prod.bicepparam        prod profile (Firewall, Standard tier, HA, AGC + WAF)
    policy/                    policy assignments: ALZ subset, AKS baseline initiative, tags
  .github/workflows/
    infra.yaml                 PR: bicep lint + what-if as a PR comment; main: deploy dev; tag: deploy prod (approval)
    images.yaml                build, scan, push to ACR, open a PR with the new tag
  bootstrap/
    bootstrap.sh               get credentials (kubelogin), apply clusters/<env>/root.yaml, print the Argo URL
  clusters/
    dev/root.yaml, prod/root.yaml   one root per cluster
  argocd/                      as today: platform.yaml, projects.yaml, apps.yaml (per-env values by kustomize)
  platform/
    gateway-api/               as today (unless AGC owns the CRDs, see phase 4)
    external-secrets/          ESO + ClusterSecretStore per vault
    azure/                     ASO + per-app identity, federated credential, database (A10)
    databases/                 db-init Job per app: Entra principal + grants (Sync hook)
    ingress/                   AGC (ALB controller) + Gateway for the UIs (prod), or internal LB (dev)
    ai-gateway/                as today, models point at Foundry, no sealed provider key
  bases/rust-agent/            as today minus postgres.yaml, plus ServiceAccount with the workload identity label
  apps/<app>/                  overlay: ExternalSecret instead of SealedSecrets, its own DB name
```

Gone: `cluster/`, `scripts/seal.sh`, `scripts/sealing-key.sh`, every `sealed-*.yaml`, `bases/rust-agent/postgres.yaml`, `platform/ai-gateway/postgres.yaml`. `scripts/agent-key.sh` stays but writes the raw key into Key Vault (from stdin) instead of sealing it.

---

## Phase 0: decisions and prerequisites

0.1 Confirm A1–A14. Write the confirmed answers into this file, as `docs/plan.md` does.

0.2 **Subscription.** One subscription (A2), with the resource providers registered: `Microsoft.ContainerService`, `Microsoft.KubernetesConfiguration` (extensions), `Microsoft.DBforPostgreSQL`, `Microsoft.CognitiveServices`, `Microsoft.ContainerRegistry`, `Microsoft.KeyVault`, `Microsoft.ServiceNetworking` (AGC, prod), `Microsoft.Monitor`, `Microsoft.Dashboard`, `Microsoft.AlertsManagement`.

0.3 **Region.** Pick one where Claude is hosted on Azure, flexible server has zone-redundant HA, and AKS has three zones. Sweden Central and West Europe are the first to check. Record the paired region for geo-redundant backups.

0.4 **Quotas.** vCPU quota for the node VM family; Claude tokens-per-minute quota in Foundry for each model (default quota depends on the subscription type); flexible server vCores.

0.5 **Entra.** The groups from the identity map. PIM for `grp-aks-admins` if the tenant has it. An app registration for Argo CD SSO (A8).

0.6 **GitHub.** Create the repo (confirm first, A1), environments `dev` and `prod` with required reviewers on `prod`, and the federated credentials for `id-github-deploy` and `id-github-acr`. These two identities and the state they need are the only things made by hand (or by a one-off `az` script in `bootstrap/`); write down how.

0.7 **Budget.** Set the expected monthly cost per environment (rough numbers below) and agree on alert thresholds.

**Checkpoint 0:** decisions written down, a `what-if` of an empty `main.bicep` runs from GitHub Actions with OIDC, and the region has the models and quota.

---

## Phase 1: landing zone

1.1 **Management** (`rg-<wl>-mgmt-<env>`):
- Log Analytics workspace (30 days interactive retention in dev, longer in prod by table; basic logs plan for noisy tables);
- Azure Monitor workspace (Managed Prometheus) and Azure Managed Grafana, with Entra groups as Grafana roles;
- an action group (mail now, later Teams);
- a budget on the subscription with alerts at 50, 80 and 100 % of the agreed amount, plus a forecast alert.

1.2 **Defender for Cloud:** plans for Containers, Key Vault, Open-source relational databases, Resource Manager and (if used) Storage. Continuous export to the Log Analytics workspace.

1.3 **Policy** (subscription scope, from `infra/policy/`):
- the ALZ subset that fits a Corp workload: no public IPs on NICs, private endpoints for PaaS, diagnostic settings to the workspace, allowed locations, required tags, secure transfer;
- the AKS initiative "Kubernetes cluster pod security restricted standards" in audit first, then deny once the apps pass;
- "Kubernetes clusters should use internal load balancers" in deny mode (the baseline does this);
- start in audit, read the compliance results at the checkpoint, then switch to deny.

1.4 **Connectivity** (`rg-<wl>-conn-<env>`):
- hub VNet with Bastion (Basic in dev, Standard in prod for native client);
- egress (A11): NAT Gateway on the spoke node subnet in dev; Azure Firewall with a firewall policy in prod, with the AKS required FQDNs (the `AzureKubernetesService` FQDN tag), `github.com` and `*.githubusercontent.com` for Argo, the chart registries used by the platform (`cr.agentgateway.dev`, the ESO and ASO chart repos), and the MCP server's allow-list (A12);
- private DNS zones for `privatelink.azurecr.io` (and the regional data endpoint zone), `privatelink.vaultcore.azure.net`, `privatelink.postgres.database.azure.com`, `privatelink.cognitiveservices.azure.com` and `privatelink.services.ai.azure.com` (check the exact zones the Foundry private endpoint needs), the AKS private cluster zone, linked to hub and spoke;
- spoke VNet, peered, with the subnets from the address plan, NSGs on every subnet, flow logs (VNet flow logs) to the workspace;
- in prod: a route table on the node subnet sending `0.0.0.0/0` to the firewall.

**Checkpoint 1:** the pipeline deploys the landing zone with no manual step; a second run is a no-op in what-if; policy compliance is read and the audit findings are understood; the budget alert fires on a test threshold.

---

## Phase 2: shared services

2.1 **ACR** (Premium in prod for private endpoints and dedicated data endpoints; Standard with a public endpoint is acceptable in dev if A9's dev path is used, decide in phase 0):
- admin user off, anonymous pull off, Entra-only auth (ABAC repository permissions if several teams push);
- dedicated data endpoints on, so the firewall doesn't need a `*.blob.core.windows.net` wildcard;
- private endpoint in `snet-pe`; Defender scans images on push;
- a retention policy for untagged manifests.

GitHub-hosted runners can't reach a private-only registry. Options, decide in phase 0: a public endpoint limited by firewall rules during the build window (fragile), `az acr build` (the registry builds; needs a dedicated agent pool for a private registry), or self-hosted runners in the spoke (a small VM scale set or a Managed DevOps Pool equivalent for GitHub). Proposal: dev keeps a public endpoint with Entra-only auth; prod uses `az acr build` with an agent pool.

2.2 **Key Vaults:** `kv-<wl>-plat-<env>` and one per app, RBAC mode, purge protection on, soft delete 90 days, public access off, private endpoint, diagnostic logs to the workspace. Content at the start:
- platform vault: the agentgateway database password (A7) and, only if A4 keeps the fallback, the Anthropic key;
- each app vault: its gateway key (D11), written by `agent-key.sh <app>` from stdin.

2.3 **PostgreSQL flexible server** (A5):
- PostgreSQL 17; Entra authentication on with `grp-psql-admins` as administrator; password auth on only for the `agentgateway` role until A7 allows turning it off;
- private endpoint, public access off;
- server parameters: `require_secure_transport` on, `log_min_duration_statement` (e.g. 1 s) for slow queries, `pgaudit` for role and DDL changes in prod;
- databases: `agentgateway` here; the app databases come from ASO in phase 5 (A10);
- diagnostic settings to the workspace; a maintenance window outside working hours;
- dev: Burstable B2s, zonal, 7 days backup. Prod: General Purpose D2ds_v5, zone-redundant HA, 35 days backup, geo-redundant backup, a read replica only if needed later.

2.4 **Foundry** (A4):
- a Foundry (AI Services) resource with local auth (keys) **disabled**, public access off, private endpoint;
- deployments for the models the gateway serves (`claude-sonnet-5-5`, `claude-haiku-5-5`, or what the region has), with their tokens-per-minute quota set per deployment;
- content filters left at the default and noted;
- diagnostic logs to the workspace.

2.5 **Managed identities** from the identity map that Bicep owns (not the per-app ones; those come from ASO).

**Checkpoint 2:** from a Bastion jump host in the spoke:
- `nslookup` of every private endpoint name returns a private address, and the public endpoints refuse;
- a Messages API call to the Foundry deployment with an Entra token answers, and one with a key is refused (local auth off);
- `psql` with an Entra token as `grp-psql-admins` member works; without TLS it's refused;
- Defender shows the new resources as covered.

---

## Phase 3: cluster and Argo CD

3.1 **AKS** (A14), by Bicep with the AVM AKS module:
- Kubernetes version: the newest GA minus one minor; auto-upgrade channel `patch`, node OS channel `NodeImage`, planned maintenance windows for both;
- private cluster in prod (API server VNet integration as the alternative), public API with authorized IP ranges in dev;
- Entra integration with Azure RBAC for Kubernetes, local accounts disabled;
- Azure CNI Overlay with the Cilium data plane, network policy Cilium, Advanced Container Networking Services for FQDN policies and flow logs (A11);
- OIDC issuer and workload identity on;
- system pool: 3 nodes over zones 1–3, `CriticalAddonsOnly` taint, ephemeral OS disks; user pool: autoscaler 2–5 (dev 1–3) over zones, ephemeral OS disks; Azure Linux as the node OS;
- add-ons: Azure Policy, Key Vault CSI only if A6 changes, Container Insights (cost-optimised data collection), Managed Prometheus metrics, Defender sensor;
- image cleaner on; `outboundType` NAT Gateway in dev, `userDefinedRouting` in prod;
- the node resource group locked down (deny assignments, the default);
- diagnostic settings: `kube-audit-admin`, `kube-apiserver`, `guard`, `cluster-autoscaler` to the workspace (resource-specific tables).

3.2 **Argo CD extension** (A8), by Bicep, in namespace `argocd`:
- the values from `bootstrap/argocd-values.yaml` that still apply: the Application health check (the stricter one from phase 4), the agentgateway health checks, dex and notifications off (Entra SSO replaces dex's role);
- Entra SSO with the Argo app registration; `policy.csv` mapping `grp-argocd-admins` to `role:admin`, `grp-argocd-readers` to `role:readonly`; the local `admin` account disabled after SSO works;
- the UI on a ClusterIP, reached by port-forward in dev and through the internal ingress in prod (never public);
- workload identity for Argo only if sources come from ACR as OCI.

3.3 **Bootstrap** (`bootstrap/bootstrap.sh`, now small): `az aks get-credentials` with `kubelogin`, apply `clusters/<env>/root.yaml`, print the Argo URL. No sealing key restore any more.

**Checkpoint 3:**
- `kubectl` works through Entra for `grp-aks-admins` and is read-only for `grp-aks-readers`; local accounts refused;
- the Argo UI signs in with Entra, the root is Synced and Healthy with no children;
- no public IP exists in the subscription except the firewall's (prod) or NAT gateway's (dev), and Bastion's;
- Defender and Policy show the cluster; Container Insights shows nodes;
- memory and CPU of the system pool with Argo and the add-ons, recorded as in phase 1 of `docs/plan.md`.

---

## Phase 4: platform from git

The order in `argocd/platform.yaml`, with what changes against today:

| Wave | Application | Change |
|---|---|---|
| -4 | `azure-service-operator` | **New.** ASO v2 by Helm, with only the CRD groups it needs (`managedidentity`, `dbforpostgresql`; `crdPattern` keeps the install small), using `id-aso`. |
| -3 | `external-secrets` | **New, replaces `sealed-secrets`.** ESO by Helm; a `ClusterSecretStore` for the platform vault using `id-eso-platform`. |
| -3 | `gateway-api-crds` | **Check the owner.** AGC's ALB controller and AKS's managed Gateway API install also want to own these CRDs. Exactly one owner: if AGC is used (prod), let the ALB controller own them at a version agentgateway supports, and drop this Application in prod. |
| -2 | `agentgateway-crds` | unchanged |
| -1 | `agentgateway` | unchanged chart; the controller's service account doesn't need Azure rights. |
| -1 | `ingress` | **New, prod only.** ALB controller (AGC), its `ApplicationLoadBalancer` in `snet-ingress`, a WAF policy (OWASP rule set, bot protection) attached, a Gateway for the agent UIs with the certificate from Key Vault. Dev: nothing; the agent Services are internal load balancers. |
| 0 | `ai-gateway` | **Changed**, below. |
| 0 | `databases` | **New.** Per app (from `platform/databases/apps/<app>/`): a Sync-hook Job running as `id-db-admin` that creates the PostgreSQL role for `id-<app>` (`pgaadauth_create_principal`), makes it owner of the app's database, and revokes `PUBLIC` on it. Idempotent. |

4.1 **The central AI gateway on Foundry** (`platform/ai-gateway/`):
- the models point at the Foundry deployments (A4) through the Azure provider, authenticating with the proxy's workload identity: the AgentgatewayParameters set the service account annotation and the `azure.workload.identity/use` label on the proxy pods;
- the `anthropic` SealedSecret goes away (and only comes back from Key Vault if the fallback provider is kept);
- the request-log database URL points at the flexible server with `sslmode=require`; the password comes from an `ExternalSecret` (A7);
- `postgres.yaml` and `sealed-postgres.yaml` go away;
- the NetworkPolicies change: the gateway's egress goes to the Foundry private endpoint's IP and the server's private endpoint IP (`ipBlock` on `snet-pe`), not to a Postgres pod;
- the per-app keys (D11), MCP routes (D10), model authorization, limits and `usage-per-app.yaml` stay as they are. Add a limit for `rust-agents` (`todo.md`), and token limits per app now that Foundry has a quota to protect.

4.2 **Default-deny network policies** per namespace (baseline layer from the AKS network policy guidance): deny all ingress and egress, then allow DNS, then each app's own rules. Add a Cilium policy that blocks `169.254.169.254` (IMDS) for every pod that doesn't need it, which is all of them with workload identity.

**Checkpoint 4:** repeat the gateway tests of phase 2 in `docs/plan.md` with a temporary key: a declared model answers (now from Foundry), an undeclared one gets 404, no key or a wrong key 401, an unlabelled namespace times out. Also:
- the gateway pods have no secret mounted for the model provider;
- the request log lands in the flexible server and the analytics page shows it;
- Foundry's metrics show the calls under the gateway's identity;
- `kubectl delete` of a platform object is reverted by Argo, as on kind.

---

## Phase 5: the apps from git

5.1 **Release the code changes** listed above through CI to ACR (phase 6.1 if CI is ready, `az acr build` otherwise).

5.2 **Per-app Azure resources** (A10), in `platform/azure/apps/<app>/`, synced by a new platform Application `azure-apps` at wave 0:
- `UserAssignedIdentity` `id-<app>`;
- `FederatedIdentityCredential` for `system:serviceaccount:<app>:agent`;
- `FlexibleServersDatabase` `<app>` (dashes to underscores) on the shared server;
- the Key Vault role assignment for its own vault (ASO `RoleAssignment`, within the constrained RBAC admin condition);
- ASO writes the identity's client id into a ConfigMap the app reads (`operatorSpec.configMaps`), so nothing is copied by hand.

5.3 **The base** (`bases/rust-agent/`):
- `postgres.yaml` removed; a ServiceAccount `agent` with the workload identity label; `DATABASE_URL` without a password, plus the settings for the Entra token (host, database, user = the identity's name);
- the gateway key from an `ExternalSecret` (the app's `SecretStore` uses its own identity) instead of `sealed-gateway-key.yaml`;
- the Service becomes `LoadBalancer` with the internal annotation (dev) or ClusterIP behind the ingress Gateway (prod); the NodePort goes;
- `topologySpreadConstraints` gain `topology.kubernetes.io/zone`;
- requests and limits checked against real usage from Container Insights; a HorizontalPodAutoscaler on CPU is not useful for an I/O-bound agent, so keep fixed replicas (3) and the concurrency cap from the code change;
- NetworkPolicies: egress to the gateway (unchanged), to the server's private endpoint IP on 5432 (`ipBlock`), to Entra ID for tokens (FQDN policy on `login.microsoftonline.com`), DNS.

5.4 **AppProject `apps`:** add the ASO, ESO `ClusterSecretStore` and AGC kinds to the blocklist, next to the Gateway API and agentgateway kinds (D10). An app may make `ExternalSecret` and namespaced `SecretStore` objects only.

5.5 **The UI** (A9): dev through Bastion or VPN to the internal load balancer; prod through AGC with the WAF policy and Entra sign-in in front, an HTTPRoute per agent (`https://<app>.<domain>`). A long SSE stream must survive the edge: check the idle timeouts of AGC and of the WAF for a turn that takes minutes.

**Checkpoint 5:** the checks from checkpoint 3 of `docs/plan.md`, now on AKS:
- 3 agent pods over three zones, a chat that continues across pods and after every pod is deleted;
- 409 when busy, reset;
- an undeclared model refused (404), another app's MCP route refused (403);
- the agent pods can't reach the internet, IMDS or another app's database (`psql` from the pod as its own identity into another database: refused);
- the database login is an Entra token: no password exists anywhere for the agents;
- the UI is unreachable without sign-in (prod) or from outside the VNet (dev);
- removing `apps/research-agent/` and its platform folders removes the app, its identity and its database (decide whether ASO should keep the database: `serviceoperator.azure.com/reconcile-policy: detach-on-delete` on the database is the safer default).

---

## Phase 6: day two

6.1 **CI for images** (`images.yaml`): on a push that touches the source paths, build both targets (per-image tags, from `todo.md`), scan (Defender plus a Trivy step that fails on critical findings), push to ACR, sign (Notation with a Key Vault key, optional), and open a PR that changes the tag in `bases/rust-agent/` for dev. The tag commit doesn't touch source paths, so it can't trigger a build.

6.2 **Promotion:** dev and prod overlays each pin their tag; a PR copies a tag from dev to prod. The `prod` GitHub environment needs a reviewer; Argo in prod syncs automatically once merged. Rollback is a `git revert`, as on kind.

6.3 **Infra changes:** every Bicep change gets a PR with the what-if as a comment, deploys to dev on merge and to prod on a tag with approval. Resource locks (`CanNotDelete`) on the flexible server, Key Vaults and the hub.

6.4 **Upgrades:** AKS patch versions and node images come from the auto-upgrade channels within the maintenance windows. Minor versions: upgrade dev first, run the checkpoint tests, then prod. Platform charts (agentgateway, ESO, ASO): a PR per bump, dev first. Check deprecated APIs before each minor upgrade (AKS shows them in the portal).

6.5 **Observability:**
- logs: JSON from the agents in Container Insights; one KQL query per question (turns per app, errors per app, 409s, slow turns);
- metrics: Managed Prometheus with the community AKS dashboards in Grafana; agentgateway's metrics scraped (pod annotations or a `PodMonitor`);
- traces: agentgateway's OpenTelemetry output to Application Insights through an OTel collector (check the gateway's OTLP settings);
- LLM usage: the gateway's analytics page (port-forward), plus Foundry's metrics per deployment;
- alerts: node and pod health (the recommended AKS Prometheus alert rules), PostgreSQL CPU, storage and connection count (the connection limit is the first one to hit), Foundry 429s, ACR and Key Vault access failures, Argo apps OutOfSync or Degraded for more than 15 minutes, the budget.

6.6 **Backup and restore drills** (reliability):
- PostgreSQL: a point-in-time restore of the server to a new name, then point one app at it through git; measure the time (RTO) and the data lost (RPO);
- the cluster: delete it and rebuild from the pipeline and the root, as the kind rebuild test did; everything except the in-cluster state must come back with no manual step, and no data is lost because none lives in the cluster;
- region loss (prod): the plan is a redeploy in the paired region from Bicep plus a geo-restore of the server; write down the expected RTO and test it once.

6.7 **Cost review** after a month: actual against budget; rightsize nodes (Advisor), check Log Analytics ingestion per table, check Foundry spend per app (gateway token limits as the budget control, `todo.md`); stop the dev cluster and server outside working hours (AKS stop/start and server stop by a scheduled workflow).

**Checkpoint 6:** a code change goes from commit to prod by two merged PRs and nothing else; a restore drill result is written down; the dashboards and alerts are in place; the cost review is written down.

---

## Rough monthly cost (check with the pricing calculator)

Order of magnitude only, without model tokens, which depend entirely on use.

| Item | Dev (A11/A14 lab profile) | Prod (baseline profile) |
|---|---|---|
| AKS control plane | Free tier | Standard tier (uptime SLA) |
| Nodes | 2–3 small VMs | 3 system + 3–5 user, over zones |
| PostgreSQL | Burstable B2s, no HA | D2ds_v5, zone-redundant HA, geo backup |
| Egress | NAT Gateway | Azure Firewall Standard (the largest single item) |
| Ingress | internal LB, Bastion Basic | Application Gateway for Containers + WAF, Bastion Standard |
| ACR | Standard | Premium |
| Monitoring | Log Analytics with cost-optimised collection, Managed Prometheus, Grafana | same, more retention |
| Rough total | a few hundred euros a month | two to three thousand euros a month |

Stopping dev outside working hours roughly halves its compute cost.

## How the plan maps to CAF and WAF

**CAF**
- *Strategy and plan:* this repo is a learning workload; the plan keeps a lab profile and a production profile so the cost of each choice is visible.
- *Ready (landing zone):* platform and workload split, hub and spoke, central private DNS, policy at subscription scope, CAF naming and tags (A2, phase 1).
- *Govern:* Azure Policy (audit, then deny), required tags, budgets and alerts, resource locks.
- *Secure:* Entra everywhere, no standing secrets, PIM for admins, Defender for Cloud, private endpoints.
- *Manage:* Azure Monitor, maintenance windows, upgrade channels, backup drills.
- *Organize:* platform team owns `infra/` and `platform/`, app teams own `apps/<app>/`; AppProjects and Azure RBAC enforce that split.

**WAF**

| Pillar | In this plan |
|---|---|
| Reliability | Zones for nodes, gateway and agents; PDBs; zone-redundant HA PostgreSQL in prod; stateless agents; geo-redundant backups; rebuild from code; tested restore with measured RTO and RPO. |
| Security | Private cluster and private endpoints; Entra sign-in for people and workload identity for pods; no provider key and no database password for agents; Key Vault for the rest; Cilium default-deny and FQDN egress; IMDS blocked for pods; WAF and sign-in in front of the UI; Defender; restricted pod security; the SSRF fix before the MCP server goes near private endpoints. |
| Cost optimization | Lab and production profiles; budgets and alerts; Burstable in dev; stop and start; gateway token limits per app; Log Analytics data collection rules; a monthly review. |
| Operational excellence | Everything as code (Bicep and git), what-if on PRs, GitOps with drift correction, dev before prod, structured logs, dashboards and alerts, written runbooks from the checkpoints. |
| Performance efficiency | Cluster autoscaler; node auto-provisioning as a later option; connection caps that match the server's limit; Foundry quota per deployment; load test a busy hour once before calling prod done. |

## Open questions to check while building

- agentgateway v1.7.0: does `AgentgatewayModel` take the Azure/Foundry provider with workload identity, or does it need an `AgentgatewayBackend`? Does the request-log database accept an Entra token (A7)?
- Which Claude models are hosted on Azure in the chosen region, and their default quota.
- The exact private DNS zones a Foundry private endpoint needs.
- The Argo CD extension: does it take every value we set today (A8)? Its upgrade cadence and how far behind upstream Argo CD it runs.
- Who owns the Gateway API CRDs once AGC is installed, and whether that version suits agentgateway.
- ASO: whether its PostgreSQL `User` resource can create an Entra principal, which would replace the db-init Job.
- AGC and WAF idle timeouts for long SSE responses.
- How GitHub-hosted runners push to a private ACR in prod (2.1).
