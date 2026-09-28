#!/bin/bash

# ============================================
# 🚀 Deploy NVIDIA NIM on GKE
# Based on: https://codelabs.developers.google.com/codelabs/nvidia-nim-google-cloud
# ============================================

set -euo pipefail  # Exit on error, unset var, or pipe failure

source "$(dirname "${BASH_SOURCE[0]}")/config.env"

echo "🎯 Configuration:"
echo "   Project: ${PROJECT_ID}"
echo "   Region: ${REGION}"
echo "   Zone: ${ZONE}"
echo "   Cluster: ${CLUSTER_NAME}"
echo "   GPU Type: ${GPU_TYPE}"
echo ""

# --- [1] Check NGC API Key and project ---
if [[ -z "${NGC_API_KEY}" ]]; then
  echo "❌ ERROR: NGC_API_KEY environment variable is not set!"
  echo "   Create a Personal Key with the NGC Catalog service: https://org.ngc.nvidia.com/setup/api-key"
  echo "   Then run: export NGC_API_KEY='your-key-here'"
  exit 1
else
  echo "✅ NGC_API_KEY is set"
fi
require_project_id

# --- [2] Verify Prerequisites ---
echo ""
echo "🔍 Checking prerequisites..."

if ! command -v gcloud &> /dev/null; then
  echo "❌ gcloud not found"
  exit 1
fi

if ! command -v kubectl &> /dev/null; then
  echo "❌ kubectl not found. Run: gcloud components install kubectl"
  exit 1
fi

if ! command -v helm &> /dev/null; then
  echo "❌ Helm not found. Install from: https://helm.sh/docs/intro/install/"
  exit 1
fi

echo "✅ All prerequisites met (gcloud, kubectl, helm)"

# --- [3] Working directory for fetched artifacts ---
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
echo ""
echo "📁 Using temp working dir: ${WORK_DIR}"

# --- [4] Create GKE Cluster ---
echo ""
echo "🏗️  Creating GKE cluster: ${CLUSTER_NAME}"
echo "   This may take 5-10 minutes..."

if gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
  echo "⚠️  Cluster ${CLUSTER_NAME} already exists, skipping creation..."
else
  gcloud container clusters create "${CLUSTER_NAME}" \
      --project="${PROJECT_ID}" \
      --location="${ZONE}" \
      --release-channel=rapid \
      --machine-type="${CLUSTER_MACHINE_TYPE}" \
      --num-nodes=1

  echo "✅ GKE cluster created successfully"
fi

# --- [5] Create GPU Node Pool ---
echo ""
echo "🎮 Creating GPU node pool..."
echo "   This may take 5-10 minutes..."

if gcloud container node-pools describe gpupool --cluster="${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
  echo "⚠️  GPU node pool 'gpupool' already exists, skipping creation..."
else
  if [[ "${AUTOSCALE}" == "1" ]]; then
    echo "   AUTOSCALE=1: gpupool starts at 0 nodes; cluster autoscaler scales 0-${MAX_GPU_NODES}."
    gcloud container node-pools create gpupool \
        --accelerator type="${GPU_TYPE}",count="${GPU_COUNT}",gpu-driver-version=latest \
        --project="${PROJECT_ID}" \
        --location="${ZONE}" \
        --cluster="${CLUSTER_NAME}" \
        --machine-type="${NODE_POOL_MACHINE_TYPE}" \
        --num-nodes=0 \
        --enable-autoscaling \
        --min-nodes=0 \
        --max-nodes="${MAX_GPU_NODES}"
  else
    gcloud container node-pools create gpupool \
        --accelerator type="${GPU_TYPE}",count="${GPU_COUNT}",gpu-driver-version=latest \
        --project="${PROJECT_ID}" \
        --location="${ZONE}" \
        --cluster="${CLUSTER_NAME}" \
        --machine-type="${NODE_POOL_MACHINE_TYPE}" \
        --num-nodes=1
  fi

  echo "✅ GPU node pool created successfully"
fi

# --- [6] Get Cluster Credentials ---
echo ""
echo "🔑 Getting cluster credentials..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}"

# --- [7] Verify Cluster and Nodes ---
echo ""
echo "📊 Cluster status:"
kubectl get nodes
echo ""
kubectl get nodes -o wide

