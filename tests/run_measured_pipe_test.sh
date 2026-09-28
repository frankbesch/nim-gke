#!/bin/bash
# Review round 2 regressions for scripts/run_measured.sh:
#   N1  output piped to tee + Ctrl-C to the process group: teardown still
#       runs (the reader of stdout is gone, so no write may abort it).
#   N2a cluster verified gone but a disk is left: the watchdog is stopped
#       (it cannot delete disks and must not outlive the cluster).
#   N2b watchdog left armed, then a new cluster with the same name appears:
#       the watchdog sees a different createTime and does not touch it.
# No network: tests/stubs on PATH plus fake RUNNER_* scripts.

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
export PATH="${STUB_DIR}:${PATH}"
export PROJECT_ID="test-project"
export NGC_API_KEY="test-key"
export POLL_SEC=1
export READY_TIMEOUT_SEC=5
export STUB_POD_READY=true
export OPS_WAIT_SEC=1

cat > "${FAKE_DIR}/ok" <<'EOF'
#!/bin/bash
echo "$(basename "$0") $*" >> "${CALLS_LOG}"
out=""
while [[ $# -gt 0 ]]; do [[ "$1" == "--out" ]] && out="$2"; shift; done
[[ -n "${out}" ]] && echo '{"ok":true}' > "${out}"
exit 0
EOF
cat > "${FAKE_DIR}/deploy_sleep" <<'EOF'
#!/bin/bash
echo "deploy $*" >> "${CALLS_LOG}"
sleep 3
EOF
# Cleanup fake: logs, optionally marks the cluster gone, exits FAKE_CLEANUP_EXIT.
cat > "${FAKE_DIR}/cleanup" <<'EOF'
#!/bin/bash
echo "cleanup $*" >> "${CALLS_LOG}"
if [[ -n "${FAKE_CLEANUP_SETS_ABSENT:-}" && -n "${STUB_CLUSTER_STATE_FILE:-}" ]]; then
  echo absent > "${STUB_CLUSTER_STATE_FILE}"
fi
exit "${FAKE_CLEANUP_EXIT:-0}"
EOF
chmod +x "${FAKE_DIR}"/*
export RUNNER_PREFLIGHT="${FAKE_DIR}/ok" RUNNER_BENCH="${FAKE_DIR}/ok" RUNNER_CLEANUP="${FAKE_DIR}/cleanup"

FAIL=0
pass() { echo "$1 PASS"; }
fail() { echo "$1 FAIL: $2"; FAIL=1; }
stop_watchdog() {  # $1 = OUT_DIR
  local pid
  pid="$(cat "$1/watchdog.pid" 2>/dev/null || true)"
  [[ -z "${pid}" ]] && return 0
  touch "$1/.watchdog_stop" 2>/dev/null || true
  kill "${pid}" 2>/dev/null || true
}

# --- N1: runner | tee, INT to the whole process group mid-deploy ---
: > "${CALLS_LOG}"
OUT1="${TMP_DIR}/outN1"
(
  set -m
  STUB_CLUSTER=absent RUNNER_DEPLOY="${FAKE_DIR}/deploy_sleep" \
    "${RUNNER}" "${OUT1}" 2>&1 | tee "${TMP_DIR}/n1.log" > /dev/null &
  sleep 1
  pgid="$(jobs -p %1)"
  kill -INT -- "-${pgid}" 2>/dev/null || true
  wait || true
)
# The runner is in a subshell job; give its trap time to finish.
for _ in $(seq 1 20); do
  grep -q "cleanup end (trap)" "${OUT1}/phases.log" 2>/dev/null && [[ -f "${OUT1}/final-clusters.txt" ]] && break
  sleep 1
done
if grep -q "^cleanup --yes" "${CALLS_LOG}" \
   && grep -q "cleanup end (trap)" "${OUT1}/phases.log" 2>/dev/null \
   && [[ -f "${OUT1}/final-clusters.txt" ]]; then
  pass N1
else
  fail N1 "teardown did not complete after Ctrl-C on a piped run"
  cat "${OUT1}/phases.log" 2>/dev/null || true
fi
stop_watchdog "${OUT1}"

# --- N2a: cluster gone, pvc- disk left -> non-zero exit, watchdog stopped ---
: > "${CALLS_LOG}"
OUT2="${TMP_DIR}/outN2a"
STATE2="${TMP_DIR}/state2"
echo "2026-01-01T00:00:00Z" > "${STATE2}"
set +e
STUB_CLUSTER_STATE_FILE="${STATE2}" FAKE_CLEANUP_SETS_ABSENT=1 \
  STUB_DISKS_OUTPUT="pvc-deadbeef us-central1-a 50 pd-balanced READY" \
  RUNNER_DEPLOY="${FAKE_DIR}/ok" WATCHDOG_SEC=600 \
  "${RUNNER}" "${OUT2}" > "${TMP_DIR}/n2a.log" 2>&1
n2a_status=$?
set -e
sleep 2
wd2="$(cat "${OUT2}/watchdog.pid" 2>/dev/null || true)"
if [[ "${n2a_status}" -ne 0 ]] && grep -q "pvc-deadbeef" "${TMP_DIR}/n2a.log" \
   && [[ -n "${wd2}" ]] && ! kill -0 "${wd2}" 2>/dev/null; then
  pass N2a
else
  fail N2a "status=${n2a_status}; watchdog must be stopped when the cluster is gone"
  stop_watchdog "${OUT2}"
fi

# --- N2b: watchdog armed (cluster stuck), then a new same-name cluster appears ---
: > "${CALLS_LOG}"
OUT3="${TMP_DIR}/outN2b"
STATE3="${TMP_DIR}/state3"
echo "2026-01-01T00:00:00Z" > "${STATE3}"
set +e
STUB_CLUSTER_STATE_FILE="${STATE3}" FAKE_CLEANUP_EXIT=1 CLEANUP_RETRY_SEC=2 \
  STUB_CLUSTERS_LIST_OUTPUT="nim-demo us-central1-a" \
  RUNNER_DEPLOY="${FAKE_DIR}/ok" WATCHDOG_SEC=12 \
  "${RUNNER}" "${OUT3}" > "${TMP_DIR}/n2b.log" 2>&1
n2b_status=$?
set -e
before="$(grep -c "^cleanup" "${CALLS_LOG}" || true)"
echo "2026-02-02T00:00:00Z" > "${STATE3}"   # a later run recreated nim-demo
for _ in $(seq 1 30); do
  grep -q "different cluster" "${OUT3}/phases.log" 2>/dev/null && break
  sleep 1
done
after="$(grep -c "^cleanup" "${CALLS_LOG}" || true)"
if [[ "${n2b_status}" -ne 0 ]] && grep -q "WATCHDOG LEFT ARMED" "${TMP_DIR}/n2b.log" \
   && grep -q "different cluster" "${OUT3}/phases.log" 2>/dev/null \
   && [[ "${before}" == "${after}" ]]; then
  pass N2b
else
  fail N2b "status=${n2b_status} cleanups before=${before} after=${after}"
  cat "${OUT3}/phases.log" 2>/dev/null || true
fi
stop_watchdog "${OUT3}"

exit "${FAIL}"
