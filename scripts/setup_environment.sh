#!/bin/bash

# ============================================
# 🔧 NVIDIA NIM Environment Setup & Validation
# ============================================

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/config.env"

# --- [1] ENVIRONMENT SETUP ---
setup_environment() {
    echo "🔧 Checking environment..."

    # Suggest gcloud PATH entry; do not modify the user's shell rc files.
    if ! echo "$PATH" | grep -q "/opt/homebrew/share/google-cloud-sdk/bin"; then
        echo "ℹ️  gcloud is not on PATH for this shell. Add it yourself if desired:"
        echo "   export PATH=\"/opt/homebrew/share/google-cloud-sdk/bin:\$PATH\""
    else
        echo "✅ gcloud already on PATH"
    fi

    # Report NGC key status without printing it or writing it anywhere.
    if [[ -z "${NGC_API_KEY}" ]]; then
        echo "❌ NGC_API_KEY not set. Export it yourself, e.g.:"
        echo "   export NGC_API_KEY=\"your-key-here\""
    else
        echo "✅ NGC_API_KEY is set"
    fi

    echo "✅ Environment check complete"
}

# --- [2] TOOL VALIDATION ---
validate_tools() {
    echo "🔍 Validating required tools..."

    local tools=("gcloud" "kubectl" "helm" "jq" "curl")
    local missing_tools=()

    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo "❌ Missing tools: ${missing_tools[*]}"
        echo ""
        echo "Install missing tools:"
        for tool in "${missing_tools[@]}"; do
            case "$tool" in
                "gcloud")
                    echo "  brew install --cask google-cloud-sdk"
                    ;;
                "kubectl")
                    echo "  brew install kubectl"
                    ;;
                "helm")
                    echo "  brew install helm"
                    ;;
                "jq")
                    echo "  brew install jq"
                    ;;
                "curl")
                    echo "  curl is usually pre-installed on macOS"
                    ;;
            esac
        done
        exit 1
    fi

    echo "✅ All required tools are installed"
}

# --- [3] GCP AUTHENTICATION ---
setup_gcp_auth() {
    echo "🔐 Setting up GCP authentication..."

    require_project_id

    # Check if already authenticated
    if gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
        echo "✅ Already authenticated with GCP"
    else
        echo "🔑 Authenticating with GCP..."
        gcloud auth login
    fi

    echo "✅ GCP authentication complete (project/region/zone passed per-command via --project, not set globally)"
}

# --- [4] API ENABLEMENT ---
enable_apis() {
    echo "🔌 Enabling required APIs..."

    require_project_id

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
        else
            echo "  ✅ $api already enabled"
        fi
    done

    echo "✅ All APIs enabled"
}

# --- [5] QUOTA VALIDATION ---
# Print the integer limit of one quota metric from gcloud JSON on stdin (empty if absent).
quota_limit() {
    python3 -c 'import json, sys
m = sys.argv[1]
d = json.load(sys.stdin)
print(next((int(q["limit"]) for q in d.get("quotas", []) if q.get("metric") == m), ""))' "$1"
}

validate_quotas() {
    echo "📊 Validating quotas..."

    require_project_id

    # Check CPU quota
    local cpu_quota
    cpu_quota=$(gcloud compute project-info describe --project="${PROJECT_ID}" --format=json | quota_limit CPUS_ALL_REGIONS)

    if [[ -z "$cpu_quota" ]] || [[ "$cpu_quota" -lt 8 ]]; then
        echo "⚠️  CPU quota may be insufficient (need at least 8 CPUs)"
        echo "   Current limit: ${cpu_quota:-unknown}"
        echo "   Request increase at: https://console.cloud.google.com/iam-admin/quotas?project=${PROJECT_ID}"
    else
        echo "✅ CPU quota sufficient: $cpu_quota CPUs"
    fi

    # Check GPU quota
    local gpu_quota
    gpu_quota=$(gcloud compute regions describe "${REGION}" --project="${PROJECT_ID}" --format=json | quota_limit NVIDIA_L4_GPUS)

    if [[ -z "$gpu_quota" ]] || [[ "$gpu_quota" -lt 1 ]]; then
        echo "❌ GPU quota insufficient (need at least 1 NVIDIA L4 GPU)"
        echo "   Current limit: ${gpu_quota:-0}"
        echo "   Request increase at: https://console.cloud.google.com/iam-admin/quotas?project=${PROJECT_ID}"
        exit 1
    else
        echo "✅ GPU quota sufficient: $gpu_quota NVIDIA L4 GPU(s)"
    fi
}

# --- [6] BILLING VALIDATION ---
validate_billing() {
    echo "💳 Validating billing..."

    require_project_id

    local billing_status
    billing_status=$(gcloud beta billing projects describe "${PROJECT_ID}" --format="value(billingEnabled)" 2>/dev/null || echo "false")

    if [[ "$billing_status" != "true" ]]; then
        echo "❌ Billing not enabled for project ${PROJECT_ID}"
        echo "   Enable billing at: https://console.cloud.google.com/billing"
        exit 1
    else
        echo "✅ Billing enabled"
    fi
}

# --- [7] NGC VALIDATION ---
validate_ngc() {
    echo "🔑 Validating NGC API key..."

    if [[ -z "${NGC_API_KEY}" ]]; then
        echo "❌ NGC_API_KEY not set"
        exit 1
    fi

    # Test NGC API key by trying to fetch a chart
    if ngc_curl -fsS -r 0-0 -o /dev/null "${NIM_CHART_URL}" 2> /dev/null; then
        echo "✅ NGC API key is valid"
    else
        echo "❌ NGC API key validation failed"
        echo "   Check your key at: https://org.ngc.nvidia.com/setup/api-key"
        exit 1
    fi
}

# --- [8] NETWORK VALIDATION ---
validate_network() {
    echo "🌐 Validating network connectivity..."

    # Test internet connectivity
    if ! curl -s --max-time 10 "https://www.google.com" > /dev/null; then
        echo "❌ No internet connectivity"
        exit 1
    fi

    # Test GCP connectivity
    if ! curl -s --max-time 10 "https://container.googleapis.com" > /dev/null; then
        echo "❌ Cannot reach GCP APIs"
        exit 1
    fi

    # Test NGC connectivity
    if ! curl -s --max-time 10 "https://helm.ngc.nvidia.com" > /dev/null; then
        echo "❌ Cannot reach NVIDIA NGC"
        exit 1
    fi

    echo "✅ Network connectivity validated"
}

# --- [9] DISPLAY SUMMARY ---
display_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Environment Validation Complete!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📋 Configuration Summary:"
    echo "  Project ID: ${PROJECT_ID}"
    echo "  Region: ${REGION}"
    echo "  Zone: ${ZONE}"
    if [[ -n "${NGC_API_KEY}" ]]; then
        echo "  NGC API Key: set (not displayed)"
    else
        echo "  NGC API Key: not set"
    fi
    echo ""
    echo "🚀 Ready to deploy! Run:"
    echo "  ./deploy_nim_production.sh"
    echo ""
    echo "📊 Monitor with:"
    echo "  kubectl get pods -n ${NIM_NAMESPACE} -w"
    echo ""
    echo "🧪 Test with:"
    echo "  ./test_nim_production.sh"
    echo ""
}

# --- MAIN EXECUTION ---
main() {
    echo "🔧 NVIDIA NIM Environment Setup & Validation"
    echo "=============================================="
    echo ""

    setup_environment
    validate_tools
    setup_gcp_auth
    enable_apis
    validate_quotas
    validate_billing
    validate_ngc
    validate_network
    display_summary
}

# Run main function
main "$@"
