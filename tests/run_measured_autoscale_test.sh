#!/bin/bash
# Tests for scripts/run_measured.sh --autoscale / --two-nodes. No network,
# no real gcloud/kubectl/helm: tests/stubs/ on PATH (kubectl's GPU-node-count
# sequence hook, gcloud's no-op list/describe calls), plus fake
# RUNNER_PREFLIGHT/RUNNER_DEPLOY/RUNNER_BENCH/RUNNER_CLEANUP scripts (in a
# temp dir) that log their own calls and exit as configured. Existing
# R1-R6 (tests/run_measured_test.sh) and T1-T3 (tests/cleanup_test.sh) are
# unaffected by this file.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${REPO_ROOT}/scripts/run_measured.sh"
STUB_DIR="${REPO_ROOT}/tests/stubs"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FAKE_DIR="${TMP_DIR}/fakes"
mkdir -p "${FAKE_DIR}"

export STUB_LOG="${TMP_DIR}/stub_calls.log"
export CALLS_LOG="${TMP_DIR}/fake_calls.log"
export PATH="${STUB_DIR}:${FAKE_DIR}:${PATH}"

export PROJECT_ID="test-project"
export NGC_API_KEY="test-key"
export POLL_SEC=1
export READY_TIMEOUT_SEC=5
export WATCHDOG_SEC=600
export STUB_POD_READY=true

cat > "${FAKE_DIR}/fake_preflight" <<'EOF'
#!/bin/bash
echo "preflight $*" >> "${CALLS_LOG}"
exit 0
EOF

cat > "${FAKE_DIR}/fake_deploy" <<'EOF'
#!/bin/bash
echo "deploy $*" >> "${CALLS_LOG}"
exit 0
EOF

cat > "${FAKE_DIR}/fake_deploy_sleep" <<'EOF'
#!/bin/bash
echo "deploy $*" >> "${CALLS_LOG}"
sleep 3
echo "deploy done $*" >> "${CALLS_LOG}"
exit 0
EOF

cat > "${FAKE_DIR}/fake_bench" <<'EOF'
#!/bin/bash
echo "bench $*" >> "${CALLS_LOG}"
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--out" ]]; then
    out="$2"
  fi
  shift
done
[[ -n "${out}" ]] && echo '{"ok":true}' > "${out}"
exit 0
EOF

cat > "${FAKE_DIR}/fake_cleanup" <<'EOF'
#!/bin/bash
echo "cleanup $*" >> "${CALLS_LOG}"
exit 0
EOF

chmod +x "${FAKE_DIR}"/fake_*

export RUNNER_PREFLIGHT="${FAKE_DIR}/fake_preflight"
export RUNNER_DEPLOY="${FAKE_DIR}/fake_deploy"
export RUNNER_BENCH="${FAKE_DIR}/fake_bench"
export RUNNER_CLEANUP="${FAKE_DIR}/fake_cleanup"

FAIL=0

reset_logs() {
  : > "${STUB_LOG}"
  : > "${CALLS_LOG}"
  unset STUB_GPU_NODE_SEQ_FILE MAX_GPU_NODES SCALE_UP_TIMEOUT_SEC SCALE_DOWN_TIMEOUT_SEC
  export RUNNER_DEPLOY="${FAKE_DIR}/fake_deploy"
  # S5b: the trap cleanup path now confirms teardown via `gcloud container
  # clusters describe` (cluster_exists(), used by cleanup_with_retry)
  # before declaring cleanup done; default to absent so these tests (which
  # never exercised describe before) don't hang retrying against the
  # stub's previous default "describe succeeds" behavior.
  export STUB_CLUSTER=absent
}

cleanup_call_count() {
  grep -c "^cleanup --yes" "${CALLS_LOG}" 2>/dev/null || true
}

