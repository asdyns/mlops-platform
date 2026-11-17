# PRD: mlops-platform (local, EKS-portable)

Status: v2 (2026-11-16). The platform is the product; tenants are its users.
Current phase: **P0, not started**. Location: `mlops-platform/docs/platform-PRD.md`.
Companion: `recsys-PRD.md`, the first tenant.

## 0. Context for a new session (read first)
**Who:** principal engineer with a strong platform/K8s/MLOps background. Prefers
direct answers, concrete numbers, minimal complexity, no repeated caveats, and
explicit pushback when a proposal is wrong. From the user's own notes (`.local`):
- Show YAML inline in chat, not only as files.
- Break each step into sub-steps and walk through them incrementally; move faster
  through patterns already learned.
- Engage with the user's guesses.
- Verify version-dependent tool behaviour before asserting it (bundled
  `kubectl apply -k` kustomize ≠ standalone CLI); test in a scratch copy when unsure.

**Focus (2026-11-16): the platform is the main deliverable.** Its users are data
scientists who build real models. Two **reference tenants** exercise every platform
path:
- **recsys-lite** (popularity → ALS on MovieLens small; retrieval-style serving,
  replayed traffic, deliberately bad models), see `recsys-PRD.md`;
- **house-price** (tabular sklearn, the simplest possible tenant).

Model quality isn't a goal.

**Bigger picture:** the real end goal is an "AI childcare" product on EKS, and time
is limited. This platform should be the substrate for that product too. Flag work
that costs more than it teaches.

**Repo:** `~/Documents/work/code/30-ml-eng/mlops-platform`, GitHub
`asdyns/mlops-platform`. It already exists: **extend it, don't recreate it.**

## 1. Purpose and scope
A model-agnostic platform that ML apps ("tenants") plug into through a fixed
contract (§3). It runs locally on one laptop and moves to EKS by swapping overlays
and infra only. The tenant manifests stay unchanged.

**Provides:**
- **Infrastructure:** cluster, ingress, image registry, object storage, Postgres,
  MLflow tracking + registry, observability, identity (Keycloak), tenant onboarding.
- **Model lifecycle services (§6a):** KServe model serving, prediction logging,
  promotion, model monitoring.
- **Feature store (§6b):** Feast (registry, offline store, online store).
- **Golden path (§6c):** a tenant repo template + onboarding docs: the path from a
  notebook to a deployed, monitored model for a data scientist.
- **Platform acceptance tests (§6d):** `make platform-test` proves the gates
  *reject* bad models, not just accept good ones. The platform owns the *mechanism*; tenants supply
  *policy and model logic*.

**Non-goals:** pipeline orchestrator (tenants use Makefiles; Argo Workflows at
~300 MB if ever wanted), tracing, GPU in-cluster, multi-node
scheduling, a shared tenant
Python SDK. Platform capabilities ship as base images + Kustomize components + YAML
policy files, and tenants extend them through hooks (§6a). They don't import a
platform library.

## 2. Ownership boundary
| Platform owns | Tenant owns |
|---|---|
| Cluster config, local registry, ingress controller | Its code, images, model artifacts |
| MinIO, Postgres (one instance, a DB per tenant), MLflow server | Its Kustomize app manifests: Deployment, Service, Ingress, ServiceMonitor, CronJobs/Jobs |
| kube-prometheus-stack, Loki, Alloy, Grafana + datasources | Its Grafana dashboards (labelled ConfigMaps) |
| Keycloak + realm | Its Keycloak client definition |
| `make tenant NAME=x` | What runs inside its namespace |
| KServe (controller, ClusterServingRuntime `mlops-mlflow`), `mlops-logsink`, `mlops-promote`, `mlops-monitor`, Feast (registry, Redis online store) + Kustomize components; ArgoCD (platform apps, a per-tenant AppProject + Application), Kyverno ClusterPolicies | Model logic (pyfunc incl. checks in `load_context`), any front API service, `promotion.yaml` values, monitoring metrics plugin, Feast feature definitions |

## 3. Tenant contract (the interface; keep stable)
Each tenant namespace gets:

