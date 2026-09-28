#!/bin/bash
# Tests for scripts/run_measured.sh. No network, no real gcloud/kubectl/helm:
# tests/stubs/ on PATH for the real calls run_measured.sh still makes
# (kubectl get pod / port-forward, gcloud operations/clusters/disks list),
# plus fake RUNNER_PREFLIGHT/RUNNER_DEPLOY/RUNNER_BENCH/RUNNER_CLEANUP
# scripts (in a temp dir) that log their own calls and exit as configured.

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
export READY_TIMEOUT_SEC=3
export WATCHDOG_SEC=600

cat > "${FAKE_DIR}/fake_preflight" <<'EOF'
#!/bin/bash
echo "preflight $*" >> "${CALLS_LOG}"
exit "${FAKE_PREFLIGHT_EXIT:-0}"
EOF

cat > "${FAKE_DIR}/fake_deploy" <<'EOF'
#!/bin/bash
echo "deploy $*" >> "${CALLS_LOG}"
exit "${FAKE_DEPLOY_EXIT:-0}"
EOF

cat > "${FAKE_DIR}/fake_bench" <<'EOF'
#!/bin/bash
echo "bench $*" >> "${CALLS_LOG}"
# args: --out OUT_FILE
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--out" ]]; then
    out="$2"
  fi
  shift
done
[[ -n "${out}" ]] && echo '{"ok":true}' > "${out}"
exit "${FAKE_BENCH_EXIT:-0}"
EOF

cat > "${FAKE_DIR}/fake_cleanup" <<'EOF'
#!/bin/bash
echo "cleanup $*" >> "${CALLS_LOG}"
exit "${FAKE_CLEANUP_EXIT:-0}"
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
  unset FAKE_PREFLIGHT_EXIT FAKE_DEPLOY_EXIT FAKE_BENCH_EXIT FAKE_CLEANUP_EXIT
  unset STUB_POD_READY STUB_DISKS_OUTPUT
}

cleanup_call_count() {
  grep -c "^cleanup --yes" "${CALLS_LOG}" 2>/dev/null || true
}

check_watchdog_gone() {
  # $1 = OUT_DIR. Passes (echoes nothing) if no watchdog.pid or the pid is gone.
  local out_dir="$1" pid
  if [[ -f "${out_dir}/watchdog.pid" ]]; then
    pid="$(cat "${out_dir}/watchdog.pid")"
    if kill -0 "${pid}" 2>/dev/null; then
      echo "watchdog pid ${pid} still alive"
    fi
  fi
}

WATCHDOG_LEFTOVER=""

# --- R1: forced deploy failure ---
reset_logs
OUT1="${TMP_DIR}/out1"
export FAKE_DEPLOY_EXIT=1
set +e
r1_out="$("${RUNNER}" "${OUT1}" 2>&1)"
r1_status=$?
set -e

r1_pass=true
[[ "${r1_status}" -ne 0 ]] || r1_pass=false
[[ "$(cleanup_call_count)" -eq 1 ]] || r1_pass=false
grep -q "^cleanup --yes$" "${CALLS_LOG}" || r1_pass=false
WATCHDOG_LEFTOVER+="$(check_watchdog_gone "${OUT1}")"

if [[ "${r1_pass}" == "true" ]]; then
  echo "R1 PASS"
else
  echo "R1 FAIL (status=${r1_status}, cleanup_calls=$(cleanup_call_count))"
  echo "--- output ---"; echo "${r1_out}"
  FAIL=1
fi

# --- R2: never Ready ---
reset_logs
OUT2="${TMP_DIR}/out2"
export STUB_POD_READY=false
set +e
r2_out="$("${RUNNER}" "${OUT2}" 2>&1)"
r2_status=$?
set -e

r2_pass=true
[[ "${r2_status}" -ne 0 ]] || r2_pass=false
grep -q "Ready TIMEOUT" "${OUT2}/phases.log" 2>/dev/null || r2_pass=false
[[ "$(cleanup_call_count)" -eq 1 ]] || r2_pass=false
WATCHDOG_LEFTOVER+="$(check_watchdog_gone "${OUT2}")"

if [[ "${r2_pass}" == "true" ]]; then
  echo "R2 PASS"
