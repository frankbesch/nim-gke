#!/bin/bash

# ============================================
# 🗑️  Cleanup NVIDIA NIM GKE Deployment
# ============================================

set -e

export CLUSTER_NAME="nim-demo"
export ZONE="us-central1-a"
export PROJECT_ID="your-gcp-project"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🗑️  NVIDIA NIM GKE Cleanup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "⚠️  WARNING: This will delete:"
echo "   - GKE Cluster: ${CLUSTER_NAME}"
echo "   - GPU node pool: gpupool"
echo "   - All associated resources"
echo ""
echo "💰 This will STOP all charges for:"
echo "   - Compute instances (~$1.63/hour)"
echo "   - Load balancers"
echo "   - Persistent storage"
echo ""

read -p "🤔 Are you sure you want to delete the cluster? (yes/no): " CONFIRM

if [[ "${CONFIRM}" != "yes" ]]; then
  echo "❌ Cleanup cancelled"
  exit 0
fi

echo ""
echo "🔍 Checking if cluster exists..."

if ! gcloud container clusters describe ${CLUSTER_NAME} --zone=${ZONE} --project=${PROJECT_ID} &> /dev/null; then
  echo "⚠️  Cluster ${CLUSTER_NAME} does not exist or already deleted"
  exit 0
fi

echo "✅ Cluster found"
echo ""

# Optional: Save cluster info before deletion
echo "💾 Saving cluster information..."
kubectl get all -n nim > nim_resources_backup.yaml 2>/dev/null || true
kubectl get configmaps -n nim -o yaml > nim_configmaps_backup.yaml 2>/dev/null || true

echo ""
echo "🗑️  Deleting GKE cluster: ${CLUSTER_NAME}"
echo "   This may take 5-10 minutes..."
echo ""

gcloud container clusters delete ${CLUSTER_NAME} \
  --zone=${ZONE} \
  --project=${PROJECT_ID} \
  --quiet

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Cleanup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Resources deleted:"
echo "   ✅ GKE cluster: ${CLUSTER_NAME}"
echo "   ✅ GPU node pool: gpupool"
echo "   ✅ All pods and services"
echo ""
echo "💾 Backup files created (if resources existed):"
echo "   - nim_resources_backup.yaml"
echo "   - nim_configmaps_backup.yaml"
echo ""
echo "💰 Cost impact: Cluster charges have stopped"
echo ""
echo "🔄 To redeploy, run: ./deploy_nim_gke.sh"
echo ""

# Optional: Clean up local files
read -p "🧹 Delete local helm charts and config files? (yes/no): " CLEAN_LOCAL

if [[ "${CLEAN_LOCAL}" == "yes" ]]; then
  rm -f nim-llm-*.tgz
  rm -f nim_custom_value.yaml
  echo "✅ Local files cleaned up"
fi

echo ""
echo "🎉 Done! Your GCP project is now clean."