| Need | Provided as | EKS equivalent |
|---|---|---|
| Tracking/registry | Secret `mlflow` → `MLFLOW_TRACKING_URI` (no S3 creds needed: artifacts proxied) | Same MLflow, RDS backend |
| Object storage | Secret `s3` → `AWS_ENDPOINT_URL`, `BUCKET`, access key/secret scoped to the tenant bucket only | S3 + IRSA (no keys) |
| Database | Secret `postgres` → DSN for the tenant's own DB/role | RDS |
| Ingress | Tenant writes an `Ingress` with no class; the overlay patches the class. Host `<app>.localtest.me` | AWS LB Controller |
| Metrics | ServiceMonitor labelled `platform.io/scrape: "true"` | AMP / Prometheus |
| Dashboards | ConfigMap labelled `grafana_dashboard: "1"` | Same |
| Logs | JSON to stdout with `app` and `model_version` fields | Same Alloy → Loki |
| Auth | ConfigMap `platform-auth` → JWKS URL + issuer | Same |
| Images | Push to `localhost:5001/<tenant>/<image>:<tag>` | ECR |
| Limits | ResourceQuota per namespace (default 4 CPU / 4 Gi; tenants that train in-cluster get a separate `training` quota, sized per tenant (e.g. 6 CPU / 8 Gi for a 32M-scale run), enforced through Kueue once P4 exists) | Same |
| Serving | `InferenceService` from component `components/model-service` (KServe RawDeployment, runtime `mlops-mlflow` or a tenant runtime `FROM` it). `storageUri` is managed by `mlops-promote`, never hand-edited. Protocol: V2 Open Inference Protocol | Same |
| Model hooks | Model is an MLflow pyfunc. Its self-checks run in `load_context()` and raise on failure (so the pod never becomes Ready). It must log an `input_example`, the required tags (`git_sha`, `dataset_hash`, `config`) and return `model_version` in its output | Same |
| Prediction logs | The KServe payload logger (`logger.mode: all`) sends to the per-tenant `mlops-logsink`, which writes the `predictions` / `feedback` tables in the tenant DB (it owns the schema) | RDS |
| Promotion | `promotion.yaml` in the tenant repo, executed by the `mlops-promote` Job | Same |
| Monitoring | Component `components/model-monitor` + optional metrics plugin; results go to table `monitoring_results` | Same |
| Model artifacts for serving | Tenant bucket `<tenant>-models`, with a read-only credential for the KServe storage initializer (Secret `s3-models` + SA) | S3 + IRSA |
| Network | Default-deny NetworkPolicy in the tenant namespace, created by `make tenant`. Allowed by default: DNS, intra-namespace traffic, egress to the platform services (MLflow, MinIO, Postgres, Redis, Keycloak), ingress from the ingress controller and from Prometheus. Extra egress needs a tenant-declared policy | Same (VPC CNI network policies) |
| Alerts | `PrometheusRule` labelled `platform.io/scrape: "true"` in the tenant namespace | AMP / Alertmanager |
| Deployment (GitOps) | ArgoCD Application `<tenant>`, in AppProject `<tenant>`, syncs the tenant repo path `k8s/overlays/<env>`. The AppProject allows only the tenant namespace and denies cluster-scoped resources. Tenants deploy by merging to their repo, not with `kubectl apply` | Same ArgoCD |
| Policy | Kyverno ClusterPolicies (§6, CI/CD + policy). Tenant manifests must pass them; the same policies run in tenant CI via the Kyverno CLI | Same |
| Batch scoring | Component `components/batch-inference` (Job/CronJob) | Same |
| Features | Secret `feast` holding a rendered `feature_store.yaml` (registry DSN, Redis, S3); Feast project = tenant name | Same (ElastiCache / RDS) |

Changing the contract is a breaking change. Document it in `docs/contract.md`.

## 4. Current repo state (reviewed 2026-11-09)
**Git (updated 2026-11-16):** `main` = `f5a7a8e`, which includes `feat/eks` (EKS
StorageClass overlay, validated on a throwaway eksctl cluster) via PR #1.
`feat/terraform-eks` is still **unmerged**: it adds a hand-rolled Terraform EKS build
(VPC, IAM, cluster, OIDC, node group, access entries; applied and destroyed between
sessions). While `main` is checked out, `terraform/` and `terraform-bootstrap/` show
as untracked leftovers from that branch. Everything is pushed. Untracked session notes: `.local`
(platform), `.local-terra` (Terraform build order).

**Keep:**
- Kustomize `base/` (cloud-agnostic) + `overlays/local` + `overlays/eks` (partial).
  StorageClass and ingressClass come from overlay patches.
- `secretGenerator` / `configMapGenerator` from env files.
- A ServiceAccount per app with automount off (maps one-to-one onto IRSA).
- Requests and limits on every workload.
- The nginx dashboard landing page.

**Gaps:**
1. Targets **k3s** (installed, inactive). Known pain, documented twice: a DHCP IP
   change breaks `/etc/hosts` and k3s pod routing; `systemctl stop` leaves
   containerd-shims behind.
2. MLflow `v2.11.3`:
   - psycopg2 is pip-installed by an initContainer at every start;
   - `--default-artifact-root=s3://mlflow/` means clients need the MinIO **root**
     credentials.
3. No tenancy: one `mlops` namespace, one `platform-secrets` with root credentials.
4. `mlflow-db` is MLflow-only.
5. No local registry, observability, Keycloak or CI. MinIO and Jupyter use
   `:latest`. StatefulSet Services aren't headless. No `.env.secrets.example`.
