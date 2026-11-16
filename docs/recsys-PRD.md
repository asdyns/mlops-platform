# PRD: recsys-lite (reference tenant of mlops-platform)

Status: v5 (2026-11-16). Rewritten as a *reference tenant*: the platform is the
product, and this tenant exists to exercise every platform path. Current step:
**0, blocked on platform P0**. Location: `mlops-platform/docs/recsys-PRD.md` for now;
move to `recsys/docs/PRD.md` once that repo exists. Platform side:
`platform-PRD.md` (contract §3, lifecycle services §6a, golden path §6c, acceptance
tests §6d).

## 0. Context for a new session (read first)
**Who:** principal engineer with a strong platform/K8s/MLOps background. **The main
focus is building the platform.** Real models will be built by the platform's users
(data scientists). This tenant is deliberately cheap: cheap to train, but **not
trivial**, because promotion, drift and rollback are only proven if some models fail.

Preferences: direct answers, concrete numbers, minimal complexity, no repeated
caveats, explicit pushback when a proposal is wrong. Show YAML inline; break steps
into sub-steps; engage with the user's guesses; verify version-dependent claims
before asserting them.

**Bigger picture:** the real end goal is an "AI childcare" product on EKS, and time is
limited. Flag work that costs more than it teaches.

**Repo:** new, at `~/Documents/work/code/30-ml-eng/recsys` (not created yet; ask
before creating a GitHub repo under `asdyns`). Built by hand first (steps 0–5); it's
then the first draft the platform's golden-path template (platform §6c) is extracted
from, and gets realigned to it.

**Platform usage, contract only:**
- **Secrets / ConfigMaps:** `mlflow`, `s3`, `s3-models`, `postgres`, `feast`;
  `platform-auth`.
- **Networking and telemetry:** an Ingress with no class; scrape labels; JSON logs
  with `app` and `model_version`; images pushed to `localhost:5001/recsys/...`.
- **Lifecycle services:** KServe + `mlops-logsink`, `mlops-promote`,
  `mlops-monitor`, batch inference, and Feast.
- **Delivery:** ArgoCD AppProject `recsys`; Kyverno policies.

If recsys needs something the platform can't do, change the platform (generically).
Never work around it in the tenant.

## 1. Goal
A small but real recommender that drives every platform path end to end: data
versioning, tracking, registry, gated promotion (pass *and* reject), KServe serving,
prediction logging, replayed traffic, drift monitoring, alerting, batch scoring,
feature store, GitOps deploy, auth, and a retraining loop. It also serves as the
reference and template for real tenants.

**Non-goals:** model quality beyond "ALS clearly beats popularity"; two-tower,
FAISS, the LightGBM ranker (these are data-scientist work, see §13); GPU; online
A/B.

## 2. Data
- **Primary:** MovieLens `ml-latest-small` (100,836 ratings, 610 users, 9,742
  movies). Everything trains in seconds to minutes on CPU.
- **Scale test, once:** MovieLens 32M (~32M ratings, ~201k users, ~87.6k movies) to
  load-test serving, batch, the training quota and the logsink. It isn't used for
  modelling.
- **Feedback:** implicit, rating >= 4 is a positive.
- **Time-based split, never random:** timestamp quantiles train 80% / val 10% /
  replay 10%.
- **Eval population:** users with ≥1 positive in the window, warm vs. cold reported
  separately, already-seen items excluded.
- **Versioning:** parquet in MinIO at `s3://recsys-data/<dataset>/<split_id>/`
  (immutable prefix). Each run calls `mlflow.log_input` with the URI and content hash,
  and tags split T.
- **Schema check on load:** pandera or asserts.

## 3. Models (two, on purpose)
1. **Popularity:** global plus recency-weighted (last 30 days before T). It's the
   first `@champion`.
2. **ALS** via `implicit` (factors=64, ~15 iterations, ml-small trains in < 1 min).
   It's the first real `@challenger` and should beat popularity comfortably on
   Recall@20.

**Metrics:** Recall@20, NDCG@20, catalogue coverage, popularity bias (mean
log-popularity of recommendations vs. train).

## 4. Deliberately bad models (platform acceptance fixtures)
Built by `make bad-models`, registered as challengers with tag `fixture=<name>`. The
platform's `make platform-test` (platform §6d) uses them.

| Fixture | Defect | Must result in |
|---|---|---|
| `broken-bundle` | `item_map` length ≠ factor rows | Promote Job `load` check fails; if forced onto KServe, it never becomes Ready |
| `regressed` | ALS trained on 10% of the data | Gate rejects (Recall@20 < champion × 1.02); reasons tagged on the version |
| `slow` | `predict()` sleeps 50 ms | Latency check fails (p95 > 30 ms) |
| `ready-fail` | Passes the gate but `load_context` raises only in-cluster (env-dependent) | `mlops-promote` deploys, the InferenceService isn't Ready, **aliases and `storageUri` auto-revert** |
| `drifting` | Normal model; the replayer serves a shifted window (users and items from late periods only) | `mlops-monitor` drift metric over threshold → alert fires |

