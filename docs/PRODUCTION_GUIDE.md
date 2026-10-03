# NVIDIA NIM on GKE - Production Guide

## Deployment Strategy

Based on the [official Google Codelabs tutorial](https://codelabs.developers.google.com/codelabs/nvidia-nim-google-cloud).

**Status**: `deploy_nim_production.sh` (autoscaling GPU pool, 0-2 nodes) is
unmeasured. The one measured end-to-end run used
`scripts/deploy_nim_gke.sh` with a fixed 1-node GPU pool; see
[docs/runs/2026-09-27-run-1-fixed.md](runs/2026-09-27-run-1-fixed.md) for
the only verified timings, latency, and cost. Treat every figure in this
guide that is not sourced from that receipt as a plan, not a result.

---

## Scripts Overview

| Script | Purpose | Status |
|--------|---------|-------------------|
| **`setup_environment.sh`** | Environment validation | Checks tools, auth, quotas |
| **`deploy_nim_production.sh`** | Autoscaling deployment | Unmeasured; not the receipt run |
| **`test_nim_production.sh`** | Load/perf testing | Unmeasured |
| **`cleanup.sh`** | Resource cleanup | Deletes cluster/node pool/PVC |

All scripts source `scripts/config.env`. `PROJECT_ID` is required there with
no default; scripts no longer call `gcloud config set project`.

---

## Deployment Steps

Not measured end to end. For the one measured deploy, smoke, and destroy
cycle, use `scripts/deploy_nim_gke.sh` and see the receipt linked above.

```bash
# 1. From the repo root: set up and
#    validate tools, auth, APIs,
#    quotas, the NGC key, network.
./scripts/setup_environment.sh

# 2. Deploy. Bills from here. GPU pool
#    autoscales 0-2 nodes; the system
#    pool keeps at least 1 node.
./scripts/deploy_nim_production.sh

# 3. Forward the port in the
#    background, then run the tests.
kubectl port-forward -n nim \
  service/my-nim-nim-llm 8000:8000 &
PF=$!; sleep 3
./scripts/test_nim_production.sh
kill "$PF"
```

**Step 3 runs:**
- ✅ Health checks
- ✅ API endpoint testing
- ✅ Chat completion testing
- ✅ Performance benchmarking
- ✅ Load testing (5 concurrent requests)
- ✅ Resource monitoring
- ✅ Generates test report

---

## **Production Optimizations**

### **1. Fault Tolerance**
```bash
# Autoscaling enabled
--enable-autoscaling --min-nodes=0 --max-nodes=2

# Auto-repair and auto-upgrade
--enable-autorepair --enable-autoupgrade

# Health checks and readiness probes (workload is a StatefulSet, not a Deployment)
kubectl rollout status statefulset/my-nim-nim-llm -n nim
```

### **2. Resource Optimization**
```yaml
# GPU node selector and tolerations
nodeSelector:
  cloud.google.com/gke-accelerator: nvidia-l4
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule

# Resource limits
resources:
  requests:
    nvidia.com/gpu: 1
  limits:
    nvidia.com/gpu: 1
```

### **3. Cost Optimization**
- **g2-standard-4** instead of g2-standard-16 (44% cost reduction)
- **Autoscaling** (0 nodes when not in use)
- **Preemptible nodes** option available
- **Spot instances** for non-critical workloads

---

## **Production Monitoring**

### **Real-time Monitoring**
```bash
# Watch pod status
kubectl get pods -n nim -w

# Monitor resource usage
kubectl top pod -n nim

# View logs
kubectl logs -f -n nim $(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}')

# Check GPU usage
kubectl describe node | grep -A 5 "nvidia.com/gpu"
```

### **Scaling Operations**
```bash
# Scale up for high load
kubectl scale statefulset my-nim-nim-llm --replicas=3 -n nim

# Scale down for cost savings
kubectl scale statefulset my-nim-nim-llm --replicas=1 -n nim

# Scale node pool
gcloud container node-pools resize gpupool --cluster=nim-demo --zone=us-central1-a --num-nodes=2
```

---

## Cost Management

See the single cost table in [README cost table](../README.md#measured-results) and the
measured run's cost breakdown in
[docs/runs/2026-09-27-run-1-fixed.md](runs/2026-09-27-run-1-fixed.md).
This production configuration (autoscaling 0-2 GPU nodes) has not been run
or costed; only the fixed 1-node deployment in the receipt is measured.

### **Cost Optimization Strategies**
1. **Autoscaling** - Scales to 0 when not in use
2. **Spot Instances** - Up to 91% cost reduction
3. **Preemptible Nodes** - Up to 80% cost reduction
4. **Committed Use** - Long-term discounts

---

## **Security Best Practices**

### **Implemented Security**
- ✅ **API Keys** protected by .gitignore
- ✅ **Kubernetes secrets** for sensitive data
- ✅ **Service accounts** with minimal permissions
- ✅ **Network policies** (can be added)
- ✅ **RBAC** configured

### **Additional Security (Optional)**
```bash
# Enable network policies
gcloud container clusters update nim-demo --enable-network-policy --zone=us-central1-a

# Create network policy
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: nim-network-policy
  namespace: nim
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
```

---

## **Troubleshooting Guide**

### **Common Issues & Solutions**

#### **1. Pod Stuck in Pending**
```bash
# Check node resources
kubectl describe nodes

# Check GPU availability
kubectl get nodes -o wide | grep gpu

# Check quotas
gcloud compute regions describe us-central1 | grep GPU
```

#### **2. Image Pull Errors**
```bash
# Verify NGC API key
echo $NGC_API_KEY

# Check secrets
kubectl get secrets -n nim

# Recreate secrets
kubectl delete secret registry-secret ngc-api -n nim
# Then re-run deployment
```

#### **3. Performance Issues**
```bash
# Check resource usage
kubectl top pod -n nim

# Check GPU utilization
kubectl exec -n nim $(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}') -- nvidia-smi

# Scale up if needed
kubectl scale statefulset my-nim-nim-llm --replicas=2 -n nim
```

---

## **Performance Tuning**

### **Optimization Settings**
```yaml
# In nim_custom_value.yaml
resources:
  requests:
    nvidia.com/gpu: 1
    memory: "8Gi"
    cpu: "2"
  limits:
    nvidia.com/gpu: 1
    memory: "16Gi"
    cpu: "4"

# Enable GPU memory optimization
env:
  - name: CUDA_VISIBLE_DEVICES
    value: "0"
  - name: NVIDIA_VISIBLE_DEVICES
    value: "all"
```

### **Scaling Recommendations**
- **Light load**: 1 replica, g2-standard-4
- **Medium load**: 2 replicas, g2-standard-8
- **Heavy load**: 3+ replicas, g2-standard-16

---

## **Production Checklist**

### **Pre-Deployment**
- [ ] ✅ Environment validated (`./scripts/setup_environment.sh`)
- [ ] ✅ Quotas approved (CPU, GPU)
- [ ] ✅ Billing enabled
- [ ] ✅ NGC API key configured

### **Deployment**
- [ ] ✅ Cluster created with autoscaling
- [ ] ✅ GPU node pool ready
- [ ] ✅ NIM deployed successfully
- [ ] ✅ Health checks passing

### **Post-Deployment**
- [ ] ✅ Production tests passing
- [ ] ✅ Monitoring configured
- [ ] ✅ Scaling policies set
- [ ] ✅ Backup strategy planned

---

## **Quick Start Commands**

```bash
# From the repo root
./scripts/setup_environment.sh
./scripts/deploy_nim_production.sh
./scripts/test_nim_production.sh

# Timing and cost for this autoscaling production path are not measured.
# See the README "Measured results" table and docs/runs/2026-09-27-run-1-fixed.md
# for the one measured run (fixed 1-node GPU pool, deploy_nim_gke.sh).
```

---

## **Additional Resources**

- [Official Google Codelabs Tutorial](https://codelabs.developers.google.com/codelabs/nvidia-nim-google-cloud)
- [NVIDIA NIM Documentation](https://docs.nvidia.com/nim/)
- [GKE GPU Guide](https://cloud.google.com/kubernetes-engine/docs/how-to/gpus)
- [GCP Pricing Calculator](https://cloud.google.com/products/calculator)

---

`deploy_nim_production.sh` has not been run end-to-end. Treat this guide as
a design for an autoscaling deployment, not a verified result.
