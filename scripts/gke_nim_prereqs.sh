#!/bin/bash

# ============================================
# 🧩 GKE + NVIDIA NIM Prerequisite Setup
# ============================================

# --- [0] REQUIRED VARIABLES ---
export PROJECT_ID="your-gcp-project"
export REGION="us-central1"        # change to your region
export ZONE="us-central1-a"        # change if needed
export BILLING_ACCOUNT="YOUR_BILLING_ACCOUNT_ID"
export ORG_ID=""                   # No organization configured
export USER_EMAIL="your-email@example.com"

# --- [1] Verify gcloud SDK installation ---
if ! command -v gcloud &> /dev/null; then
  echo "❌ Google Cloud SDK not installed. Please install from https://cloud.google.com/sdk/docs/install"
  exit 1
else
  echo "✅ gcloud SDK installed: $(gcloud version | head -n 1)"
fi

# --- [2] Authenticate & Set Project ---
gcloud auth login
gcloud config set project ${PROJECT_ID}
gcloud config set compute/region ${REGION}
gcloud config set compute/zone ${ZONE}

# --- [3] Confirm Billing & APIs Enabled ---
gcloud beta billing accounts list
gcloud beta billing projects describe ${PROJECT_ID} | grep billingAccountName || \
  echo "⚠️  Project not linked to billing account — link in Cloud Console > Billing"

gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com

# --- [4] Check User IAM Roles ---
echo "🔍 Checking IAM roles for ${USER_EMAIL}"
gcloud projects get-iam-policy ${PROJECT_ID} \
  --flatten="bindings[].members" \
  --format='table(bindings.role)' \
  --filter="bindings.members:${USER_EMAIL}"

echo "✅ You should have (at minimum):"
echo "   roles/container.admin, roles/compute.admin, roles/iam.serviceAccountUser, roles/storage.admin, roles/resourcemanager.projectIamAdmin"

# Assign if missing:
# gcloud projects add-iam-policy-binding ${PROJECT_ID} \
#   --member="user:${USER_EMAIL}" \
#   --role="roles/container.admin"

# --- [5] Check GPU Quotas ---
echo "🔍 Checking GPU quotas in ${REGION}"
gcloud compute regions describe ${REGION} \
  --format="value(quotas.metric,quotas.limit,quotas.usage)" | grep "GPUs"

# If no GPU quota appears, request more:
# https://console.cloud.google.com/iam-admin/quotas?project=${PROJECT_ID}
# Filter by "NVIDIA L4 GPU" or "NVIDIA A100 GPU"

# --- [6] Enable Service Account for GKE ---
export SA_NAME="gke-nim-sa"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create ${SA_NAME} --display-name "GKE NIM Service Account"

for ROLE in roles/container.admin roles/compute.admin roles/storage.admin roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${ROLE}"
done

gcloud iam service-accounts list | grep ${SA_NAME}

# --- [7] Confirm Docker & kubectl installed ---
if ! command -v kubectl &> /dev/null; then
  echo "❌ kubectl not found. Run: gcloud components install kubectl"
  exit 1
else
  echo "✅ kubectl installed."
fi

if ! command -v docker &> /dev/null; then
  echo "❌ Docker not installed. Install from https://docs.docker.com/get-docker/"
else
  echo "✅ Docker installed: $(docker --version)"
fi

# --- [8] Confirm NGC API keys ---
echo "🔍 Checking for NVIDIA NGC API keys..."
[[ -n "${NGC_API_KEY}" ]] && echo "✅ NGC_API_KEY found" || echo "⚠️ Missing NGC_API_KEY"
[[ -n "${NGC_DOCKER_API_KEY}" ]] && echo "✅ NGC_DOCKER_API_KEY found" || echo "⚠️ Missing NGC_DOCKER_API_KEY"

# --- [9] Ready to Deploy ---
echo "🎉 Environment validated. Next step: run the NVIDIA NIM GKE tutorial."

