#!/usr/bin/env bash
# Measured-run runner: preflight -> deploy -> wait Ready -> bench -> cleanup.
# Rebuilt from an earlier ad hoc run script to fix three defects: (a) a
# failed deploy under `set -euo pipefail` used to exit before cleanup ran,
# relying on a 60-min watchdog that only deleted the cluster, not disks;
# (b) the Ready-wait loop had no timeout and spun forever once the cluster
# was gone; (c) PROJECT_ID and the NGC key must never be hardcoded here
# (this repo is public) -- both come from the environment.
#
# --autoscale adds an unmeasured 0->1(->2)->0 GPU-node autoscale test path
# on top of the same runner: deploy with AUTOSCALE=1 (gpupool starts at 0
# nodes), wait for the cluster autoscaler to add a GPU node, run the normal
# Ready-wait/bench, then (with --two-nodes) scale the StatefulSet to 2 and
# wait for a second GPU node, then scale back to 0 and wait for the
# autoscaler to remove the node(s) before cleanup. Without --autoscale, the
# run behaves exactly as before.
#
# Usage: PROJECT_ID=... NGC_API_KEY=... scripts/run_measured.sh [--autoscale [--two-nodes]] OUT_DIR
#
# Spends real money: creates a GKE cluster with a GPU node pool. Always
# tears down via an EXIT/INT/TERM trap, backstopped by a watchdog that
# cleans up if the run gets killed outright.
#
# Test-only hooks (not for normal use): RUNNER_PREFLIGHT, RUNNER_DEPLOY,
# RUNNER_BENCH, RUNNER_CLEANUP override the command run for each step, so
# tests/run_measured_test.sh and tests/run_measured_autoscale_test.sh can
# fake them. Defaults are the real scripts. POLL_SEC / READY_TIMEOUT_SEC /
# WATCHDOG_SEC / SCALE_UP_TIMEOUT_SEC / SCALE_DOWN_TIMEOUT_SEC are also
# overridable, for both tests and tuning.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

usage() {
  cat <<'EOF'
Usage: PROJECT_ID=... NGC_API_KEY=... scripts/run_measured.sh [--autoscale [--two-nodes]] OUT_DIR
  OUT_DIR       directory for logs and artifacts (created if missing)
  --autoscale   test the 0->1->0 GPU-node autoscale path (AUTOSCALE=1 on
                deploy_nim_gke.sh); default WATCHDOG_SEC becomes 7200
  --two-nodes   also scale the StatefulSet to 2 replicas and wait for a
                second GPU node before scaling back to 0; requires
                --autoscale and MAX_GPU_NODES>=2
  -h, --help    show this help and exit

Env (required): PROJECT_ID, NGC_API_KEY (NGC_CLI_API_KEY accepted as a fallback)
Env (optional, tuning/tests): POLL_SEC, READY_TIMEOUT_SEC, WATCHDOG_SEC,
  SCALE_UP_TIMEOUT_SEC, SCALE_DOWN_TIMEOUT_SEC, MAX_GPU_NODES
EOF
}

OUT_DIR=""
AUTOSCALE_FLAG=0
TWO_NODES_FLAG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --autoscale)
      AUTOSCALE_FLAG=1
      ;;
    --two-nodes)
      TWO_NODES_FLAG=1
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "${OUT_DIR}" ]]; then
        usage >&2
        exit 2
      fi
      OUT_DIR="$1"
      ;;
  esac
  shift
done

if [[ -z "${OUT_DIR}" ]]; then
  usage >&2
  exit 2
fi

if [[ "${TWO_NODES_FLAG}" == "1" && "${AUTOSCALE_FLAG}" != "1" ]]; then
  echo "ERROR: --two-nodes requires --autoscale" >&2
  usage >&2
  exit 2
fi

if [[ "${AUTOSCALE_FLAG}" == "1" ]]; then
  export AUTOSCALE=1
fi

# shellcheck source=./config.env
source "${SCRIPT_DIR}/config.env"
require_project_id

if [[ "${TWO_NODES_FLAG}" == "1" && "${MAX_GPU_NODES}" -lt 2 ]]; then
  echo "ERROR: --two-nodes requires MAX_GPU_NODES>=2 (currently ${MAX_GPU_NODES})" >&2
  exit 2
