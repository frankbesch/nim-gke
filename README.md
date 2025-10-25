# nim-gke

**GPU-accelerated NVIDIA NIM inference on Google Kubernetes Engine**

Production-grade reference implementation for deploying NVIDIA NIM microservices on GKE with L4 GPUs, autoscaling, and cost optimization.

**Based on**: [Google Codelabs - Deploy an AI model on GKE with NVIDIA NIM](https://codelabs.developers.google.com/codelabs/nvidia-nim-google-cloud)

---

## What This Adds to the Tutorial

This repository extends the [official Google Codelabs tutorial](https://codelabs.developers.google.com/codelabs/nvidia-nim-google-cloud) with production-grade enhancements:

**Operational Excellence**:
- Comprehensive error handling (`set -euo pipefail` in all scripts)
- Idempotent operations (safe to run multiple times)
- 60-minute deployment monitoring script
- Troubleshooting runbook (465 lines, 6 failure modes)
- Cost tracking and optimization strategies

**Automation & Testing**:
- Environment validation script (prerequisites, quotas, NGC key)
- Integration test suite with load testing
- CI/CD validation (shellcheck, yamllint, security scanning)
- Automated cleanup with verification

**Production Features**:
- Autoscaling GPU node pool (0-2 nodes)
- Cost optimization ($1.36/hour vs. tutorial's fixed deployment)
- Persistent volume for model caching (faster restarts)
- Resource limits and requests defined
- Production Helm values configuration

**Documentation**:
- Architecture deep-dive (517 lines: GPU memory layout, autoscaling mechanics)
- Interview preparation guide (357 lines: design decisions, talking points)
- Operational runbooks (troubleshooting, monitoring, incident response)
- Quick reference guide (one-page ops commands)
- Script documentation (usage, security, examples)

**Developer Experience**:
- Structured repository (charts, scripts, docs, runbooks separated)
- GitHub templates (PR, issues)
- Contributing guidelines
- Verification script (validates complete setup)

**Tutorial Compatibility**: All core deployment steps from the [Google Codelabs tutorial](https://codelabs.developers.google.com/codelabs/nvidia-nim-google-cloud) are preserved and enhanced, not replaced.

---

## Architecture

NIM container → TensorRT-LLM → vLLM backend → L4 GPU → GKE node pool

**Components**:
- **Model**: Meta Llama 3 8B Instruct
- **Runtime**: NVIDIA NIM 1.0.0 (TensorRT-LLM + vLLM)
- **Orchestration**: Kubernetes StatefulSet + Helm
- **Compute**: GKE with g2-standard-4 nodes (L4 GPU, 24GB VRAM)
- **API**: OpenAI-compatible REST (`/v1/chat/completions`)

**Autoscaling**: GPU node pool scales 0→2 based on pod requests.

**Cost**: ~$1.36/hour when active. $0/hour when scaled to zero.

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

---

## Deployment

### Quick Start

```bash
# 1. Set NGC API key
export NGC_CLI_API_KEY='your-key-here'

# 2. Configure project
export PROJECT_ID="your-gcp-project"
export REGION="us-central1"
export ZONE="us-central1-a"

# 3. Deploy
./scripts/deploy_nim_gke.sh

# 4. Verify
kubectl get pods -n nim
kubectl port-forward service/my-nim-nim-llm 8000:8000 -n nim
```

### Production Deployment

```bash
# Validate environment
./scripts/setup_environment.sh

# Deploy with production values
./scripts/deploy_nim_production.sh

# Run integration tests
./scripts/test_nim_production.sh
```

**Expected duration**: 25-35 minutes (cluster creation + model loading).

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

**Expected response time**: 3-6 seconds.

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
# GPU nodes auto-scale to 0

# Delete cluster (stop all costs)
./scripts/cleanup.sh
```

---

## Troubleshoot

**Pod stuck in Pending**:
```bash
kubectl describe pod -n nim my-nim-nim-llm-0
# Check: GPU availability, node readiness, quotas
```

**ImagePullBackOff**:
```bash
# Verify NGC secret
kubectl get secret ngc-api -n nim -o yaml
# Recreate if needed
kubectl delete secret ngc-api -n nim
kubectl create secret generic ngc-api \
  --from-literal=NGC_API_KEY=$NGC_CLI_API_KEY \
  -n nim
```

**Model loading slow**:
- Expected: 10-15 minutes on first deployment
- Monitor: `kubectl logs -f my-nim-nim-llm-0 -n nim`

See `/runbooks/troubleshooting.md` for complete procedures.

---

## Repository Structure

```
nim-gke/
├── charts/                     # Helm charts and values
│   ├── nim-llm-1.3.0.tgz      # NVIDIA NIM chart
│   └── values-production.yaml  # Production config
├── scripts/                    # Deployment and ops scripts
│   ├── deploy_nim_gke.sh      # Main deployment
│   ├── setup_environment.sh    # Prerequisite validation
│   ├── test_nim_production.sh  # Integration tests
│   ├── cleanup.sh             # Resource deletion
│   └── monitor_deployment.sh   # Status monitoring
├── docs/                       # Documentation
│   ├── DEPLOYMENT_SUCCESS.md   # Deployment guide
│   ├── PRODUCTION_GUIDE.md     # Operations manual
│   ├── GPU_QUOTA_GUIDE.md      # Quota request process
│   └── interview/              # Interview preparation materials
├── runbooks/                   # Operational procedures
│   └── troubleshooting.md      # Incident response
├── examples/                   # Configuration templates
│   └── set_ngc_key.sh.template # NGC key setup
└── README.md                   # This file
```

---

## Configuration

### Helm Values

Edit `charts/values-production.yaml`:

```yaml
image:
  repository: "nvcr.io/nim/meta/llama3-8b-instruct"
  tag: "1.0.0"

resources:
  limits:
    nvidia.com/gpu: 1
  requests:
    nvidia.com/gpu: 1

persistence:
  enabled: true
  size: 50Gi
```

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `PROJECT_ID` | `your-gcp-project` | GCP project |
| `REGION` | `us-central1` | GCP region |
| `ZONE` | `us-central1-a` | GKE zone |
| `CLUSTER_NAME` | `nim-demo` | Cluster identifier |
| `GPU_TYPE` | `nvidia-l4` | GPU accelerator type |
| `NODE_POOL_MACHINE_TYPE` | `g2-standard-4` | Node instance type |

---

## Performance

| Metric | Value | Notes |
|--------|-------|-------|
| **First token latency** | 2-3s | Cold start |
| **Throughput** | 15-20 tokens/s | L4 GPU, FP16 |
| **Batch size** | Dynamic | vLLM continuous batching |
| **Context length** | 8192 tokens | Llama 3 limit |
| **GPU memory** | ~12GB used | Of 24GB available |

---

## Cost

**Baseline** (no load):
- Control plane: $0.13/hour
- **Total**: $0.13/hour

**Active** (1 GPU node):
- Control plane: $0.13/hour
- GPU node (g2-standard-4): $0.50/hour
- L4 GPU: $0.73/hour
- **Total**: $1.36/hour (~$980/month)

**Optimization strategies**:
1. Autoscaling to zero when idle
2. Preemptible nodes (-80% cost, accepts interruption)
3. Committed use discounts (-37% for 3-year)
4. Regional vs. zonal deployment tradeoffs

---

## Security

- ✅ NGC API key stored as Kubernetes Secret
- ✅ Image pull secrets for nvcr.io registry
- ✅ Service exposed via ClusterIP (internal only)
- ✅ TLS for production (configure Ingress + cert-manager)
- ⚠️ Authentication: Implement API gateway for production workloads

---

## Limitations

- **Single GPU**: Multi-GPU tensor parallelism requires code changes
- **Model size**: Llama 3 8B fits L4. Larger models need A100/H100
- **Persistence**: Model cached on PV. Deletion triggers re-download
- **Regional availability**: L4 not in all GCP zones

---

## References

### Primary Sources

- **[Google Codelabs - Deploy AI on GKE with NVIDIA NIM](https://codelabs.developers.google.com/codelabs/nvidia-nim-google-cloud)** - Original tutorial this repository is based on
- **[NVIDIA NIM Documentation](https://docs.nvidia.com/nim/)** - Official NIM microservices documentation
- **[GKE GPU Guide](https://cloud.google.com/kubernetes-engine/docs/how-to/gpus)** - Google Cloud GPU setup and configuration

### Core Technologies

- **[TensorRT-LLM](https://github.com/NVIDIA/TensorRT-LLM)** - NVIDIA's optimized inference engine (FP16 precision, fused kernels)
- **[vLLM](https://github.com/vllm-project/vllm)** - High-throughput LLM serving framework (continuous batching, PagedAttention)
- **[Kubernetes](https://kubernetes.io/docs/)** - Container orchestration platform
- **[Helm](https://helm.sh/docs/)** - Kubernetes package manager

### Additional Resources

- **[NVIDIA AI Enterprise](https://www.nvidia.com/en-us/data-center/products/ai-enterprise/)** - Enterprise AI software platform
- **[GCP GPU Regions](https://cloud.google.com/compute/docs/gpus/gpu-regions-zones)** - GPU availability by region
- **[Llama 3 Model Card](https://huggingface.co/meta-llama/Meta-Llama-3-8B-Instruct)** - Model documentation

---

## License

Provided as-is for educational and reference purposes. NVIDIA NIM requires acceptance of NVIDIA AI Enterprise EULA.

---

**Status**: Production-ready ✅  
**Last validated**: October 2025  
**GKE version**: 1.34+  
**NIM version**: 1.0.0
