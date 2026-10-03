# Operate

## Verify

With the port forwarded to `localhost:8000`:

```bash
# Health check.
curl http://localhost:8000/v1/health/ready

# List models.
curl http://localhost:8000/v1/models

# Inference test.
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [{"role": "user", "content": "What is TensorRT?"}],
    "model": "meta/llama3-8b-instruct",
    "max_tokens": 100
  }'
```

This single call is not a benchmark. For measured latency and the method behind it, see the [measured results](../README.md#measured-results) and `scripts/bench.py`.

## Monitor, scale, and cost control

### Monitor

```bash
# GPU utilization.
kubectl exec -n nim my-nim-nim-llm-0 -- nvidia-smi

# Resource usage.
kubectl top pod -n nim

# Logs. Follows until Ctrl-C.
kubectl logs -f my-nim-nim-llm-0 -n nim

# Pod status. Watches until Ctrl-C.
kubectl get pods -n nim -w
```

### Scale

Manual scale (StatefulSet). Each replica needs its own L4; with the default
1-node GPU pool a 2nd replica stays Pending.

```bash
kubectl scale statefulset my-nim-nim-llm --replicas=2 -n nim
```

<!-- separate: a resize bills a second L4 -->
GPU node pool resize, which bills a second L4:

```bash
gcloud container node-pools resize gpupool \
  --cluster=nim-demo \
  --zone=us-central1-a \
  --num-nodes=2
```

### Cost Control

Remove deployment (keep cluster):

```bash
helm uninstall my-nim -n nim
```

<!-- separate: cleanup deletes the cluster -->
Or delete the cluster and PVC, and list leftover disks:

```bash
./scripts/cleanup.sh
```

## Troubleshoot

**Pod stuck in Pending**:

```bash
kubectl describe pod -n nim my-nim-nim-llm-0
```

Check: GPU availability, node readiness, quotas.

**ImagePullBackOff** (image pulls use `registry-secret`):

```bash
kubectl get secret registry-secret -n nim
```

Recreate both secrets if needed, then restart the pod. Run this from the
repo root. It recreates `registry-secret` and `ngc-api`; the key stays off
the command line.

```bash
# Recreate the two secrets.
PROJECT_ID="${PROJECT_ID:-x}" source scripts/config.env
ngc_apply_secrets nim

# Restart the pod so it pulls again.
kubectl delete pod my-nim-nim-llm-0 -n nim
```

**Model loading slow**:
- Measured: model download to Ready took 8 m 39 s in run 1 and 7 m 24 s in run 2.
- Monitor: `kubectl logs -f my-nim-nim-llm-0 -n nim`

See [runbooks/troubleshooting.md](../runbooks/troubleshooting.md) for complete procedures.

## Production deployment (not measured)

```bash
# Deploy. Bills from here.
./scripts/deploy_nim_production.sh

# Test.
./scripts/test_nim_production.sh
```

Autoscaling GPU pool (0-2 nodes) and a system pool with a minimum of 1
node. No timing or cost numbers exist for this path.
