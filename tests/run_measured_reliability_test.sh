#!/bin/bash
# S5b fix-pass regression tests for scripts/run_measured.sh / cleanup.sh:
# signal-safe cleanup that cannot be interrupted mid-teardown (B1), a
# kubectl failure never masquerading as "0 GPU nodes" (B2), wall-clock
# watchdog/wait deadlines with a TERM-then-cleanup-itself watchdog and a
# shared cleanup lock (M3), and final-check failures reported instead of
# swallowed (M6/M7). No network, no real gcloud/kubectl/helm: tests/stubs/
# on PATH, plus fake RUNNER_PREFLIGHT/RUNNER_DEPLOY/RUNNER_BENCH/
# RUNNER_CLEANUP scripts in a temp dir. Existing R1-R6, A3-A8, T1-T3 are
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
sleep "${FAKE_DEPLOY_SLEEP_SEC:-3}"
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
exit "${FAKE_CLEANUP_EXIT:-0}"
EOF

cat > "${FAKE_DIR}/fake_cleanup_sleep" <<'EOF'
#!/bin/bash
echo "cleanup start $$" >> "${CALLS_LOG}"
sleep "${FAKE_CLEANUP_SLEEP_SEC:-0}"
echo "cleanup $*" >> "${CALLS_LOG}"
exit "${FAKE_CLEANUP_EXIT:-0}"
EOF

cat > "${FAKE_DIR}/fake_cleanup_always_fail" <<'EOF'
#!/bin/bash
echo "cleanup $*" >> "${CALLS_LOG}"
exit 1
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
  rm -f "${STUB_LOG}.kubectl_fail" "${STUB_LOG}.kubectl_count"
  unset FAKE_DEPLOY_SLEEP_SEC FAKE_CLEANUP_SLEEP_SEC FAKE_CLEANUP_EXIT
  unset STUB_GPU_NODE_SEQ_FILE STUB_GPU_NODE_STATUS
  unset STUB_KUBECTL_FAIL_AFTER STUB_KUBECTL_FAIL_AFTER_SCALE STUB_KUBECTL_FAIL_FLAG_FILE STUB_KUBECTL_CALL_COUNT_FILE
  unset STUB_CLUSTERS_LIST_EXIT STUB_CLUSTERS_LIST_OUTPUT STUB_DISKS_LIST_EXIT STUB_DISKS_OUTPUT
  unset MAX_GPU_NODES SCALE_UP_TIMEOUT_SEC SCALE_DOWN_TIMEOUT_SEC CLEANUP_RETRY_SEC OPS_WAIT_SEC
  export STUB_CLUSTER=absent
  export STUB_POD_READY=true
  export WATCHDOG_SEC=600
  export RUNNER_DEPLOY="${FAKE_DIR}/fake_deploy"
  export RUNNER_CLEANUP="${FAKE_DIR}/fake_cleanup"
}

cleanup_call_count() {
  grep -c "^cleanup --yes" "${CALLS_LOG}" 2>/dev/null || true
}

check_watchdog_gone() {  # $1 = OUT_DIR
  local out_dir="$1" pid
  if [[ -f "${out_dir}/watchdog.pid" ]]; then
    pid="$(cat "${out_dir}/watchdog.pid")"
    if kill -0 "${pid}" 2>/dev/null; then
      echo "watchdog pid ${pid} still alive"
    fi
  fi
}

WATCHDOG_LEFTOVER=""

# --- E1: HUP mid-deploy -> exit 129, exactly one cleanup ---
reset_logs
OUT1="${TMP_DIR}/outE1"
export RUNNER_DEPLOY="${FAKE_DIR}/fake_deploy_sleep"
export FAKE_DEPLOY_SLEEP_SEC=5
"${RUNNER}" "${OUT1}" > "${TMP_DIR}/e1.out" 2>&1 &
e1_pid=$!
sleep 1
kill -HUP "${e1_pid}" 2>/dev/null || true
set +e
wait "${e1_pid}"
e1_status=$?
set -e

e1_pass=true
[[ "${e1_status}" -eq 129 ]] || e1_pass=false
[[ "$(cleanup_call_count)" -eq 1 ]] || e1_pass=false
WATCHDOG_LEFTOVER+="$(check_watchdog_gone "${OUT1}")"

if [[ "${e1_pass}" == "true" ]]; then
  echo "E1 PASS"
else
  echo "E1 FAIL (status=${e1_status}, cleanup_calls=$(cleanup_call_count))"
  echo "--- output ---"; cat "${TMP_DIR}/e1.out" 2>/dev/null || true
  FAIL=1
fi

