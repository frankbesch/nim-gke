# Reference

## Cost

Rates for `us-central1`, on demand.

- **NVIDIA L4 GPU:** about $0.56 per hour (Posted: $0.5608 for 1.00 hour)
- **`g2-standard-4` cores and memory:** about $0.15 per hour (Posted: 4.01 core-hours and 16.03 GiB-hours for $0.1471)
- **GPU node, `g2-standard-4` with one L4:** $0.7068 per hour (Cloud Billing Catalog API, read 2026-09-27)
- **System node, `e2-standard-4`:** $0.1340 per hour (Cloud Billing Catalog API, read 2026-09-27)
- **GKE zonal cluster fee:** $0.10 per hour (Credited in full on this account's bill)
- **Running rate while the deployment is up:** about $0.98 per hour (Sum of the lines above plus disks)

Notes:

- The bill prices the L4, the G2 cores, and the G2 memory as three separate
  SKUs. Together they match the $0.7068 catalog figure for the node.
- The system pool keeps a minimum of 1 node, and the cluster fee applies, on
  the fixed and the autoscaling path alike. There is no "$0 per hour while
  idle" state short of deleting the cluster.
- Output cost on the GPU node alone, single stream: about $12 per million
  output tokens at 15.9 tokens/s.

## Prerequisites

| Requirement | Version | Purpose |
|-------------|---------|---------|
| `gcloud` CLI | Latest | GCP authentication, cluster management |
| `kubectl` | 1.28+ | Kubernetes operations |
| `helm` | 3.0+ | Chart deployment |
| NGC API Key | — | NIM image registry auth |
| GCP Project | — | Billing enabled |
| GPU Quota | 1× L4 | us-central1 or compatible region |

**GPU quota approval**: Required before deployment. See [GPU_QUOTA_GUIDE.md](GPU_QUOTA_GUIDE.md).

`NGC_API_KEY` is the variable the `nim-llm` chart and NVIDIA's docs use
(https://docs.nvidia.com/nim/large-language-models/latest/deployment/kubernetes-deployment/helm-k8s.html).
`NGC_CLI_API_KEY` is still accepted as a fallback if `NGC_API_KEY` is unset.

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

- `PROJECT_ID` *(required, no default)*: GCP project
- `NGC_API_KEY` *(required)*: NIM registry auth
- `REGION` (default `us-central1`): GCP region
- `ZONE` (default `us-central1-a`): GKE zone
- `CLUSTER_NAME` (default `nim-demo`): Cluster identifier
- `GPU_TYPE` (default `nvidia-l4`): GPU accelerator type
- `NODE_POOL_MACHINE_TYPE` (default `g2-standard-4`): GPU node instance type
- `CLUSTER_MACHINE_TYPE` (default `e2-standard-4`): System node instance type
- `NIM_CHART_VERSION` (default `1.3.0`): Helm chart version
- `NIM_RELEASE_NAME` (default `my-nim`): Helm release name
- `NIM_NAMESPACE` (default `nim`): Kubernetes namespace

## Security

- ✅ NGC API key stored as Kubernetes Secret
- ✅ Image pull secrets for nvcr.io registry
- ✅ Service exposed via ClusterIP (internal only)
- ⚠️ TLS: not configured; would need Ingress + cert-manager
- ⚠️ Authentication: no API gateway; add one before any production use

## What this adds to the tutorial

- `scripts/config.env`: one settings file every script sources. Only
  `PROJECT_ID` and `NGC_API_KEY` must be set; everything else has a default
  and can be overridden by exporting it first.
- `scripts/preflight.sh`: six read-only checks before touching GCP (NGC key,
  gcloud auth, image tag, chart fetch, L4 quota, no existing cluster).
- `set -euo pipefail` in every script.
- `scripts/bench.py`: the benchmark used for the measured runs (20 requests
  at temperature 0, 5 streamed for time-to-first-token, concurrency 1).
- `scripts/cleanup.sh`: uninstalls the Helm release, deletes the PVC, deletes
  the cluster, then lists any leftover disks in the project.
- `scripts/run_measured.sh`: one command for a whole measured run, with a
  trap and a watchdog that delete the cluster if the run dies.
- A troubleshooting runbook (`runbooks/troubleshooting.md`) and a quick
  reference (`QUICK_REFERENCE.md`).
- `scripts/deploy_nim_production.sh`: an alternate path with an autoscaling
  GPU node pool (0-2 nodes) and a system pool with a minimum of 1 node. This
  path has **not** been measured; treat its numbers as design targets, not
  receipts.

**Tutorial compatibility**: the core deployment steps from the
[Google Codelabs tutorial](https://codelabs.developers.google.com/codelabs/nvidia-nim-google-cloud)
are preserved.

## Repository layout

```text
nim-gke/
├── charts/                     # Helm charts and values
│   └── values-production.yaml  # Production config (chart .tgz is gitignored, fetched at deploy time)
├── scripts/                    # Deployment and ops scripts
│   ├── config.env              # Shared settings, sourced by every script
│   ├── preflight.sh             # Read-only checks before deploy
│   ├── deploy_nim_gke.sh        # Main (measured) deployment
│   ├── deploy_nim_production.sh # Autoscaling deployment (not measured)
│   ├── run_measured.sh          # Whole measured run, with trap and watchdog
│   ├── bench.py                 # Benchmark used for the measured runs
│   ├── test_nim.sh              # Basic smoke test
│   ├── cleanup.sh               # Resource deletion
│   └── monitor_deployment.sh    # Status monitoring
├── docs/                       # Documentation
│   ├── runs/README.md                     # Receipt index, attempt log, posted cost
│   ├── runs/2026-09-27-run-1-fixed.md     # Measured run 1, fixed pool
│   ├── runs/2026-09-27-run-2-fixed.md     # Measured run 2, updated scripts
│   ├── runs/2026-09-28-run-3-autoscale.md # Measured run 3, autoscaling 0→1→0
│   ├── PRODUCTION_GUIDE.md     # Operations manual
│   ├── GPU_QUOTA_GUIDE.md      # Quota request process
│   └── QUICKSTART.md
├── tests/                      # Stubbed tests; no cloud calls
├── runbooks/                   # Operational procedures
│   └── troubleshooting.md      # Incident response
├── examples/                   # Configuration templates
│   └── set_ngc_key.sh.template # NGC key setup
└── README.md                   # This file
```

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
