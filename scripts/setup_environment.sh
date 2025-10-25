#!/bin/bash

# ============================================
# 🔧 NVIDIA NIM Environment Setup & Validation
# ============================================

set -euo pipefail

# --- [0] CONFIGURATION ---
readonly PROJECT_ID="your-gcp-project"
readonly REGION="us-central1"
readonly ZONE="us-central1-a"
readonly NGC_API_KEY="YOUR_NGC_API_KEY_HERE"

# --- [1] ENVIRONMENT SETUP ---
setup_environment() {
    echo "🔧 Setting up environment..."
    
    # Add gcloud to PATH if not already there
    if ! echo "$PATH" | grep -q "/opt/homebrew/share/google-cloud-sdk/bin"; then
        export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"
        echo "export PATH=\"/opt/homebrew/share/google-cloud-sdk/bin:\$PATH\"" >> ~/.zshrc
        echo "✅ Added gcloud to PATH"
    fi
    
    # Set NGC API key
    export NGC_CLI_API_KEY="$NGC_API_KEY"
    echo "export NGC_CLI_API_KEY=\"$NGC_API_KEY\"" >> ~/.zshrc
    echo "✅ NGC API key configured"
    
    echo "✅ Environment setup complete"
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
    
    # Check if already authenticated
    if gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
        echo "✅ Already authenticated with GCP"
    else
        echo "🔑 Authenticating with GCP..."
        gcloud auth login
    fi
    
    # Configure project
    gcloud config set project "$PROJECT_ID"
    gcloud config set compute/region "$REGION"
    gcloud config set compute/zone "$ZONE"
    
    echo "✅ GCP authentication complete"
}

# --- [4] API ENABLEMENT ---
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
        else
            echo "  ✅ $api already enabled"
        fi
    done
    
    echo "✅ All APIs enabled"
}

# --- [5] QUOTA VALIDATION ---
validate_quotas() {
    echo "📊 Validating quotas..."
    
    # Check CPU quota
    local cpu_quota
    cpu_quota=$(gcloud compute project-info describe --format="value(quotas.metric,quotas.limit)" | tr ';' '\n' | grep "CPUS_ALL_REGIONS" | cut -d',' -f2)
    
    if [[ -z "$cpu_quota" ]] || [[ "$cpu_quota" -lt 8 ]]; then
        echo "⚠️  CPU quota may be insufficient (need at least 8 CPUs)"
        echo "   Current limit: ${cpu_quota:-unknown}"
        echo "   Request increase at: https://console.cloud.google.com/iam-admin/quotas?project=$PROJECT_ID"
    else
        echo "✅ CPU quota sufficient: $cpu_quota CPUs"
    fi
    
    # Check GPU quota
    local gpu_quota
    gpu_quota=$(gcloud compute regions describe "$REGION" --format="value(quotas.metric,quotas.limit)" | tr ';' '\n' | grep "NVIDIA_L4_GPUS" | cut -d',' -f2)
    
    if [[ -z "$gpu_quota" ]] || [[ "$gpu_quota" -lt 1 ]]; then
        echo "❌ GPU quota insufficient (need at least 1 NVIDIA L4 GPU)"
        echo "   Current limit: ${gpu_quota:-0}"
        echo "   Request increase at: https://console.cloud.google.com/iam-admin/quotas?project=$PROJECT_ID"
        exit 1
    else
        echo "✅ GPU quota sufficient: $gpu_quota NVIDIA L4 GPU(s)"
    fi
}

# --- [6] BILLING VALIDATION ---
validate_billing() {
    echo "💳 Validating billing..."
    
    local billing_status
    billing_status=$(gcloud beta billing projects describe "$PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null || echo "false")
    
    if [[ "$billing_status" != "true" ]]; then
        echo "❌ Billing not enabled for project $PROJECT_ID"
        echo "   Enable billing at: https://console.cloud.google.com/billing"
        exit 1
    else
        echo "✅ Billing enabled"
    fi
}

# --- [7] NGC VALIDATION ---
validate_ngc() {
    echo "🔑 Validating NGC API key..."
    
    if [[ -z "${NGC_CLI_API_KEY:-}" ]]; then
        echo "❌ NGC_CLI_API_KEY not set"
        exit 1
    fi
    
    # Test NGC API key by trying to fetch a chart
    if helm fetch "https://helm.ngc.nvidia.com/nim/charts/nim-llm-1.3.0.tgz" \
        --username='$oauthtoken' \
        --password="$NGC_CLI_API_KEY" \
        --dry-run &> /dev/null; then
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
    echo "  Project ID: $PROJECT_ID"
    echo "  Region: $REGION"
    echo "  Zone: $ZONE"
    echo "  NGC API Key: ${NGC_CLI_API_KEY:0:20}..."
    echo ""
    echo "🚀 Ready to deploy! Run:"
    echo "  ./deploy_nim_production.sh"
    echo ""
    echo "📊 Monitor with:"
    echo "  kubectl get pods -n nim -w"
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