6. `patchesStrategicMerge` (deprecated) is kept deliberately: bundled kustomize can't
   take multi-doc patch files under `patches:`.

## 5. Open decisions (resolve before P0)
| Decision | Recommendation | Why |
|---|---|---|
| kind vs. k3s | **DECIDED 2026-11-17: kind** (k3s to be uninstalled via `k3s-uninstall.sh` before the kind cluster takes 80/443) | Disposable (recreate ~1 min). Ports map to localhost, so `*.localtest.me` survives DHCP changes. Cost: an `overlays/kind` (same `local-path` provisioner) plus an ingress controller. If switching, run `k3s-uninstall.sh` so servicelb can't grab 80/443 |
| Ingress API | **DECIDED 2026-11-17: Ingress + Traefik** (Helm) | Base Ingress objects already exist. The class patch maps to the AWS LB Controller on EKS. ingress-nginx is retired (Mar 2026). Gateway API/Envoy is a later revisit, and becomes required if Istio is adopted (Later, §9) or if the scale track (`scale-track.md`) starts, for Gateway API Inference Extension LLM routing |
| Merge `feat/terraform-eks` → `main` | **DONE** (PR #2, merged 2026-11-16) | Don't branch new work off a stale `main` |
| Serving runtime | **DECIDED 2026-11-16: KServe** (RawDeployment, no Knative) | User's choice: the industry-standard serving layer. Costs: protocol-fixed routes (domain APIs need a tenant front service), a log sink to write, cert-manager + controller. Canary and scale-to-zero (serverless/Knative mode) stay deferred |
| Jupyter in the local overlay | **DECIDED 2026-11-17: keep** | Kept in the local overlay (costs ~0.5–1 GB of RAM, see §7). Tenants can still run notebooks on the host |

## 6. Target design
**Cluster:** kind `mlops`, single node, `extraPortMappings` 80/443, a kind-attached
registry `localhost:5001` (the documented kind local-registry pattern). Host facts:
30 GB RAM, 8 cores, no GPU, inotify already raised (524288/1024). kind is **not
installed** yet. Host port 5432 is taken by an unrelated container, so expose
Postgres on 5433 if exposing at all.

**Ingress:** Traefik via Helm. Hostnames on `*.localtest.me` (resolves to
127.0.0.1): `mlops.`, `mlflow.`, `minio.`, `minio-console.`, `grafana.`, `keycloak.`,
plus tenant hosts.

**MLflow:**
- Image: custom 3.x image built and pushed to the local registry (pinned version,
  with psycopg2 + boto3 baked in). Replaces the initContainer.
- Backend store: Postgres (DB `mlflow`), not SQLite. It avoids SQLite write locking,
  it maps directly to RDS on EKS, and the Postgres instance exists anyway.
- Artifacts: proxied, `--serve-artifacts --artifacts-destination s3://mlflow`, so
  clients need only the tracking URI.
- Hosts: set `--allowed-hosts` for the ingress host plus the in-cluster service name
  (recent 3.x validates the Host header; verify the flag for the pinned version).

**Postgres:** rename/generalise `mlflow-db` to `postgres`. One instance with DBs
`mlflow` plus one per tenant, each with its own role. Headless Service.

**MinIO:** pin the version. The root credentials are used only by the platform. Each
tenant gets a MinIO user + policy scoped to `s3://<tenant>-*` buckets.

**Tenant onboarding:** `make tenant NAME=x` is idempotent and creates:
- namespace + ResourceQuota + LimitRange;
- a Postgres DB/role;
- a MinIO user, policy and buckets (`<x>-data`, `<x>-artifacts` as needed);
- the contract Secrets (`mlflow`, `s3`, `postgres`) and the `platform-auth`
  ConfigMap in that namespace;
- **NetworkPolicies:** default-deny ingress + egress, plus the allow-list in the §3
  Network row. **Check enforcement first:** kind's default CNI (kindnet) only
  enforces NetworkPolicy in recent kind releases, so verify for the installed
  version with a deny test. If it doesn't, install Calico in `overlays/kind`. A
  policy that isn't enforced is worse than none.

- **(P3)** an ArgoCD AppProject + Application for the tenant repo. From P3, Kyverno
  *generate* rules create the default-deny NetworkPolicy and LimitRange whenever a
  namespace labelled `platform.io/tenant` appears, and `make tenant` stops creating
  them (it keeps the DB, bucket, Redis ACL and Secrets).

Implement it with a script or Job using `psql` / `mc`. Don't build an operator.

**Observability (P1):**
- **kube-prometheus-stack** (Helm): Alertmanager **on** (see Alerting), retention 3d, and
  ServiceMonitor selection by the `platform.io/scrape: "true"` label across all
  namespaces. The Grafana dashboard sidecar picks up `grafana_dashboard: "1"`
  ConfigMaps in all namespaces.
- **Loki** single binary + **Alloy** DaemonSet (official charts). Parse JSON logs and
  promote `app` and `model_version` to labels.
- Grafana datasources: Prometheus, Loki, and a Postgres datasource per tenant DB
  (read-only role).

**Alerting (P1):**
- **Delivery:** Alertmanager with a webhook receiver (ntfy or Slack), configured
  from a gitignored secret, with the Alertmanager UI as a fallback. Group by
  `namespace`, `alertname`.
- **Platform rules:** target down; pod CrashLoopBackOff > 5 min; PVC > 80%;
  CronJob or Job failed (kube-state-metrics); InferenceService not Ready > 5 min;
  `mlops_logsink_dropped_total` increasing; **backup older than 26 h**.
- **Tenant rules:** tenants ship their own `PrometheusRule` (contract). For recsys:
  p95 latency, fallback rate, drift threshold.
- **Silence by default** while kind is intentionally stopped. No paging on a laptop.

**Backups (P1):**
- **Postgres:** a nightly CronJob running `pg_dump -Fc` per DB (mlflow, each tenant,
  keycloak). Restore is to a fresh instance.
- **MinIO:** `mc mirror` of the `mlflow`, `<tenant>-data` and `<tenant>-models`
  buckets.
- **Target:** a host directory mounted into the kind node (`extraMounts` →
  `~/mlops-backups`), **not** MinIO itself. A backup on the same PVC dies with the
  cluster, and kind clusters are meant to be disposable. Retention: 7 daily.
- **Restore:** `make restore` (Postgres + MinIO) into a freshly created cluster.
  **Run a restore drill once per phase**; an untested backup doesn't count.
- **Freshness:** `kube_cronjob_status_last_successful_time` feeds the "backup older
  than 26 h" alert.
- **EKS:** replaced by RDS automated snapshots + S3 versioning/replication. This
  component is local-overlay only.

**Identity (P2):** Keycloak (pinned, dev-mode-free production start, backed by a
Postgres DB) with realm `mlops`. Tenants get a confidential client for the
client-credentials flow. `platform-auth` exposes the issuer and JWKS URL.

**Secrets:** `secretGenerator` from a gitignored env file. Add
`.env.secrets.example`. Use External Secrets Operator on EKS only; Secret names stay
the same.

**Manifests:** plain Kustomize. Use Helm only for kube-prometheus-stack, Loki, Alloy
and Traefik (and optionally Keycloak). Pin every chart and image version.

**CI/CD + policy (P3):**
- **CI (GitHub Actions):**
  - `kustomize build` for each overlay → kubeconform
  - yamllint
  - `kyverno apply` of the platform policies against the rendered manifests (the same
    policies the cluster enforces)
  - Trivy image scan of platform-built images (fail on critical)
- **ArgoCD** (Helm, pinned; core components only, no Dex: login via the admin
  account locally, Keycloak SSO later):
  - **app-of-apps:** `argocd/root` → one Application per platform component,
    sync-waves ordering CRDs/operators before workloads. Helm charts
    (kube-prometheus-stack, Loki, Alloy, Traefik, KServe, Kyverno) are referenced as
    Argo Helm sources with pinned versions and values files in git.
  - **Bootstrap:** `make bootstrap` installs ArgoCD and applies the root app. After
    that, git is the only way to change the cluster. `kubectl apply` is for
    break-glass only.
  - **Sync:** auto-sync with prune + self-heal for platform apps, auto-sync without
    prune for tenant apps (safer while learning).
  - **Promotion interaction:** `mlops-promote` patches the InferenceService
    `storageUri`, which ArgoCD would revert as drift. Phase 1: tenant Applications
    set `ignoreDifferences` on `/spec/predictor/model/storageUri` and the
    `mlops.io/model-version` annotation. Phase 2 (EKS): promotion **commits** the
    new `storageUri` to the tenant overlay and ArgoCD rolls it out, giving a git
    audit trail.
- **Kyverno** (Helm, pinned; admission + background controllers):
  - **validate:** requests/limits required; no `:latest`; images only from
    `localhost:5001/*` or a pinned upstream allow-list; `runAsNonRoot`, no privileged
    containers or hostPath (except platform-allowlisted, e.g. the backup host
    mount); labels `app` + `platform.io/tenant` required in tenant namespaces.
  - **generate:** default-deny NetworkPolicy + LimitRange for new tenant namespaces.
  - **mutate (minimal):** add `automountServiceAccountToken: false` if unset.
  - **Rollout:** every policy starts in `Audit`. Review PolicyReports in Grafana,
    then flip to `Enforce` per policy. Platform namespaces get scoped exceptions
    (`PolicyException`), never blanket ones.
  - **Ordering:** Kyverno policies and the ArgoCD sync-waves have to be ordered so
    the policies exist before tenant workloads sync.

## 6a. Model lifecycle services
**Rule:** these get built against **both reference tenants**, recsys-lite and
house-price, with house-price onboarded right after recsys's first deploy, not at
the end. Anything only one tenant needs stays in that tenant. Released as versioned
image tags + components (`?ref=vX` remote Kustomize refs). Breaking changes follow
the contract rules.

### Serving: KServe
- **Install:** KServe (pinned) + cert-manager (required for its webhooks), in
  **RawDeployment** mode: plain Deployments + HPA, no Knative or Istio. Check the
  mode's name and ingress settings for the pinned version (Ingress class patched by
  the overlay, as for everything else).