fi

if [[ -z "${NGC_API_KEY}" ]]; then
  echo "ERROR: NGC_API_KEY (or NGC_CLI_API_KEY) must be set" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

POLL_SEC="${POLL_SEC:-15}"
READY_TIMEOUT_SEC="${READY_TIMEOUT_SEC:-1800}"
if [[ "${AUTOSCALE:-0}" == "1" ]]; then
  WATCHDOG_SEC="${WATCHDOG_SEC:-7200}"
else
  WATCHDOG_SEC="${WATCHDOG_SEC:-3600}"
fi
SCALE_UP_TIMEOUT_SEC="${SCALE_UP_TIMEOUT_SEC:-1200}"
SCALE_DOWN_TIMEOUT_SEC="${SCALE_DOWN_TIMEOUT_SEC:-3600}"

ts() { date -u +%FT%TZ; }
mark() { echo "$(ts) $1" | tee -a "${OUT_DIR}/phases.log"; }
RUN_START_TS="$(ts)"

# Count Ready nodes carrying the GKE accelerator label (i.e. GPU nodes).
gpu_node_count() {
  kubectl get nodes -l cloud.google.com/gke-accelerator --no-headers 2>/dev/null \
    | awk '{print $2}' | grep -c '^Ready$' || true
}

wait_for_gpu_nodes() {  # $1 = target count, $2 = timeout seconds
  local target="$1" timeout="$2" elapsed=0 count
  while (( elapsed < timeout )); do
    count="$(gpu_node_count)"
    [[ "${count}" == "${target}" ]] && return 0
    sleep "${POLL_SEC}"
    elapsed=$((elapsed + POLL_SEC))
  done
  return 1
}

wait_for_pod_ready() {  # $1 = pod name, $2 = timeout seconds
  local pod="$1" timeout="$2" elapsed=0 ready="false"
  while (( elapsed < timeout )); do
    ready="$(kubectl get pod "${pod}" -n "${NIM_NAMESPACE}" \
      -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
    [[ "${ready}" == "true" ]] && return 0
    sleep "${POLL_SEC}"
    elapsed=$((elapsed + POLL_SEC))
  done
  return 1
}

save_phase_evidence() {  # $1 = phase label, for the nodes-<phase>.txt filename
  kubectl get events -A --sort-by=.lastTimestamp >> "${OUT_DIR}/events.txt" 2>&1 || true
  kubectl get nodes -o wide > "${OUT_DIR}/nodes-$1.txt" 2>&1 || true
}

PF_PID=""
WATCHDOG_PID=""
WATCHDOG_STOP="${OUT_DIR}/.watchdog_stop"
CLEANUP_RAN=0

run_cleanup_once() {
  # Runs scripts/cleanup.sh --yes (or RUNNER_CLEANUP) and tees to
  # OUT_DIR/cleanup.log. Callers decide whether to call this at all.
  local cmd="${RUNNER_CLEANUP:-${SCRIPT_DIR}/cleanup.sh}"
  "${cmd}" --yes 2>&1 | tee "${OUT_DIR}/cleanup.log"
}

on_exit() {
  local exit_status=$?
  trap - EXIT INT TERM

  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi

  if [[ "${CLEANUP_RAN}" != "1" ]]; then
    mark "cleanup start (trap)"
    run_cleanup_once || true
    mark "cleanup end (trap)"
  fi

  gcloud container operations list --project="${PROJECT_ID}" --zone="${ZONE}" \
    --format="table(operationType,targetLink.basename(),startTime,endTime,status)" \
    > "${OUT_DIR}/operations.txt" 2>&1 || true
  gcloud container clusters list --project="${PROJECT_ID}" \
    > "${OUT_DIR}/final-clusters.txt" 2>&1 || true
  gcloud compute disks list --project="${PROJECT_ID}" \
    > "${OUT_DIR}/final-disks.txt" 2>&1 || true

  if [[ -n "${WATCHDOG_PID}" ]]; then
    touch "${WATCHDOG_STOP}" 2>/dev/null || true
    for _ in 1 2 3; do
      kill -0 "${WATCHDOG_PID}" 2>/dev/null || break
      sleep 1
    done
    kill "${WATCHDOG_PID}" 2>/dev/null || true
    wait "${WATCHDOG_PID}" 2>/dev/null || true
  fi

  local final_status="${exit_status}"

  if grep -qw "${CLUSTER_NAME}" "${OUT_DIR}/final-clusters.txt" 2>/dev/null; then
    echo "ERROR: cluster ${CLUSTER_NAME} still present after cleanup" >&2
    final_status=1
  fi

  local leftover
  leftover="$(grep -E "pvc-|${CLUSTER_NAME}" "${OUT_DIR}/final-disks.txt" 2>/dev/null || true)"
  if [[ -n "${leftover}" ]]; then
    echo "ERROR: leftover disk(s) after cleanup:" >&2
    echo "${leftover}" >&2
    final_status=1
  fi

  exit "${final_status}"
}

