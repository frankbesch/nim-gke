#!/bin/bash

# ============================================
# 🚀 Deploy NVIDIA NIM Only (Cluster Already Exists)
# ============================================
#
# Use this after:
# 1. Cluster is created (deploy_nim_gke.sh step 1-5)
# 2. GPU node pool is added (add_gpu_nodepool.sh)
#

set -e

# --- Configuration ---
export PROJECT_ID="your-gcp-project"
export ZONE="us-central1-a"
export CLUSTER_NAME="nim-demo"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Deploying NVIDIA NIM to Existing Cluster"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# --- Check NGC API Key ---
if [[ -z "${NGC_CLI_API_KEY}" ]]; then
  echo "❌ ERROR: NGC_CLI_API_KEY environment variable is not set!"
  echo "   Run: export NGC_CLI_API_KEY='your-key-here'"
  echo "   Or: source ./set_ngc_key.sh"
  exit 1
fi

echo "✅ NGC_CLI_API_KEY is set"
echo ""

# --- Get Cluster Credentials ---
echo "🔑 Getting cluster credentials..."
gcloud container clusters get-credentials ${CLUSTER_NAME} --zone=${ZONE}

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

# --- Fetch NIM Helm Chart ---
echo "📦 Fetching NIM LLM Helm chart..."
if [ ! -f "nim-llm-1.3.0.tgz" ]; then
  helm fetch https://helm.ngc.nvidia.com/nim/charts/nim-llm-1.3.0.tgz \
    --username='$oauthtoken' \
    --password=${NGC_CLI_API_KEY}
  echo "✅ Helm chart downloaded"
else
  echo "✅ Helm chart already exists"
fi

# --- Create NIM Namespace ---
echo ""
echo "🏷️  Creating NIM namespace..."
kubectl create namespace nim --dry-run=client -o yaml | kubectl apply -f -

# --- Configure Kubernetes Secrets ---
echo ""
echo "🔐 Configuring Kubernetes secrets..."

kubectl create secret docker-registry registry-secret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password=${NGC_CLI_API_KEY} \
  -n nim \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic ngc-api \
  --from-literal=NGC_API_KEY=${NGC_CLI_API_KEY} \
  -n nim \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Secrets configured"

# --- Create NIM Configuration ---
echo ""
echo "📝 Creating NIM configuration file..."

cat <<EOF > nim_custom_value.yaml
image:
  repository: "nvcr.io/nim/meta/llama3-8b-instruct"
  tag: "1.0.0"
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

helm install my-nim nim-llm-1.3.0.tgz \
  -f nim_custom_value.yaml \
  --namespace nim

echo ""
echo "✅ NIM deployment initiated"

# --- Monitor Deployment ---
echo ""
echo "👀 Monitoring NIM deployment..."
sleep 10

kubectl get pods -n nim

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 NVIDIA NIM Deployment Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📌 Next Steps:"
echo ""
echo "1️⃣  Wait for pod to be ready (may take 10-20 minutes):"
echo "   kubectl get pods -n nim -w"
echo ""
echo "2️⃣  Check logs:"
echo "   kubectl logs -f -n nim \$(kubectl get pods -n nim -o jsonpath='{.items[0].metadata.name}')"
echo ""
echo "3️⃣  Once ready, test the deployment:"
echo "   # Terminal 1: Port forward"
echo "   kubectl port-forward service/my-nim-nim-llm 8000:8000 -n nim"
echo ""
echo "   # Terminal 2: Test"
echo "   ./test_nim.sh"
echo ""
echo "🗑️  To cleanup:"
echo "   ./cleanup.sh"
echo ""

