# NIM-GKE Architecture

Technical reference for GPU-accelerated inference on GKE.

---

## System Overview

```
User Request
    ↓
Port Forward (localhost:8000)
    ↓
ClusterIP Service (my-nim-nim-llm:8000)
    ↓
StatefulSet (my-nim-nim-llm-0)
    ↓
NIM Container (nvcr.io/nim/meta/llama3-8b-instruct:1.0.0)
    ↓
Inference backend (TensorRT-LLM or vLLM profile, chosen by NIM at startup)
    ↓
NVIDIA L4 GPU (24GB VRAM, Tensor Cores)
```

---

## Components

### GKE Cluster

**Control Plane**:
- Managed by Google (zonal deployment)
- Version: 1.34.0+
- Release channel: Rapid

**Node Pools**:

1. **default-pool** (control plane workloads)
   - Machine type: e2-standard-4 (4 vCPU, 16GB RAM)
   - Nodes: 1 (fixed)
   - Cost: see [README cost table](../README.md#cost-and-performance)

2. **gpupool** (GPU workloads)
   - Machine type: g2-standard-4 (4 vCPU, 16GB RAM, 1× L4)
   - Nodes: 0-2 (autoscaling)
   - GPU driver: Latest (installed automatically)
   - Cost: see [README cost table](../README.md#cost-and-performance) and
     [runs/2026-09-27-measured-run.md](runs/2026-09-27-measured-run.md)

**Autoscaling**:
- Triggered by pod resource requests (`nvidia.com/gpu: 1`)
- Scale-up latency: not measured (the measured run's GPU node pool took 1 m 02 s to create)
- Scale-down delay: 10 minutes (configurable)

---

### NIM Runtime

**Container Image**:
- Registry: `nvcr.io/nim/meta/llama3-8b-instruct`
- Tag: `1.0.0`

**Inference backend**: NIM picks a backend profile (TensorRT-LLM or vLLM) at startup for the detected GPU; which profile ran on the L4 in the measured run was not recorded.
Profile selection is visible in the pod log at startup
(`kubectl logs my-nim-nim-llm-0 -n nim | grep -i profile`).

**Model**: Llama 3 8B Instruct (decoder-only transformer, 8B parameters,
8,192-token context). Precision depends on the selected profile.

---

### Kubernetes Resources

Facts below come from `helm template my-nim` on chart `nim-llm-1.3.0` with this
repo's values; render it yourself to see full manifests.

| Resource | Name | Notes |
|---|---|---|
| StatefulSet | `my-nim-nim-llm` | 1 replica; pod `my-nim-nim-llm-0`; label `app.kubernetes.io/name: nim-llm` |
| Service (ClusterIP) | `my-nim-nim-llm` | port 8000; target of `kubectl port-forward` |
| Service (headless) | `my-nim-nim-llm-sts` | `clusterIP: None`; StatefulSet identity |
| Volume | `model-store` | mounted at `/model-store`; PVC from `volumeClaimTemplates`, retained when the pod is deleted (cleanup.sh deletes it) |
| Probes | `/v1/health/live`, `/v1/health/ready` | liveness, readiness, and startup |
| ConfigMap | `my-nim-nim-llm-scripts-configmap` | chart helper scripts, mounted at `/scripts` |

#### Secrets

Two secrets in namespace `nim`, both created by `ngc_apply_secrets` in
`scripts/config.env` so the key never appears on a command line:

- `registry-secret` (type `kubernetes.io/dockerconfigjson`): pulls images from
  `nvcr.io` as user `$oauthtoken`.
- `ngc-api`: holds key `NGC_API_KEY`, the name the nim-llm chart reads.

---

## Data Flow

### Inference Request

1. **Client** → HTTP POST `/v1/chat/completions`
2. **Port forward** → Local port 8000 → Service port 8000
3. **Service** → Load balance to pod
4. **NIM API server** → Parse request, validate
5. **Backend scheduler** → Queue request, batch with others
6. **Backend engine** → Execute kernels on the GPU
7. **GPU** → Compute attention, MLP, decode tokens
8. **NIM API** → Stream tokens back (if requested)
9. **NIM API** → Format OpenAI-compatible response
10. **Client** → Receive completion

**Measured latency** (single stream, port-forward, one L4): see
[runs/2026-09-27-measured-run.md](runs/2026-09-27-measured-run.md) — p50
11.1s / p95 16.0s end-to-end, p50 time-to-first-token 0.29s, p50 output
throughput 15.9 tokens/s. These are n=20 and n=5 samples, not a load test.

### Model Loading

1. **Pod starts** → Check the `model-store` volume for the model
2. **If missing** → Download from NGC (measured: 8 m 39 s from container start to Ready)
3. **Profile selection** → NIM picks a backend profile for the GPU
4. **Backend init** → Load weights to GPU memory
5. **Warmup** → Run dummy inference to compile kernels
6. **Ready** → Health probe succeeds, service traffic

**Persistent Volume**:
- Model cached on PV (survives pod restarts)
- Subsequent starts: faster (no download); not measured
- Storage class: GCE persistent disk (SSD)

---

## Resource Allocation

### GPU Memory

```
Total: 24GB L4 VRAM

Breakdown: not measured. Model weights take most of the memory; the KV
cache uses the rest and scales with concurrent requests.
```

**KV Cache Sizing**:
- 1 request × 8192 ctx = ~256MB
- 24 concurrent requests = ~6GB
- The inference backend manages allocation

### Node Resources

**g2-standard-4**:
```
Total:
- vCPU: 4 cores
- Memory: 16GB
- GPU: 1× L4 (24GB)

Allocatable (after system overhead):
- vCPU: ~3.9 cores
- Memory: ~14.5GB
- GPU: 1

NIM pod requests:
- vCPU: 2 cores
- Memory: 8GB
- GPU: 1

Remaining capacity:
- vCPU: 1.9 cores (DaemonSets, monitoring)
- Memory: 6.5GB
```

---

## Networking

### Internal Communication

```
Pod (10.88.X.X)
  ↓
Service (ClusterIP: 34.118.X.X)
  ↓
kube-proxy (iptables rules)
  ↓
Pod IP
```

**Service Discovery**:
- DNS: `my-nim-nim-llm.nim.svc.cluster.local`
- Resolves to ClusterIP
- kube-proxy forwards to pod IP

### External Access (Development)

**Port Forward**:
```bash
kubectl port-forward service/my-nim-nim-llm 8000:8000 -n nim
```

Creates tunnel:
```
localhost:8000 → kubectl proxy → API server → Node → Pod:8000
```

**Production alternative**: Ingress + LoadBalancer
- Terminate TLS at Ingress
- Cloud Load Balancer for HA
- Additional cost: unmeasured; see [README cost table](../README.md#cost-and-performance)

---

## Autoscaling Mechanics

### Cluster Autoscaler

**Trigger conditions**:
1. Pod has pending state
2. Reason: `Insufficient nvidia.com/gpu`
3. No existing node can fit pod

**Scale-up flow**:
1. Autoscaler detects unschedulable pod
2. Evaluates node pool configurations
3. Chooses pool with matching resources (gpupool)
4. Calls GCE API to create instance
5. Instance provisions (not measured for autoscaling)
6. Node joins cluster
7. GPU device plugin advertises resources
8. Scheduler binds pod to node

**Scale-down flow**:
1. Node underutilized for 10+ minutes
2. All pods can reschedule elsewhere
3. Autoscaler cordons node
4. Drains pods gracefully
5. Deletes GCE instance
6. Cost stops immediately

**Protection**:
- System pods block scale-down
- PodDisruptionBudgets enforced
- Local storage pods pinned to node

---

## Security Model

### Authentication

**NGC Registry**:
- Auth type: OAuth2 token
- Token stored in: `registry-secret` (Kubernetes Secret)
- Used by: kubelet for image pull

**API Access**:
- No auth by default (ClusterIP internal)
- Production: Add API gateway (Kong, Ambassador)
- Auth methods: API keys, JWT, OAuth2

### Authorization

**GCP IAM**:
- `container.admin`: Deploy/manage clusters
- `compute.admin`: Provision GPU nodes
- `iam.serviceAccountUser`: Attach service accounts

**Kubernetes RBAC**:
- `system:authenticated`: Default for kubectl
- Namespace isolation: `nim` namespace

### Network Policy (Optional)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: nim-netpol
  namespace: nim
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: nim-llm
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: nim
    ports:
    - protocol: TCP
      port: 8000
  egress:
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 443  # NGC, model downloads
```

---

## Observability

### Metrics (Built-in)

**NIM metrics endpoint**: `http://localhost:8000/metrics`

Key metrics:
- `nim_requests_total`: Request count
- `nim_request_duration_seconds`: Latency histogram
- `nim_active_requests`: Concurrent requests
- `nim_tokens_generated_total`: Output tokens

**GPU metrics**:
```bash
kubectl exec -n nim my-nim-nim-llm-0 -- nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv
```

### Logging

**Container logs**:
```bash
kubectl logs -f my-nim-nim-llm-0 -n nim
```

**Log levels**:
- `INFO`: Normal operation
- `WARNING`: Recoverable issues
- `ERROR`: Request failures

**Structured logs** (JSON):
```json
{
  "level": "INFO",
  "time": "2025-10-25 20:03:56.682",
  "message": "Service is ready",
  "model": "meta/llama3-8b-instruct"
}
```

### Tracing (Future)

Integrate OpenTelemetry:
- Trace request through API → backend → GPU
- Identify bottlenecks (queuing vs. compute)
- Export to Cloud Trace or Jaeger

---

## Design Decisions

### Why StatefulSet vs. Deployment?

**StatefulSet chosen**:
- Persistent volume binding (model cache)
- Stable network identity for debugging
- Ordered scaling (important for multi-GPU later)

**Deployment would work** if ephemeral storage acceptable (slower restarts).

### Why L4 GPU?

**L4 advantages**:
- Cost: see [README cost table](../README.md#cost-and-performance) for the measured L4 rate;
  A100 rate not measured here
- Availability: More zones than A100/H100
- Sufficient for 8B models (24GB VRAM)

**Support matrix note**: L4 is off NVIDIA's current published support matrix
for this model family
(https://docs.nvidia.com/nim/large-language-models/latest/reference/support-matrix.html).
It ran and was measured working in this repo's one end-to-end run; see
[runs/2026-09-27-measured-run.md](runs/2026-09-27-measured-run.md).

**A100 needed for**:
- Models >30B parameters
- Higher throughput requirements
- Multi-GPU tensor parallelism

### Why Zonal vs. Regional Cluster?

**Zonal chosen** (us-central1-a):
- Lower cost (no cross-zone traffic)
- Simpler for single-node GPU pool
- Acceptable for development/sandbox

**Regional recommended for**:
- Production workloads (HA)
- Multi-zone GPU pools
- SLA requirements

---

## Limitations

1. **Single GPU**: Tensor parallelism requires multi-GPU nodes + code changes
2. **No autoscaling replicas**: StatefulSet replicas managed manually
3. **FP16 only**: INT8 quantization requires different engine
4. **OpenAI API subset**: Not all parameters supported (e.g., function calling)
5. **Zone-specific**: L4 availability varies by zone

---

## Future Enhancements

1. **Horizontal Pod Autoscaling**: Scale replicas based on request rate
2. **Ingress + TLS**: Production-grade external access
3. **Prometheus + Grafana**: Metrics dashboards
4. **ArgoCD**: GitOps deployment
5. **Terraform**: IaC for cluster provisioning
6. **Multi-model**: Deploy multiple models on shared GPU pool

---

**Last updated**: October 2025  
**Architecture version**: 1.0