else
  echo "R2 FAIL (status=${r2_status}, cleanup_calls=$(cleanup_call_count))"
  echo "--- output ---"; echo "${r2_out}"
  echo "--- phases.log ---"; cat "${OUT2}/phases.log" 2>/dev/null || true
  FAIL=1
fi

# --- R3: happy path ---
reset_logs
OUT3="${TMP_DIR}/out3"
export STUB_POD_READY=true
set +e
r3_out="$("${RUNNER}" "${OUT3}" 2>&1)"
r3_status=$?
set -e

r3_pass=true
[[ "${r3_status}" -eq 0 ]] || r3_pass=false
[[ "$(cleanup_call_count)" -eq 1 ]] || r3_pass=false
for f in final-clusters.txt final-disks.txt operations.txt; do
  [[ -f "${OUT3}/${f}" ]] || r3_pass=false
done

order_ok=true
prev=0
for kw in preflight deploy Ready bench cleanup; do
  ln="$(grep -n "${kw}" "${OUT3}/phases.log" 2>/dev/null | head -1 | cut -d: -f1)"
  if [[ -z "${ln}" ]] || (( ln <= prev )); then
    order_ok=false
  fi
  prev="${ln:-${prev}}"
done
[[ "${order_ok}" == "true" ]] || r3_pass=false
WATCHDOG_LEFTOVER+="$(check_watchdog_gone "${OUT3}")"

if [[ "${r3_pass}" == "true" ]]; then
  echo "R3 PASS"
else
  echo "R3 FAIL (status=${r3_status}, cleanup_calls=$(cleanup_call_count), order_ok=${order_ok})"
  echo "--- output ---"; echo "${r3_out}"
  echo "--- phases.log ---"; cat "${OUT3}/phases.log" 2>/dev/null || true
  FAIL=1
fi

# --- R4: leftover disk ---
reset_logs
OUT4="${TMP_DIR}/out4"
export STUB_POD_READY=true
export STUB_DISKS_OUTPUT="pvc-abc123def  us-central1-a"
set +e
r4_out="$("${RUNNER}" "${OUT4}" 2>&1)"
r4_status=$?
set -e

r4_pass=true
[[ "${r4_status}" -ne 0 ]] || r4_pass=false
echo "${r4_out}" | grep -q "pvc-abc123def" || r4_pass=false
WATCHDOG_LEFTOVER+="$(check_watchdog_gone "${OUT4}")"

if [[ "${r4_pass}" == "true" ]]; then
  echo "R4 PASS"
else
  echo "R4 FAIL (status=${r4_status})"
  echo "--- output ---"; echo "${r4_out}"
  FAIL=1
fi

# --- R5: missing PROJECT_ID / missing OUT_DIR ---
reset_logs
OUT5A="${TMP_DIR}/out5a"
set +e
r5a_out="$(env -u PROJECT_ID "${RUNNER}" "${OUT5A}" 2>&1)"
r5a_status=$?
set -e

r5a_pass=true
[[ "${r5a_status}" -eq 1 ]] || r5a_pass=false
[[ ! -s "${STUB_LOG}" ]] || r5a_pass=false
[[ ! -s "${CALLS_LOG}" ]] || r5a_pass=false

set +e
r5b_out="$("${RUNNER}" 2>&1)"
r5b_status=$?
set -e

r5b_pass=true
[[ "${r5b_status}" -eq 2 ]] || r5b_pass=false

if [[ "${r5a_pass}" == "true" && "${r5b_pass}" == "true" ]]; then
  echo "R5 PASS"
else
  echo "R5 FAIL (5a_status=${r5a_status}, 5b_status=${r5b_status})"
  echo "--- 5a output ---"; echo "${r5a_out}"
  echo "--- 5b output ---"; echo "${r5b_out}"
  FAIL=1
fi

# --- R6: no watchdog process left behind by any test above ---
if [[ -z "${WATCHDOG_LEFTOVER}" ]]; then
  echo "R6 PASS"
else
  echo "R6 FAIL"
  echo "${WATCHDOG_LEFTOVER}"
  FAIL=1
fi

if [[ "${FAIL}" -ne 0 ]]; then
  exit 1
fi

exit 0
