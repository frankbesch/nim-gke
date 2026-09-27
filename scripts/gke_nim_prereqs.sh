#!/bin/bash

# ============================================
# 🧩 GKE + NVIDIA NIM Prerequisite Setup
# ============================================

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/config.env"

require_project_id

# --- [0] REQUIRED VARIABLES (not covered by shared config) ---
export BILLING_ACCOUNT="${BILLING_ACCOUNT:-YOUR_BILLING_ACCOUNT_ID}"
export ORG_ID="${ORG_ID:-}"                   # No organization configured
export USER_EMAIL="${USER_EMAIL:-your-email@example.com}"

# --- [1] Verify gcloud SDK installation ---
if ! command -v gcloud &> /dev/null; then
  echo "❌ Google Cloud SDK not installed. Please install from https://cloud.google.com/sdk/docs/install"
  exit 1
else
  echo "✅ gcloud SDK installed: $(gcloud version | head -n 1)"
fi

# --- [2] Authenticate & Confirm Target Project ---
gcloud auth login
echo "✅ Target project: ${PROJECT_ID} (region ${REGION}, zone ${ZONE})"

# --- [3] Confirm Billing & APIs Enabled ---
gcloud beta billing accounts list
gcloud beta billing projects describe "${PROJECT_ID}" | grep billingAccountName || \
  echo "⚠️  Project not linked to billing account — link in Cloud Console > Billing"

gcloud services enable \
  --project="${PROJECT_ID}" \
  container.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com

# --- [4] Check User IAM Roles ---
echo "🔍 Checking IAM roles for ${USER_EMAIL}"
gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten="bindings[].members" \
  --format='table(bindings.role)' \
  --filter="bindings.members:${USER_EMAIL}"

echo "✅ You should have at least project-editor level access (GKE, Compute, IAM service-account-user, Storage, project IAM admin)."
echo "   See required roles: https://cloud.google.com/iam/docs/understanding-roles"

# Assign missing roles via the Cloud Console IAM page or:
# gcloud projects add-iam-policy-binding "${PROJECT_ID}" --member="user:${USER_EMAIL}" --role="ROLE_NAME"

# --- [5] Check GPU Quotas ---
echo "🔍 Checking GPU quotas in ${REGION}"
gcloud compute regions describe "${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(quotas.metric,quotas.limit,quotas.usage)" | grep -i "gpus" || echo "   (no GPU quota rows returned)"

# If no GPU quota appears, request more:
# https://console.cloud.google.com/iam-admin/quotas?project=${PROJECT_ID}
# Filter by "NVIDIA L4 GPU" or "NVIDIA A100 GPU"

# --- [6] Service account for GKE ---
# No extra service account is needed: GKE node pools use the default
# Compute Engine service account with default scopes, and the NIM
# deployment authenticates to NGC via NGC_API_KEY, not GCP IAM.

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

# --- [9] Ready to Deploy ---
echo "🎉 Environment validated. Next step: run the NVIDIA NIM GKE tutorial."
