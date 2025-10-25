# 🔬 Technical Deep Dive Playbook

**NVIDIA NIM on GKE | Architecture, Design Decisions, and Implementation Details**

---

## 🏗️ System Architecture

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          GCP Project                             │
│                      (your-gcp-project)                           │
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │              GKE Cluster (nim-demo)                        │ │
│  │              Region: us-central1-a                         │ │
│  │                                                            │ │
│  │  ┌──────────────────┐      ┌───────────────────────────┐ │ │
│  │  │ Control Plane    │      │ GPU Node Pool             │ │ │
│  │  │ e2-standard-4    │      │ (gpupool)                 │ │ │
│  │  │ - 4 vCPU         │      │                           │ │ │
│  │  │ - 16 GB RAM      │      │ ┌─────────────────────┐   │ │ │
│  │  │ - $0.13/hour     │      │ │ Node 1              │   │ │ │
│  │  │                  │      │ │ g2-standard-4       │   │ │ │
│  │  │ API Server       │      │ │ - 4 vCPU            │   │ │ │
│  │  │ etcd             │◀─────▶│ - 16 GB RAM         │   │ │ │
│  │  │ Scheduler        │      │ │ - NVIDIA L4 (24GB)  │   │ │ │
│  │  │ Controller Mgr   │      │ │ - $0.87/hour        │   │ │ │
│  │  └──────────────────┘      │ │                     │   │ │ │
│  │                            │ │ ┌─────────────────┐ │   │ │ │
│  │                            │ │ │ NIM Pod         │ │   │ │ │
│  │                            │ │ │                 │ │   │ │ │
│  │  Namespace: nim            │ │ │ Container:      │ │   │ │ │
│  │  ┌──────────────────┐      │ │ │ llama3-8b       │ │   │ │ │
│  │  │ Secrets          │      │ │ │ (TensorRT-LLM)  │ │   │ │ │
│  │  │ - registry-secret│─────▶│ │ │                 │ │   │ │ │
│  │  │ - ngc-api        │      │ │ │ GPU: 1x L4      │ │   │ │ │
│  │  └──────────────────┘      │ │ │ Port: 8000      │ │   │ │ │
│  │                            │ │ └─────────────────┘ │   │ │ │
│  │  ┌──────────────────┐      │ │                     │   │ │ │
│  │  │ Service          │      │ │ PersistentVolume    │   │ │ │
│  │  │ my-nim-nim-llm   │◀─────┼─│ (model cache)       │   │ │ │
│  │  │ ClusterIP: 8000  │      │ │ 50 GB               │   │ │ │
│  │  └──────────────────┘      │ └─────────────────────┘   │ │ │
│  │                            │                           │ │ │
│  │                            │ Autoscaling: 0-2 nodes    │ │ │
│  │                            └───────────────────────────┘ │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                               │
│  External Services:                                           │
│  ┌──────────────┐     ┌──────────────┐     ┌─────────────┐  │
│  │ GCP APIs     │     │ NGC Registry │     │ Helm Charts │  │
│  │ - Compute    │     │ nvcr.io      │     │ NGC Helm    │  │
│  │ - Container  │     │ (images)     │     │ Repository  │  │
│  │ - IAM        │     │              │     │             │  │
│  └──────────────┘     └──────────────┘     └─────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🔧 Component Deep Dives

### 1. GKE Cluster Configuration

**Creation Command**:
```bash
gcloud container clusters create nim-demo \
    --project=nim-on-gke \
    --location=us-central1-a \
    --release-channel=rapid \
    --machine-type=e2-standard-4 \
    --num-nodes=1 \
    --enable-autoscaling \
    --min-nodes=1 \
    --max-nodes=3 \
    --enable-autorepair \
    --enable-autoupgrade
```

**Design Decisions**:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `release-channel=rapid` | Latest Kubernetes versions | Access to newest GPU features, TensorFlow compatibility |
| `machine-type=e2-standard-4` | 4 vCPU, 16GB RAM | Right-sized for control plane + system pods |
| `enable-autoscaling` | Min 1, Max 3 | Scale control plane for high pod counts |
| `enable-autorepair` | True | Automatic node health checks and replacement |
| `enable-autoupgrade` | True | Security patches, CVE mitigation |

**Why rapid channel?**
- NVIDIA GPU drivers evolve quickly
- TensorRT-LLM benefits from latest CUDA versions
- Rapid channel gets k8s releases ~4 weeks after upstream
- Trade-off: slight stability risk for feature access

