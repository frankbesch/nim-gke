#!/bin/bash

# ============================================
# 🗑️  Cleanup NVIDIA NIM GKE Deployment
# ============================================

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/config.env"

SKIP_PROMPT=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y)
      SKIP_PROMPT=true
      ;;
    -h|--help)
      echo "Usage: $0 [--yes|-y] [-h|--help]"
      echo "  --yes, -y   Skip the confirmation prompt (for scripted runs)"
      echo "  -h, --help  Show this help and exit"
      exit 0
      ;;
    *)
      echo "Usage: $0 [--yes|-y] [-h|--help]" >&2
      exit 2
      ;;
  esac
done

require_project_id

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🗑️  NVIDIA NIM GKE Cleanup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "⚠️  WARNING: This will delete:"
echo "   - GKE Cluster: ${CLUSTER_NAME}"
echo "   - GPU node pool: gpupool"
echo "   - All associated resources"
echo ""
echo "💰 This will STOP all charges for:"
echo "   - Compute instances (about \$0.98/hour, measured, docs/runs/2026-09-27-run-1-fixed.md)"
echo "   - Load balancers"
echo "   - Persistent storage"
echo ""

if [[ "${SKIP_PROMPT}" == "true" ]]; then
  echo "🤔 --yes passed; skipping confirmation prompt."
else
  if [[ ! -t 0 ]]; then
    echo "refusing to delete without confirmation: no terminal; pass --yes" >&2
    exit 1
  fi
  read -p "🤔 Are you sure you want to delete the cluster? (yes/no): " CONFIRM

  if [[ "${CONFIRM}" != "yes" ]]; then
    echo "❌ Cleanup cancelled"
    exit 0
  fi
fi

echo ""
echo "🔍 Checking project ${PROJECT_ID}..."
if ! gcloud projects describe "${PROJECT_ID}" > /dev/null 2>&1; then
  echo "❌ Project ${PROJECT_ID} is not accessible; nothing deleted." >&2
  exit 1
fi

echo "🔍 Checking if cluster exists..."

describe_err="$(mktemp)"
if ! gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" > /dev/null 2> "${describe_err}"; then
  if grep -qi "not found\|NOT_FOUND" "${describe_err}"; then
    echo "⚠️  Cluster ${CLUSTER_NAME} not found in ${PROJECT_ID}/${ZONE}; nothing deleted."
    others="$(gcloud container clusters list --project="${PROJECT_ID}" --filter="name=${CLUSTER_NAME}" --format="value(name,location)" 2> /dev/null || true)"
    if [[ -n "${others}" ]]; then
      echo "❗ A cluster named ${CLUSTER_NAME} exists in another location and is still billing:" >&2
      echo "${others}" >&2
      echo "   Re-run with ZONE set to that location." >&2
      rm -f "${describe_err}"
      exit 1
    fi
    rm -f "${describe_err}"
    exit 0
  else
    echo "❌ Failed to check cluster status:"
    cat "${describe_err}" >&2
    rm -f "${describe_err}"
    exit 1
  fi
fi
rm -f "${describe_err}"

echo "✅ Cluster found"
echo ""

# --- Get credentials so kubectl/helm target this cluster ---
echo "🔑 Getting cluster credentials..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}"

# --- Confirm current context is this cluster before dumping resources ---
current_context="$(kubectl config current-context 2>/dev/null || true)"
if [[ "${current_context}" == *"${CLUSTER_NAME}"* ]]; then
  echo "💾 Saving cluster information..."
  kubectl get all -n "${NIM_NAMESPACE}" > nim_resources_backup.yaml 2>/dev/null || true
  kubectl get configmaps -n "${NIM_NAMESPACE}" -o yaml > nim_configmaps_backup.yaml 2>/dev/null || true
else
  echo "⚠️  kubectl context (${current_context}) does not match cluster ${CLUSTER_NAME}; skipping resource dump"
fi

# --- Uninstall the release and delete PVCs before tearing down the cluster ---
echo ""
echo "🧹 Uninstalling helm release (if present)..."
helm uninstall "${NIM_RELEASE_NAME}" -n "${NIM_NAMESPACE}" || echo "  (no release to uninstall)"