- **ClusterServingRuntime `mlops-mlflow`:** MLServer with the mlflow runtime,
  image pinned and pushed to `localhost:5001/platform/`. A tenant that needs extra
  dependencies (e.g. faiss) builds `FROM` it and registers a namespaced
  `ServingRuntime`.
- **Component `components/model-service`:** an `InferenceService` skeleton
  (predictor `modelFormat: mlflow`, V2 protocol, resources, `logger` →
  `mlops-logsink`, SA with the `s3-models` credential), a PodMonitor for MLServer
  metrics labelled `platform.io/scrape`, and the `mlops-logsink` Deployment.
- **Aliases → storageUri:** KServe doesn't understand MLflow aliases or the proxied
  `mlflow-artifacts:` scheme. At promotion, `mlops-promote` therefore:
  1. resolves the alias to a version;
  2. **copies** that version's artifacts to `s3://<tenant>-models/<model>/<version>/`;
  3. patches the InferenceService `storageUri` and the annotation
     `mlops.io/model-version`;
  4. waits for Ready.

  This keeps tenant isolation (the serving pod can only read its own bucket) and
  maps onto IRSA on EKS. Deployment is declarative; nothing polls.
- **Readiness:** the MLServer model is Ready only after `load_context()` succeeds,
  and the tenant's checks run there.
