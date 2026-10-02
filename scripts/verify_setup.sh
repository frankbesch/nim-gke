#!/bin/bash

# ============================================
# Verify NIM-GKE Setup
# Quick environment and repository validation
# ============================================

set -euo pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
if [ -f "${SCRIPT_DIR}/config.env" ]; then
  source "${SCRIPT_DIR}/config.env"
else
  echo "❌ ${SCRIPT_DIR}/config.env MISSING; cannot continue" >&2
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 NIM-GKE Setup Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

EXIT_CODE=0

# --- Repository Structure ---
echo "📁 Repository Structure"
echo "────────────────────────────────────────────────────────────"

REQUIRED_DIRS=("charts" "scripts" "docs" "runbooks" "examples" ".github")
for dir in "${REQUIRED_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    echo "  ✅ $dir/"
  else
    echo "  ❌ $dir/ MISSING"
    EXIT_CODE=1
  fi
done
echo ""

# --- Scripts ---
echo "🔧 Scripts"
echo "────────────────────────────────────────────────────────────"

REQUIRED_SCRIPTS=(
  "scripts/deploy_nim_gke.sh"
  "scripts/cleanup.sh"
  "scripts/test_nim.sh"
  "scripts/setup_environment.sh"
)

for script in "${REQUIRED_SCRIPTS[@]}"; do
  if [ -f "$script" ] && [ -x "$script" ]; then
    echo "  ✅ $script"
  elif [ -f "$script" ]; then
    echo "  ⚠️  $script (not executable; mark it executable before running)"
  else
    echo "  ❌ $script MISSING"
    EXIT_CODE=1
  fi
done
echo ""

# --- Configuration Sourcing ---
echo "🧩 Shared Config"
echo "────────────────────────────────────────────────────────────"

if [ -f "scripts/config.env" ]; then
  echo "  ✅ scripts/config.env"
else
  echo "  ❌ scripts/config.env MISSING"
  EXIT_CODE=1
fi
echo ""

# --- Documentation ---
echo "📚 Documentation"
echo "────────────────────────────────────────────────────────────"

REQUIRED_DOCS=(
  "README.md"
  "docs/QUICKSTART.md"
  "docs/ARCHITECTURE.md"
  "docs/PRODUCTION_GUIDE.md"
  "docs/GPU_QUOTA_GUIDE.md"
  "runbooks/troubleshooting.md"
  "docs/runs/2026-09-27-run-1-fixed.md"
)

for doc in "${REQUIRED_DOCS[@]}"; do
  if [ -f "$doc" ]; then
    lines=$(wc -l < "$doc" | tr -d ' ')
    echo "  ✅ $doc ($lines lines)"
  else
    echo "  ❌ $doc MISSING"
    EXIT_CODE=1
  fi
done
echo ""

# --- Configuration Files ---
echo "⚙️  Configuration"
echo "────────────────────────────────────────────────────────────"

if [ -f "charts/values-production.yaml" ]; then
  echo "  ✅ charts/values-production.yaml"
else
  echo "  ❌ charts/values-production.yaml MISSING"
  EXIT_CODE=1
fi

if [ -f "charts/nim-llm-${NIM_CHART_VERSION}.tgz" ]; then
  echo "  ✅ charts/nim-llm-${NIM_CHART_VERSION}.tgz"
else
  echo "  ⚠️  charts/nim-llm-${NIM_CHART_VERSION}.tgz MISSING (will download on deploy)"
fi

if [ -f ".gitignore" ]; then
  echo "  ✅ .gitignore"
else
  echo "  ❌ .gitignore MISSING"
  EXIT_CODE=1
fi
echo ""

# --- Tools ---
echo "🛠️  Tools"
echo "────────────────────────────────────────────────────────────"

if command -v gcloud &> /dev/null; then
  version=$(gcloud version --format="value(core)" 2>/dev/null || echo "unknown")
  echo "  ✅ gcloud ($version)"
else
  echo "  ❌ gcloud NOT INSTALLED"
  EXIT_CODE=1
fi

if command -v kubectl &> /dev/null; then
  version=$(kubectl version --client --short 2>/dev/null | head -1 || echo "unknown")
  echo "  ✅ kubectl ($version)"
else
  echo "  ❌ kubectl NOT INSTALLED"
  EXIT_CODE=1
fi

if command -v helm &> /dev/null; then
  version=$(helm version --short 2>/dev/null || echo "unknown")
  echo "  ✅ helm ($version)"
else
  echo "  ❌ helm NOT INSTALLED"
  EXIT_CODE=1
fi
echo ""

# --- Environment Variables ---
echo "🔑 Environment Variables"
echo "────────────────────────────────────────────────────────────"

if [ -n "${NGC_API_KEY}" ]; then
  key_len=${#NGC_API_KEY}
  echo "  ✅ NGC_API_KEY set ($key_len chars)"
else
  echo "  ⚠️  NGC_API_KEY not set"
  echo "     Run: source ./set_ngc_key.sh"
fi

if [ -n "${PROJECT_ID}" ]; then
  echo "  ✅ PROJECT_ID: $PROJECT_ID"
else
  echo "  ⚠️  PROJECT_ID not set"
fi
echo ""

# --- GCP Resources (if authenticated) ---
echo "☁️  GCP Resources"
echo "────────────────────────────────────────────────────────────"

if gcloud auth list --filter=status:ACTIVE --format="value(account)" &> /dev/null; then
  account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
  echo "  ✅ Authenticated: $account"

  if [ -n "${PROJECT_ID}" ]; then
    if gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" &> /dev/null; then
      echo "  🟢 Cluster '${CLUSTER_NAME}' exists (RUNNING)"

      if kubectl get pod "${NIM_RELEASE_NAME}-nim-llm-0" -n "${NIM_NAMESPACE}" &> /dev/null; then
        status=$(kubectl get pod "${NIM_RELEASE_NAME}-nim-llm-0" -n "${NIM_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        ready=$(kubectl get pod "${NIM_RELEASE_NAME}-nim-llm-0" -n "${NIM_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "unknown")
        echo "  🟢 NIM pod exists (Status: $status, Ready: $ready)"
      else
        echo "  ⚠️  NIM pod not found"
      fi
    else
      echo "  ⚪ Cluster '${CLUSTER_NAME}' not found (fresh start)"
    fi
  else
    echo "  ⚠️  PROJECT_ID not set; skipping cluster check"
  fi
else
  echo "  ⚠️  Not authenticated"
  echo "     Run: gcloud auth login"
fi
echo ""

# --- Summary ---
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $EXIT_CODE -eq 0 ]; then
  echo "✅ Setup verification PASSED"
  echo ""
  echo "Ready to:"
  echo "  - Deploy: ./scripts/deploy_nim_gke.sh"
  echo "  - Test: ./scripts/test_nim.sh"
  echo "  - Cleanup: ./scripts/cleanup.sh"
else
  echo "❌ Setup verification FAILED"
  echo ""
  echo "Fix issues above before deploying."
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $EXIT_CODE
