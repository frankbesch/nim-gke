#!/bin/bash

# ============================================
# 🚀 Deploy NVIDIA NIM Only (Cluster Already Exists)
# ============================================
#
# Use this after:
# 1. Cluster is created (deploy_nim_gke.sh step 1-5)
# 2. GPU node pool is added (add_gpu_nodepool.sh)
#

set -euo pipefail

# --- Configuration ---
source "$(dirname "${BASH_SOURCE[0]}")/config.env"
require_project_id

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Deploying NVIDIA NIM to Existing Cluster"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# --- Check NGC API Key ---
if [[ -z "${NGC_API_KEY}" ]]; then
  echo "❌ ERROR: NGC_API_KEY environment variable is not set!"
  echo "   Run: export NGC_API_KEY='your-key-here'"
  echo "   Or: source ./set_ngc_key.sh"
  exit 1
fi

echo "✅ NGC_API_KEY is set"
echo ""

# --- Get Cluster Credentials ---
echo "🔑 Getting cluster credentials..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}"

# --- Verify Cluster and GPU Nodes ---
echo ""
echo "📊 Verifying cluster and GPU nodes..."
kubectl get nodes

GPU_NODE_COUNT=$(kubectl get nodes -o json | jq '[.items[] | select(.metadata.labels."cloud.google.com/gke-accelerator")] | length')

if [[ "${GPU_NODE_COUNT}" -eq "0" ]]; then
  echo ""
  echo "❌ No GPU nodes found in cluster!"
  echo "   Please run: ./add_gpu_nodepool.sh"
  exit 1
fi

echo "✅ Found ${GPU_NODE_COUNT} GPU node(s)"
echo ""

# --- Work in a temp directory ---
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# --- Fetch NIM Helm Chart ---
echo "📦 Fetching NIM LLM Helm chart..."
if [ ! -f "${WORK_DIR}/nim-llm-${NIM_CHART_VERSION}.tgz" ]; then
  ngc_fetch_chart "${WORK_DIR}"
  echo "✅ Helm chart downloaded"
else
  echo "✅ Helm chart already exists"
fi

# --- Create NIM Namespace ---
echo ""
echo "🏷️  Creating NIM namespace..."
kubectl create namespace "${NIM_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# --- Configure Kubernetes Secrets ---
echo ""
echo "🔐 Configuring Kubernetes secrets..."

ngc_apply_secrets "${NIM_NAMESPACE}"

echo "✅ Secrets configured"

# --- Create NIM Configuration ---
echo ""
echo "📝 Creating NIM configuration file..."

cat <<EOF > "${WORK_DIR}/nim_custom_value.yaml"
image:
  repository: "${NIM_IMAGE_REPO}"
  tag: "${NIM_IMAGE_TAG}"
model:
  ngcAPISecret: ngc-api
persistence:
  enabled: true
imagePullSecrets:
  - name: registry-secret
EOF

echo "✅ Configuration file created"

# --- Deploy NIM ---
echo ""
echo "🚀 Deploying NVIDIA NIM..."
echo "   This will download the model and may take 10-20 minutes..."
echo ""

helm upgrade --install "${NIM_RELEASE_NAME}" "${WORK_DIR}/nim-llm-${NIM_CHART_VERSION}.tgz" \
  -f "${WORK_DIR}/nim_custom_value.yaml" \
  --namespace "${NIM_NAMESPACE}"

echo ""
echo "✅ NIM deployment initiated"

# --- Monitor Deployment ---
echo ""
echo "👀 Monitoring NIM deployment..."
sleep 10

kubectl get pods -n "${NIM_NAMESPACE}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 NVIDIA NIM Deployment Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📌 Next Steps:"
echo ""
echo "1️⃣  Wait for pod to be ready (may take 10-20 minutes):"
echo "   kubectl get pods -n ${NIM_NAMESPACE} -w"
echo ""
echo "2️⃣  Check logs:"
echo "   kubectl logs -f -n ${NIM_NAMESPACE} \$(kubectl get pods -n ${NIM_NAMESPACE} -o jsonpath='{.items[0].metadata.name}')"
echo ""
echo "3️⃣  Once ready, test the deployment:"
echo "   # Terminal 1: Port forward"
echo "   kubectl port-forward service/${NIM_RELEASE_NAME}-nim-llm 8000:8000 -n ${NIM_NAMESPACE}"
echo ""
echo "   # Terminal 2: Test"
echo "   ./test_nim.sh"
echo ""
echo "🗑️  To cleanup:"
echo "   ./cleanup.sh"
echo ""