# --- [8] Fetch NIM Helm Chart ---
echo ""
echo "📦 Fetching NIM LLM Helm chart..."
CHART_FILE="${WORK_DIR}/nim-llm-${NIM_CHART_VERSION}.tgz"
ngc_fetch_chart "${WORK_DIR}"

echo "✅ Helm chart downloaded: ${CHART_FILE}"

# --- [9] Create NIM Namespace ---
echo ""
echo "🏷️  Creating NIM namespace..."
kubectl create namespace "${NIM_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# --- [10] Configure Kubernetes Secrets ---
echo ""
echo "🔐 Configuring Kubernetes secrets..."

# registry-secret (image pull) and ngc-api (NGC_API_KEY, the chart's contract);
# see ngc_apply_secrets in config.env. The key never appears on a command line.
ngc_apply_secrets "${NIM_NAMESPACE}"

echo "✅ Secrets configured"

# --- [11] Create NIM Configuration ---
echo ""
echo "📝 Creating NIM configuration file..."

VALUES_FILE="${WORK_DIR}/nim_custom_value.yaml"
cat <<EOF > "${VALUES_FILE}"
image:
  repository: "${NIM_IMAGE_REPO}" # container location
  tag: "${NIM_IMAGE_TAG}" # NIM version you want to deploy
model:
  ngcAPISecret: ngc-api  # name of a secret in the cluster that includes a key named NGC_API_KEY
persistence:
  enabled: true
imagePullSecrets:
  - name: registry-secret # name of a secret used to pull nvcr.io images
EOF

echo "✅ Configuration file created: ${VALUES_FILE}"
cat "${VALUES_FILE}"

# --- [12] Deploy NIM ---
echo ""
echo "🚀 Deploying NVIDIA NIM..."
echo "   This will download the model and may take 10-20 minutes..."

helm upgrade --install "${NIM_RELEASE_NAME}" "${CHART_FILE}" \
  -f "${VALUES_FILE}" \
  --namespace "${NIM_NAMESPACE}"

echo "✅ Deployment submitted; wait for pod Ready"

# --- [13] Monitor Deployment ---
echo ""
echo "👀 Monitoring NIM deployment..."
echo "   Waiting for pod to be ready (this may take 10-20 minutes)..."
if [[ "${AUTOSCALE}" == "1" ]]; then
  echo "   AUTOSCALE=1: gpupool has 0 nodes; the pod stays Pending until the"
  echo "   cluster autoscaler creates a GPU node (see run_measured.sh --autoscale)."
fi
echo ""

# Wait for pod to be created (does not require a GPU node to exist: the pod
# is expected to be Pending here when AUTOSCALE=1)
sleep 10

# Show pod status
kubectl get pods -n "${NIM_NAMESPACE}"

echo ""
echo "📊 To monitor the deployment in real-time, run:"
echo "   kubectl get pods -n ${NIM_NAMESPACE} -w"
echo ""
echo "📋 To check logs, run:"
echo "   kubectl logs -f -n ${NIM_NAMESPACE} \$(kubectl get pods -n ${NIM_NAMESPACE} -o jsonpath='{.items[0].metadata.name}')"
echo ""
echo "⏳ Please wait for the pod status to show 'Running' before testing."

# --- [14] Deployment Summary ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📌 Deployment submitted; wait for pod Ready"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📌 Next Steps:"
echo ""
echo "1️⃣  Wait for pod to be ready:"
echo "   kubectl get pods -n ${NIM_NAMESPACE} -w"
echo ""
echo "2️⃣  Once ready, forward the port (in a separate terminal):"
echo "   kubectl port-forward service/${NIM_RELEASE_NAME}-nim-llm 8000:8000 -n ${NIM_NAMESPACE}"
echo ""
echo "3️⃣  Test the NIM service:"
echo "   curl -X 'POST' \\"
echo "     'http://localhost:8000/v1/chat/completions' \\"
echo "     -H 'accept: application/json' \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{"
echo "     \"messages\": ["
echo "       {\"content\": \"You are a polite chatbot.\", \"role\": \"system\"},"
echo "       {\"content\": \"What should I do for a 4 day vacation in Spain?\", \"role\": \"user\"}"
echo "     ],"
echo "     \"model\": \"meta/llama3-8b-instruct\","
echo "     \"max_tokens\": 128,"
echo "     \"top_p\": 1,"
echo "     \"stream\": false"
echo "   }'"
echo ""
echo "🗑️  To cleanup when done:"
echo "   ./cleanup.sh"
echo ""