# --- E2: kubectl fails during scale-down wait -> NOT exit 0; no "gpu nodes 0" ---
reset_logs
OUT2="${TMP_DIR}/outE2"
SEQ2="${TMP_DIR}/seqE2.txt"
printf '0\n0\n1\n1\n1\n' > "${SEQ2}"
export STUB_GPU_NODE_SEQ_FILE="${SEQ2}"
export STUB_KUBECTL_FAIL_AFTER_SCALE=1
export SCALE_UP_TIMEOUT_SEC=10
export SCALE_DOWN_TIMEOUT_SEC=3
set +e
e2_out="$("${RUNNER}" --autoscale "${OUT2}" 2>&1)"
e2_status=$?
set -e

e2_pass=true
[[ "${e2_status}" -ne 0 ]] || e2_pass=false
grep -qE "gpu nodes 0$" "${OUT2}/phases.log" 2>/dev/null && e2_pass=false
WATCHDOG_LEFTOVER+="$(check_watchdog_gone "${OUT2}")"

if [[ "${e2_pass}" == "true" ]]; then
  echo "E2 PASS"
else
  echo "E2 FAIL (status=${e2_status})"
  echo "--- phases.log ---"; cat "${OUT2}/phases.log" 2>/dev/null || true
  echo "--- output ---"; echo "${e2_out}"
  FAIL=1
fi

# --- E3: double SIGINT to the process group during trap cleanup -> cleanup completes, final checks run ---
reset_logs
OUT3="${TMP_DIR}/outE3"
export RUNNER_CLEANUP="${FAKE_DIR}/fake_cleanup_sleep"
export FAKE_CLEANUP_SLEEP_SEC=3
set -m
"${RUNNER}" "${OUT3}" > "${TMP_DIR}/e3.out" 2>&1 &
e3_pid=$!
sleep 1
kill -INT -- -"${e3_pid}" 2>/dev/null || true
sleep 0.5
kill -INT -- -"${e3_pid}" 2>/dev/null || true
set +e
wait "${e3_pid}"
e3_status=$?
set -e
set +m
export RUNNER_CLEANUP="${FAKE_DIR}/fake_cleanup"

e3_pass=true
grep -q "cleanup end (trap)" "${OUT3}/phases.log" 2>/dev/null || e3_pass=false
[[ -f "${OUT3}/final-clusters.txt" ]] || e3_pass=false
[[ -f "${OUT3}/final-disks.txt" ]] || e3_pass=false
WATCHDOG_LEFTOVER+="$(check_watchdog_gone "${OUT3}")"

if [[ "${e3_pass}" == "true" ]]; then
  echo "E3 PASS"
else
  echo "E3 FAIL (status=${e3_status})"
  echo "--- phases.log ---"; cat "${OUT3}/phases.log" 2>/dev/null || true
  echo "--- output ---"; cat "${TMP_DIR}/e3.out" 2>/dev/null || true
  FAIL=1
fi

# --- E4: watchdog fires mid-run (tiny WATCHDOG_SEC) -> main terminated, never two overlapping cleanups ---
reset_logs
OUT4="${TMP_DIR}/outE4"
export RUNNER_DEPLOY="${FAKE_DIR}/fake_deploy_sleep"
export FAKE_DEPLOY_SLEEP_SEC=5
export WATCHDOG_SEC=2
set +e
e4_out="$("${RUNNER}" "${OUT4}" 2>&1)"
e4_status=$?
set -e

e4_pass=true
[[ "${e4_status}" -eq 143 ]] || e4_pass=false
[[ "$(cleanup_call_count)" -eq 1 ]] || e4_pass=false
grep -q "WATCHDOG FIRED" "${OUT4}/phases.log" 2>/dev/null || e4_pass=false
WATCHDOG_LEFTOVER+="$(check_watchdog_gone "${OUT4}")"

if [[ "${e4_pass}" == "true" ]]; then
  echo "E4 PASS"
else
  echo "E4 FAIL (status=${e4_status}, cleanup_calls=$(cleanup_call_count))"
  echo "--- phases.log ---"; cat "${OUT4}/phases.log" 2>/dev/null || true
  echo "--- output ---"; echo "${e4_out}"
  FAIL=1
fi

# --- E5: trap cleanup keeps failing with the cluster listed -> exit non-zero, banner, watchdog NOT disarmed ---
reset_logs
OUT5="${TMP_DIR}/outE5"
export RUNNER_CLEANUP="${FAKE_DIR}/fake_cleanup_always_fail"
export STUB_CLUSTER=present
export CLEANUP_RETRY_SEC=3
set +e
e5_out="$("${RUNNER}" "${OUT5}" 2>&1)"
e5_status=$?
set -e

