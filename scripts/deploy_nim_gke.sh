#!/bin/bash

# ============================================
# 🚀 Deploy NVIDIA NIM on GKE
# Based on: https://codelabs.developers.google.com/codelabs/nvidia-nim-google-cloud
# ============================================

set -e  # Exit on error

# --- [0] CONFIGURATION VARIABLES ---
export PROJECT_ID="your-gcp-project"
export REGION="us-central1"
export ZONE="us-central1-a"
export CLUSTER_NAME="nim-demo"
export NODE_POOL_MACHINE_TYPE="g2-standard-4"   # For NVIDIA L4 GPU (cost-optimized)
export CLUSTER_MACHINE_TYPE="e2-standard-4"     # For control plane
export GPU_TYPE="nvidia-l4"
export GPU_COUNT=1

echo "🎯 Configuration:"
echo "   Project: ${PROJECT_ID}"
echo "   Region: ${REGION}"
echo "   Zone: ${ZONE}"
echo "   Cluster: ${CLUSTER_NAME}"
echo "   GPU Type: ${GPU_TYPE}"
echo ""

# --- [1] Check NGC API Key ---
if [[ -z "${NGC_CLI_API_KEY}" ]]; then
  echo "❌ ERROR: NGC_CLI_API_KEY environment variable is not set!"
  echo "   Please get your API key from: https://org.ngc.nvidia.com/setup/api-key"
  echo "   Then run: export NGC_CLI_API_KEY='your-key-here'"
  exit 1
else
  echo "✅ NGC_CLI_API_KEY is set"
fi

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

# --- [3] Set gcloud Configuration ---
echo ""
echo "⚙️  Configuring gcloud..."
gcloud config set project ${PROJECT_ID}
gcloud config set compute/region ${REGION}
gcloud config set compute/zone ${ZONE}

# --- [4] Create GKE Cluster ---
echo ""
echo "🏗️  Creating GKE cluster: ${CLUSTER_NAME}"
echo "   This may take 5-10 minutes..."

if gcloud container clusters describe ${CLUSTER_NAME} --zone=${ZONE} &> /dev/null; then
  echo "⚠️  Cluster ${CLUSTER_NAME} already exists, skipping creation..."
else
  gcloud container clusters create ${CLUSTER_NAME} \
      --project=${PROJECT_ID} \
      --location=${ZONE} \
      --release-channel=rapid \
      --machine-type=${CLUSTER_MACHINE_TYPE} \
      --num-nodes=1
  
  echo "✅ GKE cluster created successfully"
fi

# --- [5] Create GPU Node Pool ---
echo ""
echo "🎮 Creating GPU node pool..."
echo "   This may take 5-10 minutes..."

if gcloud container node-pools describe gpupool --cluster=${CLUSTER_NAME} --zone=${ZONE} &> /dev/null; then
  echo "⚠️  GPU node pool 'gpupool' already exists, skipping creation..."
else
  gcloud container node-pools create gpupool \
      --accelerator type=${GPU_TYPE},count=${GPU_COUNT},gpu-driver-version=latest \
      --project=${PROJECT_ID} \
      --location=${ZONE} \
      --cluster=${CLUSTER_NAME} \
      --machine-type=${NODE_POOL_MACHINE_TYPE} \
      --num-nodes=1
  
  echo "✅ GPU node pool created successfully"
fi

# --- [6] Get Cluster Credentials ---
echo ""
echo "🔑 Getting cluster credentials..."
gcloud container clusters get-credentials ${CLUSTER_NAME} --zone=${ZONE}

# --- [7] Verify Cluster and Nodes ---
echo ""
echo "📊 Cluster status:"
kubectl get nodes
echo ""
kubectl get nodes -o wide

# --- [8] Fetch NIM Helm Chart ---
echo ""
echo "📦 Fetching NIM LLM Helm chart..."
helm fetch https://helm.ngc.nvidia.com/nim/charts/nim-llm-1.3.0.tgz \
  --username='$oauthtoken' \
  --password=${NGC_CLI_API_KEY}

echo "✅ Helm chart downloaded: nim-llm-1.3.0.tgz"

# --- [9] Create NIM Namespace ---
echo ""
echo "🏷️  Creating NIM namespace..."
kubectl create namespace nim --dry-run=client -o yaml | kubectl apply -f -

# --- [10] Configure Kubernetes Secrets ---
echo ""
echo "🔐 Configuring Kubernetes secrets..."

# Docker registry secret for pulling NIM images
kubectl create secret docker-registry registry-secret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password=${NGC_CLI_API_KEY} \
  -n nim \
  --dry-run=client -o yaml | kubectl apply -f -

# NGC API key secret
kubectl create secret generic ngc-api \
  --from-literal=NGC_CLI_API_KEY=${NGC_CLI_API_KEY} \
  -n nim \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Secrets configured"

# --- [11] Create NIM Configuration ---
echo ""
echo "📝 Creating NIM configuration file..."

cat <<EOF > nim_custom_value.yaml
image:
  repository: "nvcr.io/nim/meta/llama3-8b-instruct" # container location
  tag: "1.0.0" # NIM version you want to deploy
model:
  ngcAPISecret: ngc-api  # name of a secret in the cluster that includes a key named NGC_CLI_API_KEY
persistence:
  enabled: true
imagePullSecrets:
  - name: registry-secret # name of a secret used to pull nvcr.io images
EOF

echo "✅ Configuration file created: nim_custom_value.yaml"
cat nim_custom_value.yaml

# --- [12] Deploy NIM ---
echo ""
echo "🚀 Deploying NVIDIA NIM..."
echo "   This will download the model and may take 10-20 minutes..."

helm install my-nim nim-llm-1.3.0.tgz \
  -f nim_custom_value.yaml \
  --namespace nim

echo "✅ NIM deployment initiated"

# --- [13] Monitor Deployment ---
echo ""
echo "👀 Monitoring NIM deployment..."
echo "   Waiting for pod to be ready (this may take 10-20 minutes)..."
echo ""

# Wait for pod to be created
sleep 10

# Show pod status
kubectl get pods -n nim

echo ""
echo "📊 To monitor the deployment in real-time, run:"
echo "   kubectl get pods -n nim -w"
echo ""
echo "📋 To check logs, run:"
echo "   kubectl logs -f -n nim \$(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}')"
echo ""
echo "⏳ Please wait for the pod status to show 'Running' before testing."

# --- [14] Deployment Summary ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 NVIDIA NIM Deployment Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📌 Next Steps:"
echo ""
echo "1️⃣  Wait for pod to be ready:"
echo "   kubectl get pods -n nim -w"
echo ""
echo "2️⃣  Once ready, forward the port (in a separate terminal):"
echo "   kubectl port-forward service/my-nim-nim-llm 8000:8000 -n nim"
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
echo "   gcloud container clusters delete ${CLUSTER_NAME} --zone=${ZONE}"
echo ""