- **Metrics:** MLServer exposes request latency and counts. Tenant custom metrics go
  through MLServer's custom-metrics API (verify for the pinned version).
- **Auth:** KServe RawDeployment has no JWT validation. Validate JWTs in the tenant
  front service (a FastAPI/JWKS pattern, documented in `docs/contract.md`), or at
  ingress later. The InferenceService itself is cluster-internal only (no public
  Ingress unless a tenant asks).

### Prediction logging: `mlops-logsink`
- **Route:** the InferenceService `logger` (mode `all`) posts CloudEvents (request
  and response). The request id is the `request_id` that the model echoes in its
  output if present, otherwise `ce-id` to the per-tenant `mlops-logsink`
  Service. It's per tenant so it uses only that tenant's `postgres` Secret, which
  preserves isolation.
- **Tables:** owned by the sink (versioned migrations at startup):
  - `predictions(request_id PK, ts, model_name, model_version, entity_id, request jsonb, response jsonb, scores real[])`
  - `feedback(id, request_id FK, ts, entity_id, payload jsonb, kind)`. Tenant front
    services write it, either directly or through the sink's `POST /feedback`.

  Indexes: `(ts)`, `(request_id)`, `(model_version, ts)`.
- **Write path:** batch inserts. When overloaded it drops and counts
  (`mlops_logsink_dropped_total`), and it never blocks inference: the KServe logger
  is async.
- **Field mapping:** `model_version` comes from the response (contract) and
  `entity_id` from a configurable JSONPath on the request.
- **Retention:** `PREDICTION_RETENTION_DAYS`, enforced by a nightly cleanup CronJob.

### Promotion: `mlops-promote`
- **What it is:** an image + CLI that runs as a Job in the tenant namespace (or
  locally). Tenants call it as `make promote`.
- **Input:** the tenant `promotion.yaml` compares `@challenger` against `@champion`:
  ```yaml
  model: recsys
  required_tags: [git_sha, dataset_hash, config, split_t]   # platform adds its 3 always
  required_artifacts: [model_card.md]
  rules:                      # relative to champion; skipped on first promotion
    - {metric: val_recall_at_20,   relative_min: 1.02}
    - {metric: val_ndcg_at_20,     relative_min: 1.00}
    - {metric: catalogue_coverage, relative_min: 0.90}
  checks:                     # always run, against the challenger loaded locally in the Job
    - {type: load}            # pyfunc load_context() must succeed (runs the model's checks)
    - {type: latency, p95_ms: 30, samples: 1000, inputs: artifact:latency_inputs.json}
  on_pass:
    deploy: inferenceservice/recsys     # copy artifacts, patch storageUri, wait Ready
  ```
- **On pass:**
  1. `@previous` ← the old champion, `@champion` ← the challenger.
  2. Deploy as in §6a Serving (copy → patch → wait Ready).
  3. If the InferenceService doesn't become Ready, revert the aliases and the
     `storageUri`.

  The Job's SA can `get/patch` that InferenceService only.
