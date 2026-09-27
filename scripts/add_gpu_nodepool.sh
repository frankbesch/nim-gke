#!/bin/bash

# ============================================
# 🎮 Add GPU Node Pool to Existing Cluster
# ============================================
#
# Use this script after GPU quota is approved
# to add the GPU node pool to your existing cluster
#

set -euo pipefail

# --- Configuration ---
source "$(dirname "${BASH_SOURCE[0]}")/config.env"
require_project_id

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎮 Adding GPU Node Pool to Existing Cluster"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Configuration:"
echo "  Cluster: ${CLUSTER_NAME}"
echo "  Zone: ${ZONE}"
echo "  GPU Type: ${GPU_TYPE}"
echo "  Machine Type: ${NODE_POOL_MACHINE_TYPE}"
echo ""

# Check if cluster exists
if ! gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
  echo "❌ Cluster ${CLUSTER_NAME} not found in ${ZONE}"
  echo "   Run ./deploy_nim_gke.sh to create the cluster first"
  exit 1
fi

echo "✅ Cluster ${CLUSTER_NAME} found"
echo ""

# Check if GPU node pool already exists
if gcloud container node-pools describe gpupool --cluster="${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
  echo "⚠️  GPU node pool 'gpupool' already exists"
  echo ""
  read -p "Delete and recreate? (yes/no): " RECREATE
  if [[ "${RECREATE}" == "yes" ]]; then
    echo "🗑️  Deleting existing GPU node pool..."
    gcloud container node-pools delete gpupool \
      --cluster="${CLUSTER_NAME}" \
      --zone="${ZONE}" \
      --project="${PROJECT_ID}" \
      --quiet
    echo "✅ Deleted"
  else
    echo "❌ Aborted"
    exit 1
  fi
fi

# Create GPU node pool
echo ""
echo "🎮 Creating GPU node pool..."
echo "   This may take 5-10 minutes..."
echo ""

gcloud container node-pools create gpupool \
    --accelerator type="${GPU_TYPE}",count="${GPU_COUNT}",gpu-driver-version=latest \
    --project="${PROJECT_ID}" \
    --location="${ZONE}" \
    --cluster="${CLUSTER_NAME}" \
    --machine-type="${NODE_POOL_MACHINE_TYPE}" \
    --num-nodes=1

if [ $? -eq 0 ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✅ GPU Node Pool Created Successfully!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "📊 Cluster Status:"
  kubectl get nodes
  echo ""
  echo "🎯 Next Steps:"
  echo ""
  echo "1️⃣  Continue with NIM deployment:"
  echo "   export NGC_API_KEY='your-key-here'"
  echo "   # Then run the deployment steps manually from deploy_nim_gke.sh"
  echo "   # starting from Step 8 (Fetch NIM Helm Chart)"
  echo ""
  echo "2️⃣  Or create a new deployment script that picks up from here"
  echo ""
else
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "❌ GPU Node Pool Creation Failed"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Common Issues:"
  echo "  • GPU quota still not approved"
  echo "  • Wrong GPU type for your quota"
  echo "  • Wrong region/zone"
  echo ""
  echo "Check your GPU quota:"
  echo "  https://console.cloud.google.com/iam-admin/quotas?project=${PROJECT_ID}"
  echo ""
  exit 1
fi
