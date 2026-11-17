# Architecture

## Target architecture
The design is in [`platform-PRD.md`](platform-PRD.md). Tenants touch the platform only
through the contract (§3): Secrets, Kustomize components, labels and policy files.

```mermaid
flowchart TB
    ds(["Data scientist<br/>train CLI on laptop"])
    client(["API client"])

    subgraph platform["Platform namespaces"]
        ing["Traefik ingress<br/>*.localtest.me"]
        reg["Registry<br/>localhost:5001"]
        mlflow["MLflow 3.x<br/>tracking + registry"]
        pg[("Postgres<br/>mlflow + tenant DBs")]
        minio[("MinIO<br/>mlflow + tenant buckets")]
        redis[("Redis<br/>Feast online store")]
        kserve["KServe controller<br/>runtime mlops-mlflow"]
        obs["Prometheus · Grafana<br/>Loki · Alertmanager"]
        kc["Keycloak"]
        argo["ArgoCD"]
        kyv["Kyverno"]
    end

    subgraph tenant["Tenant namespace, e.g. recsys (created by make tenant)"]
        front["Tenant front API<br/>JWT, domain routes"]
        isvc["InferenceService<br/>MLServer + pyfunc"]
        sink["mlops-logsink"]
        promote["mlops-promote Job"]
        mon["mlops-monitor CronJob"]
        batch["batch-inference Job"]
        feastm["feast-materialize CronJob"]
    end

    ds -- "log runs, register @challenger" --> mlflow
    mlflow --> pg
    mlflow -- "proxied artifacts" --> minio
    client --> ing --> front -- "V2 infer" --> isvc
    front -. "JWKS" .-> kc
    isvc -- "payload logger" --> sink --> pg
    isvc -. "online features" .-> redis
    feastm --> redis
    promote -- "gate, move aliases" --> mlflow
    promote -- "copy artifacts" --> minio
    promote -- "patch storageUri" --> isvc
    isvc -. "storage initializer" .-> minio
    batch -. "same artifacts" .-> minio
    mon -- "predictions ⋈ feedback" --> pg
    kserve -. "reconciles" .-> isvc
    obs -. "scrape, logs, alerts" .-> tenant
    argo -. "sync from git" .-> tenant
    kyv -. "admission policy" .-> tenant
    reg -. "images" .-> tenant
```

### Model lifecycle
```mermaid
sequenceDiagram
    autonumber
    actor DS as Data scientist
    participant ML as MLflow
    participant PR as mlops-promote
    participant S3 as MinIO (tenant bucket)
    participant KS as KServe InferenceService
    participant LS as mlops-logsink
    participant MO as mlops-monitor
    DS->>ML: train CLI logs run + tags, registers @challenger
    DS->>PR: make promote (promotion.yaml)
    PR->>ML: compare @challenger vs @champion (rules)
    PR->>PR: checks: load_context, latency p95
    alt gate fails
        PR->>ML: tag reasons, exit non-zero
    else gate passes
        PR->>ML: @previous ← champion, @champion ← challenger
        PR->>S3: copy version artifacts
        PR->>KS: patch storageUri, wait Ready
        alt not Ready
            PR->>ML: revert aliases
            PR->>KS: revert storageUri
        end
    end
    KS-->>LS: request/response events
    LS->>LS: write predictions / feedback
    MO->>LS: daily: join predictions ⋈ feedback, drift + tenant metrics
    MO-->>DS: Grafana panels, alerts → retrain → back to step 1
```

