# NIM-GKE Troubleshooting Runbook

Operational procedures for incident response and debugging.

---

## Pod Scheduling Failures

### Symptom: Pod stuck in `Pending`

```bash
kubectl get pods -n nim
# NAME: my-nim-nim-llm-0  STATUS: Pending
```

**Diagnosis**:
```bash
kubectl describe pod my-nim-nim-llm-0 -n nim | grep -A 10 "Events:"
```

**Common causes**:

#### 1. Insufficient GPU Resources

**Event message**: `0/N nodes available: N Insufficient nvidia.com/gpu`

**Root cause**: No GPU nodes available or all GPUs allocated.

**Resolution**:
```bash
# Check node pool status
gcloud container node-pools describe gpupool \
  --cluster=nim-demo \
  --zone=us-central1-a

# Check GPU availability
kubectl describe nodes | grep -A 5 "nvidia.com/gpu"

# Manual scale if autoscaler didn't trigger
gcloud container node-pools resize gpupool \
  --cluster=nim-demo \
  --zone=us-central1-a \
  --num-nodes=1
```

#### 2. GPU Quota Exceeded

**Event message**: `Quota 'NVIDIA_L4_GPUS' exceeded`

**Resolution**:
```bash
# Check current quota
gcloud compute regions describe us-central1 | grep -A 2 "NVIDIA_L4"

# Request increase via GCP Console:
# IAM & Admin → Quotas → Filter "NVIDIA L4" → Edit → Request
```

#### 3. Node Provisioning Failed

**Event message**: `GCE out of resources` or `Node scale up failed`

**Root cause**: Zone capacity exhausted or configuration issue.

**Resolution**:
```bash
# Try different zone
export ZONE="us-central1-b"

# Delete failed node pool
gcloud container node-pools delete gpupool \
  --cluster=nim-demo \
  --zone=us-central1-a \
  --quiet

# Recreate in new zone
gcloud container node-pools create gpupool \
  --accelerator type=nvidia-l4,count=1,gpu-driver-version=latest \
  --cluster=nim-demo \
  --zone=$ZONE \
  --machine-type=g2-standard-4 \
  --num-nodes=1
```

---

## Image Pull Failures

### Symptom: `ImagePullBackOff` or `ErrImagePull`

```bash
kubectl get pods -n nim
# STATUS: ImagePullBackOff
```

**Diagnosis**:
```bash
kubectl describe pod my-nim-nim-llm-0 -n nim | grep -A 5 "Failed"
```

**Common causes**:

#### 1. Invalid NGC API Key

**Event message**: `unauthorized: authentication required`

**Resolution**:
```bash
# Verify key is set
echo $NGC_CLI_API_KEY | head -c 20

# Recreate registry secret
kubectl delete secret registry-secret -n nim
kubectl create secret docker-registry registry-secret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password=$NGC_CLI_API_KEY \
  -n nim

# Delete pod to retry
kubectl delete pod my-nim-nim-llm-0 -n nim
```

#### 2. Secret Not Found

**Event message**: `couldn't find key NGC_API_KEY in Secret`

**Root cause**: Secret created with wrong key name.

**Resolution**:
```bash
# Delete incorrect secret
kubectl delete secret ngc-api -n nim

# Create with both key names (compatibility)
kubectl create secret generic ngc-api \
  --from-literal=NGC_API_KEY=$NGC_CLI_API_KEY \
  --from-literal=NGC_CLI_API_KEY=$NGC_CLI_API_KEY \
  -n nim

# Restart pod
kubectl delete pod my-nim-nim-llm-0 -n nim
```

---

## Container Startup Failures

### Symptom: `CrashLoopBackOff` or `CreateContainerConfigError`

**Diagnosis**:
```bash
kubectl logs my-nim-nim-llm-0 -n nim --previous
kubectl describe pod my-nim-nim-llm-0 -n nim
```

**Common causes**:

#### 1. Insufficient GPU Memory

**Log message**: `CUDA out of memory`

**Resolution**:
- Reduce batch size in Helm values
- Use larger GPU (A100 40GB/80GB)
- Deploy smaller model variant

#### 2. Driver Version Mismatch

**Log message**: `CUDA driver version is insufficient`

**Resolution**:
```bash
# Check driver version on node
kubectl exec -n nim my-nim-nim-llm-0 -- nvidia-smi

# Update node pool with latest driver
gcloud container node-pools update gpupool \
  --cluster=nim-demo \
  --zone=us-central1-a \
  --system-config-from-file=gpu-config.yaml
```

---

## Model Loading Issues

### Symptom: Pod `Running` but not `Ready` (0/1)

**Diagnosis**:
```bash
kubectl logs -f my-nim-nim-llm-0 -n nim
kubectl get events -n nim --sort-by='.lastTimestamp' | tail -20
```

**Common causes**:

#### 1. Model Download in Progress

**Log message**: `Preparing model workspace. This step might download additional files`

**Expected behavior**: 10-15 minutes for initial download (16GB model).

**No action required**: Wait for download to complete.

**Monitor progress**:
```bash
# Watch logs for "Service is ready"
kubectl logs -f my-nim-nim-llm-0 -n nim | grep -i "ready\|loading\|download"
```

#### 2. Startup Probe Timeout

**Event message**: `Startup probe failed: dial tcp: connect refused`

**Root cause**: Model loading exceeds probe timeout.