- **On fail:** the reasons are written as tags on the version, and the Job exits
  non-zero.
- **Audit:** MLflow tags plus a `promotions` table in the tenant DB.
- **GitOps:** see CI/CD + policy, promotion interaction (ignoreDifferences now, git commit on EKS).
- **Rollback:** `mlops-promote rollback` re-points `@champion` to `@previous` and
  redeploys.

### Model monitoring: `mlops-monitor`
- **What it is:** an image run as a tenant CronJob from `components/model-monitor`
  (daily by default).
- **Generic part:** joins `predictions` ↔ `feedback` over a window and runs
  Evidently (version pinned here, once, for all tenants; its API changed
  significantly in 0.7) for score drift and input drift against a reference window.
  Results go to `monitoring_results(run_ts, model_version, window, metric, value, details jsonb)`.
- **Tenant plugin:** `MLOPS_MONITOR_METRICS=pkg.module:fn`, with signature
  `fn(predictions_df, feedback_df) -> dict[str, float]`, for domain metrics (e.g.
  recsys Recall/NDCG@K). Shipped in a tenant image `FROM mlops-monitor`.
- **Grafana:** a platform "Model overview" dashboard templated on namespace and model
  (MLServer latency and error rate, prediction volume by version, drift, plugin
  metrics). Tenants add domain dashboards.
- **Alerts (P1 alerting):** drift over threshold, monitor CronJob
  failed, logsink drops > 0, InferenceService not Ready.

### Batch inference: `components/batch-inference`
- **Job/CronJob** using the tenant runtime image (`FROM mlops-mlflow`). It loads
  **the same artifacts the InferenceService serves** (read from its `storageUri`
  and `mlops.io/model-version` annotation), so batch and online always match the
  current champion.
- **Input:** a parquet of entity ids/inputs in `s3://<tenant>-data/batch/input/`.
  **Output:** `s3://<tenant>-data/batch/<model>/<version>/<date>/` (partitioned
  parquet), plus optionally a `batch_predictions` Postgres table for low-latency
  lookup.
- Every row carries `model_version` and `scored_at`. The Job processes inputs in
  chunks, is resumable by chunk, and logs a summary run to MLflow.
- Goes through a Kueue LocalQueue once P4 exists.

## 6b. Feature store: Feast
**Why:** consistent features for training (point-in-time joins, no leakage, which
matters with the time split) and serving (low-latency online lookups), defined
once.

- **Registry:** SQL registry in Postgres, a `feast` schema in each tenant's DB. No
  file registry: `local-path` is RWO only, which is the same constraint the old
  attempt hit.
- **Offline store:** parquet on MinIO (`s3://<tenant>-data/features/`), via the file
  offline store with DuckDB for joins. Postgres offline store is the fallback if
  DuckDB + S3 misbehaves (verify for the pinned version).
- **Online store:** one shared **Redis** (platform namespace, pinned, persistence
  off locally), with tenant isolation through the Feast project = tenant name plus a
  Redis ACL user per tenant (key prefix). On EKS: ElastiCache.
- **Tenant onboarding:** `make tenant` renders `feature_store.yaml` from the tenant's
  Secrets into Secret `feast`. That fixes the old plaintext-password-in-ConfigMap
  gap.
- **Materialisation:** component `components/feast-materialize`, a CronJob running
  `feast materialize-incremental` with the tenant's feature repo image. `feast apply`
  runs in tenant CI/Make, not in the platform.
- **Online reads:** tenant code calls the Feast SDK against Redis directly (front
  service or KServe transformer). The Feast feature server and UI are optional
  (~0.3 GB) and off by default.
- **Monitoring hook:** `mlops-monitor` can compare online feature distributions
  against offline ones (training/serving skew) for tenants that declare a feature
  service.

## 6c. Golden path (tenant template + docs)
The platform's user-facing product. A data scientist should go from an empty repo to
a deployed, gated, monitored model by following one doc.
- **Template `templates/tenant/`** (copier or cookiecutter, versioned with the
  platform):
  - `src/<pkg>/{train.py, evaluate.py, bundle.py}` (a pyfunc skeleton with
    `load_context` checks and the contract output fields);
  - a `train` CLI with MLflow logging of the required tags;
  - `promotion.yaml` with commented defaults;
  - `docker/{runtime,train,monitor}.Dockerfile` (`FROM` the platform images);
  - `k8s/` with the platform components already included;
  - a Makefile (`env, train, register, promote, rollback, deploy`);
  - CI (lint, tests, kubeconform, kyverno, Trivy) and pre-commit.
- **Extraction:** from recsys-lite + house-price once both run. Both are then
  realigned to the generated layout, which is the test that the template works.
- **Docs `docs/golden-path.md`:** onboarding (`make tenant`), first model, first
  promotion, reading the dashboards, rollback, troubleshooting. Plus
  `docs/contract.md`.
