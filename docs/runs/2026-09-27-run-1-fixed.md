# Measured run: deploy, smoke test, destroy (2026-09-27)

One end-to-end run of `scripts/deploy_nim_gke.sh` on GKE, measured and costed.
Project `nim-on-gke`, zone `us-central1-a`, chart `nim-llm-1.3.0`, image
`nvcr.io/nim/meta/llama3-8b-instruct:1.0.0`, one `g2-standard-4` node with one
NVIDIA L4, one `e2-standard-4` system node, GKE rapid channel.

## Result

| Gate | Result |
|---|---|
| Preflight: NGC key, auth, image tag, chart fetch, L4 quota, no cluster | PASS |
| Deploy: pod Ready, `/v1/models` lists `meta/llama3-8b-instruct` | PASS |
| Smoke: one chat completion, HTTP 200, non-empty answer | PASS (8.1 s, 128 max tokens) |
| Destroy: no clusters, no disks left in the project | PASS |

## Timeline (UTC, from GKE operations and pod status)

| Phase | Start | End | Duration |
|---|---|---|---|
| Create cluster | 18:56:46 | 19:03:24 | 6 m 38 s |
| Create GPU node pool | 19:03:29 | 19:04:31 | 1 m 02 s |
| GPU allocatable, pod scheduled | — | 19:05:19 | 48 s after pool |
| Image pull to container running | 19:05:19 | 19:08:18 | 2 m 59 s |
| Model download and load to Ready | 19:08:18 | 19:16:57 | 8 m 39 s |
| Delete release, PVC, cluster | 19:21:27 | 19:28:02 | 6 m 35 s |
| **Script start to Ready** | 18:56:38 | 19:16:57 | **20 m 19 s** |

## Inference (single stream, concurrency 1, port-forward from a laptop)

| Metric | Value |
|---|---|
| Latency, 20 requests, max_tokens 256, temperature 0 | p50 11.1 s, p95 16.0 s |
| Completion tokens per request (mean) | 174.5 |
| Output throughput | p50 15.9 tokens/s, min 15.2 |
| Time to first token, 5 streamed requests | p50 0.29 s, max 0.30 s |

Throughput is batch-1 decode on one L4; concurrent requests raise aggregate
throughput. These are n=20 and n=5 samples, not a load test.

## Cost

List prices from the Google Cloud Billing Catalog API, us-central1, on-demand,
read 2026-09-27. Durations are upper bounds from the GKE operation times.

| Item | Minutes | Rate | Cost |
|---|---|---|---|
| GKE zonal cluster fee | 31.3 | $0.1000/h | $0.052 |
| e2-standard-4 system node | 31.3 | $0.1340/h | $0.070 |
| g2-standard-4 with 1× L4 | 24.6 | $0.7068/h | $0.289 |
| 2 × 100 GiB boot disks (assumed GKE default) | 31.3 / 24.6 | $0.0137/h each | $0.013 |
| 50 GiB model-cache PVC | 16.7 | $0.0068/h | $0.002 |
| **Total** | | | **$0.43** |

Running rate while up: about $0.98/hour. The GKE free-tier credit may cover the
cluster fee, which would make the run $0.37 (not verified). Single-stream output
cost on the GPU node alone: about $12 per million tokens at 15.9 tokens/s.
Reconcile against the Cloud Billing report 24–48 hours after the run.

## Reproduce

1. `scripts/preflight.sh` -- read-only checks: NGC key, auth, image tag, chart
   fetch, L4 quota, no cluster. Stops before any cluster is created if a check
   fails.
2. `scripts/deploy_nim_gke.sh` -- creates the cluster and node pool, installs
   the `nim-llm-1.3.0` chart.
3. Port-forward the service:
   `kubectl port-forward -n nim svc/my-nim-nim-llm 8000:8000`.
4. `python3 scripts/bench.py --out bench.json` -- same method as this run:
   20 sequential requests (temperature 0, max_tokens 256), 5 streamed
   requests for time to first token, concurrency 1.
5. `scripts/cleanup.sh` -- tears the cluster down.

`scripts/preflight.sh` and `scripts/bench.py` were committed after this run;
`bench.py` is the script used on 2026-09-27, ported unchanged in method
(same prompts, same request shapes, same percentile math), with argparse
added so it runs without editing constants.
