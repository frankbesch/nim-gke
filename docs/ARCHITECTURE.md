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
vLLM Runtime (continuous batching, FP16)
    ↓
TensorRT-LLM Engine (optimized kernels)
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
   - Cost: $0.13/hour

2. **gpupool** (GPU workloads)
   - Machine type: g2-standard-4 (4 vCPU, 16GB RAM, 1× L4)
   - Nodes: 0-2 (autoscaling)
   - GPU driver: Latest (installed automatically)
   - Cost: $1.23/hour per node

**Autoscaling**:
- Triggered by pod resource requests (`nvidia.com/gpu: 1`)
- Scale-up latency: 3-5 minutes (node provisioning)
- Scale-down delay: 10 minutes (configurable)

---

### NIM Runtime

**Container Image**:
- Registry: `nvcr.io/nim/meta/llama3-8b-instruct`
- Tag: `1.0.0`
- Size: 6.4GB (compressed), 16GB (on disk)
- Base: Ubuntu 22.04 + CUDA 12.2

**Inference Stack**:

1. **vLLM** (serving layer)
   - Continuous batching for throughput
   - PagedAttention for memory efficiency
   - Dynamic batch size based on load

2. **TensorRT-LLM** (optimization layer)
   - FP16 precision (2× faster than FP32)
   - Fused kernels for attention/MLP
   - KV cache optimization

3. **CUDA Runtime**
   - GPU memory management
   - Kernel execution
   - Multi-stream processing

**Model**:
- Architecture: Llama 3 8B (decoder-only transformer)
- Parameters: 8 billion
- Context length: 8192 tokens
- Vocabulary: 128,000 tokens
- Quantization: FP16 (16GB weights + activations)

---

### Kubernetes Resources

#### StatefulSet

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: my-nim-nim-llm
  namespace: nim
spec:
  replicas: 1
  serviceName: my-nim-nim-llm-sts
  selector:
    matchLabels:
      app: my-nim-nim-llm
  template:
    spec:
      containers:
      - name: nim-llm
        image: nvcr.io/nim/meta/llama3-8b-instruct:1.0.0
        resources:
          limits:
            nvidia.com/gpu: 1
          requests:
            nvidia.com/gpu: 1
            memory: "8Gi"
            cpu: "2"
        volumeMounts:
        - name: model-cache
          mountPath: /opt/nim/.cache
  volumeClaimTemplates:
  - metadata:
      name: model-cache
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 50Gi
```

**Why StatefulSet**:
- Persistent volume binding (model cache survives restarts)
- Stable pod identity for debugging
- Ordered startup/shutdown for multi-replica

**GPU Resource Request**:
- `nvidia.com/gpu: 1` triggers GPU node scheduling
- Cluster autoscaler creates GPU node if none available
- Device plugin binds GPU to container

#### Service

**ClusterIP** (internal access):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-nim-nim-llm
  namespace: nim
spec:
  type: ClusterIP
  ports:
  - port: 8000
    targetPort: 8000
    protocol: TCP
  selector:
    app: my-nim-nim-llm
```

**Headless Service** (StatefulSet coordination):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-nim-nim-llm-sts
  namespace: nim
spec:
  clusterIP: None
  selector:
    app: my-nim-nim-llm
```

#### Secrets

**NGC Registry**:
```bash
kubectl create secret docker-registry registry-secret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password=$NGC_CLI_API_KEY \
  -n nim
```

**NGC API Key**:
```bash
kubectl create secret generic ngc-api \
  --from-literal=NGC_API_KEY=$NGC_CLI_API_KEY \
  -n nim
```

---

## Data Flow

### Inference Request

1. **Client** → HTTP POST `/v1/chat/completions`
2. **Port forward** → Local port 8000 → Service port 8000
3. **Service** → Load balance to pod
4. **NIM API server** → Parse request, validate
5. **vLLM scheduler** → Queue request, batch with others
6. **TensorRT-LLM** → Execute optimized kernels on GPU
7. **GPU** → Compute attention, MLP, decode tokens
8. **vLLM** → Stream tokens back (if requested)
9. **NIM API** → Format OpenAI-compatible response
10. **Client** → Receive completion

**Latency breakdown**:
- Network (port-forward): <1ms
- API parsing: <10ms
- Queue wait: 0-100ms (depends on batch)
- First token: 2-3s (prefill)
- Subsequent tokens: 50-70ms each (decode)

### Model Loading

1. **Pod starts** → Check `/opt/nim/.cache` for model
2. **If missing** → Download from NGC (16GB, 5-10 minutes)
3. **vLLM init** → Load weights to GPU memory
4. **TensorRT-LLM** → Build/load optimized engines
5. **Warmup** → Run dummy inference to compile kernels
6. **Ready** → Health probe succeeds, service traffic

**Persistent Volume**:
- Model cached on PV (survives pod restarts)
- Subsequent starts: 2-3 minutes (no download)
- Storage class: GCE persistent disk (SSD)

---

## Resource Allocation

### GPU Memory

```
Total: 24GB L4 VRAM

Breakdown:
- Model weights (FP16):     ~12GB
- KV cache (dynamic):       ~6GB  (scales with concurrent requests)
- Activation memory:        ~2GB
- CUDA context:             ~1GB
- Reserved:                 ~3GB
```

**KV Cache Sizing**:
- 1 request × 8192 ctx = ~256MB
- 24 concurrent requests = ~6GB
- vLLM automatically manages allocation

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
- Additional cost: ~$0.025/hour + traffic

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
5. Instance provisions (3-5 minutes)
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
      app: my-nim-nim-llm
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
- Trace request through API → vLLM → TensorRT
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
- Cost: $0.73/hour vs. A100 $2.93/hour
- Availability: More zones than A100/H100
- Sufficient for 8B models (24GB VRAM)

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