---

### 2. GPU Node Pool Configuration

**Creation Command**:
```bash
gcloud container node-pools create gpupool \
    --accelerator type=nvidia-l4,count=1,gpu-driver-version=latest \
    --project=nim-on-gke \
    --location=us-central1-a \
    --cluster=nim-demo \
    --machine-type=g2-standard-4 \
    --num-nodes=1 \
    --enable-autoscaling \
    --min-nodes=0 \
    --max-nodes=2 \
    --enable-autorepair \
    --enable-autoupgrade
```

**Critical Parameters**:

**`--accelerator` flags**:
- `type=nvidia-l4`: Specific GPU SKU (not just "GPU")
- `count=1`: GPUs per node (L4 nodes typically 1-8)
- `gpu-driver-version=latest`: Auto-installs NVIDIA drivers via DaemonSet

**`--min-nodes=0`**: 
- **Why**: Cost optimization - scale to zero when no workloads
- **Trade-off**: Cold start time (5-10 minutes to spin up node)
- **Alternative**: `min-nodes=1` for faster response, 24/7 cost

**`--max-nodes=2`**:
- **Why**: Cost ceiling ($1.74/hour max for 2x GPU nodes)
- **Consideration**: NIM LLM doesn't horizontally scale easily (model loading overhead)
- **Production**: Increase max-nodes for multi-replica deployments

---

### 3. NVIDIA Driver Installation

**How it works**:
GKE automatically installs drivers when `gpu-driver-version=latest` specified:

1. **DaemonSet**: GKE creates DaemonSet that runs on every GPU node
2. **Init Container**: Downloads and installs NVIDIA driver from GCS bucket
3. **Device Plugin**: Deploys NVIDIA Device Plugin as DaemonSet to expose GPUs to kubelet
4. **Monitoring**: Optional DCGM (Data Center GPU Manager) for metrics

**Verify installation**:
```bash
# Check device plugin is running
kubectl get pods -n kube-system | grep nvidia-gpu-device-plugin

# Check GPU is visible from pod
kubectl exec -n nim <nim-pod> -- nvidia-smi

# Expected output:
# +-----------------------------------------------------------------------------+
# | NVIDIA-SMI 535.86.10              Driver Version: 535.86.10  CUDA: 12.2    |
# |-------------------------------+----------------------+----------------------+
# | GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC |
# |   0  NVIDIA L4                Off| 00000000:00:04.0 Off |                  Off |
# +-------------------------------+----------------------+----------------------+
```

**Common Issues**:
- Driver mismatch with CUDA version in container → use `latest` for auto-matching
- Device plugin not running → check node labels and taints
- GPU not visible → verify `resources.limits.nvidia.com/gpu: 1` in pod spec

---

### 4. NIM Container Architecture

**Image**: `nvcr.io/nim/meta/llama3-8b-instruct:1.0.0`

**Container Contents**:
```
/opt/nim/
├── model/                    # Model weights and config
│   ├── model.bin            # Llama 3 8B weights (~16GB)
│   ├── config.json          # Model architecture config
│   └── tokenizer.model      # SentencePiece tokenizer
├── tensorrt_llm/            # TensorRT-LLM engine
│   ├── engine/              # Compiled TensorRT engine
│   └── plugins/             # Custom CUDA kernels
├── triton/                  # NVIDIA Triton Inference Server
│   ├── backends/            # TensorRT-LLM backend
│   └── config/              # Model config for Triton
└── api/                     # OpenAI-compatible API server
    ├── server.py            # FastAPI server
    └── schemas/             # Pydantic schemas
```

**Startup Sequence**:
1. **Download model** (if not cached): NGC downloads to `/model` (~16GB)
2. **Build TensorRT engine**: Optimizes model for L4 GPU (~2-5 minutes)
3. **Load into GPU memory**: Loads engine to VRAM (~16GB)
4. **Start Triton server**: Inference engine on port 8001
5. **Start API server**: OpenAI-compatible API on port 8000
6. **Health checks pass**: Ready for inference

**Why so slow?**
- First start: Download (10 min) + Build (5 min) + Load (2 min) = ~17 minutes
- Subsequent starts with PV: Build (cached) + Load (2 min) = ~2 minutes

---

### 5. Kubernetes Resource Configuration

