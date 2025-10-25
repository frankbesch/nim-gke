# 🎮 GPU Quota Request Guide

## 📊 Current Status

✅ **Completed:**
- GKE cluster `nim-demo` created successfully
- Control plane running in `us-central1-a`
- gcloud, kubectl, helm installed and configured
- NGC API key configured

❌ **Blocked:**
- GPU node pool creation failed
- **Reason:** GPU quota is 0 (you have no GPU quota allocated)

---

## 🔧 How to Request GPU Quota

### Step 1: Open Quotas Page

**Direct Link:**
https://console.cloud.google.com/iam-admin/quotas?project=nim-on-gke

### Step 2: Find GPU Quotas

In the **Filter** box at the top, enter one of:
- `NVIDIA L4`
- `GPUs all regions`
- `GPUS_ALL_REGIONS`

### Step 3: Select and Edit

1. Check the box next to **"GPUs (all regions)"** or **"NVIDIA L4 GPUs"**
2. Click **"EDIT QUOTAS"** button at top
3. Fill out the form:
   - **New limit:** `1` (or more if needed)
   - **Request description:** 
     ```
     Need GPU quota for NVIDIA NIM deployment on GKE.
     Running AI/ML inference workloads with Llama 3 8B model.
     Requesting 1x NVIDIA L4 GPU in us-central1.
     ```

### Step 4: Submit

- Click **Submit Request**
- Check your email for:
  - Confirmation email
  - Approval notification (usually within 24 hours, sometimes instant)

---

## ⏰ Timeline

| Action | Duration | Status |
|--------|----------|--------|
| Submit quota request | 5 minutes | ⏸️ Pending |
| Google approval | 1-24 hours | ⏸️ Waiting |
| Add GPU node pool | 10 minutes | ⏸️ After approval |
| Deploy NIM | 20 minutes | ⏸️ After GPU nodes |

---

## 🚀 What to Do After Approval

### Option A: Add GPU Node Pool Only (Recommended)

Your cluster is already created! Just add the GPU node pool:

```bash
# After quota is approved
cd ~/nim-gke
export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"
./add_gpu_nodepool.sh
```

Then deploy NIM:

```bash
export NGC_CLI_API_KEY='your-key-here'
./deploy_nim_only.sh
```

### Option B: Start Fresh

Delete everything and redeploy:

```bash
# Delete current cluster
gcloud container clusters delete nim-demo --zone=us-central1-a

# Redeploy everything
export NGC_CLI_API_KEY='your-key-here'
./deploy_nim_gke.sh
```

---

## 📋 Alternative: Try Different GPUs

If L4 quota takes too long, check if you have quota for:

### NVIDIA T4 (Older, more available)
```bash
# Edit deploy_nim_gke.sh:
export GPU_TYPE="nvidia-tesla-t4"
export NODE_POOL_MACHINE_TYPE="n1-standard-4"
```

### NVIDIA A100 (More powerful, expensive)
```bash
# Edit deploy_nim_gke.sh:
export GPU_TYPE="nvidia-tesla-a100"
export NODE_POOL_MACHINE_TYPE="a2-highgpu-1g"
```

### Check Available GPUs by Region

Run this command to see GPU availability:
```bash
gcloud compute accelerator-types list --filter="zone:us-central1"
```

---

## 💰 Current Costs

| Resource | Status | Cost/Hour |
|----------|--------|-----------|
| Control plane (e2-standard-4) | ✅ Running | $0.13 |
| GPU node pool | ❌ Not created | $0.00 |
| **Total** | | **$0.13/hour** |

### After GPU approval:
| Resource | Cost/Hour |
|----------|-----------|
| Control plane | $0.13 |
| GPU node + L4 GPU | $1.50 |
| **Total** | **$1.63/hour** |

---

## 🗑️ Cleanup Options

### Keep Cluster (wait for approval)
```bash
# No action needed
# Costs: ~$0.13/hour while waiting
```

### Delete Everything (stop charges)
```bash
gcloud container clusters delete nim-demo --zone=us-central1-a
# Costs: $0/hour
# You'll need to recreate cluster after approval
```

---

## 🎯 Recommended Next Steps

1. **Request GPU quota now** (link above)
2. **Keep the cluster running** (~$3/day while waiting)
3. **Check email** for approval notification
4. **Run `./add_gpu_nodepool.sh`** when approved
5. **Run `./deploy_nim_only.sh`** to complete deployment

---

## 🆘 Troubleshooting

### Quota request denied?
- **Reason:** New accounts may have restrictions
- **Solution:** 
  - Add payment method
  - Use the free trial credits
  - Contact Google Cloud Support

### Quota approved but still failing?
- **Check:** Correct region (us-central1)
- **Check:** Correct GPU type in script
- **Try:** Different zone (us-central1-b, us-central1-c)

### Approval taking too long?
- **Typical:** 1-2 hours during business hours
- **Weekend:** May take up to 24 hours
- **Expedite:** Contact Google Cloud Support

---

## 📞 Support Links

- **GCP Quotas:** https://console.cloud.google.com/iam-admin/quotas?project=nim-on-gke
- **GCP Support:** https://cloud.google.com/support
- **GPU Documentation:** https://cloud.google.com/compute/docs/gpus
- **NVIDIA NIM Docs:** https://docs.nvidia.com/nim/

---

## ✅ Checklist

- [ ] Open quotas page
- [ ] Filter for "NVIDIA L4" or "GPUs all regions"
- [ ] Request quota increase (at least 1 GPU)
- [ ] Submit request form
- [ ] Wait for email confirmation
- [ ] Run `./add_gpu_nodepool.sh`
- [ ] Run `./deploy_nim_only.sh`
- [ ] Test with `./test_nim.sh`

---

**Good luck with your quota request!** 🎉

You're 90% there - just waiting on GPU approval!

