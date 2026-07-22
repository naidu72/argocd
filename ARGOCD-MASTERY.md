# ArgoCD Mastery Plan — From Foundations to Production

> Built against **your** environment, not a generic tutorial.
> Control plane: ArgoCD **v3.4.5** (Helm chart `argo-cd-10.1.4`) running on **`pi-k8s`** — a 4-node k3s v1.36.2 arm64 cluster.
> GitOps repo: `github.com/naidu72/argocd`

---

## 0. Your Starting Position

### What you already have

| Layer | Status |
|---|---|
| **ArgoCD control plane** | Running on `pi-k8s` in ns `argocd` — all 7 components healthy |
| **Cluster 1 — `pi-k8s`** | k3s v1.36.2, arm64. Nodes: `pi5-1` (control-plane+etcd), `pi5-0`, `pi4`, `rock64` |
| **Cluster 2 — `kind-k8s-kind`** | amd64 kind cluster on WSL2 — **currently unreachable** (`127.0.0.1:43333` refused) |
| **Secrets** | `vault` + `external-secrets` namespaces already deployed |
| **TLS** | `cert-manager` deployed |
| **Service mesh** | `istio-demo` namespace with `istio-injection=enabled` |
| **Ingress** | `cloudflare-tunnel-ingress-controller` |
| **CI** | `jenkins`, `arc-runners` (GitHub Actions Runner Controller), `awx`, `n8n` |

This is an unusually good lab. You have every ingredient for the advanced phases already installed — you just haven't wired them to ArgoCD yet. That shapes the plan below: **Phase 4 and 5 are not hypothetical for you, they're integration work.**

### Where your ArgoCD pods actually landed

```
argocd-application-controller-0        rock64    # the reconciliation engine
argocd-applicationset-controller-...   rock64    # generates Applications
argocd-server-...                      pi5-0     # API + UI
argocd-repo-server-...                 pi5-0     # git clone + manifest render
argocd-redis-...                       pi4       # manifest cache
argocd-dex-server-...                  rock64    # SSO broker
argocd-notifications-controller-...    rock64    # alerts
```

Note `redis` is on `pi4` while the controller is on `rock64` — every cache read crosses the network. On a Pi cluster over Wi-Fi/1GbE that is measurable. Fix in Phase 6 (tuning).

### Three issues in your current repo to fix as you go

**1. Nothing declaratively manages your control plane.**
ArgoCD was installed with the `helm install` CLI (release `argocd`, revision 1, chart `argo-cd-10.1.4`, app `v3.4.5`) — exactly as the comment at the top of [terraform/argocd.tf](terraform/argocd.tf) describes. The Terraform in this repo **cannot** manage it:

- the `helm` provider in [terraform/provider.tf](terraform/provider.tf) is entirely commented out, so `helm_release.argocd` can never apply
- the `kubernetes` provider points at `/home/naidu/.kube/config` — a different user's kubeconfig, last modified Oct 2025
- `terraform.tfstate` still records chart `3.35.4` from an abandoned attempt, while the live chart is `10.1.4`

So your control plane exists only as shell history. Reproducing it means remembering the command. **Lab 1.1 fixes this** — and the GitOps-native answer is to let ArgoCD manage its own Helm release from Git, not to revive the Terraform.

**2. `global.image.tag: "v3.4.5"` in [terraform/values/argocd.yaml](terraform/values/argocd.yaml) is a trap.**
That values file *is* live — `helm get values argocd -n argocd` returns exactly its contents. Pinning the image tag independently of the chart means templates and binary diverge on the next chart bump. Pin the **chart** version only and let it choose its tested `appVersion`.

**3. You have four overlapping Application/ApplicationSet definitions.**
[my-app.yaml](my-app.yaml), [my-app-pi.yaml](my-app-pi.yaml), [multi-my-app.yaml](multi-my-app.yaml), [applicationset.yaml](applicationset.yaml), and [applicationset_auto_discovry.yaml](applicationset_auto_discovry.yaml) — two of which both declare `metadata.name: guestbook`. Applying both will fight. Phase 2 restructures this into a proper repo layout.

---

## 1. Foundations & Core Architecture

### 1.1 What ArgoCD actually is

ArgoCD is a **Kubernetes controller that continuously reconciles live cluster state against manifests in Git.** That's the whole idea. Everything else is detail.

The mental shift from Jenkins/GitLab CI:

| Traditional CI/CD (push) | GitOps (pull) |
|---|---|
| Pipeline runs `kubectl apply` | Controller in-cluster pulls from Git |
| CI needs cluster admin credentials | Cluster needs **read** access to Git; CI needs none |
| Drift is invisible until it breaks | Drift is a first-class, alertable status |
| "What's deployed?" → read pipeline logs | "What's deployed?" → `git log` |
| Rollback = re-run an old pipeline | Rollback = `git revert` |
| N clusters = N sets of credentials in CI | N clusters = N agents pulling |

**The credential inversion is the real enterprise argument.** In push CI/CD, your Jenkins (which you have, in `jenkins` ns) holds kubeconfigs with cluster-admin for every environment. Compromise Jenkins → compromise prod. In GitOps, Jenkins only ever builds images and writes a tag to a Git repo. It never touches the cluster.

### 1.2 The GitOps four principles (OpenGitOps)

1. **Declarative** — the system is described entirely by declarative config.
2. **Versioned & immutable** — that config lives in Git, with full history.
3. **Pulled automatically** — agents pull the desired state; nothing pushes in.
4. **Continuously reconciled** — agents detect and correct drift, forever.

ArgoCD implements 3 and 4. You supply 1 and 2.

### 1.3 Architecture — the components and how they talk

```
                         ┌──────────────────────────────────┐
   git push ──────────►  │   Git (github.com/naidu72/argocd)│
                         └────────────────┬─────────────────┘
                                          │ poll (3m) or webhook
                                          ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │  argocd namespace on pi-k8s                                     │
   │                                                                 │
   │   ┌──────────────┐  gRPC   ┌──────────────────┐                 │
   │   │ repo-server  │◄────────┤ application-     │                 │
   │   │ (pi5-0)      │ render  │ controller       │                 │
   │   │              ├────────►│ (rock64)         │                 │
   │   │ git clone    │ manifest│                  │                 │
   │   │ helm template│         │  diff + apply    │                 │
   │   │ kustomize    │         └────┬────────┬────┘                 │
   │   │ build        │              │        │                      │
   │   └──────┬───────┘              │        │ watch + apply        │
   │          │                      │        │                      │
   │          ▼                      ▼        │                      │
   │   ┌──────────────┐      ┌──────────────┐ │                      │
   │   │ redis (pi4)  │◄─────┤ argocd-server│ │                      │
   │   │ manifest +   │      │ (pi5-0)      │ │                      │
   │   │ resource     │      │ API/UI/CLI   │ │                      │
   │   │ cache        │      │ authz/authn  │ │                      │
   │   └──────────────┘      └──────┬───────┘ │                      │
   │                                │         │                      │
   │   ┌────────────────────┐       ▼         │                      │
   │   │ applicationset-ctrl│  ┌──────────┐   │                      │
   │   │ generates Apps     │  │ dex (SSO)│   │                      │
   │   └────────────────────┘  └──────────┘   │                      │
   │                                          │                      │
   │   ┌────────────────────┐                 │                      │
   │   │ notifications-ctrl │                 │                      │
   │   └────────────────────┘                 │                      │
   └──────────────────────────────────────────┼──────────────────────┘
                                              │
                    ┌─────────────────────────┼──────────────────────┐
                    ▼                         ▼                      ▼
            pi-k8s (in-cluster)        kind-k8s-kind          future clusters
```

