# Measured run 3: GPU node autoscaling 0→1→0 (2026-09-28)

First measured GPU node-autoscaling run on this repo. Same project, zone,
chart, image, and hardware as [run 1](2026-09-27-measured-run.md) and
[run 2](2026-09-27-run-2.md): `nim-llm-1.3.0`,
`nvcr.io/nim/meta/llama3-8b-instruct:1.0.0`, `g2-standard-4` with one NVIDIA
L4, one `e2-standard-4` system node. The difference: `gpupool` is created
with **0 nodes** and cluster autoscaling (`--num-nodes=0 --enable-autoscaling
--min-nodes=0 --max-nodes=1`), so the GPU node exists only while a pod needs
it. Run by the owner from a local terminal:
`scripts/run_measured.sh --autoscale OUT_DIR`.

Scope: node autoscaling 0→1→0 only. Project GPU quota is 1 (an increase to 2
was declined), so 1→2 was not run. Pod autoscaling on request rate is out of
scope.

## Result

| Gate | Result |
|---|---|
| Preflight: key, auth, image tag, chart, L4 quota, no cluster, autoscale quota | PASS |
| GPU pool created at 0 nodes with autoscaling (min 0, max 1) | PASS |
| 0→1: pod Pending → `TriggeredScaleUp` → L4 node Ready → pod Ready | PASS |
| Inference: `/v1/models`, smoke 200, bench | PASS |
| 1→0: replicas=0 → autoscaler removes the L4 node | PASS |
| Autoscaler decisions logged (`cluster-autoscaler-visibility`) | PASS: 1 scaleUp, 1 scaleDown |
| Destroy: no cluster, no VM, no disk left in the project | PASS |

## Evidence of the scale-up trigger

At phase start the GPU node count was 0 and the NIM pod was Pending:

- `FailedScheduling … 0/1 nodes are available: 1 Insufficient nvidia.com/gpu`
- `TriggeredScaleUp … cluster-autoscaler … Pod triggered scale-up` (gpupool MIG)

Cloud Logging, `container.googleapis.com/cluster-autoscaler-visibility`:

| Time (UTC) | Decision |
|---|---|
| 19:55:42 | `scaleUp`: gpupool MIG, `requestedNodes: 1`, triggering pod from StatefulSet `my-nim-nim-llm` |
| 20:20:05 | `scaleDown`: `nodesToBeRemoved` = the gpupool node |

## Timeline (UTC, from phases.log, node and pod data, and the autoscaler log)

| Phase | Start | End | Duration |
|---|---|---|---|
| Preflight | 19:48:30 | 19:48:35 | 5 s |
| Create cluster + 0-node GPU pool, helm install | 19:48:35 | 19:55:41 | 7 m 06 s |
| **Scale-up: trigger to GPU node Ready** | 19:55:42 | 19:56:59 | **1 m 17 s** (node created 19:56:49) |
| Image pull and model load to pod Ready | 19:56:59 | 20:04:37 | 7 m 38 s |
| Bench | 20:04:44 | 20:08:52 | 4 m 08 s |
| **Scale-down: replicas=0 to GPU node gone** | 20:08:53 | 20:21:25 | **12 m 32 s** |
| of which: autoscaler decision | 20:08:53 | 20:20:05 | 11 m 12 s |
| of which: node removal after decision | 20:20:05 | 20:21:25 | 1 m 20 s |
| Cleanup (uninstall, PVC and PV wait, cluster delete, disk check) | 20:21:28 | 20:27:19 | 5 m 51 s |
| **Script start to pod Ready** | 19:48:30 | 20:04:37 | 16 m 07 s |

The 11-minute wait before the scale-down decision is GKE's own unneeded-node
delay; GKE does not document the value, so this is one observation, not a
spec.

## Inference (single stream, concurrency 1, port-forward from a laptop)

`scripts/bench.py`: 20 requests, max_tokens 256, temperature 0; 5 streamed
requests for time to first token. Backend profile `vllm-fp16-tp1`.

| Metric | Run 3 | Run 2 | Run 1 |
|---|---|---|---|
| Latency p50 / p95 | 11.1 s / 16.0 s | 11.1 s / 16.1 s | 11.1 s / 16.0 s |
| Output throughput p50 (min) | 15.9 (15.8) tok/s | 15.9 (15.5) tok/s | 15.9 (15.2) tok/s |
| Time to first token p50 / max | 0.19 s / 0.20 s | 0.19 s / 0.21 s | 0.29 s / 0.30 s |

Autoscaling does not change inference once the node is up, as expected.
n=20 and n=5 per run; not a load test.

## Cost (list prices as in run 1; durations are upper bounds)

| Item | Minutes | Rate | Cost |
|---|---|---|---|
| GKE zonal cluster fee | 38.6 | $0.1000/h | $0.064 |
| e2-standard-4 system node (cluster lifetime, upper bound) | 38.6 | $0.1340/h | $0.086 |
| g2-standard-4 with 1× L4 (created 19:56:49, gone 20:21:25) | 24.6 | $0.7068/h | $0.290 |
| 2 × 100 GiB boot disks (assumed GKE default) | 38.6 / 24.6 | $0.0137/h each | $0.014 |
| 50 GiB model-cache PVC | ~26 | $0.0068/h | $0.003 |
| **Total for the run** | | | **≈ $0.46** |

The GPU node billed 24.6 min of the 38.6-min run. Of that, 12.5 min was the
scale-down wait with no pod on the node: the price of scale-to-zero on GKE.
Reconcile against Cloud Billing 24–48 hours after the run.

## Cleanup proof

`cleanup.sh` deleted the PVC, waited for the PV and its disk to go, then
deleted the cluster. Final checks: 0 clusters, 0 VMs, 0 disks. This proves
live the PV-wait fix from run 2's orphaned-disk defect.

## Not measured

- 1→2 (a second GPU node): needs GPU quota 2.
- Autoscaling under load or on request rate (HPA): out of scope.
- Any GPU other than L4, or the newer `llama-3.1-8b-instruct` NIM.