**Helm Values (`nim_custom_value.yaml`)**:
```yaml
image:
  repository: "nvcr.io/nim/meta/llama3-8b-instruct"
  tag: "1.0.0"

model:
  ngcAPISecret: ngc-api  # Kubernetes secret with NGC_CLI_API_KEY

persistence:
  enabled: true           # Cache model and engine
  size: "50Gi"           # Model (~16GB) + engine (~10GB) + buffer

imagePullSecrets:
  - name: registry-secret  # NGC authentication

resources:
  requests:
    nvidia.com/gpu: 1      # Reserve 1 GPU
    memory: "8Gi"          # Model loading overhead
    cpu: "2"               # CPU for preprocessing
  limits:
    nvidia.com/gpu: 1      # Hard limit
    memory: "16Gi"         # Buffer for inference
    cpu: "4"               # Burst capacity

nodeSelector:
  cloud.google.com/gke-accelerator: nvidia-l4  # Only schedule on L4 nodes

tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule    # GPU nodes are tainted by default

livenessProbe:
  httpGet:
    path: /health
    port: 8000
  initialDelaySeconds: 300  # Model loading takes time
  periodSeconds: 30

readinessProbe:
  httpGet:
    path: /ready
    port: 8000
  initialDelaySeconds: 300
  periodSeconds: 10
```

**Key Concepts**:

**Node Selector vs Toleration**:
- **Node Selector**: Filters nodes ("only schedule on nodes with label X")
- **Toleration**: Allows scheduling despite taints ("this pod can tolerate GPU taint")
- **Why both?**: GKE taints GPU nodes to prevent non-GPU pods; node selector ensures correct GPU type