**Resolution** (adjust Helm values):
```yaml
startupProbe:
  initialDelaySeconds: 300
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 60  # 30 minutes max
```

---

## Service Access Issues

### Symptom: Cannot reach NIM API

**Diagnosis**:
```bash
# Check service exists
kubectl get svc -n nim

# Check endpoints
kubectl get endpoints -n nim

# Verify port-forward
lsof -i :8000
```

**Common causes**:

#### 1. Port Forward Not Active

**Resolution**:
```bash
# Start port-forward in background
kubectl port-forward service/my-nim-nim-llm 8000:8000 -n nim &

# Or in separate terminal (preferred)
kubectl port-forward service/my-nim-nim-llm 8000:8000 -n nim
```

#### 2. Service Selector Mismatch

**Resolution**:
```bash
# Check service targets correct pods
kubectl describe svc my-nim-nim-llm -n nim

# Verify pod labels match
kubectl get pods -n nim --show-labels
```

---

## Performance Degradation

### Symptom: Slow inference (>10s per request)

**Diagnosis**:
```bash
# Check GPU utilization
kubectl exec -n nim my-nim-nim-llm-0 -- nvidia-smi

# Check resource usage
kubectl top pod -n nim

# Review logs for errors
kubectl logs my-nim-nim-llm-0 -n nim | grep -i "error\|warning"
```

**Common causes**:

#### 1. Resource Contention

**Resolution**:
- Scale to dedicated GPU node
- Increase resource requests/limits
- Check for CPU throttling

#### 2. Suboptimal Batch Size

**Tuning**:
```yaml
# In Helm values
env:
  - name: MAX_BATCH_SIZE
    value: "32"
  - name: MAX_NUM_SEQS
    value: "256"
```

---

## Autoscaler Issues

### Symptom: GPU nodes not scaling

**Diagnosis**:
```bash
# Check autoscaler logs
kubectl logs -n kube-system deployment/cluster-autoscaler

# Check node pool config
gcloud container node-pools describe gpupool \
  --cluster=nim-demo \
  --zone=us-central1-a | grep -A 5 "autoscaling"
```

**Common causes**:

#### 1. Autoscaling Not Enabled

**Resolution**:
```bash
gcloud container node-pools update gpupool \
  --cluster=nim-demo \
  --zone=us-central1-a \
  --enable-autoscaling \
  --min-nodes=0 \
  --max-nodes=2
```

#### 2. Pods in System Namespaces Blocking Scale-Down

**Resolution**:
```bash
# Add PodDisruptionBudget for controlled scale-down
kubectl apply -f - <<EOF
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: nim-pdb
  namespace: nim
spec:
  minAvailable: 0
  selector:
    matchLabels:
      app: my-nim-nim-llm
EOF
```

---

## Cost Overruns

### Symptom: Unexpected GCP charges

**Diagnosis**:
```bash
# Check running resources
gcloud container clusters list
gcloud compute instances list --filter="name:gke-nim-demo"

# Check node pool sizes
gcloud container node-pools list --cluster=nim-demo --zone=us-central1-a
```

**Common causes**:

#### 1. GPU Nodes Not Scaling Down

**Resolution**:
```bash
# Check for stuck pods preventing scale-down
kubectl get pods -n nim

# Force scale to zero (if safe)
kubectl scale statefulset my-nim-nim-llm --replicas=0 -n nim

# Wait for autoscaler, then verify
kubectl get nodes
```

#### 2. Cluster Not Deleted

**Resolution**:
```bash
# Complete cleanup
./scripts/cleanup.sh

# Or manual deletion
gcloud container clusters delete nim-demo --zone=us-central1-a --quiet
```

---

## Emergency Procedures

### Complete Reset

```bash
# 1. Delete NIM deployment
helm uninstall my-nim -n nim

# 2. Delete namespace
kubectl delete namespace nim

# 3. Delete GPU node pool
gcloud container node-pools delete gpupool \
  --cluster=nim-demo \
  --zone=us-central1-a \
  --quiet

# 4. Redeploy from scratch
./scripts/deploy_nim_gke.sh
```

### Force Pod Restart

```bash
# Delete pod (StatefulSet recreates automatically)
kubectl delete pod my-nim-nim-llm-0 -n nim --grace-period=0 --force
```

### Collect Diagnostic Bundle

```bash
#!/bin/bash
BUNDLE="nim-diagnostics-$(date +%Y%m%d-%H%M%S).tar.gz"

mkdir -p diagnostics
kubectl get all -n nim -o yaml > diagnostics/resources.yaml
kubectl describe pods -n nim > diagnostics/pod-details.txt
kubectl logs my-nim-nim-llm-0 -n nim > diagnostics/pod-logs.txt
kubectl get events -n nim --sort-by='.lastTimestamp' > diagnostics/events.txt
kubectl top pods -n nim > diagnostics/resource-usage.txt

tar -czf $BUNDLE diagnostics/
rm -rf diagnostics/

echo "Diagnostic bundle: $BUNDLE"
```

---

## Escalation

If issue persists after following runbook:

1. **GCP Issues**: https://cloud.google.com/support
2. **NVIDIA NIM Issues**: https://forums.developer.nvidia.com/
3. **Kubernetes Issues**: https://kubernetes.slack.com/

**Required information**:
- Diagnostic bundle (see above)
- GKE version: `kubectl version`
- NIM version: `helm list -n nim`
- GPU driver version: `kubectl exec -n nim my-nim-nim-llm-0 -- nvidia-smi`