check_watchdog_gone() {
  local out_dir="$1" pid
  if [[ -f "${out_dir}/watchdog.pid" ]]; then
    pid="$(cat "${out_dir}/watchdog.pid")"
    if kill -0 "${pid}" 2>/dev/null; then
      echo "watchdog pid ${pid} still alive"
    fi
  fi
}

mark_order_ok() {
  # $1 = phases.log path, remaining args = keywords expected in order.
  local log="$1"; shift
  local prev=0 ln kw
  for kw in "$@"; do
    ln="$(grep -n -F -- "${kw}" "${log}" 2>/dev/null | head -1 | cut -d: -f1)"
    if [[ -z "${ln}" ]] || (( ln <= prev )); then
      echo "false"
      return
    fi
    prev="${ln}"
  done
  echo "true"
}

WATCHDOG_LEFTOVER=""

# --- A3: --autoscale happy path (no --two-nodes): 0 -> 1 -> 0 gpu sequence ---
reset_logs
OUT3="${TMP_DIR}/outA3"
SEQ3="${TMP_DIR}/seq3.txt"
printf '0\n0\n1\n1\n1\n0\n0\n' > "${SEQ3}"
export STUB_GPU_NODE_SEQ_FILE="${SEQ3}"
export SCALE_UP_TIMEOUT_SEC=10
export SCALE_DOWN_TIMEOUT_SEC=10
set +e
a3_out="$("${RUNNER}" --autoscale "${OUT3}" 2>&1)"
a3_status=$?
set -e

a3_pass=true
[[ "${a3_status}" -eq 0 ]] || a3_pass=false
order_a3="$(mark_order_ok "${OUT3}/phases.log" "phase 0to1 start" "gpu node 1 Ready" "pod Ready" "bench" "phase scale-to-0 start" "gpu nodes 0" "cleanup")"
[[ "${order_a3}" == "true" ]] || a3_pass=false
grep -Eq "kubectl scale statefulset/.*--replicas=0" "${STUB_LOG}" || a3_pass=false
WATCHDOG_LEFTOVER+="$(check_watchdog_gone "${OUT3}")"

if [[ "${a3_pass}" == "true" ]]; then
  echo "A3 PASS"
else
  echo "A3 FAIL (status=${a3_status}, order_ok=${order_a3})"
  echo "--- phases.log ---"; cat "${OUT3}/phases.log" 2>/dev/null || true
  echo "--- output ---"; echo "${a3_out}"
  FAIL=1
fi

# --- A4: --two-nodes with MAX_GPU_NODES=1 -> exit 2 ---
reset_logs
OUT4="${TMP_DIR}/outA4"
set +e
a4_out="$(MAX_GPU_NODES=1 "${RUNNER}" --autoscale --two-nodes "${OUT4}" 2>&1)"
a4_status=$?
set -e

a4_pass=true
[[ "${a4_status}" -eq 2 ]] || a4_pass=false
[[ ! -s "${CALLS_LOG}" ]] || a4_pass=false

if [[ "${a4_pass}" == "true" ]]; then
  echo "A4 PASS"
else
  echo "A4 FAIL (status=${a4_status})"
  echo "--- output ---"; echo "${a4_out}"
  FAIL=1
fi

# --- A5: --two-nodes happy path: 0 -> 1 -> 2 -> 0 gpu sequence ---
reset_logs
OUT5="${TMP_DIR}/outA5"
SEQ5="${TMP_DIR}/seq5.txt"
printf '0\n0\n1\n1\n2\n2\n0\n0\n' > "${SEQ5}"
export STUB_GPU_NODE_SEQ_FILE="${SEQ5}"
export MAX_GPU_NODES=2
export SCALE_UP_TIMEOUT_SEC=10
export SCALE_DOWN_TIMEOUT_SEC=10
set +e
a5_out="$("${RUNNER}" --autoscale --two-nodes "${OUT5}" 2>&1)"
a5_status=$?
set -e