**Resource Requests vs Limits**:
- **Requests**: Guaranteed resources (scheduler considers these)
- **Limits**: Maximum resources (OOMKill if exceeded)
- **GPU Special Case**: GPU limits == GPU requests (GPUs aren't overcommitable)

---

## 🔐 Security & Authentication

### NGC Authentication Flow

**Two authentication layers**:

#### 1. Image Pull Authentication
```bash
kubectl create secret docker-registry registry-secret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \   # Literal string '$oauthtoken'
  --docker-password="${NGC_CLI_API_KEY}"
```

**Breakdown**:
- `nvcr.io`: NVIDIA's container registry
- `$oauthtoken`: Special username (literal string, not shell variable)
- Password: Your NGC API key

**Why `$oauthtoken`?**
NGC uses OAuth2 token authentication. The literal string `$oauthtoken` signals "treat password as OAuth token." This is Docker registry convention, not NVIDIA-specific.

#### 2. Runtime Authentication
```bash
kubectl create secret generic ngc-api \
  --from-literal=NGC_CLI_API_KEY="${NGC_CLI_API_KEY}"
```

**Used for**:
- Downloading models from NGC (if not in container)
- Telemetry (optional)
- License validation (for enterprise NIM)

---

### Secrets Management Best Practices

**Current Implementation (MVP)**:
```bash
export NGC_CLI_API_KEY='...'  # Environment variable
# Used in scripts to create k8s secrets
```

**Production Improvements**:

1. **GCP Secret Manager**:
```bash
# Store secret
gcloud secrets create ngc-api-key --data-file=- <<< "$NGC_CLI_API_KEY"

# Grant access to GKE service account
gcloud secrets add-iam-policy-binding ngc-api-key \
  --member="serviceAccount:nim-sa@your-gcp-project.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# Use Workload Identity to access from pod
```

2. **External Secrets Operator**:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ngc-api
spec:
  secretStoreRef:
    name: gcpsm-secret-store
    kind: SecretStore
  target:
    name: ngc-api
  data:
  - secretKey: NGC_CLI_API_KEY
    remoteRef:
      key: ngc-api-key
```

3. **Sealed Secrets** (for GitOps):
```bash
# Encrypt secret
kubeseal --format yaml < secret.yaml > sealed-secret.yaml

# Commit to git (encrypted)
git add sealed-secret.yaml

# SealedSecret controller decrypts in-cluster
```

---

## 📊 Resource Sizing & Performance

### Workload Profiling Results

**Inference Characteristics**:
```
Model: Llama 3 8B Instruct
Precision: FP16 (TensorRT)
Context Length: 8192 tokens
Batch Size: 1 (default)

GPU Utilization: 80-95% (inference)
GPU Memory: 16GB / 24GB (67%)
CPU Utilization: 15-25% (4 vCPUs)
System Memory: 8-12GB / 16GB
Throughput: ~50 tokens/second
Latency (p50): ~200ms
Latency (p99): ~500ms
```

**Key Insight**: This is a GPU-bound workload. CPU does:
- Tokenization (fast, CPU-based)
- Preprocessing (minimal)
- Postprocessing (minimal)
- API serving (lightweight FastAPI)

Heavy lifting (matrix multiplication, attention) happens on GPU via TensorRT.

---

### Cost Optimization Analysis

**Original Configuration** (Google Codelabs):
```
Machine Type: g2-standard-16
- 16 vCPU
- 64 GB RAM
- Cost: $1.28/hour
- GPU: NVIDIA L4 ($0.73/hour)
- Total: $2.01/hour

Monthly (24/7): $1,447/month
```

**Optimized Configuration**:
```
Machine Type: g2-standard-4
- 4 vCPU
- 16 GB RAM
- Cost: $0.50/hour
- GPU: NVIDIA L4 ($0.73/hour)
- Total: $1.23/hour

Monthly (24/7): $885/month
Savings: $562/month (39%)
```

**With Autoscaling (0 nodes when idle)**:
```
Idle: $0/hour (control plane is shared GKE cost)
Active: $1.23/hour
Average (50% utilization): $442/month
```

---

### GPU Selection Matrix

| GPU | VRAM | FP16 TFLOPS | Cost/Hour | Use Case |
|-----|------|-------------|-----------|----------|
| **L4** | 24 GB | 30.3 | $0.73 | Inference (cost-optimized) |
| **A10G** | 24 GB | 35.6 | $0.86 | Inference (AWS-specific) |
| **T4** | 16 GB | 8.1 | $0.35 | Inference (small models) |
| **A100** | 40 GB | 312 | $2.48 | Training, large batches |
| **H100** | 80 GB | 2000 | $7.50 | Training, research |

**Why L4 for NIM?**
1. **Sufficient VRAM**: 24GB > 16GB model + overhead
2. **Modern Architecture**: Ada Lovelace (2022) vs Turing T4 (2018)
3. **Cost-Effective**: 4x cheaper than A100
4. **Availability**: Better quota allocation in GCP regions
5. **Power Efficiency**: 72W TDP vs T4 70W but 4x performance

**When to use A100/H100?**
- Llama 3 70B or larger models (need >24GB VRAM)
- High-throughput batch inference (>10 concurrent requests)
- Fine-tuning workloads
- Research with frequent model changes

---

## 🔬 Autoscaling Deep Dive

### Node-Level Autoscaling (Cluster Autoscaler)

**Configuration**:
```bash
--enable-autoscaling \
--min-nodes=0 \
--max-nodes=2
```

**How it works**:
1. **Scale Up Trigger**: Pod in "Pending" state due to insufficient resources
2. **Evaluation**: Cluster Autoscaler checks pending pods every 10 seconds
3. **Decision**: Calculate minimum nodes needed to schedule pending pods
4. **Action**: Add nodes to node pool (GCP API call)
5. **Duration**: 5-10 minutes (GCE VM provision + driver install + kubelet ready)

**Scale Down Trigger**:
1. **Low Utilization**: Node utilization <50% for >10 minutes
2. **All Pods Movable**: No local storage, no standalone pods
3. **Graceful Drain**: Evict pods, wait for termination
4. **Remove Node**: Delete GCE VM
5. **Duration**: 2-5 minutes

**Why min-nodes=0?**
- GPU nodes cost $1.23/hour - expensive to keep idle
- Cold start penalty acceptable for dev/test workloads
- Production: set `min-nodes=1` for faster response

---

### Pod-Level Autoscaling (Horizontal Pod Autoscaler)

**Configuration** (not implemented in MVP, but recommended for production):
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: nim-hpa
  namespace: nim
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-nim-nim-llm
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Pods
    pods:
      metric:
        name: gpu_utilization
      target:
        type: AverageValue
        averageValue: "80"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 100
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Pods
        value: 1
        periodSeconds: 60
```

**Key Metrics**:
- **CPU Utilization**: 70% threshold (scale up if exceeded)
- **GPU Utilization**: 80% threshold (requires DCGM exporter)
- **Custom Metric**: Request rate (requests/second via Prometheus)

**Why not implement in MVP?**
- Single-user development: don't need horizontal scaling
- Model loading overhead: each new replica takes 2-5 minutes
- Cost consideration: Each replica = $1.23/hour
- Production requirement, not dev requirement

---

## 🛠️ Troubleshooting Playbook

### Issue: Pod Stuck in "Pending"

**Symptoms**:
```bash
$ kubectl get pods -n nim
NAME                              READY   STATUS    RESTARTS   AGE
my-nim-nim-llm-7d9c8f5b6b-abcde   0/1     Pending   0          5m
```

**Diagnosis**:
```bash
kubectl describe pod -n nim <pod-name>
```

**Common Causes & Fixes**:

1. **Insufficient GPU Resources**
```
Events:
  Warning  FailedScheduling  5m  default-scheduler  0/2 nodes available: 2 Insufficient nvidia.com/gpu
```
**Fix**: GPU node pool not created or quota exceeded
```bash
# Check GPU nodes exist
kubectl get nodes -l cloud.google.com/gke-accelerator=nvidia-l4

# Check quota
gcloud compute regions describe us-central1 | grep NVIDIA_L4
```

2. **Missing Toleration**
```
Events:
  Warning  FailedScheduling  5m  default-scheduler  0/2 nodes available: 2 node(s) had untolerated taint {nvidia.com/gpu: }
```
**Fix**: Add toleration to Helm values (see section 5)

3. **Image Pull Errors**
```
Events:
  Warning  Failed  5m  kubelet  Failed to pull image "nvcr.io/nim/meta/llama3-8b-instruct:1.0.0": rpc error: code = Unknown desc = failed to pull and unpack image: failed to resolve reference
```
**Fix**: NGC authentication failed
```bash
# Verify secret exists
kubectl get secret registry-secret -n nim

# Check NGC API key
echo $NGC_CLI_API_KEY

# Recreate secret
kubectl delete secret registry-secret -n nim
kubectl create secret docker-registry registry-secret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password="$NGC_CLI_API_KEY" \
  -n nim
```

---

### Issue: Pod Stuck in "ContainerCreating"

**Symptoms**:
```bash
NAME                              READY   STATUS              RESTARTS   AGE
my-nim-nim-llm-7d9c8f5b6b-abcde   0/1     ContainerCreating   0          10m
```

**Diagnosis**:
```bash
kubectl describe pod -n nim <pod-name>
```

**Common Causes**:

1. **PersistentVolume Provisioning**
```
Events:
  Normal   SuccessfulAttachVolume  8m   attachdetach-controller  AttachVolume.Attach succeeded for volume "pvc-abc123"
```
**Normal Behavior**: GCE PD provisioning takes 2-3 minutes

2. **NGC Model Download**
```
Events:
  Normal   Pulling  10m  kubelet  Pulling image "nvcr.io/nim/meta/llama3-8b-instruct:1.0.0"
```
**Normal Behavior**: Image is 20GB+ (model + runtime), takes 10-15 minutes

**How to Monitor**:
```bash
# Check node events
kubectl get events -n nim --sort-by='.lastTimestamp' | tail -20

# Check container logs (once started)
kubectl logs -n nim <pod-name> --follow
```

---

### Issue: Pod Running but Not Ready

**Symptoms**:
```bash
NAME                              READY   STATUS    RESTARTS   AGE
my-nim-nim-llm-7d9c8f5b6b-abcde   0/1     Running   0          15m
```

**Diagnosis**:
```bash
kubectl logs -n nim <pod-name> --tail=100
```

**Common Causes**:

1. **Model Building TensorRT Engine**
```
[TensorRT-LLM] Building engine for llama3-8b-instruct...
[TensorRT-LLM] Optimizing layers: 32/32
[TensorRT-LLM] Calibrating kernels: 1024/2048
```
**Normal Behavior**: First start builds optimized engine (~5 minutes)

2. **Loading Model to GPU Memory**
```
[Triton] Loading model 'llama3-8b-instruct' version 1
[Triton] Model loaded successfully. Total time: 120s
```
**Normal Behavior**: Loads 16GB model to VRAM (~2 minutes)

3. **Readiness Probe Failing**
```
Events:
  Warning  Unhealthy  2m (x10 over 5m)  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 503
```
**Fix**: Increase `initialDelaySeconds` in readiness probe (see section 5)

---

### Issue: Poor Inference Performance

**Symptoms**:
- High latency (>1 second per request)
- Low throughput (<10 tokens/second)
- GPU utilization <50%

**Diagnosis**:
```bash
# Check GPU utilization
kubectl exec -n nim <pod-name> -- nvidia-smi dmon -s u -c 10

# Check pod resources
kubectl top pod -n nim

# Check API response times
time curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Hi"}],"model":"meta/llama3-8b-instruct","max_tokens":10}'
```

**Common Causes & Fixes**:

1. **CPU Throttling**
```bash
# Check CPU limits
kubectl describe pod -n nim <pod-name> | grep -A 5 "Limits"
```
**Fix**: Increase CPU limits in Helm values

2. **Memory Pressure**
```bash
# Check memory usage
kubectl top pod -n nim
```
**Fix**: Increase memory limits (model needs 16GB + overhead)

3. **Multiple Concurrent Requests**
NIM processes requests sequentially per pod. High concurrency queues requests.
**Fix**: Scale horizontally (HPA) or increase batch size

4. **Cold TensorRT Engine**
First few requests may be slower as TensorRT optimizes.
**Normal**: Performance stabilizes after ~10-20 requests

---

## 🎯 Production Readiness Checklist

### Infrastructure

- [ ] **Multi-AZ Deployment**: Spread nodes across zones for HA
  ```bash
  --node-locations=us-central1-a,us-central1-b,us-central1-c
  ```

- [ ] **Private GKE Cluster**: Control plane not publicly accessible
  ```bash
  --enable-private-nodes --enable-private-endpoint
  --master-ipv4-cidr=172.16.0.0/28
  ```

- [ ] **Network Policies**: Pod-to-pod traffic control
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: nim-network-policy
  spec:
    podSelector: {}
    policyTypes:
    - Ingress
    - Egress
  ```

- [ ] **Pod Security Standards**: Enforce restrictive policies
  ```yaml
  apiVersion: v1
  kind: Namespace
  metadata:
    name: nim
    labels:
      pod-security.kubernetes.io/enforce: restricted
  ```

---

### Observability

- [ ] **Prometheus Metrics**: GPU utilization, request rates, latencies
- [ ] **Grafana Dashboards**: Visualize GPU metrics, model performance
- [ ] **Distributed Tracing**: Jaeger/Tempo for request flows
- [ ] **Structured Logging**: JSON logs to Cloud Logging
- [ ] **Alerting**: PagerDuty/Opsgenie integration for critical events

**NVIDIA DCGM Exporter** (GPU metrics):
```bash
kubectl create -f https://raw.githubusercontent.com/NVIDIA/dcgm-exporter/main/dcgm-exporter.yaml
```

**Metrics to Track**:
- `DCGM_FI_DEV_GPU_UTIL`: GPU utilization (target: 70-90%)
- `DCGM_FI_DEV_MEM_COPY_UTIL`: Memory bandwidth (bottleneck detection)
- `DCGM_FI_DEV_GPU_TEMP`: Temperature (thermal throttling detection)
- `nim_request_duration_seconds`: API latency (p50, p95, p99)
- `nim_requests_total`: Request rate (QPS)

---

### Security

- [ ] **Workload Identity**: Pod-to-GCP authentication without keys
  ```bash
  gcloud iam service-accounts add-iam-policy-binding \
    nim-sa@your-gcp-project.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:YOUR_PROJECT_ID.svc.id.goog[nim/nim-sa]"
  ```

- [ ] **Secret Rotation**: Automated NGC API key rotation
- [ ] **Binary Authorization**: Only deploy signed container images
- [ ] **Vulnerability Scanning**: Container scanning (GCP Container Analysis)
- [ ] **Network Policies**: Restrict pod-to-pod and pod-to-external traffic
- [ ] **Audit Logging**: Enable GKE audit logs (Cloud Logging)

---

### Disaster Recovery

- [ ] **Backup Strategy**: Velero for cluster backups
  ```bash
  velero install --provider gcp --bucket nim-backups \
    --secret-file ./credentials-velero
  ```

- [ ] **RTO/RPO Targets**: Define and test
  - RTO (Recovery Time Objective): <1 hour
  - RPO (Recovery Point Objective): <15 minutes

- [ ] **Multi-Region Failover**: Cross-region replication
- [ ] **Disaster Recovery Runbook**: Documented recovery procedures
- [ ] **Chaos Engineering**: Simulate failures (node loss, network partition)

---

### Cost Optimization

- [ ] **Committed Use Discounts**: 1-3 year reservations (30-50% savings)
- [ ] **Spot/Preemptible Nodes**: For non-critical workloads (up to 91% savings)
- [ ] **Right-Sizing**: Adjust resources based on actual usage
- [ ] **Autoscaling Policies**: Fine-tune scale-up/down triggers
- [ ] **FinOps Dashboards**: Cost allocation by team, project, environment
- [ ] **Budgets & Alerts**: GCP budget alerts for overspend detection

---

## 🚀 Advanced Patterns

### Blue/Green Deployment

**Goal**: Zero-downtime model updates

**Strategy**:
1. Deploy new model version to new node pool ("green")
2. Test green environment with canary traffic
3. Switch traffic from "blue" to "green"
4. Drain and delete blue node pool

**Implementation**:
```bash
# Create green node pool
gcloud container node-pools create gpupool-v2 \
  --cluster=nim-demo --zone=us-central1-a \
  --machine-type=g2-standard-4 \
  --accelerator type=nvidia-l4,count=1 \
  --num-nodes=1

# Deploy NIM v2 with node selector
kubectl apply -f nim-v2-deployment.yaml

# Test green environment
curl http://green-nim-service:8000/v1/models

# Switch traffic (update service selector)
kubectl patch service my-nim-nim-llm -n nim -p \
  '{"spec":{"selector":{"version":"v2"}}}'

# Delete blue node pool
gcloud container node-pools delete gpupool --cluster=nim-demo --zone=us-central1-a
```

---

### Canary Release

**Goal**: Gradually shift traffic to new version

**Strategy**: Use Istio or native k8s weighted routing

**Implementation** (native k8s):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nim-canary
spec:
  selector:
    app: nim
  ports:
  - port: 8000
---
# Deployment v1 (90% traffic)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nim-v1
spec:
  replicas: 9  # 90% of traffic
  template:
    metadata:
      labels:
        app: nim
        version: v1
---
# Deployment v2 (10% traffic)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nim-v2
spec:
  replicas: 1  # 10% of traffic
  template:
    metadata:
      labels:
        app: nim
        version: v2
```

**Monitor canary**:
- Error rate (v2 should be ≤ v1)
- Latency (p95, p99)
- GPU utilization
- User feedback

**Rollback** (if canary fails):
```bash
kubectl scale deployment nim-v2 --replicas=0
```

---

### Multi-Model Serving

**Goal**: Serve multiple models on same GPU

**Strategy**: Use NVIDIA Triton's multi-model support

**Why**: GPU is expensive; maximize utilization

**Implementation**:
```yaml
# Triton config
triton:
  models:
    - name: llama3-8b
      version: 1
      platform: tensorrt_llm
      max_batch_size: 8
    - name: llama3-8b-chat
      version: 1
      platform: tensorrt_llm
      max_batch_size: 4
  dynamic_batching:
    max_queue_delay_microseconds: 100000
```

**Trade-offs**:
- ✅ Better GPU utilization
- ✅ Lower cost per model
- ❌ Shared VRAM (models must fit together)
- ❌ Context switching overhead

---

## 📚 References & Resources

### Official Documentation
- [NVIDIA NIM Documentation](https://docs.nvidia.com/nim/)
- [GKE GPU Guide](https://cloud.google.com/kubernetes-engine/docs/how-to/gpus)
- [TensorRT-LLM](https://github.com/NVIDIA/TensorRT-LLM)
- [NVIDIA Triton Inference Server](https://github.com/triton-inference-server/server)

### Tools & Libraries
- [DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter) - GPU metrics for Prometheus
- [nvidia-smi](https://developer.nvidia.com/nvidia-system-management-interface) - GPU monitoring CLI
- [Velero](https://velero.io/) - Kubernetes backup/restore
- [Helm](https://helm.sh/) - Kubernetes package manager

### Community Resources
- [NVIDIA Developer Forums](https://forums.developer.nvidia.com/)
- [NGC Catalog](https://catalog.ngc.nvidia.com/) - Pre-trained models and containers
- [NVIDIA AI Enterprise](https://www.nvidia.com/en-us/data-center/products/ai-enterprise/)

---

**Version**: 1.0  
**Author**: Frank Besch  
**Purpose**: Technical deep dive for NVIDIA interview preparation  
**Last Updated**: October 25, 2025

