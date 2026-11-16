# Scale track: distributed training + LLM serving (north star, NOT active)

Status: parked (2026-11-16). Source: a HyperPod-style blueprint from another AI
conversation. Kept here so it isn't lost and doesn't leak into the current platform
scope. The active work is `platform-PRD.md` (P0–P3) and `recsys-PRD.md`.

## Entry criteria (all three must be true before starting)
1. recsys-lite has reached step 3 (deployed and promoted through the gate) and platform-test (T1) passes.
2. The EKS track runs the platform (Terraform cluster + overlays/eks + IRSA + LB
   controller).
3. A concrete GPU workload exists. The likely candidate is an LLM tenant for the
   "AI childcare" product. Its *first* version is probably one vLLM endpoint (or an
   external API), not disaggregated serving. Each layer below has to be justified by
   that workload's actual load, not built ahead of it.

Why gated: the laptop has no GPU and 30 GB RAM, so about 80% of this stack can't
run or teach anything locally. On EKS, GPU instances cost real money per hour
(check current pricing before every session; tear down after, as the Terraform
track already does).

## Blueprint layers, mapped to this platform
| Layer | Components | Where it runs | When |
|---|---|---|---|
| 1. Hardware | NVIDIA GPU Operator, time-slicing/MIG, EFA device plugin, NCCL tuning | EKS GPU node group (Karpenter NodePool) | Scale track S1 |
| 1. Storage | FSx for Lustre for hot datasets/checkpoints; S3 stays the source of truth (MinIO locally) | EKS | Only if S3 throughput is a measured bottleneck |
| 2. Queueing | **Kueue**: ClusterQueue/LocalQueue per tenant, priorities, preemption, borrowing | **Local kind (CPU quotas) → EKS** | **Platform P4 (optional), before this track** |
| 2. Autoscaling | **Karpenter**: GPU + Spot NodePools, consolidation, interruption handling | EKS | S1 (already deferred in `.local-terra`) |
| 3. Distributed exec | **KubeRay** (RayJob/RayCluster/RayService): Ray Data, Tune, Train | **Local CPU (Tune for recsys HPO) → EKS** | **P4 (optional)**, GPU use in S2 |
| 3. Training operators | Kubeflow Trainer (PyTorchJob / TrainJob) | EKS GPU | S2, only when a model needs more than one GPU |
| 4. Parallelism | FSDP first; DeepSpeed / Megatron-LM / 3D parallelism only if FSDP can't fit the model | EKS multi-GPU | S2+ |
| 4. Fault tolerance | PyTorch DCP async checkpoints to S3, Node Problem Detector | EKS | With S2 |
| 5. Edge | Envoy Gateway + Gateway API (not NGINX, since ingress-nginx is retired) | EKS (and local, if migrated) | S3, triggers the Traefik → Envoy revisit (platform-PRD §5) |
| 5. LLM routing | Gateway API Inference Extension (KV-cache / queue-aware routing); NVIDIA Dynamo only at multi-node scale | EKS GPU | S3+ |
| 5. Disaggregated serving | Prefill/decode split, KV transfer over NIXL/EFA | EKS multi-GPU + EFA | Last, only for high-QPS long-context workloads |
| 5. Engines | vLLM (default), Ray Serve for composite pipelines | EKS GPU | S3 |
| Packaging | OCI images + MLflow registry. **Skip DJL containers** (SageMaker-specific) | — | — |

## Proposed sequence once the entry criteria are met
- **S1 GPU substrate:**
  - Karpenter GPU NodePool (Spot allowed for non-serving work) plus the GPU Operator;
  - a smoke test: a single-GPU Job running `nvidia-smi`, then a small PyTorch train
    through Kueue;
  - DCGM exporter → existing Prometheus.
- **S2 training:**
  - a RayJob or PyTorchJob with FSDP on 2 GPUs, checkpointing to S3, resuming after
    a forced node kill.
- **S3 LLM serving tenant:**
  - vLLM behind Envoy Gateway + the Inference Extension, registered via the MLflow
    registry, onboarded with `make tenant`;
  - metrics: TTFT, TPOT, KV-cache utilisation, cost per 1M tokens.
- **S4 advanced:** disaggregated prefill/decode, Dynamo, EFA. Only if S3 load data
  demands it.

Each stage must be verified (and torn down) before the next one starts. Bottom-up
ordering applies *within* this track, not to the platform as a whole.

## Do not import into active work
- The "build bottom-up from GPU infrastructure" working order: on this hardware it
  stalls at layer 1.
- DJL containers, Megatron/3D parallelism, and Dynamo: no workload justifies them
  yet.
