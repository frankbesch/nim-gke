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
# cleans up if the run gets killed outright. Cleanup runs with signals
# ignored (see on_exit) so a second Ctrl-C or a watchdog TERM cannot leave
# a half-torn-down cluster; a cleanup that cannot verify a clean teardown
# leaves the watchdog armed and prints the exact gcloud delete commands.
#
# Test-only hooks (not for normal use): RUNNER_PREFLIGHT, RUNNER_DEPLOY,
# RUNNER_BENCH, RUNNER_CLEANUP override the command run for each step, so
# tests/run_measured_test.sh and tests/run_measured_autoscale_test.sh can
# fake them. Defaults are the real scripts. POLL_SEC / READY_TIMEOUT_SEC /
# WATCHDOG_SEC / SCALE_UP_TIMEOUT_SEC / SCALE_DOWN_TIMEOUT_SEC /
# CLEANUP_RETRY_SEC / OPS_WAIT_SEC are also overridable, for both tests and
# tuning.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

usage() {
  cat <<'EOF'
Usage: PROJECT_ID=... NGC_API_KEY=... scripts/run_measured.sh [--autoscale [--two-nodes]] OUT_DIR
  OUT_DIR       directory for logs and artifacts (created if missing)
  --autoscale   test the 0->1->0 GPU-node autoscale path (AUTOSCALE=1 on
                deploy_nim_gke.sh)
  --two-nodes   also scale the StatefulSet to 2 replicas and wait for a
                second GPU node before scaling back to 0; requires
                --autoscale and MAX_GPU_NODES>=2
  -h, --help    show this help and exit

Env (required): PROJECT_ID, NGC_API_KEY (NGC_CLI_API_KEY accepted as a fallback)
Env (optional, tuning/tests): POLL_SEC, READY_TIMEOUT_SEC, WATCHDOG_SEC,
  SCALE_UP_TIMEOUT_SEC, SCALE_DOWN_TIMEOUT_SEC, CLEANUP_RETRY_SEC,
  OPS_WAIT_SEC, MAX_GPU_NODES
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
SCALE_UP_TIMEOUT_SEC="${SCALE_UP_TIMEOUT_SEC:-1200}"
SCALE_DOWN_TIMEOUT_SEC="${SCALE_DOWN_TIMEOUT_SEC:-1800}"

# RUN_BUDGET_SEC: sum of the phase timeouts actually exercised by this
# invocation. WATCHDOG_SEC defaults to that plus a 1800s margin, so the
# watchdog cannot fire before the run's own timeouts have had a chance to.
RUN_BUDGET_SEC=$(( READY_TIMEOUT_SEC ))
if [[ "${AUTOSCALE_FLAG}" == "1" ]]; then
  RUN_BUDGET_SEC=$(( RUN_BUDGET_SEC + SCALE_UP_TIMEOUT_SEC + SCALE_DOWN_TIMEOUT_SEC ))
  if [[ "${TWO_NODES_FLAG}" == "1" ]]; then
    RUN_BUDGET_SEC=$(( RUN_BUDGET_SEC + SCALE_UP_TIMEOUT_SEC + READY_TIMEOUT_SEC ))
  fi
fi
WATCHDOG_SEC="${WATCHDOG_SEC:-$((RUN_BUDGET_SEC + 1800))}"
CLEANUP_RETRY_SEC="${CLEANUP_RETRY_SEC:-1200}"
OPS_WAIT_SEC="${OPS_WAIT_SEC:-60}"

ts() { date -u +%FT%TZ; }
mark() { echo "$(ts) $1" | tee -a "${OUT_DIR}/phases.log"; }
RUN_START_TS="$(ts)"

# Count Ready nodes carrying the GKE accelerator label (i.e. GPU nodes).
# Returns "ERR" (never equal to any numeric target) if kubectl itself
# fails, e.g. a dead API server or a deleted cluster, so a wait loop never
# mistakes "can't tell" for "zero".
gpu_node_count() {
  local out
  if ! out="$(kubectl get nodes -l cloud.google.com/gke-accelerator --no-headers --request-timeout=30s 2>/dev/null)"; then
    echo "ERR"
    return 0
  fi
  echo "${out}" | awk '$2=="Ready"{c++} END{print c+0}'
}

# Same, but counts every node carrying the GPU label regardless of STATUS
# (NotReady/SchedulingDisabled still count as present). Used when the wait
# target is 0, so a draining node cannot be miscounted as "gone".
gpu_node_present_count() {
  local out
  if ! out="$(kubectl get nodes -l cloud.google.com/gke-accelerator --no-headers --request-timeout=30s 2>/dev/null)"; then
    echo "ERR"
    return 0
  fi
  echo "${out}" | awk 'NF{c++} END{print c+0}'
}

wait_for_gpu_nodes() {  # $1 = target count, $2 = timeout seconds
  local target="$1" timeout="$2" start=${SECONDS} count
  while (( SECONDS - start < timeout )); do
    if [[ "${target}" == "0" ]]; then
      count="$(gpu_node_present_count)"
    else
      count="$(gpu_node_count)"
    fi
    [[ "${count}" != "ERR" && "${count}" == "${target}" ]] && return 0
    sleep "${POLL_SEC}"
  done
  return 1
}

wait_for_pod_ready() {  # $1 = pod name, $2 = timeout seconds
  local pod="$1" timeout="$2" start=${SECONDS} ready="false"
  while (( SECONDS - start < timeout )); do
    ready="$(kubectl get pod "${pod}" -n "${NIM_NAMESPACE}" \
      -o jsonpath='{.status.containerStatuses[0].ready}' --request-timeout=30s 2>/dev/null || true)"
    [[ "${ready}" == "true" ]] && return 0
    sleep "${POLL_SEC}"
  done
  return 1
}

save_phase_evidence() {  # $1 = phase label, for the nodes-<phase>.txt filename
  kubectl get events -A --sort-by=.lastTimestamp >> "${OUT_DIR}/events.txt" 2>&1 || true
  kubectl get nodes -o wide > "${OUT_DIR}/nodes-$1.txt" 2>&1 || true
}

# True (0) if the cluster exists or its status could not be determined
# (i.e. any failure other than NOT_FOUND); false (1) only on a clean
# NOT_FOUND. Callers that must not skip cleanup on ambiguous failures rely
# on the "true when unsure" default.
cluster_exists() {
  local err
  err="$(mktemp)"
  if gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>"${err}"; then
    rm -f "${err}"
    return 0
  fi
  if grep -qi "not found\|NOT_FOUND" "${err}"; then
    rm -f "${err}"
    return 1
  fi
  rm -f "${err}"
  return 0
}

CLEANUP_LOCK_DIR="${OUT_DIR}/.cleanup_lock"

# Blocking mkdir-based lock so the trap cleanup and the watchdog cleanup
# never run at the same time.
acquire_cleanup_lock() {
  while ! mkdir "${CLEANUP_LOCK_DIR}" 2>/dev/null; do
    sleep 1
  done
}

release_cleanup_lock() {
  rmdir "${CLEANUP_LOCK_DIR}" 2>/dev/null || true
}

wait_for_no_running_ops() {  # $1 = timeout seconds; best-effort, never fails the caller
  local timeout="${1:-60}" start=${SECONDS} ops
  while (( SECONDS - start < timeout )); do
    ops="$(gcloud container operations list --project="${PROJECT_ID}" --zone="${ZONE}" \
      --filter="status=RUNNING AND targetLink~${CLUSTER_NAME}" --format="value(name)" 2>/dev/null || true)"
    [[ -z "${ops}" ]] && return 0
    sleep 5
  done
  return 1
}

PF_PID=""
WATCHDOG_PID=""
WATCHDOG_STOP="${OUT_DIR}/.watchdog_stop"
CLEANUP_RAN=0
MAIN_PID=$$

run_cleanup_once() {
  # Runs scripts/cleanup.sh --yes (or RUNNER_CLEANUP) and tees to
  # OUT_DIR/cleanup.log. Callers decide whether to call this at all.
  local cmd="${RUNNER_CLEANUP:-${SCRIPT_DIR}/cleanup.sh}"
  "${cmd}" --yes 2>&1 | tee "${OUT_DIR}/cleanup.log"
}

# Runs cleanup, retrying (bounded by CLEANUP_RETRY_SEC) as long as the
# cluster still exists, waiting out any RUNNING operation before each
# retry. Returns 0 once cluster_exists says NOT_FOUND, 1 if the budget
# runs out first.
cleanup_with_retry() {
  local start=${SECONDS} attempt=0
  while true; do
    attempt=$((attempt + 1))
    mark "cleanup attempt ${attempt} start"
    if run_cleanup_once; then
      mark "cleanup attempt ${attempt} end (ok)"
    else
      mark "cleanup attempt ${attempt} end (failed)"
    fi
    if ! cluster_exists; then
      return 0
    fi
    if (( SECONDS - start >= CLEANUP_RETRY_SEC )); then
      return 1
    fi
    wait_for_no_running_ops "${OPS_WAIT_SEC}" || true
    sleep 1
  done
}

on_exit() {
  local exit_status=$?
  # Ignore further interrupts once cleanup is underway: a second Ctrl-C or
  # a watchdog TERM must not kill this trap mid-teardown and leave the
  # cluster half-deleted.
  trap '' INT TERM HUP
  mark "cleanup running -- do not interrupt"

  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi

  acquire_cleanup_lock
  local final_status="${exit_status}"
  if [[ "${CLEANUP_RAN}" != "1" ]]; then
    mark "cleanup start (trap)"
    if cleanup_with_retry; then
      CLEANUP_RAN=1
      mark "cleanup end (trap)"
    else
      mark "cleanup FAILED after retries (trap)"
      final_status=1
    fi
  fi
  release_cleanup_lock

  gcloud container operations list --project="${PROJECT_ID}" --zone="${ZONE}" \
    --format="table(operationType,targetLink.basename(),startTime,endTime,status)" \
    > "${OUT_DIR}/operations.txt" 2>&1 || true

  local clusters_list_status=0 disks_list_status=0
  gcloud container clusters list --project="${PROJECT_ID}" \
    > "${OUT_DIR}/final-clusters.txt" 2>&1 || clusters_list_status=$?
  gcloud compute disks list --project="${PROJECT_ID}" --filter="zone~${ZONE}\$" \
    > "${OUT_DIR}/final-disks.txt" 2>&1 || disks_list_status=$?

  local verify_clean=1
  if (( clusters_list_status != 0 )); then
    echo "ERROR: could not verify cluster teardown (clusters list failed)" >&2
    final_status=1
    verify_clean=0
  elif grep -qw "${CLUSTER_NAME}" "${OUT_DIR}/final-clusters.txt" 2>/dev/null; then
    echo "ERROR: cluster ${CLUSTER_NAME} still present after cleanup" >&2
    final_status=1
    verify_clean=0
  fi

  local leftover=""
  if (( disks_list_status != 0 )); then
    echo "ERROR: could not verify leftover disks (disks list failed)" >&2
    final_status=1
    verify_clean=0
  else
    leftover="$(grep -E "pvc-|${CLUSTER_NAME}" "${OUT_DIR}/final-disks.txt" 2>/dev/null || true)"
    if [[ -n "${leftover}" ]]; then
      echo "ERROR: leftover disk(s) after cleanup:" >&2
      echo "${leftover}" >&2
      final_status=1
      verify_clean=0
    fi
  fi

  if [[ "${CLEANUP_RAN}" != "1" ]]; then
    verify_clean=0
  fi

  if [[ "${verify_clean}" == "1" ]]; then
    if [[ -n "${WATCHDOG_PID}" ]]; then
      touch "${WATCHDOG_STOP}" 2>/dev/null || true
      for _ in 1 2 3; do
        kill -0 "${WATCHDOG_PID}" 2>/dev/null || break
        sleep 1
      done
      kill "${WATCHDOG_PID}" 2>/dev/null || true
      wait "${WATCHDOG_PID}" 2>/dev/null || true
    fi
  else
    echo "============================================================" >&2
    echo "CLEANUP COULD NOT VERIFY A CLEAN TEARDOWN. WATCHDOG LEFT ARMED." >&2
    echo "Manual action may be required:" >&2
    echo "  gcloud container clusters delete ${CLUSTER_NAME} --zone=${ZONE} --project=${PROJECT_ID} --quiet" >&2
    echo "  gcloud compute disks delete <DISK_NAME> --zone=${ZONE} --project=${PROJECT_ID}" >&2
    echo "============================================================" >&2
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

# Watchdog: backstop if this run is killed outright, or is stuck. Polls a
# stop flag in short ticks instead of one long `sleep WATCHDOG_SEC`, so the
# trap can end it immediately (no orphaned sleep process left behind)
# instead of having to kill a process group. On fire, it signals the main
# process first and gives its own trap a chance to clean up (sharing the
# mkdir lock above), only running cleanup itself if the cluster is still
# there after that grace period.
rm -f "${WATCHDOG_STOP}"
(
  # Survive a closed terminal: the runner cleans up on HUP, but if it dies
  # without cleaning up, this is the backstop.
  trap '' HUP
  wd_start=${SECONDS}
  while (( SECONDS - wd_start < WATCHDOG_SEC )); do
    [[ -f "${WATCHDOG_STOP}" ]] && exit 0
    sleep 1
  done
  [[ -f "${WATCHDOG_STOP}" ]] && exit 0
  echo "$(ts) WATCHDOG FIRED: sending TERM to main (pid ${MAIN_PID})" >> "${OUT_DIR}/phases.log"
  kill -TERM "${MAIN_PID}" 2>/dev/null || true
  grace_start=${SECONDS}
  while (( SECONDS - grace_start < 120 )); do
    kill -0 "${MAIN_PID}" 2>/dev/null || break
    [[ -f "${WATCHDOG_STOP}" ]] && exit 0
    sleep 1
  done
  [[ -f "${WATCHDOG_STOP}" ]] && exit 0
  if cluster_exists; then
    echo "$(ts) WATCHDOG: cluster ${CLUSTER_NAME} still exists after waiting for main; running cleanup" >> "${OUT_DIR}/phases.log"
    acquire_cleanup_lock
    cmd="${RUNNER_CLEANUP:-${SCRIPT_DIR}/cleanup.sh}"
    "${cmd}" --yes >> "${OUT_DIR}/watchdog.log" 2>&1 || true
    release_cleanup_lock
  fi
# Explicitly detached stdio: if a run leaves the watchdog armed (a
# teardown that could not be verified clean, see on_exit), it can outlive
# the main process. Without this redirect it would keep holding open the
# parent's inherited stdout/stderr, and anything reading the main
# process's output via a pipe or `$(...)` (real usage, and every test
# here) would block waiting for EOF until the watchdog itself exits.
) < /dev/null >> "${OUT_DIR}/watchdog-bg.log" 2>&1 &
WATCHDOG_PID=$!
disown "${WATCHDOG_PID}" 2>/dev/null || true
echo "${WATCHDOG_PID}" > "${OUT_DIR}/watchdog.pid"

mark "deploy start"
DEPLOY_CMD="${RUNNER_DEPLOY:-${SCRIPT_DIR}/deploy_nim_gke.sh}"
"${DEPLOY_CMD}" 2>&1 | tee "${OUT_DIR}/deploy.log"
mark "deploy end"

# The NGC key has done its job (deploy consumed it); do not let bench,
# port-forward, or the watchdog inherit it.
unset NGC_API_KEY NGC_CLI_API_KEY || true

if [[ "${AUTOSCALE:-0}" == "1" ]]; then
  mark "phase 0to1 start"
  kubectl get pods -n "${NIM_NAMESPACE}" -o wide > "${OUT_DIR}/pods-0to1-start.txt" 2>&1 || true
  kubectl describe pod "${NIM_RELEASE_NAME}-nim-llm-0" -n "${NIM_NAMESPACE}" \
    > "${OUT_DIR}/pod-0-describe-0to1-start.txt" 2>&1 || true
  init_gpu_nodes="$(gpu_node_present_count)"
  echo "$(ts) gpu node count at phase 0to1 start: ${init_gpu_nodes}" >> "${OUT_DIR}/phases.log"
  if [[ "${init_gpu_nodes}" != "0" ]]; then
    mark "ERROR: expected 0 GPU nodes at phase 0to1 start, got ${init_gpu_nodes}"
    exit 1
  fi
  if ! wait_for_gpu_nodes 1 "${SCALE_UP_TIMEOUT_SEC}"; then
    mark "gpu node 1 Ready TIMEOUT"
    exit 1
  fi
  mark "gpu node 1 Ready"
  kubectl get nodes -l cloud.google.com/gke-accelerator \
    -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp,STATUS:.status.conditions[-1].type \
    > "${OUT_DIR}/gpu-nodes-0to1.txt" 2>&1 || true
fi

mark "wait Ready start"
elapsed_start=${SECONDS}
ready="false"
while (( SECONDS - elapsed_start < READY_TIMEOUT_SEC )); do
  ready="$(kubectl get pod "${NIM_RELEASE_NAME}-nim-llm-0" -n "${NIM_NAMESPACE}" \
    -o jsonpath='{.status.containerStatuses[0].ready}' --request-timeout=30s 2>/dev/null || true)"
  if [[ "${ready}" == "true" ]]; then
    break
  fi
  sleep "${POLL_SEC}"
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
  gcloud compute instances list --project="${PROJECT_ID}" \
    --filter="name~gke-${CLUSTER_NAME}-gpupool" \
    > "${OUT_DIR}/instances-scale-to-0.txt" 2>&1 || true

  # Cluster-autoscaler-visibility log for this run; failure here must not
  # abort the run (evidence-gathering only).
  autoscaler_filter="resource.type=\"k8s_cluster\" AND resource.labels.cluster_name=\"${CLUSTER_NAME}\" AND resource.labels.location=\"${ZONE}\" AND logName=\"projects/${PROJECT_ID}/logs/container.googleapis.com%2Fcluster-autoscaler-visibility\" AND timestamp>=\"${RUN_START_TS}\""
  if gcloud logging read "${autoscaler_filter}" --project="${PROJECT_ID}" --format=json \
      > "${OUT_DIR}/autoscaler.json" 2>"${OUT_DIR}/autoscaler.err"; then
    scale_up_count="$(grep -c 'scaleUp' "${OUT_DIR}/autoscaler.json" 2>/dev/null || true)"
    scale_down_count="$(grep -c 'scaleDown' "${OUT_DIR}/autoscaler.json" 2>/dev/null || true)"
    mark "autoscaler evidence: scaleUp=${scale_up_count:-0} scaleDown=${scale_down_count:-0}"
  else
    echo "$(ts) gcloud logging read failed (non-fatal); see autoscaler.err" >> "${OUT_DIR}/phases.log"
    mark "autoscaler evidence: UNAVAILABLE"
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
