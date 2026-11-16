# MLOps Platform

A self-hosted, multi-tenant MLOps platform on Kubernetes. It runs locally on one
laptop and is portable to EKS by swapping overlays and infra only. Data scientists
plug models in as **tenants** through a fixed [contract](docs/platform-PRD.md#3-tenant-contract-the-interface-keep-stable):
track and register in MLflow, pass a promotion gate, serve on KServe, and get
logging, monitoring and alerts for free.

## Status
| | Today (v0) | Target |
|---|---|---|
| Cluster | k3s, single `mlops` namespace | kind + local registry; tenant namespaces via `make tenant` |
| Platform | MLflow 2.11 (Postgres + MinIO), Jupyter, dashboard | MLflow 3.x, KServe, Feast, `mlops-promote` / `-logsink` / `-monitor`, Prometheus/Loki/Alertmanager, Keycloak, ArgoCD, Kyverno |
| EKS | Terraform cluster build (applied/destroyed per session), EBS StorageClass overlay | Same platform via `overlays/eks` + IRSA, LB controller, ESO |

## Docs
| Doc | What |
|---|---|
| [`docs/platform-PRD.md`](docs/platform-PRD.md) | Platform design, contract, phases, estimates, time-box rule |
| [`docs/recsys-PRD.md`](docs/recsys-PRD.md) | recsys-lite: reference tenant + bad-model fixtures for acceptance tests |
| [`docs/architecture.md`](docs/architecture.md) | Target architecture + model lifecycle diagrams; current v0 diagram, RBAC, k3s notes |
| [`docs/scale-track.md`](docs/scale-track.md) | Parked GPU / distributed training / LLM serving track (entry criteria) |

## Tracking
- Board: [mlops-platform roadmap](https://github.com/users/asdyns/projects/3)
- Overview: [Roadmap #55](https://github.com/asdyns/mlops-platform/issues/55)
- Milestones: M1 Critical path → M2 Operable → M3 Delivery & policy → M4 Golden path → M5 Extras, plus EKS and Later
- Next up: [#4](https://github.com/asdyns/mlops-platform/issues/4) (open decisions), then [#5](https://github.com/asdyns/mlops-platform/issues/5) (kind cluster)

## Layout
```
base/                  cloud-agnostic Kustomize (namespace, mlflow-db, mlflow, minio, jupyter, dashboard)
base/config, secrets/  env files for configMapGenerator / secretGenerator (secrets untracked)
overlays/local/        k3s: StorageClass + ingressClass patches   (→ overlays/kind in P0)
overlays/eks/          EKS: ebs-gp3 StorageClass (ingress pending)
terraform-bootstrap/   one-off S3 + DynamoDB remote-state backend (local state, keep it)
terraform/             hand-rolled EKS: modules/eks-platform + environments/dev
docs/                  PRDs, architecture, scale track
```
Planned (see PRD): `components/` (model-service, model-monitor, batch-inference,
feast-materialize), `templates/tenant/`, `argocd/`, `policies/`.

## Quick start (v0, k3s)
```bash
cp base/secrets/.env.secrets.example base/secrets/.env.secrets   # example lands in P0; until then create it by hand
kubectl apply -k overlays/local/
```
Hosts `mlops.local`, `mlflow.local`, `jupyter.local`, `minio(-console).local` via
`/etc/hosts` → Traefik. P0 (#5, #6) moves this to kind and `*.localtest.me`, with no
`/etc/hosts` edits. k3s troubleshooting: [`docs/architecture.md`](docs/architecture.md#k3s-troubleshooting-v0).

## EKS (Terraform)
```bash
cd terraform/environments/dev && terraform init && terraform plan && terraform apply   # destroy after each session
```
Built so far: VPC, cluster/node IAM roles, cluster (API auth mode), OIDC, node group,
and access entries. Next: EBS CSI addon + IRSA, then `terraform-aws-modules/eks`
(#48).