## 5. Features (Feast, minimal but real)
- **Entities:** `user`, `movie`. Event timestamp = rating timestamp.
- **`movie_stats` feature view:** `pop_7d`, `pop_30d`, `n_ratings`, `mean_rating`.
  - **Training:** the popularity model builds its ranking with
    `get_historical_features` *as of T*. That's a real point-in-time join with no
    future leakage.
  - **Serving:** the fallback for unknown users reads `pop_7d` from the online store
    (Redis). Only the fallback needs Redis, so the ALS path stays hermetic.
- **Replay:** the replayer advances a simulated clock and runs
  `feast materialize-incremental <sim_now>` per simulated day.
- **Repo:** `features/` is a Feast repo; `make features` runs `feast apply`.

## 6. Code layout and execution
- **Environment:** `uv`, **Python 3.12** pinned (system Python is 3.14).
- **Notebooks:** exploration only, importing from `src/`.
- **Training: a CLI, not a notebook.**
  `python -m recsys.train --config configs/<x>.yaml`
  - **On the host:** steps 1–8, against platform MLflow
    (`MLFLOW_TRACKING_URI=http://mlflow.localtest.me`). MinIO credentials are exported
    from the tenant Secret to a gitignored `.env` by `make env`.
  - **In-cluster Job `recsys-train`:** step 9, required for the retraining loop.
    Same image and entrypoint. Fits the default 4 CPU / 4 Gi quota for ml-small; the
    one-off 32M run uses the tenant `training` quota.
- **Reproducibility:** seeds in config; git SHA, config and dataset hash logged on
  every run.

```
recsys/
  notebooks/
  src/recsys/{data.py, features.py, models/{popularity,als}.py,
              train.py, evaluate.py,
              bundle.py,          # pyfunc: predict(), checks in load_context()
              bad_models.py,      # §4 fixtures
              monitoring.py}      # metrics plugin for mlops-monitor
  api/{app.py, auth.py}           # recsys-api front: /recommend, /feedback, JWT
  features/                       # Feast repo
  promotion.yaml
  docker/{runtime,train,monitor,api}.Dockerfile   # FROM mlops-mlflow / mlops-monitor; api slim
  replay/replayer.py
  k8s/{base, overlays/local}      # platform components via pinned remote refs + patches
  dashboards/*.json
  configs/*.yaml
  tests/{unit, bundle, api}
  Makefile                        # env, data, train, evaluate, bundle, register, promote,
                                  # rollback, bad-models, features, replay, deploy
```

## 7. Registry and promotion policy
- **Model and aliases:** registered model `recsys`. New versions get `@challenger`;
  the platform manages `@champion` and `@previous`.
- **Every version logs:** the platform tags (`git_sha`, `dataset_hash`, `config`)
  plus `split_t`, `model_type`; metrics `val_recall_at_20`, `val_ndcg_at_20`,
  `catalogue_coverage`, `popularity_bias`; artifacts `model_card.md` and
  `latency_inputs.json` (1,000 sampled users).
- **`promotion.yaml`:**
  - Recall@20 ≥ champion × 1.02
  - NDCG@20 ≥ champion × 1.00
  - coverage ≥ champion × 0.90
  - `load` must pass
  - latency p95 < 30 ms over 1,000 users
  - on pass, deploy `inferenceservice/recsys`
- **Running it:** `make promote` and `make rollback` call `mlops-promote`.

## 8. Serving bundle (pyfunc)
**Contents:** user factors, item factors, ID maps, the seen-items index, and a
popularity snapshot (used if Redis is unreachable). Retrieval is a numpy dot product
over ~9.7k items (ml-small), sub-millisecond. **No FAISS.**

- **`load_context()` checks** (raise on failure, so a bad bundle is never Ready and
  fails promote `load`):
  - `manifest.json` sha256 of each component matches
  - `len(item_map) == item_factors.shape[0]`
  - `user_factors.shape[1] == item_factors.shape[1]`
  - golden query: 20 fixed users give identical top-20 to the training-time snapshot
- **`predict()`:**
  - known user: factors · item_factors → seen-filter → top-k
  - unknown user: Feast `pop_7d` → top-k (snapshot fallback if Redis fails)

  Output: `item_ids`, `scores`, `model_version`, echoed `request_id`.