Phases and what each one builds: [`platform-PRD.md` §8](platform-PRD.md#8-phases).
Work tracking: [project board](https://github.com/users/asdyns/projects/3).

## Local cluster layout (kind, #5)
The local platform runs as a kind cluster. kind runs each Kubernetes node as a
Docker container, so there are two networks to think about: the Docker host
ports you reach from your laptop, and the Kubernetes network inside the node.
A separate registry container holds the images you build locally.

Ports:

| Where | Port | Meaning |
|---|---|---|
| host `127.0.0.1:5001` | → `kind-registry:5000` | `docker push localhost:5001/...` from your shell |
| host `:80` / `:443` | → node `:80` / `:443` | web traffic into the cluster (Traefik, #6) |
| host random localhost port | → node `:6443` | Kubernetes API (`kubectl`), written to `~/.kube/config` |
| `kind-registry:5000` | Docker network `kind` | how containerd on the node pulls images |

```mermaid
flowchart TB
    user(["You / Browser"])
    cli["docker push localhost:5001/x\n(your shell)"]

    subgraph host["Host laptop"]
        backups[("~/mlops-backups")]

        subgraph dockerNet["Docker network: kind"]
            reg["container kind-registry\nregistry:2.8.3\nlistens :5000\npublished 127.0.0.1:5001"]

            subgraph node["container mlops-control-plane (kind node)\nKubernetes v1.34.11"]
                hosts["containerd\n/etc/containerd/certs.d/localhost:5001/hosts.toml\nlocalhost:5001 → http://kind-registry:5000"]
                api["kube-apiserver :6443"]
                ing["Traefik :80 / :443\n(added in #6)"]
                pods["Pods"]
                nodeBackups[("/backups")]
            end
        end
    end

    cli -- "host :5001 → :5000" --> reg
    user -- "host :80 / :443\n(Docker port mapping)" --> ing
    ing --> pods
    hosts -- "image pull over\nDocker network" --> reg
    pods -. "image: localhost:5001/x" .-> hosts
    backups <-- "bind mount\nextraMounts" --> nodeBackups
```

## Current state (v0, k3s)
All components run in the `mlops` Kubernetes namespace, deployed via Kustomize
from `base/`. `base/` itself is cloud-agnostic: the `local-path-retain`
StorageClass and `ingressClassName: traefik` shown below are not defined in
`base/` — they're supplied by the `overlays/local` overlay via a Kustomize
patch, so the same `base/` can later be paired with an `overlays/eks/` that
patches in `gp3`/`alb` instead.

```mermaid
flowchart LR
    subgraph ns["Kubernetes namespace: mlops"]
        subgraph jup["jupyter (Deployment)"]
            jupC["notebook\njupyter/minimal-notebook"]
        end
        jupPVC[("jupyter-pvc\n5Gi")]
        jupSvc["jupyter-service\nClusterIP 8888"]

        subgraph mlf["mlflow (Deployment)"]
            mlfC["mlflow\nghcr.io/mlflow/mlflow:v2.11.3\n:5000"]
        end
        mlfSvc["mlflow-service\nClusterIP 5000"]

        subgraph db["mlflow-db (StatefulSet)"]
            dbC["postgres:15\n:5432"]
        end
        dbPVC[("mlflow-db-pvc\n5Gi")]
        dbSvc["mlflow-db-service\nClusterIP 5432"]

        subgraph mio["minio (StatefulSet)"]
            mioC["minio/minio\nS3 API :9000 · Console :9001"]
        end
        mioPVC[("minio-pvc\n10Gi")]
        mioSvc["minio-service\nClusterIP 9000/9001"]

        subgraph dash["dashboard (Deployment)"]
            dashC["nginx:alpine\n:80"]
        end
        dashSvc["dashboard-service\nClusterIP 80"]
        dashCm["ConfigMap\ndashboard-html\n(generated from index.html)"]

        sc["StorageClass\nlocal-path-retain\n(from overlays/local)"]

        cm["ConfigMap\nplatform-config\n(config/.env.config)"]
        sec["Secret\nplatform-secrets\n(secrets/.env.secrets)"]

        jupIng["Ingress\njupyter-ingress\njupyter.local"]
        mlfIng["Ingress\nmlflow-ingress\nmlflow.local"]
        mioIng["Ingress\nminio-ingress\nminio.local\nminio-console.local"]
        dashIng["Ingress\ndashboard-ingress\nmlops.local"]
    end

    user(["User / Browser"])

    user -- "mlops.local" --> dashIng --> dashSvc
    user -- "jupyter.local" --> jupIng --> jupSvc
    user -- "mlflow.local" --> mlfIng --> mlfSvc
    user -- "minio(-console).local" --> mioIng --> mioSvc

    dashSvc --> dashC
    dashCm -. "index.html" .-> dashC
    dashC -. "links to" .-> jupIng & mlfIng & mioIng

    jupSvc --> jupC
    mlfSvc --> mlfC
    mioSvc --> mioC

    jupC -- "logs runs\n(mlflow SDK)" --> mlfSvc

    mlfC -- "backend-store-uri\npostgresql://mlflow_user@...:5432/mlflow" --> dbSvc --> dbC
    mlfC -- "default-artifact-root\ns3://mlflow/ via MLFLOW_S3_ENDPOINT_URL" --> mioSvc --> mioC

    jupC -.-> jupPVC
    dbC -.-> dbPVC
    mioC -.-> mioPVC
    jupPVC & dbPVC & mioPVC -.-> sc

    cm -. "env" .-> mlfC & dbC
    sec -. "env" .-> jupC & mlfC & dbC & mioC
```

### Flow

- **Dashboard** is the entry point (`mlops.local`) — a static nginx page with
  links out to MLflow, Jupyter, and the MinIO console. Its HTML is generated
  into the `dashboard-html` ConfigMap by Kustomize's `configMapGenerator`
  from `base/dashboard/index.html`, so the page content lives in git as a
  plain file rather than embedded YAML; editing it produces a new ConfigMap
  hash and rolls the Deployment.
- **Jupyter** is where experiments run; it uses the MLflow SDK to log runs to
  the tracking server.
- **MLflow** persists run/experiment metadata to **Postgres** (`mlflow-db`)
  and writes artifacts (models, files) to **MinIO** over the S3 API.
- All stateful components (`jupyter`, `mlflow-db`, `minio`) mount PVCs backed
  by the `local-path-retain` StorageClass, so data survives pod restarts.
  `storageClassName` isn't set on the PVCs in `base/` — it's patched in by
  `overlays/local` (see note above), keeping the PVC definitions portable.
- Everything user-facing sits behind a Traefik `Ingress` on a `*.local`
  hostname (`mlops.local`, `jupyter.local`, `mlflow.local`,
  `minio.local`/`minio-console.local`); the Services themselves are
  `ClusterIP`-only, same as the internal-only `mlflow-db`. `NodePort` is
  commented out in each `service.yaml` rather than removed, in case ingress
  needs to be bypassed. `ingressClassName: traefik` is likewise patched in by
  `overlays/local` for most Ingresses (`dashboard-ingress` currently still
  hardcodes it in `base/` — a known inconsistency, see README known gaps).
- Non-sensitive settings (DB name, MinIO endpoint URL, TLS flag, `PYTHONPATH`)
  come from the `platform-config` ConfigMap; credentials (Postgres user/pass,
  MinIO root user/pass, Jupyter token) come from the `platform-secrets`
  Secret. Both are generated by Kustomize from `base/config/.env.config` and
  `base/secrets/.env.secrets`, and injected into containers via
  `configMapKeyRef`/`secretKeyRef` — no plaintext values live in the
  Deployment/StatefulSet specs.
- Not shown in the diagram above (omitted to keep it focused on traffic/data
  flow): every pod runs under its own dedicated `ServiceAccount` rather than
  the namespace's `default`. Only `jupyter`'s has its token automounted, and
  only `jupyter` has any RBAC grant at all — a namespace-scoped `Role`/
  `RoleBinding` giving read-only access to `pods`. See the README's RBAC
  section for the full rationale.

### RBAC
Every workload runs under its own dedicated `ServiceAccount` — none of them use
the namespace's `default` ServiceAccount, which is intentionally left unbound
so it can never become an accidental shared grant. `automountServiceAccountToken`
is `false` on all of them except `jupyter`, since none of the others make calls
to the Kubernetes API.

`jupyter`'s ServiceAccount is bound (via a `Role` + `RoleBinding`, both scoped to
the `mlops` namespace) to read-only access on `pods` — `get`/`list`/`watch` only,
nothing else. This is deliberately minimal for now; a `Role` covering `batch/v1`
Jobs will be added once notebooks start kicking off training runs as Kubernetes
Jobs.

This per-app ServiceAccount split isn't just isolation for its own sake — it
maps directly onto AWS IRSA (IAM Roles for Service Accounts), which annotates
individual ServiceAccounts to assume individual IAM roles. Keeping each
workload on its own identity now means `overlays/eks/` can add IRSA annotations
to existing ServiceAccounts rather than needing to first split workloads that
share one.

### k3s troubleshooting (v0)
**Ingress returns 502 Bad Gateway on every `*.local` host.** Most likely your
machine's IP has changed (DHCP lease renewal) since the `*.local` entries were
added to `/etc/hosts`. Check the two things below, in order:

1. Confirm Traefik's current address and match `/etc/hosts` to it:
   ```
   kubectl get svc -n kube-system traefik   # note the EXTERNAL-IP
   ```
   Update each `*.local` line in `/etc/hosts` to that IP.
2. If ingress still 502s after that, the IP change may have also broken k3s's
   internal pod-network routing (Traefik unable to reach the API server's
   ClusterIP) — check `kubectl logs -n kube-system -l app.kubernetes.io/name=traefik`
   for `no route to host` errors. Fix with a clean k3s restart (plain
   `systemctl restart k3s` can leave orphaned `containerd-shim` processes behind):
   ```
   sudo /usr/local/bin/k3s-killall.sh
   sudo systemctl start k3s
   ```
   Give it 30-60s, then recheck `kubectl get nodes` and `kubectl get pods -n mlops`.
