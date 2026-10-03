# Quick start: NVIDIA NIM on GKE

## Three steps

Step 3 bills from the first node it creates. The README
[quick start](../README.md#quick-start) runs the same path through teardown.

```bash
# 1. Get an NGC API key at
#    https://org.ngc.nvidia.com/setup/api-key
#    and set the two variables.
export NGC_API_KEY='your-key-here'
export PROJECT_ID='your-gcp-project'

# 2. Validate prerequisites.
#    Read-only.
./scripts/preflight.sh

# 3. Deploy NIM. Bills from here.
#    Measured: 20 m 19 s.
./scripts/deploy_nim_gke.sh

# Wait for Running (1/1).
# Watches until Ctrl-C.
kubectl get pods -n nim -w
```

`NGC_CLI_API_KEY` is accepted as a fallback if `NGC_API_KEY` is unset. The
preflight runs six checks: NGC key, gcloud auth, image tag, chart fetch, L4
quota, no existing cluster.

---

## Test your deployment

```bash
# Forward the port in the background.
kubectl port-forward -n nim \
  service/my-nim-nim-llm 8000:8000 &
PF=$!; sleep 3

# Test with the script.
./scripts/test_nim.sh

# Or by hand.
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [
      {"role": "system", "content": "You are a helpful AI assistant."},
      {"role": "user", "content": "Tell me a fun fact about space!"}
    ],
    "model": "meta/llama3-8b-instruct",
    "max_tokens": 100
  }'

# Stop the port forward.
kill "$PF"
```

---

## Common commands

### Check Status

```bash
# Pod status
kubectl get pods -n nim

# Node status (verify GPU)
kubectl get nodes -o wide

# Describe pod (for troubleshooting)
kubectl describe pod -n nim $(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}')

# Logs. Follows until Ctrl-C.
kubectl logs -f -n nim $(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}')
```

### Access NIM

With the port forwarded as in [Test your deployment](#test-your-deployment):

```bash
# Check available models
curl http://localhost:8000/v1/models | jq .
```

---

## Cleanup (stop charges)

```bash
./scripts/cleanup.sh
```

<!-- separate: each deletes the cluster -->
**Or manually**:

```bash
gcloud container clusters delete nim-demo --zone=us-central1-a
```

---

## Troubleshooting

### Issue: Pod Stuck in Pending

```bash
kubectl describe pod -n nim $(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}')
```

**Common fixes**:
- Wait for GPU node to be ready: `kubectl get nodes`
- Check GPU quota: `gcloud compute regions describe us-central1 | grep GPU`

### Issue: ImagePullBackOff

**Fix**: check that the key is set, without printing it, then recreate
both secrets from the repo root.

```bash
# Prints "set" or "missing", never the key.
[ -n "$NGC_API_KEY" ] && echo set || echo missing

# Recreate registry-secret and ngc-api.
PROJECT_ID="${PROJECT_ID:-x}" source scripts/config.env
ngc_apply_secrets nim

# Restart the pod so it pulls again.
kubectl delete pod -n nim $(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}')
```

### Issue: Model Loading Slow

**Normal**: measured model download and load to Ready took 8 m 39 s in the [run receipt](runs/2026-09-27-run-1-fixed.md)

**Monitor**:
```bash
kubectl logs -f -n nim $(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}')
```

---

## Cost Control

See the [cost and performance table](../README.md#measured-results) for
measured figures: ~$0.98/hour while up, $0.43 for one full run.

**Save money**:
```bash
# Stop cluster when not in use
gcloud container clusters delete nim-demo --zone=us-central1-a

# Or resize to 0 nodes (keeps config)
gcloud container clusters resize nim-demo --num-nodes=0 --zone=us-central1-a --node-pool=gpupool
```

---

## Quick Reference

| Command | Purpose |
|---------|---------|
| `./scripts/preflight.sh` | Validate environment (read-only) |
| `./scripts/deploy_nim_gke.sh` | Deploy NIM to GKE |
| `./scripts/test_nim.sh` | Test deployment |
| `./scripts/cleanup.sh` | Delete everything |
| `kubectl get pods -n nim` | Check pod status |
| `kubectl logs -f -n nim <pod>` | View logs |

---

## What You Just Deployed

- **Model**: Meta Llama 3 8B Instruct
- **Backend**: `vllm-fp16-tp1`, the one profile NIM 1.0.0 offers on the L4 ([run 2](runs/2026-09-27-run-2-fixed.md#backend-profile))
- **GPU**: NVIDIA L4 (24 GB)
- **API**: OpenAI-compatible REST API
- **Scale**: Kubernetes autoscaling ready

---

## Learn More

- [Full README](../README.md)
- [NVIDIA NIM Docs](https://docs.nvidia.com/nim/)
- [GKE GPU Guide](https://cloud.google.com/kubernetes-engine/docs/how-to/gpus)
- [Original Tutorial](https://codelabs.developers.google.com/codelabs/nvidia-nim-google-cloud)

---

**Need help?** Check the [README](../README.md) troubleshooting section or [open an issue](https://github.com/frankbesch/nim-gke/issues).