mark "preflight start"
PREFLIGHT_CMD="${RUNNER_PREFLIGHT:-${SCRIPT_DIR}/preflight.sh}"
"${PREFLIGHT_CMD}" 2>&1 | tee "${OUT_DIR}/preflight.log"
mark "preflight end"

# Trap armed right here: a preflight failure above exits before this point
# and creates nothing to clean up. Everything from here on can create
# billable resources.
# Signals exit with 128+N; `exit` inside a signal trap runs the EXIT trap,
# so Ctrl-C, kill, and a closed terminal (HUP) all clean up and exit non-zero.
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Watchdog: backstop if this run is killed outright. Polls a stop flag in
# short ticks instead of one long `sleep WATCHDOG_SEC`, so the trap can end
# it immediately (no orphaned sleep process left behind) instead of having
# to kill a process group.
rm -f "${WATCHDOG_STOP}"
(
  # Survive a closed terminal: the runner cleans up on HUP, but if it dies
  # without cleaning up, this is the backstop.
  trap '' HUP
  elapsed=0
  while (( elapsed < WATCHDOG_SEC )); do
    [[ -f "${WATCHDOG_STOP}" ]] && exit 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  [[ -f "${WATCHDOG_STOP}" ]] && exit 0
  if gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "$(ts) WATCHDOG FIRED: cluster ${CLUSTER_NAME} still exists" >> "${OUT_DIR}/phases.log"
    cmd="${RUNNER_CLEANUP:-${SCRIPT_DIR}/cleanup.sh}"
    "${cmd}" --yes >> "${OUT_DIR}/watchdog.log" 2>&1
  fi
) &
WATCHDOG_PID=$!
disown "${WATCHDOG_PID}" 2>/dev/null || true
echo "${WATCHDOG_PID}" > "${OUT_DIR}/watchdog.pid"

mark "deploy start"
DEPLOY_CMD="${RUNNER_DEPLOY:-${SCRIPT_DIR}/deploy_nim_gke.sh}"
"${DEPLOY_CMD}" 2>&1 | tee "${OUT_DIR}/deploy.log"
mark "deploy end"

if [[ "${AUTOSCALE:-0}" == "1" ]]; then
  mark "phase 0to1 start"
  init_gpu_nodes="$(gpu_node_count)"
  echo "$(ts) gpu node count at phase 0to1 start: ${init_gpu_nodes}" >> "${OUT_DIR}/phases.log"
  if [[ "${init_gpu_nodes}" != "0" ]]; then
    echo "$(ts) WARNING: expected 0 GPU nodes at phase 0to1 start, got ${init_gpu_nodes}" >> "${OUT_DIR}/phases.log"
  fi
  if ! wait_for_gpu_nodes 1 "${SCALE_UP_TIMEOUT_SEC}"; then
    mark "gpu node 1 Ready TIMEOUT"
    exit 1
  fi
  mark "gpu node 1 Ready"
fi

mark "wait Ready start"
elapsed=0
ready="false"
while (( elapsed < READY_TIMEOUT_SEC )); do
  ready="$(kubectl get pod "${NIM_RELEASE_NAME}-nim-llm-0" -n "${NIM_NAMESPACE}" \
    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
  if [[ "${ready}" == "true" ]]; then
    break
  fi
  sleep "${POLL_SEC}"
  elapsed=$((elapsed + POLL_SEC))
