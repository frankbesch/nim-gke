#!/bin/bash

# ============================================
# 🔍 NVIDIA NIM Deployment Monitor
# Monitors GPU node provisioning and deployment status
# ============================================

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/config.env"
require_project_id

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

MAX_ITERATIONS=60
SLEEP_SECONDS=60

echo "═══════════════════════════════════════════════════════════════"
echo "🔍 NVIDIA NIM Deployment Monitor"
echo "═══════════════════════════════════════════════════════════════"
echo "Duration: ${MAX_ITERATIONS} minutes (checking every ${SLEEP_SECONDS}s)"
echo "Start Time: $(date)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

for i in $(seq 1 $MAX_ITERATIONS); do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 CHECK #${i}/${MAX_ITERATIONS} - ${TIMESTAMP}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # ==================== IaaS COMPONENTS ====================
    echo -e "${BLUE}🏗️  IaaS COMPONENTS${NC}"
    echo "────────────────────────────────────────────────────────────"

    # 1. Cluster Status
    echo -e "${YELLOW}1. GKE Cluster Status:${NC}"
    gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" 2>/dev/null | grep -E "^status:" | head -1 || echo "  Status: UNKNOWN"

    # 2. Node Pool Status
    echo ""
    echo -e "${YELLOW}2. Node Pools:${NC}"
    gcloud container node-pools list --cluster="${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" 2>/dev/null || echo "  Error fetching node pools"

    # 3. GPU Node Pool Detail
    echo ""
    echo -e "${YELLOW}3. GPU Node Pool (gpupool) Status:${NC}"
    GPU_POOL_STATUS=$(gcloud container node-pools describe gpupool --cluster="${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" 2>/dev/null | grep -E "^status:" | head -1 || echo "status: NOT_FOUND")
    echo "  ${GPU_POOL_STATUS}"

    GPU_NODE_COUNT=$(gcloud container node-pools describe gpupool --cluster="${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" 2>/dev/null | grep -E "currentNodeCount:" | head -1 || echo "currentNodeCount: 0")
    echo "  ${GPU_NODE_COUNT}"

    # 4. Compute Nodes
    echo ""
    echo -e "${YELLOW}4. Kubernetes Nodes:${NC}"
    kubectl get nodes -o wide 2>/dev/null || echo "  Error fetching nodes"

    # 5. GPU Nodes Specific
    echo ""
    echo -e "${YELLOW}5. GPU Nodes (with ${GPU_TYPE} label):${NC}"
    GPU_NODE_COUNT=$(kubectl get nodes -l cloud.google.com/gke-accelerator="${GPU_TYPE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$GPU_NODE_COUNT" -gt 0 ]; then
        echo -e "  ${GREEN}✅ GPU Nodes Found: ${GPU_NODE_COUNT}${NC}"
        kubectl get nodes -l cloud.google.com/gke-accelerator="${GPU_TYPE}" -o wide 2>/dev/null
    else
        echo -e "  ${YELLOW}⏳ No GPU nodes yet (expected during provisioning)${NC}"
    fi

    echo ""
    echo -e "${BLUE}☁️  PaaS COMPONENTS${NC}"
    echo "────────────────────────────────────────────────────────────"

    # 6. Namespaces
    echo -e "${YELLOW}6. Namespace Status:${NC}"
    kubectl get namespace "${NIM_NAMESPACE}" 2>/dev/null || echo "  Namespace '${NIM_NAMESPACE}' not found"

    # 7. Pods
    echo ""
    echo -e "${YELLOW}7. NIM Pods:${NC}"
    kubectl get pods -n "${NIM_NAMESPACE}" -o wide 2>/dev/null || echo "  No pods found in ${NIM_NAMESPACE} namespace"

    # 8. Pod Details
    echo ""
    echo -e "${YELLOW}8. Pod Status Details:${NC}"
    POD_NAME=$(kubectl get pods -n "${NIM_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$POD_NAME" ]; then
        POD_STATUS=$(kubectl get pod "${POD_NAME}" -n "${NIM_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null)
        POD_READY=$(kubectl get pod "${POD_NAME}" -n "${NIM_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

        echo "  Pod Name: ${POD_NAME}"
        echo "  Phase: ${POD_STATUS}"
        echo "  Ready: ${POD_READY}"

        if [ "$POD_STATUS" == "Running" ] && [ "$POD_READY" == "True" ]; then
            echo -e "  ${GREEN}✅ POD IS READY!${NC}"
        elif [ "$POD_STATUS" == "Running" ]; then
            echo -e "  ${YELLOW}⏳ Pod running but not ready (model loading)${NC}"
        else
            echo -e "  ${YELLOW}⏳ Pod status: ${POD_STATUS}${NC}"
        fi
    else
        echo "  No pods found"
    fi

    # 9. Helm Releases (StatefulSet workload "${NIM_RELEASE_NAME}-nim-llm")
    echo ""
    echo -e "${YELLOW}9. Helm Releases:${NC}"
    helm list -n "${NIM_NAMESPACE}" 2>/dev/null || echo "  No helm releases found"

    # 10. Services
    echo ""
    echo -e "${YELLOW}10. Services:${NC}"
    kubectl get services -n "${NIM_NAMESPACE}" 2>/dev/null || echo "  No services found"

    # 11. Secrets
    echo ""
    echo -e "${YELLOW}11. Secrets (NGC API):${NC}"
    kubectl get secrets -n "${NIM_NAMESPACE}" 2>/dev/null | grep -E "NAME|ngc-api|registry-secret" || echo "  No secrets found"

    # 12. Recent Pod Events
    echo ""
    echo -e "${YELLOW}12. Recent Pod Events (last 5):${NC}"
    if [ -n "$POD_NAME" ]; then
        kubectl get events -n "${NIM_NAMESPACE}" --field-selector involvedObject.name="${POD_NAME}" --sort-by='.lastTimestamp' 2>/dev/null | tail -6 || echo "  No events found"
    else
        kubectl get events -n "${NIM_NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | tail -6 || echo "  No events found"
    fi

    # ==================== SUMMARY ====================
    echo ""
    echo -e "${BLUE}📈 DEPLOYMENT SUMMARY${NC}"
    echo "────────────────────────────────────────────────────────────"

    # Check completion status
    if [ "$GPU_NODE_COUNT" -gt 0 ] && [ "$POD_STATUS" == "Running" ] && [ "$POD_READY" == "True" ]; then
        echo -e "${GREEN}✅ DEPLOYMENT COMPLETE!${NC}"
        echo ""
        echo "🎉 Your NVIDIA NIM is ready!"
        echo ""
        echo "Next steps:"
        echo "  1. Open a new terminal and run:"
        echo "     kubectl port-forward service/${NIM_RELEASE_NAME}-nim-llm 8000:8000 -n ${NIM_NAMESPACE}"
        echo ""
        echo "  2. Test the deployment:"
        echo "     ./test_nim.sh"
        echo ""
        exit 0
    elif [ "$GPU_NODE_COUNT" -gt 0 ] && [ "$POD_STATUS" == "Running" ]; then
        echo -e "${YELLOW}⏳ GPU node ready, model loading...${NC}"
        echo "   Status: Pod running but not ready yet"
        echo "   This is normal - model download takes 10-15 minutes"
    elif [ "$GPU_NODE_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}⏳ GPU node ready, waiting for pod to start...${NC}"
    else
        echo -e "${YELLOW}⏳ Waiting for GPU node to provision...${NC}"
        echo "   Current node pool status: ${GPU_POOL_STATUS}"
    fi

    # Cost estimate
    ELAPSED_MINUTES=$i
    if [ "$GPU_NODE_COUNT" -gt 0 ]; then
        COST_PER_HOUR="${COST_PER_HOUR_GPU}"
        CURRENT_COST=$(echo "scale=2; ${COST_PER_HOUR} * ${ELAPSED_MINUTES} / 60" | bc)
        echo ""
        echo "💰 Estimated cost so far: \$${CURRENT_COST} (with GPU node)"
    else
        COST_PER_HOUR="${COST_PER_HOUR_BASE}"
        CURRENT_COST=$(echo "scale=2; ${COST_PER_HOUR} * ${ELAPSED_MINUTES} / 60" | bc)
        echo ""
        echo "💰 Estimated cost so far: \$${CURRENT_COST} (control plane only)"
    fi

    echo ""
    echo "⏰ Next check in ${SLEEP_SECONDS} seconds..."
    echo ""

    # Don't sleep on the last iteration
    if [ $i -lt $MAX_ITERATIONS ]; then
        sleep $SLEEP_SECONDS
    fi
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⏱️  Monitoring period complete (${MAX_ITERATIONS} minutes)"
echo "End Time: $(date)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Current Status:"
kubectl get pods -n "${NIM_NAMESPACE}"
echo ""
echo "To continue monitoring manually, run:"
echo "  kubectl get pods -n ${NIM_NAMESPACE} -w"