**`argocd-repo-server`** — stateless manifest renderer. Clones the repo, runs `helm template` / `kustomize build` / plugins, returns plain YAML over gRPC. It never talks to a target cluster. **It is your most common performance bottleneck** because Helm rendering is CPU-bound — and on a Pi, that hurts.

**`argocd-application-controller`** — the engine. For each `Application`:
1. Asks repo-server for desired manifests.
2. Reads live state from the target cluster (via a watch-based cache, not polling).
3. Computes a three-way diff (desired vs live vs last-applied).
4. Reports `Synced`/`OutOfSync` + `Healthy`/`Degraded`/`Progressing`.
5. If `automated` sync is on, applies the difference.

It's a StatefulSet because sharding assigns clusters to specific replica ordinals.

**`argocd-server`** — API server (gRPC + REST), serves the UI and `argocd` CLI, handles authn/authz. **It performs no reconciliation.** You can scale it to zero and your apps keep syncing. Good thing to know during an incident.

**`redis`** — pure cache. Losing it causes a slow, expensive re-render of everything, not data loss.

**`applicationset-controller`** — a controller whose output is `Application` objects. Templating layer above ArgoCD proper.

**`dex-server`** — OIDC broker for providers that don't do OIDC natively (GitHub, LDAP, SAML). If your IdP speaks OIDC directly, you can drop Dex.

**`notifications-controller`** — subscribes to Application state changes, fires webhooks (Slack, Teams, your `n8n`).

### 1.4 The two independent status axes

Beginners conflate these constantly:

- **Sync status** — *does the cluster match Git?* `Synced` / `OutOfSync`
- **Health status** — *is the workload actually working?* `Healthy` / `Progressing` / `Degraded` / `Missing` / `Suspended`

`Synced + Degraded` is completely normal: you deployed exactly what Git says, and what Git says is broken (bad image tag, failing probe). ArgoCD did its job. Your alerts must treat these separately.

---

## 2. Hands-On Learning Path

---

## Phase 1 — Setup, Bootstrap & First Deployment

**Goal:** ArgoCD is itself managed by Git, and you understand the render→diff→apply loop.

### 1.1 Capture your control plane in Git (do this first)

Right now ArgoCD exists only as a `helm install` you typed once. Make it reproducible.

**Decide the ownership model first — this is the fork in the road:**

| | **A. ArgoCD self-manages (recommended)** | **B. Terraform owns it** |
|---|---|---|
| Upgrade path | commit a chart version → ArgoCD syncs itself | `terraform apply` |
| Fits your repo | yes — this repo is already a GitOps repo | needs the dead provider config rebuilt |
| Failure mode | a bad values change can break the thing applying the fix | Terraform state drift, as you already have |
| Break-glass | `helm upgrade` by hand | `terraform apply` |

**Take option A.** Your Terraform is non-functional (commented-out helm provider, foreign kubeconfig path, stale state), and reviving it just to manage one Helm release adds a second source of truth alongside the Git repo you're building. Keep `helm upgrade` as the documented break-glass path and delete or archive [terraform/](terraform/) once Lab 1.1 passes.

Move the values file out of `terraform/` into the platform tree:

```yaml
# platform/argocd/values.yaml
# Note: global.image.tag removed — the chart's tested appVersion is what you want.
configs:
  params:
    server.insecure: true          # preferred over the deprecated extraArgs form
  cm:
    timeout.reconciliation: 180s
    application.resourceTrackingMethod: annotation

controller:
  metrics:
    enabled: true
server:
  metrics:
    enabled: true
repoServer:
  metrics:
    enabled: true
applicationSet:
  metrics:
    enabled: true
```

> `application.resourceTrackingMethod: annotation` — set this **now, before you have many apps.** The default `label` mode uses `app.kubernetes.io/instance`, which collides with Helm's own labels and is capped at 63 chars. Switching later forces a re-adoption of every resource.

Apply it as a normal `helm upgrade` first, so ArgoCD is in the desired state *before* it starts managing itself:

```bash
fish -c "pi-k8s; helm upgrade argocd argo/argo-cd \
  --namespace argocd --version 10.1.4 \
  -f platform/argocd/values.yaml"
```

