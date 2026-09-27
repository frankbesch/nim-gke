# ⚡ Quick Start Guide - NVIDIA NIM on GKE

## 🎯 3-Step Deployment

### 1️⃣ Get NGC API Key (5 minutes)

```bash
# Visit: https://org.ngc.nvidia.com/setup/api-key
# Sign up/Login → Generate API Key → Copy it

export NGC_API_KEY='nvapi-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
export PROJECT_ID='your-gcp-project'
```

`NGC_CLI_API_KEY` is accepted as a fallback if `NGC_API_KEY` is unset.

### 2️⃣ Validate Prerequisites (read-only checks)

```bash
./preflight.sh
```

Six checks: NGC key, gcloud auth, image tag, chart fetch, L4 quota, no
existing cluster.

### 3️⃣ Deploy NIM (measured: 20 m 19 s)

```bash
./deploy_nim_gke.sh
```

**Wait for**: Pod status shows `Running` (1/1)

```bash
kubectl get pods -n nim -w
```

---

## 🧪 Test Your Deployment

### Terminal 1: Port Forward

```bash
kubectl port-forward service/my-nim-nim-llm 8000:8000 -n nim
```

### Terminal 2: Test

```bash
./test_nim.sh
```

Or manually:

```bash
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
```

---

## 🔧 Common Commands

### Check Status

```bash
# Pod status
kubectl get pods -n nim

# Node status (verify GPU)
kubectl get nodes -o wide

# Logs
kubectl logs -f -n nim $(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}')

# Describe pod (for troubleshooting)
kubectl describe pod -n nim $(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}')
```

### Access NIM

```bash
# Port forward (blocking)
kubectl port-forward service/my-nim-nim-llm 8000:8000 -n nim

# Check available models
curl http://localhost:8000/v1/models | jq .
```

---

## 🗑️ Cleanup (Stop Charges)

```bash
./cleanup.sh
```

**Or manually**:

```bash
gcloud container clusters delete nim-demo --zone=us-central1-a
```

---

## ⚠️ Troubleshooting

### Issue: Pod Stuck in Pending

```bash
kubectl describe pod -n nim $(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}')
```

**Common fixes**:
- Wait for GPU node to be ready: `kubectl get nodes`
- Check GPU quota: `gcloud compute regions describe us-central1 | grep GPU`

### Issue: ImagePullBackOff

**Fix**: Verify NGC API key
```bash
echo $NGC_API_KEY
kubectl delete secret registry-secret -n nim
kubectl delete secret ngc-api -n nim
# Re-run deploy script
```

### Issue: Model Loading Slow

**Normal**: measured model download and load to Ready took 8 m 39 s in the [run receipt](runs/2026-09-27-measured-run.md)

**Monitor**:
```bash
kubectl logs -f -n nim $(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}')
```

---

## 💰 Cost Control

See the [cost and performance table](../README.md#cost-and-performance) for
measured figures: ~$0.98/hour while up, $0.43 for one full run.

**Save money**:
```bash
# Stop cluster when not in use
gcloud container clusters delete nim-demo --zone=us-central1-a

# Or resize to 0 nodes (keeps config)
gcloud container clusters resize nim-demo --num-nodes=0 --zone=us-central1-a --node-pool=gpupool
```

---

## 📋 Quick Reference

| Command | Purpose |
|---------|---------|
| `./preflight.sh` | Validate environment (read-only) |
| `./deploy_nim_gke.sh` | Deploy NIM to GKE |
| `./test_nim.sh` | Test deployment |
| `./cleanup.sh` | Delete everything |
| `kubectl get pods -n nim` | Check pod status |
| `kubectl logs -f -n nim <pod>` | View logs |

---

## 🎓 What You Just Deployed

- **Model**: Meta Llama 3 8B Instruct
- **Optimization**: NVIDIA TensorRT
- **GPU**: NVIDIA L4 (24 GB)
- **API**: OpenAI-compatible REST API
- **Scale**: Kubernetes autoscaling ready

---

## 📚 Learn More

- [Full README](../README.md)
- [NVIDIA NIM Docs](https://docs.nvidia.com/nim/)
- [GKE GPU Guide](https://cloud.google.com/kubernetes-engine/docs/how-to/gpus)
- [Original Tutorial](https://codelabs.developers.google.com/codelabs/nvidia-nim-google-cloud)

---

**Need help?** Check the [README](../README.md) troubleshooting section or [open an issue](https://github.com/frankbesch/nim-gke/issues).

