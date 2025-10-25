#!/bin/bash

# ============================================
# 🚀 NVIDIA NIM on GKE - DevOps Optimized Deployment
# ============================================
# 
# Streamlined deployment script based on official Google Codelabs tutorial
# Optimized for production-ready, fault-tolerant execution
#

set -euo pipefail  # Strict error handling

# --- [0] CONFIGURATION ---
readonly PROJECT_ID="your-gcp-project"
readonly REGION="us-central1"
readonly ZONE="us-central1-a"
readonly CLUSTER_NAME="nim-demo"
readonly NODE_POOL_MACHINE_TYPE="g2-standard-4"   # Cost-optimized
readonly CLUSTER_MACHINE_TYPE="e2-standard-4"
readonly GPU_TYPE="nvidia-l4"
readonly GPU_COUNT=1
readonly NIM_NAMESPACE="nim"
readonly NIM_RELEASE_NAME="my-nim"
readonly HELM_CHART_VERSION="1.3.0"

# --- [1] ENVIRONMENT VALIDATION ---
validate_environment() {
    echo "🔍 Validating environment..."
    
    # Check required tools
    local tools=("gcloud" "kubectl" "helm")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            echo "❌ $tool not found. Please install it first."
            exit 1
        fi
    done
    
    # Check NGC API key
    if [[ -z "${NGC_CLI_API_KEY:-}" ]]; then
        echo "❌ NGC_CLI_API_KEY not set. Run: source ./set_ngc_key.sh"
        exit 1
    fi
    
    # Check GCP authentication
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
        echo "❌ Not authenticated with GCP. Run: gcloud auth login"
        exit 1
    fi
    
    echo "✅ Environment validation passed"
}

# --- [2] GCP CONFIGURATION ---
configure_gcp() {
    echo "⚙️  Configuring GCP..."
    
    gcloud config set project "$PROJECT_ID"
    gcloud config set compute/region "$REGION"
    gcloud config set compute/zone "$ZONE"
    
    echo "✅ GCP configuration complete"
}

# --- [3] ENABLE REQUIRED APIs ---
enable_apis() {
    echo "🔌 Enabling required APIs..."
    
    local apis=(
        "container.googleapis.com"
        "compute.googleapis.com"
        "iam.googleapis.com"
        "cloudresourcemanager.googleapis.com"
        "serviceusage.googleapis.com"
    )
    
    for api in "${apis[@]}"; do
        if ! gcloud services list --enabled --filter="name:$api" --format="value(name)" | grep -q "$api"; then
            echo "  Enabling $api..."
            gcloud services enable "$api" --quiet
        fi
    done
    
    echo "✅ APIs enabled"
}

# --- [4] CREATE GKE CLUSTER ---
create_cluster() {
    echo "🏗️  Creating GKE cluster: $CLUSTER_NAME"
    
    if gcloud container clusters describe "$CLUSTER_NAME" --zone="$ZONE" &> /dev/null; then
        echo "⚠️  Cluster $CLUSTER_NAME already exists, skipping creation"
    else
        gcloud container clusters create "$CLUSTER_NAME" \
            --project="$PROJECT_ID" \
            --location="$ZONE" \
            --release-channel=rapid \
            --machine-type="$CLUSTER_MACHINE_TYPE" \
            --num-nodes=1 \
            --enable-autoscaling \
            --min-nodes=1 \
            --max-nodes=3 \
            --enable-autorepair \
            --enable-autoupgrade \
            --quiet
        
        echo "✅ GKE cluster created"
    fi
}

# --- [5] CREATE GPU NODE POOL ---
create_gpu_nodepool() {
    echo "🎮 Creating GPU node pool..."
    
    if gcloud container node-pools describe gpupool --cluster="$CLUSTER_NAME" --zone="$ZONE" &> /dev/null; then
        echo "⚠️  GPU node pool 'gpupool' already exists, skipping creation"
    else
        gcloud container node-pools create gpupool \
            --accelerator type="$GPU_TYPE",count="$GPU_COUNT",gpu-driver-version=latest \
            --project="$PROJECT_ID" \
            --location="$ZONE" \
            --cluster="$CLUSTER_NAME" \
            --machine-type="$NODE_POOL_MACHINE_TYPE" \
            --num-nodes=1 \
            --enable-autoscaling \
            --min-nodes=0 \
            --max-nodes=2 \
            --enable-autorepair \
            --enable-autoupgrade \
            --quiet
        
        echo "✅ GPU node pool created"
    fi
}

# --- [6] GET CLUSTER CREDENTIALS ---
get_credentials() {
    echo "🔑 Getting cluster credentials..."
    gcloud container clusters get-credentials "$CLUSTER_NAME" --zone="$ZONE"
    echo "✅ Credentials configured"
}

# --- [7] VERIFY CLUSTER STATUS ---
verify_cluster() {
    echo "📊 Verifying cluster status..."
    
    # Wait for nodes to be ready
    echo "  Waiting for nodes to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    # Show node status
    kubectl get nodes -o wide
    
    # Verify GPU nodes
    local gpu_nodes
    gpu_nodes=$(kubectl get nodes -o json | jq '[.items[] | select(.metadata.labels."cloud.google.com/gke-accelerator")] | length')
    
    if [[ "$gpu_nodes" -eq 0 ]]; then
        echo "❌ No GPU nodes found!"
        exit 1
    fi
    
    echo "✅ Found $gpu_nodes GPU node(s)"
}

