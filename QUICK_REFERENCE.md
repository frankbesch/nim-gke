# Quick Reference - NIM-GKE

One-page operational reference.

---

## 🚀 Deploy (Fresh Start)

```bash
export NGC_CLI_API_KEY='your-key-here'
cd ~/nim-gke
./scripts/deploy_nim_gke.sh
```

**Duration**: 30 minutes  
**Cost**: $1.36/hour

---

## 🧪 Test

```bash
# Terminal 1
kubectl port-forward service/my-nim-nim-llm 8000:8000 -n nim

# Terminal 2
curl http://localhost:8000/v1/health/ready
./scripts/test_nim.sh
```

---

## 📊 Monitor

```bash
# Pod status
kubectl get pods -n nim

# Logs
kubectl logs -f my-nim-nim-llm-0 -n nim

# GPU
kubectl exec -n nim my-nim-nim-llm-0 -- nvidia-smi

# Resources
kubectl top pod -n nim
```

---

## 🗑️ Cleanup

```bash
./scripts/cleanup.sh
```

**Result**: All resources deleted, $0/hour

---

## 💰 Cost Tracking

| State | Cost/Hour | Cost/Day |
|-------|-----------|----------|
| Running | $1.36 | $32.64 |
| Idle (no GPU) | $0.13 | $3.12 |
| Deleted | $0 | $0 |

**Check current costs**:
```bash
gcloud container clusters list
gcloud compute instances list --filter="name:gke-nim-demo"
```

---

## 🔧 Common Issues

### Port-forward died

```bash
pkill -f port-forward
kubectl port-forward service/my-nim-nim-llm 8000:8000 -n nim &
```

### Pod not ready

```bash
kubectl describe pod my-nim-nim-llm-0 -n nim
kubectl logs my-nim-nim-llm-0 -n nim | tail -50
```

### Cluster not found

```bash
gcloud container clusters get-credentials nim-demo --zone=us-central1-a
```

---

## 📁 Key Files

| File | Purpose |
|------|---------|
| `scripts/deploy_nim_gke.sh` | Main deployment |
| `scripts/cleanup.sh` | Delete all resources |
| `scripts/test_nim.sh` | Basic test |
| `charts/values-production.yaml` | Helm config |
| `runbooks/troubleshooting.md` | Incident response |

---

## 🔑 Environment Variables

```bash
export NGC_CLI_API_KEY='...'        # Required
export PROJECT_ID='your-gcp-project'      # Default
export REGION='us-central1'         # Default
export ZONE='us-central1-a'         # Default
```

---

## 🎯 Quick Commands

```bash
# Deploy
./scripts/deploy_nim_gke.sh

# Test
./scripts/test_nim.sh

# Monitor
kubectl get pods -n nim -w

# Cleanup
./scripts/cleanup.sh

# Cost check
gcloud container clusters list
```

---

## 📞 Help

- **Docs**: `docs/ARCHITECTURE.md`
- **Runbook**: `runbooks/troubleshooting.md`
- **Scripts**: `scripts/README.md`

