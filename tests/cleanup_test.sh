#!/bin/bash
# Tests for scripts/cleanup.sh argument parsing and confirmation gate.
# Never calls real gcloud/kubectl/helm; uses stubs from tests/stubs/.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEANUP="${REPO_ROOT}/scripts/cleanup.sh"
STUB_DIR="${REPO_ROOT}/tests/stubs"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

export STUB_LOG="${TMP_DIR}/calls.log"
export PATH="${STUB_DIR}:${PATH}"
export PROJECT_ID="test-project"

FAIL=0

# --- T1: --yes skips confirmation and succeeds ---
: > "${STUB_LOG}"
export STUB_CLUSTER=absent
set +e
t1_out="$("${CLEANUP}" --yes </dev/null 2>&1)"
t1_status=$?
set -e

t1_pass=true
if [[ "${t1_status}" -ne 0 ]]; then
  t1_pass=false
fi
if echo "${t1_out}" | grep -q "Are you sure"; then
  t1_pass=false
fi
if grep -q "delete" "${STUB_LOG}"; then
  t1_pass=false
fi

if [[ "${t1_pass}" == "true" ]]; then
  echo "T1 PASS"
else
  echo "T1 FAIL (status=${t1_status})"
  echo "--- output ---"
  echo "${t1_out}"
  echo "--- calls log ---"
  cat "${STUB_LOG}"
  FAIL=1
fi

# --- T2: no --yes, no TTY: refuse before any gcloud/kubectl/helm call ---
: > "${STUB_LOG}"
export STUB_CLUSTER=absent
set +e
t2_out="$("${CLEANUP}" </dev/null 2>&1)"
t2_status=$?
set -e

t2_pass=true
if [[ "${t2_status}" -eq 0 ]]; then
  t2_pass=false
fi
if [[ -s "${STUB_LOG}" ]]; then
  t2_pass=false
fi

if [[ "${t2_pass}" == "true" ]]; then
  echo "T2 PASS"
else
  echo "T2 FAIL (status=${t2_status})"
  echo "--- output ---"
  echo "${t2_out}"
  echo "--- calls log ---"
  cat "${STUB_LOG}"
  FAIL=1
fi

# --- T3: unknown flag exits 2 ---
: > "${STUB_LOG}"
set +e
t3_out="$("${CLEANUP}" --bogus </dev/null 2>&1)"
t3_status=$?
set -e

if [[ "${t3_status}" -eq 2 ]]; then
  echo "T3 PASS"
else
  echo "T3 FAIL (status=${t3_status})"
  echo "--- output ---"
  echo "${t3_out}"
  FAIL=1
fi

if [[ "${FAIL}" -ne 0 ]]; then
  exit 1
fi

exit 0