# The model-store disk can only be deleted after the pod releases it. Deleting
# the cluster before the CSI driver removes the PV orphans a billing disk
# (seen in the 2026-09-27 run 2: a 50 GiB pd-balanced disk survived a 10 s wait).
pvs_in_namespace() {  # PV names whose claim is in namespace $1, from `kubectl get pv -o json` on stdin
  python3 -c 'import json, sys
for pv in json.load(sys.stdin).get("items", []):
    if (pv.get("spec", {}).get("claimRef") or {}).get("namespace") == sys.argv[1]:
        print(pv["metadata"]["name"])' "$1"
}
echo "⏳ Waiting for NIM pods to terminate..."
kubectl wait --for=delete pod --all -n "${NIM_NAMESPACE}" --timeout=300s || echo "  (pods still terminating; continuing)"

echo "🧹 Deleting PVCs (if present)..."
kubectl delete pvc --all -n "${NIM_NAMESPACE}" || echo "  (no PVCs to delete)"

# Re-list PVs whose claimRef is in this namespace after the delete (rather
# than trusting a pre-delete snapshot, which races the CSI driver: a PV
# created or still finalizing between the snapshot and the delete would be
# missed) and poll in a bounded loop until none remain.
echo "⏳ Waiting for persistent volumes (and their disks) to be deleted..."
pv_wait_start=${SECONDS}
remaining_pvs=""
while (( SECONDS - pv_wait_start < 300 )); do
  remaining_pvs="$(kubectl get pv -o json 2>/dev/null | pvs_in_namespace "${NIM_NAMESPACE}" || true)"
  [[ -z "${remaining_pvs}" ]] && break
  sleep 5
done
remaining_pvs="$(kubectl get pv -o json 2>/dev/null | pvs_in_namespace "${NIM_NAMESPACE}" || true)"
if [[ -n "${remaining_pvs}" ]]; then
  echo "  ⚠️  PV(s) not deleted in 5 min; the disk check below will catch it:"
  echo "${remaining_pvs}"
fi

echo ""
echo "🗑️  Deleting GKE cluster: ${CLUSTER_NAME}"
echo "   This may take 5-10 minutes..."
echo ""

gcloud container clusters delete "${CLUSTER_NAME}" \
  --zone="${ZONE}" \
  --project="${PROJECT_ID}" \
  --quiet

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Cluster delete request complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# --- Check for leftover disks; do not auto-delete ---
echo "🔍 Checking for leftover persistent disks in ${PROJECT_ID}/${ZONE}..."
if ! leftover_disks="$(gcloud compute disks list --project="${PROJECT_ID}" --filter="zone~${ZONE}\$" --format="value(name,zone)")"; then
  echo "❗ Could not list disks; check the console for leftover disks (they bill)." >&2
  exit 1
fi
if [[ -n "${leftover_disks}" ]]; then
  suspect_disks="$(echo "${leftover_disks}" | grep -i -- "${CLUSTER_NAME}\|pvc-" || true)"
  if [[ -n "${suspect_disks}" ]]; then
    echo "⚠️  WARNING: possible leftover disks related to this cluster (not deleted automatically):"
    echo "${suspect_disks}"
    echo ""
    echo "  Review each disk above, then delete manually if unneeded:"
    while IFS=$'\t' read -r d_name d_zone; do
      [[ -z "${d_name}" ]] && continue
      echo "    gcloud compute disks delete ${d_name} --zone ${d_zone} --project ${PROJECT_ID}"
    done <<< "${suspect_disks}"
  else
    echo "✅ No disks matching cluster name or 'pvc-' found in ${ZONE}"
  fi
else
  echo "✅ No disks found in ${PROJECT_ID}/${ZONE}"
fi

echo ""
echo "💾 Backup files created (if resources existed):"
echo "   - nim_resources_backup.yaml"
echo "   - nim_configmaps_backup.yaml"
echo ""
echo "🔄 To redeploy, run: ./deploy_nim_gke.sh"
echo ""

echo ""
if [[ -n "${leftover_disks}" && -n "${suspect_disks:-}" ]]; then
  echo "⚠️  Cluster deleted, but leftover disks were found above. Review and delete manually if unneeded."
else
  echo "✅ Cluster deleted. No suspect leftover disks found."
fi