- **Acceptance:** a fresh tenant generated from the template (a "hello-model",
  e.g. sklearn iris) reaches `@champion` serving behind KServe in **≤ 1 session**,
  touching no platform code.

## 6d. Platform acceptance tests: `make platform-test`
End-to-end checks run against a live cluster, after every phase and in a nightly
CI job (once there's a runner with cluster access). They use the recsys-lite bad
model fixtures (recsys-PRD §4) plus house-price:

| Test | Expects |
|---|---|
| Good challenger (ALS over popularity) | Promoted, InferenceService Ready, `@previous` set, prediction logged |
| `broken-bundle` | Promote `load` check fails; never Ready if forced |
| `regressed` | Gate rejects; reasons tagged on the version |
| `slow` | Latency check fails |
| `ready-fail` | Deploy attempted → not Ready → aliases + `storageUri` auto-revert |
| `drifting` replay | Drift result over threshold → alert fires |
| Rollback | `@champion` ← `@previous`; serving switches version |
| Tenant isolation | recsys pod can't read house-price buckets/DB; NetworkPolicy deny holds |
| Restore drill | `make restore` into a fresh cluster brings MLflow + the registry back |
| Policy | A `:latest` image / missing limits manifest is rejected (once Kyverno is Enforce) |

A phase isn't "done" until its relevant tests pass.

## 7. RAM budget (local, platform only)
| Component | Est. |
|---|---|
| kind node / control plane | 1.0 GB |
| Traefik | 0.1 GB |
| Postgres | 0.4 GB |
| MinIO | 0.3 GB |
| MLflow | 0.4 GB |
| kube-prometheus-stack | 1.8 GB |
| Loki + Alloy | 0.6 GB |
| Keycloak | 0.8 GB |
| cert-manager + KServe controller | 0.4 GB |
| Redis (Feast online) | 0.15 GB |
| Alertmanager | 0.05 GB |
| ArgoCD (core) | 0.4 GB |
| Kyverno | 0.3 GB |
| Jupyter (optional) | 0.5–1 GB |
| **Platform total** | **~6.8 GB** (~7.8 with Jupyter) |

Backup and batch Jobs are transient. That leaves ~5–6 GB of the 12 GB budget for tenants. Per InferenceService, MLServer is ~0.5–0.8 GB.

## 8. Phases
Each phase lists which recsys steps it unblocks (see `recsys-PRD.md`).

| Phase | Scope | Unblocks recsys |
|---|---|---|
| **P0 core** | Resolve §5; merge `feat/terraform-eks`; kind + registry + Traefik + `overlays/kind`; MLflow 3.x (custom image, proxied artifacts); Postgres generalised; MinIO pinned; `make tenant` incl. **NetworkPolicies** (enforcement verified); `docs/contract.md`; `.env.secrets.example` | recsys 1–2 (data, training, registry) |
| **P1 observability + ops** | kube-prometheus-stack, Loki, Alloy, datasources, dashboard sidecar; **alerting** (Alertmanager + platform rules); **backups** + first restore drill | recsys 5 (metrics, alerts, monitoring) |
| **P2 identity** | Keycloak + realm + per-tenant client | recsys 8 (JWT auth) |
| **P3 CI/CD + policy** | CI (kubeconform, kyverno CLI, Trivy); ArgoCD app-of-apps + `make bootstrap`; per-tenant AppProject/Application; Kyverno validate/generate/mutate in Audit → Enforce; NetworkPolicy/LimitRange moved to Kyverno generate | recsys deploys via git from here on |
| **EKS track** (parallel, existing) | Finish Terraform: EBS CSI addon + IRSA, then switch to `terraform-aws-modules/eks`; AWS LB Controller; IRSA for MinIO→S3; ESO; the same ArgoCD + Kyverno config (new overlay only) | Tenant runs on EKS unchanged |
| **H1 house-price tenant** (right after recsys's first deploy) | Port the house-price model (asdyns/e2e-mlops) as a tenant using only `make tenant`, L1–L2 and its own pyfunc/policy, with **no changes to L1–L3** | Proves the platform is generic; anything that had to change is fixed in the platform |
| **T1 acceptance tests** (with L2, extended each phase) | `make platform-test` (§6d) using the recsys-lite fixtures | Every later phase is gated on it |
| **G1 golden path** (after H1 + L3) | Tenant template, `docs/golden-path.md`, hello-model acceptance | Realign recsys + house-price to the template |
| **L1 serving** (alongside recsys step 3) | cert-manager + KServe RawDeployment, `mlops-mlflow` runtime, `components/model-service`, `mlops-logsink` | recsys 3 (deploy) |
| **L2 promotion** (alongside recsys step 3) | `mlops-promote` (artifact copy → storageUri patch → Ready, auto-revert), `promotion.yaml` schema, RBAC, rollback | recsys 3, 4, 9 |
| **L3 monitoring** (after P1, alongside recsys step 5) | `mlops-monitor`, `components/model-monitor`, Model overview dashboard | recsys 5 |
| **L4 batch inference** (after L2) | `components/batch-inference` | recsys 7 (nightly top-K vs. online) |
| **F1 feature store** (alongside recsys step 6) | Redis, the Feast registry schema in `make tenant`, the `feast` Secret, `components/feast-materialize` | recsys 6 (`movie_stats`: as-of-T training, online fallback) |
| **P4 queueing + Ray** (optional, after P1) | **Kueue**: ClusterQueue + a LocalQueue per tenant, created by `make tenant`; CPU/memory quotas. **KubeRay** operator (~0.3 GB; each RayCluster ~2–4 GB, so run it on demand). Both work on CPU kind and carry over unchanged to EKS | Step 9 retraining Jobs go through Kueue; optional Ray Tune HPO for ALS |

### Estimates, time-boxes and critical path (added 2026-11-16)
Unit = one ~3 h session. Estimates are rough; the time-box is the hard limit.

| Phase | Estimate | Time-box (stop at) |
|---|---|---|
| P0 core | 3–5 | 7 |
| L1 serving (KServe) | 3–4 | 6 |
| L2 promotion | 2–3 | 4 |
| P1 observability + ops | 3–4 | 6 |
| L3 monitoring | 2 | 3 |
| P3 CI/CD + policy | 3–5 | 7 |
| F1 feature store | 2–3 | 4 |
| P2 identity | 2 | 3 |
| L4 batch inference | 1 | 2 |
| H1 house-price tenant | 1–2 | 3 |
| T1 acceptance tests | 1–2 | 3 |
| G1 golden path | 2–3 | 4 |
| **Platform total** | **~25–36** | |
| recsys-lite tenant (steps 0–9) | 4–6 | per step: 2× the step's first estimate |

**Critical path:** P0 → recsys-lite steps 0–2 → L1 + L2 → recsys step 3 (deploy +
gated promotion) → H1 + T1 (gates proven to reject). That gives a multi-tenant,
deployed, gated platform in about **8–10 sessions**. After that, each phase is
pulled in when a reference tenant needs it:
- P1 + L3 → recsys step 5
- F1 → step 6
- L4 → step 7
- P3 once manual deploys hurt
- G1 once both tenants run
- P2 last
- P4 optional

**Time-box rule:** if a phase reaches 1.5× its upper estimate, stop and cut scope
(drop to the minimal version that unblocks the next recsys step, and record the
remainder under Deferred) rather than pushing on. Same rule as the Terraform track.
Log actual sessions per phase in this table as they complete.

## 9. Deferred
Local TLS issuance (cert-manager is already installed for KServe), tracing, Argo
Workflows, multi-node kind. The Gateway API migration and a service mesh are one
decision; see Istio below.

**Later (each has a trigger; not scheduled):**
| Item | Trigger | Shape when started |
|---|---|---|
| **LLMOps** | The "AI childcare" LLM tenant starts. Comes *before* anything in `scale-track.md` | MLflow 3 prompt registry + GenAI evaluation (eval sets, LLM-judge, gate rules in `promotion.yaml`); tracing via MLflow Tracing / OpenTelemetry → the `mlops-logsink` pattern; guardrails; token-cost metrics per request; serving via an external API first, vLLM on KServe later |
| **Lineage** | More than one dataset or pipeline feeds a model, or an audit question can't be answered from MLflow | Today's lightweight lineage (`mlflow.log_input` with URI + hash, git SHA, `storageUri` per version) stays. Add OpenLineage events → Marquez only if needed |
| **Service mesh (Istio)** | (a) online A/B or canary between champion and challenger is needed (KServe serverless mode / traffic split), or (b) **mTLS / zero-trust is required, which is likely for childcare data on EKS**, or (c) per-request authn at the mesh replaces app JWT code | **Istio ambient mode** (ztunnel; waypoints only where L7 policy is needed); `PeerAuthentication` STRICT mTLS per tenant namespace; `RequestAuthentication` + `AuthorizationPolicy` for Keycloak JWTs (could remove the JWT code in tenant fronts); combined with the **Gateway API migration** (Istio implements it), retiring Traefik. Compare Linkerd and Cilium first. Budget ~1 GB ambient (sidecar mode ~1–2 GB) |
| **Cost attribution** | EKS running continuously, or a second paying workload | OpenCost by namespace (tenancy already gives one namespace per tenant), AWS cost allocation tags matching the tenant labels; per-model cost per 1k predictions on the Model overview dashboard |

**Scale track** (GPU operator, Karpenter GPU pools, distributed training, vLLM/LLM
routing, disaggregated serving): parked in `scale-track.md`, with entry criteria.
Don't pull any of it into P0–P4.
