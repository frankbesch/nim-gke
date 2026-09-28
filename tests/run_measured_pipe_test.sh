#!/bin/bash
# Review round 2 regressions for scripts/run_measured.sh:
#   N1  output piped to tee + Ctrl-C to the process group: teardown still
#       runs (the reader of stdout is gone, so no write may abort it).
#   N2a cluster verified gone but a disk is left: the watchdog is stopped
#       (it cannot delete disks and must not outlive the cluster).
#   N2b watchdog left armed, then a new cluster with the same name appears:
#       the watchdog sees a different createTime and does not touch it.
#   K1  SIGKILL to the runner's whole process group mid-deploy: the
#       watchdog (own session) survives and cleans up within seconds.
#   K2  pane-close sequence INT, HUP, KILL to the group: same outcome.
#   G1  Ctrl-C on a piped run leaves phases.log ungarbled (no duplicate or
#       bare-timestamp lines from bash 3.2's failed-write buffer).
#   D1  Ctrl-C to the process group during the normal end-of-run cleanup:
#       the trap re-enters the cleanup lock it already holds (no deadlock),
#       cleanup completes, the runner exits, and no lock dir is left.
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

# --- D1: INT to the group while the normal-path cleanup is running ---
: > "${CALLS_LOG}"
OUT4="${TMP_DIR}/outD1"
cat > "${FAKE_DIR}/cleanup_slow_first" <<'EOF2'
#!/bin/bash
echo "cleanup $*" >> "${CALLS_LOG}"
if [[ ! -f "${D1_STARTED}" ]]; then
  touch "${D1_STARTED}"
  sleep 4
fi
exit 0
EOF2
chmod +x "${FAKE_DIR}/cleanup_slow_first"
export D1_STARTED="${TMP_DIR}/d1.started"
(
  set -m
  STUB_CLUSTER=absent RUNNER_DEPLOY="${FAKE_DIR}/ok" RUNNER_CLEANUP="${FAKE_DIR}/cleanup_slow_first" \
    "${RUNNER}" "${OUT4}" > "${TMP_DIR}/d1.log" 2>&1 &
  for _ in $(seq 1 30); do [[ -f "${D1_STARTED}" ]] && break; sleep 0.5; done
  pgid="$(jobs -p %1)"
  kill -INT -- "-${pgid}" 2>/dev/null || true
  # Bounded wait: a deadlocked runner must fail this test, not hang CI.
  for _ in $(seq 1 60); do
    kill -0 -- "-${pgid}" 2>/dev/null || break
    sleep 1
  done
  if kill -0 -- "-${pgid}" 2>/dev/null; then
    echo "D1: runner still running 60 s after Ctrl-C (deadlock)" >> "${OUT4}/phases.log"
    kill -9 -- "-${pgid}" 2>/dev/null || true
  fi
  wait || true
)
d1_ok=true
[[ -f "${D1_STARTED}" ]] || d1_ok=false   # the normal-path cleanup really ran
(( $(grep -c '^cleanup' "${CALLS_LOG}") >= 2 )) || d1_ok=false   # plus the trap retry
! grep -q "deadlock" "${OUT4}/phases.log" 2>/dev/null || d1_ok=false
grep -q "cleanup end (trap)" "${OUT4}/phases.log" 2>/dev/null || d1_ok=false
[[ ! -d "${OUT4}/.cleanup_lock" ]] || d1_ok=false
[[ -f "${OUT4}/final-clusters.txt" ]] || d1_ok=false
if [[ "${d1_ok}" == "true" ]]; then
  pass D1
else
  fail D1 "trap cleanup after Ctrl-C during normal cleanup did not complete"
  cat "${OUT4}/phases.log" 2>/dev/null || true
  pkill -f "${OUT4}" 2>/dev/null || true
fi
stop_watchdog "${OUT4}"

# --- K1 / K2: the group is killed; the out-of-process watchdog cleans up ---
cat > "${FAKE_DIR}/deploy_long" <<'EOF2'
#!/bin/bash
echo "deploy $*" >> "${CALLS_LOG}"
python3 -c 'import time; time.sleep(30)'
EOF2
chmod +x "${FAKE_DIR}/deploy_long"
# Slow cleanup: in the live run 3 the KILL landed while the trap's cleanup ran.
cat > "${FAKE_DIR}/cleanup_slow" <<'EOF2'
#!/bin/bash
echo "cleanup $*" >> "${CALLS_LOG}"
sleep 2
if [[ -n "${STUB_CLUSTER_STATE_FILE:-}" ]]; then echo absent > "${STUB_CLUSTER_STATE_FILE}"; fi
exit 0
EOF2
chmod +x "${FAKE_DIR}/cleanup_slow"
run_killed() {  # $1 = label, $2 = "kill" or "pane"
  local out="${TMP_DIR}/out$1" state="${TMP_DIR}/state$1" pgid wd ok=true
  : > "${CALLS_LOG}"
  echo "2026-03-03T00:00:00Z" > "${state}"
  (
    set -m
    STUB_CLUSTER_STATE_FILE="${state}" RUNNER_CLEANUP="${FAKE_DIR}/cleanup_slow" \
      RUNNER_DEPLOY="${FAKE_DIR}/deploy_long" WATCHDOG_SEC=600 \
      "${RUNNER}" "${out}" 2>&1 | tee "${TMP_DIR}/$1.log" > /dev/null &
    sleep 2
    pgid="$(jobs -p %1)"
    if [[ "$2" == "pane" ]]; then
      kill -INT -- "-${pgid}" 2>/dev/null || true
      sleep 0.3
      kill -HUP -- "-${pgid}" 2>/dev/null || true
      sleep 0.3
    fi
    kill -KILL -- "-${pgid}" 2>/dev/null || true
    wait || true
  ) 2>/dev/null
  for _ in $(seq 1 30); do
    grep -q "WATCHDOG: cleanup done\|WATCHDOG: cluster already gone" "${out}/phases.log" 2>/dev/null && break
    sleep 1
  done
  grep -q "^cleanup --yes" "${CALLS_LOG}" || ok=false
  [[ "$(head -n1 "${state}")" == "absent" ]] || ok=false
  wd="$(cat "${out}/watchdog.pid" 2>/dev/null || true)"
  sleep 1
  [[ -n "${wd}" ]] && ! kill -0 "${wd}" 2>/dev/null || ok=false
  if [[ "${ok}" == "true" ]]; then
    pass "$1"
  else
    fail "$1" "watchdog did not clean up after the group was killed"
    cat "${out}/phases.log" 2>/dev/null || true
    stop_watchdog "${out}"
  fi
}
run_killed K1 kill
run_killed K2 pane

# --- G1: phases.log is clean after Ctrl-C on a piped run (N1's output) ---
if grep -qE "^[0-9TZ:-]+$|^$" "${OUT1}/phases.log" \
   || [[ "$(grep -c "cleanup start (trap)$" "${OUT1}/phases.log")" != "1" ]]; then
  fail G1 "phases.log garbled after Ctrl-C"
  cat -vet "${OUT1}/phases.log"
else
  pass G1
fi

exit "${FAIL}"