- **Signature:** in `user_id:str, k:int, request_id:str` → out
  `item_ids:list, scores:list, model_version:str, request_id:str`.

## 9. Serving, logging, replay
- **Predictor:** `InferenceService recsys` (`components/model-service`) with a
  namespaced runtime `FROM mlops-mlflow` + implicit + feast. Cluster-internal.
  `storageUri` is owned by `mlops-promote`.
- **Front `recsys-api`:** FastAPI at `api.localtest.me`.
  - `GET /recommend/{user_id}?k=20` → V2 infer → JSON
  - `POST /feedback` → logsink
  - JWT validation from step 8
- **Logging:** KServe payload logger → `mlops-logsink` → `predictions`. The front
  writes `feedback`. Entity JSONPath = `user_id`.
- **Replayer:** streams the replay window as `/recommend` calls, then sends the real
  interactions as `/feedback`. 1 simulated day = 1 min. Drives Feast
  materialisation; a `--shift` mode serves the `drifting` fixture.

## 10. Monitoring and observability
- **`mlops-monitor` plugin `recsys.monitoring:metrics`:** Recall@20, NDCG@20,
  coverage and popularity bias, reusing `recsys.evaluate` (same code as offline).
  Drift is generic, from the platform.
- **Custom metrics (MLServer custom-metrics API; verify for the pinned version):**
  - `recsys_stage_latency_seconds{stage=lookup|score|fallback}`
  - `recsys_fallback_total{reason}`
  - `recsys_short_result_total`
  - `recsys_score{model_version}`
- **Front:** prometheus-fastapi-instrumentator + a ServiceMonitor; structlog JSON
  (`app=recsys`, `model_version`, `request_id`).
- **Dashboards:** the platform "Model overview" plus a recsys dashboard with an
  offline vs. online gap panel.
- **`PrometheusRule`:** p95 `/recommend` > 50 ms for 10 min; fallback rate > 20%;
  drift over threshold.

## 11. Manifests, deploy, CI
- **Kustomize** (namespace `recsys`) including pinned platform components:
  `model-service`, `model-monitor`, `feast-materialize` (suspended during replay),
  `batch-inference`.
- **Recsys-only resources:**
  - the `recsys-api` Deployment, Service, Ingress and ServiceMonitor
  - the namespaced ServingRuntime
  - the replayer Job and `recsys-train` Job
  - the promote Job overlay
  - dashboards and the PrometheusRule
- **Deploy:** `make deploy` (`kubectl apply -k`) until platform P3; after that the
  ArgoCD Application `recsys` syncs from git (`storageUri` drift ignored). Manifests
  must pass the Kyverno policies.
- **CI:** ruff, mypy; unit tests on ml-small fixtures; bundle tests (including that
  `broken-bundle` fails `load_context`); `kustomize build` → kubeconform +
  `kyverno apply`; image build + Trivy.

## 12. RAM (tenant)
| Component | Est. |
|---|---|
| InferenceService (MLServer + ml-small bundle, a few MB) | 0.5 GB |
| recsys-api front | 0.15 GB |
| Monitor CronJob (transient) | 0.5–1.0 GB |
| Replayer / train / batch Jobs (transient) | ≤ 1 GB (ml-small) |
| **Peak** | **~1.5 GB** (32M scale test: measure, use the `training` quota) |

## 13. Build sequence (~4–6 sessions of tenant work in total)
| Step | Scope | Needs platform |
|---|---|---|
| 0 | Scaffold (uv, Py 3.12, layout §6, Makefile, pre-commit) | — |
| 1 | Data to MinIO, split, popularity + ALS logged to MLflow | P0 + `make tenant NAME=recsys` |
| 2 | Bundle + `load_context` checks + `promotion.yaml`; front; serve locally with `mlserver start` | — |
| 3 | Deploy: popularity → `@champion`, ALS promoted via the gate | L1 + L2 |
| 4 | Bad-model fixtures (§4) → feeds platform T1 | L2 |
| 5 | Replayer + logging; monitor plugin; dashboards + alerts; the `drifting` fixture | P1 + L3 |
| 6 | Feast `movie_stats` (training as-of T, online fallback) | F1 |
| 7 | Batch top-K for warm users vs. online during replay | L4 |
| 8 | JWT in the front; Keycloak clients for recsys + the replayer | P2 |
| 9 | Retraining loop: `recsys-train` Job on train + replayed data → `@challenger` → `make promote` → compare live | L2 (P4 Kueue optional) |
| — | Realign the repo to the golden-path template | G1 |

## 14. Deferred (data-scientist work, not platform work)
Two-tower retrieval + FAISS ANN; LightGBM ranker on Feast features; session-based or
online user embeddings; online A/B or interleaving; any modelling on 32M.
