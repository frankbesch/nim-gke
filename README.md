# nim-gke

**NVIDIA NIM inference on Google Kubernetes Engine, on a single L4 GPU**

Reference implementation for deploying an NVIDIA NIM microservice on GKE.
One full deploy/test/destroy cycle has been measured end to end; see the
[run receipt](docs/runs/2026-09-27-measured-run.md) for every number in this
file.

**Based on**: [Google Codelabs - Deploy an AI model on GKE with NVIDIA NIM](https://codelabs.developers.google.com/codelabs/nvidia-nim-google-cloud)

---

## What This Adds to the Tutorial

- `scripts/config.env`: one settings file every script sources. Only
  `PROJECT_ID` and `NGC_API_KEY` must be set; everything else has a default
  and can be overridden by exporting it first.
- `scripts/preflight.sh`: six read-only checks before touching GCP (NGC key,
  gcloud auth, image tag, chart fetch, L4 quota, no existing cluster).
- `set -euo pipefail` in every script.
- `scripts/bench.py`: the benchmark used for the measured run (20 requests
  at temperature 0, 5 streamed for time-to-first-token, concurrency 1).
- `scripts/cleanup.sh`: uninstalls the Helm release, deletes the PVC, deletes
  the cluster, then lists any leftover disks in the project.
- A troubleshooting runbook (`runbooks/troubleshooting.md`) and a quick
  reference (`QUICK_REFERENCE.md`).
- `scripts/deploy_nim_production.sh`: an alternate path with an autoscaling
  GPU node pool (0-2 nodes) and a system pool with a minimum of 1 node. This
  path has **not** been measured; treat its numbers as design targets, not
  receipts.

**Tutorial compatibility**: the core deployment steps from the
[Google Codelabs tutorial](https://codelabs.developers.google.com/codelabs/nvidia-nim-google-cloud)
are preserved.

---

## Architecture

NIM container → L4 GPU → GKE node pool. NIM picks a backend profile at startup for the detected GPU; on the L4 it found one compatible profile, `vllm-fp16-tp1` (vLLM, FP16), per the [run 2 pod log](docs/runs/2026-09-27-run-2.md#backend-profile).

**Components**:
- **Model**: Meta Llama 3 8B Instruct
- **Runtime**: NVIDIA NIM, image `nvcr.io/nim/meta/llama3-8b-instruct:1.0.0`
- **Chart**: `nim-llm` 1.3.0 (fetched at deploy time; not committed to the repo)
- **Orchestration**: Kubernetes StatefulSet via Helm
- **Compute (measured path, `deploy_nim_gke.sh`)**: one `g2-standard-4` node
  with one NVIDIA L4, plus one `e2-standard-4` system node. Fixed node
  counts; no autoscaling.
- **Compute (unmeasured path, `deploy_nim_production.sh`)**: GPU node pool
  autoscales 0-2 nodes; system pool has a minimum of 1 node.
- **API**: OpenAI-compatible REST (`/v1/chat/completions`)

### Hardware support

NVIDIA's current NIM support matrix lists `llama-3.1-8b-instruct`, and no row
lists the NVIDIA L4 (checked 2026-09-27:
https://docs.nvidia.com/nim/large-language-models/latest/reference/support-matrix.html).
This repo runs the earlier `llama3-8b-instruct:1.0.0` image on one L4; it is
off the current matrix and measured working (see the
[run receipt](docs/runs/2026-09-27-measured-run.md)). Newer chart and image
versions are not yet tested here.

---

## Prerequisites

| Requirement | Version | Purpose |
|-------------|---------|---------|
| `gcloud` CLI | Latest | GCP authentication, cluster management |
| `kubectl` | 1.28+ | Kubernetes operations |
| `helm` | 3.0+ | Chart deployment |
| NGC API Key | — | NIM image registry auth |
| GCP Project | — | Billing enabled |
| GPU Quota | 1× L4 | us-central1 or compatible region |

**GPU quota approval**: Required before deployment. See `/docs/GPU_QUOTA_GUIDE.md`.

`NGC_API_KEY` is the variable the `nim-llm` chart and NVIDIA's docs use
(https://docs.nvidia.com/nim/large-language-models/latest/deployment/kubernetes-deployment/helm-k8s.html).
`NGC_CLI_API_KEY` is still accepted as a fallback if `NGC_API_KEY` is unset.

---

## Deployment

### Quick Start (measured path)

```bash
# 1. Set the two required variables
export NGC_API_KEY='your-key-here'
export PROJECT_ID='your-gcp-project'

# 2. Preflight checks (read-only)
./scripts/preflight.sh

# 3. Deploy
./scripts/deploy_nim_gke.sh

# 4. Verify
kubectl get pods -n nim
kubectl port-forward -n nim svc/my-nim-nim-llm 8000:8000

# 5. Test
./scripts/test_nim.sh          # or: python3 scripts/bench.py

# 6. Tear down
./scripts/cleanup.sh
```

All other settings (region, zone, cluster name, machine types, chart
version, release name, namespace) come from `scripts/config.env`. Override
any of them by exporting the variable before running a script.

### Production Deployment (not measured)

```bash
./scripts/deploy_nim_production.sh
./scripts/test_nim_production.sh
```

Autoscaling GPU pool (0-2 nodes) and a system pool with a minimum of 1
node. No timing or cost numbers exist for this path.

---

## Verify

```bash
# Health check
curl http://localhost:8000/v1/health/ready

# List models
curl http://localhost:8000/v1/models

# Inference test
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [{"role": "user", "content": "What is TensorRT?"}],
    "model": "meta/llama3-8b-instruct",
    "max_tokens": 100
  }'
```

This single call is not a benchmark. For measured latency and the method behind it, see the [cost and performance](#cost-and-performance) table and `scripts/bench.py`.

---

## Operate

### Monitor

```bash
# Pod status
kubectl get pods -n nim -w

# Logs
kubectl logs -f my-nim-nim-llm-0 -n nim

# GPU utilization
kubectl exec -n nim my-nim-nim-llm-0 -- nvidia-smi

# Resource usage
kubectl top pod -n nim
```

### Scale

```bash
# Manual scale (StatefulSet)
# Each replica needs its own L4; with the default 1-node GPU pool a 2nd replica stays Pending.
kubectl scale statefulset my-nim-nim-llm --replicas=2 -n nim

# GPU node pool resize
gcloud container node-pools resize gpupool \
  --cluster=nim-demo \
  --zone=us-central1-a \
  --num-nodes=2
```

### Cost Control

```bash
# Remove deployment (keep cluster)
helm uninstall my-nim -n nim

# Delete cluster, PVC, and list leftover disks
./scripts/cleanup.sh
```

---

## Troubleshoot

**Pod stuck in Pending**:
```bash
kubectl describe pod -n nim my-nim-nim-llm-0
# Check: GPU availability, node readiness, quotas
```

**ImagePullBackOff** (image pulls use `registry-secret`):
```bash
kubectl get secret registry-secret -n nim
# Recreate both secrets if needed
PROJECT_ID="${PROJECT_ID:-x}" source scripts/config.env   # run from the repo root
ngc_apply_secrets nim   # recreates registry-secret and ngc-api; key stays off the command line
kubectl delete pod my-nim-nim-llm-0 -n nim
```

**Model loading slow**:
- Measured: model download to Ready took 8 m 39 s in the run receipt.
- Monitor: `kubectl logs -f my-nim-nim-llm-0 -n nim`

See `/runbooks/troubleshooting.md` for complete procedures.

---

## Repository Structure

```
nim-gke/
├── charts/                     # Helm charts and values
│   └── values-production.yaml  # Production config (chart .tgz is gitignored, fetched at deploy time)
├── scripts/                    # Deployment and ops scripts
│   ├── config.env              # Shared settings, sourced by every script
│   ├── preflight.sh             # Read-only checks before deploy
│   ├── deploy_nim_gke.sh        # Main (measured) deployment
│   ├── deploy_nim_production.sh # Autoscaling deployment (not measured)
│   ├── bench.py                 # Benchmark used for the measured run
│   ├── test_nim.sh              # Basic smoke test
│   ├── cleanup.sh               # Resource deletion
│   └── monitor_deployment.sh    # Status monitoring
├── docs/                       # Documentation
│   ├── runs/2026-09-27-measured-run.md  # Measured run 1 (source of truth)
│   ├── runs/2026-09-27-run-2.md         # Measured run 2, updated scripts
│   ├── PRODUCTION_GUIDE.md     # Operations manual
│   ├── GPU_QUOTA_GUIDE.md      # Quota request process
│   └── QUICKSTART.md
├── runbooks/                   # Operational procedures
│   └── troubleshooting.md      # Incident response
├── examples/                   # Configuration templates
│   └── set_ngc_key.sh.template # NGC key setup
└── README.md                   # This file
```

---

## Configuration

### Helm Values

The deploy scripts generate their Helm values inline from `scripts/config.env`
(image repo and tag, chart version, namespace). To change them, export the
variable before running a script, for example `export NIM_IMAGE_TAG=...`.
`charts/values-production.yaml` is a reference copy of those values for CI
linting; no script passes it to Helm.

### Environment Variables

All defaults live in `scripts/config.env`. `PROJECT_ID` has no default and
must be exported. `NGC_API_KEY` must be exported too (see
[Prerequisites](#prerequisites) for the fallback). Everything else below is
an optional override.

| Variable | Default | Purpose |
|----------|---------|---------|
| `PROJECT_ID` | *(required, no default)* | GCP project |
| `NGC_API_KEY` | *(required)* | NIM registry auth |
| `REGION` | `us-central1` | GCP region |
| `ZONE` | `us-central1-a` | GKE zone |
| `CLUSTER_NAME` | `nim-demo` | Cluster identifier |
| `GPU_TYPE` | `nvidia-l4` | GPU accelerator type |
| `NODE_POOL_MACHINE_TYPE` | `g2-standard-4` | GPU node instance type |
| `CLUSTER_MACHINE_TYPE` | `e2-standard-4` | System node instance type |
| `NIM_CHART_VERSION` | `1.3.0` | Helm chart version |
| `NIM_RELEASE_NAME` | `my-nim` | Helm release name |
| `NIM_NAMESPACE` | `nim` | Kubernetes namespace |

---

## Cost and Performance

Measured twice on 2026-09-27 with `deploy_nim_gke.sh`, project `nim-on-gke`,
`us-central1-a`, chart `nim-llm-1.3.0`, image
`nvcr.io/nim/meta/llama3-8b-instruct:1.0.0`, backend profile `vllm-fp16-tp1`.
Run 2 used the scripts after the review fixes. Full detail, methodology, and
list-price sources: [run 1](docs/runs/2026-09-27-measured-run.md),
[run 2](docs/runs/2026-09-27-run-2.md).
This is the only cost/performance table in the repo; other docs link here.

| Metric | Run 1 | Run 2 |
|--------|-------|-------|
| Deploy time, script start to pod Ready | 20 m 19 s | 18 m 53 s |
| Time to first token (5 streamed requests) | p50 0.29 s, max 0.30 s | p50 0.19 s, max 0.21 s |
| Output throughput, single stream | p50 15.9 tokens/s, min 15.2 | p50 15.9 tokens/s, min 15.5 |
| Latency, 20 requests, 256 max tokens, temp 0 | p50 11.1 s, p95 16.0 s | p50 11.1 s, p95 16.1 s |
| Cost for one full deploy + smoke test + destroy | $0.43 | $0.40 (plus an orphaned disk, since fixed in `cleanup.sh`) |
| Running cost while the deployment is up | ~$0.98/hour | ~$0.98/hour |
| Output cost, single stream, GPU node only | ~$12 per million output tokens | same |

Notes:
- `g2-standard-4` with 1× L4 is priced as one bundled SKU: $0.7068/hour
  (measured 2026-09-27 from the Google Cloud Billing Catalog API). GCP does
  not price the GPU as a separate line item on this machine type.
- The system pool (`e2-standard-4`) keeps a minimum of 1 node, and the GKE
  zonal cluster fee applies, on the fixed and the autoscaling path alike.
  There is no "$0/hour while idle" state short of deleting the cluster.
- GPU node autoscaling 0→1→0 is measured (`AUTOSCALE=1`,
  `run_measured.sh --autoscale`, [run 3](docs/runs/2026-09-28-run-3-autoscale.md)):
  scale-up from a Pending pod to a Ready L4 node in 1 m 17 s; scale-down to 0
  nodes 12 m 32 s after replicas=0, of which the GPU node billed idle; about
  $0.46 for the run at list price. 1→2 (`--two-nodes`) needs GPU quota 2 and
  is not measured. `deploy_nim_production.sh` remains unmeasured.

---

## Security

- ✅ NGC API key stored as Kubernetes Secret
- ✅ Image pull secrets for nvcr.io registry
- ✅ Service exposed via ClusterIP (internal only)
- ⚠️ TLS: not configured; would need Ingress + cert-manager
- ⚠️ Authentication: no API gateway; add one before any production use

---

## GKE compared with OKE

This kit has a companion, [nimble-oke](https://github.com/frankbesch/nimble-oke),
that does the same job on Oracle Kubernetes Engine: deploy NIM with Helm,
track cost, clean up, and measure GPU node autoscaling. The two platforms
reach the same result. OKE needs more explicit setup. The table lists what
each kit has to do itself.

| Task | GKE, nim-gke | OKE, nimble-oke |
|------|--------------|-----------------|
| Hardware and image | `g2-standard-4`, one NVIDIA L4 (24 GB). NVIDIA's `nim-llm` chart 1.3.0. `llama3-8b-instruct:1.0.0`. | `VM.GPU.A10.1`, one NVIDIA A10 (24 GB). Own Helm chart. `llama3-8b-instruct:1.0.3`. |
| Network rules for node registration | GKE creates the ingress firewall rules when it creates the cluster. The kit sets none. | The kit creates two security lists: workers to the API endpoint on 6443 and 12250, the control plane to workers, and node to node. |
| Subnets | The kit passes no network flags and uses the project's default network. | The kit creates an API endpoint subnet and a worker subnet. A node pool cannot use the cluster's service load-balancer subnet. |
| Root filesystem | The kit uses the default boot disk and has no resize step. | The GPU node pool runs `oci-growfs` in cloud-init. Without it the root filesystem stays near 35 GB whatever the boot volume size. |
| GPU drivers and device plugin | The node pool sets `gpu-driver-version`, and GKE installs the drivers. The kit applies no device plugin. | The GPU node image carries the drivers. The kit checks for an allocatable GPU and applies the NVIDIA device plugin if none is reported. |
| GPU taint and toleration | GKE adds the taint `nvidia.com/gpu=present:NoSchedule` and adds the toleration to pods that request a GPU. | The autoscaler treats GPU nodes as tainted `nvidia.com/gpu:NoSchedule`. The chart carries the toleration. |
| System node | The default CPU node pool runs system pods. Google states that a Standard cluster keeps at least one node for them. | One CPU node pool that the autoscaler does not manage. Oracle requires it to run the autoscaler and cluster add-ons. |
| Cluster autoscaler | Three flags on the node pool: `--enable-autoscaling`, `--min-nodes`, `--max-nodes`. The kit deploys no autoscaler. | The kit installs the Cluster Autoscaler add-on with `min:max:pool` and its scale-down timers. |
| Autoscaler permissions | The kit creates none. | A dynamic group and a six-statement policy, created once by the account owner. |
| GPU pool from zero nodes | Measured once: 0 to 1 to 0 on one L4, in nim-gke run 3. | Supported by the autoscaler's code. Oracle's documentation does not state it. The pool carries a tag that tells the autoscaler the node's storage. |
| GPU quota | A project quota, `GPUS_ALL_REGIONS`, plus the regional GPU quota. | A service limit per availability domain, `gpu-a10-count`. The default is 0. |
| Confirming a delete | `gcloud` waits for the delete. The kit then checks for a leftover model-store disk. | A delete returns a work request. The kit waits for it, then reads the resource state. |
| Cluster fee | The zonal cluster fee applies on both paths. | $0.10 per hour for an enhanced cluster. Basic clusters are free and cannot run the add-on. |

None of these is a defect in either platform. They are the steps a script
must own on OKE and can leave to the platform on GKE. The same table appears
in both repositories.

Sources: each kit's own scripts for what the kit does. For platform
behaviour, Google's GKE documentation on GPUs, firewall rules, and the
cluster autoscaler, and Oracle's OKE documentation on the Cluster Autoscaler
add-on, custom cloud-init, and GPU workloads, read on 2026-10-01. The measured
runs in each repository's `docs/runs/` show which rows are proven against the
real API.

---

## Limitations

- **Single GPU**: Multi-GPU tensor parallelism requires code changes
- **Model size**: Llama 3 8B fits L4. Larger models need A100/H100
- **Persistence**: Model cached on PV. Deletion triggers re-download
- **Regional availability**: L4 not in all GCP zones
- **Off support matrix**: see [Hardware support](#hardware-support) above

---

## References

### Primary Sources

- **[Google Codelabs - Deploy AI on GKE with NVIDIA NIM](https://codelabs.developers.google.com/codelabs/nvidia-nim-google-cloud)** - Original tutorial this repository is based on
- **[NVIDIA NIM Documentation](https://docs.nvidia.com/nim/)** - Official NIM microservices documentation
- **[NVIDIA NIM support matrix](https://docs.nvidia.com/nim/large-language-models/latest/reference/support-matrix.html)** - Supported GPUs and models
- **[GKE GPU Guide](https://cloud.google.com/kubernetes-engine/docs/how-to/gpus)** - Google Cloud GPU setup and configuration

### Core Technologies

- **[TensorRT-LLM](https://github.com/NVIDIA/TensorRT-LLM)** - NVIDIA's optimized inference engine
- **[vLLM](https://github.com/vllm-project/vllm)** - High-throughput LLM serving framework (continuous batching, PagedAttention)
- **[Kubernetes](https://kubernetes.io/docs/)** - Container orchestration platform
- **[Helm](https://helm.sh/docs/)** - Kubernetes package manager

### Additional Resources

- **[GCP GPU Regions](https://cloud.google.com/compute/docs/gpus/gpu-regions-zones)** - GPU availability by region
- **[Llama 3 Model Card](https://huggingface.co/meta-llama/Meta-Llama-3-8B-Instruct)** - Model documentation

---

## License

Provided as-is for educational and reference purposes. NVIDIA NIM requires acceptance of NVIDIA AI Enterprise EULA.

---

**Last measured**: 2026-09-27 (see [run receipt](docs/runs/2026-09-27-measured-run.md))
