#!/bin/bash

# ============================================
# 🚀 NVIDIA NIM on GKE - DevOps Optimized Deployment
# ============================================
#
# Streamlined deployment script based on official Google Codelabs tutorial
# Optimized for production-ready, fault-tolerant execution
#

set -euo pipefail  # Strict error handling

source "$(dirname "${BASH_SOURCE[0]}")/config.env"

# --- [1] ENVIRONMENT VALIDATION ---
validate_environment() {
    echo "🔍 Validating environment..."

    # Check required tools
    local tools=("gcloud" "kubectl" "helm" "jq")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            echo "❌ $tool not found. Please install it first."
            exit 1
        fi
    done

    # Check NGC API key
    if [[ -z "${NGC_API_KEY}" ]]; then
        echo "❌ NGC_API_KEY not set. Run: export NGC_API_KEY=..."
        exit 1
    fi

    require_project_id

    # Check GCP authentication
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
        echo "❌ Not authenticated with GCP. Run: gcloud auth login"
        exit 1
    fi

    echo "✅ Environment validation passed"
}

# --- [2] GCP CONFIGURATION ---
configure_gcp() {
    echo "⚙️  Confirming GCP target..."

    echo "✅ GCP target confirmed (project/region/zone passed per-command via --project, not set globally)"
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
        if ! gcloud services list --enabled --project="${PROJECT_ID}" --filter="name:$api" --format="value(name)" | grep -q "$api"; then
            echo "  Enabling $api..."
            gcloud services enable "$api" --project="${PROJECT_ID}" --quiet
        fi
    done

    echo "✅ APIs enabled"
}

# --- [4] CREATE GKE CLUSTER ---
create_cluster() {
    echo "🏗️  Creating GKE cluster: ${CLUSTER_NAME}"

    if gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
        echo "⚠️  Cluster ${CLUSTER_NAME} already exists, skipping creation"
    else
        gcloud container clusters create "${CLUSTER_NAME}" \
            --project="${PROJECT_ID}" \
            --location="${ZONE}" \
            --release-channel=rapid \
            --machine-type="${CLUSTER_MACHINE_TYPE}" \
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

    if gcloud container node-pools describe gpupool --cluster="${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
        echo "⚠️  GPU node pool 'gpupool' already exists, skipping creation"
    else
        gcloud container node-pools create gpupool \
            --accelerator type="${GPU_TYPE}",count="${GPU_COUNT}",gpu-driver-version=latest \
            --project="${PROJECT_ID}" \
            --location="${ZONE}" \
            --cluster="${CLUSTER_NAME}" \
            --machine-type="${NODE_POOL_MACHINE_TYPE}" \
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
    gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}"
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

    local chart_file="nim-llm-${NIM_CHART_VERSION}.tgz"

    if [[ -f "$chart_file" ]]; then
        echo "✅ Helm chart already exists"
    else
        ngc_fetch_chart "$(dirname "$chart_file")"
        echo "✅ Helm chart downloaded"
    fi
}

# --- [9] CREATE NIM NAMESPACE ---
create_namespace() {
    echo "🏷️  Creating namespace: ${NIM_NAMESPACE}"
    kubectl create namespace "${NIM_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    echo "✅ Namespace created"
}

# --- [10] CONFIGURE KUBERNETES SECRETS ---
configure_secrets() {
    echo "🔐 Configuring Kubernetes secrets..."

    # registry-secret and ngc-api; see ngc_apply_secrets in config.env
    ngc_apply_secrets "${NIM_NAMESPACE}"

    echo "✅ Secrets configured"
}

# --- [11] CREATE NIM CONFIGURATION ---
create_nim_config() {
    echo "📝 Creating NIM configuration..."

    cat <<EOF > nim_custom_value.yaml
image:
  repository: "${NIM_IMAGE_REPO}"
  tag: "${NIM_IMAGE_TAG}"
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
  cloud.google.com/gke-accelerator: ${GPU_TYPE}
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

    local chart_file="nim-llm-${NIM_CHART_VERSION}.tgz"

    helm upgrade --install "${NIM_RELEASE_NAME}" "$chart_file" \
        -f nim_custom_value.yaml \
        --namespace "${NIM_NAMESPACE}" \
        --wait \
        --timeout=20m

    echo "✅ NIM deployment initiated"
}

# --- [13] MONITOR DEPLOYMENT ---
monitor_deployment() {
    echo "👀 Monitoring NIM deployment..."

    # The nim-llm chart renders a StatefulSet, not a Deployment.
    kubectl rollout status statefulset/"${NIM_RELEASE_NAME}-nim-llm" \
        --namespace="${NIM_NAMESPACE}" \
        --timeout=600s

    # Show pod status
    kubectl get pods -n "${NIM_NAMESPACE}" -o wide

    # Show service status
    kubectl get services -n "${NIM_NAMESPACE}"

    echo "✅ NIM deployment ready"
}

# --- [14] VERIFY DEPLOYMENT ---
verify_deployment() {
    echo "🧪 Verifying NIM deployment..."

    # Check if pod is running
    local pod_status
    pod_status=$(kubectl get pods -n "${NIM_NAMESPACE}" -o jsonpath='{.items[0].status.phase}')

    if [[ "$pod_status" != "Running" ]]; then
        echo "❌ Pod is not running. Status: $pod_status"
        kubectl describe pod -n "${NIM_NAMESPACE}" "$(kubectl get pods -n "${NIM_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')"
        exit 1
    fi

    # The chart's service is ClusterIP (no external IP); reach it by port-forward.
    kubectl get service "${NIM_RELEASE_NAME}-nim-llm" -n "${NIM_NAMESPACE}" > /dev/null
    echo "✅ Service ${NIM_RELEASE_NAME}-nim-llm exists (ClusterIP)"
    echo "   Access: kubectl port-forward -n ${NIM_NAMESPACE} svc/${NIM_RELEASE_NAME}-nim-llm 8000:8000"

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
    echo "   kubectl port-forward service/${NIM_RELEASE_NAME}-nim-llm 8000:8000 -n ${NIM_NAMESPACE}"
    echo ""
    echo "2️⃣  Test the deployment:"
    echo "   ./test_nim.sh"
    echo ""
    echo "3️⃣  Monitor resources:"
    echo "   kubectl get pods -n ${NIM_NAMESPACE} -w"
    echo "   kubectl logs -f -n ${NIM_NAMESPACE} \$(kubectl get pods -n ${NIM_NAMESPACE} -o jsonpath='{.items[0].metadata.name}')"
    echo ""
    echo "4️⃣  Cleanup when done:"
    echo "   ./cleanup.sh"
    echo ""
    echo "💰 Current cost: about \$0.98/hour (measured, docs/runs/2026-09-27-run-1-fixed.md)"
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