e5_pass=true
[[ "${e5_status}" -ne 0 ]] || e5_pass=false
echo "${e5_out}" | grep -q "WATCHDOG LEFT ARMED" || e5_pass=false
e5_wd_pid=""
if [[ -f "${OUT5}/watchdog.pid" ]]; then
  e5_wd_pid="$(cat "${OUT5}/watchdog.pid")"
  kill -0 "${e5_wd_pid}" 2>/dev/null || e5_pass=false
else
  e5_pass=false
fi
[[ ! -f "${OUT5}/.watchdog_stop" ]] || e5_pass=false

if [[ "${e5_pass}" == "true" ]]; then
  echo "E5 PASS"
else
  echo "E5 FAIL (status=${e5_status})"
  echo "--- output ---"; echo "${e5_out}"
  FAIL=1
fi

# E5 deliberately leaves the watchdog armed (that's the behavior under
# test); tear it down explicitly now so it does not leak past this file.
if [[ -n "${e5_wd_pid}" ]]; then
  touch "${OUT5}/.watchdog_stop" 2>/dev/null || true
  kill "${e5_wd_pid}" 2>/dev/null || true
  wait "${e5_wd_pid}" 2>/dev/null || true
fi
export RUNNER_CLEANUP="${FAKE_DIR}/fake_cleanup"
export STUB_CLUSTER=absent

# --- E6: `clusters list` fails in the final check -> exit non-zero with "could not verify" ---
reset_logs
OUT6="${TMP_DIR}/outE6"
export STUB_CLUSTERS_LIST_EXIT=1
set +e
e6_out="$("${RUNNER}" "${OUT6}" 2>&1)"
e6_status=$?
set -e

e6_pass=true
[[ "${e6_status}" -ne 0 ]] || e6_pass=false
echo "${e6_out}" | grep -q "could not verify" || e6_pass=false
# A clusters-list failure means the final check could not verify a clean
# teardown, so (same as R4/E5) on_exit intentionally leaves the watchdog
# armed rather than disarming it; assert and tear it down explicitly
# instead of using the shared "watchdog gone" check.
e6_wd_pid=""
if [[ -f "${OUT6}/watchdog.pid" ]]; then
  e6_wd_pid="$(cat "${OUT6}/watchdog.pid")"
  kill -0 "${e6_wd_pid}" 2>/dev/null || e6_pass=false
else
  e6_pass=false
fi

if [[ "${e6_pass}" == "true" ]]; then
  echo "E6 PASS"
else
  echo "E6 FAIL (status=${e6_status})"
  echo "--- output ---"; echo "${e6_out}"
  FAIL=1
fi

if [[ -n "${e6_wd_pid}" ]]; then
  touch "${OUT6}/.watchdog_stop" 2>/dev/null || true
  kill "${e6_wd_pid}" 2>/dev/null || true
  wait "${e6_wd_pid}" 2>/dev/null || true
fi

# --- E7: starting GPU node count 1 in --autoscale -> exit non-zero ---
reset_logs
OUT7="${TMP_DIR}/outE7"
SEQ7="${TMP_DIR}/seqE7.txt"
printf '1\n1\n1\n' > "${SEQ7}"
export STUB_GPU_NODE_SEQ_FILE="${SEQ7}"
export SCALE_UP_TIMEOUT_SEC=5
export SCALE_DOWN_TIMEOUT_SEC=5
set +e
e7_out="$("${RUNNER}" --autoscale "${OUT7}" 2>&1)"
e7_status=$?
set -e

e7_pass=true
[[ "${e7_status}" -ne 0 ]] || e7_pass=false
grep -q "expected 0 GPU nodes" "${OUT7}/phases.log" 2>/dev/null || e7_pass=false
WATCHDOG_LEFTOVER+="$(check_watchdog_gone "${OUT7}")"

if [[ "${e7_pass}" == "true" ]]; then
  echo "E7 PASS"
else
  echo "E7 FAIL (status=${e7_status})"
  echo "--- phases.log ---"; cat "${OUT7}/phases.log" 2>/dev/null || true
  echo "--- output ---"; echo "${e7_out}"
  FAIL=1
fi

# --- watchdog leftover check across all tests above (E5's is torn down separately) ---
if [[ -z "${WATCHDOG_LEFTOVER}" ]]; then
  echo "E_WATCHDOG PASS"
else
  echo "E_WATCHDOG FAIL"
  echo "${WATCHDOG_LEFTOVER}"
  FAIL=1
fi

if [[ "${FAIL}" -ne 0 ]]; then
  exit 1
fi

exit 0
