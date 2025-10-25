# 🚀 Ready to Deploy Tomorrow?

## ✅ **Pre-Flight Checklist**

Before you start, verify:
- [ ] ✅ Received GPU quota approval email from Google Cloud
- [ ] ✅ Email subject: "Quota increase request approved"
- [ ] ✅ Checked your quota at: https://console.cloud.google.com/iam-admin/quotas?project=YOUR_PROJECT_ID

---

## 🎯 **One-Command Deployment**

Once your GPU quota is approved, run this:

```bash
cd ~/nim-gke
export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"
export NGC_CLI_API_KEY='your-ngc-api-key-here'
./deploy_nim_gke.sh
```

**That's it!** This will:
1. Create GKE cluster (~5 min)
2. Add GPU node pool (~10 min)
3. Deploy NVIDIA NIM (~20 min)
4. Configure everything automatically

**Total time: ~35 minutes**

---

## 📊 **Monitor Progress**

While it's deploying, you can watch:

```bash
# Watch pod status
kubectl get pods -n nim -w

# View logs
kubectl logs -f -n nim $(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}')

# Check nodes (should see GPU node)
kubectl get nodes
```

---

## 🧪 **Test After Deployment**

Once the pod is ready (status: Running 1/1):

**Terminal 1:**
```bash
kubectl port-forward service/my-nim-nim-llm 8000:8000 -n nim
```

**Terminal 2:**
```bash
cd ~/nim-gke
./test_nim.sh
```

---

## 💰 **Cost Reminder**

Once deployed:
- **Running cost:** ~$1.63/hour (~$39/day)
- **To stop charges:** `./cleanup.sh`

---

## 🆘 **If Something Goes Wrong**

### GPU quota still failing?
```bash
# Check current quota
gcloud compute regions describe us-central1 | grep GPU

# View quotas page
open "https://console.cloud.google.com/iam-admin/quotas?project=YOUR_PROJECT_ID"
```

### Deployment stuck?
```bash
# Check logs
kubectl describe pod -n nim $(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}')

# Delete and retry
./cleanup.sh
./deploy_nim_gke.sh
```

### Need help?
- Check `GPU_QUOTA_GUIDE.md`
- Check `README.md`
- View logs with commands above

---

## 📋 **Quick Reference**

| Command | Purpose |
|---------|---------|
| `./deploy_nim_gke.sh` | Deploy everything |
| `./test_nim.sh` | Test deployment |
| `./cleanup.sh` | Delete everything |
| `kubectl get pods -n nim` | Check status |
| `kubectl logs -n nim <pod>` | View logs |

---

## 🎉 **Success Criteria**

You'll know it's working when:

1. ✅ Pod status: `Running 1/1`
2. ✅ `./test_nim.sh` returns AI responses
3. ✅ curl returns JSON with model completions

---

**Good luck tomorrow!** 🚀

_Remember: Your NGC API key is already configured in `set_ngc_key.sh`_