done
if [[ "${ready}" != "true" ]]; then
  mark "Ready TIMEOUT"
  exit 1
fi
mark "pod Ready"

kubectl get pod "${NIM_RELEASE_NAME}-nim-llm-0" -n "${NIM_NAMESPACE}" -o json \
  > "${OUT_DIR}/pod.json" 2>/dev/null || true
kubectl logs "${NIM_RELEASE_NAME}-nim-llm-0" -n "${NIM_NAMESPACE}" \
  > "${OUT_DIR}/pod.log" 2>&1 || true

if [[ "${AUTOSCALE:-0}" == "1" ]]; then
  save_phase_evidence "0to1"
fi

kubectl port-forward -n "${NIM_NAMESPACE}" "svc/${NIM_RELEASE_NAME}-nim-llm" 8000:8000 \
  > "${OUT_DIR}/port-forward.log" 2>&1 &
PF_PID=$!
sleep 5

mark "bench start"
if [[ -n "${RUNNER_BENCH:-}" ]]; then
  BENCH_CMD=("${RUNNER_BENCH}")
else
  BENCH_CMD=(python3 "${SCRIPT_DIR}/bench.py")
fi
"${BENCH_CMD[@]}" --out "${OUT_DIR}/bench.json" 2>&1 | tee "${OUT_DIR}/bench.log"
mark "bench end"

if [[ "${AUTOSCALE:-0}" == "1" ]]; then
  save_phase_evidence "bench"
fi

kill "${PF_PID}" 2>/dev/null || true
wait "${PF_PID}" 2>/dev/null || true
PF_PID=""

if [[ "${AUTOSCALE:-0}" == "1" ]]; then
  if [[ "${TWO_NODES_FLAG}" == "1" ]]; then
    mark "scale to 2 start"
    kubectl scale "statefulset/${NIM_RELEASE_NAME}-nim-llm" -n "${NIM_NAMESPACE}" --replicas=2
    if ! wait_for_gpu_nodes 2 "${SCALE_UP_TIMEOUT_SEC}"; then
      mark "gpu node 2 Ready TIMEOUT"
      exit 1
    fi
    mark "gpu node 2 Ready"
    if ! wait_for_pod_ready "${NIM_RELEASE_NAME}-nim-llm-1" "${READY_TIMEOUT_SEC}"; then
      mark "pod -1 Ready TIMEOUT"
      exit 1
    fi
    mark "pod -1 Ready"
    save_phase_evidence "scale-to-2"
  fi

  mark "phase scale-to-0 start"
  kubectl scale "statefulset/${NIM_RELEASE_NAME}-nim-llm" -n "${NIM_NAMESPACE}" --replicas=0
  if ! wait_for_gpu_nodes 0 "${SCALE_DOWN_TIMEOUT_SEC}"; then
    mark "gpu nodes 0 TIMEOUT"
    exit 1
  fi
  mark "gpu nodes 0"
  save_phase_evidence "scale-to-0"

  # Cluster-autoscaler-visibility log for this run; failure here must not
  # abort the run (evidence-gathering only).
  autoscaler_filter="resource.type=\"k8s_cluster\" AND resource.labels.cluster_name=\"${CLUSTER_NAME}\" AND resource.labels.location=\"${ZONE}\" AND logName=\"projects/${PROJECT_ID}/logs/container.googleapis.com%2Fcluster-autoscaler-visibility\" AND timestamp>=\"${RUN_START_TS}\""
  if ! gcloud logging read "${autoscaler_filter}" --project="${PROJECT_ID}" --format=json \
      > "${OUT_DIR}/autoscaler.json" 2>"${OUT_DIR}/autoscaler.err"; then
    echo "$(ts) gcloud logging read failed (non-fatal); see autoscaler.err" >> "${OUT_DIR}/phases.log"
  fi
fi

mark "cleanup start"
if run_cleanup_once; then
  CLEANUP_RAN=1
else
  mark "cleanup FAILED; retrying in trap"
  exit 1
fi
mark "cleanup end"

echo "Run complete. Logs in ${OUT_DIR}."
exit 0
