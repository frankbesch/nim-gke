#!/bin/bash

# ============================================
# Verify NIM-GKE Setup
# Quick environment and repository validation
# ============================================

set -e

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
    echo "  ⚠️  $script (not executable)"
    chmod +x "$script"
    echo "     Fixed: made executable"
  else
    echo "  ❌ $script MISSING"
    EXIT_CODE=1
  fi
done
echo ""

# --- Documentation ---
echo "📚 Documentation"
echo "────────────────────────────────────────────────────────────"

REQUIRED_DOCS=(
  "README.md"
  "docs/ARCHITECTURE.md"
  "docs/INTERVIEW_BRIEF.md"
  "runbooks/troubleshooting.md"
  "scripts/README.md"
  "SESSION_STATE.md"
  "QUICK_REFERENCE.md"
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

if [ -f "charts/nim-llm-1.3.0.tgz" ]; then
  echo "  ✅ charts/nim-llm-1.3.0.tgz"
else
  echo "  ⚠️  charts/nim-llm-1.3.0.tgz MISSING (will download on deploy)"
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

if [ -n "${NGC_CLI_API_KEY}" ]; then
  key_len=${#NGC_CLI_API_KEY}
  echo "  ✅ NGC_CLI_API_KEY set ($key_len chars)"
else
  echo "  ⚠️  NGC_CLI_API_KEY not set"
  echo "     Run: source ./set_ngc_key.sh"
fi

if [ -n "${PROJECT_ID}" ]; then
  echo "  ✅ PROJECT_ID: $PROJECT_ID"
else
  echo "  ⚠️  PROJECT_ID not set (will use default: your-gcp-project)"
fi
echo ""

# --- GCP Resources (if authenticated) ---
echo "☁️  GCP Resources"
echo "────────────────────────────────────────────────────────────"

if gcloud auth list --filter=status:ACTIVE --format="value(account)" &> /dev/null; then
  account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
  echo "  ✅ Authenticated: $account"
  
  project=$(gcloud config get-value project 2>/dev/null)
  echo "  ✅ Project: $project"
  
  # Check for cluster
  if gcloud container clusters describe nim-demo --zone=us-central1-a &> /dev/null 2>&1; then
    echo "  🟢 Cluster 'nim-demo' exists (RUNNING)"
    
    # Check for NIM pod
    if kubectl get pod my-nim-nim-llm-0 -n nim &> /dev/null 2>&1; then
      status=$(kubectl get pod my-nim-nim-llm-0 -n nim -o jsonpath='{.status.phase}')
      ready=$(kubectl get pod my-nim-nim-llm-0 -n nim -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
      echo "  🟢 NIM pod exists (Status: $status, Ready: $ready)"
    else
      echo "  ⚠️  NIM pod not found"
    fi
  else
    echo "  ⚪ Cluster 'nim-demo' not found (fresh start)"
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