Then hand ownership to ArgoCD (this is the Application you'll create in Phase 2):

```yaml
# platform/argocd.yaml — ArgoCD manages its own Helm release
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "-3" }
spec:
  project: platform
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      chart: argo-cd
      targetRevision: 10.1.4              # bump this to upgrade ArgoCD
      helm:
        valueFiles:
          - $values/platform/argocd/values.yaml
    - repoURL: https://github.com/naidu72/argocd.git
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: false, selfHeal: true }   # prune:false — never let it delete its own CRDs
    syncOptions: [ServerSideApply=true]
```

The multi-source pattern (`ref: values`) lets you keep the upstream chart and *your* values file in separate repos — the standard way to manage third-party charts in GitOps.

> **`prune: false` here is deliberate.** A pruning self-managed ArgoCD that renders a bad manifest can delete its own CRDs, taking every Application object with them. Self-management is elegant; give it a safety rail.

### 1.2 Reach the UI

You have `cloudflare-tunnel-ingress-controller` — but start simple:

```bash
fish -c "pi-k8s; kubectl -n argocd port-forward svc/argocd-server 8080:443"
fish -c "pi-k8s; kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d"
```

CLI login (you'll live in the CLI more than the UI):

```bash
argocd login localhost:8080 --username admin --insecure
argocd cluster list
argocd app list
```

### 1.3 Understand render-before-deploy

The single most useful debugging habit — reproduce what repo-server does, locally:

```bash
kustomize build guestbook/arm64          # exactly what repo-server sends the controller
helm template myrelease ./chart -f values-prod.yaml
```

If this output is wrong, ArgoCD is not your problem.

### Phase 1 Labs

- **Lab 1.1** — Move `terraform/values/argocd.yaml` → `platform/argocd/values.yaml`, strip `global.image.tag`, add the metrics/params block, and `helm upgrade`. Confirm with `helm get values argocd -n argocd` that live matches the file. *Your control plane is now described by a file in Git instead of by shell history.* (The self-managing Application from §1.1 lands in Lab 2.6.)
- **Lab 1.2** — Deploy [my-app-pi.yaml](my-app-pi.yaml). Watch `argocd app get pi-guestbook` transition `OutOfSync → Progressing → Synced/Healthy`.
- **Lab 1.3 — Prove self-heal.** `kubectl -n guestbook scale deploy/guestbook-ui --replicas=5`. Watch it snap back within ~3 minutes. Then `kubectl -n argocd logs sts/argocd-application-controller | grep -i "auto-sync"` and read why.
- **Lab 1.4 — Prove prune.** Delete `service.yaml` from `guestbook/arm64/`, commit, push. Confirm the Service is removed from the cluster. Then set `prune: false`, repeat, and observe it left orphaned as `OutOfSync`.
- **Lab 1.5 — Multi-arch reality.** Read [guestbook/arm64/kustomization.yaml](guestbook/arm64/kustomization.yaml): you replaced `gcr.io/google-samples/gb-frontend` with `nginx:alpine` because the upstream image has no arm64 build. Now do it properly — `docker buildx build --platform linux/amd64,linux/arm64` a real multi-arch image, push to GHCR, and delete the `images:` override entirely. **One manifest, two architectures.** This is the correct answer to the problem your repo currently works around.

---

## Phase 2 — Applications, App-of-Apps, ApplicationSets

**Goal:** stop hand-applying Application YAML.

### 2.1 Restructure the repo

Your five overlapping files at the root need to become a hierarchy. Target layout:

```
argocd/
├── bootstrap/
│   └── root-app.yaml               # the ONE thing you kubectl apply, ever
├── projects/
│   ├── platform.yaml               # AppProject
│   └── apps.yaml
├── platform/                       # cluster infrastructure (App-of-Apps children)
│   ├── cert-manager.yaml
│   ├── external-secrets.yaml
│   ├── istio.yaml
│   └── argo-rollouts.yaml
├── appsets/
│   ├── guestbook.yaml
│   └── homelab-git-generator.yaml
└── apps/
    └── guestbook/
        ├── base/
        └── overlays/{dev,prod}/
```

Delete [multi-my-app.yaml](multi-my-app.yaml) and one of the two `guestbook`-named ApplicationSets — [applicationset.yaml](applicationset.yaml) and [multi-my-app.yaml](multi-my-app.yaml) both claim `metadata.name: guestbook` and will overwrite each other.

### 2.2 App-of-Apps

One root Application whose source directory contains other Applications. Recursion.

```yaml
# bootstrap/root-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # cascade-delete children
spec:
  project: platform
  source:
    repoURL: https://github.com/naidu72/argocd.git
    targetRevision: HEAD
    path: platform
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

**Ordering matters** for platform components. Use sync waves — lower numbers first, and ArgoCD waits for each wave to be Healthy:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"    # cert-manager, CRDs
```

Suggested waves for your stack: `-2` namespaces/CRDs → `-1` cert-manager, external-secrets → `0` istio → `1` argo-rollouts → `2` workloads.

### 2.3 ApplicationSet generators

You've already used `list` and `clusters`. The one that will change how you work is **`git`**:

```yaml
# appsets/homelab-git-generator.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: homelab
  namespace: argocd
spec:
  goTemplate: true                       # use Go templating, not the legacy {{var}} engine
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/naidu72/argocd.git
        revision: HEAD
        directories:
          - path: apps/*
  template:
    metadata:
      name: '{{.path.basename}}'
    spec:
      project: apps
      source:
        repoURL: https://github.com/naidu72/argocd.git
        targetRevision: HEAD
        path: '{{.path.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.path.basename}}'
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true]
```

Now **creating a directory in Git creates an application.** No YAML to write.

**Matrix generator** — the enterprise workhorse. Cross-product of clusters × apps:

```yaml
generators:
  - matrix:
      generators:
        - clusters:
            selector:
              matchLabels: { env: prod }
        - git:
            repoURL: https://github.com/naidu72/argocd.git
            revision: HEAD
            directories: [{ path: apps/* }]
```

Two prod clusters × ten apps = twenty Applications from one object.

**Generator cheat sheet:**

| Generator | Use it for |
|---|---|
| `list` | Small fixed set; explicit control (your current `applicationset.yaml`) |
| `clusters` | Every registered cluster; filter with `selector.matchLabels` |
| `git` (directories) | App-per-folder auto-discovery |
| `git` (files) | Config-driven — a `config.json` per env supplies template values |
| `matrix` | Cross-product (clusters × apps) |
| `merge` | Overlay generator outputs — per-cluster overrides on a base set |
| `scmProvider` | One App per GitHub repo in an org |
| `pullRequest` | **Ephemeral preview environment per PR** — pairs with your `arc-runners` |

### 2.4 The critical safety valve

Default ApplicationSet behavior does **not** delete Applications when they leave the generator. Turn that on deliberately, and always dry-run first:

```yaml
spec:
  syncPolicy:
    applicationsSync: create-update      # create-only | create-update | create-delete
    preserveResourcesOnDeletion: false
```

Before any generator change: `argocd appset get <name> --dry-run` — or you delete production.

### Phase 2 Labs

- **Lab 2.1** — Restructure the repo per §2.1; delete the duplicate-name ApplicationSets.
- **Lab 2.2** — Build the root App-of-Apps managing `cert-manager` + `external-secrets` (already installed — let ArgoCD **adopt** them; observe what it reports `OutOfSync` and why. This is exactly what enterprise brownfield adoption feels like).
- **Lab 2.3** — Convert [applicationset.yaml](applicationset.yaml) from `list` to `git` directory generator. Prove it by `mkdir apps/podinfo` + commit, and watching an Application appear.
- **Lab 2.4** — Add sync waves to your platform apps; force a wave-1 app to fail and confirm wave 2 never starts.
- **Lab 2.5** — Matrix generator across `pi-k8s` and `kind-k8s-kind` (bring kind back up first).
- **Lab 2.6 — Self-management.** Apply the multi-source `argocd` Application from §1.1 so ArgoCD adopts its own Helm release. Change a value in Git and watch it upgrade itself. Then deliberately reason through the failure mode: what breaks if you commit a values file that crashes `argocd-server`, and what your recovery command is (`helm rollback argocd -n argocd`). **Write that break-glass command in your README before you need it.**

---

## Phase 3 — Sync Strategies, Hooks & Waves

### 3.1 Sync policy anatomy

```yaml
syncPolicy:
  automated:
    prune: true            # delete resources removed from Git
    selfHeal: true         # revert manual cluster changes
    allowEmpty: false      # refuse to sync a source that renders zero resources
  retry:
    limit: 5
    backoff: { duration: 5s, factor: 2, maxDuration: 3m }
  syncOptions:
    - CreateNamespace=true
    - PrunePropagationPolicy=foreground
    - PruneLast=true                # prune only after everything else is healthy
    - ApplyOutOfSyncOnly=true       # big perf win on large apps
    - ServerSideApply=true          # required for large CRDs (>256KB annotation limit)
    - RespectIgnoreDifferences=true
```

`allowEmpty: false` is a **production must-have.** Without it, a bad Kustomize edit that renders nothing causes ArgoCD to prune your entire application.

`ServerSideApply=true` is what you'll need for Istio and cert-manager CRDs — the client-side `last-applied-configuration` annotation blows past the 256KB limit.

### 3.2 Sync waves within an app

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"
```

Order: all PreSync hooks → wave N resources (ascending, waiting for health each time) → PostSync hooks. Negative waves are legal and idiomatic for CRDs and namespaces.

### 3.3 Hooks

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: ghcr.io/naidu72/migrator:v1.4.0
          command: ["./migrate", "up"]
```

| Hook | Fires | Typical use |
|---|---|---|
| `PreSync` | before sync | DB migrations, backups |
| `Sync` | with the main wave | custom ordering |
| `Skip` | never applied | conditional manifests |
| `PostSync` | after all healthy | smoke tests, cache warm, Slack notify |
| `SyncFail` | on failure | rollback, alert |
| `PostDelete` | after app deletion | external cleanup (DNS, S3 bucket) |

Delete policies: `HookSucceeded` (clean, but you lose logs), `HookFailed`, `BeforeHookCreation` (default — keeps the last run for debugging; **this is usually what you want**).

**Hooks are not a workflow engine.** If your PreSync needs branching, retries with conditions, or fan-out, reach for Argo Workflows — not five chained hook Jobs.

### 3.4 ignoreDifferences — stopping perpetual OutOfSync

The single most common ArgoCD annoyance. HPA-managed replicas, injected sidecars, mutating webhooks:

```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas                      # HPA owns this
    - group: ""
      kind: Service
      jsonPointers:
        - /spec/clusterIP
    - group: apps
      kind: Deployment
      namespace: istio-demo
      jqPathExpressions:
        - '.spec.template.spec.containers[] | select(.name == "istio-proxy")'
    - group: apiextensions.k8s.io
      kind: CustomResourceDefinition
      managedFieldsManagers: [cert-manager]   # ignore whatever this controller owns
```

`managedFieldsManagers` is the elegant option: "ignore any field this other controller legitimately manages," instead of enumerating paths.

### Phase 3 Labs

- **Lab 3.1** — Add a `PreSync` migration Job that sleeps 30s; watch the sync block on it. Then make it exit 1 and watch the sync abort before touching workloads.
- **Lab 3.2** — Add a `PostSync` smoke test that `curl`s the guestbook Service; make it fail and observe the app stays `Degraded` despite `Synced`.
- **Lab 3.3** — Add an HPA to guestbook, watch perpetual `OutOfSync`, then fix it with `ignoreDifferences` on `/spec/replicas`.
- **Lab 3.4** — Deploy guestbook into your `istio-demo` namespace (injection enabled) and resolve the sidecar diff with `jqPathExpressions`.
- **Lab 3.5 — The prune disaster drill.** With `allowEmpty: true`, break your kustomization so it renders nothing. Watch the app get wiped. Restore, set `allowEmpty: false`, repeat, confirm the sync is refused. **Do this once and you will never forget the flag.**
- **Lab 3.6** — Configure a GitHub webhook to `argocd-server` and measure sync latency drop from ~90s average to ~2s.

---

## Phase 4 — Enterprise Security & Access Control

This is where your existing `vault` + `external-secrets` + `cert-manager` install pays off.

### 4.1 AppProjects — the real security boundary

`default` project allows everything, everywhere. Never use it past Phase 2.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: apps
  namespace: argocd
spec:
  description: Application workloads
  sourceRepos:
    - https://github.com/naidu72/*
  destinations:
    - server: https://kubernetes.default.svc
      namespace: 'app-*'
    - name: kind-k8s-kind
      namespace: 'app-*'
  clusterResourceWhitelist: []           # no cluster-scoped resources at all
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota
    - group: rbac.authorization.k8s.io
      kind: ClusterRole
  roles:
    - name: developer
      policies:
        - p, proj:apps:developer, applications, get,  apps/*, allow
        - p, proj:apps:developer, applications, sync, apps/*, allow
      groups:
        - naidu72:developers
  syncWindows:
    - kind: deny
      schedule: '0 22 * * 5'     # Friday 22:00
      duration: 60h              # through Monday 10:00
      applications: ['*']
      manualSync: true           # break-glass still allowed
```

`syncWindows` is the feature nobody discovers until they need it — no automated deploys over the weekend, manual override available.

### 4.2 RBAC

`argocd-rbac-cm`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly          # deny-by-default posture
  scopes: '[groups, email]'
  policy.csv: |
    p, role:dev, applications, get,      apps/*, allow
    p, role:dev, applications, sync,     apps/*, allow
    p, role:dev, applications, action/*, apps/*, allow
    p, role:dev, logs,         get,      apps/*, allow
    p, role:dev, exec,         create,   apps/*, deny

    p, role:sre, applications, *,        */*,    allow
    p, role:sre, clusters,     get,      *,      allow
    p, role:sre, repositories, *,        *,      allow

    g, naidu72:developers, role:dev
    g, naidu72:sre,        role:sre
```

Resources: `applications`, `applicationsets`, `clusters`, `projects`, `repositories`, `accounts`, `certificates`, `gpgkeys`, `logs`, `exec`.

**`exec, create` should be `deny` for developers.** It grants a shell in any pod of any app they can see — a complete bypass of your Kubernetes RBAC.

### 4.3 SSO via Dex + GitHub

Your `dex-server` is already running:

```yaml
# argocd-cm
data:
  url: https://argocd.yourdomain.com
  dex.config: |
    connectors:
      - type: github
        id: github
        name: GitHub
        config:
          clientID: $dex.github.clientId
          clientSecret: $dex.github.clientSecret
          orgs:
            - name: naidu72
              teams: [developers, sre]
```

The `$` prefix reads from the `argocd-secret` Secret — never inline credentials in the ConfigMap.

### 4.4 Secrets — three approaches, ranked for you

**You already have Vault and External Secrets Operator installed, so use them.** This is the strongest option and it's already 80% done.

**Option A — External Secrets Operator + Vault (recommended for you):**

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault
spec:
  provider:
    vault:
      server: http://vault.vault.svc:8200
      path: secret
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: argocd
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: guestbook-db
  namespace: guestbook
spec:
  refreshInterval: 1h
  secretStoreRef: { name: vault, kind: ClusterSecretStore }
  target:
    name: guestbook-db
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef: { key: guestbook/db, property: password }
```

Only the `ExternalSecret` (a pointer, no secret data) goes in Git. ArgoCD syncs the pointer; ESO materialises the Secret. Clean separation, automatic rotation, no ciphertext in Git.

> **Gotcha:** ArgoCD will flag the ESO-created Secret as an unmanaged resource. Either exclude Secrets from tracking or let ESO own it via `creationPolicy: Owner` and add the Secret kind to `ignoreDifferences`.

**Option B — Sealed Secrets:** encrypted secrets committed to Git, decryptable only by the in-cluster controller's private key. Simpler than Vault, but rotation is manual and the controller key becomes a critical backup artifact.

**Option C — SOPS + age via a Config Management Plugin:** flexible, but you now own a custom plugin sidecar in repo-server. Only if A and B don't fit.

**Never:** plain Secrets in Git, even in a private repo. Git history is forever, and repo access is far broader than cluster access.

### 4.5 Hardening checklist

- [ ] Disable the local `admin` account once SSO works: `admin.enabled: false` in `argocd-cm`
- [ ] `policy.default: role:readonly` (deny-by-default)
- [ ] NetworkPolicy on the `argocd` namespace — repo-server needs egress to Git+registries only
- [ ] `exec` denied for all non-admin roles
- [ ] Every app in a scoped `AppProject`; `default` project locked down to nothing
- [ ] Repo credentials as scoped deploy keys, not personal PATs
- [ ] `cert-manager`-issued TLS on the server; drop `server.insecure` before exposing via Cloudflare Tunnel
- [ ] Enable the resource `exclusions` list to stop the controller watching high-churn kinds

### Phase 4 Labs

- **Lab 4.1** — Create `platform` and `apps` AppProjects; move all Applications off `default`; confirm the `default` project can no longer deploy anything.
- **Lab 4.2** — Attempt to deploy a `ClusterRole` from the `apps` project; confirm rejection by `clusterResourceWhitelist`.
- **Lab 4.3** — Wire Dex to GitHub OAuth with your `naidu72` org; log in as a team member and verify read-only mapping.
- **Lab 4.4** — Wire Vault → ESO → an app Secret consumed by guestbook. Rotate the value in Vault and watch it propagate without a Git commit.
- **Lab 4.5** — Add a Friday-evening `syncWindow`; try an auto-sync inside it; then break glass with a manual sync.
- **Lab 4.6** — Expose ArgoCD through your `cloudflare-tunnel-ingress-controller` with a `cert-manager` certificate, and turn off `server.insecure`.

---

## Phase 5 — Progressive Delivery with Argo Rollouts

**ArgoCD deploys. Argo Rollouts controls *how* the new version takes traffic.** They're separate controllers; ArgoCD syncs the `Rollout` object and Rollouts executes the strategy.

### 5.1 Install (as an App-of-Apps child)

```yaml
# platform/argo-rollouts.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-rollouts
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "1" }
spec:
  project: platform
  source:
    repoURL: https://argoproj.github.io/argo-helm
    chart: argo-rollouts
    targetRevision: 2.40.5
    helm:
      values: |
        installCRDs: true
        dashboard:
          enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argo-rollouts
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

### 5.2 Canary with Istio (you already have Istio)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: guestbook
  namespace: istio-demo
spec:
  replicas: 4
  revisionHistoryLimit: 3
  selector:
    matchLabels: { app: guestbook }
  template:
    metadata:
      labels: { app: guestbook }
    spec:
      containers:
        - name: guestbook
          image: ghcr.io/naidu72/guestbook:v2.0.0
          resources:
            requests: { cpu: 50m, memory: 64Mi }
  strategy:
    canary:
      canaryService: guestbook-canary
      stableService: guestbook-stable
      trafficRouting:
        istio:
          virtualService:
            name: guestbook-vsvc
            routes: [primary]
      analysis:
        templates: [{ templateName: success-rate }]
        startingStep: 2            # start analysing once at 20%
        args:
          - name: service-name
            value: guestbook-canary
      steps:
        - setWeight: 5
        - pause: { duration: 2m }
        - setWeight: 20
        - pause: { duration: 5m }
        - setWeight: 50
        - pause: {}                # indefinite — requires manual promote
        - setWeight: 100
```

### 5.3 AnalysisTemplate — automated rollback

This is the point of Rollouts. Without analysis you have a slow manual deploy.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: istio-demo
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 1m
      count: 5
      successCondition: result[0] >= 0.95
      failureLimit: 2               # 2 failed measurements → abort + rollback
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc:9090
          query: |
            sum(irate(istio_requests_total{
              destination_service=~"{{args.service-name}}.*",
              response_code!~"5.."}[2m]))
            /
            sum(irate(istio_requests_total{
              destination_service=~"{{args.service-name}}.*"}[2m]))
```

On failure: traffic returns to stable **automatically, in seconds**, with no human and no Git commit.

### 5.4 Blue/Green

```yaml
  strategy:
    blueGreen:
      activeService: guestbook-active
      previewService: guestbook-preview
      autoPromotionEnabled: false        # human gate
      scaleDownDelaySeconds: 300         # keep blue warm for fast rollback
      prePromotionAnalysis:
        templates: [{ templateName: smoke-test }]
      postPromotionAnalysis:
        templates: [{ templateName: success-rate }]
```

### 5.5 Canary vs Blue/Green — pick correctly

| | Canary | Blue/Green |
|---|---|---|
| Extra capacity | ~10–20% | **100%** |
| Blast radius | 5% of users | all-or-nothing at cutover |
| Rollback speed | seconds (shift weight) | seconds (flip Service) |
| DB migrations | hard — both versions live | easier — one version live |
| Needs mesh/ingress | yes for fine weights | no |
| Best for | stateless HTTP services | stateful apps, big schema changes |

On a 4-node Pi cluster, blue/green's 2× capacity requirement is a real constraint. **Prefer canary.**

### 5.6 The ArgoCD ↔ Rollouts integration gotcha

A `Rollout` mid-canary looks `Progressing`, and ArgoCD may report the app `OutOfSync` because the live weight differs from Git. Add the Rollouts health check via `resource.customizations` (the Rollouts chart ships a Lua check) and let it settle. Don't chase the diff.

### Phase 5 Labs

- **Lab 5.1** — Install Argo Rollouts as an App-of-Apps child; install the `kubectl argo rollouts` plugin.
- **Lab 5.2** — Convert guestbook `Deployment` → `Rollout` with a basic canary (no analysis). Promote manually via `kubectl argo rollouts promote guestbook -n istio-demo`.
- **Lab 5.3** — Add Istio `VirtualService` traffic splitting; verify with `istioctl proxy-config routes` that weights actually shift.
- **Lab 5.4** — Add the Prometheus `AnalysisTemplate`. Deploy a deliberately broken image (returns 500s) and **watch it roll itself back.** This is the payoff lab.
- **Lab 5.5** — Blue/green with `prePromotionAnalysis` and a manual gate; measure the capacity cost on your Pi nodes with `kubectl top nodes`.
- **Lab 5.6** — Full loop: GitHub Actions (your `arc-runners`) builds a multi-arch image → writes the tag to this repo → ArgoCD syncs → Rollouts canaries it → Prometheus judges it. **That's the complete production pipeline.**

---

## 3. Five Real-World Enterprise Use Cases

---

### Use Case 1 — Multi-Cluster, Multi-Region Fleet Management

**Problem.** 40 clusters across 3 regions. Platform team must guarantee `cert-manager`, `external-secrets`, and network policy are present, identical in version, and drift-corrected — on every cluster, forever. Doing this per-cluster doesn't scale past about five.

**Architecture.** One central "hub" ArgoCD (yours would be `pi-k8s`) managing all spokes. Register clusters with labels; use a `clusters` generator filtered by label, plus a `matrix` for the app dimension. Per-cluster variance comes from generator-injected values, not from copied YAML.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-baseline
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - matrix:
        generators:
          - clusters:
              selector:
                matchLabels:
                  argocd.argoproj.io/secret-type: cluster
                  fleet: managed
          - list:
              elements:
                - component: cert-manager
                  wave: "-1"
                - component: external-secrets
                  wave: "-1"
                - component: kyverno
                  wave: "0"
  template:
    metadata:
      name: '{{.name}}-{{.component}}'
      annotations:
        argocd.argoproj.io/sync-wave: '{{.wave}}'
    spec:
      project: platform
      source:
        repoURL: https://github.com/naidu72/argocd.git
        targetRevision: HEAD
        path: 'platform/{{.component}}'
        helm:
          valueFiles:
            - values.yaml
            - 'values-{{.metadata.labels.region}}.yaml'
      destination:
        server: '{{.server}}'
        namespace: '{{.component}}'
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Cluster registration carries the metadata that drives everything:

```bash
argocd cluster add prod-eu-1 --name prod-eu-1 \
  --label fleet=managed --label region=eu --label env=prod
```

**Result.** Adding cluster #41 is one `argocd cluster add`. Three Applications appear automatically. Upgrading cert-manager fleet-wide is one commit.

**Watch out:** a hub failure means no reconciliation anywhere. Above ~50 clusters or across trust boundaries, move to per-region hubs with a shared repo.

---

### Use Case 2 — Disaster Recovery: Rebuild a Cluster in Under an Hour

**Problem.** Region loses its cluster. Traditional recovery means hunting through runbooks and Terraform state for what was actually deployed, in what order.

**Architecture.** Because the cluster is 100% Git-described, recovery is: provision empty cluster → install ArgoCD → apply one root Application → wait.

```bash
# 1. New empty cluster exists
# 2. Install ArgoCD — the ONE imperative step, from your versioned values file
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace \
  --version 10.1.4 -f platform/argocd/values.yaml

# 3. Restore ArgoCD's own state (repo creds, cluster secrets, projects)
argocd admin import - < argocd-backup-2026-07-22.yaml

# 4. Bootstrap everything else — one command
kubectl apply -f bootstrap/root-app.yaml

# 5. Watch the whole platform rebuild itself
argocd app wait root --timeout 3600
```

Automate the state backup as a CronJob:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: argocd-backup
  namespace: argocd
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: argocd-application-controller
          restartPolicy: OnFailure
          containers:
            - name: backup
              image: quay.io/argoproj/argocd:v3.4.5
              command: [sh, -c]
              args:
                - argocd admin export > /backup/argocd-$(date +%F).yaml
              volumeMounts:
                - { name: backup, mountPath: /backup }
          volumes:
            - name: backup
              persistentVolumeClaim: { claimName: argocd-backup }
```

**Critical caveat — GitOps does not restore data.** It restores *configuration*. PVCs, databases, and object storage need Velero or native snapshots. The number of teams that discover this during a real incident is high; don't be one.

**RTO reality:** ~15 min for the platform layer, plus image pull time, plus data restore. Test it quarterly — a DR plan you haven't executed is a hypothesis.

---

### Use Case 3 — Microservices at Scale: 200 Services, 4 Environments

**Problem.** 200 services × dev/staging/uat/prod = 800 Applications. Hand-maintaining that YAML is impossible. Each team must own its service without touching platform config, and prod must require approval.

**Architecture.** Config-driven `git` **files** generator. Each service owns a small config file; the platform team owns the template.

```
apps/
├── checkout/
│   ├── base/
│   └── envs/
│       ├── dev.json
│       ├── staging.json
│       └── prod.json
```

```json
// apps/checkout/envs/prod.json
{
  "service": "checkout",
  "env": "prod",
  "cluster": "https://prod.k8s.internal",
  "replicas": 12,
  "image": "ghcr.io/naidu72/checkout:v4.2.1",
  "autoSync": false
}
```

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: microservices
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/naidu72/argocd.git
        revision: HEAD
        files:
          - path: 'apps/*/envs/*.json'
  template:
    metadata:
      name: '{{.service}}-{{.env}}'
      labels:
        env: '{{.env}}'
        service: '{{.service}}'
  templatePatch: |                       # conditional logic lives here
    spec:
      project: {{ if eq .env "prod" }}prod{{ else }}nonprod{{ end }}
      source:
        repoURL: https://github.com/naidu72/argocd.git
        targetRevision: HEAD
        path: apps/{{ .service }}/base
        kustomize:
          images:
            - {{ .image }}
          replicas:
            - name: {{ .service }}
              count: {{ .replicas }}
      destination:
        server: {{ .cluster }}
        namespace: {{ .service }}-{{ .env }}
      syncPolicy:
        {{- if .autoSync }}
        automated: { prune: true, selfHeal: true }
        {{- end }}
        syncOptions: [CreateNamespace=true, ApplyOutOfSyncOnly=true]
```

**Result.** A new service = one directory + four JSON files, in a PR the platform team reviews. Prod is manual-sync by construction. Ownership enforced by CODEOWNERS on `apps/*/`.

**At this scale you must also:** shard the application controller, enable `ApplyOutOfSyncOnly`, use webhooks not polling, and set aggressive resource exclusions.

---

### Use Case 4 — Ephemeral Preview Environments per Pull Request

**Problem.** QA and product need to click through a change before merge. Static staging is a queue and a bottleneck.

**Architecture.** `pullRequest` generator — an environment exists exactly as long as the PR does. Pairs directly with your `arc-runners` GitHub Actions setup.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: previews
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - pullRequest:
        github:
          owner: naidu72
          repo: checkout-service
          tokenRef: { secretName: github-token, key: token }
          labels: [preview]           # opt-in: only PRs labelled 'preview'
        requeueAfterSeconds: 60
  template:
    metadata:
      name: 'preview-pr-{{.number}}'
    spec:
      project: preview
      source:
        repoURL: https://github.com/naidu72/checkout-service.git
        targetRevision: '{{.head_sha}}'
        path: deploy
        helm:
          parameters:
            - name: image.tag
              value: '{{.head_sha}}'
            - name: ingress.host
              value: 'pr-{{.number}}.preview.yourdomain.com'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'preview-pr-{{.number}}'
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=true]
  syncPolicy:
    applicationsSync: create-delete      # REQUIRED: PR closed → env destroyed
```

Add a `ResourceQuota` to the `preview` AppProject and a Cloudflare Tunnel wildcard route for `*.preview.yourdomain.com`.

**Result.** Open a PR labelled `preview` → a full environment at a predictable URL in ~2 minutes. Close the PR → it's gone, including the namespace. Cost is bounded by quota, not by discipline.

---

### Use Case 5 — Regulated Change Control: Auditable, Approval-Gated Production

**Problem.** SOX/PCI/HIPAA require that every production change be reviewed, approved, attributable, and reconstructible for auditors years later. Screenshots of a Jenkins console don't satisfy that.

**Architecture.** Git *is* the audit log. Combine: signed commits, protected branches with mandatory review, manual-sync-only prod, sync windows, and AppProject-scoped RBAC.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: prod
  namespace: argocd
spec:
  sourceRepos: ['https://github.com/naidu72/argocd.git']
  destinations:
    - { server: 'https://prod.k8s.internal', namespace: '*' }

  signatureKeys:                        # only GPG-signed commits may deploy
    - keyID: 4AEE18F83AFDEB23

  syncWindows:
    - kind: allow
      schedule: '0 9 * * 1-4'           # Mon–Thu 09:00
      duration: 8h
      applications: ['*']
      manualSync: true
    - kind: deny
      schedule: '0 0 * * *'
      duration: 24h
      applications: ['*']
      manualSync: false                 # hard freeze outside the window

  roles:
    - name: deployer
      description: May sync prod, may not edit definitions
      policies:
        - p, proj:prod:deployer, applications, get,      prod/*, allow
        - p, proj:prod:deployer, applications, sync,     prod/*, allow
        - p, proj:prod:deployer, applications, update,   prod/*, deny
        - p, proj:prod:deployer, applications, delete,   prod/*, deny
        - p, proj:prod:deployer, exec,         create,   prod/*, deny
      groups: ['naidu72:release-managers']
```

Prod Applications carry **no** `automated` block — sync is deliberate, attributed, and timestamped.

Ship the audit trail out for retention:

```yaml
# argocd-notifications-cm
trigger.on-sync-succeeded: |
  - when: app.status.operationState.phase in ['Succeeded']
    send: [audit-log]
template.audit-log: |
  webhook:
    audit-sink:
      method: POST
      body: |
        {
          "app": "{{.app.metadata.name}}",
          "revision": "{{.app.status.sync.revision}}",
          "initiatedBy": "{{.app.status.operationState.operation.initiatedBy.username}}",
          "startedAt": "{{.app.status.operationState.startedAt}}",
          "phase": "{{.app.status.operationState.phase}}"
        }
```

**Result.** For any production change an auditor can ask about, you produce: the commit, its GPG signature, the PR approvals, the exact synced revision, who clicked sync, and when. Reconstructing the state of prod on any past date is `git checkout <sha>`.

---

## 4. Troubleshooting & Operational Best Practices

### 4.1 Common failures and their real causes

**`ComparisonError: rpc error ... failed to get repo`**
Repo creds or network. Check `argocd repo list`, then `kubectl -n argocd logs deploy/argocd-repo-server`. On your Pi cluster, also suspect DNS — CoreDNS on k3s under load is a frequent culprit.

**App stuck `Progressing` forever**
The health check never returns Healthy. Usually a Deployment whose pods can't schedule (on arm64: `exec format error` = amd64-only image — exactly the problem your `guestbook/arm64` kustomization works around), or a Service of type LoadBalancer with no provider.
```bash
argocd app get <app> --show-operation
kubectl -n <ns> get events --sort-by=.lastTimestamp | tail -30
```

**Perpetual `OutOfSync` with an empty diff**
Almost always a mutating webhook, a defaulted field, or `managedFields` noise. Diagnose with:
```bash
argocd app diff <app> --local ./path      # what ArgoCD thinks differs
kubectl get <res> -o yaml --show-managed-fields
```
Fix with `ignoreDifferences`, preferably `managedFieldsManagers`.

**`SyncError: the server could not find the requested resource`**
CRD applied in the same wave as the CR that uses it. Put CRDs in a negative sync wave, or `ServerSideApply=true` + `SkipDryRunOnMissingResource=true`.

**Sync succeeded but nothing changed**
`targetRevision: HEAD` with a cached repo. Force it: `argocd app get <app> --hard-refresh`.

**Application won't delete (stuck Terminating)**
A finalizer waiting on child resources that can't be removed:
```bash
kubectl -n argocd patch app <name> --type merge \
  -p '{"metadata":{"finalizers":null}}'
```
Understand that this **orphans** the cluster resources — you now have to clean up manually.

**`error: metadata.annotations: Too long`**
The 256KB `last-applied-configuration` limit, hit by big CRDs (Istio, cert-manager, Prometheus Operator). Fix: `ServerSideApply=true`.

### 4.2 Diagnostic command set

```bash
argocd app get <app>                       # status summary
argocd app get <app> --show-operation      # current sync operation detail
argocd app diff <app>                      # live vs desired
argocd app history <app>                   # deployment history
argocd app rollback <app> <id>             # revert to a previous sync
argocd app manifests <app>                 # exactly what repo-server rendered
argocd app resources <app>                 # per-resource health
argocd app sync <app> --dry-run
argocd app sync <app> --prune --force      # last resort; understand it first
argocd app terminate-op <app>              # cancel a stuck sync

argocd admin settings validate             # config sanity
argocd admin app get-reconcile-results     # what the controller decided
```

Logs worth knowing:
```bash
kubectl -n argocd logs sts/argocd-application-controller -f | grep -i <app>
kubectl -n argocd logs deploy/argocd-repo-server -f
```

### 4.3 Performance tuning for large clusters

**Shard the application controller** (one shard per ~2000 apps or ~50 clusters):

```yaml
controller:
  replicas: 3
  env:
    - name: ARGOCD_CONTROLLER_SHARDING_ALGORITHM
      value: consistent-hashing        # better rebalancing than round-robin
```

**Scale repo-server** — it's CPU-bound on Helm/Kustomize rendering:

```yaml
repoServer:
  replicas: 3
  env:
    - name: ARGOCD_EXEC_TIMEOUT
      value: 5m
  extraArgs:
    - --parallelismlimit=20            # cap concurrent manifest generations
  resources:
    requests: { cpu: 500m, memory: 512Mi }
    limits:   { memory: 2Gi }
```

**Stop watching resources you don't manage** — the biggest single win on a busy cluster:

```yaml
# argocd-cm
resource.exclusions: |
  - apiGroups: ["cilium.io"]
    kinds: ["CiliumIdentity", "CiliumEndpoint"]
    clusters: ["*"]
  - apiGroups: ["metrics.k8s.io"]
    kinds: ["*"]
    clusters: ["*"]
  - apiGroups: [""]
    kinds: ["Event", "Endpoints"]
    clusters: ["*"]
  - apiGroups: ["discovery.k8s.io"]
    kinds: ["EndpointSlice"]
    clusters: ["*"]
```

**Replace polling with webhooks.** Default `timeout.reconciliation: 180s` means every app re-checks Git every 3 minutes. At 500 apps that's constant load for nothing. With a GitHub webhook to `/api/webhook`, raise it:

```yaml
# argocd-cm
timeout.reconciliation: 600s
```

**Other levers:**
- `ApplyOutOfSyncOnly=true` — skip already-matching resources
- `--repo-server-timeout-seconds` — raise for large Helm charts
- Redis HA (`redis-ha.enabled: true`) once you depend on this in production
- Split very large monorepos, or use `sharding` on the repo generator

**For your Pi cluster specifically:**
- Pin `redis` and `application-controller` to the same node (pod affinity) — you're currently paying a network hop on every cache read
- Keep `repo-server` on `pi5-0`/`pi5-1` (the Pi 5s) — it's the CPU-hungry component and the `rock64`/`pi4` are weaker
- Set memory limits deliberately; the controller's resource cache grows with cluster object count and OOM on a 4–8GB node is easy to hit

### 4.4 Monitoring & alerting

Enable metrics (already in the Phase 1 values), then scrape. Key series:

| Metric | Meaning |
|---|---|
| `argocd_app_info` | per-app `sync_status`, `health_status`, `project` — the backbone of every alert |
| `argocd_app_sync_total` | sync counter by phase (`Succeeded`/`Failed`/`Error`) |
| `argocd_app_reconcile_bucket` | reconciliation duration histogram — your saturation signal |
| `argocd_app_k8s_request_total` | API calls to target clusters |
| `argocd_git_request_duration_seconds` | Git fetch latency — repo-server health |
| `argocd_cluster_api_resource_objects` | objects cached per cluster — memory driver |
| `argocd_redis_request_duration` | cache latency (relevant to your cross-node redis) |

Alert rules worth having from day one:

```yaml
groups:
  - name: argocd
    rules:
      - alert: ArgoCDAppOutOfSync
        expr: argocd_app_info{sync_status="OutOfSync"} == 1
        for: 30m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.name }} has been OutOfSync for 30m"

      - alert: ArgoCDAppDegraded
        expr: argocd_app_info{health_status="Degraded"} == 1
        for: 10m
        labels: { severity: critical }
        annotations:
          summary: "{{ $labels.name }} is Degraded"

      - alert: ArgoCDSyncFailing
        expr: increase(argocd_app_sync_total{phase=~"Failed|Error"}[30m]) > 3
        labels: { severity: critical }

      - alert: ArgoCDReconciliationSlow
        expr: |
          histogram_quantile(0.95,
            sum(rate(argocd_app_reconcile_bucket[10m])) by (le)) > 30
        for: 15m
        labels: { severity: warning }
        annotations:
          summary: "p95 reconciliation > 30s — controller saturated, consider sharding"

      - alert: ArgoCDComponentDown
        expr: up{job=~"argocd-.*"} == 0
        for: 5m
        labels: { severity: critical }
```

> **Alert on `Degraded`, not on `OutOfSync`.** `OutOfSync` for 30 minutes on a manual-sync prod app is *expected* — it means a change is awaiting approval. Alerting on it trains people to ignore ArgoCD alerts. `Degraded` means something is actually broken.

Grafana: import dashboards **14584** (ArgoCD overview) and **14391** (Argo Rollouts).

Notifications — route to your `n8n` for anything clever:

```yaml
# argocd-notifications-cm
trigger.on-health-degraded: |
  - when: app.status.health.status == 'Degraded'
    send: [app-degraded]
template.app-degraded: |
  message: |
    :rotating_light: *{{.app.metadata.name}}* is Degraded
    Revision: {{.app.status.sync.revision}}
    <{{.context.argocdUrl}}/applications/{{.app.metadata.name}}|Open>
```
```yaml
# on the Application
metadata:
  annotations:
    notifications.argoproj.io/subscribe.on-health-degraded.slack: platform-alerts
```

### 4.5 Operational principles

1. **Never `kubectl apply` to a managed namespace.** With `selfHeal: true` it's reverted; without it, you've created invisible drift.
2. **`allowEmpty: false` on everything.** Prevents a rendering bug from becoming a deletion event.
3. **Prod is manual-sync.** Auto-sync for dev/staging, human intent for prod.
4. **Separate config repo from source repo.** A CI-driven image-tag bump shouldn't retrigger CI.
5. **Pin every version.** No `targetRevision: HEAD` on prod, no floating chart versions, no `:latest`.
6. **Test the DR path quarterly.** Untested recovery is a guess.
7. **Backup ArgoCD's own state** (`argocd admin export`) — cluster secrets and repo creds are *not* in your Git repo.
8. **Everything through an AppProject.** `default` should be able to deploy nothing.
9. **`argocd app diff` before every prod sync.** Read what you're about to change.
10. **The control plane manages itself,** but keep a break-glass `helm upgrade`/`helm rollback` path — you need it precisely when self-management is what broke.

---

## 5. Suggested Schedule

| Week | Focus | Exit criterion |
|---|---|---|
| 1 | Phase 1 | Values file in Git matches `helm get values`; guestbook self-heals and prunes on demand |
| 2 | Phase 1–2 | Multi-arch image built; `images:` override deleted |
| 3 | Phase 2 | Repo restructured; App-of-Apps bootstraps the platform; git generator working |
| 4 | Phase 3 | Hooks, waves, and `ignoreDifferences` all demonstrated; webhook syncs |
| 5 | Phase 4 | AppProjects + RBAC + GitHub SSO live; `admin` disabled |
| 6 | Phase 4 | Vault → ESO → app secrets; ArgoCD exposed via Cloudflare Tunnel with real TLS |
| 7 | Phase 5 | Rollouts canary with Prometheus analysis auto-rolling-back |
| 8 | Ops | Prometheus + Grafana + alerts; DR drill; `argocd admin export` restore rehearsed |

**Then build one of the five use cases end-to-end.** Use Case 4 (PR preview environments) is the best fit for your setup — you have `arc-runners` and Cloudflare Tunnel already, and it's the one that most visibly demonstrates GitOps value.

---

## 6. Reference

- Docs — https://argo-cd.readthedocs.io/
- ApplicationSet generators — https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators/
- Argo Rollouts — https://argo-rollouts.readthedocs.io/
- Best practices — https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/
- Example apps — https://github.com/argoproj/argocd-example-apps
- OpenGitOps principles — https://opengitops.dev/
- Certification: **Argo Project Associate (CAPA)**, CNCF — a reasonable target after Week 8
