# Quick Reference - NIM-GKE

One-page operational reference.

---

## 🚀 Deploy (Fresh Start)

```bash
export NGC_API_KEY='your-key-here'   # NGC_CLI_API_KEY accepted as a fallback
export PROJECT_ID='your-gcp-project'
cd ~/nim-gke
./scripts/preflight.sh
./scripts/deploy_nim_gke.sh
```

**Duration**: measured 20 m 19 s (script start to pod Ready)
**Cost**: see the [cost and performance table in README](README.md#measured-results)

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

**Result**: Uninstalls the release, deletes the PVC, deletes the cluster, then lists any leftover disks.

---

## 💰 Cost Tracking

See the [cost and performance table in README](README.md#measured-results)
for measured figures. Summary: ~$0.98/hour while up, $0.43 for one full
deploy/test/destroy run. The system pool keeps a minimum of 1 node, so
there is no idle-but-running $0/hour state; only a deleted cluster is $0.

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
export NGC_API_KEY='...'            # Required
export PROJECT_ID='your-gcp-project' # Required, no default
export REGION='us-central1'         # Optional override (default shown)
export ZONE='us-central1-a'         # Optional override (default shown)
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