a5_pass=true
[[ "${a5_status}" -eq 0 ]] || a5_pass=false
grep -q "gpu node 2 Ready" "${OUT5}/phases.log" 2>/dev/null || a5_pass=false
r2_line="$(grep -n -E "kubectl scale statefulset/.*--replicas=2" "${STUB_LOG}" | head -1 | cut -d: -f1)"
r0_line="$(grep -n -E "kubectl scale statefulset/.*--replicas=0" "${STUB_LOG}" | head -1 | cut -d: -f1)"
if [[ -z "${r2_line}" || -z "${r0_line}" || "${r0_line}" -le "${r2_line}" ]]; then
  a5_pass=false
fi

if [[ "${a5_pass}" == "true" ]]; then
  echo "A5 PASS"
else
  echo "A5 FAIL (status=${a5_status})"
  echo "--- phases.log ---"; cat "${OUT5}/phases.log" 2>/dev/null || true
  echo "--- stub log ---"; cat "${STUB_LOG}" 2>/dev/null || true
  echo "--- output ---"; echo "${a5_out}"
  FAIL=1
fi

# --- A7: scale-down timeout (node count stays 1) ---
reset_logs
OUT7="${TMP_DIR}/outA7"
SEQ7="${TMP_DIR}/seq7.txt"
printf '0\n0\n1\n' > "${SEQ7}"   # clamps to 1 forever once exhausted
export STUB_GPU_NODE_SEQ_FILE="${SEQ7}"
export SCALE_UP_TIMEOUT_SEC=10
export SCALE_DOWN_TIMEOUT_SEC=3
set +e
a7_out="$("${RUNNER}" --autoscale "${OUT7}" 2>&1)"
a7_status=$?
set -e

a7_pass=true
[[ "${a7_status}" -ne 0 ]] || a7_pass=false
grep -q "TIMEOUT" "${OUT7}/phases.log" 2>/dev/null || a7_pass=false
[[ "$(cleanup_call_count)" -eq 1 ]] || a7_pass=false
WATCHDOG_LEFTOVER+="$(check_watchdog_gone "${OUT7}")"

if [[ "${a7_pass}" == "true" ]]; then
  echo "A7 PASS"
else
  echo "A7 FAIL (status=${a7_status}, cleanup_calls=$(cleanup_call_count))"
  echo "--- phases.log ---"; cat "${OUT7}/phases.log" 2>/dev/null || true
  echo "--- output ---"; echo "${a7_out}"
  FAIL=1
fi

# --- A8: SIGTERM mid-deploy ---
reset_logs
OUT8="${TMP_DIR}/outA8"
export RUNNER_DEPLOY="${FAKE_DIR}/fake_deploy_sleep"
"${RUNNER}" "${OUT8}" > "${TMP_DIR}/a8.out" 2>&1 &
a8_pid=$!
sleep 1
kill -TERM "${a8_pid}" 2>/dev/null || true
set +e
wait "${a8_pid}"
a8_status=$?
set -e
export RUNNER_DEPLOY="${FAKE_DIR}/fake_deploy"

a8_pass=true
[[ "${a8_status}" -eq 143 ]] || a8_pass=false
[[ "$(cleanup_call_count)" -eq 1 ]] || a8_pass=false
WATCHDOG_LEFTOVER+="$(check_watchdog_gone "${OUT8}")"

if [[ "${a8_pass}" == "true" ]]; then
  echo "A8 PASS"
else
  echo "A8 FAIL (status=${a8_status}, cleanup_calls=$(cleanup_call_count))"
  echo "--- output ---"; cat "${TMP_DIR}/a8.out" 2>/dev/null || true
  FAIL=1
fi

# --- watchdog leftover check across all tests above ---
if [[ -z "${WATCHDOG_LEFTOVER}" ]]; then
  echo "A_WATCHDOG PASS"
else
  echo "A_WATCHDOG FAIL"
  echo "${WATCHDOG_LEFTOVER}"
  FAIL=1
fi

if [[ "${FAIL}" -ne 0 ]]; then
  exit 1
fi

exit 0