# --- [8] FETCH NIM HELM CHART ---
fetch_helm_chart() {
    echo "📦 Fetching NIM Helm chart..."
    
    local chart_file="nim-llm-${HELM_CHART_VERSION}.tgz"
    
    if [[ -f "$chart_file" ]]; then
        echo "✅ Helm chart already exists"
    else
        helm fetch "https://helm.ngc.nvidia.com/nim/charts/nim-llm-${HELM_CHART_VERSION}.tgz" \
            --username='$oauthtoken' \
            --password="$NGC_CLI_API_KEY"
        echo "✅ Helm chart downloaded"
    fi
}

# --- [9] CREATE NIM NAMESPACE ---
create_namespace() {
    echo "🏷️  Creating namespace: $NIM_NAMESPACE"
    kubectl create namespace "$NIM_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    echo "✅ Namespace created"
}

# --- [10] CONFIGURE KUBERNETES SECRETS ---
configure_secrets() {
    echo "🔐 Configuring Kubernetes secrets..."
    
    # Docker registry secret
    kubectl create secret docker-registry registry-secret \
        --docker-server=nvcr.io \
        --docker-username='$oauthtoken' \
        --docker-password="$NGC_CLI_API_KEY" \
        -n "$NIM_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # NGC API key secret
    kubectl create secret generic ngc-api \
        --from-literal=NGC_CLI_API_KEY="$NGC_CLI_API_KEY" \
        -n "$NIM_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    echo "✅ Secrets configured"
}

# --- [11] CREATE NIM CONFIGURATION ---
create_nim_config() {
    echo "📝 Creating NIM configuration..."
    
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
resources:
  requests:
    nvidia.com/gpu: 1
  limits:
    nvidia.com/gpu: 1
nodeSelector:
  cloud.google.com/gke-accelerator: nvidia-l4
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
EOF
    
    echo "✅ Configuration file created"
}

# --- [12] DEPLOY NIM ---
deploy_nim() {
    echo "🚀 Deploying NVIDIA NIM..."
    
    local chart_file="nim-llm-${HELM_CHART_VERSION}.tgz"
    
    helm upgrade --install "$NIM_RELEASE_NAME" "$chart_file" \
        -f nim_custom_value.yaml \
        --namespace "$NIM_NAMESPACE" \
        --wait \
        --timeout=20m
    
    echo "✅ NIM deployment initiated"
}

# --- [13] MONITOR DEPLOYMENT ---
monitor_deployment() {
    echo "👀 Monitoring NIM deployment..."
    
    # Wait for deployment to be ready
    kubectl wait --for=condition=Available deployment/"$NIM_RELEASE_NAME-nim-llm" \
        --namespace="$NIM_NAMESPACE" \
        --timeout=600s
    
    # Show pod status
    kubectl get pods -n "$NIM_NAMESPACE" -o wide
    
    # Show service status
    kubectl get services -n "$NIM_NAMESPACE"
    
    echo "✅ NIM deployment ready"
}

# --- [14] VERIFY DEPLOYMENT ---
verify_deployment() {
    echo "🧪 Verifying NIM deployment..."
    
    # Check if pod is running
    local pod_status
    pod_status=$(kubectl get pods -n "$NIM_NAMESPACE" -o jsonpath='{.items[0].status.phase}')
    
    if [[ "$pod_status" != "Running" ]]; then
        echo "❌ Pod is not running. Status: $pod_status"
        kubectl describe pod -n "$NIM_NAMESPACE" "$(kubectl get pods -n "$NIM_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')"
        exit 1
    fi
    
    # Check if service is ready
    local service_ip
    service_ip=$(kubectl get service "$NIM_RELEASE_NAME-nim-llm" -n "$NIM_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    
    if [[ -z "$service_ip" ]]; then
        echo "⚠️  LoadBalancer IP not assigned yet (may take a few minutes)"
    else
        echo "✅ Service IP: $service_ip"
    fi
    
    echo "✅ Deployment verification complete"
}

# --- [15] DISPLAY SUCCESS INFO ---
display_success() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎉 NVIDIA NIM Deployment Complete!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📌 Next Steps:"
    echo ""
    echo "1️⃣  Port forward (in separate terminal):"
    echo "   kubectl port-forward service/$NIM_RELEASE_NAME-nim-llm 8000:8000 -n $NIM_NAMESPACE"
    echo ""
    echo "2️⃣  Test the deployment:"
    echo "   ./test_nim.sh"
    echo ""
    echo "3️⃣  Monitor resources:"
    echo "   kubectl get pods -n $NIM_NAMESPACE -w"
    echo "   kubectl logs -f -n $NIM_NAMESPACE \$(kubectl get pods -n $NIM_NAMESPACE -o jsonpath='{.items[0].metadata.name}')"
    echo ""
    echo "4️⃣  Cleanup when done:"
    echo "   ./cleanup.sh"
    echo ""
    echo "💰 Current cost: ~\$1.36/hour"
    echo ""
}

# --- MAIN EXECUTION ---
main() {
    echo "🚀 Starting NVIDIA NIM on GKE Deployment"
    echo "=========================================="
    echo ""
    
    validate_environment
    configure_gcp
    enable_apis
    create_cluster
    create_gpu_nodepool
    get_credentials
    verify_cluster
    fetch_helm_chart
    create_namespace
    configure_secrets
    create_nim_config
    deploy_nim
    monitor_deployment
    verify_deployment
    display_success
}

# Run main function
main "$@"
